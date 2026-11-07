-- SPDX-License-Identifier: Apache-2.0
-- Unit tests for the handler's windows and responses: UTC conversion, invalid
-- windows, the problem document and response templates. Kong is not started;
-- see handler_stubs.lua.

local cjson = require "cjson"
local stubs = require "spec.schedule-outage.handler_stubs"

local new_conf, window = stubs.new_conf, stubs.window
local DEC_01_0200, DEC_01_0600 = stubs.DEC_01_0200, stubs.DEC_01_0600
local LEAP_DAY_END = 1835481599  -- 2028-02-29T23:59:59Z, computed with `date -u`

describe(stubs.PLUGIN_NAME .. ": (handler)", function()
  local s = stubs.new()
  local request = s.request

  before_each(s.setup)
  after_each(s.teardown)

  describe("UTC conversion", function()
    local conf = new_conf({ window("2026-12-01T02:00:00Z", "2026-12-01T06:00:00Z") })

    it("treats start_time as inclusive", function()
      s.now = DEC_01_0200
      local exit = request(conf)
      assert.equal(503, exit.status)
      assert.equal(tostring(DEC_01_0600 - DEC_01_0200), exit.headers["Retry-After"])
    end)

    it("proxies one second before start_time", function()
      s.now = DEC_01_0200 - 1
      local exit, hdrs = request(conf)
      assert.is_nil(exit)
      assert.equal('start="2026-12-01T02:00:00Z", end="2026-12-01T06:00:00Z"', hdrs["Planned-Outage"])
    end)

    it("treats end_time as exclusive", function()
      s.now = DEC_01_0600 - 1
      assert.equal("1", request(conf).headers["Retry-After"])

      s.exits = {}
      s.now = DEC_01_0600
      assert.is_nil(request(conf))
    end)

    it("handles leap days", function()
      s.now = LEAP_DAY_END
      local exit = request(new_conf({ window("2028-02-29T23:59:59Z", "2028-03-01T00:00:30Z") }))
      assert.equal("31", exit.headers["Retry-After"])
    end)
  end)

  describe("invalid windows", function()
    it("ignores and logs a date that does not exist", function()
      s.now = DEC_01_0200
      local exit = request(new_conf({ window("2026-02-30T00:00:00Z", "2026-12-31T00:00:00Z") }))
      assert.is_nil(exit)
      assert.equal(1, #s.errors)
      assert.matches("out of range", s.errors[1])
    end)

    it("ignores and logs a window whose start is not before its end", function()
      s.now = DEC_01_0200
      assert.is_nil(request(new_conf({ window("2026-12-01T06:00:00Z", "2026-12-01T02:00:00Z") })))
      assert.matches("start_time must be before end_time", s.errors[1])
    end)

    it("logs a critical message when every window is invalid", function()
      s.now = DEC_01_0200
      request(new_conf({ window("2026-02-30T00:00:00Z", "2026-12-31T00:00:00Z"),
                         window("2026-12-01T06:00:00Z", "2026-12-01T02:00:00Z") }))
      assert.equal(1, #s.crits)
      assert.matches("all 2 configured windows are invalid", s.crits[1], 1, true)
    end)

    it("does not log a critical message when one window is valid", function()
      s.now = DEC_01_0200
      request(new_conf({ window("2026-02-30T00:00:00Z", "2026-12-31T00:00:00Z"),
                         window("2026-12-01T02:00:00Z", "2026-12-01T06:00:00Z") }))
      assert.equal(1, #s.errors)
      assert.equal(0, #s.crits)
    end)

    -- Both kinds of invalid window, so every message is checked.
    local function log_messages(overrides)
      s.now = DEC_01_0200
      request(new_conf({ window("2026-02-30T00:00:00Z", "2026-12-31T00:00:00Z"),
                         window("2026-12-01T06:00:00Z", "2026-12-01T02:00:00Z") }, overrides))
      return s.errors, s.crits
    end

    it("ends the messages with the plugin id when the config has one", function()
      local errors, crits = log_messages({ __plugin_id = "0a1b2c3d" })
      assert.same({ "ignoring window #1: date or time out of range (plugin 0a1b2c3d)",
                    "ignoring window #2: start_time must be before end_time (plugin 0a1b2c3d)" }, errors)
      assert.same({ "all 2 configured windows are invalid: no outage will be enforced (plugin 0a1b2c3d)" }, crits)
    end)

    local function assert_plain_messages(overrides)
      local errors, crits = log_messages(overrides)
      assert.same({ "ignoring window #1: date or time out of range",
                    "ignoring window #2: start_time must be before end_time" }, errors)
      assert.same({ "all 2 configured windows are invalid: no outage will be enforced" }, crits)
    end

    it("leaves the messages as they are without a plugin id", function()
      assert_plain_messages()
    end)

    it("ignores a plugin id that is not a string", function()
      assert_plain_messages({ __plugin_id = ngx.null })
    end)
  end)

  describe("response", function()
    it("builds an RFC 9457 problem document", function()
      s.now = DEC_01_0200
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
        s.now = DEC_01_0200
        local w = window("2026-12-01T02:00:00Z", "2026-12-01T06:00:00Z")
        assert.equal(title, request(new_conf({ w }, { status_code = status })).body.title)
      end)
    end
  end)

  describe("response template", function()
    local DEC_01 = { start_time = "2026-12-01T02:00:00Z", end_time = "2026-12-01T06:00:00Z" }

    it("renders every placeholder", function()
      s.now = DEC_01_0200
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
      s.now = DEC_01_0200
      local exit = request(new_conf({ DEC_01 }, {
        message = "Core banking upgrade",
        response_body = '{"errors":[{"code":"urn:au-cds:error:cds-all:Service/Unavailable",'
                        .. '"title":"Service Unavailable","detail":"{message}","meta":{}}]}',
      }))
      assert.equal('{"errors":[{"code":"urn:au-cds:error:cds-all:Service/Unavailable",'
                   .. '"title":"Service Unavailable","detail":"Core banking upgrade","meta":{}}]}', exit.body)
    end)

    it("JSON-escapes values for a JSON content type", function()
      s.now = DEC_01_0200
      local msg = 'Quote " backslash \\ newline \n bell \7'
      local exit = request(new_conf({ DEC_01 }, { message = msg, response_body = '{"m":"{message}"}' }))
      assert.equal(msg, cjson.decode(exit.body).m)
    end)

    it("does not escape values for other content types", function()
      s.now = DEC_01_0200
      local exit = request(new_conf({ DEC_01 }, {
        message = 'He said "soon"',
        response_body = "<p>{message}</p>",
        response_content_type = "text/html",
      }))
      assert.equal("text/html", exit.headers["Content-Type"])
      assert.equal('<p>He said "soon"</p>', exit.body)
    end)

    -- Media types are case-insensitive (RFC 9110, section 8.3.1).
    for _, case in ipairs({
      { "Application/JSON", true }, { "APPLICATION/JSON", true },
      { "application/vnd.api+json", true }, { "text/json; charset=utf-8", true },
      { "text/html", false }, { "text/plain", false },
    }) do
      local content_type, escaped = case[1], case[2]
      it((escaped and "escapes" or "does not escape") .. " values for " .. content_type, function()
        s.now = DEC_01_0200
        local msg = 'He said "soon"\n'
        local exit = request(new_conf({ DEC_01 }, {
          message = msg,
          response_body = '{"m":"{message}"}',
          response_content_type = content_type,
        }))
        assert.equal(content_type, exit.headers["Content-Type"])
        if escaped then
          assert.equal(msg, cjson.decode(exit.body).m)
        else
          assert.equal('{"m":"' .. msg .. '"}', exit.body)
        end
      end)
    end

    it("leaves unknown placeholders untouched", function()
      s.now = DEC_01_0200
      local exit = request(new_conf({ DEC_01 }, { response_body = '{"x":"{unknown}","meta":{}}' }))
      assert.equal('{"x":"{unknown}","meta":{}}', exit.body)
    end)

    it("uses an empty message when none is configured", function()
      s.now = DEC_01_0200
      local exit = request(new_conf({ DEC_01 }, { response_body = '{"m":"{message}"}' }))
      assert.equal('{"m":""}', exit.body)
    end)

    it("treats ngx.null optional fields as unset", function()
      s.now = DEC_01_0200
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
      s.now = DEC_01_0200
      local exit = request(new_conf({ DEC_01 }, { response_content_type = "application/json" }))
      assert.equal("application/json", exit.headers["Content-Type"])
      assert.equal("about:blank", exit.body.type)
    end)

    it("adds custom headers, rendered and able to override defaults", function()
      s.now = DEC_01_0200
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
end)
