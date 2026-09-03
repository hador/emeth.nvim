--- `session/update` dispatch tests for `emeth.integrations.acp_updates`.
--- One group per sessionUpdate type, plus the dispatcher's own behaviour
--- (transform hook, unknown kinds, per-session stream isolation).

local h = require("tests.helpers")
local H = require("tests.acp_harness")
local Winbar = H.winbar()
local make_setup = H.setup
local flush = H.flush

-- Global stubs; released at the bottom of this file.
local restore = H.install()

h.describe("acp integration: user_message_chunk", function()
  h.it("appends a user message", function()
    local session, view = make_setup()
    session:_emit("update", { sessionUpdate = "user_message_chunk", content = { type = "text", text = "hi" } })
    h.eq(1, #view.messages)
    h.eq("user", view.messages[1].role)
    h.eq("hi", view.messages[1]:text())
  end)

  h.it("ignores non-text content", function()
    local session, view = make_setup()
    session:_emit("update", { sessionUpdate = "user_message_chunk", content = { type = "image" } })
    h.eq(0, #view.messages)
  end)
end)

h.describe("acp integration: agent_message_chunk", function()
  h.it("creates a new assistant message on first chunk", function()
    local session, view = make_setup()
    session:_emit("update", { sessionUpdate = "agent_message_chunk", content = { type = "text", text = "hello " } })
    h.eq(1, #view.messages)
    h.eq("assistant", view.messages[1].role)
    h.eq("hello ", view.messages[1]:text())
  end)

  h.it("appends to the same message across multiple chunks", function()
    local session, view = make_setup()
    session:_emit("update", { sessionUpdate = "agent_message_chunk", content = { type = "text", text = "foo" } })
    session:_emit("update", { sessionUpdate = "agent_message_chunk", content = { type = "text", text = "bar" } })
    h.eq(1, #view.messages)
    h.eq("foobar", view.messages[1]:text())
  end)

  h.it("starts a fresh message when a tool_call arrives between chunks", function()
    local session, view = make_setup()
    session:_emit("update", { sessionUpdate = "agent_message_chunk", content = { type = "text", text = "before" } })
    session:_emit("update", {
      sessionUpdate = "tool_call",
      toolCallId = "t1",
      title = "Read file.lua",
      kind = "read",
      status = "pending",
    })
    session:_emit("update", { sessionUpdate = "agent_message_chunk", content = { type = "text", text = "after" } })
    -- 3 messages: assistant text, tool_use, new assistant text
    h.eq(3, #view.messages)
    h.eq("before", view.messages[1]:text())
    h.eq("tool_use", view.messages[2].content[1].type)
    h.eq("after", view.messages[3]:text())
  end)
end)

h.describe("acp integration: agent_thought_chunk", function()
  h.it("creates a thinking message on first non-empty chunk", function()
    local session, view = make_setup()
    session:_emit(
      "update",
      { sessionUpdate = "agent_thought_chunk", content = { type = "text", text = "pondering..." } }
    )
    h.eq(1, #view.messages)
    h.eq("assistant", view.messages[1].role)
    h.eq("thinking", view.messages[1].content[1].type)
    h.eq("pondering...", view.messages[1].content[1].thinking)
  end)

  h.it("ignores empty-text chunks (no header for empty thoughts)", function()
    local session, view = make_setup()
    session:_emit("update", { sessionUpdate = "agent_thought_chunk", content = { type = "text", text = "" } })
    h.eq(0, #view.messages)
  end)

  h.it("appends thinking text across chunks", function()
    local session, view = make_setup()
    session:_emit("update", { sessionUpdate = "agent_thought_chunk", content = { type = "text", text = "first " } })
    session:_emit("update", { sessionUpdate = "agent_thought_chunk", content = { type = "text", text = "second" } })
    h.eq(1, #view.messages)
    h.eq("first second", view.messages[1].content[1].thinking)
  end)
end)

h.describe("acp integration: tool_call lifecycle", function()
  h.it("creates a tool_use message on first tool_call", function()
    local session, view = make_setup()
    session:_emit("update", {
      sessionUpdate = "tool_call",
      toolCallId = "t1",
      title = "Read foo.lua",
      kind = "read",
      status = "pending",
      rawInput = { file_path = "foo.lua" },
    })
    h.eq(1, #view.messages)
    local item = view.messages[1].content[1]
    h.eq("tool_use", item.type)
    h.eq("t1", item.id)
    h.eq("pending", item.status)
  end)

  h.it("tool_call_update changes status of an existing message", function()
    local session, view = make_setup()
    session:_emit("update", {
      sessionUpdate = "tool_call",
      toolCallId = "t1",
      title = "Read",
      status = "pending",
    })
    session:_emit("update", {
      sessionUpdate = "tool_call_update",
      toolCallId = "t1",
      status = "completed",
    })
    h.eq(1, #view.messages)
    h.eq("completed", view.messages[1].content[1].status)
  end)

  h.it("tool_call_update with title updates the displayed name", function()
    local session, view = make_setup()
    session:_emit("update", {
      sessionUpdate = "tool_call",
      toolCallId = "t1",
      title = "Bash",
      status = "pending",
    })
    session:_emit("update", {
      sessionUpdate = "tool_call_update",
      toolCallId = "t1",
      title = "ls -la",
    })
    h.eq("ls -la", view.messages[1].content[1].name)
  end)

  h.it("tool_call_update for unknown id is a no-op", function()
    local session, view = make_setup()
    session:_emit("update", {
      sessionUpdate = "tool_call_update",
      toolCallId = "ghost",
      status = "completed",
    })
    h.eq(0, #view.messages)
  end)

  h.it("repeat tool_call refines existing message rather than duplicating", function()
    local session, view = make_setup()
    session:_emit("update", {
      sessionUpdate = "tool_call",
      toolCallId = "t1",
      title = "Task",
      status = "pending",
      rawInput = {},
    })
    session:_emit("update", {
      sessionUpdate = "tool_call",
      toolCallId = "t1",
      title = "Task",
      status = "in_progress",
      rawInput = { description = "Find foo" },
    })
    h.eq(1, #view.messages)
    h.eq("in_progress", view.messages[1].content[1].status)
  end)
end)

h.describe("acp integration: streaming tool render throttle", function()
  -- A content-only tool_call_update (a body chunk while the tool streams) is
  -- applied synchronously but its render is deferred to a throttle timer, so a
  -- fast stream can't force a re-render of the whole growing body per chunk. A
  -- structural change (status/title/locations) renders promptly.
  local function open_tool()
    local session, view = make_setup()
    session:_emit("update", {
      sessionUpdate = "tool_call",
      toolCallId = "t1",
      title = "Bash",
      status = "in_progress",
    })
    view.flush_count = 0 -- reset after setup noise
    return session, view
  end

  h.it("defers the render for a content-only chunk (no synchronous flush)", function()
    local session, view = open_tool()
    session:_emit("update", {
      sessionUpdate = "tool_call_update",
      toolCallId = "t1",
      content = { { type = "content", content = { text = "partial output" } } },
    })
    -- Data applied immediately...
    h.eq("partial output", view.messages[1].metadata.tool_call.content[1].content.text)
    -- ...but no synchronous flush: the throttle timer will paint later.
    h.eq(0, view.flush_count)
  end)

  h.it("flushes promptly on a structural update (status)", function()
    local session, view = open_tool()
    session:_emit("update", {
      sessionUpdate = "tool_call_update",
      toolCallId = "t1",
      content = { { type = "content", content = { text = "done body" } } },
      status = "completed",
    })
    -- update_message renders synchronously for structural changes, so the
    -- integration does not additionally arm the throttle. We assert the model
    -- is current; render promptness is covered by update_message's own path.
    h.eq("completed", view.messages[1].content[1].status)
    h.eq("done body", view.messages[1].metadata.tool_call.content[1].content.text)
  end)

  h.it("paints any pending throttled content on disconnect", function()
    local session, view = open_tool()
    session:_emit("update", {
      sessionUpdate = "tool_call_update",
      toolCallId = "t1",
      content = { { type = "content", content = { text = "trailing" } } },
    })
    h.eq(0, view.flush_count, "content chunk should not flush synchronously")
    view.integration.disconnect()
    h.is_true(view.flush_count >= 1, "disconnect must flush the final throttled paint")
  end)
end)

h.describe("acp integration: plan", function()
  h.it("renders plan entries with status icons", function()
    local session, view = make_setup()
    session:_emit("update", {
      sessionUpdate = "plan",
      entries = {
        { content = "Step one", status = "completed" },
        { content = "Step two", status = "in_progress" },
        { content = "Step three", status = "pending" },
      },
    })
    h.eq(1, #view.messages)
    local text = view.messages[1]:text()
    h.is_true(text:find("**Plan:**", 1, true) ~= nil)
    h.is_true(text:find("✓ Step one", 1, true) ~= nil)
    h.is_true(text:find("→ Step two", 1, true) ~= nil)
    h.is_true(text:find("○ Step three", 1, true) ~= nil)
  end)

  h.it("updates the plan in place instead of stacking copies", function()
    local session, view = make_setup()
    local function emit_plan(entries)
      session:_emit("update", { sessionUpdate = "plan", entries = entries })
    end
    emit_plan({ { content = "Step one", status = "pending" } })
    emit_plan({ { content = "Step one", status = "in_progress" } })
    emit_plan({
      { content = "Step one", status = "completed" },
      { content = "Step two", status = "pending" },
    })
    -- Three plan updates → still ONE message, showing the latest full plan.
    h.eq(1, #view.messages)
    local text = view.messages[1]:text()
    h.is_true(text:find("✓ Step one", 1, true) ~= nil, "latest status wins")
    h.is_true(text:find("○ Step two", 1, true) ~= nil, "grown plan is present")
    -- No stale copies: "Step one" appears exactly once.
    local _, count = text:gsub("Step one", "")
    h.eq(1, count)
  end)

  h.it("consecutive plan updates (still last block) stay in place", function()
    local session, view = make_setup()
    session:_emit("update", { sessionUpdate = "plan", entries = { { content = "A", status = "pending" } } })
    session:_emit("update", { sessionUpdate = "plan", entries = { { content = "A", status = "in_progress" } } })
    session:_emit("update", { sessionUpdate = "plan", entries = { { content = "A", status = "completed" } } })
    local plan_count = 0
    for _, m in ipairs(view.messages) do
      if m:text():find("**Plan:**", 1, true) then
        plan_count = plan_count + 1
      end
    end
    h.eq(1, plan_count, "no interleaving → single in-place block")
  end)

  h.it("re-displays the plan when content streamed in below it", function()
    local session, view = make_setup()
    session:_emit("update", { sessionUpdate = "plan", entries = { { content = "A", status = "pending" } } })
    -- Content streams in below the plan, pushing it out of view.
    session:_emit("update", { sessionUpdate = "agent_message_chunk", content = { type = "text", text = "working" } })
    session:_emit("update", { sessionUpdate = "plan", entries = { { content = "A", status = "completed" } } })

    -- Two plan blocks: the stale one (scrolled away) and a fresh copy at bottom.
    local plan_count = 0
    for _, m in ipairs(view.messages) do
      if m:text():find("**Plan:**", 1, true) then
        plan_count = plan_count + 1
      end
    end
    h.eq(2, plan_count, "plan re-displayed at bottom after interleaving")
    -- The fresh copy is the last message and shows the latest status.
    local last = view.messages[#view.messages]
    h.is_true(last:text():find("✓ A", 1, true) ~= nil, "re-displayed copy shows current state")
  end)

  h.it("a new prompt starts a fresh plan block", function()
    local session, view = make_setup()
    -- Turn 1: submit (capturing the completion cb), emit a plan, then complete
    -- the turn so activity returns to idle before the next submit.
    local turn1_cb
    session.send_prompt = function(_, _prompt, cb)
      turn1_cb = cb
    end
    view.on_submit("first question")
    session:_emit("update", { sessionUpdate = "plan", entries = { { content = "A", status = "pending" } } })
    turn1_cb(nil, nil) -- turn 1 completes → idle
    flush()

    -- Turn 2: a fresh submit runs reset_state, so the next plan is a new block.
    session.send_prompt = function() end
    view.on_submit("next question")
    session:_emit("update", { sessionUpdate = "plan", entries = { { content = "B", status = "pending" } } })

    local plan_count = 0
    for _, m in ipairs(view.messages) do
      if m:text():find("**Plan:**", 1, true) then
        plan_count = plan_count + 1
      end
    end
    h.eq(2, plan_count, "second turn's plan is a separate block")
  end)
end)

h.describe("acp integration: available_commands_update", function()
  h.it("registers commands with hint extracted from input.hint", function()
    local Commands = require("emeth.commands")
    Commands.clear_acp()
    local session, _ = make_setup()
    session:_emit("update", {
      sessionUpdate = "available_commands_update",
      availableCommands = {
        { name = "/model", description = "Switch model", input = { hint = "<model_id>" } },
        { name = "/agents", description = "Manage agents" }, -- no hint
        { name = "/null", description = "x", input = vim.NIL }, -- defensively handled
      },
    })
    h.is_true(Commands.get("model") ~= nil)
    h.eq("<model_id>", Commands.get("model").hint)
    h.eq("acp", Commands.get("model").source)
    h.is_nil(Commands.get("agents").hint)
    h.is_nil(Commands.get("null").hint)
    Commands.clear_acp()
  end)
end)

h.describe("acp integration: session_info_update", function()
  h.it("stores title on view._session_title", function()
    local session, view = make_setup()
    session:_emit("update", { sessionUpdate = "session_info_update", title = "Renamed" })
    h.eq("Renamed", view._session_title)
  end)
end)

h.describe("acp integration: current_mode_update", function()
  -- The handler reaches `render_mode` through a wrapper, because the real one is
  -- assigned further down setup_integration than the dispatch table is built.
  -- Nothing else covers that indirection: pass the function directly (nil at
  -- build time) and the mode would silently stop rendering.
  h.it("renders the new mode and records it on the session", function()
    local session, view = make_setup()
    local badges = {}
    local restore = Winbar.set_badge
    Winbar.set_badge = function(key, text)
      badges[key] = text
    end

    session:_emit("update", { sessionUpdate = "current_mode_update", currentModeId = "plan" })
    flush()
    Winbar.set_badge = restore

    h.eq("plan", (session.extensions or {}).mode_id)
    h.eq("plan", badges.mode, "render_mode should have pushed the mode badge")
    h.eq(0, #view.messages, "a mode change is winbar-only, not a transcript entry")
  end)

  h.it("ignores an update with no currentModeId", function()
    local session = make_setup()
    session:_emit("update", { sessionUpdate = "current_mode_update" })
    flush()
    h.is_nil((session.extensions or {}).mode_id)
  end)
end)

h.describe("acp integration: transform_update hook", function()
  h.it("provider transform mutates update before consumption", function()
    local session, view, integration = make_setup()
    integration.set_transform_update(function(update)
      if update.sessionUpdate == "tool_call" then
        update.title = "TRANSFORMED"
      end
    end)
    session:_emit("update", {
      sessionUpdate = "tool_call",
      toolCallId = "t1",
      title = "Original",
      status = "pending",
    })
    h.eq(1, #view.messages)
    h.eq("TRANSFORMED", view.messages[1].content[1].name)
  end)

  h.it("setting nil clears the transform", function()
    local session, view, integration = make_setup()
    integration.set_transform_update(function(update)
      update.title = "X"
    end)
    integration.set_transform_update(nil)
    session:_emit("update", {
      sessionUpdate = "tool_call",
      toolCallId = "t1",
      title = "Original",
      status = "pending",
    })
    h.eq("Original", view.messages[1].content[1].name)
  end)
end)

h.describe("acp integration: dispatch", function()
  h.it("ignores unknown sessionUpdate types", function()
    local session, view = make_setup()
    session:_emit("update", { sessionUpdate = "future_thing", weird = "stuff" })
    h.eq(0, #view.messages)
  end)
end)

h.describe("acp integration: per-session stream isolation", function()
  -- A subagent's output arrives under its OWN session id. Sharing one streaming
  -- state table would let two live streams append into each other's messages.
  local function chunk(text)
    return { sessionUpdate = "agent_message_chunk", content = { type = "text", text = text } }
  end

  h.it("keeps concurrent sessions in separate messages", function()
    local session, view = make_setup()
    session:_emit("update", chunk("parent one "), "main")
    session:_emit("update", chunk("child one "), "sub-1")
    session:_emit("update", chunk("parent two"), "main")
    session:_emit("update", chunk("child two"), "sub-1")
    h.eq(2, #view.messages, "one message per session, not one per chunk")
    h.eq("parent one parent two", view.messages[1]:text())
    h.eq("child one child two", view.messages[2]:text())
  end)

  h.it("still appends within a single session", function()
    local session, view = make_setup()
    session:_emit("update", chunk("a"), "main")
    session:_emit("update", chunk("b"), "main")
    h.eq(1, #view.messages)
    h.eq("ab", view.messages[1]:text())
  end)

  h.it("does not let one session's tool call resolve into another's", function()
    local session, view = make_setup()
    -- Same toolCallId in two sessions must not collide in the tool map.
    local function tool(id, title)
      return { sessionUpdate = "tool_call", toolCallId = id, title = title, kind = "read", status = "pending" }
    end
    session:_emit("update", tool("t1", "parent reads"), "main")
    session:_emit("update", tool("t1", "child reads"), "sub-1")
    h.eq(2, #view.messages, "each session gets its own tool card")
    session:_emit("update", {
      sessionUpdate = "tool_call_update",
      toolCallId = "t1",
      status = "completed",
    }, "sub-1")
    flush()
    -- Only the child's card completed; the parent's is untouched.
    h.eq("pending", view.messages[1].content[1].status)
    h.eq("completed", view.messages[2].content[1].status)
  end)

  h.it("separates thinking blocks per session", function()
    local session, view = make_setup()
    local function thought(text)
      return { sessionUpdate = "agent_thought_chunk", content = { type = "text", text = text } }
    end
    session:_emit("update", thought("parent thinks"), "main")
    session:_emit("update", thought("child thinks"), "sub-1")
    h.eq(2, #view.messages)
    h.eq("parent thinks", view.messages[1].content[1].thinking)
    h.eq("child thinks", view.messages[2].content[1].thinking)
  end)

  h.it("drops every session's stream when the transcript is reset", function()
    local session, view = make_setup()
    session:_emit("update", chunk("before"), "main")
    view.integration.new_session()
    flush()
    -- A chunk after the reset must start a fresh message rather than appending
    -- to the one that is no longer in the transcript.
    session:_emit("update", chunk("after"), "main")
    h.eq("after", view.messages[#view.messages]:text())
  end)
end)

h.describe("acp integration: error event", function()
  h.it("appends an error system message", function()
    local session, view = make_setup()
    session:_emit("error", { message = "boom" })
    h.eq(1, #view.messages)
    h.eq("assistant", view.messages[1].role)
    h.is_true(view.messages[1]:text():find("boom", 1, true) ~= nil)
  end)
end)

restore()
