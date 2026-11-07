-- SPDX-License-Identifier: Apache-2.0
-- schedule-outage: rejects traffic during scheduled maintenance windows and
-- announces upcoming windows on normal responses.
--
-- Kept in a single self-contained module (PDK only, no custom requires, no
-- timers, no init_worker) so it can be streamed by Konnect to Dedicated Cloud
-- Gateways as well as installed on self-managed hybrid data planes.

local floor = math.floor
local sort = table.sort
local format = string.format
local lower = string.lower
local time = ngx.time

local ScheduleOutageHandler = {
  -- Above jwt (1450), oauth2 (1400), key-auth (1250), ldap-auth (1200), basic-auth
  -- (1100), openid-connect (1050), hmac-auth (1030) and the rate limiters (below
  -- 1000), so those callers get 503 rather than 401/429. mtls-auth (1600),
  -- oauth2-introspection (1700), session (1900), jwe-decrypt (1999), cors (2000)
  -- and bot-detection (2500) still run first; being below cors matters because it
  -- answers preflight (OPTIONS) requests itself rather than have them rejected.
  -- CORS headers reach the 503 at any priority: header_filter runs for every
  -- collected plugin.
  PRIORITY = 1500,
  VERSION = "1.0.0",
}

local RFC3339_UTC = "^(%d%d%d%d)%-(%d%d)%-(%d%d)T(%d%d):(%d%d):(%d%d)Z$"

local DAYS_IN_MONTH = { 31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31 }

-- IANA reason phrases (RFC 9110 and later) for the allowed 400 to 599 range.
-- Unassigned or unused codes, such as 418, get no title: RFC 9457 makes the
-- member optional.
local STATUS_TITLES = {
  [400] = "Bad Request", [401] = "Unauthorized", [402] = "Payment Required",
  [403] = "Forbidden", [404] = "Not Found", [405] = "Method Not Allowed",
  [406] = "Not Acceptable", [407] = "Proxy Authentication Required", [408] = "Request Timeout",
  [409] = "Conflict", [410] = "Gone", [411] = "Length Required", [412] = "Precondition Failed",
  [413] = "Content Too Large", [414] = "URI Too Long", [415] = "Unsupported Media Type",
  [416] = "Range Not Satisfiable", [417] = "Expectation Failed", [421] = "Misdirected Request",
  [422] = "Unprocessable Content", [423] = "Locked", [424] = "Failed Dependency",
  [425] = "Too Early", [426] = "Upgrade Required", [428] = "Precondition Required",
  [429] = "Too Many Requests", [431] = "Request Header Fields Too Large",
  [451] = "Unavailable For Legal Reasons", [500] = "Internal Server Error",
  [501] = "Not Implemented", [502] = "Bad Gateway", [503] = "Service Unavailable",
  [504] = "Gateway Timeout", [505] = "HTTP Version Not Supported",
  [506] = "Variant Also Negotiates", [507] = "Insufficient Storage", [508] = "Loop Detected",
  [510] = "Not Extended", [511] = "Network Authentication Required",
}

local function is_leap(y)
  return y % 4 == 0 and (y % 100 ~= 0 or y % 400 == 0)
end

-- Days since 1970-01-01 for a proleptic Gregorian date (H. Hinnant's
-- days_from_civil). Pure arithmetic: independent of the node's timezone.
local function days_from_civil(y, m, d)
  if m <= 2 then
    y = y - 1
  end
  local era = floor(y / 400)
  local yoe = y - era * 400
  local doy = floor((153 * ((m + 9) % 12) + 2) / 5) + d - 1
  local doe = yoe * 365 + floor(yoe / 4) - floor(yoe / 100) + doy
  return era * 146097 + doe - 719468
end

--- Converts an RFC 3339 UTC string (`2026-12-01T02:00:00Z`) to epoch seconds.
-- @treturn number|nil epoch seconds, or nil and an error message
local function to_epoch(value)
  local y, mo, d, h, mi, s = value:match(RFC3339_UTC)
  if not y then
    return nil, "not an RFC 3339 UTC timestamp"
  end
  y, mo, d, h, mi, s = tonumber(y), tonumber(mo), tonumber(d), tonumber(h), tonumber(mi), tonumber(s)

  local max_day = (mo == 2 and is_leap(y)) and 29 or DAYS_IN_MONTH[mo]
  if not max_day or d < 1 or d > max_day or h > 23 or mi > 59 or s > 59 then
    return nil, "date or time out of range"
  end

  return days_from_civil(y, mo, d) * 86400 + h * 3600 + mi * 60 + s
end

-- Returns an optional config value only when it has the expected type, so an
-- unset field is never mistaken for a value even if it arrives as ngx.null.
local function optional(value, kind)
  if type(value) == kind then
    return value
  end
end

