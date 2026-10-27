--- Session validity — can an indexed session still be resumed?
---
--- The picker's only signal used to be `isdirectory(cwd)`. That catches a deleted
--- workspace but not a session the *provider* has forgotten: claude prunes idle
--- transcripts, kiro sweeps its store against a disk budget. Resuming either hands
--- the agent an id it no longer knows. This module answers the real question per
--- provider, read-only, with no live agent connection — the same way the built-in
--- resume pickers do it.
---
--- Both claude-code and kiro-cli (v3 engine) keep one `<id>.jsonl` transcript per
--- session, so validity is a single `fs_stat` of a provider-resolved path.
---
--- Three verdicts:
---   "valid" — resumable now.
---   "stale" — still on disk but eligible for the provider's own pruning, so it
---             will vanish on the provider's next launch (claude only; mtime past
---             the retention window). Shown, dimmed — not yet removed.
---   "gone"  — not resumable; nothing to load.
---
--- Dispatch is by `entry.provider`. Providers without a known transcript location
--- fall back to the directory check (the historical behaviour).

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

---Per-provider transcript location. Claude keys its store by working dir, so an
---entry without one has no transcript; kiro's store is global (`$KIRO_HOME`,
---default `~/.kiro`, then `sessions/cli/`), so cwd doesn't matter.
---@type table<string, fun(entry: table, home: string): string|nil>
local TRANSCRIPT = {
  ["claude-code"] = function(entry, home)
    local cwd = entry.cwd or ""
    if cwd == "" then
      return nil
    end
    return M.claude_transcript_path(cwd, entry.session_id, home)
  end,
  ["kiro-cli"] = function(entry, home)
    local kiro_home = vim.env.KIRO_HOME
    if not kiro_home or kiro_home == "" then
      kiro_home = home .. "/.kiro"
    end
    return ("%s/sessions/cli/%s.jsonl"):format(kiro_home, entry.session_id)
  end,
}

---Absolute path of the transcript backing a session, or nil when the provider
---has no known per-session file (or the entry can't have one).
---@param entry table  { provider, cwd, session_id }
---@param home string
---@return string|nil
function M.transcript_path(entry, home)
  local resolve = TRANSCRIPT[entry.provider]
  return resolve and resolve(entry, home) or nil
end

---On-disk size, in bytes, of the transcript backing a session -- or nil when
---there is no per-session file to stat. Sidecar files (e.g. claude's
---`<id>/subagents/`) are deliberately not counted: the main transcript dominates
---and this keeps the picker's per-row cost to a single `fs_stat`. Note this is
---raw disk footprint -- most of a claude transcript is api-request logging, not
---rendered conversation.
---@param entry table  { provider, cwd, session_id }
---@param home? string  defaults to the real home dir
---@return integer|nil bytes
function M.transcript_size(entry, home)
  local path = M.transcript_path(entry, home or vim.fn.expand("~"))
  if not path then
    return nil
  end
  local st = vim.uv.fs_stat(path)
  return st and st.size or nil
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

---Build the injectable environment with real defaults. Tests pass their own.
---@return table env  { now, home, file_mtime, read_json }
function M.default_env()
  return {
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
  }
end

---@param entry table  { session_id, provider, cwd, ... }
---@param env? table   injectable; defaults to the real filesystem and clock
---@return "valid"|"stale"|"gone"
function M.check(entry, env)
  env = env or M.default_env()
  local cwd = entry.cwd or ""

  if not TRANSCRIPT[entry.provider] then
    -- Fallback (gemini/codex/goose/unknown): the historical directory check.
    return vim.fn.isdirectory(cwd) == 1 and "valid" or "gone"
  end

  local path = M.transcript_path(entry, env.home)
  local mtime = path and env.file_mtime(path)
  if not mtime then
    return "gone"
  end

  -- Only claude prunes by age, so only claude can be predicted "stale". kiro's
  -- sweep is disk-budget driven and can't be anticipated from one file.
  if entry.provider == "claude-code" then
    local days = M.claude_retention_days(cwd, env.home, env.read_json)
    local age_days = (env.now - mtime) / 86400
    return age_days >= days and "stale" or "valid"
  end
  return "valid"
end

---Verdicts for a whole index in one pass, keyed by session_id.
---@param entries table[]
---@param env? table
---@return table<string, "valid"|"stale"|"gone">
function M.check_all(entries, env)
  env = env or M.default_env()
  local verdicts = {}
  for _, e in ipairs(entries) do
    verdicts[e.session_id] = M.check(e, env)
  end
  return verdicts
end

return M
