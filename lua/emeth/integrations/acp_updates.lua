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
}

---@class acp_updates.Ctx
---@field view chat_ui.ChatView
---@field session acp.Session
---@field schedule_tool_render fun()  arm the streamed-content render throttle
---@field schedule_reload fun(path: string, first_changed?: integer)
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

---Build the dispatch table. Each handler receives the update plus the streaming
---state for the session that update belongs to; handlers that keep no streaming
---state ignore it.
---@param ctx acp_updates.Ctx
---@return table<string, fun(update: table, stream: acp.StreamState)>
function M.handlers(ctx)
  local view = ctx.view
  local session = ctx.session
  local handlers = {}

  function handlers.user_message_chunk(update)
    if update.content and update.content.type == "text" then
      view:add_message(Message:new("user", update.content.text))
    end
  end

  function handlers.agent_message_chunk(update, stream)
    if not (update.content and update.content.type == "text") then
      return
    end
    if stream.assistant_uuid then
      view:update_message(stream.assistant_uuid, function(msg)
        msg:append_text(update.content.text)
      end)
    else
      local msg = Message:new("assistant", update.content.text)
      stream.assistant_uuid = msg.uuid
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

  function handlers.tool_call(update, stream)
    stream.assistant_uuid = nil
    stream.thinking_uuid = nil
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
      -- A tool run by a subagent is folded into the tool that spawned it: one
      -- subagent easily runs dozens of calls, and left at top level they bury
      -- the main conversation. `parent_tool_call_id` is set by a provider
      -- transform, so this stays namespace-agnostic.
      local parent_uuid = update.parent_tool_call_id and stream.tool_map[update.parent_tool_call_id]
      local parent = parent_uuid and view:get_message(parent_uuid) or nil
      if parent then
        metadata.parent_tool_call_id = update.parent_tool_call_id
      end
      local msg = Message:new("assistant", {
        type = "tool_use",
        name = update.kind or update.title or "tool",
        id = update.toolCallId,
        input = update.rawInput or {},
        status = update.status or "pending",
      }, metadata)
      if parent then
        -- Hidden while the parent is collapsed; a child arriving after the user
        -- expanded it shows up straight away.
        msg.visible = parent.metadata._expanded == true
        -- Repaint just the parent, whose child count changed. The child's own
        -- add_message below only dirties from the child down, so the parent row
        -- would otherwise keep a stale count.
        view:update_message(parent_uuid, function(m)
          m.metadata.subagent_children = (m.metadata.subagent_children or 0) + 1
          attach_subagent_expand(m, view)
        end)
      end
      stream.tool_map[update.toolCallId] = msg.uuid
      view:add_message(msg)
    end
  end

  function handlers.tool_call_update(update, stream)
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

    -- Debounced buffer reload for completed tool calls that wrote files
    if update.status == "completed" and uuid then
      local tc = (view:get_message(uuid) or {}).metadata
      tc = tc and tc.tool_call
      if tc and tc.content then
        local first_line = tc.locations and tc.locations[1] and tc.locations[1].line
        for _, c in ipairs(tc.content) do
          if c.type == "diff" and c.path then
            ctx.schedule_reload(c.path, first_line)
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
      view._session_title = update.title
      if session.session_id then
        Sessions.update_title(session.session_id, update.title)
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

  function handlers.config_option_update(update)
    vim.schedule(function()
      ctx.reconcile_config_options(update.configOptions)
    end)
  end

  return handlers
end

return M
