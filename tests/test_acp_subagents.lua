--- Subagent tests: a subagent's tool calls fold under the tool that spawned
--- them, driven by the generic `parent_tool_call_id` a provider transform sets.

local h = require("tests.helpers")
local H = require("tests.acp_harness")
local Winbar = H.winbar()
local make_setup = H.setup
local flush = H.flush

-- Global stubs; released at the bottom of this file.
local restore = H.install()

-- Payload shapes taken from real claude-acp 0.94 traffic with
-- `clientCapabilities.subagents` advertised: the spawning tool is `Agent` on the
-- main session, titled "Task" until its rawInput lands; `subagent_update`
-- announces the child session; everything the child runs arrives under the
-- child's session id and carries parentToolUseId.
local MAIN = "sess-1"
local CHILD = "child-1"
local PARENT_ID = "toolu_parent"

local CC = require("emeth.integrations.claude-code")

local function parent_call()
  return {
    sessionUpdate = "tool_call",
    toolCallId = PARENT_ID,
    title = "Task",
    kind = "think",
    status = "pending",
    rawInput = {},
    _meta = { claudeCode = { toolName = "Agent" } },
  }
end

local function announce(child)
  return {
    sessionUpdate = "subagent_update",
    sessionId = child or CHILD,
    title = "general-purpose",
    description = "Run two echo commands",
    capabilities = { cancel = vim.empty_dict() },
    state = { state = "running" },
  }
end

local function child_call(id, title, tool_name)
  return {
    sessionUpdate = "tool_call",
    toolCallId = id,
    title = title,
    kind = "execute",
    status = "pending",
    _meta = { claudeCode = { parentToolUseId = PARENT_ID, toolName = tool_name or "Bash" } },
  }
end

--- Emit through the provider transform, as the real dispatch does.
local function emit(session, update, session_id)
  if CC._transform_update(update) == false then
    return
  end
  session:_emit("update", update, session_id)
end

--- A parent Agent call on the main session with its child announced.
local function spawn(session)
  emit(session, parent_call(), MAIN)
  emit(session, announce(), MAIN)
end

