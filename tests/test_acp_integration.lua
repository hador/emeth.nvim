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

  function view:update_message(uuid, fn_or_msg)
    for _, m in ipairs(self.messages) do
      if m.uuid == uuid then
        if type(fn_or_msg) == "function" then
          fn_or_msg(m)
        end
        return
      end
    end
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
    -- updates before it execs the agent): connect() never calls back, so the
    -- lifecycle's `done` never fires and `connecting` stays true.
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
    local session, view = make_setup() -- _state = "ready", not connecting
    local before = #view.messages
    press("<C-c>")
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
    session.connect = function() end -- never completes → stays connecting

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
    -- Completes synchronously via done(nil): connecting flips false before the
    -- timer. Called as session:connect(opts, cb) → (self, opts, cb).
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

-- Restore stubs
for k, fn in pairs(_orig_winbar) do
  Winbar[k] = fn
end
vim.api.nvim_buf_set_keymap = _orig_set_keymap
vim.api.nvim_buf_del_keymap = _orig_del_keymap
