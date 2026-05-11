--- Claude Code provider extension.
---
--- All claude-acp-specific knowledge lives here. The generic ACP integration
--- talks to this module through these optional hooks:
---   - `setup(session, view) → cleanup`        custom notification subscriber
---   - `build_session_meta(emeth_config) → t`  `_meta` to attach on session/new
---   - `format_mode(mode_id) → render_desc`    badge + bottom-bar tag rendering
---   - `extract_session_info(result, exts)`    scrape claude-acp's configOptions

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

---Hook claude-code-specific notifications. The mode badge / tag / model
---display are now handled via `format_mode` and `extract_session_info`, so
---this only handles the optional raw-SDK-message debug stream.
---@param session acp.Session
---@param view chat_ui.ChatView
---@return fun() cleanup
function M.setup(session, view)
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

  session:on("notification", on_notification)

  return function()
    session:off("notification", on_notification)
    Winbar.clear_badge("model")
    Winbar.clear_badge("mode")
    Winbar.clear_badge("cost")
  end
end

return M
