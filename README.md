# Schedule Outage Plugin

A Kong Gateway plugin that rejects traffic during scheduled maintenance windows
and announces upcoming windows to clients.

## Compatibility

The same plugin code runs on every supported version. What depends on the
version is how the plugin gets onto the gateway.

| Deployment | Gateway 3.14 (LTS) | Gateway 3.15 and later |
|---|---|---|
| Konnect, self-managed hybrid data planes | Supported. Upload `schema.lua` to the control plane and install both files on every data plane. | Supported. Install the files as on 3.14, or stream the plugin from the control plane (`custom_plugin_streaming_enabled=on`). |
| Konnect, Dedicated Cloud Gateways | Not supported. These gateways take custom plugins only through plugin streaming, which Kong has confirmed is not available on 3.14. | Supported through plugin streaming. |
| Konnect, Serverless Gateways | Not supported. Konnect does not allow custom plugins there. | Not supported. |
| Self-managed Kong Gateway (traditional or DB-less) | Supported. Install both files on every node. | Supported. Install the files, or use plugin streaming. |

See [Deploying to Konnect](#deploying-to-konnect) for the steps.

Tested versions:

| Version | Result |
|---|---|
| Kong Gateway 3.14.0.13 (LTS) | Tested (Postgres and DB-less) |
| Kong Gateway 3.15.0.3 | Tested (Postgres and DB-less). Minimum for Dedicated Cloud Gateways. |
| Kong Gateway 3.16.0.0 | Tested (Postgres and DB-less) |

## Behaviour

| Time | Result |
|---|---|
| Before a window, within `announce_lead_time` | Request proxied; response carries the announcement header |
| Inside a window `[start_time, end_time)` | Request rejected with `status_code` (default 503) |
| Outside any window | Plugin does nothing |

Overlapping windows are merged. The schema rejects timestamps that do not
exist, such as month 13 or 31 April, when the configuration is written (see
[Limits and validation](#limits-and-validation)). It cannot compare two fields
(Konnect does not run custom validators), so window order is checked at
runtime: a window whose `start_time` is not before its `end_time` is logged as
an error and ignored, so a bad schedule never causes an outage. If every
window is invalid, the plugin logs at `crit` level, because no outage will be
enforced at all. These messages are logged when the configuration is loaded
(Kong's `configure` phase), once per worker and again for every instance each
time any plugin configuration changes, not on the first request. Each ends with the plugin
instance ID, so you can tell which configuration has the problem. An ignored
window enforces no outage, so check window order before deploying, for example
in CI.

The announcement header is added to every response during the lead time,
including upstream errors such as 502. It describes the next scheduled
window, not the cause of the error.

During an outage:

```http
HTTP/1.1 503 Service Temporarily Unavailable
Content-Type: application/problem+json
Cache-Control: no-store
Retry-After: 5400

{
  "type": "about:blank",
  "title": "Service Unavailable",
  "status": 503,
  "detail": "Scheduled maintenance",
  "outage_start": "2026-12-01T02:00:00Z",
  "outage_end": "2026-12-01T06:00:00Z"
}
```

The status line carries nginx's reason phrase (`Service Temporarily
Unavailable`), while the `title` member uses the IANA phrase (`Service
Unavailable`).

Before an outage:

```http
Planned-Outage: start="2026-12-01T02:00:00Z", end="2026-12-01T06:00:00Z"
```

## Open standards

There is no single standard for scheduled maintenance in HTTP. The plugin
follows the published standard for each part of the behaviour instead.

| Concern | Standard | How the plugin applies it |
|---|---|---|
| Outage status | [RFC 9110, section 15.6.4](https://www.rfc-editor.org/rfc/rfc9110#section-15.6.4) | `503 Service Unavailable` is the status defined for temporary unavailability such as maintenance, so it is the default. `status_code` is limited to 400 to 599. |
| When to retry | [RFC 9110, section 10.2.3](https://www.rfc-editor.org/rfc/rfc9110#section-10.2.3) | `Retry-After` carries the number of seconds until the current window ends. |
| Error body | [RFC 9457](https://www.rfc-editor.org/rfc/rfc9457) | The outage response is a Problem Details document (`application/problem+json`) with `type`, `title`, `status`, `detail` and the extension members `outage_start` and `outage_end`. RFC 9457 replaces RFC 7807. |
| Caching | [RFC 9111, section 5.2.2.5](https://www.rfc-editor.org/rfc/rfc9111#section-5.2.2.5) | `Cache-Control: no-store` stops caches and CDNs from storing the outage response and serving it after the window ends. |
| Timestamps | [RFC 3339, section 5.6](https://www.rfc-editor.org/rfc/rfc3339#section-5.6) | Window times use the RFC 3339 profile of ISO 8601, in UTC (`Z`) only, so daylight saving and timezone offsets cannot shift a window. |
| Announcement header format | [RFC 9651, section 3.2](https://www.rfc-editor.org/rfc/rfc9651#section-3.2) | The announcement value is a Structured Field dictionary, `start="...", end="..."`, which any Structured Fields parser can read. |
| Announcement header name | [RFC 6648](https://www.rfc-editor.org/rfc/rfc6648) and [RFC 9110, section 5.1](https://www.rfc-editor.org/rfc/rfc9110#section-5.1) | The default name `Planned-Outage` has no `X-` prefix, as RFC 6648 recommends. Custom names must be valid RFC 9110 field names, without underscores; see [Limits and validation](#limits-and-validation). |

No standard defines a header for announcing planned maintenance, so
`Planned-Outage` is specific to this plugin.

Standards considered and not used:

| Standard | Reason |
|---|---|
| [RFC 8594](https://www.rfc-editor.org/rfc/rfc8594) `Sunset` | Announces that a resource will be removed permanently, not that it will be unavailable for a while. |
| [RFC 9745](https://www.rfc-editor.org/rfc/rfc9745) `Deprecation` | Marks a resource as deprecated, which an outage is not. |
| [RFC 5545](https://www.rfc-editor.org/rfc/rfc5545) iCalendar | Suited to publishing maintenance calendars outside HTTP, for example on a status page. That is outside the scope of a gateway plugin. |

## Configuration

| Field | Required | Default | Description |
|---|---|---|---|
| `config.windows` | yes | | Array (1 to 100) of `{ start_time, end_time }`, RFC 3339 UTC, e.g. `2026-12-01T02:00:00Z`. Start is inclusive, end exclusive. Dates that do not exist are rejected. |
| `config.status_code` | no | `503` | Status returned during an outage, 400 to 599. |
| `config.message` | no | | `detail` of the problem response, and the `{message}` placeholder. Limit: 512 bytes. |
| `config.retry_after` | no | `true` | Send `Retry-After` during an outage. |
| `config.announce` | no | `true` | Announce the next upcoming window. |
| `config.announce_header` | no | `Planned-Outage` | Name of the announcement header. Limits: 64 bytes, no underscore, and some names are reserved. See [Limits and validation](#limits-and-validation). |
| `config.announce_lead_time` | no | `604800` (7 days) | Seconds before a window to start announcing it; `0` = always. Maximum 31536000 (one year). |
| `config.response_body` | no | RFC 9457 problem document | Outage body template. Limit: 4096 bytes. See [Custom response](#custom-response). |
| `config.response_content_type` | no | `application/json` with `response_body`, otherwise `application/problem+json` | Outage `Content-Type`. Limits: 255 bytes, and it must start with `type/subtype`. |
| `config.response_headers` | no | | Extra outage response headers. Values may use placeholders. Limits: 20 entries, and rules for names and values. See [Limits and validation](#limits-and-validation). |

### Scoping and plugin order

The plugin can be applied globally, or to a service or route, on `http` and
`https` only. gRPC is excluded because a JSON outage body would bypass Kong's
gRPC status translation.

It cannot be scoped to a consumer or consumer group: it runs before most
authentication plugins (priority 1500), and at that point the consumer is not
yet known, so a consumer-scoped instance would never match. The schema rejects
such a configuration, except on a streamed plugin (Dedicated Cloud Gateways, or
streaming on self-managed 3.15 and later). There the schema sandbox has no
`ngx`, and Konnect does not allow `require()` in `schema.lua`, so the schema
can use neither `ngx.null` nor Kong's `no_consumer` definition to forbid it:
Kong accepts the instance, but it never runs (observed on 3.15.0.3). Apply the
plugin globally, or to a service or route.

In the access phase, plugins run from the highest priority to the lowest, so a
plugin above 1500 can answer a request before this one does:

| Plugins (priority) | During an outage |
|---|---|
| bot-detection (2500), cors (2000), jwe-decrypt (1999), session (1900), oauth2-introspection (1700), mtls-auth (1600) | Run before this plugin and can answer first. In a test, bot-detection answered 403 in the middle of an outage. |
| pre-function, correlation-id, zipkin, exit-transformer | Run before this plugin. They do not reject requests unless you configure them to, for example with code in pre-function. |
| jwt (1450), oauth2 (1400), key-auth (1250), ldap-auth (1200), basic-auth (1100), openid-connect (1050), hmac-auth (1030), rate limiting plugins (910 and below) | Run after this plugin, so they never answer first: callers get the outage response, not a 401 or 429. |

`cors` answers preflight (`OPTIONS`) requests itself. The outage response still
carries CORS headers, because `header_filter` runs for every plugin that
applies to the request, whatever its priority. Kong's `ordering` field can
change the order for the access phase.

### Limits and validation

The schema checks these when the configuration is written, so an invalid value
is rejected instead of being applied. Lengths are counted in bytes, so a
character outside ASCII counts as 2 to 4 bytes in UTF-8.

| Field | Accepted |
|---|---|
| `windows[].start_time`, `windows[].end_time` | `YYYY-MM-DDTHH:MM:SSZ` for a time that exists: month 01 to 12, a day that the month has (leap years included), hour 00 to 23, minute and second 00 to 59. A leap second (`:60`) is not accepted. |
| `message` | Up to 512 bytes. |
| `announce_header` | A valid header name of up to 64 bytes, without an underscore, and not one of the reserved names below. |
| `announce_lead_time` | 0 to 31536000 seconds (one year). |
| `response_body` | Up to 4096 bytes. |
| `response_content_type` | Up to 255 bytes. It must start with `type/subtype`; parameters after it are accepted if they contain no control characters. |
| `response_headers` | Up to 20 entries. Names are valid header names of up to 64 bytes, without an underscore, and not reserved. Values are up to 256 bytes, without control characters. |

Reserved names match in any letter case, so `content-length` is rejected too:

| Setting | Reserved names |
|---|---|
| `announce_header` | `Content-Length`, `Transfer-Encoding`, `Connection`, `Keep-Alive`, `Upgrade`, `TE`, `Trailer`, `Content-Type`, `Content-Encoding`, `Cache-Control`, `Set-Cookie`, `ETag`, `Last-Modified`, `Expires`, `Date`, `Location` |
| `response_headers` | `Content-Length`, `Transfer-Encoding`, `Connection`, `Keep-Alive`, `Upgrade`, `TE`, `Trailer` |

The length limits bound the memory and CPU that one request can use. A template
can repeat `{message}` many times, so without limits a 112 KB configuration
could make a single request build a 116 MB response body. With the limits, the
worst case is about 1.4 MB and 20 ms of CPU for one request, reached only by a
deliberately pathological template whose message consists of control characters
that JSON escaping expands; ordinary templates take microseconds. The reserved names
are rejected because a framing header such as `Content-Length` or
`Transfer-Encoding` set from configuration would corrupt or stall the
response, and because the announcement is added to proxied responses, where a
representation header such as `Content-Type` would replace the one the
upstream sent. Underscores are rejected because Kong turns `_` into `-` in
response header names, so the header sent would not match the name configured.

### decK example

```yaml
_format_version: "3.0"
plugins:
  - name: schedule-outage
    service: orders
    config:
      message: Scheduled maintenance
      windows:
        - start_time: "2026-12-01T02:00:00Z"
          end_time: "2026-12-01T06:00:00Z"
        - start_time: "2027-01-15T22:00:00Z"
          end_time: "2027-01-16T01:00:00Z"
```

### Admin API example

```bash
curl -X POST http://localhost:8001/services/orders/plugins \
  --json '{
    "name": "schedule-outage",
    "config": {
      "message": "Scheduled maintenance",
      "windows": [{ "start_time": "2026-12-01T02:00:00Z", "end_time": "2026-12-01T06:00:00Z" }]
    }
  }'
```

### Custom response

The outage body can follow any format your APIs already use. Set
`response_body` to a template; these placeholders are replaced:

| Placeholder | Value |
|---|---|
| `{status}` | `status_code`, e.g. `503` |
| `{message}` | `message`, or empty |
| `{start_time}` / `{end_time}` | The active window, RFC 3339 UTC |
| `{retry_after}` | Seconds until the window ends |
| `{request_id}` | Kong's request ID (`kong.request.get_id()`), the value Kong uses for `X-Kong-Request-Id` |

When the content type contains `json`, in any letter case, placeholder values
in the body are escaped for use inside JSON strings, so a message with quotes
or newlines cannot break the body. The content type here is
`response_content_type`, or its default; a `Content-Type` set in
`response_headers` does not change it. Unknown placeholders are left
unchanged. Apart from its length, the template is not validated: Konnect does
not run custom schema validators, so check that it is valid JSON before
deploying it.

`response_headers` adds headers to the outage response, after the defaults.
Header names are case-insensitive, so a header named like a default
(`Cache-Control`, `Retry-After` or `Content-Type`), in any letter case,
replaces that default. Avoid two entries whose names differ only in letter
case, such as `X-Env` and `x-env`: they collapse to one. The names are applied
in byte-wise sorted order (uppercase before lowercase) and the last one wins,
here `x-env`. Header values may use the same placeholders; control characters
are removed from them. Some names are not allowed; see
[Limits and validation](#limits-and-validation).

Example, an error list in the shape used by the Australian Consumer Data
Right standards:

```yaml
config:
  message: Core banking upgrade
  response_body: >-
    {"errors":[{"code":"urn:au-cds:error:cds-all:Service/Unavailable",
    "title":"Service Unavailable","detail":"{message}","meta":{}}]}
  response_headers:
    X-Correlation-Id: "{request_id}"
  windows:
    - start_time: "2026-12-01T02:00:00Z"
      end_time: "2026-12-01T06:00:00Z"
```

```http
HTTP/1.1 503 Service Temporarily Unavailable
Content-Type: application/json
Cache-Control: no-store
Retry-After: 5400
X-Correlation-Id: 5d41402abc4b2a76b9719d911017c592

{"errors":[{"code":"urn:au-cds:error:cds-all:Service/Unavailable", "title":"Service Unavailable","detail":"Core banking upgrade","meta":{}}]}
```

The template only shapes this plugin's outage response. Errors from other
Kong plugins (authentication, rate limiting, unknown routes) are unchanged; to
reshape those, use Kong's Exit Transformer plugin (Enterprise).

### Letting operators through during an outage

The plugin has no bypass of its own, on purpose: a bypass is an access control
and belongs in Kong's routing and auth layer. To smoke-test during a window,
add a dedicated route (for example matching an `Ops-Smoke-Test` header)
protected by `key-auth` or `ip-restriction`, and do not attach this plugin to
it. On Kong 3.15+, plugin conditions (CEL) are an alternative.

## Deploying to Konnect

The plugin is two self-contained files: no `require` in the schema, no custom
schema validators, no timers, no database entities. That meets the rules for
both deployment models.

### Self-managed hybrid data planes

1. Upload `kong/plugins/schedule-outage/schema.lua` to the control plane
   (Gateway Manager > Plugins > Custom plugin, or
   `POST /v2/control-planes/{id}/core-entities/plugin-schemas` with a
   `lua_schema` body).
2. Install both files on **every** data plane, e.g. in a custom image:

   ```dockerfile
   FROM kong/kong-gateway:3.14.0.13
   COPY kong/plugins/schedule-outage /usr/local/share/lua/5.1/kong/plugins/schedule-outage
   ENV KONG_PLUGINS=bundled,schedule-outage
   ```

   or `luarocks make` from this directory.

### Dedicated Cloud Gateways (streamed plugin)

Custom plugin streaming requires **Kong Gateway 3.15 or later**; Kong has
confirmed it is not available on 3.14 LTS. A Dedicated Cloud Gateway that needs
this plugin must therefore run 3.15 or later.

Upload `handler.lua` and `schema.lua` as a streamed custom plugin (Gateway
Manager > Plugins > Custom plugin, or decK). Konnect distributes it to every
data plane in the control plane.

Streaming is also available on self-managed data planes from 3.15, as an
alternative to installing the files on each node. It must be enabled with
[`custom_plugin_streaming_enabled`](https://developer.konghq.com/gateway/configuration/#custom-plugin-streaming-enabled)
(`KONG_CUSTOM_PLUGIN_STREAMING_ENABLED=on`).

## Upgrading from 0.1

| 0.1 | 1.0 |
|---|---|
| `from` / `to` | `windows[].start_time` / `windows[].end_time` |
| `statusCode` | `status_code` (now 400 to 599, default 503) |
| `statusMessage` | `message` |
| `plannedHeader` (`PLANNED-OUTAGE`) | `announce_header` (`Planned-Outage`) |
| JSON value in the planned header | Structured Field dictionary `start="...", end="..."` |
| `{errorCode, errorDescription}` body | RFC 9457 problem document |
| `?skip_outage_check=1` | Removed; see "Letting operators through" |

1.0 also fixes a bug where windows were read in the node's local timezone
instead of UTC.

## Testing

Tests run with [Pongo](https://github.com/Kong/kong-pongo), which needs Docker.
Install Pongo once:

```bash
git clone https://github.com/Kong/kong-pongo.git
ln -s "$(pwd)/kong-pongo/pongo.sh" ~/.local/bin/pongo   # any directory on your PATH
```

Kong Enterprise versions have four parts, so use `3.14.0.x` rather than
`3.14.x`. The first run for a version builds a test image and takes a few
minutes.

| Spec | Type | What it covers |
|---|---|---|
| `spec/schedule-outage/01-schema_spec.lua` | Unit | Configuration validation, defaults, limits and date rules |
| `spec/schedule-outage/03-handler_spec.lua` | Unit | UTC conversion and window boundaries, invalid windows and their log messages, the problem response and titles, response templates and JSON escaping |
| `spec/schedule-outage/04-headers_spec.lua` | Unit | Response header merging and `header_filter` |
| `spec/schedule-outage/05-schedule_spec.lua` | Unit | The schedule cache (config tables are never written), `configure`, window lookup checked against a brute-force reference, and the handler and schema running inside a restricted Lua environment like Konnect's sandbox (no `setmetatable`, `require`, `io` or `os`) |
| `spec/schedule-outage/06-calendar_spec.lua` | Unit | The schema and the handler agree, case by case, on which timestamps exist and which windows are ignored |
| `spec/schedule-outage/02-access_spec.lua` | Integration | Requests through a running Kong (Postgres and DB-less), including header merging, JSON escaping and load-time logging |

The unit specs do not start Kong: the PDK and the clock are stubbed, and the
stubs are shared in `spec/schedule-outage/handler_stubs.lua`. The calendar
cases used by specs 01 and 06 are in `spec/schedule-outage/calendar_cases.lua`.
All specs need Docker, and Pongo starts a Postgres container.

Unit tests only:

```bash
KONG_VERSION=3.14.0.x pongo run spec/schedule-outage/01-schema_spec.lua spec/schedule-outage/03-handler_spec.lua spec/schedule-outage/04-headers_spec.lua spec/schedule-outage/05-schedule_spec.lua spec/schedule-outage/06-calendar_spec.lua
```

All tests, on the LTS and the latest version:

```bash
KONG_VERSION=3.14.0.x pongo run
KONG_VERSION=3.16.0.x pongo run
```

Lint, and stop the test containers when finished:

```bash
pongo lint
pongo down
```

## License

Licensed under the Apache License, Version 2.0. See [LICENSE](LICENSE).