h.describe("acp integration: subagent tool nesting", function()
  h.it("hides a subagent's calls under the tool that spawned it", function()
    local session, view = make_setup()
    spawn(session)
    emit(session, child_call("t1", "grep -r foo"), CHILD)
    emit(session, child_call("t2", "ls"), CHILD)
    h.eq(3, #view.messages, "children still exist as messages")
    h.eq(true, view.messages[1].visible ~= false, "the spawning tool stays visible")
    h.eq(false, view.messages[2].visible, "children are collapsed by default")
    h.eq(false, view.messages[3].visible)
  end)

  h.it("counts the nested calls on the parent", function()
    local session, view = make_setup()
    spawn(session)
    emit(session, child_call("t1", "a"), CHILD)
    emit(session, child_call("t2", "b"), CHILD)
    h.eq(2, view.messages[1].metadata.subagent_children)
  end)

  h.it("expanding the parent reveals its children, and collapsing hides them", function()
    local session, view = make_setup()
    spawn(session)
    emit(session, child_call("t1", "a"), CHILD)
    local parent = view.messages[1]
    h.is_true(type(parent.metadata.on_expand) == "function", "parent must carry the K hook")

    parent.metadata.on_expand(parent)
    h.eq(true, view.messages[2].visible)
    parent.metadata.on_expand(parent)
    h.eq(false, view.messages[2].visible)
  end)

  h.it("shows a child that arrives while the parent is already expanded", function()
    local session, view = make_setup()
    spawn(session)
    emit(session, child_call("t1", "a"), CHILD)
    local parent = view.messages[1]
    parent.metadata.on_expand(parent) -- expand
    emit(session, child_call("t2", "b"), CHILD)
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
    }, MAIN)
    h.eq(1, #view.messages)
    h.is_true(view.messages[1].visible ~= false)
    h.is_nil(view.messages[1].metadata.parent_tool_call_id)
    h.is_nil(view.messages[1].metadata.on_expand)
  end)

  -- The parent tool_call can be missing (a reconnect, or a transform that did not
  -- run). Nesting under nothing would hide the child forever.
  h.it("keeps a child visible when its parent is unknown", function()
    local session, view = make_setup()
    emit(session, announce(), MAIN)
    emit(session, child_call("orphan", "grep"), CHILD)
    h.eq(1, #view.messages)
    h.is_true(view.messages[1].visible ~= false, "an orphan must not be invisible")
    h.is_nil(view.messages[1].metadata.parent_tool_call_id)
  end)

  h.it("still updates a hidden child's status", function()
    local session, view = make_setup()
    spawn(session)
    emit(session, child_call("t1", "a"), CHILD)
    session:_emit("update", { sessionUpdate = "tool_call_update", toolCallId = "t1", status = "completed" }, CHILD)
    flush()
    h.eq("completed", view.messages[2].content[1].status)
  end)

  h.it("drops the subagent's handback tool", function()
    local session, view = make_setup()
    spawn(session)
    emit(session, child_call("t1", "a"), CHILD)
    emit(session, child_call("hb", "SubagentHandback", "SubagentHandback"), CHILD)
    h.eq(2, #view.messages, "the handback is plumbing, not a nested call")
    h.eq(1, view.messages[1].metadata.subagent_children)
  end)
end)

h.describe("acp integration: subagent sessions", function()
  local function chunk(kind, text)
    return { sessionUpdate = kind, content = { type = "text", text = text } }
  end

  h.it("keeps a subagent's prose out of the transcript", function()
    local session, view = make_setup()
    spawn(session)
    emit(session, chunk("agent_thought_chunk", "`echo one` ran cleanly"), CHILD)
    emit(session, chunk("agent_message_chunk", "child says hi"), CHILD)
    emit(session, {
      sessionUpdate = "session_message",
      messageId = PARENT_ID,
      senderSessionId = MAIN,
      recipientSessionId = CHILD,
    }, CHILD)
    h.eq(1, #view.messages, "only the spawning tool call")
  end)

  h.it("keeps the main session's text streaming into one message around a subagent", function()
    local session, view = make_setup()
    emit(session, chunk("agent_message_chunk", "before "), MAIN)
    emit(session, announce(), MAIN)
    emit(session, chunk("agent_thought_chunk", "child thinks"), CHILD)
    emit(session, chunk("agent_message_chunk", "after"), MAIN)
    h.eq(1, #view.messages)
    h.eq("before after", view.messages[1]:text())
  end)

  h.it("never lets a subagent flip the winbar to generating", function()
    local session = make_setup()
    local states = {}
    local orig = Winbar.set_state
    Winbar.set_state = function(s)
      states[#states + 1] = s
    end
    emit(session, announce(), MAIN)
    emit(session, child_call("t1", "a"), CHILD)
    Winbar.set_state = orig
    h.eq(0, #states, "announcement is metadata and the child's call is not the main turn")
  end)

  h.it("does not duplicate a subagent call's card on its permission request", function()
    local session, view = make_setup()
    spawn(session)
    emit(session, child_call("t1", "rm -rf build"), CHILD)
    session:_emit("permission", { toolCallId = "t1", title = "rm -rf build" }, {
      { kind = "allow_once", name = "Yes", optionId = "allow" },
    }, function() end, CHILD)
    flush()
    local cards = 0
    for _, m in ipairs(view.messages) do
      local c = m.content[1]
      if type(c) == "table" and c.type == "tool_use" and c.id == "t1" then
        cards = cards + 1
      end
    end
    h.eq(1, cards, "the request reuses the child's existing card")
  end)

  h.it("forgets announced subagents when the transcript is reset", function()
    local session, view = make_setup()
    emit(session, announce(), MAIN)
    view.integration.new_session()
    flush()
    -- A session id reused after the reset is no longer a known child, so its
    -- text renders like any other session's.
    emit(session, chunk("agent_message_chunk", "visible"), CHILD)
    h.eq("visible", view.messages[#view.messages]:text())
  end)
end)

restore()
