local M = {}

-- Highlight group name constants
M.USER = "EmethUser"
M.THINKING = "EmethThinking"
M.TOOL_CALLING = "EmethToolCalling"
M.TOOL_SUCCEEDED = "EmethToolSucceeded"
M.TOOL_FAILED = "EmethToolFailed"
M.DIFF_ADDED = "EmethDiffAdded"
M.DIFF_REMOVED = "EmethDiffRemoved"
M.DIFF_CONTEXT = "EmethDiffContext"
M.MUTED = "EmethMuted"
M.PROMPT_SIGN = "EmethPromptSign"
M.WIN_SEPARATOR = "EmethWinSeparator"
M.TOOL_PARAM = "EmethToolParam"
M.SUBAGENT_NEST = "EmethSubagentNest"

function M.setup()
  local set = vim.api.nvim_set_hl
  local nf = vim.api.nvim_get_hl(0, { name = "NormalFloat", link = false })
  local nf_bg = nf.bg and string.format("#%06x", nf.bg) or "#1e222a"
  local border_fg = vim.api.nvim_get_hl(0, { name = "FloatBorder", link = false }).fg
  local sep_fg = border_fg and string.format("#%06x", border_fg) or "#5c6370"

  set(0, M.USER, { default = true, link = "Title" })
  set(0, M.THINKING, { default = true, link = "Comment" })
  set(0, M.TOOL_CALLING, { default = true, link = "DiagnosticWarn" })
  set(0, M.TOOL_SUCCEEDED, { default = true, link = "DiagnosticOk" })
  set(0, M.TOOL_FAILED, { default = true, link = "DiagnosticError" })
  set(0, M.TOOL_PARAM, { default = true, link = "Special" })
  set(0, M.MUTED, { default = true, link = "Comment" })

  -- Diff backgrounds: faint wash of green/red into the float background
  local blend = require("emeth.util").blend
  local ok_fg = vim.api.nvim_get_hl(0, { name = "DiagnosticOk", link = false }).fg
  local err_fg = vim.api.nvim_get_hl(0, { name = "DiagnosticError", link = false }).fg
  local add_color = ok_fg and string.format("#%06x", ok_fg) or "#98c379"
  local del_color = err_fg and string.format("#%06x", err_fg) or "#e06c75"
  set(0, M.DIFF_ADDED, { default = true, bg = blend(nf_bg, add_color, 0.12) })
  set(0, M.DIFF_REMOVED, { default = true, bg = blend(nf_bg, del_color, 0.12) })
  local nf_fg = nf.fg and string.format("#%06x", nf.fg) or "#abb2bf"
  set(0, M.DIFF_CONTEXT, { default = true, fg = nf_fg, bg = nf.bg and nf_bg or nil })

  -- A neutral wash behind a subagent's whole block (spawn card + its nested
  -- calls) so the group reads as one region without box-drawing. Toward the
  -- border colour, stronger than the diff washes since it has no fg cue of its
  -- own and must stay legible across the blank lines it also covers.
  set(0, M.SUBAGENT_NEST, { default = true, bg = blend(nf_bg, sep_fg, 0.22) })

  local info_fg = vim.api.nvim_get_hl(0, { name = "DiagnosticInfo", link = false }).fg
  local prompt_fg = info_fg and string.format("#%06x", info_fg) or "#61afef"
  set(0, M.PROMPT_SIGN, { default = true, fg = prompt_fg, bg = nf.bg, bold = true })
  set(0, M.WIN_SEPARATOR, { fg = nf.bg, bg = nf.bg })
  -- Prevent treesitter markdown from rendering ~text~ as strikethrough in chat
  set(0, "@markup.strikethrough.markdown_inline.emeth", { strikethrough = false })
end

return M
