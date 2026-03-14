--- Winbar — centered status on the input separator bar (close to cursor),
--- minimal title on the result window.
local api = vim.api
local M = {}
local spinner_frames = { "⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏" }
local spinner_idx = 0
local spinner_timer = nil
local context_pct = nil
---@type number|nil
local result_win = nil
---@type number|nil
local input_win = nil
local opts = {} ---@type { provider?: string }
---@alias EmethWinbarState "connecting"|"ready"|"generating"|"compacting"
local state = "ready" ---@type EmethWinbarState
-- Fallback colors when colorscheme doesn't define expected groups (One Dark palette)
local function get_hl_color(name, attr, fallback)
  local hl = api.nvim_get_hl(0, { name = name, link = false })
  return hl[attr] and string.format("#%06x", hl[attr]) or fallback
end

-- Fallback colors when colorscheme doesn't define expected groups (One Dark palette)
local FALLBACK_BG = "#1e222a" -- NormalFloat bg
local FALLBACK_MUTED = "#5c6370" -- Comment fg / FloatBorder fg
local FALLBACK_BLUE = "#61afef" -- DiagnosticInfo fg
local FALLBACK_GREEN = "#98c379" -- DiagnosticOk fg
local FALLBACK_YELLOW = "#e5c07b" -- DiagnosticWarn fg
local FALLBACK_RED = "#e06c75" -- DiagnosticError fg

local function blend(a, b, t)
  local ar, ag, ab = tonumber(a:sub(2, 3), 16) or 0, tonumber(a:sub(4, 5), 16) or 0, tonumber(a:sub(6, 7), 16) or 0
  local br, bg, bb = tonumber(b:sub(2, 3), 16) or 0, tonumber(b:sub(4, 5), 16) or 0, tonumber(b:sub(6, 7), 16) or 0
  local function clamp(v)
    return math.max(0, math.min(255, math.floor(v)))
  end
  return string.format("#%02x%02x%02x", clamp(ar + (br - ar) * t), clamp(ag + (bg - ag) * t), clamp(ab + (bb - ab) * t))
end
-- ── Rendering ──────────────────────────────────────────────────
local hl_cache = {}
local function set_hl(name, val)
  local key = name
  local cached = hl_cache[key]
  if
    cached
    and cached.fg == val.fg
    and cached.bg == val.bg
    and cached.bold == val.bold
    and cached.italic == val.italic
  then
    return
  end
  hl_cache[key] = val
  api.nvim_set_hl(0, name, val)
