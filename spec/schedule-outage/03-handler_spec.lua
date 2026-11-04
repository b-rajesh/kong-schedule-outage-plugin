-- Unit tests for the handler. Kong is not started: the `kong` PDK and
-- `ngx.time` are replaced with stubs so the clock can be set per test.

local cjson = require "cjson"

local PLUGIN_NAME = "schedule-outage"
local MODULE = "kong.plugins." .. PLUGIN_NAME .. ".handler"

-- Reference values computed with `date -u`.
local DEC_01_0200 = 1796090400   -- 2026-12-01T02:00:00Z
local DEC_01_0600 = 1796104800   -- 2026-12-01T06:00:00Z
local LEAP_DAY_END = 1835481599  -- 2028-02-29T23:59:59Z

local now
local real_ngx_time
local real_kong

local function load_handler()
  package.loaded[MODULE] = nil
  return require(MODULE)
end

local function new_conf(windows, overrides)
  local conf = {
    windows = windows,
    status_code = 503,
    retry_after = true,
    announce = true,
    announce_header = "Planned-Outage",
    announce_lead_time = 0,
  }
  for k, v in pairs(overrides or {}) do
    conf[k] = v
  end
  return conf
end

local function window(start_time, end_time)
  return { start_time = start_time, end_time = end_time }
end

