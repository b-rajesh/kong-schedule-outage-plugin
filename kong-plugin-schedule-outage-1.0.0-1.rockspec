package = "kong-plugin-schedule-outage"
version = "1.0.0-1"

local pluginName = package:match("^kong%-plugin%-(.+)$")  -- "schedule-outage"

supported_platforms = { "linux", "macosx" }
source = {
  url = "git+https://github.com/b-rajesh/kong-schedule-outage-plugin.git",
  tag = "1.0.0",
}

description = {
  summary = "Kong plugin that rejects traffic during scheduled outage windows.",
  detailed = [[
    Returns an RFC 9457 problem response with Retry-After during configured
    maintenance windows and announces upcoming windows with a configurable
    response header. Compatible with Kong Gateway 3.14+ and Kong Konnect.
  ]],
  homepage = "https://github.com/b-rajesh/kong-schedule-outage-plugin",
  license = "GPL-3.0",
}

dependencies = {}

build = {
  type = "builtin",
  modules = {
    ["kong.plugins." .. pluginName .. ".handler"] = "kong/plugins/" .. pluginName .. "/handler.lua",
    ["kong.plugins." .. pluginName .. ".schema"] = "kong/plugins/" .. pluginName .. "/schema.lua",
  },
}
