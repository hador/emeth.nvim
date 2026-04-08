--- Message data model — protocol-agnostic.

local _uuid_counter = 0

---@class chat_ui.ContentItem
---@field type "text"|"thinking"|"tool_use"|"tool_result"
---@field text? string
---@field thinking? string
---@field name? string
---@field id? string
---@field input? table
---@field tool_use_id? string
---@field content? string|table
---@field is_error? boolean
---@field status? "pending"|"in_progress"|"completed"|"failed"|"cancelled"

---@class chat_ui.MessageMetadata
---@field provider? string
---@field model? string
---@field selected_files? string[]
---@field tool_call? table
---@field sender? string  -- attribution label (e.g. subagent name)
---@field [string] any

---@class chat_ui.Message
---@field role "user"|"assistant"|"system"
---@field content chat_ui.ContentItem[]
---@field _show_files? boolean
---@field timestamp string
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
  return setmetatable({
    role = role,
    content = content,
    timestamp = os.date("%Y-%m-%d %H:%M:%S"),
    uuid = gen_uuid(),
    metadata = metadata or {},
    visible = true,
  }, Message)
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
