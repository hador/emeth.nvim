--- OpenCode ACP extension.
---
--- Everything but subagents is generic: top-level tool calls arrive with clean
--- human titles, and `qN` / `qN_custom` elicitation, steering, and session
--- storage (opencode's own db) all go through emeth's generic paths. Subagents
--- are the exception. They are *not* ACP child sessions: all child traffic
--- rides **our** session id, tagged with
---
---     _meta["opencode/child-session"] = { depth, id, parentID, title }
---
--- so the core's child-prose guard (which filters on session id alone) never
--- catches the child's `agent_message_chunk` / `agent_thought_chunk` text, and
--- child tool calls carry no structural link to their launch.
---
--- The launch itself is an ordinary tool call: `name = "subagent"` with
--- `{ agent, description, prompt }` in `rawInput` (pending arrives with an
--- empty `rawInput`); the child's `ses_` id only surfaces on completion, in
--- `rawOutput.metadata.sessionID` — *after* all the child's calls.
---
--- So a stateful transform:
---   * re-parents tagged child tool calls onto their launch card by stamping
---     `parent_tool_call_id` (session-id binding → description → last launch)
---     and strips the child's `"<description>: "` title prefix;
---   * drops tagged prose (the launch card's body already carries the child's
---     final text);
---   * renames the launch title `subagent` to `"<description> ⊳ <agent>"` once
---     `rawInput` has landed;
---   * records each launch → child-id binding so late or resumed child traffic
---     resolves by id.
---
--- Nested subagents arrive tagged (they run in the first subagent's session):
--- they get the same treatment and are recorded as launches too, so their own
--- children resolve onto them.

local M = {}

-- ── Launch ↔ child state ─────────────────────────────────────────
-- The child's traffic rides our session id, so structural nesting is
-- impossible; we carry the launch↔child link ourselves. One per session,
-- re-initialised in `setup`.
local desc_to_id = {} -- launch description -> launch toolCallId
local child_binding = {} -- child ses_ id -> launch toolCallId (from completion)
local last_launch_id = nil -- last top-level launch (fallback)

---The `update._meta["opencode/child-session"]` tag, or nil if top-level.
---Presence of the key decides: a malformed value is still treated as child
---traffic (empty table → nothing resolves, prose still dropped).
---@param update table|nil
---@return table|nil
local function child_meta(update)
  local meta = type(update) == "table" and update._meta or nil
  if type(meta) ~= "table" or meta["opencode/child-session"] == nil then
    return nil
  end
  local c = meta["opencode/child-session"]
  return type(c) == "table" and c or {}
end

---Resolve the launch card a child update belongs to: session-id binding
---(exists only after the launch completes → late/resumed children), then the
---launch description (the tag carries it, recorded before any child traffic —
---the path that fires in practice), then the last launch seen (sound while a
---single subagent is active).
---@param c table child-session tag
---@return string|nil
local function resolve_parent(c)
  if type(c.id) == "string" then
    local bound = child_binding[c.id]
    if bound then
      return bound
    end
  end
  if type(c.title) == "string" then
    local by_desc = desc_to_id[c.title]
    if by_desc then
      return by_desc
    end
  end
  return last_launch_id
end

---Child tool calls are titled `"<description>: <tool>"` while the same calls
---run top-level titled just `<tool>` (or the command). Strip the prefix so a
---child card reads like its top-level twin (plain compare — the description is
---arbitrary text, never a pattern).
---@param update table
---@param c table child-session tag
local function strip_child_prefix(update, c)
  if type(update.title) ~= "string" or type(c.title) ~= "string" or c.title == "" then
    return
  end
  local prefix = c.title .. ": "
  if update.title:sub(1, #prefix) == prefix then
    update.title = update.title:sub(#prefix + 1)
  end
end

---Record a launch on the binding tables and rewrite its title.
---
---`rawInput` may arrive after the pending update, so record on every update
---that carries a description; the core re-applies `title` per update, so a
---late rewrite still lands. With `nested`, leave `last_launch_id` alone — that
---child's children resolve via its description, not the fallback.
---@param update table
---@param nested boolean|nil whether the launch arrived tagged (inside another subagent)
local function record_launch(update, nested)
  local id = type(update.toolCallId) == "string" and update.toolCallId or nil
  if not id then
    return
  end
  if not nested then
    last_launch_id = id
  end

  local raw = type(update.rawInput) == "table" and update.rawInput or {}
  local desc = type(raw.description) == "string" and raw.description or ""
  if desc ~= "" then
    desc_to_id[desc] = id
    local agent = type(raw.agent) == "string" and raw.agent or ""
    update.title = agent ~= "" and (desc .. " ⊳ " .. agent) or desc
  end

  local out = type(update.rawOutput) == "table" and update.rawOutput or {}
  local md = type(out.metadata) == "table" and out.metadata or {}
  if type(md.sessionID) == "string" and md.sessionID ~= "" then
    child_binding[md.sessionID] = id
  end
end

---Stateful transform: fold tagged child updates under their launch card and
---drop tagged prose (returning `false` tells the integration to drop the
---update).
---@param update table
---@return boolean|nil  false to drop
local function transform_update(update)
  if type(update) ~= "table" then
    return
  end

  local c = child_meta(update)
  if c then
    if update.sessionUpdate == "tool_call" or update.sessionUpdate == "tool_call_update" then
      update.parent_tool_call_id = resolve_parent(c)
      strip_child_prefix(update, c)
      if update.name == "subagent" then
        record_launch(update, true) -- a nested launch: its children must resolve onto it
      end
      return
    end
    -- Prose / thought / plan: the core's child-prose guard filters on session
    -- id alone, and this one is ours — nothing downstream would catch it.
    return false
  end

  if
    (update.sessionUpdate == "tool_call" or update.sessionUpdate == "tool_call_update")
    and update.name == "subagent"
  then
    record_launch(update)
  end
end

-- Exposed for testing.
M._transform_update = transform_update

-- ── mode / model display hooks ───────────────────────────────────

-- opencode modes: `build` (default), `plan`, `worker`; the default gets a
-- badge only, no bottom-bar tag.
local MODE_INFO = {
  build = { label = "build", normal = true },
  plan = { label = "plan", kind = "info" },
  worker = { label = "worker", kind = "hint" },
}

---Opencode renders modes as plain ids.
---@param mode_id string|nil
---@return { badge?: string, tag?: string, tag_kind?: string }|nil
function M.format_mode(mode_id)
  if not mode_id or mode_id == "" then
    return nil
  end
  local info = MODE_INFO[mode_id]
  if not info then
    return { badge = "⚙ " .. mode_id, tag = mode_id, tag_kind = "hint" }
  end
  if info.normal then
    return { badge = "⚙ " .. info.label } -- no bottom-bar tag for the default mode
  end
  return { badge = "⚙ " .. info.label, tag = info.label, tag_kind = info.kind }
end

---opencode reports models as `"<source>/<id>"`; the winbar already shows the
---provider, so drop the first segment and let the core cap the rest.
---@param model_id string
---@return string
function M.format_model(model_id)
  local tail = type(model_id) == "string" and model_id:match("^[^/]+/(.+)$") or nil
  return tail or (type(model_id) == "string" and model_id or "")
end

-- ── setup / cleanup ──────────────────────────────────────────────

---Install opencode's transform on the session.
---@param _session acp.Session|nil
---@param view chat_ui.ChatView|nil
---@return fun() cleanup
function M.setup(_session, view)
  -- One extension instance per session: drop any previous session's bindings.
  desc_to_id = {}
  child_binding = {}
  last_launch_id = nil

  if view and view.integration and view.integration.set_transform_update then
    view.integration.set_transform_update(transform_update)
  end

  return function()
    if view and view.integration and view.integration.set_transform_update then
      view.integration.set_transform_update(nil)
    end
  end
end

return M
