-- SPDX-License-Identifier: Apache-2.0
-- The calendar, through the handler: every timestamp of the shared table
-- (calendar_cases.lua) is enforced as an outage window exactly when it exists,
-- and exactly when the schema accepts it, so neither side can change without
-- the other. Kong is not started; see handler_stubs.lua. Unlike the other
-- handler specs this one loads the Kong test helpers, to ask Kong's own schema
-- validation for its verdicts, and so needs a database connection like 01.

local stubs = require "spec.schedule-outage.handler_stubs"
local cases = require "spec.schedule-outage.calendar_cases"
local schema_def = require("kong.plugins." .. stubs.PLUGIN_NAME .. ".schema")
local v = require("spec.helpers").validate_plugin_config_schema

local new_conf, window = stubs.new_conf, stubs.window
local DEC_01_0200, DEC_01_0600 = stubs.DEC_01_0200, stubs.DEC_01_0600

-- Each stamp is tried as the start of a window that ends at the last second the
-- format can express, and as the end of one that starts at the first second,
-- with the clock inside the window. The one stamp that would leave a window
-- without length in a position is not tried there.
local FIRST, FIRST_EPOCH = "0000-01-01T00:00:00Z", -62167219200
local LAST, LAST_EPOCH = "9999-12-31T23:59:59Z", 253402300799

local POSITIONS = { "start_time", "end_time" }
local PLACEMENT = {
  start_time = { window = function(stamp) return window(stamp, LAST) end, now = LAST_EPOCH - 1, skip = LAST },
  end_time = { window = function(stamp) return window(FIRST, stamp) end, now = FIRST_EPOCH, skip = FIRST },
}

describe(stubs.PLUGIN_NAME .. ": (calendar)", function()
  local s = stubs.new()
  before_each(s.setup)
  after_each(s.teardown)

  -- Kong's verdict on each stamp in each position, asked once and before the
  -- stubs replace `kong`.
  local accepted = { start_time = {}, end_time = {} }
  lazy_setup(function()
    for _, position in ipairs(POSITIONS) do
      for _, case in ipairs(cases) do
        local _, err = v({ windows = { PLACEMENT[position].window(case[1]) } }, schema_def)
        accepted[position][case[1]] = err == nil
      end
    end
  end)

  -- Handles a request, with the clock inside the window that has `stamp` in
  -- `position`; returns the outage response, if there was one.
  local function request_with(stamp, position)
    local placement = PLACEMENT[position]
    s.now = placement.now
    local exit = s.request(new_conf({ placement.window(stamp) }))
    return exit
  end

  it("has valid and invalid timestamps", function()
    local valid = 0
    for _, case in ipairs(cases) do
      valid = valid + (case[2] and 1 or 0)
    end
    assert.is_true(valid > 0 and valid < #cases)
  end)

  for _, position in ipairs(POSITIONS) do
    for _, case in ipairs(cases) do
      local stamp, valid, why = case[1], case[2], case[3]

      if stamp ~= PLACEMENT[position].skip then
        local label = string.format("%s as %s (%s)", cases.show(stamp), position, why)

        it((valid and "enforces " or "ignores ") .. label, function()
          local exit = request_with(stamp, position)
          if valid then
            assert.is_table(exit)
            assert.equal(503, exit.status)
            assert.same({}, s.errors)
            assert.same({}, s.crits)
          else
            assert.is_nil(exit)
            assert.equal(1, #s.errors)
            assert.is_truthy(s.errors[1]:find("ignoring window #1", 1, true))
          end
        end)

        it("agrees with the schema on " .. label, function()
          assert.equal(accepted[position][stamp], request_with(stamp, position) ~= nil)
        end)
      end
    end
  end

  describe("a window without length", function()
    local MESSAGE = "ignoring window #1: start_time must be before end_time"

    for _, case in ipairs({
      { window("2026-12-01T02:00:00Z", "2026-12-01T02:00:00Z"), "start equal to end" },
      { window("2026-12-01T02:00:01Z", "2026-12-01T02:00:00Z"), "start one second after end" },
      { window("2027-01-01T00:00:00Z", "2026-12-01T00:00:00Z"), "start a month after end" },
    }) do
      it("is ignored, and no outage starts: " .. case[2], function()
        local conf = new_conf({ case[1] })
        for _, now in ipairs({ DEC_01_0200 - 1, DEC_01_0200, DEC_01_0200 + 1, DEC_01_0600 }) do
          s.now = now
          local exit = s.request(conf)
          assert.is_nil(exit)
        end
        assert.same({}, s.exits)
        assert.equal(1, #s.errors)
        assert.is_truthy(s.errors[1]:find(MESSAGE, 1, true))
        assert.equal(1, #s.crits)
      end)
    end

    it("is the only window ignored when others are valid", function()
      local conf = new_conf({
        window("2026-12-01T02:00:00Z", "2026-12-01T02:00:00Z"),
        window("2026-12-01T02:00:00Z", "2026-12-01T06:00:00Z"),
      })
      s.now = DEC_01_0200
      local exit = s.request(conf)
      assert.is_table(exit)
      assert.equal(503, exit.status)
      assert.equal(1, #s.errors)
      assert.is_truthy(s.errors[1]:find(MESSAGE, 1, true))
      assert.same({}, s.crits)
    end)
  end)
end)
