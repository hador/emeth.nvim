---@alias chat_ui.LineSection table

---@class chat_ui.Line
---@field sections chat_ui.LineSection[]
---@field line_hl? string  highlight group applied as line background
local Line = {}
Line.__index = Line

---@param sections chat_ui.LineSection[]
---@param line_hl? string
---@return chat_ui.Line
function Line:new(sections, line_hl)
  return setmetatable({ sections = sections, line_hl = line_hl }, Line)
end

---@param ns_id number
---@param bufnr number
---@param line number 0-indexed
---@param offset number|nil
function Line:set_highlights(ns_id, bufnr, line, offset)
  if not vim.api.nvim_buf_is_valid(bufnr) then
    return
  end
  if self.line_hl then
    vim.api.nvim_buf_set_extmark(bufnr, ns_id, line, 0, { line_hl_group = self.line_hl })
  end
  local col = offset or 0
  for _, section in ipairs(self.sections) do
    local text = section[1]
    local hl = section[2]
    if type(hl) == "function" then
      hl = hl()
    end
    if hl then
      vim.api.nvim_buf_add_highlight(bufnr, ns_id, hl, line, col, col + #text)
    end
    col = col + #text
  end
end

function Line:__tostring()
  local parts = {}
  for _, s in ipairs(self.sections) do
    parts[#parts + 1] = s[1]
  end
  return table.concat(parts)
end

return Line
