--- Cross-directory session picker — "where was I?" across every project.
---
--- The per-directory history (`:EmethHistory`) answers "what did I do *here*".
--- This answers the harder one: you remember the conversation, not the folder it
--- lived in. The local index is global (every session, with the cwd it ran in),
--- so the list is built from it rather than from the agent's `session/list`,
--- which is scoped to one cwd and needs a live connection.
---
--- Sessions whose directory has since been deleted are dropped, not dimmed:
--- resuming one cannot work (the agent is handed that cwd), and in a real index
--- they were 41% of entries — mostly transient per-review workspaces. The count
--- is reported so they aren't hidden silently.

local Sessions = require("emeth.sessions")

local M = {}

---Seconds between two `os.date("!%Y-%m-%dT%H:%M:%SZ")` stamps.
---
---Both sides are parsed with `os.time`, which reads the table as *local* time.
---That is wrong for a UTC stamp, but identically wrong for both, so the bias
---cancels in the subtraction — which avoids needing a timezone offset at all.
---@param iso string
---@param now_iso string
---@return integer|nil
local function seconds_since(iso, now_iso)
  local function epoch(s)
    if type(s) ~= "string" then
      return nil
    end
    local y, mo, d, h, mi, sec = s:match("(%d+)-(%d+)-(%d+)T(%d+):(%d+):(%d+)Z")
    if not y then
      return nil
    end
    -- `or 0` only to satisfy the type checker: the pattern already matched digits.
    return os.time({
      year = tonumber(y) or 0,
      month = tonumber(mo) or 0,
      day = tonumber(d) or 0,
      hour = tonumber(h) or 0,
      min = tonumber(mi) or 0,
      sec = tonumber(sec) or 0,
      isdst = false,
    })
  end
  local a, b = epoch(now_iso), epoch(iso)
  if not a or not b then
    return nil
  end
  return a - b
end

---Coarse age, in the largest unit that still reads as a number.
---@param iso string  UTC stamp from the index
---@param now_iso? string  injectable for tests
---@return string
function M.ago(iso, now_iso)
  local now = now_iso or os.date("!%Y-%m-%dT%H:%M:%SZ") --[[@as string]]
  local diff = seconds_since(iso, now)
  if not diff then
    return "?"
  end
  if diff < 0 then
    diff = 0
  end
  local units = {
    { 60, 1, "s" },
    { 3600, 60, "m" },
    { 86400, 3600, "h" },
    { 604800, 86400, "d" },
    { 2592000, 604800, "w" },
    { math.huge, 2592000, "mo" },
  }
  for _, u in ipairs(units) do
    if diff < u[1] then
      return ("%d%s"):format(math.floor(diff / u[2]), u[3])
    end
  end
  return "?"
end

local TITLE_MAX = 60
local DIR_MAX = 30

---Trim to `max` characters, adding an ellipsis when anything was cut.
---@param s string
---@param max integer
---@return string
local function clamp(s, max)
  -- Byte length bounds character length, so the cheap test gates the vim call.
  if #s <= max or vim.fn.strchars(s) <= max then
    return s
  end
  return vim.fn.strcharpart(s, 0, max) .. "…"
end

---A directory short enough for a one-line label but still identifying.
---
---A bare basename is ambiguous in a Brazil-shaped tree, where a dozen projects
---all end in `src` — so long paths keep their parent too. `src` itself is skipped
---when it would *be* that parent: for `.../FTV/FOS/src/FireTvLauncher` the useful
---pair is `FOS/FireTvLauncher`, not `src/FireTvLauncher`.
---@param dir string
---@return string
function M.short_dir(dir)
  if type(dir) ~= "string" or dir == "" then
    return "?"
  end
  local home = vim.fn.expand("~")
  if dir == home then
    return "~"
  end
  local tilde = vim.fn.fnamemodify(dir, ":~")
  if #tilde <= DIR_MAX then
    return tilde
  end
  local base = vim.fn.fnamemodify(dir, ":t")
  local head = vim.fn.fnamemodify(dir, ":h")
  local parent = vim.fn.fnamemodify(head, ":t")
  if parent == "src" then
    parent = vim.fn.fnamemodify(head, ":h:t")
  end
  return parent ~= "" and (parent .. "/" .. base) or base
end

---Build the picker rows: most recent first, unreachable directories removed.
---@param entries table[]  raw index entries
---@param now_iso? string  injectable for tests
---@return table[] items, integer dropped
function M.items(entries, now_iso)
  local items, dropped = {}, 0
  for _, e in ipairs(entries) do
    if vim.fn.isdirectory(e.cwd or "") ~= 1 then
      dropped = dropped + 1
    else
      -- Titles need clamping, not just wrapping: most are the first prompt
      -- (capped at 80 bytes), but an agent-sent one reached 201 characters in a
      -- real index, which buries the directory and age that follow it.
      items[#items + 1] = {
        entry = e,
        label = ("%s  ·  %s  ·  %s"):format(
          clamp(e.title or e.session_id:sub(1, 8), TITLE_MAX),
          M.short_dir(e.cwd),
          M.ago(e.updated_at or e.created_at, now_iso)
        ),
      }
    end
  end
  return items, dropped
end

---Prompt for a session across all directories.
---@param on_pick fun(entry: table)
function M.open(on_pick)
  local items, dropped = M.items(Sessions.list_all())
  if #items == 0 then
    vim.notify(
      dropped > 0 and ("[emeth] No resumable sessions (%d point at deleted directories)"):format(dropped)
        or "[emeth] No sessions recorded yet",
      vim.log.levels.INFO
    )
    return
  end
  local prompt = dropped > 0 and ("Resume session (%d hidden, directory gone):"):format(dropped) or "Resume session:"
  vim.ui.select(items, {
    prompt = prompt,
    format_item = function(item)
      return item.label
    end,
  }, function(choice)
    if choice then
      on_pick(choice.entry)
    end
  end)
end

return M
