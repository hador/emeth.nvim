--- Shared harness for the `emeth.integrations.acp` test files.
---
--- The ACP integration tests are split by concern (updates, prompts, lifecycle,
--- subagents) and all need the same scaffolding: a mock ChatView, a Session with
--- no transport, and stubs over the globals `setup_integration` touches.
---
--- IMPORTANT: the Winbar and keymap stubs are global mutations, so they are NOT
--- applied on require. `install()` applies them and returns a restore function
--- that each test file must call at the end. The runner `dofile`s test files in
--- alphabetical order, and later ones (test_winbar.lua) assert against the REAL
--- Winbar -- leaking these stubs would break them.

local M = {}

-- Initialise emeth first (registers builtins, sets config defaults), then
-- override the acp config with a fake provider for these tests.
require("emeth").setup({})
require("emeth.acp").config = {
  providers = { ["test"] = { command = "echo", args = {} } },
  auto_approve_tools = false,
}

local Session = require("emeth.acp.session")
local Acp = require("emeth.integrations.acp")

-- Records keymaps bound directly by the integration (e.g. <C-c>), keyed by the
-- normal-mode lhs. Reset by each `install()` so files can't see each other's.
local bound_keymaps = {} ---@type table<string, fun()>

-- A minimal stand-in for chat_ui.ChatView that records what would be rendered
-- without touching nvim buffers or windows.

function M.make_view()
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

  -- Records that focus moved to the input box (real impl scans windows).
  view.focus_input_count = 0
  function view:focus_input()
    self.focus_input_count = self.focus_input_count + 1
    return true
  end

  -- Real impl scans windows for the result buffer. Tests flip `_visible` to say
  -- whether the sidebar is on screen; the default matches the common case.
  view._visible = true
  function view:is_visible()
    return self._visible
  end

  -- Transient-prompt key claims. The real view binds these keys once and
  -- dispatches to registered owners; the mock just records the claims so
  -- `press` can walk them. Dispatch semantics (first owner wins, fallback to
  -- the key's default) are covered by ChatView's own tests.
  view._prompt_key_owners = {}
  function view:set_prompt_keys(owner, keys)
    self:clear_prompt_keys(owner)
    self._prompt_key_owners[#self._prompt_key_owners + 1] = { owner = owner, keys = keys }
  end
  function view:clear_prompt_keys(owner)
    for i = #self._prompt_key_owners, 1, -1 do
      if self._prompt_key_owners[i].owner == owner then
        table.remove(self._prompt_key_owners, i)
      end
    end
  end

  -- Stands in for the real cursor lookup, which needs a rendered buffer.
  -- Tests set `_cursor_offset` (and optionally `_cursor_msg`) to say which line
  -- of which message the cursor is on. Offset alignment against a real render
  -- is covered by ChatView:cursor_message_line's own tests.
  view._cursor_offset = nil
  view._cursor_msg = nil
  function view:cursor_message_line()
    if not self._cursor_offset then
      return nil, nil
    end
    return self._cursor_msg or self.messages[#self.messages], self._cursor_offset
  end

  -- These are touched by integration setup but we don't care about effects.
  view.result_buf = 0
  view.input_buf = 0
  return view
end

---Stub the globals `setup_integration` touches. Returns the restore function.
---@return fun()
function M.install()
  bound_keymaps = {}

  -- Stub winbar so badge calls / state flips don't hit real highlight groups.
  local Winbar = package.loaded["emeth.ui.winbar"]
  local orig_winbar = {}
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
    orig_winbar[k] = Winbar[k]
    Winbar[k] = function() end
  end

  -- Stub buf_set_keymap (do_cancel registers C-c in input/result bufs), but
  -- record the callbacks so tests can invoke them. del_keymap removes the entry.
  local orig_set_keymap = vim.api.nvim_buf_set_keymap
  local orig_del_keymap = vim.api.nvim_buf_del_keymap
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

  return function()
    for k, fn in pairs(orig_winbar) do
      Winbar[k] = fn
    end
    vim.api.nvim_buf_set_keymap = orig_set_keymap
    vim.api.nvim_buf_del_keymap = orig_del_keymap
  end
end

---The stubbed Winbar module, for tests that need to spy on a specific call.
---@return table
function M.winbar()
  return package.loaded["emeth.ui.winbar"]
end

--- Run pending vim.schedule callbacks (the permission handler defers to one).
function M.flush()
  vim.wait(0)
end

--- Press a real buffer keymap (e.g. <C-c>, which the integration still binds
--- directly because it is not a transient-prompt key).
function M.press(key)
  local cb = bound_keymaps[key]
  if cb then
    cb()
  end
  return cb ~= nil
end

--- Press a key claimed by a transient prompt. Returns false when nothing
--- claimed it, which is what the view would treat as "fall through to default".
function M.press_on(view, key)
  for _, entry in ipairs(view._prompt_key_owners) do
    local fn = entry.keys[key]
    if fn then
      fn()
      return true
    end
  end
  return false
end

-- ── Helper: build session + view + integration ─────────────────

---A ready Session (no transport spawned) wired to a fresh mock view.
---@return acp.Session, table, table
function M.setup()
  local session = Session:new("test")
  session._state = "ready"
  session.session_id = "sess-1"
  local view = M.make_view()
  local integration = Acp.setup_integration(view, session)
  return session, view, integration
end

return M
