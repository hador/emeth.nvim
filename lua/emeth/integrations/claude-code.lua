--- Claude Code provider extension.
---
--- All claude-acp-specific knowledge lives here. The generic ACP integration
--- talks to this module through these optional hooks:
---   - `setup(session, view) → cleanup`        custom notification subscriber
---   - `build_session_meta(emeth_config) → t`  `_meta` to attach on session/new
---   - `format_mode(mode_id) → render_desc`    badge + bottom-bar tag rendering
---   - `format_model(model_id) → string`       shorten model id for display
---
--- Subagents: a stateless transform_update rewrites Task/Agent tool_call titles
--- to show the description + subagent_type directly from the streaming rawInput.
--- No lifecycle tracking — titles are enriched opportunistically as data arrives.

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

---Shorten a claude model id for display by removing claude-family noise: the
---`claude-` family token and any trailing release date. Unanchored so it also
---fires inside a Bedrock-style prefixed id (the generic length fallback in the
---core integration strips the dotted region/vendor prefix itself):
---   "claude-opus-4-6"                      → "opus-4-6"
---   "claude-sonnet-4-5-20250101"           → "sonnet-4-5"
---   "global.anthropic.claude-opus-4-8[1m]" → "global.anthropic.opus-4-8[1m]"
---This hook only encodes claude id-shape knowledge; keeping the result short
---enough to display is the generic integration's job.
---@param model_id string
---@return string
function M.format_model(model_id)
  return (
    model_id
      :gsub("claude%-", "") -- drop the claude- family token wherever it appears
      :gsub("%-?20%d%d%d%d%d%d?$", "") -- drop a trailing release date
  )
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

---Stateless transform: enrich Task/Agent tool_call titles with the
---description and subagent_type from rawInput as it streams in.
---@param update table
local function transform_update(update)
  if not update or not update._meta then
    return
  end
  local meta = update._meta.claudeCode
  if not meta or (meta.toolName ~= "Task" and meta.toolName ~= "Agent") then
    return
  end
  local raw = type(update.rawInput) == "table" and update.rawInput or {}
  local description = (type(raw.description) == "string" and raw.description ~= "" and raw.description) or update.title
  local subagent_type = type(raw.subagent_type) == "string" and raw.subagent_type ~= "" and raw.subagent_type or nil
  if description and description ~= "" then
    if subagent_type then
      update.title = description .. " ⊳ " .. subagent_type
    else
      update.title = description
    end
  end
end

-- Exposed for testing.
M._transform_update = transform_update

-- `_meta` keys claude-acp attaches to elicitation payloads. Both are
-- underscore-prefixed, which the ACP spec reserves for implementation-specific
-- extensions — hence provider-local knowledge rather than generic handling.
local CUSTOM_ANSWER_META = "_askUserQuestionCustomAnswer"
local OPTION_META = "_claude/askUserQuestionOption"

---Enrich parsed elicitation fields with claude-acp's AskUserQuestion shape.
---
---The generic renderer already handles these forms correctly — claude-acp maps
---questions onto standard schema fields (`title` is the header chip,
---`description` the question text, `oneOf` the options). Two provider-specific
---touches remain:
---
---  1. Each select field is followed by a `question_<n>_custom` free-text field
---     that is really the CLI's per-question "Other" box. Folding it into its
---     sibling turns two prompts into one "type your own…" line.
---  2. An option's `preview` (mockups, code snippets) rides in the option's
---     `_meta` because `EnumOption` has no slot for it. Lift it so K can show it.
---
---Also restores question order: `parse` sorts keys, which is stable but puts
---`question_10` before `question_2`.
---@param fields acp.ElicitationField[]
---@return acp.ElicitationField[]
local function transform_elicitation(fields)
  -- Index the custom-answer companions by the question they belong to, and
  -- collect them for removal. The `_meta` marker is authoritative; the
  -- `question_<n>_custom` name is only a fallback for a reshaped payload.
  local custom_for = {} ---@type table<string, string>
  local is_custom = {} ---@type table<string, boolean>
  for _, field in ipairs(fields) do
    local marker = type(field.meta) == "table" and field.meta[CUSTOM_ANSWER_META] or nil
    local owner = type(marker) == "table" and type(marker.questionId) == "string" and marker.questionId or nil
    if not owner then
      local base = field.key:match("^(.+)_custom$")
      if base and field.kind == "text" then
        owner = base
      end
    end
    if owner then
      custom_for[owner] = field.key
      is_custom[field.key] = true
    end
  end

  local out = {}
  for _, field in ipairs(fields) do
    if not is_custom[field.key] then
      field.custom_key = custom_for[field.key]
      for _, opt in ipairs(field.options or {}) do
        local meta = type(opt.meta) == "table" and opt.meta[OPTION_META] or nil
        if type(meta) == "table" and type(meta.preview) == "string" and meta.preview ~= "" then
          opt.preview = meta.preview
        end
      end
      out[#out + 1] = field
    end
  end

  -- Sort `question_<n>` fields by numeric index; anything else keeps its
  -- relative position after them.
  local order = {}
  for i, field in ipairs(out) do
    local n = field.key:match("^question_(%d+)$")
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

---Hook claude-code-specific notifications and the title transform.
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

  if view.integration and view.integration.set_transform_update then
    view.integration.set_transform_update(transform_update)
  end
  if view.integration and view.integration.set_transform_elicitation then
    view.integration.set_transform_elicitation(transform_elicitation)
  end

  return function()
    session:off("notification", on_notification)
    Winbar.clear_badge("model")
    Winbar.clear_badge("mode")
    Winbar.clear_badge("cost")
    if view.integration and view.integration.set_transform_update then
      view.integration.set_transform_update(nil)
    end
    if view.integration and view.integration.set_transform_elicitation then
      view.integration.set_transform_elicitation(nil)
    end
  end
end

return M
