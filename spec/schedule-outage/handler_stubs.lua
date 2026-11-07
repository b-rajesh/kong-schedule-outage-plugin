-- SPDX-License-Identifier: Apache-2.0
-- Shared by the handler unit specs. Kong is not started: the `kong` PDK and
-- `ngx.time` are replaced with stubs so the clock can be set per test. Not a
-- spec itself: the name does not end in _spec, so busted does not run it.
--
-- Inside a describe block:
--   local s = stubs.new()
--   before_each(s.setup)
--   after_each(s.teardown)
-- A test sets `s.now`, runs `s.request(conf)`, and reads what the handler did
-- from `s.exits` (kong.response.exit calls), `s.headers` (kong.response.set_header
-- calls), `s.errors` and `s.crits` (kong.log messages); `s.handler` is the
-- handler under test.

local M = {}

M.PLUGIN_NAME = "schedule-outage"
local MODULE = "kong.plugins." .. M.PLUGIN_NAME .. ".handler"
M.HANDLER = MODULE
M.SCHEMA = "kong.plugins." .. M.PLUGIN_NAME .. ".schema"

-- Reference values computed with `date -u`.
M.DEC_01_0200 = 1796090400   -- 2026-12-01T02:00:00Z
M.DEC_01_0600 = 1796104800   -- 2026-12-01T06:00:00Z

--- Loads a fresh copy of the handler, which captures `ngx.time` as it loads.
function M.load_handler()
  package.loaded[MODULE] = nil
  return require(MODULE)
end

-- The globals Kong's streamed-plugin sandbox provides besides the PDK. Anything
-- else (setmetatable, getmetatable, rawget, rawset, rawequal, load, loadstring,
-- dofile, require, io, os, collectgarbage, print) is not there.
local SANDBOX_GLOBALS = {
  "assert", "error", "ipairs", "next", "pairs", "pcall", "select", "tonumber",
  "tostring", "type", "unpack", "xpcall", "math", "string", "table",
}

--- Returns an environment with the sandbox globals plus `extra`. Reading or
-- assigning any other global raises; the names in `nil_ok` read as nil instead,
-- for a global the sandbox lacks and the code guards for (ngx in the schema).
function M.sandbox_env(extra, nil_ok)
  local env = {}
  for _, name in ipairs(SANDBOX_GLOBALS) do
    env[name] = _G[name]
  end
  for name, value in pairs(extra or {}) do
    env[name] = value
  end
  return setmetatable(env, {
    __index = function(_, name)
      if nil_ok and nil_ok[name] then
        return nil
      end
      error("global '" .. tostring(name) .. "' is not available in the sandbox", 2)
    end,
    __newindex = function(_, name)
      error("global '" .. tostring(name) .. "' must not be assigned in the sandbox", 2)
    end,
  })
end

--- Loads a module from its source file inside that environment, so a use of any
-- other global raises, whether as it loads or whenever its functions run.
function M.load_sandboxed(modname, extra, nil_ok)
  local chunk = assert(loadfile(assert(package.searchpath(modname, package.path))))
  setfenv(chunk, M.sandbox_env(extra, nil_ok))
  return chunk()
end

function M.new_conf(windows, overrides)
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

function M.window(start_time, end_time)
  return { start_time = start_time, end_time = end_time }
end

--- Creates the state of one describe block: the clock, the records, the stubs.
function M.new()
  local s = {}
  local real_ngx_time, real_kong

  function s.setup()
    s.exits, s.headers, s.errors, s.crits = {}, {}, {}, {}

    _G.ngx = _G.ngx or {}
    real_ngx_time = ngx.time
    ngx.time = function() return s.now end

    real_kong = _G.kong
    _G.kong = {
      ctx = { plugin = {} },
      log = {
        err = function(...) s.errors[#s.errors + 1] = table.concat({ ... }) end,
        crit = function(...) s.crits[#s.crits + 1] = table.concat({ ... }) end,
      },
      request = { get_id = function() return "a1b2c3d4" end },
      response = {
        exit = function(status, body, hdrs)
          s.exits[#s.exits + 1] = { status = status, body = body, headers = hdrs }
          return true
        end,
        set_header = function(name, value) s.headers[name] = value end,
      },
    }

    s.handler = M.load_handler()
  end

  function s.teardown()
    ngx.time = real_ngx_time
    _G.kong = real_kong
    package.loaded[MODULE] = nil
  end

  --- Runs both phases for one request and returns the outcome.
  function s.request(conf)
    kong.ctx.plugin = {}
    s.handler:access(conf)
    if #s.exits == 0 then
      s.handler:header_filter(conf)
    end
    return s.exits[1], s.headers
  end

  return s
end

return M
