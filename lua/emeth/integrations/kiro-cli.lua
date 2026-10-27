--- Kiro CLI v3 ACP extension (`kiro-cli acp --agent-engine=v3`).
---
--- v3 is the Kiro Agent Server-backed ACP server. All the CLI v2 `_kiro.dev/*`
--- methods are gone; model/mode/effort now ride the standard `configOptions` +
--- `session/set_config_option` channel (handled generically by integrations/acp),
--- so this module only carries what is genuinely kiro-shaped:
---
---   * steering via `_session/steer` (always queues; async lifecycle)
---   * `session_info_update` kinds under `_meta.kiro.kind`
---     (context_usage, turn_completion, steering_*, summarization_*, display_error)
---   * `_kiro/*` notifications (rate limit, custom-agent errors, MCP status)
---   * MCP OAuth: `/mcp-auth` + the `_kiro/openExternalUrl` request
---   * a transform normalising `_meta.kiro` onto generic update fields
---
--- Written against kiro-cli 2.31.1's v3 engine; re-checked against 2.34.x (its
--- ACP surface is byte-identical from 2.34.0 to 2.34.2).

local Commands = require("emeth.commands")
local Message = require("emeth.message")
local Winbar = require("emeth.ui.winbar")

local M = {}

---Return `_meta.kiro` off an update, or nil.
---@param update table|nil
---@return table|nil
local function kiro_meta(update)
  local meta = update and update._meta
  if type(meta) ~= "table" then
    return nil
  end
  return type(meta.kiro) == "table" and meta.kiro or nil
end

---Stateless transform: lift kiro's `_meta.kiro` onto the generic fields the core
---integration understands, and drop the empty replay boundary chunk. Returning
---`false` tells the integration to drop the update entirely.
---@param update table
---@return boolean|nil  false to drop
local function transform_update(update)
  -- Replayed steers come back as `user_message_chunk` with a trailing empty
  -- boundary chunk; the generic handler would render that as a blank user
  -- message. Drop any content-less user_message_chunk (independent of `_meta`,
  -- which the boundary marker may not carry).
  if update.sessionUpdate == "user_message_chunk" then
    local c = update.content
    if not (type(c) == "table" and type(c.text) == "string" and c.text ~= "") then
      return false
    end
  end

  local k = kiro_meta(update)
  if not k then
    return
  end

  if k.replay == true then
    update.replay = true
  end
  -- Agent-side message id (present on replayed user/agent chunks). Lifted onto a
  -- generic field so a rendered user message can carry it for rewind targeting.
  if type(k.messageId) == "string" then
    update.provider_message_id = k.messageId
  end
  -- `_meta.kiro.failureReason` (cancelled | denied | error) would classify a
  -- failed tool call for the generic renderer's `failure_reason`. Unconfirmed:
  -- in the 2.31.1 and 2.34.0 v3 bundles `failureReason` appears only on
  -- workflow-node state, not on tool_call `_meta.kiro`, so this may never fire.
  -- Kept until a denied v3 tool call is captured to settle it.
  if type(k.failureReason) == "string" then
    update.failure_reason = k.failureReason
  end

  -- Subagent nesting. The spawning subtask arrives as a tool_call whose own
  -- toolCallId equals its agentSubtaskId and carries kind "agent-subtask"; each
  -- call it makes carries that same agentSubtaskId. Point the children at it so
  -- the core nests them (the same shape claude uses).
  if
    k.kind ~= "agent-subtask"
    and type(k.agentSubtaskId) == "string"
    and k.agentSubtaskId ~= ""
    and update.toolCallId ~= k.agentSubtaskId
  then
    update.parent_tool_call_id = k.agentSubtaskId
  end
end

-- Exposed for testing.
M._transform_update = transform_update

