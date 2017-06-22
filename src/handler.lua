local cjson = require "cjson"
local BasePlugin = require "kong.plugins.base_plugin"
local ScheduleOutageHandler = BasePlugin:extend()

local req_get_uri_args = ngx.req.get_uri_args
local exit = ngx.exit
local header = ngx.header

local PATTERN = "(%d+)%-(%d+)%-(%d+)%a(%d+)%:(%d+)%:([%d%.]+)([Z%p])"

-- Credit where credit is due: https://coronalabs.com/blog/2013/01/15/working-with-time-and-dates-in-corona/
local function makeTimeStamp( dateString )
  local year, month, day, hour, minute, seconds, zulu = dateString:match(PATTERN)
  local timestamp = os.time(
    { year=year, month=month, day=day, hour=hour, min=minute, sec=seconds }
  )
  return timestamp
end

function ScheduleOutageHandler:new()
  ScheduleOutageHandler.super.new(self, "schedule-outage")
end

function ScheduleOutageHandler:access(config)
  ScheduleOutageHandler.super.access(self)

  -- HTTP Status Code to send back in response
  local httpStatusCode = config.statusCode

  -- If HTTP Status Message is set, then set it here
  local httpStatusMessage
  if config.statusMessage ~= nil then
    httpStatusMessage = config.statusMessage
  end

  local plannedOutageHeader = config.plannedHeader or "PLANNED-OUTAGE"

  -- Current Timestamp
  local currentTimestamp = os.time()

  -- From Timestamp
  local fromTimestamp = makeTimeStamp(config.from)

  -- To Timestamp
  local toTimestamp = makeTimeStamp(config.to)

  -- Get Arguments from URI, e.g. uri?foo=bar
  local args = req_get_uri_args()

  -- Skip the outage check and outage headers? Default: false (do not skip)
  local skipOutage = false
  if args['skip_outage_check'] == '1' then
    skipOutage = true
  end

  -- If current time within outage range, kill the request and respond with 503 Service Unavailable
  if currentTimestamp >= fromTimestamp and currentTimestamp <= toTimestamp then
    if httpStatusMessage and httpStatusMessage ~= "" then
      ngx.status = httpStatusCode
      ngx.say(cjson.encode({
        errorCode = httpStatusCode, -- TODO: Map httpStatusCode (e.g. 503) to string code (e.g. SERVICE_UNAVAILABLE)
        errorDescription = httpStatusMessage
      }))
    end

    return exit(httpStatusCode)
  -- If not within current outage, and an outage is expected to occur in the future, then add the `AUSPOST-PLANNED-OUTAGE` header
  elseif not skipOutage and currentTimestamp < fromTimestamp then
    header[plannedOutageHeader] = '{"from":"' .. config.from .. '", "to":"' .. config.to .. '"}'
  end
end

return ScheduleOutageHandler
