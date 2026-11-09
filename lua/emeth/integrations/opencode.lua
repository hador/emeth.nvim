--- OpenCode ACP extension.
---
--- Subagents: we advertise `opencode/child-session-updates`, so current
--- opencode sends each child event as an `opencode/session/child_update`
--- notification (content + terminal status) rather than a tagged
--- `session/update`. `handle_child_update` (below) routes that: content is
--- re-emitted through the ordinary update pipeline, terminal status is stamped
--- onto the launch card. The tagged path the rest of this file describes is
--- kept for older agents that don't implement the capability — the two share
--- the same projected update shape, so `transform_update` serves both.
---
--- Everything but subagents is generic: top-level tool calls arrive with clean
--- human titles, and `qN` / `qN_custom` elicitation, steering, and session
--- storage (opencode's own db) all go through emeth's generic paths — except
--- that each `qN_custom` "type your own answer" box is folded into its `qN`
--- question so the user is asked once, not twice. Subagents
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

-- ── `opencode/session/child_update` (advertised capability) ──────
-- Because we advertise `opencode/child-session-updates`, opencode stops
-- sending child traffic as tagged `session/update` and instead sends one
-- `opencode/session/child_update` notification per child event, each carrying
-- the child's session id plus either:
--
--   { type = "update", update = <SessionUpdate> }
--       a projected child update — byte-identical to the tagged
--       `session/update` we handled before (same `_meta["opencode/child-session"]`
--       tag, same `"<child id>:"`-namespaced toolCallId), so we re-emit it
--       through the ordinary update pipeline and the transform + render pick it
--       up unchanged; or
--
--   { type = "status", status = "created"|"running"|"completed"|"failed"
--     |"interrupted", error? = { type, message } }
--       the child's real terminal state — the ONLY source of it. We stamp it
--       onto the launch card's `subagent_state` (render.lua drives the card's
--       icon from that), overriding the blanket "completed" the launch card
--       would otherwise show when the child failed or was interrupted.
--
-- The tagged `session/update` path above is kept for older agents that don't
-- implement the capability, so this is additive against them and a switch on
-- current opencode.

---Map a child's terminal status onto the `subagent_state` the renderer
---understands. Non-terminal states (created/running) return nil — the launch
---card's own pending/in_progress status already reads "running".
---@param status string|nil
---@return string|nil
local function child_state(status)
  if status == "completed" then
    return "idle"
  end
  if status == "failed" or status == "interrupted" then
    return "failed"
  end
  return nil
end

---Find a launch card's message uuid by its toolCallId.
---@param view chat_ui.ChatView|nil
---@param tool_call_id string
---@return string|nil
local function find_launch_card(view, tool_call_id)
  if not (view and view.get_messages) then
    return nil
  end
  for _, m in ipairs(view:get_messages()) do
    if m.content and m.content[1] and m.content[1].id == tool_call_id then
      return m.uuid
    end
  end
  return nil
end

---Handle one `opencode/session/child_update` notification.
---@param session acp.Session|nil
---@param view chat_ui.ChatView|nil
---@param params table|nil the notification's params (the Update envelope)
local function handle_child_update(session, view, params)
  if type(params) ~= "table" then
    return
  end

  if params.type == "update" then
    -- Re-emit the projected child update through the ordinary pipeline; the
    -- transform (which knows the child tag) and the renderer handle it exactly
    -- as they did for the tagged `session/update` path.
    local update = params.update
    if type(update) == "table" and session and session._emit then
      session:_emit("update", update, session.session_id)
    end
    return
  end

  if params.type == "status" then
    local state = child_state(params.status)
    if not state then
      return -- created/running: the card's own status already reads "running"
    end
    local launch_id = resolve_parent({ id = params.childSessionId, title = params.title })
    if not launch_id then
      return
    end
    local uuid = find_launch_card(view, launch_id)
    if not (uuid and view and view.update_message) then
      return
    end
    local err = type(params.error) == "table" and params.error.message or nil
    view:update_message(uuid, function(m)
      m.metadata.subagent_state = state
      if type(err) == "string" and err ~= "" then
        m.metadata.subagent_error = err
      end
    end)
  end
