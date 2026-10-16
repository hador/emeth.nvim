--- Session validity — can an indexed session still be resumed?
---
--- The picker's only signal used to be `isdirectory(cwd)`. That catches a deleted
--- workspace but not a session the *provider* has forgotten: claude prunes idle
--- transcripts, kiro drops conversations. Resuming either hands the agent an id it
--- no longer knows. This module answers the real question per provider, read-only,
--- with no live agent connection — the same way the built-in resume pickers do it.
---
--- Three verdicts:
---   "valid" — resumable now.
---   "stale" — still on disk but eligible for the provider's own pruning, so it
---             will vanish on the provider's next launch (claude only; mtime past
---             the retention window). Shown, dimmed — not yet removed.
---   "gone"  — not resumable; nothing to load.
---
--- Dispatch is by `entry.provider`. Unknown providers fall back to the directory
--- check (the historical behaviour), and any check that can't reach its store
--- (missing `sqlite3`, unreadable db) is lenient — it returns "valid" rather than
--- nuke an entry over a tooling gap.

local M = {}

M.CLAUDE_DEFAULT_RETENTION_DAYS = 30

---`/` and `.` both map to `-`; claude names each project dir this way and nothing
---else is substituted (verified against a real `~/.claude/projects`).
---@param cwd string
---@return string
function M.sanitize_cwd(cwd)
  return (cwd:gsub("[/.]", "-"))
end

---Absolute path of the claude transcript backing a session, if it existed.
---@param cwd string
---@param session_id string
---@param home string
---@return string
function M.claude_transcript_path(cwd, session_id, home)
  return ("%s/.claude/projects/%s/%s.jsonl"):format(home, M.sanitize_cwd(cwd), session_id)
end

---Resolve `cleanupPeriodDays` from the settings cascade, later file winning,
---default 30. Order mirrors claude's own precedence for emeth's purposes:
---user (~/.claude) < project (<cwd>/.claude) < project-local.
---@param cwd string
---@param home string
---@param read_json fun(path: string): table|nil
---@return integer
function M.claude_retention_days(cwd, home, read_json)
  local days = M.CLAUDE_DEFAULT_RETENTION_DAYS
  local files = {
    home .. "/.claude/settings.json",
    cwd .. "/.claude/settings.json",
    cwd .. "/.claude/settings.local.json",
  }
  for _, f in ipairs(files) do
    local data = read_json(f)
    if type(data) == "table" and type(data.cleanupPeriodDays) == "number" then
      days = math.floor(data.cleanupPeriodDays)
    end
  end
  return days
end

---Default macOS/Linux locations for the kiro-cli session store.
---@param home string
---@return string[]
local function kiro_db_candidates(home)
  return {
    home .. "/Library/Application Support/kiro-cli/data.sqlite3", -- macOS
    home .. "/.local/share/kiro-cli/data.sqlite3", -- XDG / Linux
  }
end

