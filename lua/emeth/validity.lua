--- Session validity — can an indexed session still be resumed?
---
--- The picker's only signal used to be `isdirectory(cwd)`. That catches a deleted
--- workspace but not a session the *provider* has forgotten: agents prune or
--- sweep their own stores, and resuming then hands the agent an id it no longer
--- knows. This module answers the real question, read-only, with no live agent
--- connection — the same way the built-in resume pickers do it.
---
--- It knows nothing about any provider's store. A provider extension
--- (`integrations/<provider>.lua`) describes its own by exporting a
--- `session_store` (see `emeth.SessionStore`); providers without one fall back
--- to the directory check.
---
--- Three verdicts:
---   "valid" — resumable now.
---   "stale" — still on disk but eligible for the provider's own pruning, so it
---             will vanish on the provider's next launch. Only a store with an
---             `is_stale` rule can say this. Shown, dimmed — not yet removed.
---   "gone"  — not resumable; nothing to load.

local M = {}

---How a provider persists sessions, for validity checks and the picker's size
---column. Exported by a provider extension as `M.session_store`.
---@class emeth.SessionStore
---@field transcript_path fun(entry: table, home: string): string|nil  the session's transcript file; nil when the entry can't have one
---@field is_stale? fun(entry: table, mtime: integer, env: table): boolean  true when the provider will prune it on its next launch

---The provider extension's session store, if it exports one.
---@param provider? string
---@return emeth.SessionStore|nil
local function provider_store(provider)
  if type(provider) ~= "string" or provider == "" then
    return nil
  end
  local ok, ext = pcall(require, "emeth.integrations." .. provider)
  if ok and type(ext) == "table" and type(ext.session_store) == "table" then
    return ext.session_store
  end
  return nil
end

---Build the injectable environment with real defaults. Tests pass their own.
---@return table env  { now, home, file_mtime, read_json, store_for }
function M.default_env()
  return {
    now = os.time(),
    home = vim.fn.expand("~"),
    file_mtime = function(path)
      local st = vim.uv.fs_stat(path)
      return st and st.mtime and st.mtime.sec or nil
    end,
    read_json = require("emeth.util").read_json,
    store_for = provider_store,
  }
end

---Absolute path of the transcript backing a session, or nil when its provider
---has no known per-session file (or the entry can't have one).
---@param entry table  { provider, cwd, session_id }
---@param home? string  defaults to the real home dir
---@return string|nil
function M.transcript_path(entry, home)
  local store = provider_store(entry.provider)
  return store and store.transcript_path(entry, home or vim.fn.expand("~")) or nil
end

---On-disk size, in bytes, of the transcript backing a session -- or nil when
---there is no per-session file to stat. Raw disk footprint, one `fs_stat` per
---row; sidecar files (e.g. claude's `<id>/subagents/`) are not counted.
---@param entry table  { provider, cwd, session_id }
---@param home? string  defaults to the real home dir
---@return integer|nil bytes
function M.transcript_size(entry, home)
  local path = M.transcript_path(entry, home)
  if not path then
    return nil
  end
  local st = vim.uv.fs_stat(path)
  return st and st.size or nil
end

---@param entry table  { session_id, provider, cwd, ... }
---@param env? table   injectable; defaults to the real filesystem and clock
---@return "valid"|"stale"|"gone"
function M.check(entry, env)
  env = env or M.default_env()
  local store = env.store_for(entry.provider)
  if not store then
    -- No known store: the historical directory check.
    return vim.fn.isdirectory(entry.cwd or "") == 1 and "valid" or "gone"
  end

  local path = store.transcript_path(entry, env.home)
  local mtime = path and env.file_mtime(path)
  if not mtime then
    return "gone"
  end
  if store.is_stale and store.is_stale(entry, mtime, env) then
    return "stale"
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
