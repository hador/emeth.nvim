--- Message renderer — pure function: messages[] → Line[]

local Line = require("emeth.ui.line")
local HL = require("emeth.ui.highlights")

local M = {}

local _preferred_keys = { "command", "pattern", "query", "path", "file_path", "url", "regex", "search", "glob" }

--- The model's own one-line summary of what a tool call is for, if it sent one.
---
--- `description` is what makes a header readable: an agent hands us the entire
--- command as a tool's title, but writes a short summary of its intent alongside
--- it ("Locate SignalPresentationAction class file"). Measured across real
--- sessions it is present on ~90% of long commands, always single-line, and never
--- over 100 characters — so it needs no clamping and beats any truncation of the
--- command itself.
---
--- Read from `rawInput`, which is the tool's own declared input, rather than from
--- a provider's `_meta`: the two carry identical text wherever both appear, and
--- `rawInput.description` covers strictly more cases. That keeps this file free of
--- provider-specific knowledge.
---@param item table tool_use content item
---@param msg chat_ui.Message
---@return string|nil
function M.get_tool_purpose(item, msg)
  local tc = msg.metadata and msg.metadata.tool_call
  local raw = tc and tc.rawInput
  local function pick(t)
    if type(t) ~= "table" then
      return nil
    end
    local v = t.__tool_use_purpose or t.description
    return (type(v) == "string" and v ~= "" and v:find("\n") == nil) and v or nil
  end
  return pick(item.input) or pick(raw)
end

local function get_icons()
  return require("emeth").config.icons
end

--- Fallbacks so the renderer stays usable without a configured `emeth` (tests
--- stub the module with icons only).
local LIMITS = {
  tool_header_max_chars = 100,
  diff_collapse_lines = 30,
}

---@return { tool_header_max_chars: integer, diff_collapse_lines: integer }
local function get_limits()
  local ok, emeth = pcall(require, "emeth")
  local cfg = ok and emeth.config or {}
  return {
    tool_header_max_chars = cfg.tool_header_max_chars or LIMITS.tool_header_max_chars,
    diff_collapse_lines = cfg.diff_collapse_lines or LIMITS.diff_collapse_lines,
  }
end

