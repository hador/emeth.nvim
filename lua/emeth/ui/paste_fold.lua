--- Paste folding for the chat input buffer.
---
--- A large paste collapses to a one-line placeholder; the raw text is held
--- off-buffer (keyed by an extmark on the placeholder line) and spliced back in
--- at submit time, so it never sits in the live-edited, treesitter-parsed input
--- buffer. Implemented by overriding the global `vim.paste` while the view is
--- up. The per-view state (`_pastes`, `_paste_ns`, `_paste_seq`) lives on the
--- ChatView, which exposes these as methods.

local api = vim.api

local M = {}

-- Tracks our `vim.paste` override so re-installing wraps the true original
-- rather than stacking wrapper-on-wrapper.
local _emeth_paste_orig = nil ---@type function|nil
local _emeth_paste_wrapper = nil ---@type function|nil

local fmt_size = require("emeth.util").fmt_size

--- Forget all folded-paste state and remove their placeholder extmarks.
--- Called whenever the input buffer's contents are discarded.
---@param self chat_ui.ChatView
function M.clear(self)
  self._pastes = {}
  if api.nvim_buf_is_valid(self.input_buf) then
    api.nvim_buf_clear_namespace(self.input_buf, self._paste_ns, 0, -1)
  end
end

--- Expand any intact paste placeholders in `lines` back to their stored
--- content. A placeholder is honored only if its extmark still resolves to a
--- line whose text is exactly the placeholder string — if the user edited or
--- removed that line, the entry is ignored and the line is treated literally.
---@param lines string[]
---@return string[]
---@param self chat_ui.ChatView
function M.expand(self, lines)
  if not next(self._pastes) then
    return lines
  end
  -- Map current row (0-based) → paste entry, via each entry's extmark.
  local by_row = {}
  for _, entry in pairs(self._pastes) do
    local pos = api.nvim_buf_get_extmark_by_id(self.input_buf, self._paste_ns, entry.mark, {})
    if pos and pos[1] then
      by_row[pos[1]] = entry
    end
  end
  local out = {}
  for i, line in ipairs(lines) do
    local entry = by_row[i - 1]
    if entry and line == entry.placeholder then
      for _, l in ipairs(vim.split(entry.text, "\n", { plain = true })) do
        out[#out + 1] = l
      end
    else
      out[#out + 1] = line
    end
  end
  return out
end

--- Expand the folded paste whose placeholder is on the cursor line, replacing
--- the single placeholder line with the stored content in the buffer. No-op if
--- the cursor isn't on an intact placeholder line.
---@return boolean expanded
---@param self chat_ui.ChatView
function M.expand_at_cursor(self)
  local buf = self.input_buf
  if not api.nvim_buf_is_valid(buf) or not next(self._pastes) then
    return false
  end
  local row = api.nvim_win_get_cursor(0)[1] - 1 -- 0-based
  local line = api.nvim_buf_get_lines(buf, row, row + 1, false)[1]
  for id, entry in pairs(self._pastes) do
    local pos = api.nvim_buf_get_extmark_by_id(buf, self._paste_ns, entry.mark, {})
    if pos and pos[1] == row and line == entry.placeholder then
      local content = vim.split(entry.text, "\n", { plain = true })
      api.nvim_buf_set_lines(buf, row, row + 1, false, content)
      api.nvim_buf_del_extmark(buf, self._paste_ns, entry.mark)
      self._pastes[id] = nil
      return true
    end
  end
  return false
end

--- Override `vim.paste` so large pastes into the input buffer collapse to a
--- single placeholder line, keeping the raw content out of the live-edited
--- (treesitter-parsed) buffer. Pastes into any other buffer, and small pastes,
--- fall through to the original handler untouched.
---@param buf integer input buffer handle
---@param self chat_ui.ChatView
function M.install(self, buf)
  -- Streamed pastes arrive in phases (1 start, 2 continue, 3 end); -1 is a
  -- single-shot. We buffer chunks readfile-style — within a chunk the list is
  -- newline-joined, but across chunks the last element concatenates with the
  -- next chunk's first element (|channel-lines|) — and only decide on the last
  -- chunk, since line count isn't known until then.
  local accum = nil ---@type string[]|nil

  -- Capture the underlying handler once. If our wrapper is already installed
  -- (input re-setup over the singleton buffer), reuse the original we saved
  -- rather than wrapping our own wrapper.
  local orig = (vim.paste == _emeth_paste_wrapper) and _emeth_paste_orig or vim.paste

  local function decide_and_finish()
    local lines = accum or { "" }
    accum = nil

    local config = self._config
    if not config.fold_pasted_text then
      return orig(lines, -1)
    end

    local nlines = #lines
    local nchars = #lines - 1 -- newlines between lines
    for _, l in ipairs(lines) do
      nchars = nchars + #l
    end

    if nlines < (config.paste_fold_min_lines or 10) and nchars < (config.paste_fold_min_chars or 1000) then
      -- Small paste: behave exactly like a normal non-streaming paste.
      return orig(lines, -1)
    end

    -- Fold: store content off-buffer, drop a one-line placeholder, track it
    -- with an extmark so submit-time expansion survives buffer edits.
    self._paste_seq = self._paste_seq + 1
    local id = self._paste_seq
    local placeholder = string.format("▌ pasted %d line%s (%s)", nlines, nlines == 1 and "" or "s", fmt_size(nchars))
    local text = table.concat(lines, "\n")

    -- Insert the placeholder as its own line. Deterministic placement (rather
    -- than nvim_put, whose linewise semantics leave a stray blank line when the
    -- buffer's current line is empty): replace the cursor line if it's empty,
    -- otherwise open a new line just below it.
    local cur_row = api.nvim_win_get_cursor(0)[1] -- 1-based
    local cur_line = api.nvim_buf_get_lines(buf, cur_row - 1, cur_row, false)[1] or ""
    local mark_row ---@type integer 0-based
    if cur_line == "" then
      api.nvim_buf_set_lines(buf, cur_row - 1, cur_row, false, { placeholder })
      mark_row = cur_row - 1
    else
      api.nvim_buf_set_lines(buf, cur_row, cur_row, false, { placeholder })
      mark_row = cur_row
    end
    pcall(api.nvim_win_set_cursor, 0, { mark_row + 1, #placeholder })
    local mark = api.nvim_buf_set_extmark(buf, self._paste_ns, mark_row, 0, {
      line_hl_group = "Comment",
    })
    self._pastes[id] = { text = text, placeholder = placeholder, mark = mark }
    return true
  end

  -- Our folding logic; isolated so the public wrapper can guarantee a paste is
  -- never lost to a bug here.
  local function fold_paste(lines, phase)
    local is_last = phase == -1 or phase == 3

    -- Mirror the core handler's guards: an empty chunk normalizes to one blank
    -- line, and an empty non-final streamed chunk is a no-op.
    if #lines == 0 then
      lines = { "" }
    end
    if #lines == 1 and lines[1] == "" and not is_last then
      return true
    end

    if phase == -1 then
      accum = vim.deepcopy(lines)
      return decide_and_finish()
    end

    -- Streamed: accumulate, readfile-style join across chunks.
    if phase == 1 or accum == nil or #accum == 0 then
      accum = vim.deepcopy(lines)
    else
      accum[#accum] = accum[#accum] .. (lines[1] or "")
      for i = 2, #lines do
        accum[#accum + 1] = lines[i]
      end
    end

    if phase == 3 then
      return decide_and_finish()
    end
    return true
  end

  local function wrapper(lines, phase)
    -- Self-heal: if our target buffer is gone we're a stale wrapper squatting
    -- the global (e.g. a detach was missed). Restore the original — but only if
    -- we're still the top of the chain; if another plugin wrapped over us we
    -- must not stomp it — and delegate.
    if not api.nvim_buf_is_valid(buf) then
      if vim.paste == wrapper then
        vim.paste = orig
        _emeth_paste_orig = nil
        _emeth_paste_wrapper = nil
      end
      return orig(lines, phase)
    end
    if api.nvim_get_current_buf() ~= buf then
      return orig(lines, phase)
    end
    -- A bug in folding must never swallow a paste. On error, fall back to the
    -- accumulated-or-current lines via the original handler so text still lands.
    local ok, result = pcall(fold_paste, lines, phase)
    if ok then
      return result
    end
    local fallback = accum or lines
    accum = nil
    return orig(fallback, -1)
  end

  _emeth_paste_orig = orig
  _emeth_paste_wrapper = wrapper
  vim.paste = wrapper
end

--- Tear down view-global side effects: restore the original `vim.paste` so we
--- don't squat the global after the UI is gone. Safe to call repeatedly, and a
--- no-op if another plugin has since wrapped over us (we can't safely unwrap a
--- chain we're no longer the top of).
function M.detach()
  if _emeth_paste_wrapper and vim.paste == _emeth_paste_wrapper then
    vim.paste = _emeth_paste_orig
  end
  _emeth_paste_orig = nil
  _emeth_paste_wrapper = nil
end

return M
