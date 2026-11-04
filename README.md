# Schedule Outage Plugin

A Kong Gateway plugin that rejects traffic during scheduled maintenance windows
and announces upcoming windows to clients.

## Compatibility

| Platform | Status |
|---|---|
| Kong Gateway 3.14.0.13 (LTS) | Tested (Postgres and DB-less) |
| Kong Gateway 3.16.0.0 | Tested (Postgres and DB-less) |
| Konnect, self-managed hybrid data planes | Supported |
| Konnect, Dedicated Cloud Gateways | Supported through plugin streaming, see [Deploying to Konnect](#deploying-to-konnect) |
| Konnect, Serverless Gateways | Not supported (Konnect does not allow custom plugins there) |

## Behaviour

| Time | Result |
|---|---|
| Before a window, within `announce_lead_time` | Request proxied; response carries the announcement header |
| Inside a window `[start_time, end_time)` | Request rejected with `status_code` (default 503) |
| Outside any window | Plugin does nothing |

Overlapping windows are merged. A window whose `start_time` is not before its
`end_time` is logged and ignored, so a bad schedule never causes an outage.

During an outage:

```http
HTTP/1.1 503 Service Unavailable
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
| Announcement header name | [RFC 6648](https://www.rfc-editor.org/rfc/rfc6648) and [RFC 9110, section 5.1](https://www.rfc-editor.org/rfc/rfc9110#section-5.1) | The default name `Planned-Outage` has no `X-` prefix, as RFC 6648 recommends. Custom names must be valid RFC 9110 field names. |

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
| `config.windows` | yes | | Array (1 to 100) of `{ start_time, end_time }`, RFC 3339 UTC, e.g. `2026-12-01T02:00:00Z`. Start is inclusive, end exclusive. |
| `config.status_code` | no | `503` | Status returned during an outage, 400 to 599. |
| `config.message` | no | | `detail` of the problem response. |
| `config.retry_after` | no | `true` | Send `Retry-After` during an outage. |
| `config.announce` | no | `true` | Announce the next upcoming window. |
| `config.announce_header` | no | `Planned-Outage` | Name of the announcement header. |
| `config.announce_lead_time` | no | `604800` (7 days) | Seconds before a window to start announcing it; `0` = always. |

The plugin can be applied globally, or to a service or route. It cannot be
scoped to a consumer: it runs before authentication (priority 1500), so that
callers get a 503 rather than a 401 during an outage.

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

Upload `handler.lua` and `schema.lua` as a streamed custom plugin (Gateway
Manager > Plugins > Custom plugin, or decK). Konnect distributes it to every
data plane in the control plane.

Kong's streaming documentation lists Gateway 3.15 as the minimum version. Check
with Kong whether streaming is available for a Dedicated Cloud Gateway running
3.14. If it is not, either run the gateway on 3.15 or later, or ask Kong support
to deploy the plugin manually.

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

Tests use [Pongo](https://github.com/Kong/kong-pongo) and Docker:

```bash
KONG_VERSION=3.14.0.x pongo run   # LTS (Enterprise versions have 4 parts)
KONG_VERSION=3.16.0.x pongo run   # latest
pongo lint
pongo down
```
