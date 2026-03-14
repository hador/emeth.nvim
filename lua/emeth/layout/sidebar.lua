--- Sidebar layout — arranges ChatView buffers in a vertical/horizontal split.

local api = vim.api

---@class chat_ui.SidebarLayout
---@field view chat_ui.ChatView|nil
---@field result_win number|nil
---@field input_win number|nil
---@field _config chat_ui.Config
---@field _augroup number
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
