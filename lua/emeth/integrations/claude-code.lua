--- Claude Code provider extension.
---
--- All claude-acp-specific knowledge lives here. The generic ACP integration
--- talks to this module through these optional hooks:
---   - `setup(session, view) → cleanup`        custom notification subscriber
---   - `build_session_meta(emeth_config) → t`  `_meta` to attach on session/new
---   - `format_mode(mode_id) → render_desc`    badge + bottom-bar tag rendering
---   - `extract_session_info(result, exts)`    scrape claude-acp's configOptions
---
--- Subagents: claude reports Task-tool invocations. We track in-flight Task
--- tool calls per-session so that a `transform_update` callback (registered
--- via `view.integration.set_transform_update` inside `setup`) can enrich the
--- Task tool_call card title with the description + subagent_type for visual
--- attribution. State is closure-scoped, never module-level.

local Message = require("emeth.message")
local Winbar = require("emeth.ui.winbar")

local M = {}

-- Human-friendly labels + bottom-bar highlight kind for claude-code modes.
-- "normal" modes (default/auto) skip the bottom-bar tag entirely.
local MODE_INFO = {
  default = { label = "ask", kind = "hint", normal = true },
  auto = { label = "auto", kind = "hint", normal = true },
  acceptEdits = { label = "auto-edit", kind = "info" },
  plan = { label = "plan", kind = "info" },
  dontAsk = { label = "deny-default", kind = "warn" },
  bypassPermissions = { label = "bypass", kind = "error" },
}

---Render description for a given mode id. The generic integration consumes
---only `badge`, `tag`, and `tag_kind` — it knows nothing about the keys here.
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
    return { badge = "⚙ " .. info.label } -- no bottom-bar tag for normal modes
  end
  return { badge = "⚙ " .. info.label, tag = info.label, tag_kind = info.kind }
end

---Scrape claude-acp's `configOptions` shape for the active model/mode and
---reflect them in the model badge. Standard ACP fields are handled in
---session.lua before we're called.
---@param result table  raw session/new or session/load result
---@param extensions table  session.extensions; populate fields here
function M.extract_session_info(result, extensions)
  if result.configOptions then
    for _, opt in ipairs(result.configOptions) do
      if opt.id == "model" and type(opt.currentValue) == "string" then
        extensions.model_id = opt.currentValue
      elseif opt.id == "mode" and type(opt.currentValue) == "string" then
        extensions.mode_id = opt.currentValue
      end
    end
  end
  -- Refresh the model badge in the winbar to reflect the (possibly updated) id.
  vim.schedule(function()
    local model = extensions.model_id
    if not model or model == "" then
      Winbar.clear_badge("model")
      return
    end
    -- Strip provider prefix and trailing date for display: "claude-opus-4-6" → "opus-4-6"
    local short = model:gsub("^claude%-", ""):gsub("%-?20%d%d%d%d%d%d?$", "")
    Winbar.set_badge("model", short)
  end)
end

---Build the `_meta` payload to attach to `session/new`/`session/load`.
---Reads `config.claude_code.extra_args` and emits the claude-acp-shaped
---`{ claudeCode = { options = { extraArgs = {...} } } }` envelope.
---
---`extra_args` is a `table<string, string|true>` — keys become claude CLI
---flags. A boolean `true` value renders as a bare `--key`; a string renders
---as `--key value`.
---@param emeth_config table
---@return table|nil
function M.build_session_meta(emeth_config)
  local cc = emeth_config and emeth_config.claude_code or {}
  local extra_args = cc.extra_args
  if type(extra_args) ~= "table" or next(extra_args) == nil then
    return nil
  end
  return {
    claudeCode = {
      options = {
        extraArgs = vim.deepcopy(extra_args),
      },
    },
  }
end

---@class claude_code.TaskInfo
---@field description string  human-friendly label (from rawInput.description)
---@field subagent_type string|nil  e.g. "general-purpose", "Explore", "Plan"
---@field status string  pending|in_progress|completed|failed|cancelled

---Build a sender label from a tracked task entry, including the secondary
---`subagent_type` for flavour when available: `"description ⊳ Explore"`.
---@param entry claude_code.TaskInfo
---@return string
local function task_sender_label(entry)
  if entry.subagent_type and entry.subagent_type ~= "" then
    return entry.description .. " ⊳ " .. entry.subagent_type
  end
  return entry.description
end

