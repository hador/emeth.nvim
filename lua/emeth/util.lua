--- Shared utilities for emeth.nvim

local M = {}

---Find the first non-emeth window (source editor window).
---@return number|nil win_id
function M.find_source_win()
  for _, win in ipairs(vim.api.nvim_list_wins()) do
    local buf = vim.api.nvim_win_get_buf(win)
    local name = vim.api.nvim_buf_get_name(buf)
    if not name:match("^emeth://") then
      return win
    end
  end
end

---Format an ACP error, including .data when present.
---@param err table|nil
---@return string
function M.fmt_err(err)
  if not err then
    return "unknown error"
  end
  local msg = err.message or "unknown error"
  if err.data then
    local detail = type(err.data) == "table" and (err.data.details or vim.inspect(err.data)) or tostring(err.data)
    msg = msg .. ": " .. detail
  end
  return msg
end

return M
