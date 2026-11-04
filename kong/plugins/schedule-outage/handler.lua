-- schedule-outage: rejects traffic during scheduled maintenance windows and
-- announces upcoming windows on normal responses.
--
-- Kept in a single self-contained module (PDK only, no custom requires, no
-- timers, no init_worker) so it can be streamed by Konnect to Dedicated Cloud
-- Gateways as well as installed on self-managed hybrid data planes.

local floor = math.floor
local sort = table.sort
local format = string.format
local time = ngx.time

local ScheduleOutageHandler = {
  -- Above authentication (jwt 1450, key-auth 1250, ...) and rate limiting, so
  -- callers get 503 rather than 401/429 during an outage; below cors (2000),
  -- so outage responses still carry CORS headers.
  PRIORITY = 1500,
  VERSION = "1.0.0",
}

local RFC3339_UTC = "^(%d%d%d%d)%-(%d%d)%-(%d%d)T(%d%d):(%d%d):(%d%d)Z$"

local DAYS_IN_MONTH = { 31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31 }

local STATUS_TITLES = {
  [403] = "Forbidden",
  [404] = "Not Found",
  [410] = "Gone",
  [423] = "Locked",
  [429] = "Too Many Requests",
  [500] = "Internal Server Error",
  [502] = "Bad Gateway",
  [503] = "Service Unavailable",
  [504] = "Gateway Timeout",
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

-- Parses, validates, sorts and merges the configured windows into disjoint
-- intervals. Invalid windows are logged and ignored (fail open: a bad
-- schedule must never cause an outage of its own).
local function build_schedule(conf)
  local parsed = {}
  for i, w in ipairs(conf.windows) do
    local start, err = to_epoch(w.start_time)
    local stop, err2 = to_epoch(w.end_time)
    if not start or not stop then
      kong.log.err("ignoring window #", i, ": ", err or err2)
    elseif start >= stop then
      kong.log.err("ignoring window #", i, ": start_time must be before end_time")
    else
      parsed[#parsed + 1] = { start = start, stop = stop, start_time = w.start_time, end_time = w.end_time }
    end
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
  return merged
end

-- Plugin config tables are replaced on every configuration change, so a
-- weak-keyed cache parses each schedule once and is collected with it.
-- Kong's strict Lua sandbox, which streamed plugins may run under, does not
-- expose setmetatable. Without it the cache holds strong references and is
-- cleared once it reaches MAX_STRONG_ENTRIES, so old configs cannot pile up.
local MAX_STRONG_ENTRIES = 1024

-- pcall guards against sandboxes that raise on unknown globals.
local _, set_mt = pcall(function() return setmetatable end)
local weak = type(set_mt) == "function"
local schedules = weak and set_mt({}, { __mode = "k" }) or {}
local entries = 0

local function get_schedule(conf)
  local schedule = schedules[conf]
  if schedule then
    return schedule
  end

  if not weak then
    if entries >= MAX_STRONG_ENTRIES then
      schedules, entries = {}, 0
    end
    entries = entries + 1
  end

  schedule = build_schedule(conf)
  schedules[conf] = schedule
  return schedule
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

-- nginx's per-request id; empty when unavailable (e.g. outside a request).
local function request_id()
  local ok, id = pcall(function() return ngx.var.request_id end)
  return ok and type(id) == "string" and id or ""
end

--- Replaces `{name}` placeholders with `values[name]`. Unknown placeholders
-- are left as they are. With `escape`, values are JSON-string escaped.
local function render(template, values, escape)
  return (template:gsub("{([%w_]+)}", function(name)
    local value = values[name]
    if value == nil then
      return nil
    end
    value = tostring(value)
    return escape and json_escape(value) or value
  end))
end

-- Returns an optional config value only when it has the expected type, so an
-- unset field is never mistaken for a value even if it arrives as ngx.null.
local function optional(value, kind)
  if type(value) == kind then
    return value
  end
end

-- Responds for the active window: an RFC 9457 problem document by default,
-- or the configured `response_body` template.
local function reject(conf, window, now)
  local status = conf.status_code
  local retry_after = window.stop - now
  local message = optional(conf.message, "string")
  local template = optional(conf.response_body, "string")
  local content_type = optional(conf.response_content_type, "string")
  local values = {
    status = status,
    message = message or "",
    start_time = window.start_time,
    end_time = window.end_time,
    retry_after = retry_after,
    request_id = request_id(),
  }

  local headers = { ["Cache-Control"] = "no-store" }
  if conf.retry_after then
    headers["Retry-After"] = tostring(retry_after)
  end

  local body
  if template then
    content_type = content_type or "application/json"
    headers["Content-Type"] = content_type
    body = render(template, values, content_type:find("json", 1, true) ~= nil)
  else
    headers["Content-Type"] = content_type or "application/problem+json"
    body = {
      type = "about:blank",
      title = STATUS_TITLES[status],
      status = status,
      detail = message,
      outage_start = window.start_time,
      outage_end = window.end_time,
    }
  end

  -- Custom headers are applied last, so they can override the defaults.
  -- Control characters are removed: they are not allowed in header values.
  for name, value in pairs(optional(conf.response_headers, "table") or {}) do
    if type(value) == "string" then
      headers[name] = (render(value, values):gsub("%c", ""))
    end
  end

  return kong.response.exit(status, body, headers)
end

function ScheduleOutageHandler:access(conf)
  local now = time()

  for _, window in ipairs(get_schedule(conf)) do
    if now < window.start then
      -- Windows are sorted: this is the next upcoming one.
      local lead = conf.announce_lead_time
      if conf.announce and (lead == 0 or window.start - now <= lead) then
        kong.ctx.plugin.announcement =
          'start="' .. window.start_time .. '", end="' .. window.end_time .. '"'
      end
      return
    end

    if now < window.stop then
      return reject(conf, window, now)
    end
  end
end

-- Set in header_filter so the announcement wins over any upstream header of
-- the same name.
function ScheduleOutageHandler:header_filter(conf)
  local announcement = kong.ctx.plugin.announcement
  if announcement then
    kong.response.set_header(conf.announce_header, announcement)
  end
end

return ScheduleOutageHandler
