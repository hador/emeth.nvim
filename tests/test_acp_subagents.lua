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

local function parent_call(id)
  return {
    sessionUpdate = "tool_call",
    toolCallId = id or PARENT_ID,
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

local function child_call(id, title, tool_name, parent_id)
  return {
    sessionUpdate = "tool_call",
    toolCallId = id,
    title = title,
    kind = "execute",
    status = "pending",
    _meta = { claudeCode = { parentToolUseId = parent_id or PARENT_ID, toolName = tool_name or "Bash" } },
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

local function chunk(kind, text)
  return { sessionUpdate = kind, content = { type = "text", text = text } }
end

local function state_update(child, state)
  return { sessionUpdate = "subagent_update", sessionId = child or CHILD, state = { state = state } }
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

  -- claude-acp turns a completed handback into session_messages and exposes
  -- the tool call only when it failed, on purpose; that failure must show.
  h.it("shows a handback tool call the agent exposed, like any child call", function()
    local session, view = make_setup()
    spawn(session)
    emit(session, child_call("t1", "a"), CHILD)
    local hb = child_call("hb", "SubagentHandback", "SubagentHandback")
    hb.status = "failed"
    emit(session, hb, CHILD)
    h.eq(3, #view.messages, "the exposed (failed) handback nests under the card")
    h.eq(2, view.messages[1].metadata.subagent_children)
  end)
end)

h.describe("acp integration: subagent placement", function()
  local function text(t)
    return { sessionUpdate = "agent_message_chunk", content = { type = "text", text = t } }
  end

  --- The transcript as a list of labels: a tool card's title, or a text body.
  local function layout(view)
    local out = {}
    for _, m in ipairs(view.messages) do
      local c = m.content[1]
      out[#out + 1] = (type(c) == "table" and c.type == "tool_use") and m.metadata.tool_call.title or m:text()
    end
    return out
  end

  h.it("keeps a subagent's calls under its parent while the main session keeps going", function()
    local session, view = make_setup()
    spawn(session)
    emit(session, child_call("t1", "first"), CHILD)
    emit(session, text("meanwhile"), MAIN)
    emit(session, child_call("t2", "second"), CHILD)
    h.eq({ "Task", "first", "second", "meanwhile" }, layout(view))
  end)

  h.it("does not split the main session's text around a subagent's call", function()
    local session, view = make_setup()
    spawn(session)
    emit(session, text("one "), MAIN)
    emit(session, child_call("t1", "child"), CHILD)
    emit(session, text("two"), MAIN)
    h.eq({ "Task", "child", "one two" }, layout(view))
  end)

  h.it("keeps parallel subagents' calls with their own parents", function()
    local session, view = make_setup()
    emit(session, parent_call("p1"), MAIN)
    emit(session, announce("c1"), MAIN)
    emit(session, parent_call("p2"), MAIN)
    emit(session, announce("c2"), MAIN)
    emit(session, child_call("a1", "a1", nil, "p1"), "c1")
    emit(session, child_call("b1", "b1", nil, "p2"), "c2")
    emit(session, child_call("a2", "a2", nil, "p1"), "c1")
    h.eq({ "Task", "a1", "a2", "Task", "b1" }, layout(view))
  end)
end)

h.describe("acp integration: subagent sessions", function()
  local function launch_message(child, parent_id, text)
    return {
      sessionUpdate = "session_message",
      messageId = parent_id or PARENT_ID,
      senderSessionId = MAIN,
      recipientSessionId = child or CHILD,
      content = { { type = "text", text = text or "do the thing" } },
    }
  end

  h.it("keeps a subagent's prose and launch message out of the transcript", function()
    local session, view = make_setup()
    spawn(session)
    emit(session, chunk("agent_thought_chunk", "`echo one` ran cleanly"), CHILD)
    emit(session, chunk("agent_message_chunk", "child says hi"), CHILD)
    emit(session, launch_message(), CHILD)
    h.eq(1, #view.messages, "only the spawning tool call")
  end)

  h.it("puts the subagent's launch prompt on its parent card", function()
    local session, view = make_setup()
    spawn(session)
    emit(session, launch_message(CHILD, PARENT_ID, "investigate the crash"), CHILD)
    h.eq("investigate the crash", view.messages[1].metadata.subagent_prompt)
  end)

  -- A subagent with no spawning Agent/Task tool_call is announced only by
  -- subagent_update; its launch message names a call that has no card. emeth
  -- synthesizes a stand-in card from the announcement so the subagent's work
  -- nests instead of spilling onto the main transcript. Since claude-acp ~0.95
  -- hides the Agent/Task launch tool_call, this is now the path for EVERY
  -- subagent, not just background ones.
  h.it("synthesizes a card for a subagent with no spawning tool_call", function()
    local session, view = make_setup()
    emit(session, announce(), MAIN) -- carries description + subagent_type, no Agent tool_call
    emit(session, launch_message(CHILD, "no-such-call", "dig into the logs"), CHILD)
    h.eq(1, #view.messages, "a stand-in card is created from the announcement")
    local card = view.messages[1]
    h.eq("tool_use", card.content[1].type)
    -- The hidden launch means no enriched tool_call title ever arrives, so the
    -- card is labelled from the announcement: its human `description`, with the
    -- `subagent_type` (its `title`) appended -- never the bare, indistinguishable
    -- subagent_type alone.
    h.eq("Run two echo commands ⊳ general-purpose", card.metadata.tool_call.title, "titled from the announcement")
    h.eq("dig into the logs", card.metadata.subagent_prompt, "its prompt is the launch message")
    -- A child call naming that launch now nests under the synthesized card.
    emit(session, child_call("c1", "grep logs", "Bash", "no-such-call"), CHILD)
    h.eq(2, #view.messages)
    h.eq(false, view.messages[2].visible, "the child folds under the synthesized card")
    h.eq(1, card.metadata.subagent_children)
  end)

  -- Fix for claude-acp ~0.95 hiding the launch tool_call: the synthesized card
  -- must close the in-flight text block, exactly as a visible top-level tool_call
  -- used to. Otherwise every later assistant message keeps extending the
  -- pre-spawn prose block and the card is stranded at the tail below a growing
  -- wall of text. The card has to stay at the spawn point: prose before it above,
  -- prose after it in a fresh message below.
  h.it("anchors a synthesized card at the spawn point, not the tail", function()
    local session, view = make_setup()
    emit(session, chunk("agent_message_chunk", "before spawn"), MAIN)
    emit(session, announce(), MAIN)
    emit(session, launch_message(CHILD, "no-such-call", "do the thing"), CHILD)
    emit(session, chunk("agent_message_chunk", "after spawn"), MAIN)
    h.eq(3, #view.messages, "prose does not merge across the card")
    h.eq("before spawn", view.messages[1]:text(), "pre-spawn prose stays above the card")
    h.eq("tool_use", view.messages[2].content[1].type, "the card sits at the spawn point")
    h.eq("after spawn", view.messages[3]:text(), "post-spawn prose starts a fresh message below")
  end)

  -- Guard the title fallback: an announcement with no description must still
  -- label the card with the subagent_type, never regress to a bare "subagent".
  h.it("falls back to the subagent_type when the announcement has no description", function()
    local session, view = make_setup()
    emit(
      session,
      { sessionUpdate = "subagent_update", sessionId = CHILD, title = "general-purpose", state = { state = "running" } },
      MAIN
    )
    emit(session, launch_message(CHILD, "no-such-call", "dig in"), CHILD)
    h.eq("general-purpose", view.messages[1].metadata.tool_call.title)
  end)

  -- A subagent that pauses and is resumed by the main agent's SendMessage gets
  -- a second session_message whose messageId is the SendMessage call, not the
  -- spawning Agent call. The card binding must not move onto that row, or the
  -- subagent's closing state lands there and the real card stays stuck running.
  h.it("keeps the card binding through a SendMessage resume", function()
    local session, view = make_setup()
    spawn(session)
    emit(session, launch_message(CHILD, PARENT_ID, "first task"), CHILD)
    emit(session, child_call("t1", "a"), CHILD)
    emit(session, state_update(CHILD, "idle"), MAIN)
    -- Main agent resumes the subagent: a SendMessage tool call on the main
    -- session, then a session_message on the child naming that call.
    emit(
      session,
      { sessionUpdate = "tool_call", toolCallId = "sendmsg-1", title = "SendMessage", status = "completed" },
      MAIN
    )
    emit(session, launch_message(CHILD, "sendmsg-1", "keep going"), CHILD)
    emit(session, state_update(CHILD, "running"), MAIN)
    emit(session, state_update(CHILD, "idle"), MAIN)
    -- The original Agent card (messages[1]) carries the final state; the
    -- SendMessage card does not, and the launch prompt is unchanged.
    h.eq("idle", view.messages[1].metadata.subagent_state, "closing state lands on the real card")
    h.eq("first task", view.messages[1].metadata.subagent_prompt, "launch prompt is not overwritten")
    for _, m in ipairs(view.messages) do
      if m.content[1] and m.content[1].id == "sendmsg-1" then
        h.is_nil(m.metadata.subagent_state, "the SendMessage row never became the subagent card")
      end
    end
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

  h.it("records the child's state on its parent card", function()
    local session, view = make_setup()
    spawn(session) -- announce carries running
    emit(session, child_call("t1", "a"), CHILD) -- binds the card
    h.eq("running", view.messages[1].metadata.subagent_state)
    emit(session, state_update(CHILD, "idle"), MAIN)
    h.eq("idle", view.messages[1].metadata.subagent_state)
  end)

  h.it("marks an idle-with-error subagent as failed", function()
    local session, view = make_setup()
    spawn(session)
    emit(session, child_call("t1", "a"), CHILD)
    emit(session, {
      sessionUpdate = "subagent_update",
      sessionId = CHILD,
      state = { state = "idle", stopReason = "error", error = "boom" },
    }, MAIN)
    h.eq("failed", view.messages[1].metadata.subagent_state)
  end)

  h.it("flushes a state seen before the card was bound", function()
    local session, view = make_setup()
    spawn(session) -- parent card exists; announce carries running, not yet bound
    emit(session, child_call("t1", "a"), CHILD) -- first call binds it
    h.eq("running", view.messages[1].metadata.subagent_state, "the pre-bind state reaches the card")
  end)

  h.it("expands the parent card when its subagent needs the user", function()
    local session, view = make_setup()
    spawn(session)
    emit(session, child_call("t1", "a"), CHILD)
    h.eq(false, view.messages[2].visible, "child starts hidden under a collapsed card")
    emit(session, state_update(CHILD, "requires_action"), MAIN)
    h.eq(true, view.messages[1].metadata._expanded, "the card auto-expands")
    h.eq(true, view.messages[2].visible, "so the request below it is visible")
  end)

  h.it("does not fight a user who already collapsed the card", function()
    local session, view = make_setup()
    spawn(session)
    emit(session, child_call("t1", "a"), CHILD)
    view.messages[1].metadata._expanded = false -- user collapsed it
    emit(session, state_update(CHILD, "requires_action"), MAIN)
    h.eq(false, view.messages[1].metadata._expanded, "a set expand state is left alone")
  end)
end)

h.describe("acp integration: cancel a subagent", function()
  -- announce() carries capabilities.cancel, so a live child is cancellable.
  local function cancel_action(view)
    return view.actions and view.actions.C
  end

  h.it("offers cancel only on a live, cancellable subagent card", function()
    local session, view = make_setup()
    local C = cancel_action(view)
    h.is_true(C ~= nil, "the C action is registered")
    spawn(session)
    emit(session, child_call("t1", "a"), CHILD)
    local card = view.messages[1]
    h.is_true(C.when(card), "a running subagent card offers cancel")
    h.is_true(not C.when(view.messages[2]), "a child tool call does not")
  end)

  h.it("hides cancel once the subagent is done", function()
    local session, view = make_setup()
    local C = cancel_action(view)
    spawn(session)
    emit(session, child_call("t1", "a"), CHILD)
    emit(session, state_update(CHILD, "idle"), MAIN)
    h.is_true(not C.when(view.messages[1]), "a finished subagent is not cancellable")
  end)

  h.it("cancels the child session, not the main turn", function()
    local session, view = make_setup()
    local cancelled
    session.cancel = function(_, id)
      cancelled = id
    end
    local C = cancel_action(view)
    spawn(session)
    emit(session, child_call("t1", "a"), CHILD)
    C.run(view.messages[1])
    h.eq(CHILD, cancelled, "cancel targets the child session id")
  end)

  h.it("does not offer cancel when the child never advertised it", function()
    local session, view = make_setup()
    local C = cancel_action(view)
    -- Announce without capabilities, then bind + run.
    emit(session, parent_call(), MAIN)
    emit(session, { sessionUpdate = "subagent_update", sessionId = CHILD, state = { state = "running" } }, MAIN)
    emit(session, child_call("t1", "a"), CHILD)
    h.is_true(not C.when(view.messages[1]), "no cancel capability, no cancel")
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

-- A subagent can spawn its own subagent. The grandchild is announced by a
-- subagent_update that arrives on the CHILD's session, so that announcement has
-- to be dispatched from a subagent session too — otherwise the grandchild is
-- never registered and its prose and tool calls leak to the main transcript.
h.describe("acp integration: nested subagents", function()
  local GRANDCHILD = "grandchild-1"
  local CHILD_AGENT = "toolu_child_agent" -- the child's Agent call that spawns the grandchild

  local function setup_nested(session)
    spawn(session) -- parent Agent call on MAIN + CHILD announced
    emit(session, child_call(CHILD_AGENT, "Delegate deeper", "Agent"), CHILD) -- child's own Agent call
    -- The child announces its grandchild, on the CHILD session.
    emit(session, {
      sessionUpdate = "subagent_update",
      sessionId = GRANDCHILD,
      capabilities = { cancel = vim.empty_dict() },
      state = { state = "running" },
    }, CHILD)
  end

  h.it("drops a grandchild's prose instead of leaking it to the main transcript", function()
    local session, view = make_setup()
    setup_nested(session)
    local before = #view.messages
    emit(session, chunk("agent_thought_chunk", "grandchild thinking"), GRANDCHILD)
    emit(session, chunk("agent_message_chunk", "grandchild says hi"), GRANDCHILD)
    h.eq(before, #view.messages, "nothing new rendered at the top level")
  end)

  h.it("nests a grandchild's tool call under the child's spawning call", function()
    local session, view = make_setup()
    setup_nested(session)
    emit(session, child_call("gc-tool", "deep grep", "Bash", CHILD_AGENT), GRANDCHILD)
    local gc
    for _, m in ipairs(view.messages) do
      if m.content[1] and m.content[1].id == "gc-tool" then
        gc = m
      end
    end
    h.is_true(gc ~= nil, "the grandchild tool call exists as a message")
    h.eq(CHILD_AGENT, gc.metadata.parent_tool_call_id, "nested under the child's Agent call")
    h.eq(false, gc.visible, "hidden under its collapsed parent, not shown at top level")
  end)
end)

restore()
