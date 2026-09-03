--- Subagent tests: a subagent's tool calls fold under the tool that spawned
--- them, driven by the generic `parent_tool_call_id` a provider transform sets.

local h = require("tests.helpers")
local H = require("tests.acp_harness")
local make_setup = H.setup
local flush = H.flush

-- Global stubs; released at the bottom of this file.
local restore = H.install()

h.describe("acp integration: subagent tool nesting", function()
  local CC = require("emeth.integrations.claude-code")

  -- Payload shapes taken from real claude-acp 0.73 traffic: the spawning tool is
  -- `Agent`, titled "Task" until its rawInput lands, and everything it runs
  -- carries parentToolUseId on the SAME session.
  local PARENT_ID = "toolu_parent"

  local function parent_call()
    return {
      sessionUpdate = "tool_call",
      toolCallId = PARENT_ID,
      title = "Task",
      kind = "think",
      status = "pending",
      rawInput = {},
      _meta = { claudeCode = { subagent = true, toolName = "Agent" } },
    }
  end

  local function child_call(id, title)
    return {
      sessionUpdate = "tool_call",
      toolCallId = id,
      title = title,
      kind = "execute",
      status = "pending",
      _meta = { claudeCode = { parentToolUseId = PARENT_ID, toolName = "Bash", title = title } },
    }
  end

  --- Emit through the provider transform, as the real dispatch does.
  local function emit(session, update)
    CC._transform_update(update)
    session:_emit("update", update, "main")
  end

  h.it("hides a subagent's calls under the tool that spawned it", function()
    local session, view = make_setup()
    emit(session, parent_call())
    emit(session, child_call("t1", "grep -r foo"))
    emit(session, child_call("t2", "ls"))
    h.eq(3, #view.messages, "children still exist as messages")
    h.eq(true, view.messages[1].visible ~= false, "the spawning tool stays visible")
    h.eq(false, view.messages[2].visible, "children are collapsed by default")
    h.eq(false, view.messages[3].visible)
  end)

  h.it("counts the nested calls on the parent", function()
    local session, view = make_setup()
    emit(session, parent_call())
    emit(session, child_call("t1", "a"))
    emit(session, child_call("t2", "b"))
    h.eq(2, view.messages[1].metadata.subagent_children)
  end)

  h.it("expanding the parent reveals its children, and collapsing hides them", function()
    local session, view = make_setup()
    emit(session, parent_call())
    emit(session, child_call("t1", "a"))
    local parent = view.messages[1]
    h.is_true(type(parent.metadata.on_expand) == "function", "parent must carry the K hook")

    parent.metadata.on_expand(parent)
    h.eq(true, view.messages[2].visible)
    parent.metadata.on_expand(parent)
    h.eq(false, view.messages[2].visible)
  end)

  h.it("shows a child that arrives while the parent is already expanded", function()
    local session, view = make_setup()
    emit(session, parent_call())
    emit(session, child_call("t1", "a"))
    local parent = view.messages[1]
    parent.metadata.on_expand(parent) -- expand
    emit(session, child_call("t2", "b"))
    h.eq(true, view.messages[3].visible, "a later child must not be hidden")
  end)

  h.it("leaves ordinary tool calls at top level", function()
    local session, view = make_setup()
    emit(session, {
      sessionUpdate = "tool_call",
      toolCallId = "plain",
      title = "Read x.lua",
      kind = "read",
      status = "pending",
    })
    h.eq(1, #view.messages)
    h.is_true(view.messages[1].visible ~= false)
    h.is_nil(view.messages[1].metadata.parent_tool_call_id)
    h.is_nil(view.messages[1].metadata.on_expand)
  end)

  -- The parent tool_call can be missing (a reconnect, or a transform that did not
  -- run). Nesting under nothing would hide the child forever.
  h.it("keeps a child visible when its parent is unknown", function()
    local session, view = make_setup()
    emit(session, child_call("orphan", "grep"))
    h.eq(1, #view.messages)
    h.is_true(view.messages[1].visible ~= false, "an orphan must not be invisible")
    h.is_nil(view.messages[1].metadata.parent_tool_call_id)
  end)

  h.it("still updates a hidden child's status", function()
    local session, view = make_setup()
    emit(session, parent_call())
    emit(session, child_call("t1", "a"))
    session:_emit("update", { sessionUpdate = "tool_call_update", toolCallId = "t1", status = "completed" }, "main")
    flush()
    h.eq("completed", view.messages[2].content[1].status)
  end)
end)

restore()
