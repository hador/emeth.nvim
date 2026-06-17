--- Tests for Sidebar layout — focused on tmux-style zoom (toggle_zoom).

local h = require("tests.helpers")

-- An earlier test (test_render) replaces package.loaded["emeth"] with a stub
-- and never restores it. Force a clean reload so we get the real module.
package.loaded["emeth"] = nil
require("emeth").setup({})

local ChatView = require("emeth.ui.chat_view")
local Sidebar = require("emeth.layout.sidebar")

--- Open a sidebar with a real view on a wide-enough screen.
local function make_open_sidebar()
  vim.o.columns = 200
  vim.o.lines = 50
  local view = ChatView:new({ config = require("emeth").config })
  local sb = Sidebar:new(require("emeth").config)
  sb:open(view)
  return sb, view
end

h.describe("Sidebar:toggle_zoom", function()
  h.it("grows to fill then restores the saved size", function()
    local sb = make_open_sidebar()
    local win = sb.result_win
    local before = vim.api.nvim_win_get_width(win)

    sb:toggle_zoom()
    h.is_true(sb._zoomed, "should be zoomed")
    h.eq(before, sb._saved_size)
    h.is_true(vim.api.nvim_win_get_width(win) > before, "width should grow when zoomed")

    sb:toggle_zoom()
    h.eq(false, sb._zoomed)
    h.is_nil(sb._saved_size)
    h.eq(before, vim.api.nvim_win_get_width(win))

    sb:close()
  end)

  h.it("keeps all windows alive while zoomed (no :only cascade)", function()
    local sb = make_open_sidebar()
    local n_before = #vim.api.nvim_tabpage_list_wins(0)
    sb:toggle_zoom()
    h.eq(n_before, #vim.api.nvim_tabpage_list_wins(0))
    h.is_true(vim.api.nvim_win_is_valid(sb.result_win), "result win survives zoom")
    h.is_true(vim.api.nvim_win_is_valid(sb.input_win), "input win survives zoom")
    sb:close()
  end)

  h.it("drops winminwidth to 0 while zoomed and restores it", function()
    vim.o.winminwidth = 1
    local sb = make_open_sidebar()
    sb:toggle_zoom()
    h.eq(0, vim.o.winminwidth) -- code window can collapse to 0 body
    sb:toggle_zoom()
    h.eq(1, vim.o.winminwidth)
    sb:close()
  end)

  h.it("does not touch laststatus (the bar is owned per-window)", function()
    vim.o.laststatus = 2
    local sb = make_open_sidebar()
    sb:toggle_zoom()
    h.eq(2, vim.o.laststatus) -- zoom must NOT fiddle with the global statusline
    sb:toggle_zoom()
    h.eq(2, vim.o.laststatus)
    sb:close()
  end)

  h.it("fills (nearly) the full width when zoomed", function()
    local sb = make_open_sidebar()
    sb:toggle_zoom()
    -- col 0 holds the collapsed code window's separator; emeth gets the rest.
    h.is_true(vim.api.nvim_win_get_width(sb.result_win) >= vim.o.columns - 1, "result should fill the screen width")
    sb:toggle_zoom()
    sb:close()
  end)

  h.it("restores winminwidth if closed while still zoomed", function()
    vim.o.winminwidth = 1
    local sb = make_open_sidebar()
    sb:toggle_zoom()
    sb:close() -- close without un-zooming first
    h.eq(1, vim.o.winminwidth)
  end)

  h.it("double-exit is idempotent", function()
    vim.o.winminwidth = 1
    local sb = make_open_sidebar()
    sb:toggle_zoom()
    sb:_exit_zoom()
    sb:_exit_zoom()
    h.eq(1, vim.o.winminwidth)
    sb:close()
  end)

  h.it("is a no-op when the sidebar is closed", function()
    local sb = Sidebar:new(require("emeth").config)
    -- Not opened.
    sb:toggle_zoom()
    h.eq(false, sb._zoomed)
  end)
end)

-- The real fix: emeth must own BOTH windows' statuslines. Leaving the input
-- window's default (filename/ruler) is what made the bottom bar look broken on
-- resize/zoom; the laststatus toggle was only masking it.
h.describe("Sidebar statusline ownership", function()
  h.it("blanks the statusline on both the result and input windows", function()
    local sb = make_open_sidebar()
    h.eq(" ", vim.api.nvim_get_option_value("statusline", { win = sb.result_win }))
    h.eq(" ", vim.api.nvim_get_option_value("statusline", { win = sb.input_win }))
    sb:close()
  end)

  h.it("keeps the input statusline flat after a manual resize", function()
    local sb = make_open_sidebar()
    -- Shrink then grow the result window (input shares the column).
    vim.o.winminwidth = 0
    pcall(vim.api.nvim_win_set_width, sb.result_win, 20)
    pcall(vim.api.nvim_win_set_width, sb.result_win, vim.o.columns)
    h.eq(" ", vim.api.nvim_get_option_value("statusline", { win = sb.input_win }))
    sb:close()
  end)
end)
