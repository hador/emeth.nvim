--- Sidebar layout — arranges ChatView buffers in a vertical/horizontal split.

local api = vim.api

---@class chat_ui.SidebarLayout
---@field view chat_ui.ChatView|nil
---@field result_win number|nil
---@field input_win number|nil
---@field _augroup number
local Sidebar = {}
Sidebar.__index = Sidebar

---@return chat_ui.SidebarLayout
function Sidebar:new()
  return setmetatable({
    view = nil,
    result_win = nil,
    input_win = nil,
    _augroup = api.nvim_create_augroup("emeth_sidebar", { clear = true }),
  }, Sidebar)
end

---@param view chat_ui.ChatView
function Sidebar:open(view)
  if self:is_open() then
    -- Already open, just make sure buffers are set
    if self.view ~= view then
      self.view = view
      pcall(api.nvim_win_set_buf, self.result_win, view.result_buf)
      pcall(api.nvim_win_set_buf, self.input_win, view.input_buf)
    end
    return
  end

  self.view = view
  local config = require("emeth").config
  local pos = config.sidebar.position
  local width = config.sidebar.width
  local input_height = config.sidebar.input_height

  -- Create the sidebar split
  local split_cmd
  if pos == "right" then
    split_cmd = "botright vertical"
  elseif pos == "left" then
    split_cmd = "topleft vertical"
  elseif pos == "top" then
    split_cmd = "topleft"
  elseif pos == "bottom" then
    split_cmd = "botright"
  else
    split_cmd = "botright vertical"
  end

  -- Calculate size
  local is_vertical = pos == "left" or pos == "right"
  local size
  if is_vertical then
    size = math.floor(vim.o.columns * width / 100)
  else
    size = math.floor(vim.o.lines * width / 100)
  end

  vim.cmd(split_cmd .. " " .. size .. "split")
  self.result_win = api.nvim_get_current_win()
  api.nvim_win_set_buf(self.result_win, view.result_buf)
  api.nvim_set_option_value("wrap", true, { win = self.result_win })
  api.nvim_set_option_value("number", false, { win = self.result_win })
  api.nvim_set_option_value("relativenumber", false, { win = self.result_win })
  api.nvim_set_option_value("signcolumn", "no", { win = self.result_win })
  api.nvim_set_option_value("winfixwidth", is_vertical, { win = self.result_win })

  -- Create input split at the bottom of the sidebar
  vim.cmd("belowright " .. input_height .. "split")
  self.input_win = api.nvim_get_current_win()
  api.nvim_win_set_buf(self.input_win, view.input_buf)
  api.nvim_set_option_value("wrap", true, { win = self.input_win })
  api.nvim_set_option_value("number", false, { win = self.input_win })
  api.nvim_set_option_value("relativenumber", false, { win = self.input_win })
  api.nvim_set_option_value("signcolumn", "no", { win = self.input_win })
  api.nvim_set_option_value("winfixheight", true, { win = self.input_win })

  -- Set up keymaps
  self:_setup_keymaps()

  -- Auto-close cleanup
  api.nvim_create_autocmd("WinClosed", {
    group = self._augroup,
    callback = function(ev)
      local closed_win = tonumber(ev.match)
      if closed_win == self.result_win or closed_win == self.input_win then
        vim.schedule(function() self:close() end)
      end
    end,
  })

  -- Focus input
  self:focus_input()
  vim.cmd("startinsert")
end

function Sidebar:close()
  api.nvim_clear_autocmds({ group = self._augroup })
  if self.input_win and api.nvim_win_is_valid(self.input_win) then
    api.nvim_win_close(self.input_win, true)
  end
  if self.result_win and api.nvim_win_is_valid(self.result_win) then
    api.nvim_win_close(self.result_win, true)
  end
  self.result_win = nil
  self.input_win = nil
end

---@param view chat_ui.ChatView
function Sidebar:toggle(view)
  if self:is_open() then
    self:close()
  else
    self:open(view)
  end
end

---@return boolean
function Sidebar:is_open()
  return self.result_win ~= nil and api.nvim_win_is_valid(self.result_win)
end

function Sidebar:focus_input()
  if self.input_win and api.nvim_win_is_valid(self.input_win) then
    api.nvim_set_current_win(self.input_win)
  end
end

function Sidebar:focus_result()
  if self.result_win and api.nvim_win_is_valid(self.result_win) then
    api.nvim_set_current_win(self.result_win)
  end
end

function Sidebar:_setup_keymaps()
  local config = require("emeth").config
  local view = self.view
  if not view then return end

  -- Close keymaps on result buffer
  local close_keys = config.mappings.close.normal
  if type(close_keys) == "string" then close_keys = { close_keys } end
  for _, key in ipairs(close_keys or {}) do
    for _, buf in ipairs({ view.result_buf, view.input_buf }) do
      if api.nvim_buf_is_valid(buf) then
        api.nvim_buf_set_keymap(buf, "n", key, "", {
          noremap = true, silent = true,
          callback = function() self:close() end,
        })
      end
    end
  end

  -- Switch window keymap
  local switch_key = config.mappings.switch_window.normal
  if switch_key then
    for _, buf in ipairs({ view.result_buf, view.input_buf }) do
      if api.nvim_buf_is_valid(buf) then
        api.nvim_buf_set_keymap(buf, "n", switch_key, "", {
          noremap = true, silent = true,
          callback = function()
            local cur = api.nvim_get_current_win()
            if cur == self.result_win then
              self:focus_input()
            else
              self:focus_result()
            end
          end,
        })
      end
    end
  end
end

return Sidebar
