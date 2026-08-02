--- Integration-level tests for `emeth.integrations.acp`. These exercise the
--- update dispatch table by building a real `Session` (no transport spawned)
--- + a mock view, calling `setup_integration`, and emitting synthetic
--- session/update events.

local h = require("tests.helpers")

-- Initialise emeth first (registers builtins, sets config defaults), then
-- override the acp config with a fake provider for these tests.
require("emeth").setup({})
require("emeth.acp").config = {
  providers = { ["test"] = { command = "echo", args = {} } },
  auto_approve_tools = false,
}

local Session = require("emeth.acp.session")
local Acp = require("emeth.integrations.acp")

-- ── Mock view ──────────────────────────────────────────────────
-- A minimal stand-in for chat_ui.ChatView that records what would be rendered
-- without touching nvim buffers or windows.

local function make_view()
  local view = {
    messages = {},
    cleared_count = 0,
    context_files = {},
    integration = nil,
    _context_files = {},
    _mention_handlers = {},
  }

  function view:add_message(msg)
    table.insert(self.messages, msg)
  end

  function view:update_message(uuid, fn_or_msg, _opts)
    for _, m in ipairs(self.messages) do
      if m.uuid == uuid then
        if type(fn_or_msg) == "function" then
          fn_or_msg(m)
        end
        return
      end
    end
  end

  -- Streaming tool content is applied synchronously in update_message above, so
  -- the stub's flush only needs to exist (real render coalescing is a ChatView
  -- concern, tested there); the integration calls it on throttle + disconnect.
  view.flush_count = 0
  function view:flush()
    self.flush_count = self.flush_count + 1
  end

  function view:get_message(uuid)
    for _, m in ipairs(self.messages) do
      if m.uuid == uuid then
        return m
      end
    end
  end

  function view:get_messages()
    return self.messages
  end

  function view:clear()
    self.messages = {}
    self.cleared_count = self.cleared_count + 1
  end

  function view:invalidate() end

  function view:set_context_files(files)
    self.context_files = files
    self._context_files = files
  end

  function view:append_fenced(header, lines)
    self.last_fence = { header = header, lines = lines }
  end

  function view:open_file_manager() end

  -- These are touched by integration setup but we don't care about effects.
  view.result_buf = 0
  view.input_buf = 0
  return view
end

-- Stub winbar so badge calls / state flips don't hit real highlight groups.
local Winbar = package.loaded["emeth.ui.winbar"]
local _orig_winbar = {}
for _, k in ipairs({
  "set_state",
  "set_badge",
  "clear_badge",
  "set_context",
  "attach",
  "set_left",
  "set_mode_tag",
  "clear_mode_tag",
}) do
  _orig_winbar[k] = Winbar[k]
  Winbar[k] = function() end
end

-- Stub buf_set_keymap (do_cancel registers C-c in input/result bufs), but
-- record permission keymaps so tests can invoke their callbacks. Keyed by the
-- normal-mode lhs; del_keymap removes the entry.
local _orig_set_keymap = vim.api.nvim_buf_set_keymap
local _orig_del_keymap = vim.api.nvim_buf_del_keymap
local bound_keymaps = {} ---@type table<string, fun()>
vim.api.nvim_buf_set_keymap = function(_, mode, lhs, _rhs, opts)
  if mode == "n" and opts and opts.callback then
    bound_keymaps[lhs] = opts.callback
  end
end
vim.api.nvim_buf_del_keymap = function(_, mode, lhs)
  if mode == "n" then
    bound_keymaps[lhs] = nil
  end
end

--- Run pending vim.schedule callbacks (the permission handler defers to one).
local function flush()
  vim.wait(0)
end

--- Press a normal-mode key that the permission UI bound.
local function press(key)
  local cb = bound_keymaps[key]
  if cb then
    cb()
  end
  return cb ~= nil
end

-- ── Helper: build session + view + integration ─────────────────

local function make_setup()
  local session = Session:new("test")
  session._state = "ready"
  session.session_id = "sess-1"
  local view = make_view()
  local integration = Acp.setup_integration(view, session)
  return session, view, integration
end

-- ── Tests ──────────────────────────────────────────────────────

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

