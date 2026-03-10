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
---@field status? "pending"|"in_progress"|"completed"|"failed"

---@class chat_ui.MessageMetadata
---@field provider? string
---@field model? string
---@field selected_files? string[]
---@field tool_call? table
---@field [string] any

---@class chat_ui.Message
---@field role "user"|"assistant"|"system"
---@field content string|chat_ui.ContentItem[]
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
  -- Wrap single ContentItem in a list
  if type(content) == "table" and content.type then
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

---@param new_content string|chat_ui.ContentItem[]
function Message:update_content(new_content)
  self.content = new_content
end

--- Append text for streaming. If content is a string, concatenate.
--- If content is a table, find last text item and append, or add new text item.
---@param text string
function Message:append_text(text)
  if type(self.content) == "string" then
    self.content = self.content .. text
  elseif type(self.content) == "table" then
    -- Find last text item
    for i = #self.content, 1, -1 do
      if self.content[i].type == "text" then
        self.content[i].text = (self.content[i].text or "") .. text
        return
      end
    end
    -- No text item found, add one
    table.insert(self.content, { type = "text", text = text })
  end
end

---@return boolean
function Message:is_tool_use()
  if type(self.content) ~= "table" then return false end
  for _, item in ipairs(self.content) do
    if item.type == "tool_use" then return true end
  end
  return false
end

---@return boolean
function Message:is_tool_result()
  if type(self.content) ~= "table" then return false end
  for _, item in ipairs(self.content) do
    if item.type == "tool_result" then return true end
  end
  return false
end

---@return boolean
function Message:is_thinking()
  if type(self.content) ~= "table" then return false end
  for _, item in ipairs(self.content) do
    if item.type == "thinking" then return true end
  end
  return false
end

return Message
