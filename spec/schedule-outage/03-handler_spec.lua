-- Unit tests for the handler. Kong is not started: the `kong` PDK and
-- `ngx.time` are replaced with stubs so the clock can be set per test.

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
  local handler, exits, headers, errors

  before_each(function()
    exits, headers, errors = {}, {}, {}

    _G.ngx = _G.ngx or {}
    real_ngx_time = ngx.time
    ngx.time = function() return now end

    real_kong = _G.kong
    _G.kong = {
      ctx = { plugin = {} },
      log = { err = function(...) errors[#errors + 1] = table.concat({ ... }) end },
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

  describe("without setmetatable (strict Lua sandbox)", function()
    before_each(function()
      local real_setmetatable = setmetatable
      _G.setmetatable = nil
      local ok, result = pcall(load_handler)
      _G.setmetatable = real_setmetatable
      assert(ok, result)
      handler = result
    end)

    it("loads and enforces windows", function()
      local conf = new_conf({ window("2026-12-01T02:00:00Z", "2026-12-01T06:00:00Z") })
      now = DEC_01_0200 - 1
      assert.is_nil(request(conf))
      now = DEC_01_0200
      assert.equal(503, request(conf).status)
    end)

    it("keeps working after the cache is cleared", function()
      now = DEC_01_0200
      for i = 1, 1100 do
        exits = {}
        local conf = new_conf({ window("2026-12-01T02:00:00Z", "2026-12-01T06:00:00Z") })
        assert.equal(503, request(conf).status, "request " .. i)
      end
    end)
  end)
end)
