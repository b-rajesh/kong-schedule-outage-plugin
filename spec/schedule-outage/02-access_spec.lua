local helpers = require "spec.helpers"
local cjson = require "cjson"

local PLUGIN_NAME = "schedule-outage"

local HOUR = 3600
local DAY = 24 * HOUR

-- Kong's clock (ngx.time) and this test's clock are the same host clock.
local NOW = os.time()

local function iso(offset)
  return os.date("!%Y-%m-%dT%H:%M:%SZ", NOW + offset)
end

local function window(from, to)
  return { start_time = iso(from), end_time = iso(to) }
end

local function announcement(w)
  return 'start="' .. w.start_time .. '", end="' .. w.end_time .. '"'
end

-- host => plugin config
local FIXTURES = {
  ["upcoming.test"]   = { windows = { window(HOUR, 2 * HOUR) } },
  ["far.test"]        = { windows = { window(30 * DAY, 31 * DAY) } },
  ["always.test"]     = { windows = { window(30 * DAY, 31 * DAY) }, announce_lead_time = 0,
                          announce_header = "X-Maintenance" },
  ["silent.test"]     = { windows = { window(HOUR, 2 * HOUR) }, announce = false },
  ["active.test"]     = { windows = { window(-HOUR, 600) }, message = "Scheduled maintenance" },
  ["bare.test"]       = { windows = { window(-HOUR, 600) }, status_code = 500, retry_after = false },
  ["past.test"]       = { windows = { window(-2 * HOUR, -HOUR) } },
  ["multi.test"]      = { windows = { window(-3 * HOUR, -2 * HOUR), window(2 * HOUR, 3 * HOUR),
                                      window(HOUR, 90 * 60) } },
  ["overlap.test"]    = { windows = { window(-HOUR, 300), window(120, 1200) } },
  ["invalid.test"]    = { windows = { window(-HOUR, -2 * HOUR), window(HOUR, 2 * HOUR) } },
  ["template.test"]   = { windows = { window(-HOUR, 600) }, message = "Core banking upgrade",
                          response_body = '{"errors":[{"code":"Service/Unavailable",'
                                          .. '"detail":"{message}","until":"{end_time}","meta":{}}]}',
                          response_headers = { ["X-Correlation-Id"] = "{request_id}" } },
}

for _, strategy in helpers.all_strategies() do
  if strategy ~= "cassandra" then
    describe(PLUGIN_NAME .. ": (access) [#" .. strategy .. "]", function()
      local client

      lazy_setup(function()
        local bp = helpers.get_db_utils(strategy == "off" and "postgres" or strategy, nil, { PLUGIN_NAME })

        for host, config in pairs(FIXTURES) do
          local route = bp.routes:insert({ hosts = { host } })
          bp.plugins:insert({ name = PLUGIN_NAME, route = { id = route.id }, config = config })
        end

        assert(helpers.start_kong({
          database = strategy,
          nginx_conf = "spec/fixtures/custom_nginx.template",
          plugins = "bundled," .. PLUGIN_NAME,
          declarative_config = strategy == "off" and helpers.make_yaml_file() or nil,
        }))
      end)

      lazy_teardown(function()
        helpers.stop_kong(nil, true)
      end)

      before_each(function()
        client = helpers.proxy_client()
      end)

      after_each(function()
        if client then client:close() end
      end)

      local function get(host)
        return assert(client:send({ method = "GET", path = "/request", headers = { host = host } }))
      end

      describe("before a window", function()
        it("proxies and announces a window within the lead time", function()
          local res = get("upcoming.test")
          assert.res_status(200, res)
          assert.equal(announcement(FIXTURES["upcoming.test"].windows[1]), res.headers["Planned-Outage"])
        end)

        it("does not announce a window beyond the lead time", function()
          local res = get("far.test")
          assert.res_status(200, res)
          assert.is_nil(res.headers["Planned-Outage"])
        end)

        it("always announces with lead time 0, using the configured header", function()
          local res = get("always.test")
          assert.res_status(200, res)
          assert.equal(announcement(FIXTURES["always.test"].windows[1]), res.headers["X-Maintenance"])
          assert.is_nil(res.headers["Planned-Outage"])
        end)

        it("does not announce when announce is false", function()
          local res = get("silent.test")
          assert.res_status(200, res)
          assert.is_nil(res.headers["Planned-Outage"])
        end)
      end)

      describe("during a window", function()
        it("returns an RFC 9457 problem with Retry-After", function()
          local res = get("active.test")
          local body = cjson.decode(assert.res_status(503, res))
          local w = FIXTURES["active.test"].windows[1]

          assert.equal("application/problem+json", res.headers["Content-Type"])
          assert.equal("no-store", res.headers["Cache-Control"])
          local retry_after = tonumber(res.headers["Retry-After"])
          assert.is_true(retry_after > 0 and retry_after <= 600)

          assert.same({
            type = "about:blank",
            title = "Service Unavailable",
            status = 503,
            detail = "Scheduled maintenance",
            outage_start = w.start_time,
            outage_end = w.end_time,
          }, body)
        end)

        it("honours status_code and retry_after = false", function()
          local res = get("bare.test")
          local body = cjson.decode(assert.res_status(500, res))
          assert.is_nil(res.headers["Retry-After"])
          assert.equal(500, body.status)
          assert.is_nil(body.detail)
        end)

        it("uses the merged end of overlapping windows for Retry-After", function()
          local res = get("overlap.test")
          local body = cjson.decode(assert.res_status(503, res))
          assert.equal(FIXTURES["overlap.test"].windows[2].end_time, body.outage_end)
          assert.is_true(tonumber(res.headers["Retry-After"]) > 300)
        end)

        it("renders the configured response body and headers", function()
          local res = get("template.test")
          local raw = assert.res_status(503, res)
          assert.equal("application/json", res.headers["Content-Type"])
          assert.matches("^%x+$", res.headers["X-Correlation-Id"])
          assert.matches('"meta":{}', raw, 1, true)
          assert.same({ errors = { {
            code = "Service/Unavailable",
            detail = "Core banking upgrade",
            ["until"] = FIXTURES["template.test"].windows[1].end_time,
            meta = {},
          } } }, cjson.decode(raw))
        end)
      end)

      describe("after windows", function()
        it("proxies without announcing", function()
          local res = get("past.test")
          assert.res_status(200, res)
          assert.is_nil(res.headers["Planned-Outage"])
        end)

        it("announces the earliest upcoming window regardless of config order", function()
          local res = get("multi.test")
          assert.res_status(200, res)
          assert.equal(announcement(FIXTURES["multi.test"].windows[3]), res.headers["Planned-Outage"])
        end)

        it("ignores windows whose start is not before their end", function()
          local res = get("invalid.test")
          assert.res_status(200, res)
          assert.equal(announcement(FIXTURES["invalid.test"].windows[2]), res.headers["Planned-Outage"])
        end)
      end)
    end)
  end
end
