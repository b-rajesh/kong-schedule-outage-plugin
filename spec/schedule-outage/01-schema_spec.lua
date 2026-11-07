-- SPDX-License-Identifier: Apache-2.0
local PLUGIN_NAME = "schedule-outage"

local schema_def = require("kong.plugins." .. PLUGIN_NAME .. ".schema")
local cases = require("spec.schedule-outage.calendar_cases")
local v = require("spec.helpers").validate_plugin_config_schema

local WINDOW = { start_time = "2026-12-01T02:00:00Z", end_time = "2026-12-01T06:00:00Z" }

-- Validates the valid WINDOW plus the given config fields.
local function check(extra)
  local config = { windows = { WINDOW } }
  for key, value in pairs(extra) do
    config[key] = value
  end
  return v(config, schema_def)
end

-- Validates one window with `field` (start_time or end_time) set to `value`.
-- Whether start_time precedes end_time is not a schema rule (see handler.lua).
local function check_time(field, value)
  local window = { start_time = WINDOW.start_time, end_time = WINDOW.end_time }
  window[field] = value
  return v({ windows = { window } }, schema_def)
end

-- A string of exactly `n` bytes that starts with `prefix`.
local function bytes(n, prefix)
  prefix = prefix or ""
  return prefix .. string.rep("a", n - #prefix)
end

-- Besides letters and digits, these are the RFC 9110 token characters, but for
-- "_". NOT_TOKEN holds the separators, quotes and white space: never in a token.
local TOKEN_PUNCTUATION = "!#$%&'*+-.^`|~"
local NOT_TOKEN = '"(),/:;<=>?@[\\]{} \t'

-- `count` distinct, valid response headers.
local function headers(count)
  local map = {}
  for i = 1, count do
    map["X-H" .. i] = "v"
  end
  return map
end

describe(PLUGIN_NAME .. ": (schema)", function()

  it("accepts a minimal config and fills defaults", function()
    local ok, err = v({ windows = { WINDOW } }, schema_def)
    assert.is_nil(err)
    assert.same({ WINDOW }, ok.config.windows)
    assert.equal(503, ok.config.status_code)
    assert.is_true(ok.config.retry_after)
    assert.is_true(ok.config.announce)
    assert.equal("Planned-Outage", ok.config.announce_header)
    assert.equal(604800, ok.config.announce_lead_time)
  end)

  it("accepts multiple windows and a custom announce header", function()
    local ok, err = v({
      windows = { WINDOW, { start_time = "2027-01-01T00:00:00Z", end_time = "2027-01-01T01:00:00Z" } },
      announce_header = "X-Maintenance",
      message = "Scheduled maintenance",
    }, schema_def)
    assert.is_nil(err)
    assert.equal(2, #ok.config.windows)
    assert.equal("X-Maintenance", ok.config.announce_header)
  end)

  it("requires at least one window", function()
    local _, err = v({ windows = {} }, schema_def)
    assert.is_truthy(err.config.windows)

    _, err = v({}, schema_def)
    assert.is_truthy(err.config.windows)
  end)

  for _, bad in ipairs({
    "2026-12-01 02:00:00Z",        -- missing T
    "2026-12-01T02:00:00",         -- no timezone
    "2026-12-01T02:00:00+10:00",   -- offsets not allowed, UTC only
    "2026-12-01T02:00:00.123Z",    -- no fractional seconds
    "01/12/2026",
  }) do
    it("rejects non RFC 3339 UTC timestamp " .. bad, function()
      local _, err = v({ windows = { { start_time = bad, end_time = WINDOW.end_time } } }, schema_def)
      assert.is_truthy(err.config.windows)
    end)
  end

  describe("calendar", function()
    -- The handler ignores a window it cannot parse, which would silently
    -- enforce no outage, so the schema must accept exactly the timestamps that
    -- exist. 06-calendar_spec.lua runs the same table through the handler.
    for _, field in ipairs({ "start_time", "end_time" }) do
      for _, case in ipairs(cases) do
        local stamp, valid, why = case[1], case[2], case[3]
        local name = string.format("%s %s %s (%s)", valid and "accepts" or "rejects", field, cases.show(stamp), why)

        it(name, function()
          local ok, err = check_time(field, stamp)
          if valid then
            assert.is_nil(err)
            assert.equal(stamp, ok.config.windows[1][field])
          else
            assert.is_truthy(err.config.windows[1][field])
          end
        end)
      end
    end

    it("says what is wrong with an impossible timestamp", function()
      local function message(value)
        local _, err = check_time("start_time", value)
        return err.config.windows[1].start_time
      end
      assert.equal("month must be 01-12", message("2026-13-01T00:00:00Z"))
      assert.equal("day must be 01-31", message("2026-12-32T00:00:00Z"))
      assert.equal("hour must be 00-23", message("2026-12-01T24:00:00Z"))
      assert.equal("February has at most 29 days", message("2026-02-30T00:00:00Z"))
      assert.equal("April, June, September and November have 30 days", message("2026-04-31T00:00:00Z"))
      assert.equal("29 February needs a leap year", message("2100-02-29T00:00:00Z"))
    end)
  end)

  for _, code in ipairs({ 200, 302, 399, 600 }) do
    it("rejects status_code " .. code, function()
      local _, err = v({ windows = { WINDOW }, status_code = code }, schema_def)
      assert.is_truthy(err.config.status_code)
    end)
  end

  it("rejects an invalid header name", function()
    local _, err = v({ windows = { WINDOW }, announce_header = "Bad Header:" }, schema_def)
    assert.is_truthy(err.config.announce_header)
  end)

  it("rejects a negative announce_lead_time", function()
    local _, err = v({ windows = { WINDOW }, announce_lead_time = -1 }, schema_def)
    assert.is_truthy(err.config.announce_lead_time)
  end)

  describe("scope", function()
    it("defaults protocols to http and https", function()
      local ok = assert(v({ windows = { WINDOW } }, schema_def))
      table.sort(ok.protocols)
      assert.same({ "http", "https" }, ok.protocols)
    end)

    it("rejects gRPC protocols", function()
      local _, err = v({ windows = { WINDOW } }, schema_def, { protocols = { "grpc" } })
      assert.is_truthy(err.protocols)
    end)

    it("rejects consumer scoping", function()
      local _, err = v({ windows = { WINDOW } }, schema_def,
                       { consumer = { id = "6f7e8a1c-2b3d-4e5f-8a9b-0c1d2e3f4a5b" } })
      assert.is_truthy(err.consumer)
    end)

    it("rejects consumer group scoping", function()
      local _, err = v({ windows = { WINDOW } }, schema_def,
                       { consumer_group = { id = "6f7e8a1c-2b3d-4e5f-8a9b-0c1d2e3f4a5b" } })
      assert.is_truthy(err.consumer_group)
    end)
  end)

  describe("custom response", function()
    it("is optional", function()
      -- Kong fills unset optional fields with ngx.null.
      local ok = assert(v({ windows = { WINDOW } }, schema_def))
      assert.equal(ngx.null, ok.config.response_body)
      assert.equal(ngx.null, ok.config.response_content_type)
      assert.equal(ngx.null, ok.config.response_headers)
    end)

    it("accepts a body template, content type and headers", function()
      local ok, err = v({
        windows = { WINDOW },
        response_body = '{"errors":[{"detail":"{message}"}]}',
        response_content_type = "application/json",
        response_headers = { ["X-Outage-End"] = "{end_time}" },
      }, schema_def)
      assert.is_nil(err)
      assert.equal("{end_time}", ok.config.response_headers["X-Outage-End"])
    end)

    it("rejects an empty body template", function()
      local _, err = v({ windows = { WINDOW }, response_body = "" }, schema_def)
      assert.is_truthy(err.config.response_body)
    end)

    it("rejects an invalid response header name", function()
      local _, err = v({ windows = { WINDOW }, response_headers = { ["Bad Header"] = "x" } }, schema_def)
      assert.is_truthy(err.config.response_headers)
    end)

    for _, good in ipairs({ "application/json", "application/problem+json; charset=utf-8", "text/html" }) do
      it("accepts content type " .. good, function()
        local _, err = check({ response_content_type = good })
        assert.is_nil(err)
      end)
    end

    -- A media type is sent as it is, so it keeps "_"; a header name does not
    -- (see "header names"): the PDK would send it as "-". The pattern accepts
    -- anything after the first character of the subtype, so only an underscore
    -- in the type or at the start of the subtype tests the token characters.
    for _, good in ipairs({ "application/vnd.my_app+json", "text/x_custom", "my_type/json", "text/_custom" }) do
      it("accepts content type " .. good .. ", with an underscore", function()
        local _, err = check({ response_content_type = good })
        assert.is_nil(err)
      end)
    end

    for _, case in ipairs({
      { "json", "no subtype separator" },
      { "/json", "no type" },
      { "application/", "no subtype" },
      { "application/json\r\nX-Evil: 1", "CR LF" },
      { "text/html\0x", "NUL" },
    }) do
      it("rejects content type with " .. case[2], function()
        local _, err = check({ response_content_type = case[1] })
        assert.is_truthy(err.config.response_content_type)
      end)
    end

    for _, case in ipairs({
      { "a\tb", "a tab" },
      { "a\rb", "a CR" },
      { "a\nb", "a LF" },
      { "a\0b", "a NUL" },
      { "a\127b", "a DEL" },
      { "", "no characters" },
    }) do
      it("rejects a response header value with " .. case[2], function()
        local _, err = check({ response_headers = { ["X-Value"] = case[1] } })
        assert.is_truthy(err.config.response_headers)
      end)
    end

    it("accepts a response header value with spaces and punctuation", function()
      local _, err = check({ response_headers = { ["X-Value"] = 'max-age=0; note="back at {end_time}"' } })
      assert.is_nil(err)
    end)
  end)

  describe("size limits", function()
    -- { field, limit in bytes, prefix that keeps the value well-formed }
    for _, case in ipairs({
      { "message", 512 },
      { "response_body", 4096 },
      { "response_content_type", 255, "text/" },
      { "announce_header", 64 },
    }) do
      local field, limit, prefix = case[1], case[2], case[3]

      it("accepts " .. field .. " of " .. limit .. " bytes", function()
        local _, err = check({ [field] = bytes(limit, prefix) })
        assert.is_nil(err)
      end)

      it("rejects " .. field .. " of " .. limit + 1 .. " bytes", function()
        local _, err = check({ [field] = bytes(limit + 1, prefix) })
        assert.is_truthy(err.config[field])
      end)
    end

    -- { at the limit, its response_headers, one over, its response_headers }
    for _, case in ipairs({
      { "20 response headers", headers(20),
        "21 response headers", headers(21) },
      { "a response header name of 64 bytes", { [bytes(64)] = "v" },
        "a response header name of 65 bytes", { [bytes(65)] = "v" } },
      { "a response header value of 256 bytes", { ["X-Value"] = bytes(256) },
        "a response header value of 257 bytes", { ["X-Value"] = bytes(257) } },
    }) do
      it("accepts " .. case[1], function()
        local _, err = check({ response_headers = case[2] })
        assert.is_nil(err)
      end)

      it("rejects " .. case[3], function()
        local _, err = check({ response_headers = case[4] })
        assert.is_truthy(err.config.response_headers)
      end)
    end

    it("accepts 100 windows and rejects 101", function()
      local windows = {}
      for i = 1, 100 do
        windows[i] = WINDOW
      end
      local _, err = v({ windows = windows }, schema_def)
      assert.is_nil(err)

      windows[101] = WINDOW
      _, err = v({ windows = windows }, schema_def)
      assert.is_truthy(err.config.windows)
    end)
  end)

  describe("header names", function()
    -- Framing headers are set by Kong and nginx: a custom value would corrupt
    -- or stall the response.
    for _, name in ipairs({
      "Content-Length", "content-length", "TRANSFER-ENCODING", "Connection",
      "keep-alive", "Upgrade", "TE", "Trailer",
    }) do
      it("rejects " .. name .. " as a response header", function()
        local _, err = check({ response_headers = { [name] = "x" } })
        assert.is_truthy(err.config.response_headers)
      end)
    end

    -- The handler lets these override the outage response defaults.
    for _, name in ipairs({ "Content-Type", "Cache-Control", "Retry-After" }) do
      it("accepts " .. name .. " as a response header", function()
        local _, err = check({ response_headers = { [name] = "x" } })
        assert.is_nil(err)
      end)
    end

    it("only rejects exact framing names as response headers", function()
      local _, err = check({ response_headers = {
        ["X-Content-Length"] = "1", ["Connection-Id"] = "2", ["Tea"] = "3", ["Trailers"] = "4",
      } })
      assert.is_nil(err)
    end)

    -- The announcement is added to every proxied response, so it must not
    -- stall it (framing headers) or replace what the upstream said about its
    -- payload.
    for _, name in ipairs({
      "Content-Length", "TRANSFER-ENCODING", "Connection", "Keep-Alive", "uPgRaDe", "Te", "TRAILER",
      "Content-Type", "content-ENCODING", "Cache-Control", "SET-COOKIE", "ETag", "Last-Modified",
      "EXPIRES", "Date", "LOCATION",
    }) do
      it("rejects " .. name .. " as announce_header", function()
        local _, err = check({ announce_header = name })
        assert.is_truthy(err.config.announce_header)
      end)
    end

    for _, name in ipairs({ "Planned-Outage", "X-Maintenance", "X-Date", "Expires-At", "Etags" }) do
      it("accepts " .. name .. " as announce_header", function()
        local ok, err = check({ announce_header = name })
        assert.is_nil(err)
        assert.equal(name, ok.config.announce_header)
      end)
    end

    -- The PDK sends "_" as "-", so the header on the wire would differ from
    -- the one configured.
    it("rejects an underscore in announce_header", function()
      local _, err = check({ announce_header = "My_Hdr" })
      assert.is_truthy(err.config.announce_header)
    end)

    it("rejects an underscore in a response header name", function()
      local _, err = check({ response_headers = { ["X_Under"] = "v" } })
      assert.is_truthy(err.config.response_headers)
    end)

    -- Header names and the type of a media type are tokens.
    it("accepts every token character in a header name and a media type", function()
      local name = "A" .. TOKEN_PUNCTUATION .. "z0"
      local _, err = check({
        announce_header = name,
        response_headers = { [name] = "v" },
        response_content_type = name .. "_/" .. name .. "_",
      })
      assert.is_nil(err)
    end)

    for char in NOT_TOKEN:gmatch(".") do
      it(string.format("rejects %q in a header name and in a media type", char), function()
        local name = "X" .. char .. "Y"
        local _, err = check({ announce_header = name })
        assert.is_truthy(err.config.announce_header)
        _, err = check({ response_headers = { [name] = "v" } })
        assert.is_truthy(err.config.response_headers)
        if char ~= "/" then
          _, err = check({ response_content_type = name .. "/html" })
          assert.is_truthy(err.config.response_content_type)
        end
      end)
    end
  end)
end)
