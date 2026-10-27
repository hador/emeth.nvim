--- `session/update` handlers — one per `sessionUpdate` type.
---
--- Split out of `integrations/acp.lua` because this is the region protocol work
--- always lands in: every new ACP update type, every provider `_meta` field, and
--- every rendering tweak for streamed content touches a handler and nothing else.
--- Keeping it beside the session lifecycle and prompt UI meant unrelated changes
--- collided in one file.
---
--- Handlers take no upvalues from the integration. Everything they need arrives
--- in a context table (see `acp_updates.Ctx`), so they can be built and tested
--- without a session or a real view.
---
--- Provider-specific knowledge does NOT belong here — an extension's `_meta` is
--- normalised onto generic fields by its `transform_update` hook before dispatch,
--- so these handlers only ever see spec-shaped updates plus generic extras like
--- `parent_tool_call_id`.

local Commands = require("emeth.commands")
local Message = require("emeth.message")
local Sessions = require("emeth.sessions")
local Winbar = require("emeth.ui.winbar")

local M = {}

--- `sessionUpdate` types that are pure metadata and shouldn't flip the winbar to
--- "generating" state.
M.NON_STREAMING = {
  available_commands_update = true,
  session_info_update = true,
  usage_update = true,
  current_mode_update = true,
  config_option_update = true,
  subagent_update = true,
}

--- `sessionUpdate` types from a subagent's child session that still reach a
--- handler. `tool_call`/`tool_call_update` render, nested under the call that
--- spawned the subagent; `session_message` is captured (its launch prompt goes
--- on the parent card) but renders nothing; `subagent_update` is how a subagent
--- announces a subagent of its OWN (nesting) — it must be dispatched from a
--- child session or the grandchild is never registered and its traffic leaks to
--- the main transcript. Everything else a child sends (its prose as thought
--- chunks, its plans) is dropped.
M.SUBAGENT_DISPATCHED = {
  tool_call = true,
  tool_call_update = true,
  session_message = true,
  subagent_update = true,
}

---@class acp_updates.Ctx
---@field view chat_ui.ChatView
---@field session acp.Session
---@field schedule_tool_render fun()  arm the streamed-content render throttle
---@field schedule_reload fun(path: string, first_changed?: integer, no_follow?: boolean)
---@field render_mode fun(mode_id: string)
---@field reconcile_config_options fun(config_options: table)

---Give a subagent's spawning tool an expand hook that shows/hides the calls
---nested under it. Installed on demand (the first child to arrive) and
---idempotent, since the parent tool_call is created before we know it has any.
---
---Takes over from the renderer's default `_expanded` toggle because the two have
---to move together: the parent's own body is empty for a subagent tool, and what
---the user wants to see is its children.
---@param parent chat_ui.Message
---@param view chat_ui.ChatView
local function attach_subagent_expand(parent, view)
  if parent.metadata.on_expand then
    return
  end
  parent.metadata.on_expand = function(msg)
    local expanded = msg.metadata._expanded ~= true
    msg.metadata._expanded = expanded
    for _, m in ipairs(view:get_messages()) do
      if m.metadata and m.metadata.parent_tool_call_id == msg.content[1].id then
        m.visible = expanded
      end
    end
  end
end

