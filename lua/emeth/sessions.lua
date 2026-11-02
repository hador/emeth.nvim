--- Local session index: every session emeth has used, across all directories,
--- with the cwd it ran in. The source for resume and the session pickers (the
--- agent's own `session/list` is per-cwd and needs a live connection).

local M = {}

local function index_path()
  return vim.fn.stdpath("state") .. "/emeth/sessions.json"
end

---@return table[]
local function read_index()
  local data = require("emeth.util").read_json(index_path())
  if not data then
    return {}
  end
  -- Drop entries with no id. One such record (timestamps only) was found in a
  -- real index; `list` hid it because it also had no `cwd` to match, but anything
  -- that reads across directories would reach it and index a nil id.
  local entries = {}
  for _, e in ipairs(data) do
    if type(e) == "table" and type(e.session_id) == "string" and e.session_id ~= "" then
      entries[#entries + 1] = e
    end
  end
  return entries
end

---@param entries table[]
local function write_index(entries)
  local path = index_path()
  vim.fn.mkdir(vim.fn.fnamemodify(path, ":h"), "p")
  vim.fn.writefile({ vim.json.encode(entries) }, path)
end

---UTC timestamp in the index's ISO-8601 form.
---@return string
local function now_iso()
  return os.date("!%Y-%m-%dT%H:%M:%SZ") --[[@as string]]
end

---Zone shift of this machine in seconds east of UTC (positive east), measured
---against the current instant. Needed because `os.time(table)` interprets its
---fields as *local* time, while the index and the wire both speak UTC.
---@return integer
local function zone_shift()
  local now = os.time()
  return os.difftime(os.time(os.date("*t", now) --[[@as table]]), os.time(os.date("!*t", now) --[[@as table]]))
end

---Epoch seconds for an ISO-8601 timestamp, or nil if it cannot be read. `Z`
---and `±HH:MM` offsets are both honored, so foreign stamps compare correctly
---against the index's `Z` form.
---@param s string|nil
---@return integer|nil
local function iso_epoch(s)
  if type(s) ~= "string" then
    return nil
  end
  local y, mo, d, h, mi, sec = s:match("^(%d%d%d%d)-(%d%d)-(%d%d)T(%d%d):(%d%d):(%d%d)")
  if not y then
    return nil
  end
  local ok, e = pcall(os.time, {
    year = assert(tonumber(y)),
    month = assert(tonumber(mo)),
    day = assert(tonumber(d)),
    hour = assert(tonumber(h)),
    min = assert(tonumber(mi)),
    sec = assert(tonumber(sec)),
  })
  if not ok then
    return nil
  end
  e = e + zone_shift() -- read as local above; convert to the UTC reading
  local sign, oh, om = s:match("^.-([%+%-])(%d%d):(%d%d)$")
  if sign then
    e = e - (tonumber(oh) * 3600 + tonumber(om) * 60) * (sign == "+" and 1 or -1)
  end
  return e
end

---The later of two instants, rendered in the index's `Z` form. Unreadable
---stamps lose (fall back to the readable one, or the local one when neither is
---) — an import must never demote a session just used, and never store a
---stamp whose lexicographic order disagrees with its instant.
---@param local_s string|nil
---@param remote_s string|nil
---@return string|nil
local function later_iso(local_s, remote_s)
  local e1, e2 = iso_epoch(local_s), iso_epoch(remote_s)
  if not e2 then
    return local_s
  end
  if not e1 then
    return os.date("!%Y-%m-%dT%H:%M:%SZ", e2) --[[@as string]]
  end
  return os.date("!%Y-%m-%dT%H:%M:%SZ", e1 >= e2 and e1 or e2) --[[@as string]]
end

---Apply `fn` to one entry and persist, bumping its `updated_at`. No-op when
---the id isn't indexed.
---@param session_id string
---@param fn? fun(e: table)
local function update_entry(session_id, fn)
  local entries = read_index()
  for _, e in ipairs(entries) do
    if e.session_id == session_id then
      if fn then
        fn(e)
      end
      e.updated_at = now_iso()
      write_index(entries)
      return
    end
  end
end

---@param entry { session_id: string, provider: string, cwd: string, title?: string, additional_directories?: string[], forked_from?: string }
function M.save(entry)
  local entries = read_index()
  local now = now_iso()
  -- Update existing or insert new
  for _, e in ipairs(entries) do
    if e.session_id == entry.session_id then
      if entry.title then
        e.title = entry.title
        e.title_source = "auto"
      end
      if entry.additional_directories then
        e.additional_directories = entry.additional_directories
      end
      -- Lineage is write-once: later lazy saves (first-prompt record) don't carry
      -- it, so never clear it, and don't let a re-save overwrite a known parent.
      if entry.forked_from and not e.forked_from then
        e.forked_from = entry.forked_from
      end
      e.updated_at = now
      write_index(entries)
      return
    end
  end
  entries[#entries + 1] = {
    session_id = entry.session_id,
    provider = entry.provider,
    cwd = entry.cwd,
    title = entry.title,
    title_source = "auto",
    additional_directories = entry.additional_directories,
    forked_from = entry.forked_from,
    created_at = now,
    updated_at = now,
  }
  write_index(entries)
end

---@param session_id string
---@param title string
---@param source? "auto"|"user"  `user` marks a picker rename: imports and agent
--- titles must never overwrite it
function M.update_title(session_id, title, source)
  update_entry(session_id, function(e)
    e.title = title
    e.title_source = source == "user" and "user" or "auto"
  end)
end

---@param session_id string
function M.touch(session_id)
  update_entry(session_id)
end

---@param session_id string
---@return table|nil
function M.get(session_id)
  for _, e in ipairs(read_index()) do
    if e.session_id == session_id then
      return e
    end
  end
end

---@param session_id string
function M.remove(session_id)
  local entries = read_index()
  for i, e in ipairs(entries) do
    if e.session_id == session_id then
      table.remove(entries, i)
      write_index(entries)
      return
    end
  end
end

--- Every recorded session, most recent first, regardless of directory. Backs the
--- cross-directory picker: the agent's own `session/list` is scoped to one cwd,
--- so this index is the only place that knows the whole set.
---@param provider? string
---@return table[]
function M.list_all(provider)
  local entries = {}
  for _, e in ipairs(read_index()) do
    if not provider or e.provider == provider then
      entries[#entries + 1] = e
    end
  end
  table.sort(entries, function(a, b)
    return (a.updated_at or a.created_at or "") > (b.updated_at or b.created_at or "")
  end)
  return entries
end

--- Ingest one page (or the whole list) of the agent's `session/list` results.
--- Merges per `(session_id, provider)` — an id is scoped to the provider that
--- minted it, so the same id from two agents stays two entries. The agent's
--- title wins over an auto-derived one, but never over a user rename
--- (`title_source == "user"`). `cwd` adopts the agent's (it is the cwd of
--- record for that provider). `updated_at` takes the *later* of the two, so an
--- import never demotes a session just used in emeth. `additional_directories`
--- replaces wholesale — spec: never merge with prior values. `forked_from` is
--- local-only lineage and untouched (forks are otherwise imported like any
--- other entry). Returns `{ imported, updated }`.
---@param rows { session_id: string, cwd?: string, title?: string, updated_at?: string, additional_directories?: string[] }[]
---@param provider string
---@return { imported: integer, updated: integer }
function M.import(rows, provider)
  local entries = read_index()
  local imported, updated = 0, 0
  for _, row in ipairs(rows or {}) do
    if type(row) == "table" and type(row.session_id) == "string" and row.session_id ~= "" then
      local e
      for _, cand in ipairs(entries) do
        if cand.session_id == row.session_id and cand.provider == provider then
          e = cand
          break
        end
      end
      if e then
        if row.title and row.title ~= "" and e.title_source ~= "user" then
          e.title = row.title
        end
        if row.cwd then
          e.cwd = row.cwd
        end
        if row.updated_at then
          e.updated_at = later_iso(e.updated_at, row.updated_at)
        end
        if row.additional_directories ~= nil then
          e.additional_directories = row.additional_directories
        end
        updated = updated + 1
      else
        local remote_e = iso_epoch(row.updated_at)
        local stamp = remote_e and os.date("!%Y-%m-%dT%H:%M:%SZ", remote_e) or now_iso()
        entries[#entries + 1] = {
          session_id = row.session_id,
          provider = provider,
          cwd = row.cwd,
          title = row.title,
          title_source = "auto",
          additional_directories = row.additional_directories,
          created_at = stamp,
          updated_at = stamp,
        }
        imported = imported + 1
      end
    end
  end
  if imported > 0 or updated > 0 then
    write_index(entries)
  end
  return { imported = imported, updated = updated }
end

--- List sessions for a given cwd and provider, most recent first.
---@param cwd string
---@param provider? string
---@return table[]
function M.list(cwd, provider)
  local entries = read_index()
  local filtered = {}
  for _, e in ipairs(entries) do
    if e.cwd == cwd and (not provider or e.provider == provider) then
      filtered[#filtered + 1] = e
    end
  end
  table.sort(filtered, function(a, b)
    return (a.updated_at or "") > (b.updated_at or "")
  end)
  return filtered
end

return M
