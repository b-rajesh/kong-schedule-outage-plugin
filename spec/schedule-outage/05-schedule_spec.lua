-- SPDX-License-Identifier: Apache-2.0
-- Unit tests for the compiled schedule: its cache, `configure`, and the lookup
-- of the active or next window. Kong is not started; see handler_stubs.lua.

local stubs = require "spec.schedule-outage.handler_stubs"

local new_conf, window = stubs.new_conf, stubs.window
local DEC_01_0200 = stubs.DEC_01_0200

local function iso(epoch)
  return os.date("!%Y-%m-%dT%H:%M:%SZ", epoch)
end

describe(stubs.PLUGIN_NAME .. ": (handler)", function()
  local s = stubs.new()
  local request = s.request

  before_each(s.setup)
  after_each(s.teardown)

  describe("schedule cache", function()
    -- One invalid window, so every compilation logs exactly one error.
    local function mixed_conf(overrides)
      return new_conf({ window("2026-02-30T00:00:00Z", "2026-12-31T00:00:00Z"),
                        window("2026-12-01T02:00:00Z", "2026-12-01T06:00:00Z") }, overrides)
    end

    local function shallow_copy(t)
      local copy = {}
      for k, v in pairs(t) do
        copy[k] = v
      end
      return copy
    end

    it("compiles each configuration once, without writing to it", function()
      local conf = mixed_conf()
      local before = shallow_copy(conf)
      s.now = DEC_01_0200 - 1
      request(conf)
      request(conf)
      assert.equal(1, #s.errors)
      assert.is_nil(conf.__schedule_outage)
      assert.same(before, conf)
    end)

    for _, case in ipairs({ { "without a plugin id", {} }, { "with a plugin id", { __plugin_id = "p1" } } }) do
      local name, overrides = case[1], case[2]
      it("compiles the same configuration table once " .. name, function()
        local conf = mixed_conf(overrides)
        s.now = DEC_01_0200 - 1
        for _ = 1, 3 do
          request(conf)
        end
        assert.equal(1, #s.errors)
      end)

      it("compiles a new configuration table again " .. name, function()
        s.now = DEC_01_0200 - 1
        request(mixed_conf(overrides))
        request(mixed_conf(overrides))
        assert.equal(2, #s.errors)
      end)
    end

    for _, kind in ipairs({ "a number", "ngx.null" }) do
      it("never shares a cache key between configs whose plugin id is " .. kind, function()
        local id = kind == "ngx.null" and ngx.null or 42
        local a, b = mixed_conf({ __plugin_id = id }), mixed_conf({ __plugin_id = id })
        s.handler:configure({ a, b })
        s.now = DEC_01_0200 - 1
        for _ = 1, 2 do
          request(a)
          request(b)
        end
        assert.equal(2, #s.errors)
      end)
    end

    it("keeps one schedule per plugin instance", function()
      local a = mixed_conf({ __plugin_id = "a" })
      local b = new_conf({ window("2026-12-01T10:00:00Z", "2026-12-01T12:00:00Z") }, { __plugin_id = "b" })
      s.now = DEC_01_0200
      for _ = 1, 2 do
        s.exits = {}
        assert.equal(503, request(a).status)
        s.exits = {}
        assert.is_nil(request(b))
      end
      assert.equal(1, #s.errors)
    end)

    it("still enforces windows when the config is read-only", function()
      local readonly = setmetatable({}, {
        __index = mixed_conf(),
        __newindex = function() error("read-only config") end,
      })
      s.now = DEC_01_0200
      assert.equal(503, request(readonly).status)
      s.exits = {}
      assert.equal(503, request(readonly).status)
      assert.equal(1, #s.errors)
    end)
  end)

  describe("configure", function()
    local function invalid_conf(overrides)
      return new_conf({ window("2026-12-01T06:00:00Z", "2026-12-01T02:00:00Z"),
                        window("2026-12-01T02:00:00Z", "2026-12-01T06:00:00Z") }, overrides)
    end

    it("compiles up front, so invalid windows are logged before any request", function()
      local conf = invalid_conf({ __plugin_id = "p1" })
      s.handler:configure({ conf })
      assert.equal(1, #s.errors)
      assert.matches("start_time must be before end_time", s.errors[1])

      s.now = DEC_01_0200
      for _ = 1, 3 do
        s.exits = {}
        assert.equal(503, request(conf).status)
      end
      assert.equal(1, #s.errors)
    end)

    it("names the plugin instance in what it logs", function()
      s.handler:configure({ invalid_conf({ __plugin_id = "p1" }) })
      assert.equal("ignoring window #1: start_time must be before end_time (plugin p1)", s.errors[1])
    end)

    it("compiles every listed configuration", function()
      local a, b = invalid_conf({ __plugin_id = "a" }), invalid_conf()
      s.handler:configure({ a, b })
      assert.equal(2, #s.errors)

      s.now = DEC_01_0200
      request(a)
      s.exits = {}
      request(b)
      assert.equal(2, #s.errors)
    end)

    it("logs the critical message at configure time when every window is invalid", function()
      s.handler:configure({ new_conf({ window("2026-02-30T00:00:00Z", "2026-12-31T00:00:00Z"),
                                     window("2026-12-01T06:00:00Z", "2026-12-01T02:00:00Z") }) })
      assert.equal(2, #s.errors)
      assert.equal(1, #s.crits)
      assert.matches("all 2 configured windows are invalid", s.crits[1], 1, true)
    end)

    it("does not write to the configurations", function()
      local conf = invalid_conf({ __plugin_id = "p1" })
      local before = {}
      for k, v in pairs(conf) do
        before[k] = v
      end
      s.handler:configure({ conf })
      assert.same(before, conf)
    end)

    it("is harmless without configurations", function()
      assert.has_no.errors(function() s.handler:configure(nil) end)
      assert.has_no.errors(function() s.handler:configure({}) end)
      assert.equal(0, #s.errors + #s.crits)
    end)

    it("drops the schedules of configurations it no longer lists", function()
      local conf = invalid_conf({ __plugin_id = "p1" })
      s.handler:configure({ conf })
      s.now = DEC_01_0200
      request(conf)
      assert.equal(1, #s.errors)

      s.handler:configure({})
      s.exits = {}
      assert.equal(503, request(conf).status)
      assert.equal(2, #s.errors)
    end)

    it("replaces the schedule of a plugin that comes with a new table", function()
      s.handler:configure({ invalid_conf({ __plugin_id = "p1" }) })
      local replaced = invalid_conf({ __plugin_id = "p1" })
      s.handler:configure({ replaced })
      assert.equal(2, #s.errors)

      s.now = DEC_01_0200
      assert.equal(503, request(replaced).status)
      assert.equal(2, #s.errors)
    end)

    it("is optional: requests compile lazily when it never ran", function()
      s.now = DEC_01_0200
      assert.equal(503, request(invalid_conf()).status)
      assert.equal(1, #s.errors)
    end)
  end)

  describe("window lookup", function()
    local BASE, HOUR = DEC_01_0200, 3600

    -- Brute-force expectation for raw (unsorted, possibly overlapping) spans
    -- of epoch seconds at time `t`: nil when nothing is active or upcoming,
    -- else the merged window that is active, or the next one to start.
    local function expected(spans, t)
      local function merged(lo, hi)
        local grown = true
        while grown do
          grown = false
          for _, s in ipairs(spans) do
            if s.start <= hi and s.stop >= lo and (s.start < lo or s.stop > hi) then
              lo, hi, grown = math.min(lo, s.start), math.max(hi, s.stop), true
            end
          end
        end
        return lo, hi
      end

      local next_span
      for _, s in ipairs(spans) do
        if s.start <= t and t < s.stop then
          local lo, hi = merged(s.start, s.stop)
          return { active = true, from = lo, to = hi }
        elseif s.start > t and (not next_span or s.start < next_span.start) then
          next_span = s
        end
      end
      if next_span then
        local lo, hi = merged(next_span.start, next_span.stop)
        return { active = false, from = lo, to = hi }
      end
    end

    -- Times around every boundary and every start's announcement threshold,
    -- between boundaries, and outside the schedule.
    local function probes(spans, lead)
      local bounds, seen, times = {}, {}, {}
      local function add(t)
        if not seen[t] then
          seen[t], times[#times + 1] = true, t
        end
      end
      for _, s in ipairs(spans) do
        bounds[#bounds + 1] = s.start
        bounds[#bounds + 1] = s.stop
        for d = -1, 1 do
          add(s.start - lead + d)
        end
      end
      table.sort(bounds)
      add(BASE - HOUR)
      add((bounds[#bounds] or BASE) + HOUR)
      for i, b in ipairs(bounds) do
        add(b - 1)
        add(b)
        add(b + 1)
        add(bounds[i + 1] and math.floor((b + bounds[i + 1]) / 2) or b)
      end
      return times
    end

    -- 100 windows in scrambled order: every 5th overlaps the next one, every
    -- 7th touches it, the rest are apart.
    local function scrambled(count)
      local seed = 12345
      local function rand(n)
        seed = seed * 16807 % 2147483647
        return seed % n
      end
      local spans = {}
      for i = 1, count do
        local start = BASE + (i - 1) * HOUR + rand(600)
        spans[i] = { start = start, stop = start + 600 + rand(2000) }
      end
      for i = 1, count - 1 do
        if i % 5 == 0 then
          spans[i].stop = spans[i + 1].start + 300
        elseif i % 7 == 0 then
          spans[i].stop = spans[i + 1].start
        end
      end
      for i = count, 2, -1 do
        local j = 1 + rand(i)
        spans[i], spans[j] = spans[j], spans[i]
      end
      return spans
    end

    local function span(from, to)
      return { start = BASE + from, stop = BASE + to }
    end

    local configs = {
      { "no windows", {} },
      { "one window", { span(0, HOUR) } },
      { "two windows apart", { span(HOUR, 2 * HOUR), span(4 * HOUR, 5 * HOUR) } },
      { "two windows given latest first", { span(4 * HOUR, 5 * HOUR), span(HOUR, 2 * HOUR) } },
      { "two overlapping windows", { span(0, 2 * HOUR), span(HOUR, 3 * HOUR) } },
      { "two touching windows", { span(0, HOUR), span(HOUR, 2 * HOUR) } },
      { "one window inside another", { span(0, 4 * HOUR), span(HOUR, 2 * HOUR), span(5 * HOUR, 6 * HOUR) } },
      { "100 windows, some merging", scrambled(100) },
    }

    for _, case in ipairs(configs) do
      local name, spans = case[1], case[2]
      for _, lead in ipairs({ 0, 900 }) do
        it("matches a brute-force scan: " .. name .. ", lead time " .. lead, function()
          local windows = {}
          for i, s in ipairs(spans) do
            windows[i] = window(iso(s.start), iso(s.stop))
          end
          local conf = new_conf(windows, { announce_lead_time = lead })

          for _, t in ipairs(probes(spans, lead)) do
            s.now = t
            s.exits, s.headers = {}, {}
            local exit, hdrs = request(conf)
            local want, where = expected(spans, t), "at " .. iso(t)
            if want and want.active then
              assert.is_table(exit, where)
              assert.equal(503, exit.status, where)
              assert.equal(tostring(want.to - t), exit.headers["Retry-After"], where)
              assert.equal(iso(want.from), exit.body.outage_start, where)
              assert.equal(iso(want.to), exit.body.outage_end, where)
            else
              assert.is_nil(exit, where)
              local announced = want and (lead == 0 or want.from - t <= lead)
              assert.equal(announced and ('start="%s", end="%s"'):format(iso(want.from), iso(want.to)) or nil,
                           hdrs["Planned-Outage"], where)
            end
          end
        end)
      end
    end
  end)

  -- Kong's streamed-plugin sandbox has no setmetatable, require, io, os and so
  -- on. These run the plugin in an environment without them that raises on any
  -- other global, so a use at load time or on any request fails here.
  describe("sandbox", function()
    local W = window("2026-12-01T02:00:00Z", "2026-12-01T06:00:00Z")
    local BAD = window("2026-12-01T06:00:00Z", "2026-12-01T02:00:00Z")

    -- Runs one request at `now` and returns the exit and the headers set on it.
    local function visit(conf, now)
      s.now, s.exits, s.headers = now, {}, {}
      return request(conf)
    end

    it("raises on every global the sandbox lacks", function()
      for _, name in ipairs({ "setmetatable", "getmetatable", "rawget", "rawset", "rawequal", "load",
                              "loadstring", "dofile", "require", "io", "os", "collectgarbage", "print" }) do
        local ok, err = pcall(setfenv(loadstring("return " .. name), stubs.sandbox_env()))
        assert.is_false(ok, name)
        assert.matches("global '" .. name .. "' is not available", err, 1, true)
      end
    end)

    it("runs configure, access and header_filter on the allowed globals only", function()
      s.handler = stubs.load_sandboxed(stubs.HANDLER, { ngx = { time = function() return s.now end }, kong = kong })
      local plain, silent = new_conf({ W }), new_conf({ W }, { announce = false })
      local lazy = new_conf({ W })
      local template = new_conf({ W }, {
        message = 'Back "soon"',
        response_body = '{"m":"{message}","id":"{request_id}"}',
        response_headers = { ["X-Static"] = "1", ["X-Dynamic"] = "{retry_after}", ["cache-control"] = "no-cache" },
      })
      local partly = new_conf({ BAD, W }, { __plugin_id = "p1" })
      local invalid = new_conf({ BAD }, { __plugin_id = "p2" })

      s.handler:configure({ plain, silent, template, partly, invalid })
      assert.equal(2, #s.errors)
      assert.equal(1, #s.crits)

      local exit, hdrs = visit(plain, DEC_01_0200 - 1)
      assert.is_nil(exit)
      assert.equal('start="2026-12-01T02:00:00Z", end="2026-12-01T06:00:00Z"', hdrs["Planned-Outage"])
      assert.same({}, select(2, visit(silent, DEC_01_0200 - 1)))

      assert.equal("about:blank", visit(plain, DEC_01_0200).body.type)
      exit = visit(template, DEC_01_0200)
      assert.equal('{"m":"Back \\"soon\\"","id":"a1b2c3d4"}', exit.body)
      assert.same({ ["X-Static"] = "1", ["X-Dynamic"] = "14400", ["Cache-Control"] = "no-cache",
                    ["Retry-After"] = "14400", ["Content-Type"] = "application/json" }, exit.headers)

      assert.equal(503, visit(partly, DEC_01_0200).status)
      assert.is_nil((visit(invalid, DEC_01_0200)))
      assert.equal(503, visit(lazy, DEC_01_0200).status) -- never listed in configure
      assert.equal(2, #s.errors)
    end)

    it("loads the schema without ngx", function()
      local schema = stubs.load_sandboxed(stubs.SCHEMA, nil, { ngx = true })
      assert.equal(stubs.PLUGIN_NAME, schema.name)
    end)
  end)
end)