---@param text string
---@param decoration? string
---@return chat_ui.Line[]
local function text_to_lines(text, decoration)
  local result = {}
  for _, l in ipairs(vim.split(text, "\n")) do
    l = l:gsub("\27%[[%d;]*m", "")
    if decoration then
      result[#result + 1] = Line:new({ { decoration }, { l } })
    else
      result[#result + 1] = Line:new({ { l } })
    end
  end
  return result
end

---A fence longer than any backtick run in the content it has to wrap, so content
---containing its own fences can't close ours early.
---@param texts string[]
---@return string
local function fence_ticks(texts)
  local max_ticks = 2
  for _, s in ipairs(texts) do
    for run in s:gmatch("`+") do
      if #run > max_ticks then
        max_ticks = #run
      end
    end
  end
  return string.rep("`", max_ticks + 1)
end

---Wrap text in a fenced block at column 0.
---
---Column 0 matters: the transcript runs markdown treesitter, and a fence only
---opens after at most three spaces of indent. A decorated body (`│   `) can never
---be highlighted, which is why tool output used to render as literal backticks
---while diffs came out highlighted — the diff box already emits undecorated.
---@param text string
---@param lang string  fence language, "" for none
---@return chat_ui.Line[]
local function fenced_lines(text, lang)
  local ticks = fence_ticks({ text })
  local lines = { Line:new({ { ticks .. lang } }) }
  vim.list_extend(lines, text_to_lines(text))
  lines[#lines + 1] = Line:new({ { ticks } })
  return lines
end

---@param old_str string
---@param new_str string
---@param path? string  optional filename to display on the fence line
---@return chat_ui.Line[]
local function diff_to_lines(old_str, new_str, path)
  old_str = type(old_str) == "string" and old_str or ""
  new_str = type(new_str) == "string" and new_str or ""
  local lines = {}
  local old_lines = vim.split(old_str, "\n")
  local new_lines = vim.split(new_str, "\n")
  ---@diagnostic disable-next-line: assign-type-mismatch, missing-fields
  local hunks = vim.diff(old_str, new_str, { algorithm = "histogram", result_type = "indices", ctxlen = 3 })
  if #hunks == 0 then
    return lines
  end
  local ticks = fence_ticks({ old_str, new_str })
  local fence = path and (ticks .. "diff " .. path) or (ticks .. "diff")
  lines[#lines + 1] = Line:new({ { fence } })
  local prev_end_a = 0
  for _, hunk in ipairs(hunks) do
    local start_a, count_a, start_b, count_b = unpack(hunk)
    local ctx_start = math.max(prev_end_a + 1, start_a - 3)
    if ctx_start > prev_end_a + 1 then
      lines[#lines + 1] = Line:new({ { "..." } })
    end
    for i = ctx_start, start_a - 1 do
      if old_lines[i] then
        lines[#lines + 1] = Line:new({ { "  " .. old_lines[i] } }, HL.DIFF_CONTEXT)
      end
    end
    for i = start_a, start_a + count_a - 1 do
      if old_lines[i] then
        lines[#lines + 1] = Line:new({ { "- " .. old_lines[i] } }, HL.DIFF_REMOVED)
      end
    end
    for i = start_b, start_b + count_b - 1 do
      if new_lines[i] then
        lines[#lines + 1] = Line:new({ { "+ " .. new_lines[i] } }, HL.DIFF_ADDED)
      end
    end
    prev_end_a = start_a + count_a - 1
  end
  lines[#lines + 1] = Line:new({ { ticks } })
  return lines
end

---@param tool_id string
---@param messages chat_ui.Message[]
---@return chat_ui.ContentItem|nil
local function find_tool_result(tool_id, messages)
  for i = #messages, 1, -1 do
    local msg = messages[i]
    for _, item in ipairs(msg.content) do
      if item.type == "tool_result" and item.tool_use_id == tool_id then
        return item
      end
    end
  end
  return nil
end

---@param item chat_ui.ContentItem
---@param result chat_ui.ContentItem|nil
---@return string icon, string hl_group
local function tool_status(item, result)
  local icons = get_icons()
  if not result then
    local s = item.status or "pending"
    if s == "completed" then
      return icons.tool_succeeded, HL.TOOL_SUCCEEDED
    elseif s == "failed" or s == "cancelled" then
      return icons.tool_failed, HL.TOOL_FAILED
    else
      return icons.tool_generating, HL.TOOL_CALLING
    end
  elseif result.is_error then
    return icons.tool_failed, HL.TOOL_FAILED
  end
  return icons.tool_succeeded, HL.TOOL_SUCCEEDED
end

---Extract the most descriptive string param from a table for display.
---@param tbl table|nil
---@return string|nil
local function best_str_param(tbl)
  if not tbl then
    return nil
  end
  for _, k in ipairs(_preferred_keys) do
    local v = tbl[k]
    if type(v) == "string" and #v > 0 then
      return v
    end
  end
  for _, v in pairs(tbl) do
    if type(v) == "string" and #v > 0 and #v < 200 then
      return v
    end
  end
  return nil
end

---Reduce a header string to something that fits on one row.
---
---A collapsed tool row is meant to read as a single line, but the sidebar wraps
---and Bash hands us the entire command as its `title` — an inline heredoc script
---turns one "collapsed" row into a hundred-plus screen rows. Keep the first
---physical line rather than flattening newlines into it, clamp that, and report
---how many lines were withheld so the row admits there's more behind `K`.
---@param s string
---@param max integer  characters, not bytes
---@return string text, integer hidden, boolean truncated  hidden counts lines
---dropped; `truncated` is also true when only characters were cut from line one
local function clamp_header(s, max)
  local first = s:match("^[^\n]*") or s
  local hidden = 0
  if #s > #first then
    local _, newlines = s:gsub("\n", "")
    -- A trailing newline withholds nothing.
    hidden = s:sub(-1) == "\n" and newlines - 1 or newlines
  end
  local truncated = hidden > 0
  -- Byte length bounds character length, so the cheap check gates the vim call.
  if #first > max and vim.fn.strchars(first) > max then
    first = vim.fn.strcharpart(first, 0, max) .. "…"
    truncated = true
  end
  return first, hidden, truncated
end

---Resolve what the header says and what the expanded body has to make good on.
---
---Preference order for the label is intent first: the model's own summary if it
---sent one, then the title, then the tool name. A summary supersedes the command
---entirely — it is shorter, it says what the call is *for*, and the command itself
---is then shown in full in the body rather than truncated in the header.
---
---`withheld` carries the *unclamped* source of anything the header isn't showing,
---so the expanded body can show it. Without it, clamping the header would put a
---long command permanently out of reach — the header was the only place it ever
---appeared (a tool's body is its output, not its invocation).
---@return string name, string|nil param, integer hidden, string[] withheld
local function tool_display(item, msg)
  local max = get_limits().tool_header_max_chars
  local name = item.name or "unknown"
  local tc = msg.metadata.tool_call
  local title = (tc and tc.title and tc.title ~= "" and tc.title ~= name) and tc.title or nil
  local summary = M.get_tool_purpose(item, msg)
  local label = summary or title or name
  local param = best_str_param(item.input) or (tc and best_str_param(tc.rawInput))
  -- Dedupe against the *unclamped* strings. The label frequently is the command
  -- verbatim, and comparing already-clamped forms would stop matching and print
  -- the same text twice.
  if param and label:find(param, 1, true) then
    param = nil
  end
  local withheld = {}
  -- With a summary in the header the invocation isn't up there at all, so the body
  -- owes the reader the whole thing. Prefer the title, which for an `execute` tool
  -- is the command verbatim; fall back to the param.
  if summary then
    local invocation = title or param
    if invocation then
      withheld[#withheld + 1] = invocation
      -- It lives in the body now; repeating a slice of it after the summary would
      -- just re-widen the row we set out to shrink.
      param = nil
    end
  end
  local full_label, full_param = label, param
  local hidden, cut
  label, hidden, cut = clamp_header(label, max)
  if cut then
    table.insert(withheld, 1, full_label)
  end
  if param then
    local param_hidden, param_cut
    param, param_hidden, param_cut = clamp_header(param, max)
    hidden = hidden + param_hidden
    if param_cut then
      withheld[#withheld + 1] = full_param
    end
  end
  return label, param, hidden, withheld
end

---Detect whether a tool call contains diff content.
---@return boolean
local function has_diff_content(item, tc)
  if item.input and item.input.old_str and item.input.new_str then
    return true
  end
  if tc and tc.rawInput and tc.rawInput.oldString and tc.rawInput.newString then
    return true
  end
  if tc and tc.content then
    for _, c in ipairs(tc.content) do
      if c.type == "diff" and c.oldText and c.newText then
        return true
      end
    end
  end
  return false
end

---Every file named on a fence line inside this tool's rendered diff. Content
---diffs carry their own `path`, which is where the fence label usually comes
---from — `rawInput.path` is often absent, so looking only there misses it.
---@return table<string, true>
local function diff_paths(item, tc)
  local paths = {}
  local p = (item.input and item.input.path) or (tc and tc.rawInput and tc.rawInput.path)
  if p then
    paths[p] = true
  end
  if tc and tc.content then
    for _, c in ipairs(tc.content) do
      if c.type == "diff" and c.path then
        paths[c.path] = true
      end
    end
  end
  return paths
end

---Collect all diff Line[] from a tool call's various input sources.
---@return chat_ui.Line[]
local function collect_diffs(item, tc)
  local lines = {}
  local path = (item.input and item.input.path) or (tc and tc.rawInput and tc.rawInput.path)
  if item.input and item.input.old_str and item.input.new_str then
    vim.list_extend(lines, diff_to_lines(item.input.old_str, item.input.new_str, path))
  elseif tc and tc.rawInput and tc.rawInput.oldString and tc.rawInput.newString then
    vim.list_extend(lines, diff_to_lines(tc.rawInput.oldString, tc.rawInput.newString, path))
  end
  if tc and tc.content then
    for _, c in ipairs(tc.content) do
      if c.type == "diff" and c.oldText and c.newText then
        vim.list_extend(lines, diff_to_lines(c.oldText, c.newText, c.path))
      end
    end
  end
  return lines
end

---Effective expand state for a tool call, resolving the default when the user
---hasn't toggled it.
---
---Diffs default to expanded while they're small — an `Edit` hunk is a few lines
---and worth reading inline — and to collapsed once they aren't. `Write` sends an
---empty `oldText`, so its entire file arrives as a single hunk; unfolded, that
---buries the conversation under hundreds of `+` lines. Everything else defaults
---to collapsed.
---@param item chat_ui.ContentItem
---@param msg chat_ui.Message
---@param diff_lines? chat_ui.Line[]  reuse the caller's, if it already has them
---@return boolean
local function expanded_for(item, msg, diff_lines)
  if msg.metadata._expanded ~= nil then
    return msg.metadata._expanded == true
  end
  local tc = msg.metadata.tool_call
  if not has_diff_content(item, tc) then
    return false
  end
  diff_lines = diff_lines or collect_diffs(item, tc)
  return #diff_lines <= get_limits().diff_collapse_lines
end

---The expand state `K` should toggle away from — the renderer owns the per-kind
---default, so the keymap can't just flip `_expanded` and assume it started false.
---@param msg chat_ui.Message
---@return boolean
function M.is_expanded(msg)
  for _, item in ipairs(msg.content or {}) do
    if item.type == "tool_use" then
      return expanded_for(item, msg)
    end
  end
  return msg.metadata._expanded == true
end

---@param item chat_ui.ContentItem
---@param msg chat_ui.Message
---@param messages chat_ui.Message[]
---@param tool_results? table<string, chat_ui.ContentItem>
---@return chat_ui.Line[]
local function render_tool_use(item, msg, messages, tool_results)
  local result = tool_results and tool_results[item.id] or find_tool_result(item.id, messages)
  local status_icon, status_hl = tool_status(item, result)
  local tool_name, tool_param, hidden, withheld = tool_display(item, msg)
  local tc = msg.metadata.tool_call
  local lines = {}

  ---How much this row is withholding, as a muted trailing section. One counter
  ---for both causes: whatever the reason, the answer is the same keypress.
  ---@param header table[]
  ---@param count integer
  local function add_hidden(header, count)
    if count > 0 then
      header[#header + 1] = {
        ("  +%d line%s"):format(count, count == 1 and "" or "s"),
        HL.MUTED,
      }
    end
  end

  ---Whatever the header had to cut, in full. This is what `K` is *for* on a tool
  ---whose invocation didn't fit — the body below is the tool's output, so without
  ---this the command would be unreachable at any expand state.
  ---@param skip? table<string, true>  text the body already shows by other means
  local function add_withheld(skip)
    for _, full in ipairs(withheld) do
      if not (skip and skip[full]) then
        vim.list_extend(lines, text_to_lines(full))
      end
    end
  end

  if has_diff_content(item, tc) then
    -- ── Heavy box style for diffs ──
    local diff_lines = collect_diffs(item, tc)
    local expanded = expanded_for(item, msg, diff_lines)
    -- The fence line names the file. Repeating it as the header's param says the
    -- same path twice on one row (the title usually already carries it, relative)
    -- and a third time on the fence.
    local paths = diff_paths(item, tc)
    if tool_param and paths[tool_param] then
      tool_param = nil
    end
    local header_parts = {
      { expanded and "┏━ " or "── " },
      { status_icon .. " ", status_hl },
      { tool_name },
    }
    if tool_param then
      header_parts[#header_parts + 1] = { ": " }
      header_parts[#header_parts + 1] = { tool_param, HL.TOOL_PARAM }
    end
    add_hidden(header_parts, hidden + (expanded and 0 or #diff_lines))
    lines[#lines + 1] = Line:new(header_parts)

    if not expanded then
      return lines
    end

    add_withheld(paths)
    vim.list_extend(lines, diff_lines)
    lines[#lines + 1] =
      Line:new({ { "┗━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" } })
  else
    -- ── Light box style for non-diff tool calls ──
    local header = {
      { "╭─ " },
      { status_icon .. " ", status_hl },
      { tool_name },
    }
    if tool_param then
      header[#header + 1] = { ": " }
      header[#header + 1] = { tool_param, HL.TOOL_PARAM }
    end
    -- A subagent's spawning tool stands in for everything it ran, so say how
    -- much is folded away under it — otherwise the row looks inert.
    local children = msg.metadata.subagent_children
    if type(children) == "number" and children > 0 then
      header[#header + 1] = {
        ("  ⊳ %d tool%s"):format(children, children == 1 and "" or "s"),
        HL.MUTED,
      }
    end
    -- Collapse non-diff tool bodies by default (K to expand).
    if not expanded_for(item, msg) then
      header[1] = { "── " }
      add_hidden(header, hidden)
      lines[#lines + 1] = Line:new(header)
      return lines
    end

    add_hidden(header, hidden)
    lines[#lines + 1] = Line:new(header)

    -- The invocation, above the output: you read what ran before what it printed.
    -- Fenced as shell for an `execute` tool (spec `kind`, so this stays provider
    -- agnostic) so it highlights as the code it is.
    local lang = (tc and tc.kind == "execute") and "bash" or ""
    for _, full in ipairs(withheld) do
      vim.list_extend(lines, fenced_lines(full, lang))
    end

    local outputs = {}
    if tc and tc.content then
      for _, c in ipairs(tc.content) do
        if c.type == "content" and c.content and c.content.text then
          outputs[#outputs + 1] = c.content.text
        end
      end
    end
    if result and type(result.content) == "string" then
      outputs[#outputs + 1] = result.content
    end

    if #outputs > 0 then
      -- Only worth a divider when there's something above it to divide from.
      if #lines > 1 then
        lines[#lines + 1] = Line:new({ { "├─ output", HL.MUTED } })
      end
      for _, text in ipairs(outputs) do
        -- Agents usually send output already fenced (```console …). Emit that
        -- verbatim: re-wrapping would nest fences and highlight neither. Anything
        -- unfenced is left as-is rather than force-fenced, since it's often
        -- markdown that's worth rendering as markdown.
        vim.list_extend(lines, text_to_lines(text))
      end
    end

    -- Single-line if no body content
    if #lines <= 1 then
      lines[1].sections[1][1] = "── "
      return lines
    end

    lines[#lines + 1] = Line:new({ { "╰─  " } })
  end

  return lines
end

---@param item chat_ui.ContentItem
---@return chat_ui.Line[]
local function render_thinking(item)
  local icons = get_icons()
  local text = item.thinking or ""
  local text_lines = vim.split(text, "\n")
  -- Trim empty prefix/suffix
  while #text_lines > 0 and text_lines[1] == "" do
    table.remove(text_lines, 1)
  end
  while #text_lines > 0 and text_lines[#text_lines] == "" do
    table.remove(text_lines)
  end

  local lines = {}
  lines[#lines + 1] = Line:new({ { icons.thinking .. "Thinking:", HL.THINKING } })
  lines[#lines + 1] = Line:new({ { "" } })
  for _, l in ipairs(text_lines) do
    lines[#lines + 1] = Line:new({ { "> " .. l, HL.THINKING } })
  end
  return lines
end

---@param msg chat_ui.Message
---@return chat_ui.Line[]
local function render_user_message(msg)
  local lines = {}
  -- Compact header: HH:MM · provider · N files
  local parts = { msg.timestamp:match("%d%d:%d%d") or msg.timestamp }
  -- A steered message cut into a turn that was already running, which is why it
  -- appears mid-stream between the agent's own output. Shown in the header rather
  -- than behind K: a marker explaining an oddity has to be visible unprompted.
  if msg.metadata.steered then
    parts[#parts + 1] = "⤳ steered"
  end
  local files = msg.metadata.selected_files or {}
  if #files > 0 then
    parts[#parts + 1] = #files .. (#files == 1 and " file" or " files")
  end
  for _, badge in ipairs(msg.metadata.badges or {}) do
    parts[#parts + 1] = badge
  end
  lines[#lines + 1] = Line:new({
    {
      "───────────────────────────────────────",
      HL.MUTED,
    },
  })
  lines[#lines + 1] = Line:new({ { table.concat(parts, " · ") .. " ", HL.USER } })

  -- Details (hidden by default, toggled with K)
  if msg._show_details then
    if msg.metadata.model then
      lines[#lines + 1] = Line:new({ { "  model: " .. msg.metadata.model, HL.MUTED } })
    end
    if msg.metadata.mode then
      lines[#lines + 1] = Line:new({ { "  mode:  " .. msg.metadata.mode, HL.MUTED } })
    end
    for _, f in ipairs(files) do
      local rel = vim.fn.fnamemodify(f, ":~:.")
      lines[#lines + 1] = Line:new({ { "  @ " .. rel, HL.MUTED } })
    end
  end

  -- Content
  local msg_text = msg:text()
  if msg_text ~= "" then
    for _, l in ipairs(vim.split(msg_text, "\n")) do
      lines[#lines + 1] = Line:new({ { "> " .. l, HL.USER } })
    end
  end
  lines[#lines + 1] = Line:new({ { "" } })
  return lines
end

---@param msg chat_ui.Message
---@param messages chat_ui.Message[]
---@param tool_results? table<string, chat_ui.ContentItem>
---@return chat_ui.Line[]
local function render_assistant_message(msg, messages, tool_results)
  local lines = {}
  for _, item in ipairs(msg.content) do
    if item.type == "text" then
      vim.list_extend(lines, text_to_lines(item.text or ""))
    elseif item.type == "thinking" then
      vim.list_extend(lines, render_thinking(item))
      lines[#lines + 1] = Line:new({ { "" } })
    elseif item.type == "tool_use" then
      vim.list_extend(lines, render_tool_use(item, msg, messages, tool_results))
      lines[#lines + 1] = Line:new({ { "" } })
    end
    -- tool_result is rendered as part of tool_use, skip
  end
  -- Indent a subagent's calls so an expanded parent reads as one nested block
  -- rather than as more top-level tool rows.
  if msg.metadata and msg.metadata.parent_tool_call_id then
    for _, line in ipairs(lines) do
      line:indent("  ")
    end
  end
  return lines
end

---@param msg chat_ui.Message
---@return chat_ui.Line[]
local function render_system_message(msg)
  local lines = {}
  local text = msg:text()
  for _, l in ipairs(vim.split(text, "\n")) do
    lines[#lines + 1] = Line:new({ { "  " .. l, HL.MUTED } })
  end
  return lines
end

--- Render a single message to Line[]
---@param msg chat_ui.Message
---@param messages chat_ui.Message[]
---@param tool_results? table<string, chat_ui.ContentItem>
---@return chat_ui.Line[]
function M.render_message(msg, messages, tool_results)
  if msg.role == "user" then
    return render_user_message(msg)
  elseif msg.role == "assistant" then
    return render_assistant_message(msg, messages, tool_results)
  elseif msg.role == "system" then
    return render_system_message(msg)
  end
  return {}
end

return M