---One sqlite round-trip for a whole batch of kiro ids: returns the set of ids
---that have a row, or nil when the store can't be reached (so callers stay
---lenient). Factored out so both the single and batched checks share it.
---@param ids string[]
---@param home string
---@return table<string, true>|nil
local function kiro_present_set(ids, home)
  if #ids == 0 then
    return {}
  end
  if vim.fn.executable("sqlite3") ~= 1 then
    return nil
  end
  local quoted = {}
  for _, id in ipairs(ids) do
    -- UUIDs only; anything else is skipped rather than interpolated into SQL.
    if id:match("^[%w%-]+$") then
      quoted[#quoted + 1] = "'" .. id .. "'"
    end
  end
  if #quoted == 0 then
    return {}
  end
  local db
  for _, c in ipairs(kiro_db_candidates(home)) do
    if vim.fn.filereadable(c) == 1 then
      db = c
      break
    end
  end
  if not db then
    return nil
  end
  local sql = ("SELECT conversation_id FROM conversations_v2 WHERE conversation_id IN (%s);"):format(
    table.concat(quoted, ",")
  )
  local out = vim.fn.system({ "sqlite3", db, sql })
  if vim.v.shell_error ~= 0 then
    return nil
  end
  local present = {}
  for line in vim.gsplit(out, "\n", { plain = true }) do
    line = vim.trim(line)
    if line ~= "" then
      present[line] = true
    end
  end
  return present
end

---Build the injectable environment with real defaults. Tests pass their own.
---@return table env  { now, home, file_mtime, read_json, kiro_present, kiro_present_set }
function M.default_env()
  return {
    kiro_present_set = kiro_present_set,
    now = os.time(),
    home = vim.fn.expand("~"),
    file_mtime = function(path)
      local st = vim.uv.fs_stat(path)
      return st and st.mtime and st.mtime.sec or nil
    end,
    read_json = function(path)
      if vim.fn.filereadable(path) ~= 1 then
        return nil
      end
      local ok, data = pcall(function()
        return vim.json.decode(table.concat(vim.fn.readfile(path), "\n"))
      end)
      return ok and type(data) == "table" and data or nil
    end,
    -- nil = couldn't determine (tooling/db absent); true/false = definite answer.
    kiro_present = function(session_id, home)
      local set = kiro_present_set({ session_id }, home)
      if set == nil then
        return nil
      end
      return set[session_id] == true
    end,
  }
end

---@param entry table  { session_id, provider, cwd, ... }
---@param env? table   injectable; defaults to real filesystem/clock/sqlite
---@return "valid"|"stale"|"gone"
function M.check(entry, env)
  env = env or M.default_env()
  local cwd = entry.cwd or ""

  if entry.provider == "claude-code" then
    -- A missing working dir can't host a transcript; treat as gone up front so a
    -- deleted workspace reads the same regardless of provider.
    if cwd == "" then
      return "gone"
    end
    local path = M.claude_transcript_path(cwd, entry.session_id, env.home)
    local mtime = env.file_mtime(path)
    if not mtime then
      return "gone"
    end
    local days = M.claude_retention_days(cwd, env.home, env.read_json)
    local age_days = (env.now - mtime) / 86400
    return age_days >= days and "stale" or "valid"
  end

  if entry.provider == "kiro-cli" then
    local present = env.kiro_present(entry.session_id, env.home)
    if present == nil then
      return "valid" -- couldn't check — don't prune over a tooling gap
    end
    return present and "valid" or "gone"
  end

  -- Fallback (gemini/codex/goose/unknown): the historical directory check.
  return vim.fn.isdirectory(cwd) == 1 and "valid" or "gone"
end

---Verdicts for a whole index in one pass, keyed by session_id. Identical in
---meaning to calling `check` per entry, but kiro's rows are fetched with a single
---batched sqlite query rather than one shell-out per session — the picker builds
---this over the entire index on every open.
---@param entries table[]
---@param env? table
---@return table<string, "valid"|"stale"|"gone">
function M.check_all(entries, env)
  env = env or M.default_env()

  local kiro_ids = {}
  for _, e in ipairs(entries) do
    if e.provider == "kiro-cli" then
      kiro_ids[#kiro_ids + 1] = e.session_id
    end
  end
  -- Not the `and/or` idiom: a nil return (store unreachable) must survive as nil
  -- so the loop below can stay lenient, not collapse to an empty set ⇒ all gone.
  local kiro_set = {}
  if #kiro_ids > 0 then
    kiro_set = env.kiro_present_set(kiro_ids, env.home)
  end

  local verdicts = {}
  for _, e in ipairs(entries) do
    if e.provider == "kiro-cli" then
      -- nil set = store unreachable; stay lenient rather than prune.
      verdicts[e.session_id] = (kiro_set == nil or kiro_set[e.session_id]) and "valid" or "gone"
    else
      verdicts[e.session_id] = M.check(e, env)
    end
  end
  return verdicts
end

return M
