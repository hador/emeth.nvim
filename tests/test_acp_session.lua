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
