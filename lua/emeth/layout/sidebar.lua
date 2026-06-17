--- Sidebar layout — arranges ChatView buffers in a vertical/horizontal split.

local api = vim.api

---@class chat_ui.SidebarLayout
---@field view chat_ui.ChatView|nil
---@field result_win number|nil
---@field input_win number|nil
---@field _config chat_ui.Config
---@field _augroup number
---@field _zoomed boolean
---@field _saved_size number|nil
---@field _saved_winmin number|nil
local Sidebar = {}
Sidebar.__index = Sidebar

---@param config chat_ui.Config
---@return chat_ui.SidebarLayout
function Sidebar:new(config)
  return setmetatable({
    view = nil,
    result_win = nil,
    input_win = nil,
    _config = config,
    _augroup = api.nvim_create_augroup("emeth_sidebar", { clear = true }),
    _zoomed = false,
    _saved_size = nil,
  }, Sidebar)
end

---@param view chat_ui.ChatView
function Sidebar:open(view)
  if self:is_open() then
    if self.view ~= view then
      self.view = view
      pcall(api.nvim_win_set_buf, self.result_win, view.result_buf)
      pcall(api.nvim_win_set_buf, self.input_win, view.input_buf)
    end
    return
  end

  self.view = view
  local config = self._config
  local pos = config.sidebar.position
  local width = config.sidebar.width
  local input_height = config.sidebar.input_height

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

  local is_vertical = pos == "left" or pos == "right"
  local size
  if is_vertical then
    size = math.floor(vim.o.columns * width / 100)
  else
    size = math.floor(vim.o.lines * width / 100)
  end

  vim.cmd(split_cmd .. " " .. size .. "split")
  self.result_win = api.nvim_get_current_win()

  -- Hide the vertical separator on the adjacent editor window
  self._code_win = vim.fn.win_getid(vim.fn.winnr("#"))
  if self._code_win and api.nvim_win_is_valid(self._code_win) then
    local HL = require("emeth.ui.highlights")
    self._code_win_old_winhl = vim.wo[self._code_win].winhl
    local pieces = {}
    for _, p in ipairs(vim.split(self._code_win_old_winhl or "", ",")) do
      if p ~= "" and not p:find("WinSeparator:") then
        pieces[#pieces + 1] = p
      end
    end
    pieces[#pieces + 1] = "WinSeparator:" .. HL.WIN_SEPARATOR
    vim.wo[self._code_win].winhl = table.concat(pieces, ",")
  end
  api.nvim_win_set_buf(self.result_win, view.result_buf)
  api.nvim_set_option_value("wrap", true, { win = self.result_win })
  api.nvim_set_option_value("number", false, { win = self.result_win })
  api.nvim_set_option_value("relativenumber", false, { win = self.result_win })
  api.nvim_set_option_value("signcolumn", "no", { win = self.result_win })
  api.nvim_set_option_value("winfixwidth", is_vertical, { win = self.result_win })
  api.nvim_set_option_value("linebreak", true, { win = self.result_win })
  api.nvim_set_option_value("breakindent", true, { win = self.result_win })
  api.nvim_set_option_value("fillchars", "eob: ", { win = self.result_win })
  api.nvim_set_option_value(
    "winhighlight",
    "Normal:NormalFloat,WinSeparator:EmethWinSeparator",
    { win = self.result_win }
  )
  api.nvim_set_option_value("statusline", " ", { win = self.result_win })
  vim.treesitter.language.register("markdown", "emeth")
  api.nvim_set_option_value("filetype", "emeth", { buf = view.result_buf })
  pcall(vim.treesitter.start, view.result_buf, "markdown")

  vim.cmd("belowright " .. input_height .. "split")
  self.input_win = api.nvim_get_current_win()
  api.nvim_win_set_buf(self.input_win, view.input_buf)
  api.nvim_set_option_value("wrap", true, { win = self.input_win })
  api.nvim_set_option_value("number", false, { win = self.input_win })
  api.nvim_set_option_value("relativenumber", false, { win = self.input_win })
  api.nvim_set_option_value("signcolumn", "no", { win = self.input_win })
  api.nvim_set_option_value("winfixheight", true, { win = self.input_win })
  api.nvim_set_option_value("winhighlight", "Normal:NormalFloat,WinSeparator:FloatBorder", { win = self.input_win })
  -- Own the input window's statusline too (the result window already blanks
  -- its own). The chat's status row is rendered by the winbar on this window;
  -- the statusline underneath must be a plain emeth-owned bar, otherwise it
  -- falls back to Vim's default (filename/ruler) which reflows and looks broken
  -- on resize. A single space keeps a flat, full-width bar at any size.
  api.nvim_set_option_value("statusline", " ", { win = self.input_win })
  api.nvim_set_option_value("filetype", "markdown", { buf = view.input_buf })

  -- Show > prompt via extmarks
  local prompt_ns = api.nvim_create_namespace("emeth_input_prompt")
  local function update_prompt()
    api.nvim_buf_clear_namespace(view.input_buf, prompt_ns, 0, -1)
    if not api.nvim_buf_is_valid(view.input_buf) then
      return
    end
    local line_count = api.nvim_buf_line_count(view.input_buf)
    for i = 0, line_count - 1 do
      api.nvim_buf_set_extmark(view.input_buf, prompt_ns, i, 0, {
        virt_text = { { "> ", "EmethPromptSign" } },
        virt_text_pos = "inline",
        right_gravity = false,
      })
    end
  end
  update_prompt()
  api.nvim_create_autocmd({ "TextChanged", "TextChangedI", "BufEnter" }, {
    buffer = view.input_buf,
    callback = update_prompt,
  })

  self:_setup_keymaps()

  api.nvim_create_autocmd("WinClosed", {
    group = self._augroup,
    callback = function(ev)
      local closed_win = tonumber(ev.match)
      if closed_win == self.result_win or closed_win == self.input_win then
        vim.schedule(function()
          require("emeth").close()
        end)
      end
    end,
  })

  self:focus_input()
  vim.cmd("startinsert")
end

function Sidebar:close()
  api.nvim_clear_autocmds({ group = self._augroup })
  -- If closed while zoomed, restore the globals we changed for the fill. Reuses
  -- the single restore path so close and un-zoom can't drift apart.
  self:_exit_zoom()
  if self._code_win and api.nvim_win_is_valid(self._code_win) then
    vim.wo[self._code_win].winhl = self._code_win_old_winhl or ""
  end
  self._code_win = nil
  self._code_win_old_winhl = nil
  if self.input_win and api.nvim_win_is_valid(self.input_win) then
    api.nvim_win_close(self.input_win, true)
  end
  if self.result_win and api.nvim_win_is_valid(self.result_win) then
    api.nvim_win_close(self.result_win, true)
  end
  self.result_win = nil
  self.input_win = nil
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

--- True if the sidebar is laid out along a vertical edge (left/right), where we
--- resize by width; otherwise (top/bottom) we resize by height.
---@return boolean
function Sidebar:_is_vertical()
  local pos = self._config.sidebar.position
  return pos == "left" or pos == "right"
end

--- Enter zoom: grow the emeth window to fill the screen.
---
--- Idempotent — bails if already zoomed. We drop `winmin*` to 0 so the adjacent
--- code window collapses to a 0-width body (only its 1-col separator remains),
--- saving the prior value for un-zoom. No statusline trickery is needed: emeth
--- owns both its windows' statuslines (see open()), so the bar stays flat at any
--- width on its own.
function Sidebar:_enter_zoom()
  if self._zoomed or not self:is_open() then
    return
  end
  local is_vertical = self:_is_vertical()
  local get = is_vertical and api.nvim_win_get_width or api.nvim_win_get_height
  local set = is_vertical and api.nvim_win_set_width or api.nvim_win_set_height

  self._saved_size = get(self.result_win)
  if is_vertical then
    self._saved_winmin = vim.o.winminwidth
    vim.o.winminwidth = 0
  else
    self._saved_winmin = vim.o.winminheight
    vim.o.winminheight = 0
  end
  pcall(set, self.result_win, is_vertical and vim.o.columns or vim.o.lines)
  self._zoomed = true
end

--- Exit zoom: restore the window minimums and the saved size. Idempotent.
function Sidebar:_exit_zoom()
  if not self._zoomed then
    return
  end
  local is_vertical = self:_is_vertical()

  if is_vertical then
    vim.o.winminwidth = self._saved_winmin or vim.o.winminwidth
  else
    vim.o.winminheight = self._saved_winmin or vim.o.winminheight
  end
  if self:is_open() then
    local set = is_vertical and api.nvim_win_set_width or api.nvim_win_set_height
    local size = self._saved_size
      or math.floor((is_vertical and vim.o.columns or vim.o.lines) * self._config.sidebar.width / 100)
    pcall(set, self.result_win, size)
  end

  self._zoomed = false
  self._saved_size = nil
  self._saved_winmin = nil
end

--- tmux-style zoom toggle: grow the emeth column/row to fill the screen and
--- back. A pure resize of existing windows — nothing is created or closed — so
--- it can't trip the WinClosed teardown the way `<C-w>o`/`:only` does. The input
--- window shares the result window's column/row, so resizing it carries along.
function Sidebar:toggle_zoom()
  if not self:is_open() then
    return
  end
  if self._zoomed then
    self:_exit_zoom()
  else
    self:_enter_zoom()
  end
end

function Sidebar:_setup_keymaps()
  local config = self._config
  local view = self.view
  if not view then
    return
  end

  local close_keys = config.mappings.close.normal
  if type(close_keys) == "string" then
    close_keys = { close_keys }
  end
  for _, key in ipairs(close_keys or {}) do
    for _, buf in ipairs({ view.result_buf, view.input_buf }) do
      if api.nvim_buf_is_valid(buf) then
        api.nvim_buf_set_keymap(buf, "n", key, "", {
          noremap = true,
          silent = true,
          callback = function()
            self:close()
          end,
        })
      end
    end
  end

  local switch_key = config.mappings.switch_window.normal
  if switch_key then
    for _, buf in ipairs({ view.result_buf, view.input_buf }) do
      if api.nvim_buf_is_valid(buf) then
        api.nvim_buf_set_keymap(buf, "n", switch_key, "", {
          noremap = true,
          silent = true,
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

  local zoom_keys = config.mappings.zoom and config.mappings.zoom.normal
  if type(zoom_keys) == "string" then
    zoom_keys = { zoom_keys }
  end
  for _, key in ipairs(zoom_keys or {}) do
    for _, buf in ipairs({ view.result_buf, view.input_buf }) do
      if api.nvim_buf_is_valid(buf) then
        api.nvim_buf_set_keymap(buf, "n", key, "", {
          noremap = true,
          silent = true,
          callback = function()
            self:toggle_zoom()
          end,
        })
      end
    end
  end

  local function cycle_window()
    local cur = api.nvim_get_current_win()
    if cur == self.result_win then
      self:focus_input()
      vim.cmd("startinsert")
    else
      vim.cmd("stopinsert")
      self:focus_result()
    end
  end
  for _, buf in ipairs({ view.result_buf, view.input_buf }) do
    if api.nvim_buf_is_valid(buf) then
      api.nvim_buf_set_keymap(buf, "n", "<Tab>", "", { noremap = true, silent = true, callback = cycle_window })
      api.nvim_buf_set_keymap(buf, "i", "<Tab>", "", { noremap = true, silent = true, callback = cycle_window })
      api.nvim_buf_set_keymap(buf, "n", "<S-Tab>", "", { noremap = true, silent = true, callback = cycle_window })
      api.nvim_buf_set_keymap(buf, "i", "<S-Tab>", "", { noremap = true, silent = true, callback = cycle_window })
    end
  end
end

return Sidebar