---Process a session/update payload looking for Task tool_call lifecycle.
---Mutates `tasks` in place.
---@param tasks table<string, claude_code.TaskInfo>
---@param update table
local function track_task_update(tasks, update)
  local meta = update._meta and update._meta.claudeCode
  local tool_name = meta and meta.toolName
  if tool_name ~= "Task" and tool_name ~= "Agent" then
    return
  end
  local id = update.toolCallId
  if not id then
    return
  end
  if update.sessionUpdate == "tool_call" then
    local raw = update.rawInput or {}
    tasks[id] = {
      description = (type(raw.description) == "string" and raw.description ~= "" and raw.description)
        or update.title
        or "Task",
      subagent_type = (type(raw.subagent_type) == "string" and raw.subagent_type ~= "") and raw.subagent_type or nil,
      status = update.status or "pending",
    }
  elseif update.sessionUpdate == "tool_call_update" then
    local entry = tasks[id]
    if not entry then
      return
    end
    -- Late-arriving rawInput may finally contain the description / subagent_type
    -- (claude streams the tool_call header before the input json is complete).
    if type(update.rawInput) == "table" then
      local raw = update.rawInput
      if type(raw.description) == "string" and raw.description ~= "" then
        entry.description = raw.description
      end
      if type(raw.subagent_type) == "string" and raw.subagent_type ~= "" then
        entry.subagent_type = raw.subagent_type
      end
    end
    if update.status then
      entry.status = update.status
    end
    if update.status == "completed" or update.status == "failed" or update.status == "cancelled" then
      tasks[id] = nil
    end
  end
end

---Build a `transform_update` closure that rewrites Task / Agent tool titles
---to include the subagent_type for visual flavour. Captures `tasks` so it
---reads the freshest tracked state at call time.
---@param tasks table<string, claude_code.TaskInfo>
---@return fun(update: table)
local function make_transform_update(tasks)
  return function(update)
    if not update or not update._meta then
      return
    end
    local meta = update._meta.claudeCode
    if not meta or (meta.toolName ~= "Task" and meta.toolName ~= "Agent") then
      return
    end
    local entry = tasks[update.toolCallId]
    local description, subagent_type
    if entry then
      description = entry.description
      subagent_type = entry.subagent_type
    end
    -- Streaming updates may pass fresh rawInput; prefer those values.
    if type(update.rawInput) == "table" then
      local raw = update.rawInput
      if type(raw.description) == "string" and raw.description ~= "" then
        description = raw.description
      end
      if type(raw.subagent_type) == "string" and raw.subagent_type ~= "" then
        subagent_type = raw.subagent_type
      end
    end
    if description and description ~= "" then
      if subagent_type and subagent_type ~= "" then
        update.title = description .. " ⊳ " .. subagent_type
      else
        update.title = description
      end
    end
  end
end

-- Exposed for testing.
M._task_sender_label = task_sender_label
M._track_task_update = track_task_update
M._make_transform_update = make_transform_update

---Hook claude-code-specific notifications + subagent tracking. All state is
---closure-scoped — multiple sessions don't interfere.
---@param session acp.Session
---@param view chat_ui.ChatView
---@return fun() cleanup
function M.setup(session, view)
  ---@type table<string, claude_code.TaskInfo>
  local tasks = {}

  local function on_notification(method, params)
    if method ~= "_claude/sdkMessage" or not params or not params.message then
      return
    end
    local cfg = require("emeth").config.claude_code or {}
    if not cfg.show_raw_sdk_messages then
      return
    end
    vim.schedule(function()
      local encoded = vim.json.encode(params.message)
      if #encoded > 800 then
        encoded = encoded:sub(1, 800) .. "…"
      end
      view:add_message(Message:new("system", "[claude/sdk] " .. encoded))
    end)
  end

  local function on_update(update)
    track_task_update(tasks, update)
  end

  session:on("notification", on_notification)
  session:on("update", on_update)

  -- Register the per-session transform callback. `view.integration` is set
  -- by the generic integration *before* it calls into this `setup()`, so
  -- the setter is available here.
  if view.integration then
    if view.integration.set_transform_update then
      view.integration.set_transform_update(make_transform_update(tasks))
    end
    -- Expose a count of in-flight background tasks so the integration layer
    -- can signal the user when deferred output is pending.
    view.integration.get_pending_task_count = function()
      local n = 0
      for _ in pairs(tasks) do
        n = n + 1
      end
      return n
    end
  end

  return function()
    session:off("notification", on_notification)
    session:off("update", on_update)
    Winbar.clear_badge("model")
    Winbar.clear_badge("mode")
    Winbar.clear_badge("cost")
    if view.integration and view.integration.set_transform_update then
      view.integration.set_transform_update(nil)
    end
  end
end

return M
