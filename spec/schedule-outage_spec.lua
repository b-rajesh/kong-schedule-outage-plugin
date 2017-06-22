local helpers = require "spec.helpers"
local cjson   = require "cjson"

describe("Plugin: schedule-outage", function()
  local client
  setup(function()

    -- API with outage scheduled in the future
    local api = assert(helpers.dao.apis:insert {
      name         = "api1",
      hosts        = { "test.com" },
      upstream_url = "http://mockbin.com",
    })

    assert(helpers.dao.plugins:insert {
      api_id = api.id,
      name = "schedule-outage",
      config = {
          from = "2111-11-11T11:11:11Z",
          to = "2111-12-12T12:12:12Z",
          statusCode = "503",
          statusMessage = "Error Message",
          plannedHeader = "PLANNED-OUTAGE",
      }
    })

  -- API with outage currently scheduled
    local api2 = assert(helpers.dao.apis:insert {
      name         = "api2",
      hosts        = { "test2.com" },
      upstream_url = "http://mockbin.com",
    })

    assert(helpers.dao.plugins:insert {
      api_id = api2.id,
      name = "schedule-outage",
      config = {
          from = "2011-11-11T11:11:11Z",
          to = "2111-12-12T12:12:12Z",
          statusCode = "503",
          statusMessage = "Error Message",
          plannedHeader = "PLANNED-OUTAGE",
      }
    })

    -- API with an outage scheduled in the past
    local api3 = assert(helpers.dao.apis:insert {
      name         = "api3",
      hosts        = { "test3.com" },
      upstream_url = "http://mockbin.com",
    })

    assert(helpers.dao.plugins:insert {
      api_id = api3.id,
      name = "schedule-outage",
      config = {
          from = "2011-11-11T11:11:11Z",
          to = "2011-12-12T12:12:12Z",
          statusCode = "503",
          statusMessage = "Error Message",
          plannedHeader = "PLANNED-OUTAGE",
      }
    })

    assert(helpers.start_kong())
  end)

  teardown(function()
    helpers.stop_kong(nil, false)
  end)

  before_each(function()
    client = helpers.proxy_client()
  end)

  after_each(function()
    if client then client:close() end
  end)

  describe("before scheduled outage", function()
    it("should return 200 and display planned outage header", function()
      local res = assert(client:send {
        method  = "GET",
        path    = "/",
        body    = {},
        headers = {
          ["Host"] = "test.com"
        }
      })

      assert.res_status(200, res)
      assert.equals(res.headers["PLANNED-OUTAGE"], '{"from":"2111-11-11T11:11:11Z", "to":"2111-12-12T12:12:12Z"}')
    end)

      it("should return 200 and not display planned outage header, with skip_outage_check true", function()
        local res = assert(client:send {
          method  = "GET",
          path    = "/?skip_outage_check=1",
          body    = {},
          headers = {
            ["Host"] = "test.com"
          }
        })

        assert.res_status(200, res)
        assert.equals(res.headers["PLANNED-OUTAGE"], nil)
    end)
  end)

  describe("during scheduled outage", function()
    client = helpers.proxy_client()

    it("should return 503 and display outage error message", function()
      local res = assert(client:send {
        method  = "GET",
        path    = "/",
        body    = {},
        headers = {
          ["Host"] = "test2.com"
        }
      })

      local body = assert.res_status(503, res)
      local json = cjson.decode(body)
      assert.equals(503, json.errorCode)
      assert.equals("Error Message", json.errorDescription)
    end)

    it("should return 503 and display outage error message, with skip outage check true", function()
      local res = assert(client:send {
        method  = "GET",
        path    = "/?skip_outage_check=1",
        body    = {},
        headers = {
          ["Host"] = "test2.com"
        }
      })

      local body = assert.res_status(503, res)
      local json = cjson.decode(body)
      assert.equals(503, json.errorCode)
      assert.equals("Error Message", json.errorDescription)
    end)
  end)

  describe("after scheduled outage", function()
    client = helpers.proxy_client()

    it("should return 200", function()
      local res = assert(client:send {
        method  = "GET",
        path    = "/",
        body    = {},
        headers = {
          ["Host"] = "test3.com"
        }
      })

      assert.res_status(200, res)
      assert.equals(res.headers["PLANNED-OUTAGE"], nil)
    end)
  end)

end)
