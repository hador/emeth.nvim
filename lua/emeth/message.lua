--- Message data model — protocol-agnostic.

local _uuid_counter = 0

---@class chat_ui.ContentItem
---@field type "text"|"thinking"|"tool_use"
---@field text? string
---@field thinking? string
---@field name? string
---@field id? string
---@field input? table
---@field status? "pending"|"in_progress"|"completed"|"failed"|"cancelled"
---@field failure_reason? "cancelled"|"denied"|"error"
---@field backgrounded? boolean  the call returned at once, its work still running

---@class chat_ui.MessageMetadata
---@field model? string
---@field selected_files? string[]
---@field tool_call? table
---@field [string] any

---@class chat_ui.Message
---@field role "user"|"assistant"|"system"
---@field content chat_ui.ContentItem[]
---@field _show_details? boolean
---@field timestamp string  "YYYY-MM-DD HH:MM:SS" of `at`, "" when the time is unknown
---@field at? integer  when the message was produced (epoch seconds); nil when unknown (replayed history
---  whose agent sent no time)
---@field uuid string
---@field metadata chat_ui.MessageMetadata
---@field visible boolean
local Message = {}
Message.__index = Message

local function gen_uuid()
  _uuid_counter = _uuid_counter + 1
  return string.format("%s-%04x", os.clock(), _uuid_counter)
end

---@param role "user"|"assistant"|"system"
---@param content string|chat_ui.ContentItem[]|chat_ui.ContentItem
---@param metadata? chat_ui.MessageMetadata
---@return chat_ui.Message
function Message:new(role, content, metadata)
  if type(content) == "string" then
    content = { { type = "text", text = content } }
  elseif type(content) == "table" and content.type then
    content = { content }
  end
  local now = os.time()
  return setmetatable({
    role = role,
    content = content,
    at = now,
    timestamp = os.date("%Y-%m-%d %H:%M:%S", now) --[[@as string]],
    uuid = gen_uuid(),
    metadata = metadata or {},
    visible = true,
  }, Message)
end

--- Set when the message was produced (an agent-supplied time, or nil when unknown).
---@param at? number  epoch seconds
function Message:set_time(at)
  self.at = at and math.floor(at) or nil
  self.timestamp = self.at and os.date("%Y-%m-%d %H:%M:%S", self.at) --[[@as string]] or ""
end

--- Get the concatenated text content of the message.
---@return string
function Message:text()
  local parts = {}
  for _, item in ipairs(self.content) do
    if item.type == "text" and item.text then
      parts[#parts + 1] = item.text
    end
  end
  return table.concat(parts)
end

--- Append text for streaming.
---@param text string
function Message:append_text(text)
  for i = #self.content, 1, -1 do
    if self.content[i].type == "text" then
      self.content[i].text = (self.content[i].text or "") .. text
      return
    end
  end
  table.insert(self.content, { type = "text", text = text })
end

return Message
