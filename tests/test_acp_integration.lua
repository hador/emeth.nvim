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
for _, k in ipairs({ "set_state", "set_badge", "clear_badge", "set_context", "attach", "set_left", "set_mode_tag", "clear_mode_tag" }) do
  _orig_winbar[k] = Winbar[k]
  Winbar[k] = function() end
end

-- Stub buf_set_keymap (do_cancel registers C-c in input/result bufs)
local _orig_set_keymap = vim.api.nvim_buf_set_keymap
vim.api.nvim_buf_set_keymap = function() end

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
    session:_emit("update", { sessionUpdate = "agent_thought_chunk", content = { type = "text", text = "pondering..." } })
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
        { name = "/agents", description = "Manage agents" },  -- no hint
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

-- Restore stubs
for k, fn in pairs(_orig_winbar) do
  Winbar[k] = fn
end
vim.api.nvim_buf_set_keymap = _orig_set_keymap
