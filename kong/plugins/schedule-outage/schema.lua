-- SPDX-License-Identifier: Apache-2.0
-- Configuration schema for the schedule-outage plugin.
--
-- Konnect constraints this file deliberately respects:
--   * no `require()` (Konnect uploads this file alone to the control plane,
--     and the sandbox that loads it lets `require` reach only a short list of
--     Kong modules, never the plugin's own; it has no `ngx` global either)
--   * no custom validator functions (streamed plugins / Dedicated Cloud
--     Gateways only honour declarative rules). Lua patterns have no
--     alternation and no case folding, so calendar ranges and deny lists are
--     `match` / `match_none` rules; `deny()` only expands plain name lists
--     into such rules when the file is loaded.
--   * `start_time < end_time` is not checked here: a declarative schema
--     cannot compare two fields, so handler.lua checks it.

-- RFC 3339 date-time, UTC only ("Z"), no fractional seconds. The character
-- classes only cap each field at its highest digits; CALENDAR removes the
-- impossible values they still admit.
local RFC3339_UTC = "^%d%d%d%d%-[01]%d%-[0-3]%dT[0-2]%d:[0-5]%d:[0-5]%dZ$"

-- Dates and times RFC3339_UTC admits but the calendar does not. The handler
-- ignores a window it cannot parse, so without these a typo would silently
-- schedule no outage at all.
local CALENDAR = {
  -- month 00
  { pattern = "^%d%d%d%d%-00", err = "month must be 01-12" },
  -- month 13 to 19
  { pattern = "^%d%d%d%d%-1[3-9]", err = "month must be 01-12" },
  -- day 00
  { pattern = "^%d%d%d%d%-%d%d%-00", err = "day must be 01-31" },
  -- day 32 to 39
  { pattern = "^%d%d%d%d%-%d%d%-3[2-9]", err = "day must be 01-31" },
  -- hour 24 to 29
  { pattern = "^%d%d%d%d%-%d%d%-%d%dT2[4-9]", err = "hour must be 00-23" },
  -- 30 and 31 February
  { pattern = "^%d%d%d%d%-02%-3[01]", err = "February has at most 29 days" },
  -- 31 April, June and September
  { pattern = "^%d%d%d%d%-0[469]%-31", err = "April, June, September and November have 30 days" },
  -- 31 November
  { pattern = "^%d%d%d%d%-11%-31", err = "April, June, September and November have 30 days" },
  -- 29 February, year not divisible by 4: tens digit even, units not 0, 4 or 8
  { pattern = "^%d%d[02468][1235679]%-02%-29", err = "29 February needs a leap year" },
  -- 29 February, year not divisible by 4: tens digit odd, units not 2 or 6
  { pattern = "^%d%d[13579][01345789]%-02%-29", err = "29 February needs a leap year" },
  -- 29 February, century year xx00 with xx not divisible by 4 (1900, 2100, ...): same test on xx, even tens
  { pattern = "^[02468][1235679]00%-02%-29", err = "29 February needs a leap year" },
  -- 29 February, century year xx00 with xx not divisible by 4: same test on xx, odd tens
  { pattern = "^[13579][01345789]00%-02%-29", err = "29 February needs a leap year" },
}

-- RFC 9110 token characters. Header names leave out "_": it is a token
-- character, but the PDK sends it as "-", so the header on the wire would not
-- be the one configured. Media types are sent verbatim and keep it.
local TOKEN_CHARS = "%w!#%$%%&'%*%+%-%.%^`|~"
local HEADER_NAME = "^[" .. TOKEN_CHARS .. "]+$"
local MEDIA_TOKEN = "[" .. TOKEN_CHARS .. "_]+"

-- RFC 9110 media type: "type/subtype", then any parameters. Control
-- characters are excluded so a value cannot split the response header.
local MEDIA_TYPE = "^" .. MEDIA_TOKEN .. "/" .. MEDIA_TOKEN .. "[^%c]*$"

-- Header values go on the wire as they are: no CR, LF, NUL or other control
-- characters. Also rejects the empty string.
local HEADER_VALUE = "^[^%c]+$"

-- Headers that frame the message or manage the connection. Kong and nginx
-- set them, so a custom value corrupts or stalls the response.
local FRAMING_HEADERS = {
  "content-length", "transfer-encoding", "connection", "keep-alive", "upgrade", "te", "trailer",
}

-- Headers whose value belongs to the upstream response. The announcement is
-- added to every proxied response and replaces a header of the same name, so
-- announcing under one of these would overwrite the upstream's.
local PAYLOAD_HEADERS = {
  "content-type", "content-encoding", "cache-control", "set-cookie", "etag",
  "last-modified", "expires", "date", "location",
}

-- Turns lists of lowercase header names into a `match_none` list that rejects
-- each name in any letter case.
local function deny(...)
  local rules = {}
  for _, names in ipairs({ ... }) do
    for _, name in ipairs(names) do
      local pattern = name:gsub("[%a%-]", function(c)
        return c == "-" and "%-" or "[" .. c:upper() .. c:lower() .. "]"
      end)
      rules[#rules + 1] = { pattern = "^" .. pattern .. "$", err = name .. " is not allowed here" }
    end
  end
  return rules
end

local ONE_YEAR = 365 * 24 * 60 * 60

-- `typedefs.no_consumer` without the require. The guard keeps the schema
-- loadable by parsers that do not expose the `ngx` global.
local null = ngx and ngx.null

local window = {
  type = "record",
  fields = {
    { start_time = { type = "string", required = true, match = RFC3339_UTC, match_none = CALENDAR,
                     description = "Outage start, RFC 3339 UTC (e.g. 2026-12-01T02:00:00Z), "
                                   .. "a real calendar date and time. Inclusive." } },
    { end_time   = { type = "string", required = true, match = RFC3339_UTC, match_none = CALENDAR,
                     description = "Outage end, RFC 3339 UTC. Exclusive: traffic resumes at this instant." } },
  },
}

return {
  name = "schedule-outage",
  fields = {
    -- The plugin runs before most authentication plugins (priority 1500), so
    -- the consumer is not known yet: scoping to a consumer or consumer group
    -- would never match.
    { consumer = { type = "foreign", reference = "consumers", eq = null } },
    { consumer_group = { type = "foreign", reference = "consumer_groups", eq = null } },
    -- HTTP only. On gRPC, the JSON outage body would bypass Kong's gRPC
    -- status translation.
    { protocols = { type = "set", required = true, default = { "http", "https" },
                    elements = { type = "string", one_of = { "http", "https" } } } },
    -- Every limit below is in bytes. They bound what one request renders: a
    -- body template can repeat {message}, so without them a small config could
    -- expand into a response of hundreds of MB and exhaust worker memory.
    { config = {
        type = "record",
        fields = {
          { windows = { type = "array", required = true, len_min = 1, len_max = 100,
                        elements = window,
                        description = "Scheduled outage windows (1 to 100). Overlapping windows are merged." } },
          { status_code = { type = "integer", required = true, default = 503, between = { 400, 599 },
                            description = "HTTP status returned during an outage (RFC 9110: 503)." } },
          { message = { type = "string", len_min = 1, len_max = 512,
                        description = "Human-readable `detail` of the RFC 9457 problem response, "
                                      .. "up to 512 bytes." } },
          { retry_after = { type = "boolean", required = true, default = true,
                            description = "Send `Retry-After` (seconds until the window ends)." } },
          { announce = { type = "boolean", required = true, default = true,
                         description = "Announce the next upcoming window on normal responses." } },
          { announce_header = { type = "string", required = true, default = "Planned-Outage",
                                len_max = 64, match = HEADER_NAME,
                                match_none = deny(FRAMING_HEADERS, PAYLOAD_HEADERS),
                                description = "Name of the announcement header: an RFC 9110 token without "
                                              .. "underscores, up to 64 bytes. Framing and upstream payload "
                                              .. "headers such as Content-Length or Cache-Control are rejected." } },
          { announce_lead_time = { type = "integer", required = true, default = 604800,
                                   between = { 0, ONE_YEAR },
                                   description = "Seconds before a window starts to begin announcing it; 0 = always." } },
          { response_body = { type = "string", len_min = 1, len_max = 4096,
                              description = "Outage body template, up to 4096 bytes, with {status}, {message}, "
                                            .. "{start_time}, {end_time}, {retry_after} and {request_id} "
                                            .. "placeholders. Default: an RFC 9457 problem document." } },
          { response_content_type = { type = "string", len_min = 1, len_max = 255, match = MEDIA_TYPE,
                                      description = "Outage Content-Type: a media type such as "
                                                    .. "application/json, up to 255 bytes. Default: "
                                                    .. "application/json with response_body, otherwise "
                                                    .. "application/problem+json." } },
          { response_headers = { type = "map", len_max = 20,
                                 keys = { type = "string", len_max = 64, match = HEADER_NAME,
                                          match_none = deny(FRAMING_HEADERS) },
                                 values = { type = "string", len_max = 256, match = HEADER_VALUE },
                                 description = "Extra outage response headers, up to 20. Names are RFC 9110 "
                                               .. "tokens without underscores (up to 64 bytes); framing headers "
                                               .. "such as Content-Length are rejected. Values (up to 256 bytes, "
                                               .. "no control characters) may use the response_body "
                                               .. "placeholders." } },
        },
      },
    },
  },
}