describe(PLUGIN_NAME .. ": (handler)", function()
  local handler, exits, headers, errors, crits

  before_each(function()
    exits, headers, errors, crits = {}, {}, {}, {}

    _G.ngx = _G.ngx or {}
    real_ngx_time = ngx.time
    ngx.time = function() return now end

    real_kong = _G.kong
    _G.kong = {
      ctx = { plugin = {} },
      log = {
        err = function(...) errors[#errors + 1] = table.concat({ ... }) end,
        crit = function(...) crits[#crits + 1] = table.concat({ ... }) end,
      },
      request = { get_id = function() return "a1b2c3d4" end },
      response = {
        exit = function(status, body, hdrs)
          exits[#exits + 1] = { status = status, body = body, headers = hdrs }
          return true
        end,
        set_header = function(name, value) headers[name] = value end,
      },
    }

    handler = load_handler()
  end)

  after_each(function()
    ngx.time = real_ngx_time
    _G.kong = real_kong
    package.loaded[MODULE] = nil
  end)

  -- Runs both phases for one request and returns the outcome.
  local function request(conf)
    kong.ctx.plugin = {}
    handler:access(conf)
    if #exits == 0 then
      handler:header_filter(conf)
    end
    return exits[1], headers
  end

  describe("UTC conversion", function()
    local conf = new_conf({ window("2026-12-01T02:00:00Z", "2026-12-01T06:00:00Z") })

    it("treats start_time as inclusive", function()
      now = DEC_01_0200
      local exit = request(conf)
      assert.equal(503, exit.status)
      assert.equal(tostring(DEC_01_0600 - DEC_01_0200), exit.headers["Retry-After"])
    end)

    it("proxies one second before start_time", function()
      now = DEC_01_0200 - 1
      local exit, hdrs = request(conf)
      assert.is_nil(exit)
      assert.equal('start="2026-12-01T02:00:00Z", end="2026-12-01T06:00:00Z"', hdrs["Planned-Outage"])
    end)

    it("treats end_time as exclusive", function()
      now = DEC_01_0600 - 1
      assert.equal("1", request(conf).headers["Retry-After"])

      exits = {}
      now = DEC_01_0600
      assert.is_nil(request(conf))
    end)

    it("handles leap days", function()
      now = LEAP_DAY_END
      local exit = request(new_conf({ window("2028-02-29T23:59:59Z", "2028-03-01T00:00:30Z") }))
      assert.equal("31", exit.headers["Retry-After"])
    end)
  end)

  describe("invalid windows", function()
    it("ignores and logs a date that does not exist", function()
      now = DEC_01_0200
      local exit = request(new_conf({ window("2026-02-30T00:00:00Z", "2026-12-31T00:00:00Z") }))
      assert.is_nil(exit)
      assert.equal(1, #errors)
      assert.matches("out of range", errors[1])
    end)

    it("ignores and logs a window whose start is not before its end", function()
      now = DEC_01_0200
      assert.is_nil(request(new_conf({ window("2026-12-01T06:00:00Z", "2026-12-01T02:00:00Z") })))
      assert.matches("start_time must be before end_time", errors[1])
    end)

    it("logs a critical message when every window is invalid", function()
      now = DEC_01_0200
      request(new_conf({ window("2026-02-30T00:00:00Z", "2026-12-31T00:00:00Z"),
                         window("2026-12-01T06:00:00Z", "2026-12-01T02:00:00Z") }))
      assert.equal(1, #crits)
      assert.matches("all 2 configured windows are invalid", crits[1], 1, true)
    end)

    it("does not log a critical message when one window is valid", function()
      now = DEC_01_0200
      request(new_conf({ window("2026-02-30T00:00:00Z", "2026-12-31T00:00:00Z"),
                         window("2026-12-01T02:00:00Z", "2026-12-01T06:00:00Z") }))
      assert.equal(1, #errors)
      assert.equal(0, #crits)
    end)
  end)

  describe("response", function()
    it("builds an RFC 9457 problem document", function()
      now = DEC_01_0200
      local exit = request(new_conf({ window("2026-12-01T02:00:00Z", "2026-12-01T06:00:00Z") },
                                    { status_code = 418, message = "Back soon" }))
      assert.equal(418, exit.status)
      assert.equal("application/problem+json", exit.headers["Content-Type"])
      assert.equal("no-store", exit.headers["Cache-Control"])
      assert.same({
        type = "about:blank",
        status = 418,
        detail = "Back soon",
        outage_start = "2026-12-01T02:00:00Z",
        outage_end = "2026-12-01T06:00:00Z",
      }, exit.body)
    end)
  end)

  describe("problem title", function()
    for status, title in pairs({ [501] = "Not Implemented", [507] = "Insufficient Storage",
                                 [451] = "Unavailable For Legal Reasons" }) do
      it("is the IANA reason phrase for " .. status, function()
        now = DEC_01_0200
        local w = window("2026-12-01T02:00:00Z", "2026-12-01T06:00:00Z")
        assert.equal(title, request(new_conf({ w }, { status_code = status })).body.title)
      end)
    end
  end)

  describe("response template", function()
    local DEC_01 = { start_time = "2026-12-01T02:00:00Z", end_time = "2026-12-01T06:00:00Z" }

    it("renders every placeholder", function()
      now = DEC_01_0200
      local exit = request(new_conf({ DEC_01 }, {
        message = "Back soon",
        response_body = '{"s":{status},"m":"{message}","from":"{start_time}","to":"{end_time}",'
                        .. '"retry":{retry_after},"id":"{request_id}"}',
      }))
      assert.equal("application/json", exit.headers["Content-Type"])
      assert.same({
        s = 503, m = "Back soon",
        from = "2026-12-01T02:00:00Z", to = "2026-12-01T06:00:00Z",
        retry = DEC_01_0600 - DEC_01_0200, id = "a1b2c3d4",
      }, cjson.decode(exit.body))
    end)

    it("produces a custom error shape, e.g. CDR", function()
      now = DEC_01_0200
      local exit = request(new_conf({ DEC_01 }, {
        message = "Core banking upgrade",
        response_body = '{"errors":[{"code":"urn:au-cds:error:cds-all:Service/Unavailable",'
                        .. '"title":"Service Unavailable","detail":"{message}","meta":{}}]}',
      }))
      assert.equal('{"errors":[{"code":"urn:au-cds:error:cds-all:Service/Unavailable",'
                   .. '"title":"Service Unavailable","detail":"Core banking upgrade","meta":{}}]}', exit.body)
    end)

    it("JSON-escapes values for a JSON content type", function()
      now = DEC_01_0200
      local msg = 'Quote " backslash \\ newline \n bell \7'
      local exit = request(new_conf({ DEC_01 }, { message = msg, response_body = '{"m":"{message}"}' }))
      assert.equal(msg, cjson.decode(exit.body).m)
    end)

    it("does not escape values for other content types", function()
      now = DEC_01_0200
      local exit = request(new_conf({ DEC_01 }, {
        message = 'He said "soon"',
        response_body = "<p>{message}</p>",
        response_content_type = "text/html",
      }))
      assert.equal("text/html", exit.headers["Content-Type"])
      assert.equal('<p>He said "soon"</p>', exit.body)
    end)

    it("leaves unknown placeholders untouched", function()
      now = DEC_01_0200
      local exit = request(new_conf({ DEC_01 }, { response_body = '{"x":"{unknown}","meta":{}}' }))
      assert.equal('{"x":"{unknown}","meta":{}}', exit.body)
    end)

    it("uses an empty message when none is configured", function()
      now = DEC_01_0200
      local exit = request(new_conf({ DEC_01 }, { response_body = '{"m":"{message}"}' }))
      assert.equal('{"m":""}', exit.body)
    end)

    it("treats ngx.null optional fields as unset", function()
      now = DEC_01_0200
      local exit = request(new_conf({ DEC_01 }, {
        message = ngx.null,
        response_body = ngx.null,
        response_content_type = ngx.null,
        response_headers = ngx.null,
      }))
      assert.equal("application/problem+json", exit.headers["Content-Type"])
      assert.equal("about:blank", exit.body.type)
      assert.is_nil(exit.body.detail)
    end)

    it("keeps the problem document with only a custom content type", function()
      now = DEC_01_0200
      local exit = request(new_conf({ DEC_01 }, { response_content_type = "application/json" }))
      assert.equal("application/json", exit.headers["Content-Type"])
      assert.equal("about:blank", exit.body.type)
    end)

    it("adds custom headers, rendered and able to override defaults", function()
      now = DEC_01_0200
      local exit = request(new_conf({ DEC_01 }, {
        message = "line one\r\nInjected: yes",
        response_headers = {
          ["X-Outage-End"] = "{end_time}",
          ["X-Outage-Message"] = "{message}",
          ["Cache-Control"] = "no-cache",
        },
      }))
      assert.equal("2026-12-01T06:00:00Z", exit.headers["X-Outage-End"])
      assert.equal("line oneInjected: yes", exit.headers["X-Outage-Message"])
      assert.equal("no-cache", exit.headers["Cache-Control"])
    end)
  end)

  describe("schedule cache", function()
    local function mixed_conf()
      return new_conf({ window("2026-02-30T00:00:00Z", "2026-12-31T00:00:00Z"),
                        window("2026-12-01T02:00:00Z", "2026-12-01T06:00:00Z") })
    end

    it("parses each configuration once and stores it on the config", function()
      local conf = mixed_conf()
      now = DEC_01_0200 - 1
      request(conf)
      request(conf)
      assert.equal(1, #errors)
      assert.is_table(conf.__schedule_outage)
    end)

    it("parses a new configuration again", function()
      now = DEC_01_0200 - 1
      request(mixed_conf())
      request(mixed_conf())
      assert.equal(2, #errors)
    end)

    it("still enforces windows when the config is read-only", function()
      local readonly = setmetatable({}, {
        __index = mixed_conf(),
        __newindex = function() error("read-only config") end,
      })
      now = DEC_01_0200
      assert.equal(503, request(readonly).status)
      exits = {}
      assert.equal(503, request(readonly).status)
      assert.equal(2, #errors)
    end)

    it("loads without setmetatable (strict Lua sandbox)", function()
      local real_setmetatable = setmetatable
      _G.setmetatable = nil
      local ok, result = pcall(load_handler)
      _G.setmetatable = real_setmetatable
      assert(ok, result)
      handler = result

      now = DEC_01_0200
      assert.equal(503, request(new_conf({ window("2026-12-01T02:00:00Z", "2026-12-01T06:00:00Z") })).status)
    end)
  end)
end)
