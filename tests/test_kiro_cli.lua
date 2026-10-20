local h = require("tests.helpers")
local Kiro = require("emeth.integrations.kiro-cli")
local transform = Kiro._transform_update

-- ── build_session_meta ──────────────────────────────────────────

h.describe("kiro-cli build_session_meta", function()
  h.it("sends the configured mode as _meta.kiro.modeId on a new session", function()
    local meta = Kiro.build_session_meta({ kiro_cli = { mode = "my-agent" } }, "new")
    h.eq("my-agent", meta.kiro.modeId)
  end)

  h.it("does not set a default mode when resuming (load keeps its own)", function()
    local meta = Kiro.build_session_meta({ kiro_cli = { mode = "x" } }, "load")
    h.is_nil(meta)
  end)

  h.it("returns nil when no mode is configured", function()
    h.is_nil(Kiro.build_session_meta({ kiro_cli = {} }, "new"))
    h.is_nil(Kiro.build_session_meta({}, "new"))
    h.is_nil(Kiro.build_session_meta({ kiro_cli = { mode = "" } }, "new"))
  end)
end)

-- ── transform_update ────────────────────────────────────────────
-- Normalises kiro's `_meta.kiro` onto the generic fields the core integration
-- understands, and drops the empty replay boundary chunk. Verified against the
-- shapes kiro-cli 2.31.1 emits on the wire.

h.describe("kiro-cli transform_update", function()
  h.it("lifts failureReason onto the generic field", function()
    local u = { sessionUpdate = "tool_call_update", status = "failed", _meta = { kiro = { failureReason = "denied" } } }
    transform(u)
    h.eq("denied", u.failure_reason)
  end)

  h.it("marks replayed updates", function()
    local u = { sessionUpdate = "agent_message_chunk", _meta = { kiro = { replay = true } } }
    transform(u)
    h.eq(true, u.replay)
  end)

  h.it("lifts the agent message id onto a generic field (for rewind targeting)", function()
    local u = {
      sessionUpdate = "user_message_chunk",
      content = { type = "text", text = "hi" },
      _meta = { kiro = { replay = true, messageId = "msg-7" } },
    }
    transform(u)
    h.eq("msg-7", u.provider_message_id)
  end)

  h.it("never points an agent-subtask tool at itself", function()
    local u = {
      sessionUpdate = "tool_call",
      toolCallId = "subtask-1",
      _meta = { kiro = { kind = "agent-subtask", agentSubtaskId = "subtask-1" } },
    }
    transform(u)
    h.is_nil(u.parent_tool_call_id)
  end)

  h.it("nests a child tool call under its subtask", function()
    local u = {
      sessionUpdate = "tool_call",
      toolCallId = "call-9",
      _meta = { kiro = { agentSubtaskId = "subtask-1" } },
    }
    transform(u)
    h.eq("subtask-1", u.parent_tool_call_id)
  end)

  h.it("drops the empty replay boundary user_message_chunk", function()
    local empty = { sessionUpdate = "user_message_chunk", _meta = { kiro = { replay = true } } }
    h.eq(false, transform(empty), "a content-less user chunk is dropped")
    local blank = { sessionUpdate = "user_message_chunk", content = { type = "text", text = "" } }
    h.eq(false, transform(blank))
  end)

  h.it("keeps a real replayed user message", function()
    local u = {
      sessionUpdate = "user_message_chunk",
      content = { type = "text", text = "hello" },
      _meta = { kiro = { replay = true } },
    }
    h.is_nil(transform(u), "a real user message is not dropped")
    h.eq(true, u.replay)
  end)

  h.it("is inert on updates with no kiro meta", function()
    local u = { sessionUpdate = "tool_call", toolCallId = "t" }
    h.is_nil(transform(u))
    h.is_nil(u.failure_reason)
    h.is_nil(u.replay)
  end)
end)
