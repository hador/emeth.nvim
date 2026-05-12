--- Message renderer — pure function: messages[] → Line[]

local Line = require("emeth.ui.line")
local HL = require("emeth.ui.highlights")

local M = {}

local _preferred_keys = { "command", "pattern", "query", "path", "file_path", "url", "regex", "search", "glob" }

--- Extract __tool_use_purpose from a tool_use content item.
---@param item table tool_use content item
---@param msg chat_ui.Message
---@return string|nil
function M.get_tool_purpose(item, msg)
  local tc = msg.metadata and msg.metadata.tool_call
  return (item.input and item.input.__tool_use_purpose) or (tc and tc.rawInput and tc.rawInput.__tool_use_purpose)
end

local function get_icons()
  return require("emeth").config.icons
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
  -- Use a fence longer than any backtick run in the content
  local max_ticks = 2
  for _, s in ipairs({ old_str, new_str }) do
    for run in s:gmatch("`+") do
      if #run > max_ticks then
        max_ticks = #run
      end
    end
  end
  local ticks = string.rep("`", max_ticks + 1)
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

---Resolve tool display name and parameter string.
---@return string name, string|nil param
local function tool_display(item, msg)
  local name = item.name or "unknown"
  local tc = msg.metadata.tool_call
  if tc and tc.title and tc.title ~= "" and tc.title ~= name then
    local title = tc.title:gsub("\n", " ")
    local param = best_str_param(item.input) or (tc and best_str_param(tc.rawInput))
    param = param and param:gsub("\n", " ") or nil
    if param and title:find(param, 1, true) then
      param = nil
    end
    return title, param
  end
  local param = best_str_param(item.input) or (tc and best_str_param(tc.rawInput))
  param = param and param:gsub("\n", " ") or nil
  if param and name:find(param, 1, true) then
    param = nil
  end
  return name, param
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

---@param item chat_ui.ContentItem
---@param msg chat_ui.Message
---@param messages chat_ui.Message[]
---@param tool_results? table<string, chat_ui.ContentItem>
---@return chat_ui.Line[]
local function render_tool_use(item, msg, messages, tool_results)
  local result = tool_results and tool_results[item.id] or find_tool_result(item.id, messages)
  local status_icon, status_hl = tool_status(item, result)
  local tool_name, tool_param = tool_display(item, msg)
  local tc = msg.metadata.tool_call
  local purpose = M.get_tool_purpose(item, msg)
  local lines = {}

  if has_diff_content(item, tc) then
    -- ── Heavy box style for diffs ──
    local header_parts = {
      { "┏━ " },
      { status_icon .. " ", status_hl },
      { tool_name },
    }
    if tool_param then
      header_parts[#header_parts + 1] = { ": " }
      header_parts[#header_parts + 1] = { tool_param, HL.TOOL_PARAM }
    end
    lines[#lines + 1] = Line:new(header_parts)

    if msg.metadata._show_purpose and purpose then
      lines[#lines + 1] = Line:new({ { purpose:gsub("\n", " "), HL.MUTED } })
    end

    vim.list_extend(lines, collect_diffs(item, tc))
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
    -- Collapse non-diff tool bodies by default (K to expand).
    if not msg.metadata._expanded then
      header[1] = { "── " }
      lines[#lines + 1] = Line:new(header)
      return lines
    end

    lines[#lines + 1] = Line:new(header)

    local decoration = "│   "

    if msg.metadata._show_purpose and purpose then
      lines[#lines + 1] = Line:new({ { decoration }, { purpose:gsub("\n", " "), HL.MUTED } })
    end

    if tc and tc.content then
      for _, c in ipairs(tc.content) do
        if c.type == "content" and c.content and c.content.text then
          vim.list_extend(lines, text_to_lines(c.content.text, decoration))
        end
      end
    end

    if result and result.content then
      local rc = result.content
      if type(rc) == "string" then
        vim.list_extend(lines, text_to_lines(rc, decoration))
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
