--- emeth.nvim — Reusable chat UI library for AI/LLM interactions.

---@class chat_ui.ClaudeCodeConfig
---@field show_raw_sdk_messages? boolean
---@field extra_args? table<string, string|boolean>

---@class chat_ui.Config
---@field sidebar { position: string, width: number, input_height: number }
---@field mappings table
---@field icons table
---@field resume_last_session boolean
---@field prompt_dirs string[]
---@field prompt_edit_before_send boolean
---@field default_provider string|nil
---@field auto_add_current_file boolean
---@field fold_pasted_text boolean
---@field paste_fold_min_lines number
---@field paste_fold_min_chars number
---@field show_title? boolean
---@field claude_code? chat_ui.ClaudeCodeConfig

---@class chat_ui.Module
---@field config chat_ui.Config
local M = {}

---@type chat_ui.Config
local defaults = {
  sidebar = {
    position = "right",
    width = 40,
    input_height = 8,
  },
  mappings = {
    submit = { insert = "<C-s>", normal = "<CR>" },
    close = { normal = { "q", "<Esc>" } },
    switch_window = { normal = "<Tab>" },
    -- tmux-style zoom: grow the sidebar to fill the screen and back.
    zoom = { normal = "<leader>ez" },
    -- Expand a folded paste under the cursor in the input buffer. `za`/`zo`
    -- can't work here (it's not a real vim fold — the text is held off-buffer
    -- for performance), so this provides an explicit, familiar binding.
    expand_paste = { normal = { "za", "zo" } },
  },
  icons = {
    user = "> ",
    assistant = "",
    thinking = "🤔 ",
    tool_generating = "⏳",
    tool_succeeded = "✓",
    tool_failed = "✗",
  },
  resume_last_session = false,
  prompt_dirs = {},
  prompt_edit_before_send = true,
  -- Collapse large pastes in the input buffer to a single placeholder line.
  -- The raw text is held off-buffer and spliced back in at submit time, so it
  -- never sits in the live-edited (treesitter-parsed) input buffer.
  fold_pasted_text = true,
  paste_fold_min_lines = 10, -- fold pastes with at least this many lines
  paste_fold_min_chars = 1000, -- ...or at least this many chars (catches huge single-line blobs)
  show_title = true,
  default_provider = nil,
  auto_add_current_file = true,
  claude_code = {
    show_raw_sdk_messages = false,
    -- Forwarded as `--<key> <value>` to the Claude CLI on session/new and
    -- session/load via the agent SDK's `extraArgs` channel. Use `true` for
    -- boolean flags. Example:
    --   extra_args = { agent = "my-agent", verbose = true }
    -- becomes `--agent my-agent --verbose` on the underlying claude invocation.
    extra_args = nil, ---@type table<string, string|boolean>|nil
  },
}

M.config = vim.deepcopy(defaults)

---@type chat_ui.ChatView|nil
local _view = nil
---@type chat_ui.SidebarLayout|nil
local _sidebar = nil
---@type table|nil
M._integration = nil
---@type string|nil
M._provider = nil

---@param opts? table
function M.setup(opts)
  M.config = vim.tbl_deep_extend("force", vim.deepcopy(defaults), opts or {})
  require("emeth.ui.highlights").setup()
  require("emeth.acp").setup(opts and opts.acp)
  require("emeth.commands").register_builtins()
end

---Resolve which provider to use: explicit arg > config default > single configured > error.
---@param provider? string
---@return string|nil
local function resolve_provider(provider)
  if provider then
    return provider
  end
  if M.config.default_provider then
    return M.config.default_provider
  end
  local names = vim.tbl_keys(require("emeth.acp").config.providers)
  if #names == 1 then
    return names[1]
  end
  vim.notify(
    "[emeth] Multiple providers configured. Specify one with :Emeth <provider> or set default_provider.",
    vim.log.levels.WARN
  )
  return nil
end

