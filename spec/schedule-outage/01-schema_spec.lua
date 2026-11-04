local PLUGIN_NAME = "schedule-outage"

local schema_def = require("kong.plugins." .. PLUGIN_NAME .. ".schema")
local v = require("spec.helpers").validate_plugin_config_schema

local WINDOW = { start_time = "2026-12-01T02:00:00Z", end_time = "2026-12-01T06:00:00Z" }

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
  end)
end)
