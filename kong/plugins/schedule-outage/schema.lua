-- Configuration schema for the schedule-outage plugin.
--
-- Konnect constraints this file deliberately respects:
--   * no `require()` (hybrid mode uploads this file alone to the control plane)
--   * no custom validator functions (streamed plugins / Dedicated Cloud
--     Gateways only honour declarative rules); semantic checks such as
--     `start_time < end_time` therefore live in handler.lua.

-- RFC 3339 date-time, UTC only ("Z"), no fractional seconds.
local RFC3339_UTC = "^%d%d%d%d%-%d%d%-%d%dT%d%d:%d%d:%d%dZ$"

-- RFC 9110 field-name token.
local HEADER_NAME = "^[%w!#%$%%&'%*%+%-%.%^_`|~]+$"

local ONE_YEAR = 365 * 24 * 60 * 60

-- `typedefs.no_consumer` without the require. The guard keeps the schema
-- loadable by parsers that do not expose the `ngx` global.
local null = ngx and ngx.null

local window = {
  type = "record",
  fields = {
    { start_time = { type = "string", required = true, match = RFC3339_UTC,
                     description = "Outage start, RFC 3339 UTC (e.g. 2026-12-01T02:00:00Z). Inclusive." } },
    { end_time   = { type = "string", required = true, match = RFC3339_UTC,
                     description = "Outage end, RFC 3339 UTC. Exclusive: traffic resumes at this instant." } },
  },
}

return {
  name = "schedule-outage",
  fields = {
    { consumer = { type = "foreign", reference = "consumers", eq = null } },
    { config = {
        type = "record",
        fields = {
          { windows = { type = "array", required = true, len_min = 1, len_max = 100,
                        elements = window,
                        description = "Scheduled outage windows. Overlapping windows are merged." } },
          { status_code = { type = "integer", required = true, default = 503, between = { 400, 599 },
                            description = "HTTP status returned during an outage (RFC 9110: 503)." } },
          { message = { type = "string", len_min = 1,
                        description = "Human-readable `detail` of the RFC 9457 problem response." } },
          { retry_after = { type = "boolean", required = true, default = true,
                            description = "Send `Retry-After` (seconds until the window ends)." } },
          { announce = { type = "boolean", required = true, default = true,
                         description = "Announce the next upcoming window on normal responses." } },
          { announce_header = { type = "string", required = true, default = "Planned-Outage",
                                match = HEADER_NAME,
                                description = "Name of the announcement header." } },
          { announce_lead_time = { type = "integer", required = true, default = 604800,
                                   between = { 0, ONE_YEAR },
                                   description = "Seconds before a window starts to begin announcing it; 0 = always." } },
          { response_body = { type = "string", len_min = 1,
                              description = "Outage body template with {status}, {message}, {start_time}, "
                                            .. "{end_time}, {retry_after} and {request_id} placeholders. "
                                            .. "Default: an RFC 9457 problem document." } },
          { response_content_type = { type = "string", len_min = 1,
                                      description = "Outage Content-Type. Default: application/json with "
                                                    .. "response_body, otherwise application/problem+json." } },
          { response_headers = { type = "map",
                                 keys = { type = "string", match = HEADER_NAME },
                                 values = { type = "string" },
                                 description = "Extra outage response headers; values may use the "
                                               .. "response_body placeholders." } },
        },
      },
    },
  },
}
