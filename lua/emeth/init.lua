--- emeth.nvim — Reusable chat UI library for AI/LLM interactions.

local Highlights = require("emeth.highlights")
local ChatView = require("emeth.view")
local Sidebar = require("emeth.layout.sidebar")

---@class chat_ui.Config
---@field sidebar { position: string, width: number, input_height: number }
---@field mappings table
---@field icons table

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
  },
  icons = {
    user = "> ",
    assistant = "",
    thinking = "🤔 ",
    tool_generating = "⏳",
    tool_succeeded = "✓",
    tool_failed = "✗",
  },
}

M.config = vim.deepcopy(defaults)

---@type chat_ui.ChatView|nil
local _view = nil
---@type chat_ui.SidebarLayout|nil
local _sidebar = nil
---@type table|nil  -- integration returned by integrations/acp.setup_integration
M._integration = nil

---@param opts? table
function M.setup(opts)
  M.config = vim.tbl_deep_extend("force", vim.deepcopy(defaults), opts or {})
  Highlights.setup()
end

---@param opts? { on_submit?: fun(text: string) }
function M.open(opts)
  if _sidebar and _sidebar:is_open() then
    _sidebar:focus_input()
    return
  end
  if not _view then
    _view = ChatView:new(opts)
  end
  if not _sidebar then
    _sidebar = Sidebar:new()
  end
  _sidebar:open(_view)
end

function M.close()
  if M._integration and M._integration.disconnect then
    M._integration.disconnect()
  end
  M._integration = nil
  if _sidebar then
    _sidebar:close()
  end
  _sidebar = nil
  _view = nil
end

function M.toggle()
  if _sidebar and _sidebar:is_open() then
    _sidebar:close()
  else
    M.open()
  end
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