---Build the dispatch table. Each handler receives the update, the streaming
---state for the session that update belongs to, and that session's id; handlers
---that need neither ignore them.
---@param ctx acp_updates.Ctx
---@return table<string, fun(update: table, stream: acp.StreamState, session_id: string?)>
function M.handlers(ctx)
  local view = ctx.view
  local session = ctx.session
  local handlers = {}

  -- The concatenated text of a `content` field, which is either a single block
  -- (`{ type, text }`, as the chunk updates carry) or an array of them (as
  -- `session_message` carries). Non-text blocks contribute nothing.
  local function text_of(content)
    if type(content) ~= "table" then
      return ""
    end
    if content.type then
      content = { content }
    end
    local parts = {}
    for _, block in ipairs(content) do
      if type(block) == "table" and block.type == "text" and type(block.text) == "string" then
        parts[#parts + 1] = block.text
      end
    end
    return table.concat(parts)
  end

  -- Push a subagent record's current state onto its parent card (if bound), and
  -- when it needs the user, expand the card so the request below it is visible.
  ---@param record { parent_uuid?: string, state?: string }
  local function set_card_state(record)
    if not (record.parent_uuid and record.state) then
      return
    end
    local state = record.state
    view:update_message(record.parent_uuid, function(m)
      m.metadata.subagent_state = state
      if state == "requires_action" and m.metadata._expanded == nil then
        m.metadata._expanded = true
        for _, child in ipairs(view:get_messages()) do
          if child.metadata and child.metadata.parent_tool_call_id == m.content[1].id then
            child.visible = true
          end
        end
      end
    end)
  end

  -- Bind a child session's record to its parent card, stamping the child's
  -- identity (so the card can cancel it) and flushing any state that arrived
  -- before the binding (the first `running` precedes it).
  ---@param record { parent_uuid?: string, state?: string, session_id?: string, cancellable?: boolean }
  local function bind_parent(record, parent_uuid)
    record.parent_uuid = parent_uuid
    view:update_message(parent_uuid, function(m)
      m.metadata.subagent_session_id = record.session_id
      m.metadata.subagent_cancellable = record.cancellable
    end)
    set_card_state(record)
  end

  -- A subagent spawned with no visible Agent/Task tool_call (a background one,
  -- say) is announced only by subagent_update; its child calls name a launch
  -- message that has no card. Synthesize a stand-in card from the announcement
  -- so the work has somewhere to nest instead of spilling onto the main
  -- transcript. Registered in the tool map under `tool_id` so children that name
  -- it as their parent resolve to it.
  ---@param record { title?: string, description?: string }
  ---@param tool_id string
  ---@return string uuid
  local function create_subagent_card(stream, record, tool_id)
    -- claude-acp withholds the Agent/Task launch tool_call of every child it
    -- announces (RFD routing), so for those the enriched `description ⊳
    -- subagent_type` title never arrives as a tool_call and the card is built
    -- here; only a fallback for an unannounced child shows the call. The
    -- `subagent_update` announcement is then the only label source: its
    -- `description` is the human task summary, its `title` the subagent_type.
    -- Prefer the description and reproduce the old enrichment when both exist,
    -- so the card reads "claude-acp version delta ⊳ general-purpose" rather than
    -- a bare, indistinguishable "general-purpose".
    local label = record.description or record.title or "subagent"
    if record.description and record.title and record.description ~= record.title then
      label = record.description .. " ⊳ " .. record.title
    end
    local msg = Message:new("assistant", {
      type = "tool_use",
      name = label,
      id = tool_id,
      input = {},
      status = "pending",
    }, { tool_call = { toolCallId = tool_id, title = label } })
    stream.tool_map[tool_id] = msg.uuid
    -- Close the in-flight text/thought blocks, exactly as a top-level tool_call
    -- does (see the `tool_call` handler). A visible Agent/Task launch used to do
    -- this for us; now that claude-acp hides it, nothing else resets these, so
    -- every later assistant message would keep extending the pre-spawn block and
    -- the card would be stranded below a growing wall of prose. Resetting here
    -- anchors the card at the spawn point: prose before it stays above, prose
    -- after it starts a fresh message below.
    stream.assistant_uuid = nil
    stream.thinking_uuid = nil
    view:add_message(msg)
    return msg.uuid
  end

  function handlers.user_message_chunk(update)
    if update.content and update.content.type == "text" then
      -- A provider transform may stamp the agent-side message id (kiro sets it
      -- from `_meta.kiro.messageId` on replay) so transcript actions like rewind
      -- can target this message. Only present on replayed history.
      local meta = update.provider_message_id and { provider_message_id = update.provider_message_id } or nil
      view:add_message(Message:new("user", update.content.text, meta))
    end
  end

  function handlers.agent_message_chunk(update, stream)
    if not (update.content and update.content.type == "text") then
      return
    end
    local message_id = update.messageId
    if stream.assistant_uuid then
      -- A turn can hold several assistant messages, each with its own id (claude
      -- emits trailing/followup messages after a tool call or at turn end). The
      -- chunks of one message share an id and stream into one block; a change of
      -- id is a new message, separated with a blank line so the two don't run
      -- together on one line.
      local sep = (message_id and stream.assistant_message_id and message_id ~= stream.assistant_message_id) and "\n\n"
        or ""
      view:update_message(stream.assistant_uuid, function(msg)
        msg:append_text(sep .. update.content.text)
      end)
      if message_id then
        stream.assistant_message_id = message_id
      end
    else
      local msg = Message:new("assistant", update.content.text)
      stream.assistant_uuid = msg.uuid
      stream.assistant_message_id = message_id
      stream.thinking_uuid = nil
      view:add_message(msg)
    end
  end

  function handlers.agent_thought_chunk(update, stream)
    if not (update.content and update.content.type == "text" and update.content.text ~= "") then
      return
    end
    if stream.thinking_uuid then
      view:update_message(stream.thinking_uuid, function(msg)
        for _, item in ipairs(msg.content) do
          if item.type == "thinking" then
            item.thinking = (item.thinking or "") .. update.content.text
            return
          end
        end
      end)
    else
      local msg = Message:new("assistant", {
        type = "thinking",
        thinking = update.content.text,
      })
      stream.thinking_uuid = msg.uuid
      stream.assistant_uuid = nil
      view:add_message(msg)
    end
  end

  function handlers.tool_call(update, stream, session_id)
    -- A tool run by a subagent is folded into the tool that spawned it: one
    -- subagent easily runs dozens of calls, and left at top level they bury the
    -- main conversation. `parent_tool_call_id` is set by a provider transform,
    -- so this stays namespace-agnostic.
    local record = session_id and stream.subagents[session_id]
    -- The agent parents every child call at the original Agent call, even after
    -- a SendMessage resume. Re-parent to the call that triggered THIS run (the
    -- Agent call for the launch, the SendMessage call for a resume, tracked on
    -- the record), so resumed work folds under the SendMessage inline instead of
    -- back up at the original card.
    if record and record.nest_tool_id then
      update.parent_tool_call_id = record.nest_tool_id
    end
    local parent_uuid = update.parent_tool_call_id and stream.tool_map[update.parent_tool_call_id]
    local parent = parent_uuid and view:get_message(parent_uuid) or nil
    -- Bind the child session to its parent card. `session_message` usually does
    -- this first (and carries the prompt), but an Agent call with no prompt
    -- sends none, so the first child call is the backstop.
    if parent_uuid and record and not record.parent_uuid then
      bind_parent(record, parent_uuid)
    end
    -- A top-level call ends the text/thought blocks it lands after. A nested one
    -- is placed under its parent, not at the tail, so the main stream carries on.
    if not parent then
      stream.assistant_uuid = nil
      stream.thinking_uuid = nil
    end
    local existing_uuid = stream.tool_map[update.toolCallId]
    if existing_uuid then
      view:update_message(existing_uuid, function(msg)
        for _, item in ipairs(msg.content) do
          if item.type == "tool_use" and item.id == update.toolCallId then
            if update.status then
              item.status = update.status
            end
            if update.kind or update.title then
              item.name = update.kind or update.title
            end
            if update.rawInput then
              item.input = update.rawInput
            end
          end
        end
        if msg.metadata.tool_call then
          for k, v in pairs(update) do
            msg.metadata.tool_call[k] = v
          end
        end
      end)
    else
      local metadata = { tool_call = update }
      if parent then
        metadata.parent_tool_call_id = update.parent_tool_call_id
      end
      local msg = Message:new("assistant", {
        type = "tool_use",
        name = update.kind or update.title or "tool",
        id = update.toolCallId,
        input = update.rawInput or {},
        status = update.status or "pending",
        failure_reason = update.failure_reason,
      }, metadata)
      stream.tool_map[update.toolCallId] = msg.uuid
      if not parent then
        view:add_message(msg)
        return
      end
      -- Hidden while the parent is collapsed; a child arriving after the user
      -- expanded it shows up straight away.
      msg.visible = parent.metadata._expanded == true
      -- Directly after the parent's previous child, NOT at the tail: the main
      -- session keeps streaming while a subagent runs, and appended children
      -- would expand below everything said since.
      local after = parent.metadata.last_child_uuid or parent_uuid
      -- Repaint the parent too, whose child count changed: the insert only
      -- dirties from the child down.
      view:update_message(parent_uuid, function(m)
        m.metadata.subagent_children = (m.metadata.subagent_children or 0) + 1
        m.metadata.last_child_uuid = msg.uuid
        attach_subagent_expand(m, view)
      end)
      view:insert_message_after(after, msg)
    end
  end

  function handlers.tool_call_update(update, stream, session_id)
    local uuid = stream.tool_map[update.toolCallId]
    if uuid then
      -- A content/rawOutput-only chunk (the common case while a tool streams)
      -- is throttled: apply it now, paint on the timer. Anything that changes
      -- what the card *shows structurally* -- status, title, locations, input
      -- -- renders promptly so the header/box/icon never lags the model.
      local structural = update.status ~= nil
        or update.title ~= nil
        or update.rawInput ~= nil
        or update.locations ~= nil
      view:update_message(uuid, function(msg)
        for _, item in ipairs(msg.content) do
          if item.type == "tool_use" and item.id == update.toolCallId then
            if update.status then
              item.status = update.status
            end
            if update.title then
              item.name = update.title
            end
            if update.rawInput then
              item.input = update.rawInput
            end
            -- CLI v3 failed-tool classification (cancelled | denied | error),
            -- normalised onto the generic field by the provider transform.
            if update.failure_reason then
              item.failure_reason = update.failure_reason
            end
          end
        end
        if msg.metadata.tool_call then
          if update.content and next(update.content) ~= nil then
            msg.metadata.tool_call.content = update.content
          end
          if update.status then
            msg.metadata.tool_call.status = update.status
          end
          if update.title then
            msg.metadata.tool_call.title = update.title
          end
          if update.rawOutput then
            msg.metadata.tool_call.rawOutput = update.rawOutput
          end
          if update.locations then
            msg.metadata.tool_call.locations = update.locations
          end
        end
      end, { defer_render = not structural })
      -- Structural updates rendered synchronously via update_message above (any
      -- content deferred earlier rides along in that same paint). Content-only
      -- chunks arm the throttle timer to paint shortly.
      if not structural then
        ctx.schedule_tool_render()
      end
    end

    -- Debounced buffer reload for completed tool calls that wrote files.
    -- Skipped during session/load replay: those writes already happened on disk,
    -- so there is nothing to reload and no window to follow.
    if update.status == "completed" and uuid and not update.replay then
      local tc = (view:get_message(uuid) or {}).metadata
      tc = tc and tc.tool_call
      if tc and tc.content then
        local first_line = tc.locations and tc.locations[1] and tc.locations[1].line
        -- A subagent's write reloads an open buffer but must not steer the
        -- source window: a background agent shouldn't yank the user's editor.
        local no_follow = session_id ~= nil and stream.subagents[session_id] ~= nil
        for _, c in ipairs(tc.content) do
          if c.type == "diff" and c.path then
            ctx.schedule_reload(c.path, first_line, no_follow)
          end
        end
      end
    end
  end

  function handlers.plan(update, stream)
    -- Each `plan` update carries the FULL current plan and supersedes the
    -- previous one — it's a self-updating block, not an append. Render it once
    -- per turn and rewrite in place as entries progress. `stream.plan_uuid` is
    -- cleared only by reset_state (next prompt), so the plan keeps updating even
    -- as assistant text / tool calls interleave around it.
    local parts = { "**Plan:**" }
    for _, entry in ipairs(update.entries or {}) do
      local icon = entry.status == "completed" and "✓" or entry.status == "in_progress" and "→" or "○"
      parts[#parts + 1] = icon .. " " .. entry.content
    end
    local text = table.concat(parts, "\n")
    -- Update in place only while the plan is still the last block. Once other
    -- content (tool calls, assistant text) has streamed in below it, the plan
    -- has scrolled out of view — so re-display a fresh copy at the bottom
    -- instead of silently mutating the off-screen one.
    local messages = view:get_messages()
    local last = messages[#messages]
    if stream.plan_uuid and last and last.uuid == stream.plan_uuid then
      view:update_message(stream.plan_uuid, function(msg)
        msg.content = { { type = "text", text = text } }
      end)
    else
      local msg = Message:new("system", text)
      stream.plan_uuid = msg.uuid
      view:add_message(msg)
    end
  end

  function handlers.available_commands_update(update)
    Commands.clear_acp()
    for _, cmd in ipairs(update.availableCommands or {}) do
      local name = cmd.name:gsub("^/", "")
      local input = cmd.input
      local hint = type(input) == "table" and input.hint or nil
      if hint == vim.NIL or hint == "" then
        hint = nil
      end
      Commands.register(name, {
        desc = cmd.description or name,
        source = "acp",
        hint = hint,
        execute = function(args, cmd_ctx)
          if cmd_ctx.view.on_submit then
            cmd_ctx.view.on_submit("/" .. name .. (args ~= "" and (" " .. args) or ""))
          end
        end,
      })
    end
  end

  function handlers.session_info_update(update)
    if update.title then
      if session.session_id then
        -- A fork shares its parent's history, so the title the agent derives
        -- (the conversation's first message) is the parent's. Persisting it
        -- makes the fork duplicate the parent in the picker ("title … ⑂ title").
        -- Leave a fork's own title to its first new prompt (record_session) or a
        -- rename; the ⑂ column already names the parent.
        local entry = Sessions.get(session.session_id)
        if not (entry and entry.forked_from) then
          Sessions.update_title(session.session_id, update.title)
        end
      end
    end
  end

  function handlers.usage_update(update)
    -- Standard ACP context-window update: { used, size, cost? }
    vim.schedule(function()
      if update.used and update.size and update.size > 0 then
        local pct = (update.used / update.size) * 100
        Winbar.set_context(pct)
      end
      if update.cost and type(update.cost.amount) == "number" then
        local sym = update.cost.currency == "USD" and "$" or ((update.cost.currency or "") .. " ")
        Winbar.set_badge("cost", string.format("%s%.2f", sym, update.cost.amount))
      end
    end)
  end

  function handlers.current_mode_update(update)
    -- Standard ACP permission/mode update.
    if update.currentModeId then
      vim.schedule(function()
        session.extensions = session.extensions or {}
        session.extensions.mode_id = update.currentModeId
        ctx.render_mode(update.currentModeId)
      end)
    end
  end

  function handlers.config_option_update(update, _, session_id)
    -- Only the root session's own snapshot is a full set to reconcile. claude-acp
    -- also reports each subagent's model as a one-entry `config_option_update`:
    -- on the child's session, or on the root tagged with the child's launching
    -- `parentToolUseId`. Reconciling either would replace the root's options
    -- with that single entry (dropping mode/effort/...), so both are ignored.
    if session_id and session.session_id and session_id ~= session.session_id then
      return
    end
    local cc = type(update._meta) == "table" and update._meta.claudeCode or nil
    if type(cc) == "table" and cc.parentToolUseId then
      return
    end
    vim.schedule(function()
      ctx.reconcile_config_options(update.configOptions)
    end)
  end

  -- ACP subagents RFD: announces a child session before any of its traffic;
  -- later copies patch its title/state. The record marks the id a subagent (so
  -- the dispatcher routes its traffic here) and carries the link to the parent
  -- card once known. The `state.state` (running | requires_action | idle, with
  -- a stopReason or error on idle) drives the card's status glyph. Recorded
  -- synchronously, not scheduled, because the child's first updates follow
  -- right behind.
  function handlers.subagent_update(update, stream)
    local child = update.sessionId
    if type(child) ~= "string" or child == "" then
      return
    end
    local record = stream.subagents[child] or {}
    stream.subagents[child] = record
    record.session_id = child
    -- Kept for a card we may have to synthesize (a subagent spawned with no
    -- visible Agent/Task tool_call, e.g. a background one): the announcement is
    -- the only source of a human label for it.
    if type(update.title) == "string" and update.title ~= "" then
      record.title = update.title
    end
    if type(update.description) == "string" and update.description ~= "" then
      record.description = update.description
    end
    -- Advertised `capabilities.cancel` lets the card stop just this child. A
    -- concrete capabilities object replaces the set; omitted leaves it. A
    -- finished child clears it (null), which disables the card's cancel.
    if type(update.capabilities) == "table" then
      record.cancellable = update.capabilities.cancel ~= nil
      if record.parent_uuid then
        local can = record.cancellable
        view:update_message(record.parent_uuid, function(m)
          m.metadata.subagent_cancellable = can
        end)
      end
    end
    -- Omitted state leaves the current one; only a concrete object replaces it.
    -- Normalize to a display state: a failure is `idle` with an `error` stop
    -- reason, not a state of its own, but the card's icon marks it as failed
    -- rather than done. `requires_action` drives the folded-tool marker; every
    -- state drives the leading status icon, so the latest always wins.
    local st = type(update.state) == "table" and update.state
    if st and type(st.state) == "string" then
      if st.state == "idle" and (st.stopReason == "error" or st.error ~= nil) then
        record.state = "failed"
      else
        record.state = st.state
      end
      -- The first `running` lands before the card is bound; the bind flushes it.
      set_card_state(record)
    end
  end

  -- A child session's launch message (ACP subagents RFD). Its `messageId` is the
  -- toolCallId of the Agent/Task call that spawned the child, so it binds the
  -- child session to that card; its text is the subagent's prompt, which the
  -- card shows in its expanded body. Renders no message of its own.
  function handlers.session_message(update, stream, session_id)
    local record = session_id and stream.subagents[session_id]
    if not record then
      return
    end
    local trigger_id = type(update.messageId) == "string" and update.messageId or nil
    if not trigger_id then
      return
    end
    local trigger_uuid = stream.tool_map[trigger_id]
    if not record.parent_uuid then
      -- The launch: bind the subagent's card. The trigger is the spawning
      -- Agent/Task call; when it has no card (a subagent spawned without a
      -- visible tool_call, e.g. a background one) synthesize one so the work
      -- nests rather than spilling onto the main transcript. The binding is
      -- permanent, so state stays put even as later runs move the work.
      if not trigger_uuid then
        trigger_uuid = create_subagent_card(stream, record, trigger_id)
      end
      record.nest_tool_id = trigger_id
      bind_parent(record, trigger_uuid)
      local prompt = text_of(update.content)
      if prompt ~= "" then
        view:update_message(trigger_uuid, function(m)
          m.metadata.subagent_prompt = prompt
        end)
      end
    elseif trigger_uuid then
      -- A resume whose trigger has a real card (the SendMessage call): fold this
      -- run's work under it so it continues inline. A background resume with no
      -- such card keeps nesting under the launch card rather than opening an
      -- empty fold.
      record.nest_tool_id = trigger_id
    end
  end

  return handlers
end

return M
