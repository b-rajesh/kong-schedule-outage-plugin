local PATTERN = "^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$"

local function checkUTC(date)
  local match = ngx.re.match(date, PATTERN)
  if match then
    return true
  end
  return false, "Input does not follow ISO 8601 UTC format"
end

local function checkStatusCode(statusCode)
  if statusCode <= 599 and statusCode >= 100 then
    return true
  end

  return false, "Input not a valid HTTP status code"
end

return {
  no_consumer = true,
  fields = {
    from = { type = "string", func = checkUTC, required = true },
    to = { type = "string", func = checkUTC, required = true },
    statusCode = { type = "number", func = checkStatusCode, required = true },
    statusMessage = { type = "string" },
    plannedHeader = { type = "string" }
  }
}