-- Kong gives every plugin instance a string id. Anything else (ngx.null, a number)
-- is no id: it must neither name an instance in a log message nor share a cache key.
local function plugin_id(conf)
  return optional(conf.__plugin_id, "string")
end

-- Parses, validates, sorts and merges the configured windows into disjoint
-- intervals, each with its announcement header value prebuilt. Invalid
-- windows are logged and ignored (fail open: a bad schedule must never cause
-- an outage of its own); if none is valid, that is logged as critical because
-- no outage will be enforced at all. `configure` logs outside any request, so
-- the messages end with the plugin id, to say which instance has the problem.
local function build_windows(conf)
  local id = plugin_id(conf)
  local where = id and " (plugin " .. id .. ")" or ""
  local parsed = {}
  for i, w in ipairs(conf.windows) do
    local start, err = to_epoch(w.start_time)
    local stop, err2 = to_epoch(w.end_time)
    if not start or not stop then
      kong.log.err("ignoring window #", i, ": ", err or err2, where)
    elseif start >= stop then
      kong.log.err("ignoring window #", i, ": start_time must be before end_time", where)
    else
      parsed[#parsed + 1] = { start = start, stop = stop, start_time = w.start_time, end_time = w.end_time }
    end
  end

  if #parsed == 0 then
    kong.log.crit("all ", #conf.windows, " configured windows are invalid: no outage will be enforced", where)
  end

  sort(parsed, function(a, b) return a.start < b.start end)

  local merged = {}
  for _, w in ipairs(parsed) do
    local last = merged[#merged]
    if last and w.start <= last.stop then
      if w.stop > last.stop then
        last.stop, last.end_time = w.stop, w.end_time
      end
    else
      merged[#merged + 1] = w
    end
  end

  for _, w in ipairs(merged) do
    w.announcement = 'start="' .. w.start_time .. '", end="' .. w.end_time .. '"'
  end
  return merged
end

-- Canonical spelling of the default headers, by lower-cased name.
local DEFAULT_HEADERS = {
  ["cache-control"] = "Cache-Control",
  ["retry-after"] = "Retry-After",
  ["content-type"] = "Content-Type",
}

-- Builds the final outage headers: the defaults overlaid by `response_headers`.
-- Names are case-insensitive and kong.response.exit applies headers in pairs()
-- order, which varies between starts and Kong versions, so a name must never
-- appear in two spellings. A custom name matching a default replaces it, under
-- the default's canonical spelling. Custom names that differ only in case
-- collapse into one: sorted byte-wise, the last wins, the same in every worker.
--
-- An entry is { name, value } when static (stripped of control characters, which
-- header values cannot carry, once here), { name, template } when rendered on
-- every request, or { name } for the default Retry-After. The defaults keep
-- slots 1-3 (slot 2 is false without Retry-After) so that reject() sets them
-- without a loop. A plain loop over every entry measured 1.4x slower on the
-- default 503 (median of 15 runs each on Kong 3.14.0.13 and 3.16.0.0; the
-- template 503 and the other paths stayed within 3%): LuaJIT often compiles it
-- as a trace of its own, and the `values` table is then allocated every time.
local function build_headers(conf, content_type)
  local list = {
    { name = "Cache-Control", value = "no-store" },
    conf.retry_after and { name = "Retry-After" } or false,
    { name = "Content-Type", value = content_type },
  }
  local slot = { ["cache-control"] = 1, ["retry-after"] = 2, ["content-type"] = 3 }

  local custom = optional(conf.response_headers, "table") or {}
  local names = {}
  for name, value in pairs(custom) do
    if type(value) == "string" then
      names[#names + 1] = name
    end
  end
  sort(names)

  for _, name in ipairs(names) do
    local value = custom[name]
    local key = lower(name)
    local entry = { name = DEFAULT_HEADERS[key] or name }
    if value:find("{", 1, true) then
      entry.template = value
    else
      entry.value = (value:gsub("%c", ""))
    end
    local i = slot[key] or #list + 1
    slot[key] = i
    list[i] = entry
  end
  return list
end

-- Compiles what a configuration implies for every request: the merged windows,
-- the outage headers, and whether template values are JSON-escaped (case-blind).
local function build_schedule(conf)
  local template = optional(conf.response_body, "string")
  local content_type = optional(conf.response_content_type, "string")
    or (template and "application/json" or "application/problem+json")
  return {
    windows = build_windows(conf),
    headers = build_headers(conf, content_type),
    json = lower(content_type):find("json", 1, true) ~= nil,
  }
end

-- Compiled schedules by plugin instance, kept off the config tables: Kong walks
-- those on every request (to resolve vault references). An entry is valid only
-- for the table it was compiled from: Kong builds new ones on every change.
local cache = {}

local function get_schedule(conf)
  local key = plugin_id(conf) or conf
  local entry = cache[key]
  if not entry or entry.conf ~= conf then
    entry = { conf = conf, schedule = build_schedule(conf) }
    cache[key] = entry
  end
  return entry.schedule
end

-- Kong calls this in every worker when the configuration is applied and on each
-- change, with all this plugin's config tables (nil if none). Compiling here logs
-- invalid windows at deployment; a fresh cache drops removed or replaced plugins.
function ScheduleOutageHandler:configure(configs)
  local fresh = {}
  for _, conf in ipairs(configs or {}) do
    fresh[plugin_id(conf) or conf] = { conf = conf, schedule = build_schedule(conf) }
  end
  cache = fresh
end

local JSON_ESCAPES = {
  ['"'] = '\\"', ["\\"] = "\\\\", ["\b"] = "\\b", ["\f"] = "\\f",
  ["\n"] = "\\n", ["\r"] = "\\r", ["\t"] = "\\t",
}

local function json_escape_char(c)
  return JSON_ESCAPES[c] or format("\\u%04x", c:byte())
end

-- Escapes a value for use inside a JSON string literal.
local function json_escape(value)
  return (value:gsub('[%c"\\]', json_escape_char))
end

-- The replacement function is created once instead of per render() call: the
-- JIT does not compile a function that creates a closure, so template responses
-- would run interpreted. Its inputs travel in these locals; render never yields.
local render_values, render_escape

local function replace_placeholder(name)
  local value = render_values[name]
  if value == nil then
    return nil
  end
  if type(value) == "number" then
    return tostring(value) -- digits only: nothing to escape
  end
  return render_escape and json_escape(value) or value
end

--- Replaces `{name}` placeholders with `values[name]`. Unknown placeholders
-- are left as they are. With `escape`, values are JSON-string escaped.
local function render(template, values, escape)
  render_values, render_escape = values, escape
  return (template:gsub("{([%w_]+)}", replace_placeholder))
end

-- Adds a compiled header entry to `headers`; false (no Retry-After) is skipped.
local function set_header(headers, entry, values, retry_after)
  if not entry then
    return
  end
  local value = entry.value
  if not value then
    local template = entry.template
    -- Rendered values may carry control characters (e.g. from `message`).
    value = template and (render(template, values):gsub("%c", "")) or tostring(retry_after)
  end
  headers[entry.name] = value
end

-- Responds for the active window: an RFC 9457 problem document by default,
-- or the configured `response_body` template.
local function reject(conf, schedule, window, now)
  local status = conf.status_code
  local retry_after = window.stop - now
  local message = optional(conf.message, "string")
  local template = optional(conf.response_body, "string")
  local values = {
    status = status,
    message = message or "",
    start_time = window.start_time,
    end_time = window.end_time,
    retry_after = retry_after,
    request_id = kong.request.get_id(),
  }

  local body
  if template then
    body = render(template, values, schedule.json)
  else
    body = {
      type = "about:blank",
      title = STATUS_TITLES[status],
      status = status,
      detail = message,
      outage_start = window.start_time,
      outage_end = window.end_time,
    }
  end

  -- A new table for every response: kong.response.exit keeps the one it gets.
  local headers = {}
  local entries = schedule.headers
  set_header(headers, entries[1], values, retry_after)
  set_header(headers, entries[2], values, retry_after)
  set_header(headers, entries[3], values, retry_after)
  for i = 4, #entries do
    set_header(headers, entries[i], values, retry_after)
  end

  return kong.response.exit(status, body, headers)
end

function ScheduleOutageHandler:access(conf)
  local now = time()
  local schedule = get_schedule(conf)
  local windows = schedule.windows

  -- Merged windows are disjoint and sorted, so the first one that has not
  -- ended yet is found by bisection rather than by a scan past every old window.
  local lo, hi = 1, #windows + 1
  while lo < hi do
    local mid = floor((lo + hi) / 2)
    if now < windows[mid].stop then
      hi = mid
    else
      lo = mid + 1
    end
  end

  local window = windows[lo]
  if not window then
    return
  end

  if now < window.start then
    local lead = conf.announce_lead_time
    if conf.announce and (lead == 0 or window.start - now <= lead) then
      kong.ctx.plugin.announcement = window.announcement
    end
    return
  end

  return reject(conf, schedule, window, now)
end

-- Set in header_filter so the announcement wins over any upstream header of
-- the same name.
function ScheduleOutageHandler:header_filter(conf)
  -- Nothing is stored with announcements off, and reading kong.ctx.plugin allocates its table.
  if not conf.announce then
    return
  end

  local announcement = kong.ctx.plugin.announcement
  if announcement then
    kong.response.set_header(conf.announce_header, announcement)
  end
end

return ScheduleOutageHandler