end

-- Exposed for testing.
M._handle_child_update = handle_child_update

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

-- ── Elicitations: fold the "type your own answer" box ───────────
-- opencode's `question` tool arrives as `q<N>` / `q<N>_custom` pairs: a
-- select plus a free-text "Type your own answer" companion. The generic
-- renderer would offer those as two prompts, asking the user twice about
-- one question. Fold each companion into its question instead: the single
-- prompt then offers a "type your own…" line, and the generic answer paths
-- already send a typed answer under the companion key (which the agent
-- prefers over the selection).
--
-- Only fold onto a select base: with a plain text base the `_custom`
-- suffix would most likely be a separate question, and folding it away
-- would drop one of the two answers.
---@param fields acp.ElicitationField[]
---@return acp.ElicitationField[]
local function transform_elicitation(fields)
  local kind_of = {} ---@type table<string, string>
  for _, field in ipairs(fields) do
    kind_of[field.key] = field.kind
  end

  local custom_for = {} ---@type table<string, string>
  local is_custom = {} ---@type table<string, boolean>
  for _, field in ipairs(fields) do
    if field.kind == "text" then
      local base = field.key:match("^(.+)_custom$")
      if base and kind_of[base] == "select" then
        custom_for[base] = field.key
        is_custom[field.key] = true
      end
    end
  end

  local out = {}
  for _, field in ipairs(fields) do
    if not is_custom[field.key] then
      -- Assign only when found so a re-pass over an already-folded list
      -- cannot undo the fold by resetting to nil.
      local companion = custom_for[field.key]
      if companion then
        field.custom_key = companion
      end
      out[#out + 1] = field
    end
  end

  -- parse() orders keys lexicographically, which puts `q10` before `q2`;
  -- restore numeric order should the agent ever ask ten-plus questions.
  local order = {} ---@type table<string, { n: number|nil, i: number }>
  for i, field in ipairs(out) do
    local n = field.key:match("^q(%d+)$")
    order[field.key] = { n = n and tonumber(n) or nil, i = i }
  end
  table.sort(out, function(a, b)
    local oa, ob = order[a.key], order[b.key]
    if oa.n and ob.n then
      return oa.n < ob.n
    end
    if oa.n ~= nil then
      return true
    end
    if ob.n ~= nil then
      return false
    end
    return oa.i < ob.i
  end)

  return out
end

-- Exposed for testing.
M._transform_elicitation = transform_elicitation

-- ── setup / cleanup ──────────────────────────────────────────────

---Install opencode's update and elicitation transforms on the session, and
---route the advertised `opencode/session/child_update` notifications.
---@param session acp.Session|nil
---@param view chat_ui.ChatView|nil
---@return fun() cleanup
function M.setup(session, view)
  -- One extension instance per session: drop any previous session's bindings.
  desc_to_id = {}
  child_binding = {}
  last_launch_id = nil

  if view and view.integration and view.integration.set_transform_update then
    view.integration.set_transform_update(transform_update)
  end
  if view and view.integration and view.integration.set_transform_elicitation then
    view.integration.set_transform_elicitation(transform_elicitation)
  end

  -- The advertised capability: child traffic arrives as
  -- `opencode/session/child_update` notifications rather than tagged
  -- `session/update`. Re-emit content through the update pipeline and stamp
  -- terminal status onto the launch card. Optional — a session handle is
  -- present in real use but nil in the transform-only tests.
  local on_notification = nil
  if session and session.on then
    on_notification = function(method, params)
      if method == "opencode/session/child_update" then
        handle_child_update(session, view, params)
      end
    end
    session:on("notification", on_notification)
  end

  return function()
    if view and view.integration and view.integration.set_transform_update then
      view.integration.set_transform_update(nil)
    end
    if view and view.integration and view.integration.set_transform_elicitation then
      view.integration.set_transform_elicitation(nil)
    end
    if on_notification and session and session.off then
      session:off("notification", on_notification)
    end
  end
end

return M