h.describe("acp integration: error event", function()
  h.it("appends an error system message", function()
    local session, view = make_setup()
    session:_emit("error", { message = "boom" })
    h.eq(1, #view.messages)
    h.eq("assistant", view.messages[1].role)
    h.is_true(view.messages[1]:text():find("boom", 1, true) ~= nil)
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

h.describe("acp integration: abort stuck connect", function()
  h.it("Ctrl+C during a pending handshake tears down and messages the user", function()
    local session = Session:new("test")
    local view = make_view()
    local integration = Acp.setup_integration(view, session)

    -- Simulate a handshake that never completes (e.g. a launcher running
    -- updates before it execs the agent): connect() never calls back, so
    -- activity stays "connecting".
    session.connect = function() end
    local disconnected = false
    session.disconnect = function()
      disconnected = true
    end

    integration.connect()

    -- <C-c> is bound to do_cancel; pressing it should abort the connect.
    h.is_true(press("<C-c>"), "C-c keymap should be bound")
    h.is_true(disconnected, "session should be torn down on abort")
    local last = view.messages[#view.messages]
    h.is_true(last:text():find("aborted", 1, true) ~= nil, "should report the abort to the user")
  end)

  h.it("Ctrl+C does nothing when idle and connected", function()
    local session, view = make_setup() -- _state = "ready", activity = "idle"
    local before = #view.messages
    press("<C-c>")
    h.eq(before, #view.messages)
  end)
end)

h.describe("acp integration: cancel during auto-resumed streaming", function()
  -- Reproduces: claude auto-resumes a session — session/prompt callback has
  -- fired (activity → idle), then updates start streaming again on the same
  -- session (activity → generating). Cancel must still work.
  h.it("Ctrl+C cancels when updates stream while session state is ready", function()
    local session, view = make_setup() -- _state = "ready"
    local cancelled = false
    session.cancel = function()
      cancelled = true
    end

    -- Streaming resumes with no prompt in flight.
    session:_emit("update", { sessionUpdate = "agent_message_chunk", content = { type = "text", text = "resumed" } })

    h.is_true(press("<C-c>"), "C-c keymap should be bound")
    h.is_true(cancelled, "session:cancel() must fire when activity is generating")
    local last = view.messages[#view.messages]
    h.is_true(last:text():find("cancelled", 1, true) ~= nil, "should report the cancel")
  end)

  h.it("Ctrl+C stays a no-op when idle and nothing is streaming", function()
    local session, view = make_setup()
    local cancelled = false
    session.cancel = function()
      cancelled = true
    end
    local before = #view.messages
    press("<C-c>")
    h.is_true(not cancelled, "no cancel when idle")
    h.eq(before, #view.messages)
  end)

  h.it("metadata-only updates do not arm cancel", function()
    local session, view = make_setup()
    local cancelled = false
    session.cancel = function()
      cancelled = true
    end
    session:_emit("update", { sessionUpdate = "usage_update", used = 10, size = 100 })
    flush()
    local before = #view.messages
    press("<C-c>")
    h.is_true(not cancelled, "usage_update alone must not arm cancel")
    h.eq(before, #view.messages)
  end)

  h.it("trailing updates after cancel do not re-arm cancel", function()
    local session, view = make_setup()
    local cancel_count = 0
    session.cancel = function()
      cancel_count = cancel_count + 1
    end

    session:_emit("update", { sessionUpdate = "agent_message_chunk", content = { type = "text", text = "x" } })
    press("<C-c>")
    h.eq(1, cancel_count)

    -- Trailing chunk arrives after the cancel; a second C-c must be a no-op.
    session:_emit("update", { sessionUpdate = "agent_message_chunk", content = { type = "text", text = "tail" } })
    local before = #view.messages
    press("<C-c>")
    h.eq(1, cancel_count, "trailing updates must not re-arm cancel")
    h.eq(before, #view.messages)
  end)
end)

h.describe("acp integration: slow-connect nudge", function()
  h.it("posts a nudge if the handshake is still pending after the threshold", function()
    local emeth = require("emeth")
    local prev = emeth.config.slow_connect_ms
    emeth.config.slow_connect_ms = 10 -- fire almost immediately

    local session = Session:new("test")
    local view = make_view()
    local integration = Acp.setup_integration(view, session)
    session.connect = function() end -- never completes → activity stays "connecting"

    integration.connect()
    vim.wait(200, function()
      local last = view.messages[#view.messages]
      return last and last:text():find("Taking longer", 1, true) ~= nil
    end)

    local last = view.messages[#view.messages]
    h.is_true(last and last:text():find("Taking longer", 1, true) ~= nil, "nudge should post")
    h.is_true(last:text():find("<C-c>", 1, true) ~= nil, "nudge should point at the abort")

    emeth.config.slow_connect_ms = prev
  end)

  h.it("does not nudge once the connect has completed", function()
    local emeth = require("emeth")
    local prev = emeth.config.slow_connect_ms
    emeth.config.slow_connect_ms = 10

    local session = Session:new("test")
    local view = make_view()
    local integration = Acp.setup_integration(view, session)
    -- Completes synchronously: done(nil) bumps epoch before the timer fires.
    -- Called as session:connect(opts, cb) → (self, opts, cb).
    session.connect = function(_self, _opts, cb)
      cb(nil)
    end
    session.session_id = "sess-1"

    integration.connect()
    vim.wait(100)

    for _, m in ipairs(view.messages) do
      h.is_true(m:text():find("Taking longer", 1, true) == nil, "no nudge after completion")
    end

    emeth.config.slow_connect_ms = prev
  end)

  h.it("is disabled when slow_connect_ms is 0", function()
    local emeth = require("emeth")
    local prev = emeth.config.slow_connect_ms
    emeth.config.slow_connect_ms = 0

    local session = Session:new("test")
    local view = make_view()
    local integration = Acp.setup_integration(view, session)
    session.connect = function() end

    integration.connect()
    vim.wait(100)

    for _, m in ipairs(view.messages) do
      h.is_true(m:text():find("Taking longer", 1, true) == nil, "no nudge when disabled")
    end

    emeth.config.slow_connect_ms = prev
  end)
end)

h.describe("acp integration: buffer reload focus", function()
  h.it("shows the edited file in the source window without stealing focus from emeth", function()
    local session = Session:new("test")
    session._state = "ready"
    session.session_id = "sess-1"
    local view = make_view()
    Acp.setup_integration(view, session)

    -- A real file the "agent" wrote, with enough lines to jump to.
    local tmp = vim.fn.tempname() .. ".txt"
    local lines = {}
    for i = 1, 20 do
      lines[i] = "line " .. i
    end
    vim.fn.writefile(lines, tmp)

    -- Two real windows: source (normal buffer) + emeth (named emeth://…).
    -- find_source_win picks the non-emeth one; the user sits in the emeth one.
    vim.cmd("only")
    local source_win = vim.api.nvim_get_current_win()
    vim.cmd("vsplit")
    local emeth_win = vim.api.nvim_get_current_win()
    local emeth_buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_name(emeth_buf, "emeth://test-chat")
    vim.api.nvim_win_set_buf(emeth_win, emeth_buf)
    h.is_true(source_win ~= emeth_win, "need two distinct windows")

    -- Agent writes the file while the user's cursor is in the emeth window.
    -- Resolve via uv.fs_realpath so /tmp symlink on macOS (/private/tmp) matches.
    local abs_tmp = vim.uv.fs_realpath(tmp) or vim.fn.fnamemodify(tmp, ":p")
    session:_emit("file_written", tmp, 12)

    -- Wait out the 1s reload debounce + the scheduled cursor positioning.
    -- Check both that the buffer shows the file AND cursor hit line 12.
    local ok = vim.wait(5000, function()
      if not vim.api.nvim_win_is_valid(source_win) then
        return false
      end
      local buf = vim.api.nvim_win_get_buf(source_win)
      local buf_name = vim.api.nvim_buf_get_name(buf)
      if buf_name ~= abs_tmp then
        return false
      end
      return vim.api.nvim_win_get_cursor(source_win)[1] == 12
    end, 20)

    h.is_true(ok, "source window should show the edited file at the changed line")
    h.eq(emeth_win, vim.api.nvim_get_current_win(), "focus must stay in the emeth window")

    -- Cleanup
    vim.cmd("only")
    pcall(vim.api.nvim_buf_delete, emeth_buf, { force = true })
    vim.fn.delete(tmp)
  end)
end)

h.describe("acp integration: permission queue", function()
  -- Build a session whose request_permission round-trips through the integration
  -- like the real client: each call records the chosen optionId.
  local function perm_setup()
    local session, view = make_setup()
    local resolved = {} ---@type table[]
    --- Mimic a permission request arriving from the agent.
    local function request(tool_call, options)
      session:_emit("permission", tool_call, options, function(option_id)
        resolved[#resolved + 1] = { id = tool_call.toolCallId, option = option_id }
      end)
    end
    return session, view, resolved, request
  end

  local OPTS = {
    { kind = "allow_once", name = "Yes", optionId = "allow_once" },
    { kind = "reject_once", name = "No", optionId = "reject_once" },
  }

  h.it("resolves a single request when its key is pressed", function()
    local _, _, resolved, request = perm_setup()
    request({ toolCallId = "t1", title = "Read a.lua" }, OPTS)
    flush()
    h.is_true(press("a"), "allow key should be bound")
    h.eq(1, #resolved)
    h.eq("t1", resolved[1].id)
    h.eq("allow_once", resolved[1].option)
  end)

  h.it("serializes concurrent requests: answering the head activates the next", function()
    local _, _, resolved, request = perm_setup()
    -- Two requests arrive before the user answers either.
    request({ toolCallId = "t1", title = "Read a.lua" }, OPTS)
    request({ toolCallId = "t2", title = "Read b.lua" }, OPTS)
    flush()

    -- Only the head (t1) is answerable right now.
    h.is_true(press("a"), "head keymap bound")
    h.eq(1, #resolved)
    h.eq("t1", resolved[1].id)
    h.eq("allow_once", resolved[1].option)

    -- The second request is now active; the same key resolves it (no collision).
    h.is_true(press("r"), "next keymap rebound after head resolved")
    h.eq(2, #resolved)
    h.eq("t2", resolved[2].id)
    h.eq("reject_once", resolved[2].option)
  end)

  h.it("shows pending count on the active prompt when a request queues behind it", function()
    local _, view, _, request = perm_setup()
    request({ toolCallId = "t1", title = "Read a.lua" }, OPTS)
    flush()
    -- Head prompt is the last message; no pending line yet.
    local head = view.messages[#view.messages]
    h.is_true(head:text():find("more pending") == nil, "no pending line with one request")

    -- A second request arrives behind it — head prompt should now show it.
    request({ toolCallId = "t2", title = "Read b.lua" }, OPTS)
    flush()
    h.is_true(head:text():find("1 more pending") ~= nil, "head prompt should report 1 pending")
  end)

  h.it("preserves FIFO order across three requests", function()
    local _, _, resolved, request = perm_setup()
    request({ toolCallId = "t1" }, OPTS)
    request({ toolCallId = "t2" }, OPTS)
    request({ toolCallId = "t3" }, OPTS)
    flush()
    press("a")
    press("a")
    press("a")
    h.eq(3, #resolved)
    h.eq("t1", resolved[1].id)
    h.eq("t2", resolved[2].id)
    h.eq("t3", resolved[3].id)
  end)
end)

h.describe("acp integration: session config options (/model etc.)", function()
  local Commands = require("emeth.commands")

  -- Stub vim.ui.select to auto-pick by predicate; returns what was offered.
  local _orig_select = vim.ui.select
  local function with_select(pick, body)
    local offered
    vim.ui.select = function(items, _opts, on_choice)
      offered = items
      on_choice(pick(items))
    end
    local ok, err = pcall(body, function()
      return offered
    end)
    vim.ui.select = _orig_select
    if not ok then
      error(err)
    end
  end

  local MODEL_OPT = {
    id = "model",
    type = "select",
    name = "Model",
    description = "AI model to use",
    currentValue = "opus",
    options = {
      { value = "opus", name = "Opus", description = "big" },
      { value = "sonnet", name = "Sonnet", description = "fast" },
    },
  }

  h.it("registers a /model command from a config_option_update snapshot", function()
    Commands.clear_config()
    local session = make_setup()
    session:_emit("update", { sessionUpdate = "config_option_update", configOptions = { MODEL_OPT } })
    flush()
    local cmd = Commands.get("model")
    h.is_true(cmd ~= nil, "/model should be registered")
    h.eq("config", cmd.source)
    h.is_true(cmd.has_picker == true)
    Commands.clear_config()
  end)

  h.it("picking a different model sets it and reconciles the response snapshot", function()
    Commands.clear_config()
    local session, view = make_setup()
    local sent
    -- Mimic the wrapper: return the updated configOptions in the response
    -- (it does NOT push config_option_update for a user-initiated switch).
    session.set_config_option = function(_, config_id, value, cb)
      sent = { config_id = config_id, value = value }
      cb({
        configOptions = {
          {
            id = "model",
            type = "select",
            currentValue = value,
            options = MODEL_OPT.options,
          },
        },
      }, nil)
    end
    session:_emit("update", { sessionUpdate = "config_option_update", configOptions = { MODEL_OPT } })
    flush()

    with_select(function(items)
      for _, it in ipairs(items) do
        if it.value == "sonnet" then
          return it
        end
      end
    end, function()
      Commands.get("model").execute("", { view = view, integration = view.integration })
    end)
    flush()

    h.eq("model", sent.config_id)
    h.eq("sonnet", sent.value)
    -- The response snapshot must land in session state so the prompt's
    -- `model:` detail and the winbar badge reflect the switch.
    h.eq("sonnet", session.extensions.config_options.model.currentValue)
    h.eq("sonnet", session.extensions.model_id)
    Commands.clear_config()
  end)

  h.it("selecting the current value is a no-op (no request)", function()
    Commands.clear_config()
    local session, view = make_setup()
    local called = false
    session.set_config_option = function()
      called = true
    end
    session:_emit("update", { sessionUpdate = "config_option_update", configOptions = { MODEL_OPT } })
    flush()

    with_select(function(items)
      for _, it in ipairs(items) do
        if it.value == "opus" then -- currentValue
          return it
        end
      end
    end, function()
      Commands.get("model").execute("", { view = view, integration = view.integration })
    end)

    h.is_true(not called, "re-selecting the current model must not send a request")
    Commands.clear_config()
  end)

  h.it("a forwarded ACP /model does not override the config-sourced one", function()
    Commands.clear_config()
    local session, view = make_setup()
    session:_emit("update", { sessionUpdate = "config_option_update", configOptions = { MODEL_OPT } })
    flush()
    -- Agent later forwards its own /model slash command.
    session:_emit("update", {
      sessionUpdate = "available_commands_update",
      availableCommands = { { name = "/model", description = "server model" } },
    })
    local cmd = Commands.get("model")
    h.eq("config", cmd.source, "config command stays authoritative for /model")
    h.is_true(cmd.has_picker == true)
    Commands.clear_config()
    Commands.clear_acp()
  end)

  h.it("renders provider · model in the winbar left segment and updates on switch", function()
    Commands.clear_config()
    -- Capture set_left for this test only, then restore the stub.
    local left
    local stub = Winbar.set_left
    Winbar.set_left = function(_, plain)
      left = plain
    end

    local session, view = make_setup()
    session.extensions = { model_id = "opus" }
    session.set_config_option = function(_, _config_id, value, cb)
      cb({ configOptions = { { id = "model", type = "select", currentValue = value, options = MODEL_OPT.options } } }, nil)
    end
    -- Seed the picker options + render the initial left segment.
    session:_emit("update", { sessionUpdate = "config_option_update", configOptions = { MODEL_OPT } })
    flush()
    h.is_true(left ~= nil and left:find("test", 1, true) ~= nil, "left shows provider")
    h.is_true(left:find("opus", 1, true) ~= nil, "left shows initial model")

    with_select(function(items)
      for _, it in ipairs(items) do
        if it.value == "sonnet" then
          return it
        end
      end
    end, function()
      Commands.get("model").execute("", { view = view, integration = view.integration })
    end)
    flush()
    h.is_true(left:find("sonnet", 1, true) ~= nil, "left updates to switched model")

    Winbar.set_left = stub
    Commands.clear_config()
  end)

  h.it("shortens an over-long model id generically (last dotted segment)", function()
    Commands.clear_config()
    local left
    local stub = Winbar.set_left
    Winbar.set_left = function(_, plain)
      left = plain
    end

    -- The `test` provider has no format_model hook, so this exercises the
    -- generic core fallback directly on a Bedrock-style id.
    local LONG = "global.anthropic.claude-opus-4-8[1m]"
    local session = make_setup()
    session.extensions = { model_id = LONG }
    session:_emit("update", {
      sessionUpdate = "config_option_update",
      configOptions = { { id = "model", type = "select", currentValue = LONG, options = {} } },
    })
    flush()

    h.is_true(left:find("test", 1, true) ~= nil, "left still shows provider")
    -- Collapsed to the last dot-separated segment, dotted prefix dropped.
    h.is_true(left:find("claude-opus-4-8[1m]", 1, true) ~= nil, "shows last dotted segment")
    h.is_true(left:find("global.anthropic", 1, true) == nil, "drops the dotted prefix")

    Winbar.set_left = stub
    Commands.clear_config()
  end)

  h.it("disconnect clears config commands", function()
    Commands.clear_config()
    local session, _, integration = make_setup()
    session:_emit("update", { sessionUpdate = "config_option_update", configOptions = { MODEL_OPT } })
    flush()
    h.is_true(Commands.get("model") ~= nil)
    integration.disconnect()
    h.is_nil(Commands.get("model"))
  end)
end)

-- Restore stubs
for k, fn in pairs(_orig_winbar) do
  Winbar[k] = fn
end
vim.api.nvim_buf_set_keymap = _orig_set_keymap
vim.api.nvim_buf_del_keymap = _orig_del_keymap
