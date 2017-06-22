package = "schedule-outage"
version = "0.1-1"
source = {
    url = "https://stash.cd.auspost.com.au/projects/GP/repos/api-gateway-poc/browse/kong/schedule-outage"
}
description = {
    summary = "A Kong plugin that allows outage scheduling.",
    detailed = [[
        A Kong plugin that allows outage scheduling by Datetime string, with customisation of HTTP status code, planned outage header and error message.
    ]],
    license = "GPL-3.0"
}
dependencies = {
    "lua ~> 5.1"
}
build = {
    type = "builtin",
    modules = {
        ["kong.plugins.schedule-outage.handler"] = "src/handler.lua",
        ["kong.plugins.schedule-outage.schema"] = "src/schema.lua"
    }
}