---Build the `session/new` `_meta` payload. When `config.kiro_cli.mode` is set,
---start new sessions on that agent/mode via `_meta.kiro.modeId` (v3 session
---input, verified live). Applied to NEW sessions only — a resumed session keeps
---the mode it already had, so `kind == "load"` returns nothing.
---@param emeth_config table
---@param kind? "new"|"load"
---@return table|nil
function M.build_session_meta(emeth_config, kind)
  if kind == "load" then
    return nil
  end
  local mode = emeth_config and emeth_config.kiro_cli and emeth_config.kiro_cli.mode
  if type(mode) == "string" and mode ~= "" then
    return { kiro = { modeId = mode } }
  end
  return nil
end

---Hook kiro-cli v3 behaviour into the ACP integration.
---@param session acp.Session
---@param view chat_ui.ChatView
---@return fun() cleanup
function M.setup(session, view)
  session.extensions = session.extensions or {}
  local credits_total = 0 -- summed turn_completion credit usage, for the badge
  local seen_errors = {} ---@type table<string, boolean>  dedup display_error
  local announced_auth = {} ---@type table<string, boolean>  dedup "needs auth"

  -- ── Steering ──────────────────────────────────────────────────
  -- `_session/steer` takes a plain string and ALWAYS queues, returning
  -- `{queued, messageId}`. It is injected at the next inference boundary (within
  -- the running turn, or — if the turn has ended — not until the next prompt).
  -- There is no synchronous "injected"/"promptRequired" outcome and no advertised
  -- capability to gate on, so support is simply constant.
  if view.integration and view.integration.set_steering then
    view.integration.set_steering({
      supported = true,
      steer = function(prompt, text, cb)
        -- kiro steer is a string; fold any @-attached file paths into it.
        local message = text or ""
        local files = {}
        for _, item in ipairs(prompt or {}) do
          if item.type == "resource_link" and type(item.uri) == "string" then
            files[#files + 1] = (item.uri:gsub("^file://", ""))
          end
        end
        if #files > 0 then
          message = message .. "\n\nAttached files:\n" .. table.concat(files, "\n")
        end
        session:request("_session/steer", {
          sessionId = session.session_id,
          message = message,
        }, function(result, err)
          if err then
            cb(nil, err)
            return
          end
          cb("queued", nil, { message_id = type(result) == "table" and result.messageId or nil })
        end)
      end,
    })
  end

  ---Flip the steer-state marker on the user message that carries `message_id`.
  ---@param message_id string
  ---@param state string
  ---@param only_if_queued? boolean  only downgrade ones never injected
  local function set_steer_state(message_id, state, only_if_queued)
    for _, m in ipairs(view:get_messages()) do
      if m.metadata and m.metadata.steer_message_id == message_id then
        if only_if_queued and m.metadata.steer_state ~= "queued" then
          return
        end
        view:update_message(m.uuid, function(mm)
          mm.metadata.steer_state = state
        end)
        return
      end
    end
  end

  -- ── session_info_update kinds (_meta.kiro.kind) ───────────────
  local function on_update(update)
    if update.sessionUpdate ~= "session_info_update" then
      return
    end
    local k = kiro_meta(update)
    if not k then
      return
    end
    local kind = k.kind

    if kind == "context_usage" then
      local usage = type(k.contextUsage) == "table" and k.contextUsage.usagePercentage or k.usagePercentage
      if type(usage) == "number" then
        vim.schedule(function()
          Winbar.set_context(usage)
        end)
      end
    elseif kind == "turn_completion" then
      -- Credit metering: sum each turn's usage across the session.
      local sum = 0
      for _, s in ipairs(k.promptTurnSummaries or {}) do
        if type(s.usage) == "number" then
          sum = sum + s.usage
        end
      end
      if sum > 0 then
        credits_total = credits_total + sum
        vim.schedule(function()
          Winbar.set_badge("cost", string.format("%.2f cr", credits_total))
        end)
      end
    elseif kind == "steering_injected" then
      if type(k.messageId) == "string" then
        vim.schedule(function()
          set_steer_state(k.messageId, "steered")
        end)
      end
    elseif kind == "steering_cleared" then
      -- A clear at turn end: anything still "queued" (never injected) was dropped.
      vim.schedule(function()
        for _, id in ipairs(k.messageIds or {}) do
          set_steer_state(id, "not_delivered", true)
        end
      end)
    elseif kind == "summarization_started" then
      vim.schedule(function()
        Winbar.set_state("compacting")
      end)
    elseif kind == "summarization_completed" then
      vim.schedule(function()
        Winbar.set_state("ready")
        local summary = k.conversationSummary
        if type(summary) == "string" and summary ~= "" then
          view:add_message(Message:new("system", summary))
        end
      end)
    elseif kind == "summarization_failed" then
      vim.schedule(function()
        Winbar.set_state("ready")
        view:add_message(Message:new("system", "Compaction failed" .. (k.error and (": " .. tostring(k.error)) or "")))
      end)
    elseif kind == "display_error" then
      local de = type(k.displayError) == "table" and k.displayError or k
      local text = de.message
      if type(text) == "string" and text ~= "" and not seen_errors[text] then
        seen_errors[text] = true
        vim.schedule(function()
          view:add_message(Message:new("system", "⚠ " .. text))
        end)
      end
    elseif kind == "turn_end" then
      -- Refusal / abnormal stop detail, when present.
      local details = type(k.turnEnd) == "table" and k.turnEnd.stopDetails or k.stopDetails
      if type(details) == "table" and type(details.message) == "string" and details.message ~= "" then
        vim.schedule(function()
          view:add_message(Message:new("system", details.message))
        end)
      end
    end
  end
  session:on("update", on_update)

  -- ── `_kiro/*` notifications ────────────────────────────────────
  local function on_notification(method, params)
    if method == "_kiro/error/rate_limit" then
      local msg = (params and params.message) or "Request limit reached"
      vim.schedule(function()
        view:add_message(Message:new("system", "⚠ " .. msg))
      end)
    elseif method == "_kiro/customAgent/not_found" then
      vim.schedule(function()
        local req = (params and params.requestedAgent) or "?"
        local skipped = params and params.skipped
        if type(skipped) == "table" then
          view:add_message(
            Message:new(
              "system",
              ("Agent '%s' found but unusable (%s): %s"):format(
                req,
                skipped.reasonCode or "?",
                skipped.error or skipped.path or ""
              )
            )
          )
        else
          view:add_message(
            Message:new(
              "system",
              ("Agent '%s' not found; using '%s'"):format(req, (params and params.fallbackAgent) or "default")
            )
          )
        end
      end)
    elseif method == "_kiro/customAgent/config_error" then
      vim.schedule(function()
        local rc = (params and params.reasonCode) or "?"
        if rc == "internal_error" then
          -- Not a user configuration fault — don't present it as one.
          view:add_message(Message:new("system", "Agent config internal error: " .. ((params and params.path) or "")))
        else
          view:add_message(
            Message:new(
              "system",
              ("Invalid agent config (%s): %s%s"):format(
                rc,
                (params and params.path) or "?",
                (params and params.error) and (" — " .. params.error) or ""
              )
            )
          )
        end
      end)
    elseif method == "_kiro/mcp/status" then
      -- Authoritative full snapshot. Announce a server needing auth once per
      -- auth-required episode (reset when it leaves the failed state).
      vim.schedule(function()
        for _, srv in ipairs((params and params.servers) or {}) do
          local name = srv.name
          if name then
            if srv.failedAuthorization == true then
              if not announced_auth[name] then
                announced_auth[name] = true
                view:add_message(
                  Message:new(
                    "system",
                    ("MCP server '%s' needs authentication — run /mcp-auth %s"):format(name, name)
                  )
                )
              end
            elseif srv.status ~= "failed" then
              announced_auth[name] = nil
            end
          end
        end
      end)
    end
  end
  session:on("notification", on_notification)

  -- ── MCP OAuth ──────────────────────────────────────────────────
  -- The agent asks us to open the authorization URL via a request; answer it.
  local function open_external_url(params, respond, respond_error)
    local url = params and params.url
    if type(url) == "string" and url ~= "" then
      local ok = pcall(vim.ui.open, url)
      respond({ success = ok == true })
    else
      respond_error("missing url", -32602)
    end
  end
  session:on_request("_kiro/openExternalUrl", open_external_url)

  -- `/mcp-auth <server>` forces reauthentication (removes local OAuth creds and
  -- starts a fresh flow). Registered as a builtin so the generic
  -- available_commands_update refresh (which clears acp-source commands) can't
  -- wipe it; removed on cleanup.
  Commands.register("mcp-auth", {
    desc = "Re-authenticate an MCP server (forced OAuth)",
    source = "builtin",
    hint = "<server>",
    execute = function(args)
      local server = vim.trim(args or "")
      if server == "" then
        vim.notify("[emeth] usage: /mcp-auth <server>", vim.log.levels.WARN)
        return
      end
      session:request("_kiro/mcp/resetServer", { serverName = server, startOAuth = true }, function(_, err)
        if err then
          vim.schedule(function()
            view:add_message(Message:new("system", "MCP auth failed: " .. require("emeth.util").fmt_err(err)))
          end)
        end
      end)
    end,
  })

  -- ── Rewind (fork at a past message) ───────────────────────────
  -- Fork ids live only in session/load replay; a live, never-loaded session's
  -- user messages carry none. So: if the selected message already has an id
  -- (session was resumed), fork there directly; otherwise reload the current
  -- session in place to harvest ids, then fork at the same message by ordinal.
  local function fork_supported()
    local sc = session.client
      and session.client.agent_capabilities
      and session.client.agent_capabilities.sessionCapabilities
    return sc ~= nil and sc.fork ~= nil
  end

  ---1-based position of `msg` among the transcript's user messages.
  local function user_ordinal(msg)
    local n = 0
    for _, m in ipairs(view:get_messages()) do
      if m.role == "user" then
        n = n + 1
        if m == msg then
          return n
        end
      end
    end
  end

  ---Agent message id of the n-th user message, or nil.
  local function nth_user_id(n)
    local seen = 0
    for _, m in ipairs(view:get_messages()) do
      if m.role == "user" then
        seen = seen + 1
        if seen == n then
          return m.metadata and m.metadata.provider_message_id
        end
      end
    end
  end

  local function do_rewind(msg)
    local ordinal = user_ordinal(msg)
    if not ordinal then
      return
    end
    local function fork_at(id)
      if not id then
        vim.schedule(function()
          view:add_message(Message:new("system", "Couldn't resolve a rewind point for that message."))
        end)
        return
      end
      view.integration.rewind({ kiro = { messageId = id } })
    end
    local known = msg.metadata and msg.metadata.provider_message_id
    if known then
      fork_at(known)
      return
    end
    -- Harvest: reload the current session in place so its replay stamps ids,
    -- then fork at the same ordinal's (now known) id.
    view.integration.load_session(session.session_id, function(err)
      if err then
        return
      end
      vim.schedule(function()
        fork_at(nth_user_id(ordinal))
      end)
    end)
  end

  local rewind_key = (require("emeth").config.kiro_cli or {}).rewind_key
  if rewind_key == nil then
    rewind_key = "R"
  end
  if view.add_action and rewind_key and rewind_key ~= "" then
    view:add_action({
      key = rewind_key,
      hint = rewind_key .. ": rewind",
      when = function(m)
        return m.role == "user" and fork_supported()
      end,
      run = do_rewind,
    })
  end

  -- Transform runs on every update before the core consumes it.
  if view.integration and view.integration.set_transform_update then
    view.integration.set_transform_update(transform_update)
  end

  return function()
    session:off("update", on_update)
    session:off("notification", on_notification)
    session:off_request("_kiro/openExternalUrl", open_external_url)
    Commands.unregister("mcp-auth")
    if view.remove_action and rewind_key and rewind_key ~= "" then
      view:remove_action(rewind_key)
    end
    Winbar.clear_badge("cost")
    if view.integration and view.integration.set_steering then
      view.integration.set_steering(nil)
    end
    if view.integration and view.integration.set_transform_update then
      view.integration.set_transform_update(nil)
    end
  end
end

return M
