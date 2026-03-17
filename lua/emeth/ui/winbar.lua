--- Winbar — two fungible segments (left/right) with a centered title.
--- Providers decide what goes in each segment via set_left / set_right.
--- Built-in formatters (Winbar.fmt.*) produce ready-to-use statusline strings.

local api = vim.api
local M = {}

-- ── State ──────────────────────────────────────────────────────
local spinner_frames = { "⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏" }
local spinner_idx = 0
local spinner_timer = nil

---@type number|nil
local result_win = nil
---@type number|nil
local input_win = nil

---@alias EmethWinbarState "connecting"|"ready"|"generating"|"compacting"
local state = "ready" ---@type EmethWinbarState

--- Raw winbar strings (may contain %#Hl# escapes).
local left_raw = "" ---@type string
local right_raw = "" ---@type string

--- Plain-text versions for width measurement.
local left_plain = "" ---@type string
local right_plain = "" ---@type string

--- Numeric context percentage (preserved for message metadata).
local context_pct = nil ---@type number|nil

--- Fungible badges: provider-defined key→text pairs snapshotted into message metadata.
local badges = {} ---@type table<string, string>

-- ── Color helpers ──────────────────────────────────────────────
local FALLBACK_BG = "#1e222a"
local FALLBACK_MUTED = "#5c6370"
local FALLBACK_BLUE = "#61afef"
local FALLBACK_GREEN = "#98c379"
local FALLBACK_YELLOW = "#e5c07b"
local FALLBACK_RED = "#e06c75"

local function get_hl_color(name, attr, fallback)
  local hl = api.nvim_get_hl(0, { name = name, link = false })
  return hl[attr] and string.format("#%06x", hl[attr]) or fallback
end

local function blend(a, b, t)
  local ar, ag, ab = tonumber(a:sub(2, 3), 16) or 0, tonumber(a:sub(4, 5), 16) or 0, tonumber(a:sub(6, 7), 16) or 0
  local br, bg, bb = tonumber(b:sub(2, 3), 16) or 0, tonumber(b:sub(4, 5), 16) or 0, tonumber(b:sub(6, 7), 16) or 0
  local function clamp(v)
    return math.max(0, math.min(255, math.floor(v)))
  end
  return string.format("#%02x%02x%02x", clamp(ar + (br - ar) * t), clamp(ag + (bg - ag) * t), clamp(ab + (bb - ab) * t))
end

-- ── Highlight cache ────────────────────────────────────────────
local hl_cache = {}
local function set_hl(name, val)
  local cached = hl_cache[name]
  if
    cached
    and cached.fg == val.fg
    and cached.bg == val.bg
    and cached.bold == val.bold
    and cached.italic == val.italic
  then
    return
  end
  hl_cache[name] = val
  api.nvim_set_hl(0, name, val)
end

-- ── Formatters ─────────────────────────────────────────────────
--- Built-in formatters that return winbar-ready strings with highlight escapes.
M.fmt = {}

--- Plain text in muted color.
---@param text string
---@return string raw, string plain
function M.fmt.plain(text)
  return "%#EmethWinbarInfo#" .. text, text
end

--- Text with a specific highlight group.
---@param text string
---@param hl string highlight group name
---@return string raw, string plain
function M.fmt.badge(text, hl)
  return "%#" .. hl .. "#" .. text, text
end

--- Percentage with green→yellow→red gradient.
---@param pct number 0-100
---@return string raw, string plain
function M.fmt.gradient(pct)
  local c_ok = get_hl_color("DiagnosticOk", "fg", FALLBACK_GREEN)
  local c_warn = get_hl_color("DiagnosticWarn", "fg", FALLBACK_YELLOW)
  local c_err = get_hl_color("DiagnosticError", "fg", FALLBACK_RED)
  local bg = get_hl_color("NormalFloat", "bg", FALLBACK_BG)
  local fg = pct <= 50 and blend(c_ok, c_warn, pct / 50) or blend(c_warn, c_err, (pct - 50) / 50)
  set_hl("EmethWinbarGrad", { fg = fg, bg = bg, bold = true })
  local text = string.format("%.0f%%", pct)
  return "%#EmethWinbarGrad#" .. text:gsub("%%", "%%%%"), text
end

-- ── Truncation ─────────────────────────────────────────────────
--- Strip %#...# highlight escapes to get plain text.
---@param s string
---@return string
local function strip_hl(s)
  return (s:gsub("%%#[^#]*#", ""))
end

--- Truncate a plain string to max display width, appending … if cut.
---@param s string
---@param max number
---@return string
local function trunc_plain(s, max)
  if max <= 0 then
    return ""
  end
  if vim.fn.strdisplaywidth(s) <= max then
    return s
  end
  -- Leave room for …
  local target = max - 1
  if target <= 0 then
    return "…"
  end
  local result = vim.fn.strcharpart(s, 0, target)
  -- strcharpart counts chars not display width; trim further if needed
  while vim.fn.strdisplaywidth(result) > target and #result > 0 do
    result = vim.fn.strcharpart(result, 0, vim.fn.strchars(result) - 1)
  end
  return result .. "…"
end

-- ── Rendering ──────────────────────────────────────────────────
local MIN_GAP = 2 -- minimum space between left and right when title is dropped

local function render()
  local bg = get_hl_color("NormalFloat", "bg", FALLBACK_BG)
  local fg_muted = get_hl_color("Comment", "fg", FALLBACK_MUTED)

  -- ── Result window ──
  if result_win and api.nvim_win_is_valid(result_win) then
    set_hl("EmethWinbarFill", { bg = bg })
    set_hl("EmethWinbarTitle", { fg = fg_muted, bg = bg, italic = true })
    set_hl("EmethWinbarInfo", { fg = fg_muted, bg = bg })

    local win_w = api.nvim_win_get_width(result_win)
    local left_w = vim.fn.strdisplaywidth(left_plain)
    local right_w = vim.fn.strdisplaywidth(right_plain)

    local title = require("emeth").config.show_title and "── ✦ אמת ──" or ""
    local title_w = vim.fn.strdisplaywidth(title)

    local l_out, r_out = left_raw, right_raw
    local total_content = left_w + right_w

    if total_content + title_w + 4 <= win_w then
      -- Tier 1: everything fits
      local lpad_n = math.max(0, right_w - left_w)
      local rpad_n = math.max(0, left_w - right_w)
      local lpad = lpad_n > 0 and ("%#EmethWinbarFill#" .. string.rep(" ", lpad_n)) or ""
      local rpad = rpad_n > 0 and ("%#EmethWinbarFill#" .. string.rep(" ", rpad_n)) or ""
      pcall(
        api.nvim_set_option_value,
        "winbar",
        "%#EmethWinbarFill#" .. l_out .. lpad .. "%=%#EmethWinbarTitle#" .. title .. "%=" .. rpad .. r_out,
        { win = result_win }
      )
    elseif total_content + MIN_GAP <= win_w then
      -- Tier 2: drop title, segments fit
      local lpad_n = math.max(0, right_w - left_w)
      local rpad_n = math.max(0, left_w - right_w)
      local lpad = lpad_n > 0 and ("%#EmethWinbarFill#" .. string.rep(" ", lpad_n)) or ""
      local rpad = rpad_n > 0 and ("%#EmethWinbarFill#" .. string.rep(" ", rpad_n)) or ""
      pcall(
        api.nvim_set_option_value,
        "winbar",
        "%#EmethWinbarFill#" .. l_out .. lpad .. "%=" .. rpad .. r_out,
        { win = result_win }
      )
    else
      -- Tier 3: proportional truncation, no title
      local avail = math.max(0, win_w - MIN_GAP)
      if total_content > 0 and avail > 0 then
        local ratio = avail / total_content
        local new_left_w = math.floor(left_w * ratio)
        local new_right_w = math.floor(right_w * ratio)
        l_out = "%#EmethWinbarInfo#" .. trunc_plain(left_plain, new_left_w)
        r_out = "%#EmethWinbarInfo#" .. trunc_plain(right_plain, new_right_w)
      else
        l_out = ""
        r_out = ""
      end
      pcall(api.nvim_set_option_value, "winbar", "%#EmethWinbarFill#" .. l_out .. "%=" .. r_out, { win = result_win })
    end
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

---@param win number result window
---@param iwin? number input window
function M.attach(win, iwin)
  result_win = win
  input_win = iwin
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
  left_raw = ""
  left_plain = ""
  right_raw = ""
  right_plain = ""
  context_pct = nil
  badges = {}
  state = "ready"
end

--- Set the left segment. Accepts a raw winbar string (may contain %#Hl# escapes).
---@param raw string
---@param plain? string plain-text version for width measurement (auto-stripped if omitted)
function M.set_left(raw, plain)
  left_raw = raw
  left_plain = plain or strip_hl(raw)
  render()
end

--- Set the right segment. Accepts a raw winbar string (may contain %#Hl# escapes).
---@param raw string
---@param plain? string plain-text version for width measurement (auto-stripped if omitted)
function M.set_right(raw, plain)
  right_raw = raw
  right_plain = plain or strip_hl(raw)
  render()
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

--- Convenience: set right segment to a gradient-colored percentage.
--- Equivalent to set_right(Winbar.fmt.gradient(pct)).
---@param pct number 0-100
function M.set_context(pct)
  context_pct = pct
  local raw, plain = M.fmt.gradient(pct)
  M.set_right(raw .. " ", plain .. " ")
  M.set_badge("ctx", string.format("ctx %.0f%%", pct))
end

---@return number|nil
function M.get_context()
  return context_pct
end

---@return string
function M.get_left()
  return left_plain
end

---@return string
function M.get_right()
  return right_plain
end

--- Set a named badge. Badges are snapshotted into message metadata at send time.
---@param key string
---@param text string
function M.set_badge(key, text)
  badges[key] = text
end

--- Remove a named badge.
---@param key string
function M.clear_badge(key)
  badges[key] = nil
end

--- Snapshot current badges as an ordered list of strings.
---@return string[]
function M.get_badges()
  local out = {}
  for _, v in pairs(badges) do
    out[#out + 1] = v
  end
  return out
end

return M
