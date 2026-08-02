local h = require("tests.helpers")

-- Set up emeth.acp config with a fake provider before loading Session
require("emeth.acp").config = {
  providers = {
    ["test"] = { command = "echo", args = {} },
  },
}

local Session = require("emeth.acp.session")

h.describe("Session event emitter", function()
  h.it("on + _emit calls listener", function()
    local s = Session:new("test")
    local called = {}
    s:on("update", function(val)
      called[#called + 1] = val
    end)
    s:_emit("update", "hello")
    h.eq({ "hello" }, called)
  end)

  h.it("multiple listeners all fire", function()
    local s = Session:new("test")
    local a, b = 0, 0
    s:on("update", function()
      a = a + 1
    end)
    s:on("update", function()
      b = b + 1
    end)
    s:_emit("update")
    h.eq(1, a)
    h.eq(1, b)
  end)

  h.it("off removes the correct listener", function()
    local s = Session:new("test")
    local count = 0
    local fn = function()
      count = count + 1
    end
    s:on("error", fn)
    s:off("error", fn)
    s:_emit("error")
    h.eq(0, count)
  end)

  h.it("off with unknown event is a no-op", function()
    local s = Session:new("test")
    s:off("nonexistent", function() end)
  end)

  h.it("emit with no listeners is a no-op", function()
    local s = Session:new("test")
    s:_emit("update", "data")
  end)
end)

h.describe("Session _extract_session_info", function()
  h.it("extracts model and mode", function()
    local s = Session:new("test")
    s:_extract_session_info({
      models = { currentModelId = "gpt-5" },
      modes = { currentModeId = "agent" },
    })
    h.eq("gpt-5", s.extensions.model_id)
    h.eq("agent", s.extensions.mode_id)
  end)

  h.it("handles nil result", function()
    local s = Session:new("test")
    s:_extract_session_info(nil)
    h.is_nil(s.extensions)
  end)

  h.it("handles partial result with only models", function()
    local s = Session:new("test")
    s:_extract_session_info({ models = { currentModelId = "m1" } })
    h.eq("m1", s.extensions.model_id)
    h.is_nil(s.extensions.mode_id)
  end)

  h.it("handles empty result table", function()
    local s = Session:new("test")
    s:_extract_session_info({})
    -- extensions gets initialized but no model/mode set
    h.is_nil(s.extensions.model_id)
    h.is_nil(s.extensions.mode_id)
  end)

  h.it("captures configOptions keyed by id", function()
    local s = Session:new("test")
    s:_extract_session_info({
      configOptions = {
        { id = "model", type = "select", currentValue = "opus", options = {} },
        { id = "mode", type = "select", currentValue = "default", options = {} },
      },
    })
    h.eq("opus", s.extensions.config_options.model.currentValue)
    h.eq("select", s.extensions.config_options.mode.type)
  end)

  h.it("merges configOptions across calls (later snapshot wins per id)", function()
    local s = Session:new("test")
    s:_extract_session_info({ configOptions = { { id = "model", currentValue = "opus" } } })
    s:_extract_session_info({ configOptions = { { id = "model", currentValue = "sonnet" } } })
    h.eq("sonnet", s.extensions.config_options.model.currentValue)
  end)
end)

h.describe("Session set_config_option", function()
  h.it("sends a select value as { configId, value } when ready", function()
    local s = Session:new("test")
    s._state = "ready"
    s.session_id = "sess-1"
    local sent
    s.client.set_config_option = function(_, session_id, config_id, value, cb)
      sent = { session_id = session_id, config_id = config_id, value = value }
      cb({ configOptions = {} }, nil)
    end
    local got
    s:set_config_option("model", "opus", function(result)
      got = result
    end)
    h.eq("sess-1", sent.session_id)
    h.eq("model", sent.config_id)
    h.eq("opus", sent.value)
    h.is_true(got ~= nil)
  end)

  h.it("errors without hitting the client when not ready", function()
    local s = Session:new("test")
    s._state = "connecting"
    local called = false
    s.client.set_config_option = function()
      called = true
    end
    local err
    s:set_config_option("model", "opus", function(_, e)
      err = e
    end)
    h.is_true(not called, "client must not be called when not ready")
    h.is_true(err ~= nil and err.message:find("not ready") ~= nil)
  end)
end)

h.describe("ACPClient set_config_option wire shape", function()
  local ACPClient = require("emeth.acp.client")

  h.it("tags boolean values with type=boolean", function()
    local c = ACPClient:new({ transport_type = "stdio", command = "echo" })
    local captured
    c._send_request = function(_, method, params)
      captured = { method = method, params = params }
    end
    c:set_config_option("s1", "fast", true, function() end)
    h.eq("session/set_config_option", captured.method)
    h.eq("boolean", captured.params.type)
    h.eq(true, captured.params.value)
  end)

  h.it("omits type for select (string) values", function()
    local c = ACPClient:new({ transport_type = "stdio", command = "echo" })
    local captured
    c._send_request = function(_, method, params)
      captured = { method = method, params = params }
    end
    c:set_config_option("s1", "model", "opus", function() end)
    h.is_nil(captured.params.type)
    h.eq("opus", captured.params.value)
  end)
end)

h.describe("Session permission event", function()
  h.it("emits permission with tool_call, options, and callback", function()
    local s = Session:new("test")
    local received = {}
    s:on("permission", function(tool_call, options, callback)
      received.tool_call = tool_call
      received.options = options
      received.callback = callback
    end)
    local tc = { toolCallId = "t1", title = "ls", kind = "execute" }
    local opts = { { kind = "allow_once", optionId = "a1", name = "Allow" } }
    local cb = function() end
    s.client.config.handlers.on_request_permission(tc, opts, cb)
    h.eq("t1", received.tool_call.toolCallId)
    h.eq(1, #received.options)
    h.eq("allow_once", received.options[1].kind)
    h.is_true(received.callback ~= nil)
  end)

  h.it("auto_approve_tools calls callback immediately", function()
    require("emeth.acp").config.auto_approve_tools = true
    local s = Session:new("test")
    local chosen = nil
    local cb = function(id)
      chosen = id
    end
    local opts = {
      { kind = "reject_once", optionId = "r1", name = "Reject" },
      { kind = "allow_once", optionId = "a1", name = "Allow" },
    }
    s.client.config.handlers.on_request_permission({ toolCallId = "t1" }, opts, cb)
    h.eq("a1", chosen)
    require("emeth.acp").config.auto_approve_tools = false
  end)

  h.it("without auto_approve_tools callback is not called", function()
    require("emeth.acp").config.auto_approve_tools = false
    local s = Session:new("test")
    local chosen = nil
    local cb = function(id)
      chosen = id
    end
    local opts = { { kind = "allow_once", optionId = "a1", name = "Allow" } }
    s.client.config.handlers.on_request_permission({ toolCallId = "t1" }, opts, cb)
    h.is_nil(chosen)
  end)
end)

h.describe("Session _extract_session_info provider delegation", function()
  -- Inject a fake provider extension module on the fly. We use a unique name
  -- so the require cache miss doesn't clash with real integrations.
  local fake = { calls = 0, last_result = nil, last_extensions = nil }
  package.loaded["emeth.integrations.fakeprov"] = {
    extract_session_info = function(result, extensions)
      fake.calls = fake.calls + 1
      fake.last_result = result
      fake.last_extensions = extensions
      extensions.custom_field = "from-extension"
    end,
  }
  -- Register provider config too
  require("emeth.acp").config.providers["fakeprov"] = { command = "echo", args = {} }

  h.it("calls extension's extract_session_info with result and extensions table", function()
    local s = Session:new("fakeprov")
    s:_extract_session_info({ models = { currentModelId = "m1" }, configOptions = { foo = "bar" } })
    h.eq(1, fake.calls)
    h.eq("m1", s.extensions.model_id) -- standard field still set
    h.eq("from-extension", s.extensions.custom_field) -- extension mutation visible
    h.eq("bar", fake.last_result.configOptions.foo)
  end)

  h.it("nil result short-circuits before delegation", function()
    fake.calls = 0
    local s = Session:new("fakeprov")
    s:_extract_session_info(nil)
    h.eq(0, fake.calls)
  end)

  h.it("missing extract_session_info on extension is ok", function()
    package.loaded["emeth.integrations.bareprov"] = { build_session_meta = function() end }
    require("emeth.acp").config.providers["bareprov"] = { command = "echo", args = {} }
    local s = Session:new("bareprov")
    s:_extract_session_info({ models = { currentModelId = "x" } })
    h.eq("x", s.extensions.model_id)
  end)

  h.it("buggy extract_session_info is contained via pcall", function()
    package.loaded["emeth.integrations.brokenprov"] = {
      extract_session_info = function()
        error("boom")
      end,
    }
    require("emeth.acp").config.providers["brokenprov"] = { command = "echo", args = {} }
    local s = Session:new("brokenprov")
    -- Should not throw
    s:_extract_session_info({ models = { currentModelId = "x" } })
    h.eq("x", s.extensions.model_id)
  end)
end)
