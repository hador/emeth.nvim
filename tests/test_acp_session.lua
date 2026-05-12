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
    local cb = function(id) chosen = id end
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
    local cb = function(id) chosen = id end
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
    h.eq("m1", s.extensions.model_id)  -- standard field still set
    h.eq("from-extension", s.extensions.custom_field)  -- extension mutation visible
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
      extract_session_info = function() error("boom") end,
    }
    require("emeth.acp").config.providers["brokenprov"] = { command = "echo", args = {} }
    local s = Session:new("brokenprov")
    -- Should not throw
    s:_extract_session_info({ models = { currentModelId = "x" } })
    h.eq("x", s.extensions.model_id)
  end)
end)