end
local function render()
  local bg = get_hl_color("NormalFloat", "bg", FALLBACK_BG)
  local fg_muted = get_hl_color("Comment", "fg", FALLBACK_MUTED)
  -- ── Result window: static title ──
  if result_win and api.nvim_win_is_valid(result_win) then
    set_hl("EmethWinbarFill", { bg = bg })
    set_hl("EmethWinbarTitle", { fg = fg_muted, bg = bg, italic = true })
    set_hl("EmethWinbarInfo", { fg = fg_muted, bg = bg })
    local left = opts.provider and ("%#EmethWinbarInfo#" .. opts.provider) or ""
    local left_w = opts.provider and #opts.provider or 0
    local right = ""
    local right_w = 0
    if context_pct then
      local c_ok = get_hl_color("DiagnosticOk", "fg", FALLBACK_GREEN)
      local c_warn = get_hl_color("DiagnosticWarn", "fg", FALLBACK_YELLOW)
      local c_err = get_hl_color("DiagnosticError", "fg", FALLBACK_RED)
      local ctx_fg = context_pct <= 50 and blend(c_ok, c_warn, context_pct / 50)
        or blend(c_warn, c_err, (context_pct - 50) / 50)
      set_hl("EmethWinbarCtx", { fg = ctx_fg, bg = bg, bold = true })
      right = "%#EmethWinbarCtx#" .. string.format("%.0f%%%% ", context_pct)
      right_w = #string.format("%.0f%% ", context_pct)
    end
    -- Balance sides so %= truly centers the title
    local lpad = right_w > left_w and ("%#EmethWinbarFill#" .. string.rep(" ", right_w - left_w)) or ""
    local rpad = left_w > right_w and ("%#EmethWinbarFill#" .. string.rep(" ", left_w - right_w)) or ""
    local title = require("emeth").config.show_title and "── ✦ אמת ──" or ""
    pcall(
      api.nvim_set_option_value,
      "winbar",
      "%#EmethWinbarFill#" .. left .. lpad .. "%=%#EmethWinbarTitle#" .. title .. "%=" .. rpad .. right,
      { win = result_win }
    )
  end
  -- ── Input separator: ──── status ──── ──
  if not input_win or not api.nvim_win_is_valid(input_win) then
    return
  end
  local label, label_hl
  local sep_fg = get_hl_color("FloatBorder", "fg", FALLBACK_MUTED)
  if state == "connecting" then
    local frame = spinner_frames[(spinner_idx % #spinner_frames) + 1]
    label = " " .. frame .. " connecting "
    label_hl = get_hl_color("DiagnosticInfo", "fg", FALLBACK_BLUE)
  elseif state == "generating" then
    local frame = spinner_frames[(spinner_idx % #spinner_frames) + 1]
    label = " " .. frame .. " generating "
    label_hl = get_hl_color("DiagnosticWarn", "fg", FALLBACK_YELLOW)
  elseif state == "compacting" then
    local frame = spinner_frames[(spinner_idx % #spinner_frames) + 1]
    label = " " .. frame .. " compacting "
    label_hl = get_hl_color("DiagnosticError", "fg", FALLBACK_RED)
  else
    label = " ● ready "
    label_hl = get_hl_color("DiagnosticOk", "fg", FALLBACK_GREEN)
  end
  api.nvim_set_hl(0, "EmethSepLine", { fg = sep_fg, bg = bg })
  api.nvim_set_hl(0, "EmethSepLabel", { fg = label_hl, bg = bg, bold = true })
  local win_w = api.nvim_win_get_width(input_win)
  local label_w = vim.fn.strdisplaywidth(label)
  local side = math.max(0, math.floor((win_w - label_w) / 2))
  pcall(
    api.nvim_set_option_value,
    "winbar",
    "%#EmethSepLine#"
      .. string.rep("─", side)
      .. "%#EmethSepLabel#"
      .. label
      .. "%#EmethSepLine#"
      .. string.rep("─", side),
    { win = input_win }
  )
end
local function start_timer()
  if spinner_timer then
    return
  end
  spinner_timer = vim.uv.new_timer()
  spinner_timer:start(
    0,
    80,
    vim.schedule_wrap(function()
      spinner_idx = spinner_idx + 1
      render()
    end)
  )
end
local function stop_timer()
  if spinner_timer then
    spinner_timer:stop()
    spinner_timer:close()
    spinner_timer = nil
  end
end
-- ── Public API ─────────────────────────────────────────────────
---@param win number
---@param iwin? number
---@param new_opts? { provider?: string }
function M.attach(win, iwin, new_opts)
  result_win = win
  input_win = iwin
  opts = new_opts or opts
  render()
end
function M.detach()
  stop_timer()
  if result_win and api.nvim_win_is_valid(result_win) then
    pcall(api.nvim_set_option_value, "winbar", "", { win = result_win })
  end
  if input_win and api.nvim_win_is_valid(input_win) then
    pcall(api.nvim_set_option_value, "winbar", "", { win = input_win })
  end
  result_win = nil
  input_win = nil
  state = "ready"
end
---@param s EmethWinbarState
function M.set_state(s)
  if state == s then
    return
  end
  state = s
  if s == "connecting" or s == "generating" or s == "compacting" then
    spinner_idx = 0
    start_timer()
  else
    stop_timer()
  end
  render()
end
---@return number|nil
function M.get_context()
  return context_pct
end
---@param pct number 0-100
function M.set_context(pct)
  context_pct = pct
  render()
end
return M
