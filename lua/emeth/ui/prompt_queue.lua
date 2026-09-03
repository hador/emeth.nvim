--- Transient-prompt queue — the machine behind the transcript's inline prompts.
---
--- Tool permissions and agent elicitations are the same mechanism: requests
--- arrive while the agent is blocked, they queue up, only the head is live, its
--- body renders as a system message in the transcript, and it claims keys from
--- the set the view binds permanently. Answering it rewrites (or hides) that
--- message, pops the queue, and activates whatever was waiting behind it.
---
--- Only three things actually differ between the two: the body lines, the claim
--- map, and what the message becomes once answered. Those are the spec — the
--- queueing, activation, key-claim lifecycle and message rewriting live here, so
--- a third prompt kind is a descriptor rather than another pipeline.
---
--- Prompts are rendered inline rather than in a picker on purpose: they arrive
--- unpredictably, and a modal window would steal focus and keystrokes from
--- whatever buffer the user is editing.

local Message = require("emeth.message")

---@class emeth.PromptQueueSpec
---@field owner string  claim namespace, passed to set/clear_prompt_keys
---@field render fun(item: table, q: emeth.PromptQueue): string[]  body lines; may stash render state on `item`
---@field claims fun(item: table, q: emeth.PromptQueue): table<string, fun(): boolean?>
---@field close? fun(item: table, result: any): string|nil  replacement body, or nil to hide the message
---@field on_expand? fun(item: table, q: emeth.PromptQueue)  K toggle, when the prompt has more to show
---@field on_detach? fun(item: table)  as an item leaves the queue, by either close or drain
---@field on_change? fun(q: emeth.PromptQueue)  after any change in depth

---@class emeth.PromptQueue
---@field view chat_ui.ChatView
---@field spec emeth.PromptQueueSpec
---@field items table[]  FIFO; every item carries a `callback`, and gains `prompt_uuid` once live
local PromptQueue = {}
PromptQueue.__index = PromptQueue

---@param view chat_ui.ChatView
---@param spec emeth.PromptQueueSpec
---@return emeth.PromptQueue
function PromptQueue.new(view, spec)
  return setmetatable({ view = view, spec = spec, items = {} }, PromptQueue)
end

---@return integer
function PromptQueue:depth()
  return #self.items
end

---The live request, or nil when nothing is pending.
---@return table|nil
function PromptQueue:head()
  return self.items[1]
end

---@param lines string[]
---@return chat_ui.ContentItem[]
local function body(lines)
  return { { type = "text", text = table.concat(lines, "\n") } }
end

---Render the head into a fresh transcript message and claim its keys. Only ever
---one prompt per queue is live, so a fixed key set can't collide across
---concurrent requests from the same queue.
function PromptQueue:_activate()
  local item = self.items[1]
  if not item then
    return
  end
  local metadata = nil
  if self.spec.on_expand then
    -- The view calls this and repaints itself, so the handler mutates in place.
    metadata = {
      on_expand = function()
        self.spec.on_expand(item, self)
      end,
    }
  end
  local msg = Message:new("system", body(self.spec.render(item, self)), metadata)
  self.view:add_message(msg)
  item.prompt_uuid = msg.uuid
  -- Claim rather than bind: the view owns these keys permanently, so releasing
  -- a claim restores their default instead of deleting a mapping something else
  -- relies on.
  self.view:set_prompt_keys(self.spec.owner, self.spec.claims(item, self))
end

---Recompute the head's body in place — a selection moved, it expanded, or the
---queue depth changed under it.
---@param inline? boolean  mutate the message directly, for callers that repaint
---themselves (the view invalidates the message right after calling `on_expand`);
---otherwise go through `update_message`, which schedules the paint.
function PromptQueue:refresh(inline)
  local item = self.items[1]
  if not item or not item.prompt_uuid then
    return
  end
  local content = body(self.spec.render(item, self))
  if inline then
    local msg = self.view:get_message(item.prompt_uuid)
    if msg then
      msg.content = content
    end
    return
  end
  self.view:update_message(item.prompt_uuid, function(m)
    m.content = content
  end)
end

---Queue a request, activating it when nothing is ahead of it.
---@param item table  must carry `callback`
function PromptQueue:push(item)
  self.items[#self.items + 1] = item
  if #self.items == 1 then
    self:_activate()
  else
    -- Something queued behind the live prompt; its "N more waiting" moved.
    self:refresh()
  end
  if self.spec.on_change then
    self.spec.on_change(self)
  end
end

---Turn an answered prompt's message into its closed form. Leaving the live body
---in place would keep offering choices on a question that is already settled.
---The expand hook goes too: there is nothing left to expand.
---@param item table
---@param result any
function PromptQueue:_close_message(item, result)
  if not item.prompt_uuid then
    return
  end
  local text = self.spec.close and self.spec.close(item, result) or nil
  self.view:update_message(item.prompt_uuid, function(m)
    m.metadata.on_expand = nil
    if text then
      m.content = body({ text })
    else
      m.visible = false
    end
  end)
end

---Answer the head with `result` and hand over to the next request.
---@param result any  passed to the item's callback verbatim
function PromptQueue:close(result)
  local item = table.remove(self.items, 1)
  if not item then
    return
  end
  self.view:clear_prompt_keys(self.spec.owner)
  if self.spec.on_detach then
    self.spec.on_detach(item)
  end
  self:_close_message(item, result)
  -- Guarded: a throwing callback must not strand the rest of the queue.
  pcall(item.callback, result)
  if self.items[1] then
    self:_activate()
  end
  if self.spec.on_change then
    self.spec.on_change(self)
  end
end

---Answer every queued request with the same result and empty the queue — used
---when the turn goes away. Drains directly rather than looping `close`, which
---would render each queued prompt on its way to killing it.
---@param result any
function PromptQueue:drain(result)
  if not self.items[1] then
    return
  end
  local queued = self.items
  self.items = {}
  self.view:clear_prompt_keys(self.spec.owner)
  for _, item in ipairs(queued) do
    if self.spec.on_detach then
      self.spec.on_detach(item)
    end
    self:_close_message(item, result)
    pcall(item.callback, result)
  end
  if self.spec.on_change then
    self.spec.on_change(self)
  end
end

return PromptQueue
