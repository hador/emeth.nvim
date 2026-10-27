--- Agent-to-client prompts: permission requests and form elicitations.
---
--- Both are requests the agent blocks its turn on, so both are answered inline
--- in the transcript through a PromptQueue (one live prompt per kind, its keys
--- claimed on the view rather than bound) instead of a modal picker that would
--- steal focus. Split out of acp.lua, which attaches this once per integration
--- and reaches it only through the small handle `attach` returns: on_submit
--- offers each submission to `take_submit` (an elicitation may have claimed the
--- input box for a free-text answer), and do_cancel calls `cancel`.

local PromptQueue = require("emeth.ui.prompt_queue")
local Winbar = require("emeth.ui.winbar")

local M = {}

---@class acp_prompts.Ctx
---@field view chat_ui.ChatView
---@field session acp.Session
---@field get_stream fun(): acp.StreamState  current stream state (replaced on reset)
---@field get_transform_elicitation fun(): (fun(fields: acp.ElicitationField[], request: table): acp.ElicitationField[]|nil)|nil

---@class acp_prompts.Handle
---@field take_submit fun(text: string): boolean  hand a submission to a prompt waiting for free text; true if consumed
---@field cancel fun()  answer every open elicitation with `cancel`

---@param ctx acp_prompts.Ctx
---@return acp_prompts.Handle
function M.attach(ctx)
  local view, session = ctx.view, ctx.session
  -- Forward-declared: the elicitation helpers below close over it before the
  -- queue is constructed at the end of the section.
  local elicitations ---@type emeth.PromptQueue
  -- Set while a prompt is waiting for free text from the input box; the next
  -- submission goes there instead of to the agent.
  local input_capture = nil ---@type fun(text: string)|nil

  ---@class acp.PendingElicitation
  ---@field request acp.CreateElicitationRequest
  ---@field callback fun(response: acp.CreateElicitationResponse)
  ---@field fields acp.ElicitationField[]
  ---@field answers table<string, any>
  ---@field index integer          which field is being answered
  ---@field expanded boolean       K toggles descriptions + previews
  ---@field rows table<integer, table>  message line offset -> action
  ---@field awaiting_input? string  answer key the input box is currently claimed for
  ---@field prompt_uuid? string

  -- Flatten an agent-supplied string onto one line, optionally truncating.
  -- Newlines matter beyond looks: the renderer splits them into extra buffer
  -- rows, which would shift the elicitation row->action map and select the wrong
  -- option.
  ---@param s string|nil
  ---@param width? integer  truncate beyond this display width
  ---@return string
  local function oneline(s, width)
    local out = (s or ""):gsub("%s+", " ")
    if width and vim.fn.strdisplaywidth(out) > width then
      out = vim.fn.strcharpart(out, 0, width - 1) .. "…"
    end
    return out
  end

  local kind_keys = { allow_once = "a", allow_always = "A", reject_once = "r", reject_always = "R" }

  --- Build the prompt body for a queued permission request. The tool_call card
  --- is rendered directly above this prompt, so we keep it terse: a short tool
  --- identity (truncated — kiro titles are the whole command), the count of
  --- other requests waiting, then one line per option.
  ---@param req { tool_call: table, options: table[] }
  ---@param depth integer  queue depth, for the "N more pending" line
  ---@return string[] lines, string[] keys  keys aligned to req.options order
  local function permission_lines(req, depth)
    local tool_name = oneline(req.tool_call.title or req.tool_call.kind or "tool", 60)
    local lines = { "Agent wants permission for: " .. tool_name }
    if depth > 1 then
      lines[#lines + 1] = ("  (%d more pending)"):format(depth - 1)
    end
    -- Keys must come from the set the view binds permanently, otherwise the
    -- claim would never fire and the option would be unanswerable. The four ACP
    -- kinds map 1:1; an unknown kind takes whichever slot is still free.
    local keys = {}
    local taken = {}
    for _, opt in ipairs(req.options or {}) do
      local key = kind_keys[opt.kind]
      if not key or taken[key] then
        for _, candidate in ipairs(view:prompt_keys()) do
          if not taken[candidate] then
            key = candidate
            break
          end
        end
      end
      if key then
        taken[key] = true
        keys[#keys + 1] = key
        lines[#lines + 1] = "  [" .. key .. "] " .. (opt.name or opt.kind)
      end
    end
    return lines, keys
  end

  -- Answering hides the prompt rather than summarising it: the tool_call card
  -- rendered directly above already shows what happened to the call.
  local permissions = PromptQueue.new(view, {
    owner = "permission",
    render = function(req, q)
      local lines, keys = permission_lines(req, q:depth())
      req.keys = keys
      return lines
    end,
    claims = function(req, q)
      local claims = {}
      for i, opt in ipairs(req.options or {}) do
        local key = req.keys[i]
        if key then
          claims[key] = function()
            q:close(opt.optionId)
          end
        end
      end
      return claims
    end,
  })

  session:on("permission", function(tool_call, options, callback, permission_session_id)
    vim.schedule(function()
      -- Render the card via the regular tool_call path when the agent asked
      -- before announcing the call, under the session that asked (a subagent's
      -- request comes from its child session).
      if not ctx.get_stream().tool_map[tool_call.toolCallId] then
        local update = vim.tbl_extend("keep", tool_call, { sessionUpdate = "tool_call" })
        session:_emit("update", update, permission_session_id or session.session_id)
      end

      -- A nil callback means the session layer already answered this request
      -- (auto-approve): render the tool-call card above, but don't prompt.
      if not callback then
        return
      end

      -- Only the head claims keys. That serializes the UI for concurrent
      -- requests so their fixed a/r claims can't overwrite each other (which
      -- previously left earlier requests unanswerable → hang).
      permissions:push({ tool_call = tool_call, options = options, callback = callback })
    end)
  end)

  -- ── Elicitation ──────────────────────────────────────────────
  -- The agent asks the user a structured question and blocks its turn on the
  -- answer. Rendered inline in the transcript with cursor-positioned <CR>, not
  -- as a picker: elicitations arrive unpredictably, and a modal window would
  -- steal focus (and keystrokes) from whatever buffer the user is editing.

  ---Lines for the active field, plus the row->action map that makes <CR> work.
  ---Row keys are 1-based offsets within the rendered message, which line up
  ---1:1 with this array because system messages render one row per text line.
  ---@param req acp.PendingElicitation
  ---@param depth integer  queue depth, for the "N more waiting" line
  ---@return string[] lines, table<integer, table> rows
  local function elicitation_lines(req, depth)
    local field = req.fields[req.index]
    local lines = {}
    local rows = {}

    local header = oneline(req.request.message, 200)
    if header == "" then
      header = "The agent needs input"
    end
    if #req.fields > 1 then
      header = ("%s  (%d/%d)"):format(header, req.index, #req.fields)
    end
    lines[#lines + 1] = "❓ " .. header
    if depth > 1 then
      lines[#lines + 1] = ("  (%d more waiting)"):format(depth - 1)
    end

    -- A field's own title/description only add value when they aren't already
    -- the header (single-field forms carry the question in `message`).
    local label = field.title or field.description
    if label and #req.fields > 1 then
      lines[#lines + 1] = "  " .. oneline(label, 200)
    end

    local selected = req.answers[field.key]
    for _, opt in ipairs(field.options or {}) do
      local marker
      if field.kind == "multi_select" then
        marker = vim.tbl_contains(type(selected) == "table" and selected or {}, opt.value) and "✓" or "▸"
      else
        marker = selected == opt.value and "✓" or "▸"
      end
      local line = "  " .. marker .. " " .. oneline(opt.label, 60)
      if opt.description and not req.expanded then
        line = line .. "  " .. oneline(opt.description, 48)
      end
      lines[#lines + 1] = line
      rows[#lines] = { kind = "option", value = opt.value }
      -- Expanded: full description and any provider-supplied preview body.
      if req.expanded then
        for _, extra in ipairs({ opt.description, opt.preview }) do
          for _, l in ipairs(vim.split(extra or "", "\n", { plain = true })) do
            if l ~= "" then
              lines[#lines + 1] = "      " .. l
            end
          end
        end
      end
    end

    -- While armed, the row says where the answer is going; the agent is blocked
    -- and the input box looks no different from a normal prompt otherwise.
    local claimed = req.awaiting_input and "  ✎ answer in the input box below, then submit" or nil
    if field.kind == "text" or field.kind == "number" then
      lines[#lines + 1] = claimed or "  ▸ type an answer…"
      rows[#lines] = { kind = "input" }
    elseif field.custom_key then
      -- Provider hook folded a free-text companion into this field.
      lines[#lines + 1] = claimed or "  ▸ type your own…"
      rows[#lines] = { kind = "input", key = field.custom_key }
    end
    if field.kind == "boolean" then
      for _, v in ipairs({ true, false }) do
        lines[#lines + 1] = "  " .. (selected == v and "✓" or "▸") .. " " .. (v and "yes" or "no")
        rows[#lines] = { kind = "bool", value = v }
      end
    end
    if field.kind == "multi_select" then
      lines[#lines + 1] = "  ⏎ submit"
      rows[#lines] = { kind = "submit" }
    end
    lines[#lines + 1] = "  ✗ skip"
    rows[#lines] = { kind = "skip" }
    lines[#lines + 1] = "  _cursor to a line and press <CR>; K expands_"

    return lines, rows
  end

  ---Collapse an answered prompt into a one-line-per-answer record. Leaving the
  ---live prompt in place would keep offering "skip" and "press <CR>" on a
  ---question that is already closed.
  ---@param req acp.PendingElicitation
  ---@param response acp.CreateElicitationResponse
  ---@return string
  local function elicitation_summary(req, response)
    if response.action ~= "accept" then
      local why = response.action == "cancel" and "cancelled" or "skipped"
      return "❓ " .. oneline(req.request.message, 120) .. "  — " .. why
    end
    local lines = { "❓ " .. oneline(req.request.message, 120) }
    for _, field in ipairs(req.fields) do
      local answer = req.answers[field.custom_key] or req.answers[field.key]
      if answer ~= nil then
        if type(answer) == "table" then
          answer = table.concat(answer, ", ")
        elseif type(answer) == "boolean" then
          answer = answer and "yes" or "no"
        end
        -- Show the option's label rather than its wire value when they differ.
        for _, opt in ipairs(field.options or {}) do
          if opt.value == answer then
            answer = opt.label
            break
          end
        end
        local prefix = #req.fields > 1 and (oneline(field.title or field.key, 40) .. ": ") or ""
        lines[#lines + 1] = "  ✓ " .. prefix .. oneline(tostring(answer), 120)
      end
    end
    return table.concat(lines, "\n")
  end

  ---Accept if we have everything required, otherwise decline — an accept
  ---carrying blanks would look like a real answer to the agent.
  local function submit_elicitation(req)
    local Elicit = require("emeth.acp.elicitation")
    if not Elicit.is_complete(req.fields, req.answers) then
      elicitations:close({ action = "decline" })
      return
    end
    elicitations:close({ action = "accept", content = Elicit.to_content(req.fields, req.answers) })
  end

  ---Move to the next unanswered field, or submit when the form is done.
  local function advance_elicitation(req)
    req.index = req.index + 1
    -- Fields we can't render contribute nothing to the response; skip them
    -- rather than showing an empty prompt the user can't act on.
    while req.fields[req.index] and req.fields[req.index].kind == "unsupported" do
      req.index = req.index + 1
    end
    if not req.fields[req.index] then
      submit_elicitation(req)
      return
    end
    req.expanded = false
    elicitations:refresh()
  end

  ---Act on the row under the cursor.
  local function on_elicitation_cr()
    local req = elicitations:head()
    if not req then
      return
    end
    local msg, offset = view:cursor_message_line()
    if not msg or msg.uuid ~= req.prompt_uuid or not offset then
      return
    end
    local action = req.rows[offset]
    if not action then
      return
    end
    local field = req.fields[req.index]

    -- Picking anything else abandons a pending free-text answer — this is also
    -- the way out of it, since an empty submission never reaches on_submit.
    if action.kind ~= "input" and req.awaiting_input then
      req.awaiting_input = nil
      input_capture = nil
    end

    if action.kind == "skip" then
      -- Skipping any field abandons the whole form: the agent reads `decline`
      -- as "the user chose not to answer", which is exactly what happened.
      elicitations:close({ action = "decline" })
    elseif action.kind == "submit" then
      advance_elicitation(req)
    elseif action.kind == "bool" then
      req.answers[field.key] = action.value
      advance_elicitation(req)
    elseif action.kind == "option" then
      if field.kind == "multi_select" then
        local list = type(req.answers[field.key]) == "table" and req.answers[field.key] or {}
        local at = nil
        for i, v in ipairs(list) do
          if v == action.value then
            at = i
            break
          end
        end
        if at then
          table.remove(list, at)
        else
          list[#list + 1] = action.value
        end
        req.answers[field.key] = list
        elicitations:refresh()
      else
        req.answers[field.key] = action.value
        advance_elicitation(req)
      end
    elseif action.kind == "input" then
      -- Answer in the sidebar input box rather than a modal prompt: the user
      -- gets real editing (multiline, paste folding, their own keymaps), and
      -- focus moves only because they asked for it by pressing <CR> here.
      local key = action.key or field.key
      req.awaiting_input = key
      input_capture = function(text)
        req.awaiting_input = nil
        if text and text ~= "" then
          req.answers[key] = text
          advance_elicitation(req)
        else
          elicitations:refresh()
        end
      end
      elicitations:refresh()
      view:focus_input()
    end
  end

  elicitations = PromptQueue.new(view, {
    owner = "elicitation",
    render = function(req, q)
      local lines, rows = elicitation_lines(req, q:depth())
      req.rows = rows
      return lines
    end,
    claims = function()
      return { ["<CR>"] = on_elicitation_cr }
    end,
    close = elicitation_summary,
    on_expand = function(req, q)
      req.expanded = not req.expanded
      -- Inline: the view repaints the message itself right after this returns.
      q:refresh(true)
    end,
    on_detach = function(req)
      -- Never leave the input box hijacked: an armed capture would swallow the
      -- user's next real prompt.
      if req.awaiting_input then
        req.awaiting_input = nil
        input_capture = nil
      end
    end,
    on_change = function(q)
      if q:depth() > 0 then
        Winbar.set_badge("ask", "❓ input needed")
      else
        Winbar.clear_badge("ask")
      end
    end,
  })

  session:on("elicitation", function(request, callback)
    vim.schedule(function()
      local fields = require("emeth.acp.elicitation").parse(request.requestedSchema)
      local transform_elicitation_fn = ctx.get_transform_elicitation()
      if transform_elicitation_fn then
        local ok, replaced = pcall(transform_elicitation_fn, fields, request)
        if ok and type(replaced) == "table" then
          fields = replaced
        end
      end
      -- Nothing renderable (empty or wholly unsupported schema): decline
      -- immediately rather than showing a prompt with no answerable lines.
      local renderable = false
      for _, f in ipairs(fields) do
        if f.kind ~= "unsupported" then
          renderable = true
          break
        end
      end
      if not renderable then
        callback({ action = "decline" })
        return
      end

      local req = {
        request = request,
        callback = callback,
        fields = fields,
        answers = {},
        index = 1,
        expanded = false,
        rows = {},
      }
      while req.fields[req.index] and req.fields[req.index].kind == "unsupported" do
        req.index = req.index + 1
      end

      elicitations:push(req)
      -- The transcript prompt and the winbar badge are both invisible when the
      -- sidebar is closed, and the agent stays blocked until it's answered — so
      -- that case needs an out-of-band nudge.
      if not view:is_visible() then
        vim.notify("emeth: the agent is asking for input (:Emeth to answer)", vim.log.levels.INFO)
      end
    end)
  end)

  return {
    take_submit = function(text)
      if not input_capture then
        return false
      end
      local capture = input_capture
      input_capture = nil
      capture(text)
      return true
    end,
    cancel = function()
      elicitations:drain({ action = "cancel" })
    end,
  }
end

return M
