# Schedule Outage Plugin
This is a Schedule Outage plugin for Kong, written in Lua. It allows outages to be scheduled from upstream in kong. 

## Usage
### Configuration
| Input Field| Required/Optional|Data Type|Description |
|---|---|---|---|
|config.from| Required|ISO8601 Date String|An ISO8601 date string with UTC, e.g. 2016-09-23T01:18:33Z, which defines the start datetime of the outage range.
|config.to|Required| ISO8601 Date String| An ISO8601 date string with UTC, e.g. 2016-09-23T01:18:33Z, which defines the end datetime of the outage range.
|config.statusCode|Required|Integer| A status code between 100 and 599 (inclusive) to be sent in the body of the response, and as the HTTP Status of the response. 
|config.statusMessage|Optional|String|A status message to be displayed in the body of the response. If not defined, the json body is not sent in the response.
|config.plannedHeader|Optional|String|The title of the header that will displayed in the response, when a future outage is scheduled. If not defined, will default to 'PLANNED-OUTAGE'

Here is a sample CURL command for enablind the plugin 

`curl -X POST kong:8001/apis/{api-name}}/plugins \`

`--data "name=schedule-outage" \`

`--data "config.statusMessage=Currently under maintenance" \`

`--data "config.plannedHeader=OUTAGE-PLANNED" \`

`--data "config.from=2017-06-07T05:55:05Z" \`

`--data "config.to=2017-06-07T11:55:05Z" \`

`--data "config.statusCode=503"`

### skip_outage_check

If skip_outage_check URL parameter is appended to the request, the check is skipped and the planned outage header is not added.

If it is appended to the request during an outage, the modified response will still occur, blocking usage of the API.

Example URL:
http://localhost:8000/[api-name]?skip_outage_check=1



## Testing
In order to run the tests, you must have a Kong development environment set up, with the Busted testing framework installed (Instructions on this can be found here: https://github.com/Mashape/kong-vagrant)

Once your development environment is ready, copy the 'schedule-out' directory into your filesystem and run 'luarocks make' from within the schedule-outage directory, which will install it into the Kong plugins directory.

The plugin itself can be enabled in kong by running 
`export KONG_CUSTOM_PLUGINS=myPlugin`

Once enabled, navigate to to the 'schedule-outage' directory you copied into your file system and run `busted busted spec/schedule-outage_spec.lua`