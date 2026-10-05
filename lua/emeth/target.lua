--- Source-window routing — the one place that decides "put this file in the
--- code pane, not the chat".
---
--- nvim's window model is imperative (windows are mutable handles with no
--- reactive "this buffer always lives in that window" primitive), so routing
--- itself can't be declarative. What this module buys is a declarative-reading
--- call site: callers describe intent — a path, an optional line, whether to
--- steal focus — and the mechanics (find the source window, fall back to a
--- split, jump + center, follow-vs-focus) live here, shared by every opener.
---
--- Two callers today:
---   - `gf`/`gd` in the result buffer → focus = true  (navigation gesture)
---   - the edit-follow in integrations/acp.lua → focus = false (hands-off)
---
--- The declarative *guard* is elsewhere: the sidebar sets `winfixbuf` on its
--- windows (layout/sidebar.lua), so nothing can clobber the chat even if it
--- bypasses this module — it errors instead.

local api = vim.api
local util = require("emeth.util")

local M = {}

--- Pull a `path` / `path:LINE` / `path:LINE:COL` reference out of a raw token,
--- tolerating the punctuation agents wrap paths in (backticks, quotes, parens,
--- a trailing comma or period). Pure string work — no filesystem, no window —
--- so it is unit-testable on its own.
---@param token string
---@return string|nil path, integer|nil line
function M.parse_ref(token)
  if not token or token == "" then
    return nil
  end
  -- Strip leading openers.
  token = token:gsub("^[`'\"(%[<]+", "")
  -- A :LINE(:COL) suffix, allowing trailing closers/punctuation after it.
  local path, line = token:match("^(.-):(%d+):?%d*[`'\"%)%]>,.;]*$")
  if not path then
    -- No line suffix: just peel trailing punctuation off the bare path.
    path = token:gsub("[`'\"%)%]>,.;]+$", "")
  end
  if path == "" then
    return nil
  end
  return path, line and tonumber(line) or nil
end

--- Resolve a (possibly relative) path to a readable absolute path, trying the
--- cwd and the source window's directory as bases. Returns nil if nothing on
--- disk matches — the caller surfaces that to the user.
---@param path string
---@return string|nil abs
function M.resolve(path)
  local candidates = {}
  if path:match("^~") or path:match("^/") then
    candidates[#candidates + 1] = vim.fn.fnamemodify(path, ":p")
  else
    candidates[#candidates + 1] = vim.fn.fnamemodify(vim.fn.getcwd() .. "/" .. path, ":p")
    local src = util.find_source_win()
    if src and api.nvim_win_is_valid(src) then
      local srcname = api.nvim_buf_get_name(api.nvim_win_get_buf(src))
      if srcname ~= "" then
        local dir = vim.fn.fnamemodify(srcname, ":h")
        candidates[#candidates + 1] = vim.fn.fnamemodify(dir .. "/" .. path, ":p")
      end
    end
    candidates[#candidates + 1] = vim.fn.fnamemodify(path, ":p")
  end
  for _, c in ipairs(candidates) do
    if vim.fn.filereadable(c) == 1 then
      return c
    end
  end
end

--- Resolve the file reference under the cursor in the current window.
---@return string|nil abs, integer|nil line
function M.ref_under_cursor()
  local path, line = M.parse_ref(vim.fn.expand("<cWORD>"))
  if not path then
    return nil
  end
  return M.resolve(path), line
end

---@class emeth.target.OpenOpts
---@field path string          absolute or relative path to open
---@field line? integer        1-based line to jump to and center
---@field focus? boolean        move focus to the target window (default false)
---@field win? integer          explicit target window; else the source window

--- Open `path` in the source (code) window — never in the chat.
---@param opts emeth.target.OpenOpts
---@return integer|nil win, string abs
function M.open(opts)
  local abs = vim.fn.fnamemodify(opts.path, ":p")
  local win = opts.win or util.find_source_win()
  if not win or not api.nvim_win_is_valid(win) then
    -- No code window (chat is zoomed or the only pane): peel one off. The new
    -- split inherits window-local options from the current (chat) window —
    -- including `winfixbuf` — so clear it before editing, or the edit errors.
    vim.cmd("leftabove vsplit")
    win = api.nvim_get_current_win()
    pcall(api.nvim_set_option_value, "winfixbuf", false, { win = win })
  end

  api.nvim_win_call(win, function()
    vim.cmd("edit " .. vim.fn.fnameescape(abs))
  end)

  local function place()
    if not api.nvim_win_is_valid(win) then
      return
    end
    if opts.line then
      pcall(api.nvim_win_set_cursor, win, { opts.line, 0 })
      api.nvim_win_call(win, function()
        vim.cmd("normal! zz")
      end)
    end
  end

  if opts.focus then
    api.nvim_set_current_win(win)
    place()
  else
    -- Hands-off: show it next door without yanking the cursor out of the chat.
    -- Scheduled so cursor placement lands after the edit settles.
    vim.schedule(place)
  end

  return win, abs
end

---@class emeth.target.SendBufOpts
---@field line? integer   1-based line to place the cursor on and center
---@field focus? boolean    move focus to the target window (default false)
---@field win? integer      explicit target window; else the source window

--- Display an existing buffer in the source (code) window. The handle-based
--- sibling of `open`: used by the relocation autocmd, which already has the
--- intruding buffer and wants to preserve its exact state (not re-`:edit` by
--- path, which would drop an unsaved/scratch buffer's contents).
---@param buf integer
---@param opts? emeth.target.SendBufOpts
---@return integer|nil win
function M.send_buf(buf, opts)
  opts = opts or {}
  if not api.nvim_buf_is_valid(buf) then
    return
  end
  local win = opts.win or util.find_source_win()
  if not win or not api.nvim_win_is_valid(win) then
    vim.cmd("leftabove vsplit")
    win = api.nvim_get_current_win()
    pcall(api.nvim_set_option_value, "winfixbuf", false, { win = win })
  end

  api.nvim_win_set_buf(win, buf)

  local function place()
    if not api.nvim_win_is_valid(win) then
      return
    end
    if opts.line then
      pcall(api.nvim_win_set_cursor, win, { opts.line, 0 })
      api.nvim_win_call(win, function()
        vim.cmd("normal! zz")
      end)
    end
  end

  if opts.focus then
    api.nvim_set_current_win(win)
    place()
  else
    vim.schedule(place)
  end

  return win
end

return M
