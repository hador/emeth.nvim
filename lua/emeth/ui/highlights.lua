local M = {}

-- Highlight group name constants
M.USER = "EmethUser"
M.ASSISTANT = "EmethAssistant"
M.THINKING = "EmethThinking"
M.TOOL_CALLING = "EmethToolCalling"
M.TOOL_SUCCEEDED = "EmethToolSucceeded"
M.TOOL_FAILED = "EmethToolFailed"
M.DIFF_ADDED = "EmethDiffAdded"
M.DIFF_REMOVED = "EmethDiffRemoved"
M.DIFF_CONTEXT = "EmethDiffContext"
M.MUTED = "EmethMuted"
M.INPUT = "EmethInput"
M.INPUT_CURSOR_LINE = "EmethInputCursorLine"
M.PROMPT_SIGN = "EmethPromptSign"
M.WIN_SEPARATOR = "EmethWinSeparator"
M.HORIZ_SEP = "EmethHorizSep"
M.TOOL_PARAM = "EmethToolParam"

function M.setup()
  local set = vim.api.nvim_set_hl
  local nf = vim.api.nvim_get_hl(0, { name = "NormalFloat", link = false })
  local nf_bg = nf.bg and string.format("#%06x", nf.bg) or "#1e222a"
  local border_fg = vim.api.nvim_get_hl(0, { name = "FloatBorder", link = false }).fg
  local sep_fg = border_fg and string.format("#%06x", border_fg) or "#5c6370"

  set(0, M.USER, { default = true, link = "Title" })
  set(0, M.ASSISTANT, { default = true, link = "Normal" })
  set(0, M.THINKING, { default = true, link = "Comment" })
  set(0, M.TOOL_CALLING, { default = true, link = "DiagnosticWarn" })
  set(0, M.TOOL_SUCCEEDED, { default = true, link = "DiagnosticOk" })
  set(0, M.TOOL_FAILED, { default = true, link = "DiagnosticError" })
  set(0, M.TOOL_PARAM, { default = true, link = "Special" })
  set(0, M.MUTED, { default = true, link = "Comment" })
  set(0, M.INPUT, { default = true, link = "NormalFloat" })
  set(0, M.INPUT_CURSOR_LINE, { default = true, link = "CursorLine" })

  -- Diff backgrounds: faint wash of green/red into the float background
  local function blend(a, b, t)
    local ar, ag, ab = tonumber(a:sub(2, 3), 16), tonumber(a:sub(4, 5), 16), tonumber(a:sub(6, 7), 16)
    local br, bg, bb = tonumber(b:sub(2, 3), 16), tonumber(b:sub(4, 5), 16), tonumber(b:sub(6, 7), 16)
    return string.format(
      "#%02x%02x%02x",
      math.floor(ar + (br - ar) * t),
      math.floor(ag + (bg - ag) * t),
      math.floor(ab + (bb - ab) * t)
    )
  end
  local ok_fg = vim.api.nvim_get_hl(0, { name = "DiagnosticOk", link = false }).fg
  local err_fg = vim.api.nvim_get_hl(0, { name = "DiagnosticError", link = false }).fg
  local add_color = ok_fg and string.format("#%06x", ok_fg) or "#98c379"
  local del_color = err_fg and string.format("#%06x", err_fg) or "#e06c75"
  set(0, M.DIFF_ADDED, { default = true, bg = blend(nf_bg, add_color, 0.12) })
  set(0, M.DIFF_REMOVED, { default = true, bg = blend(nf_bg, del_color, 0.12) })
  local nf_fg = nf.fg and string.format("#%06x", nf.fg) or "#abb2bf"
  set(0, M.DIFF_CONTEXT, { default = true, fg = nf_fg, bg = nf.bg and nf_bg or nil })

  local info_fg = vim.api.nvim_get_hl(0, { name = "DiagnosticInfo", link = false }).fg
  local prompt_fg = info_fg and string.format("#%06x", info_fg) or "#61afef"
  set(0, M.PROMPT_SIGN, { default = true, fg = prompt_fg, bg = nf.bg, bold = true })
  set(0, M.WIN_SEPARATOR, { fg = nf.bg, bg = nf.bg })
  set(0, M.HORIZ_SEP, { fg = sep_fg, bg = nf.bg and nf_bg or nil })
  -- Prevent treesitter markdown from rendering ~text~ as strikethrough in chat
  set(0, "@markup.strikethrough.markdown_inline.emeth", { strikethrough = false })
end

return M
