--- Local session index — tracks session IDs for agents that don't support session/list.

local M = {}

local function index_path()
  return vim.fn.stdpath("state") .. "/emeth/sessions.json"
end

---@return table[]
local function read_index()
  local path = index_path()
  if vim.fn.filereadable(path) ~= 1 then
    return {}
  end
  local ok, data = pcall(function()
    return vim.json.decode(table.concat(vim.fn.readfile(path), "\n"))
  end)
  return ok and data or {}
end

---@param entries table[]
local function write_index(entries)
  local path = index_path()
  vim.fn.mkdir(vim.fn.fnamemodify(path, ":h"), "p")
  vim.fn.writefile({ vim.json.encode(entries) }, path)
end

---@param entry { session_id: string, provider: string, cwd: string, title?: string, additional_directories?: string[] }
function M.save(entry)
  local entries = read_index()
  local now = os.date("!%Y-%m-%dT%H:%M:%SZ")
  -- Update existing or insert new
  for _, e in ipairs(entries) do
    if e.session_id == entry.session_id then
      if entry.title then
        e.title = entry.title
      end
      if entry.additional_directories then
        e.additional_directories = entry.additional_directories
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
    additional_directories = entry.additional_directories,
    created_at = now,
    updated_at = now,
  }
  write_index(entries)
end

---@param session_id string
---@param title string
function M.update_title(session_id, title)
  local entries = read_index()
  for _, e in ipairs(entries) do
    if e.session_id == session_id then
      e.title = title
      e.updated_at = os.date("!%Y-%m-%dT%H:%M:%SZ")
      write_index(entries)
      return
    end
  end
end

---@param session_id string
function M.touch(session_id)
  local entries = read_index()
  for _, e in ipairs(entries) do
    if e.session_id == session_id then
      e.updated_at = os.date("!%Y-%m-%dT%H:%M:%SZ")
      write_index(entries)
      return
    end
  end
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
