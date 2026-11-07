-- SPDX-License-Identifier: Apache-2.0
-- Unit tests for the outage response headers and the announcement header set
-- in header_filter. Kong is not started; see handler_stubs.lua.

local stubs = require "spec.schedule-outage.handler_stubs"

local new_conf, window = stubs.new_conf, stubs.window
local DEC_01_0200, DEC_01_0600 = stubs.DEC_01_0200, stubs.DEC_01_0600

describe(stubs.PLUGIN_NAME .. ": (handler)", function()
  local s = stubs.new()
  local request = s.request

  before_each(s.setup)
  after_each(s.teardown)

  describe("response headers", function()
    local W = window("2026-12-01T02:00:00Z", "2026-12-01T06:00:00Z")

    -- Headers of the rejection for a configuration with the given overrides.
    local function outage_headers(overrides)
      s.now = DEC_01_0200
      s.exits = {}
      return request(new_conf({ W }, overrides)).headers
    end

    -- The spellings under which `name` appears in `hdrs`, in any letter case.
    local function spellings(hdrs, name)
      local found = {}
      for k in pairs(hdrs) do
        if k:lower() == name:lower() then
          found[#found + 1] = k
        end
      end
      return found
    end

    it("sends exactly the three defaults when nothing is configured", function()
      assert.same({
        ["Cache-Control"] = "no-store",
        ["Retry-After"] = tostring(DEC_01_0600 - DEC_01_0200),
        ["Content-Type"] = "application/problem+json",
      }, outage_headers())
    end)

    for _, case in ipairs({
      { custom = "cache-control", canonical = "Cache-Control", value = "max-age=60" },
      { custom = "CACHE-CONTROL", canonical = "Cache-Control", value = "max-age=60" },
      { custom = "RETRY-AFTER", canonical = "Retry-After", value = "1" },
      { custom = "content-type", canonical = "Content-Type", value = "text/plain" },
      { custom = "Content-TYPE", canonical = "Content-Type", value = "text/plain" },
    }) do
      it("replaces the default " .. case.canonical .. " with " .. case.custom, function()
        local hdrs = outage_headers({ response_headers = { [case.custom] = case.value } })
        assert.same({ case.canonical }, spellings(hdrs, case.canonical))
        assert.equal(case.value, hdrs[case.canonical])
      end)
    end

    it("replaces a default with a rendered value", function()
      local hdrs = outage_headers({ response_headers = { ["retry-after"] = "{retry_after}0" } })
      assert.same({ "Retry-After" }, spellings(hdrs, "Retry-After"))
      assert.equal(tostring(DEC_01_0600 - DEC_01_0200) .. "0", hdrs["Retry-After"])
    end)

    it("collapses custom names that differ only in case, whatever the insertion order", function()
      -- pairs() order follows a per-process hash seed, so a missing sort only shows
      -- as a wrong winner in some processes: several groups make that near-certain.
      local groups = {
        { "x-trace", "X-Trace", "X-TRACE", "x-TRACE" }, { "x-span", "X-Span", "X-SPAN", "x-SPAN" },
        { "x-tenant", "X-Tenant", "X-TENANT", "x-TENANT" }, { "x-zone", "X-Zone", "X-ZONE", "x-ZONE" },
      }
      local names = {}
      for _, group in ipairs(groups) do
        for _, name in ipairs(group) do
          names[#names + 1] = name
        end
      end

      for shift = 0, #names - 1 do
        local custom = {}
        for i = 1, #names do
          local name = names[(i + shift - 1) % #names + 1]
          custom[name] = name
        end
        local hdrs = outage_headers({ response_headers = custom })
        for _, group in ipairs(groups) do
          -- Sorted byte-wise, the all lower-case spelling comes last and wins.
          assert.same({ group[1] }, spellings(hdrs, group[1]), "insertion shift " .. shift)
          assert.equal(group[1], hdrs[group[1]])
        end
      end
    end)

    it("strips control characters from static values", function()
      local hdrs = outage_headers({ response_headers = { ["X-Static"] = "a\r\nInjected: yes\0b\tc" } })
      assert.equal("aInjected: yesbc", hdrs["X-Static"])
    end)

    it("renders dynamic values, then strips control characters", function()
      local hdrs = outage_headers({
        message = "one\r\ntwo",
        response_headers = { ["X-Dynamic"] = "{message}\t{status}" },
      })
      assert.equal("onetwo503", hdrs["X-Dynamic"])
    end)

    it("omits Retry-After when retry_after is false", function()
      assert.same({}, spellings(outage_headers({ retry_after = false }), "Retry-After"))
    end)

    it("lets custom headers override defaults when retry_after is false", function()
      local hdrs = outage_headers({
        retry_after = false,
        response_headers = { ["cache-control"] = "no-cache", ["retry-after"] = "30" },
      })
      assert.equal("no-cache", hdrs["Cache-Control"])
      assert.equal("30", hdrs["Retry-After"])
      assert.same({ "Cache-Control" }, spellings(hdrs, "Cache-Control"))
    end)

    it("builds a new table for every response", function()
      local conf = new_conf({ W }, { response_headers = { ["X-Static"] = "1", ["X-Dynamic"] = "{status}" } })
      s.now = DEC_01_0200
      local first = request(conf).headers
      first["Cache-Control"], first["X-Static"], first["X-Added"] = "tampered", "tampered", "1"

      s.exits = {}
      local second = request(conf).headers
      assert.is_false(first == second)
      assert.same({
        ["Cache-Control"] = "no-store", ["Retry-After"] = tostring(DEC_01_0600 - DEC_01_0200),
        ["Content-Type"] = "application/problem+json", ["X-Static"] = "1", ["X-Dynamic"] = "503",
      }, second)
    end)
  end)

  describe("header_filter", function()
    local ANNOUNCEMENT = 'start="2026-12-01T02:00:00Z", end="2026-12-01T06:00:00Z"'

    it("never touches kong.ctx.plugin when announce is false", function()
      kong.ctx = setmetatable({}, { __index = function() error("kong.ctx.plugin was read") end })
      local conf = new_conf({ window("2026-12-01T02:00:00Z", "2026-12-01T06:00:00Z") }, { announce = false })

      s.now = DEC_01_0200 - 1
      assert.has_no.errors(function()
        s.handler:access(conf)
        s.handler:header_filter(conf)
      end)
      assert.same({}, s.headers)
    end)

    it("sets the configured header when there is an announcement", function()
      kong.ctx.plugin = { announcement = ANNOUNCEMENT }
      s.handler:header_filter(new_conf({}, { announce_header = "X-Maintenance" }))
      assert.same({ ["X-Maintenance"] = ANNOUNCEMENT }, s.headers)
    end)

    it("sets nothing when there is no announcement", function()
      kong.ctx.plugin = {}
      s.handler:header_filter(new_conf({}))
      assert.same({}, s.headers)
    end)
  end)
end)