---Ensure the sidebar is open with the given view.
local function ensure_sidebar_open()
  if not _view then
    _view = require("emeth.ui.chat_view"):new({ config = M.config })
  end
  if not _sidebar then
    _sidebar = require("emeth.layout.sidebar"):new(M.config)
  end
  if not _sidebar:is_open() then
    _sidebar:open(_view)
    if _sidebar.result_win then
      require("emeth.ui.winbar").attach(_sidebar.result_win, _sidebar.input_win)
      local lc = vim.api.nvim_buf_line_count(_view.result_buf)
      pcall(vim.api.nvim_win_set_cursor, _sidebar.result_win, { lc, 0 })
    end
  end
end

---Connect to a provider, setting up the integration and session.
---@param provider string
---@param opts? { fresh?: boolean }
local function connect(provider, opts)
  opts = opts or {}
  local origin_buf = vim.api.nvim_get_current_buf()
  local origin_file = vim.api.nvim_buf_get_name(origin_buf)

  ensure_sidebar_open()

  local session = require("emeth.acp").create_session(provider)
  local integration = require("emeth.integrations.acp").setup_integration(assert(_view), session)
  M._integration = integration
  M._provider = provider

  if M.config.auto_add_current_file and origin_file ~= "" and vim.fn.filereadable(origin_file) == 1 then
    integration.add_file(origin_file)
  end

  local resumed = false
  if not opts.fresh and M.config.resume_last_session then
    local Sessions = require("emeth.sessions")
    local last = Sessions.list(vim.fn.getcwd(), provider)[1]
    if last then
      resumed = true
      integration.connect_and_load(last.session_id)
    end
  end
  if not resumed then
    integration.connect()
  end
end

---Open the chat sidebar, optionally with a specific provider.
---@param provider? string
---@param opts? { fresh?: boolean }  fresh=true forces a new session (skip resume)
function M.open(provider, opts)
  opts = opts or {}

  -- Switch provider if a different one was requested
  if provider and M._integration and provider ~= M._provider then
    M._integration.disconnect()
    M._integration = nil
    M._provider = nil
  end

  -- Already connected — start a new session if fresh was requested, else focus
  if M._integration then
    ensure_sidebar_open()
    if opts.fresh and M._integration.new_session then
      M._integration.new_session()
    end
    if _sidebar then
      _sidebar:focus_input()
    end
    return
  end

  local resolved = resolve_provider(provider)
  if resolved then
    connect(resolved, opts)
  end
end

function M.close()
  if M._closing then
    return
  end
  M._closing = true
  if M._integration and M._integration.disconnect then
    M._integration.disconnect()
  end
  M._integration = nil
  M._provider = nil
  if _sidebar then
    _sidebar:close()
  end
  if _view and _view.detach then
    _view:detach()
  end
  _sidebar = nil
  _view = nil
  M._closing = false
end

function M.toggle(provider)
  if _sidebar and _sidebar:is_open() then
    require("emeth.ui.winbar").detach()
    _sidebar:close()
  else
    M.open(provider)
  end
end

---Toggle tmux-style zoom of the emeth sidebar (grow to fill the screen / back).
function M.zoom()
  if _sidebar and _sidebar:is_open() then
    _sidebar:toggle_zoom()
  else
    vim.notify("[emeth] No active chat. Open one first with :Emeth", vim.log.levels.WARN)
  end
end

function M.history()
  if M._integration and M._integration.pick_session then
    M._integration.pick_session()
  else
    vim.notify("[emeth] No active chat. Open one first with :Emeth", vim.log.levels.WARN)
  end
end

function M.cancel()
  if M._integration and M._integration.cancel then
    M._integration.cancel()
  end
end

---Send the current visual selection to the chat as a fenced code block.
function M.send_selection()
  if not M._integration then
    vim.notify("[emeth] No active chat. Open one first with :Emeth", vim.log.levels.WARN)
    return
  end
  local lines = vim.fn.getregion(vim.fn.getpos("v"), vim.fn.getpos("."), { type = vim.fn.mode() })
  if #lines == 0 then
    return
  end
  local fname = vim.fn.fnamemodify(vim.api.nvim_buf_get_name(0), ":.")
  assert(_view):append_fenced({ "From " .. fname .. ":" }, lines)
  vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<Esc>", true, false, true), "nx", false)
  M.open()
end

---@return chat_ui.ChatView|nil
function M.get_view()
  return _view
end

---@return chat_ui.SidebarLayout|nil
function M.get_sidebar()
  return _sidebar
end

return M
