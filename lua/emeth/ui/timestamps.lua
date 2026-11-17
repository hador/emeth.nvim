--- When a transcript message shows its time. Pure: the chat view asks per message as it paints.
local M = {}

---@class emeth.TimestampConfig
---@field enabled? boolean
---@field format? string
---@field day_format? string
---@field gap_minutes? number

---@return emeth.TimestampConfig
local function config()
  local ok, emeth = pcall(require, "emeth")
  local cfg = ok and emeth.config and emeth.config.timestamps or nil
  return type(cfg) == "table" and cfg or {}
end
M.config = config

---Whether a message takes part in time-keeping: top-level (not a subagent's nested call) and not a
---system note.
---@param msg chat_ui.Message
---@return boolean
function M.counts(msg)
  return msg.role ~= "system" and msg.visible ~= false and not (msg.metadata and msg.metadata.parent_tool_call_id)
end

---The marks for `msg`, given the message before it (`prev`, top-level) and the time of the last
---top-level message before it that has one (`prev_at`).
---`right`: the time to show right-aligned on its first row (an agent message that starts a turn or
---follows `gap_minutes` of quiet; a user message shows its time in its own header instead).
---`day`: a divider label when the day changed since `prev_at` (or for the first timed message).
---@param msg chat_ui.Message
---@param prev? chat_ui.Message
---@param prev_at? integer
---@param cfg? emeth.TimestampConfig
---@return { right?: string, day?: string }
function M.marks(msg, prev, prev_at, cfg)
  cfg = cfg or config()
  if cfg.enabled == false or not msg.at or not M.counts(msg) then
    return {}
  end
  local out = {}
  local day_format = cfg.day_format or "%a %d %b"
  if not prev_at or os.date("%Y%m%d", prev_at) ~= os.date("%Y%m%d", msg.at) then
    out.day = os.date(day_format, msg.at) --[[@as string]]
  end
  if msg.role == "assistant" then
    local gap = (cfg.gap_minutes or 5) * 60
    if not prev or prev.role ~= "assistant" or (prev_at and msg.at - prev_at >= gap) then
      out.right = os.date(cfg.format or "%H:%M", msg.at) --[[@as string]]
    end
  end
  return out
end

---A user message's header time ("" when unknown).
---@param msg chat_ui.Message
---@return string
function M.header(msg)
  if not msg.at then
    return ""
  end
  return os.date(config().format or "%H:%M", msg.at) --[[@as string]]
end

return M
