--- ChatView — owns result buffer + input buffer, manages messages and rendering.

local Line = require("emeth.ui.line")
local Render = require("emeth.ui.render")

local api = vim.api

---@class chat_ui.ChatView
---@field result_buf number
---@field input_buf number
---@field messages chat_ui.Message[]
---@field on_submit fun(text: string)|nil
---@field on_remove_file fun(index: number)|nil
---@field integration table|nil
---@field _config chat_ui.Config
---@field _ns_id number
---@field _ns_input number
---@field _scroll boolean
---@field _context_files string[]
---@field _session_title? string
local ChatView = {}
ChatView.__index = ChatView

---True if the user message has any expandable details to show on K.
---@param msg chat_ui.Message
---@return boolean
local function has_user_details(msg)
  local m = msg.metadata or {}
  return (m.selected_files and #m.selected_files > 0) or m.mode ~= nil or m.model ~= nil
end

---@param opts? { config: chat_ui.Config, on_submit?: fun(text: string) }
---@return chat_ui.ChatView
function ChatView:new(opts)
  opts = opts or {}
  local function get_or_create_buf(name)
    local existing = vim.fn.bufnr(name)
    if existing ~= -1 and api.nvim_buf_is_valid(existing) then
      return existing
    end
    local buf = api.nvim_create_buf(false, true)
    api.nvim_set_option_value("buftype", "nofile", { buf = buf })
    api.nvim_set_option_value("swapfile", false, { buf = buf })
    api.nvim_buf_set_name(buf, name)
    return buf
  end

  local result_buf = get_or_create_buf("emeth://result")
  api.nvim_set_option_value("modifiable", false, { buf = result_buf })

  local input_buf = get_or_create_buf("emeth://input")

  local view = setmetatable({
    result_buf = result_buf,
    input_buf = input_buf,
    messages = {},
    on_submit = opts.on_submit,
    on_remove_file = nil,
    integration = nil,
    _config = opts.config,
    _ns_id = api.nvim_create_namespace("emeth_render"),
    _ns_input = api.nvim_create_namespace("emeth_input_ctx"),
    _scroll = true,
    _context_files = {},
    _line_to_msg = {},
    _line_cache = {}, -- uuid → { lines = Line[], text = string[] }
    _dirty_from = nil, -- index of first dirty message
  }, ChatView)

  -- Toggle tool purpose detail on K
  local function invalidate_msg(msg)
    view._line_cache[msg.uuid] = nil
    for i, m in ipairs(view.messages) do
      if m == msg then
        view._dirty_from = i
        break
      end
    end
    view._scroll = false
    view:_render()
    view._scroll = true
  end

  api.nvim_buf_set_keymap(result_buf, "n", "K", "", {
    noremap = true,
    silent = true,
    callback = function()
      local row = api.nvim_win_get_cursor(0)[1]
      local msg = view._line_to_msg[row]
      if not msg then
        return
      end

      if msg.role == "user" and has_user_details(msg) then
        msg._show_details = not msg._show_details
        invalidate_msg(msg)
        return
      end

      if msg.content then
        for _, item in ipairs(msg.content) do
          if item.type == "tool_use" then
            msg.metadata._expanded = not msg.metadata._expanded
            invalidate_msg(msg)
            return
          end
        end
      end
    end,
  })

  -- Retry: resend the user prompt under cursor
  api.nvim_buf_set_keymap(result_buf, "n", "r", "", {
    noremap = true,
    silent = true,
    callback = function()
      local row = api.nvim_win_get_cursor(0)[1]
      local msg = view._line_to_msg[row]
      if msg and msg.role == "user" and view.on_submit then
        local text = msg:text()
        if text ~= "" then
          view.on_submit(text)
          vim.schedule(function()
            local lc = api.nvim_buf_line_count(result_buf)
            pcall(api.nvim_win_set_cursor, 0, { lc, 0 })
          end)
        end
      end
    end,
  })

  -- Edit: put user prompt back in input buffer for modification
  api.nvim_buf_set_keymap(result_buf, "n", "e", "", {
    noremap = true,
    silent = true,
    callback = function()
      local row = api.nvim_win_get_cursor(0)[1]
      local msg = view._line_to_msg[row]
      if msg and msg.role == "user" then
        api.nvim_buf_set_lines(view.input_buf, 0, -1, false, vim.split(msg:text(), "\n"))
        for _, win in ipairs(api.nvim_list_wins()) do
          if api.nvim_win_is_valid(win) and api.nvim_win_get_buf(win) == view.input_buf then
            api.nvim_set_current_win(win)
            vim.cmd("startinsert!")
            return
          end
        end
      end
    end,
  })

  -- Contextual help: show available keybinds as virtual text on the
  -- message's "primary" line — the line where the user actually looks. For
  -- user messages that's the first content line (`> text`); for everything
  -- else it's the first row of the message.
  local help_ns = api.nvim_create_namespace("emeth_help_hints")

  ---@param msg chat_ui.Message
  ---@param cursor_row number  1-based buffer row currently under the cursor
  ---@return number  1-based buffer row to anchor the hint on
  local function primary_row_for(msg, cursor_row)
    -- Walk back to the message's first row.
    local first = cursor_row
    while first > 1 and view._line_to_msg[first - 1] == msg do
      first = first - 1
    end
    -- Walk forward to the message's last row.
    local last = cursor_row
    local total = api.nvim_buf_line_count(result_buf)
    while last < total and view._line_to_msg[last + 1] == msg do
      last = last + 1
    end
    -- For user messages, prefer the first `> ` content line.
    if msg.role == "user" then
      for r = first, last do
        local line = api.nvim_buf_get_lines(result_buf, r - 1, r, false)[1] or ""
        if line:sub(1, 2) == "> " then
          return r
        end
      end
    end
    return first
  end

  local last_anchor_row = nil
  api.nvim_create_autocmd("CursorMoved", {
    buffer = result_buf,
    callback = function()
      local row = api.nvim_win_get_cursor(0)[1]
      local msg = view._line_to_msg[row]
      local anchor_row = msg and primary_row_for(msg, row) or nil
      if anchor_row == last_anchor_row then
        return
      end
      last_anchor_row = anchor_row
      api.nvim_buf_clear_namespace(result_buf, help_ns, 0, -1)
      if not msg then
        return
      end
      local hints = {}
      if msg.role == "user" then
        hints[#hints + 1] = "r: retry"
        hints[#hints + 1] = "e: edit"
        if has_user_details(msg) then
          hints[#hints + 1] = "K: " .. (msg._show_details and "hide" or "show") .. " details"
        end
      end
      if msg.content then
        for _, item in ipairs(msg.content) do
          if item.type == "tool_use" then
            hints[#hints + 1] = "K: " .. (msg.metadata._expanded and "collapse" or "expand")
            break
          end
        end
      end
      if #hints > 0 and anchor_row then
        api.nvim_buf_set_extmark(result_buf, help_ns, anchor_row - 1, 0, {
          virt_text = { { "  [" .. table.concat(hints, ", ") .. "]", "Comment" } },
          virt_text_pos = "eol",
        })
      end
    end,
  })

  view:_setup_input()
  return view
end

---@param msg chat_ui.Message
function ChatView:add_message(msg)
  self.messages[#self.messages + 1] = msg
  local idx = #self.messages
  self._dirty_from = self._dirty_from and math.min(self._dirty_from, idx) or idx
  self:_schedule_render()
end

---@param uuid string
---@param msg_or_fn chat_ui.Message|fun(msg: chat_ui.Message)
function ChatView:update_message(uuid, msg_or_fn)
  for i, m in ipairs(self.messages) do
    if m.uuid == uuid then
      if type(msg_or_fn) == "function" then
        msg_or_fn(m)
      else
        self.messages[i] = msg_or_fn
      end
      self._line_cache[uuid] = nil
      self._dirty_from = self._dirty_from and math.min(self._dirty_from, i) or i
      self:_schedule_render()
      return
    end
  end
end

function ChatView:clear()
  self.messages = {}
  self._line_cache = {}
  self._dirty_from = nil
  self:_render()
end

function ChatView:invalidate()
  self._line_cache = {}
  self._dirty_from = 1
  self:_schedule_render()
end

---@return chat_ui.Message[]
function ChatView:get_messages()
  return self.messages
end

function ChatView:get_message(uuid)
  for _, msg in ipairs(self.messages) do
    if msg.uuid == uuid then
      return msg
    end
  end
end

function ChatView:_schedule_render()
  if self._render_pending then
    return
  end
  self._render_pending = true
  vim.schedule(function()
    self._render_pending = false
    self:_render()
  end)
end

function ChatView:_render()
  local buf = self.result_buf
  if not api.nvim_buf_is_valid(buf) then
    return
  end

  local dirty_from = self._dirty_from or 1
  self._dirty_from = nil

  -- Expand raw rendered lines (split embedded \n) into final lines
  local function expand(raw_lines)
    local out = {}
    for _, line in ipairs(raw_lines) do
      local has_nl = false
      for _, s in ipairs(line.sections) do
        if s[1]:find("\n", 1, true) then
          has_nl = true
          break
        end
      end
      if not has_nl then
        out[#out + 1] = line
      else
        local rows = { {} }
        for _, s in ipairs(line.sections) do
          local parts = vim.split(s[1], "\n", { plain = true })
          for pi, part in ipairs(parts) do
            if pi > 1 then
              rows[#rows + 1] = {}
            end
            rows[#rows][#rows[#rows] + 1] = { part, s[2] }
          end
        end
        for _, row in ipairs(rows) do
          out[#out + 1] = Line:new(row, line.line_hl)
        end
      end
    end
    return out
  end

  -- Build prefix from cache (messages before dirty_from)
  local prefix_lines = {}
  local prefix_text = {}
  self._line_to_msg = {}
  for i = 1, dirty_from - 1 do
    local msg = self.messages[i]
    if msg and msg.visible ~= false then
      local cached = self._line_cache[msg.uuid]
      if cached then
        local base = #prefix_lines
        vim.list_extend(prefix_lines, cached.lines)
        vim.list_extend(prefix_text, cached.text)
        for j = base + 1, #prefix_lines do
          self._line_to_msg[j] = msg
        end
      end
    end
  end

  -- Build tool_id → result lookup once for O(1) resolution
  local tool_results = {}
  for _, msg in ipairs(self.messages) do
    for _, item in ipairs(msg.content) do
      if item.type == "tool_result" and item.tool_use_id then
        tool_results[item.tool_use_id] = item
      end
    end
  end

  -- Render dirty messages
  local tail_lines = {}
  local tail_text = {}
  for i = dirty_from, #self.messages do
    local msg = self.messages[i]
    if msg and msg.visible ~= false then
      local raw = Render.render_message(msg, self.messages, tool_results)
      local expanded = expand(raw)
      local texts = {}
      for _, line in ipairs(expanded) do
        texts[#texts + 1] = tostring(line)
      end
      self._line_cache[msg.uuid] = { lines = expanded, text = texts }
      local base = #prefix_lines + #tail_lines
      vim.list_extend(tail_lines, expanded)
      vim.list_extend(tail_text, texts)
      for j = base + 1, #prefix_lines + #tail_lines do
        self._line_to_msg[j] = msg
      end
    end
  end

  -- Partial buffer update: only replace from prefix end onward
  local start_line = #prefix_text
  api.nvim_set_option_value("modifiable", true, { buf = buf })
  api.nvim_buf_set_lines(buf, start_line, -1, false, tail_text)
  api.nvim_set_option_value("modifiable", false, { buf = buf })

  -- Highlights: only on the changed region
  api.nvim_buf_clear_namespace(buf, self._ns_id, start_line, -1)
  for i, line in ipairs(tail_lines) do
    line:set_highlights(self._ns_id, buf, start_line + i - 1)
  end

  if self._scroll then
    vim.schedule(function()
      local cur_buf = api.nvim_get_current_buf()
      for _, win in ipairs(api.nvim_list_wins()) do
        if api.nvim_win_is_valid(win) and api.nvim_win_get_buf(win) == buf then
          if cur_buf ~= buf then
            local line_count = api.nvim_buf_line_count(buf)
            pcall(api.nvim_win_set_cursor, win, { line_count, 0 })
          end
        end
      end
    end)
  end
end

function ChatView:_setup_input()
  local Commands = require("emeth.commands")
  local config = self._config
  local buf = self.input_buf

  local function submit()
    if not api.nvim_buf_is_valid(buf) then
      return
    end
    local lines = api.nvim_buf_get_lines(buf, 0, -1, false)
    local text = vim.trim(table.concat(lines, "\n"))
    if text == "" then
      return
    end
    api.nvim_buf_set_lines(buf, 0, -1, false, {})
    self:set_context_files(self._context_files)

    local cmd_name, cmd_args = text:match("^/(%S+)%s*(.*)")
    if cmd_name then
      local cmd = Commands.get(cmd_name)
      if cmd then
        cmd.execute(cmd_args, { view = self, integration = self.integration })
        return
      end
    end

    if self.on_submit then
      self.on_submit(text)
    end
  end

  local insert_key = config.mappings.submit.insert
  if insert_key then
    api.nvim_buf_set_keymap(buf, "i", insert_key, "", {
      noremap = true,
      silent = true,
      callback = function()
        vim.cmd("stopinsert")
        submit()
      end,
    })
  end

  local normal_key = config.mappings.submit.normal
  if normal_key then
    api.nvim_buf_set_keymap(buf, "n", normal_key, "", {
      noremap = true,
      silent = true,
      callback = submit,
    })
  end

  ---@type table<string, { handler: fun(), desc: string }>
  self._mention_handlers = {}

  ---Build a markdown preview body for a command (used by the snacks-native
  ---picker on the side pane).
  ---@param name string command name (without leading /)
  ---@param cmd emeth.Command
  ---@return string
  local function command_preview_text(name, cmd)
    local lines = { "# /" .. name, "" }
    if cmd.desc and cmd.desc ~= "" then
      lines[#lines + 1] = cmd.desc
      lines[#lines + 1] = ""
    end
    if cmd.hint and cmd.hint ~= "" then
      lines[#lines + 1] = "**Args:** `" .. cmd.hint .. "`"
      lines[#lines + 1] = ""
    end
    if cmd.source then
      lines[#lines + 1] = "_source: " .. cmd.source .. "_"
    end
    return table.concat(lines, "\n")
  end

  ---Run the command picker. Uses snacks.picker.pick directly when available
  ---(two-pane layout with description preview); falls back to vim.ui.select.
  ---@param cmds { name: string, desc: string, source: string }[]
  ---@param on_pick fun(name: string)
  local function pick_command(cmds, on_pick)
    local has_snacks, SnacksPicker = pcall(require, "snacks.picker")
    if has_snacks then
      local items = {}
      for _, c in ipairs(cmds) do
        local cmd = Commands.get(c.name)
        items[#items + 1] = {
          text = "/" .. c.name,
          cmd = c.name,
          preview = cmd and { text = command_preview_text(c.name, cmd), ft = "markdown" } or nil,
        }
      end
      SnacksPicker.pick({
        source = "emeth_commands",
        title = "emeth commands",
        items = items,
        format = "text",
        preview = "preview",
        confirm = function(picker, item)
          picker:close()
          if item and item.cmd then
            on_pick(item.cmd)
          end
        end,
      })
      return
    end
    -- Fallback: vim.ui.select with name + truncated desc on one line
    vim.ui.select(cmds, {
      prompt = "/",
      format_item = function(c)
        return "/" .. c.name .. "  " .. c.desc
      end,
    }, function(choice)
      if choice then
        on_pick(choice.name)
      end
    end)
  end

  -- Intercept "/" before it enters the buffer so completion plugins
  -- never see it and don't trigger path completion over the command picker.
  api.nvim_create_autocmd("InsertCharPre", {
    buffer = buf,
    callback = function()
      if vim.v.char ~= "/" then
        return
      end
      local row = api.nvim_win_get_cursor(0)[1]
      if row ~= 1 then
        return
      end
      local line = api.nvim_buf_get_lines(buf, row - 1, row, false)[1] or ""
      if line ~= "" then
        return
      end
      local cmds = Commands.list()
      if #cmds == 0 then
        return
      end
      vim.v.char = ""
      vim.schedule(function()
        pick_command(cmds, function(name)
          local cmd = Commands.get(name)
          if not cmd then
            return
          end
          if cmd.has_picker or cmd.immediate then
            -- Provider-driven picker, or fire-and-forget: execute directly.
            api.nvim_buf_set_lines(buf, 0, -1, false, {})
            self:set_context_files(self._context_files)
            cmd.execute("", { view = self, integration = self.integration })
          else
            -- Default: pre-fill `/cmd ` (and the hint as a real-text
            -- placeholder if the command provides one). Description is
            -- visible in the picker's preview pane, so we don't render
            -- it in the input window.
            self:prefill_command(name, cmd.hint)
          end
        end)
      end)
    end,
  })

  api.nvim_create_autocmd("TextChangedI", {
    buffer = buf,
    callback = function()
      local row = api.nvim_win_get_cursor(0)[1]
      local line = api.nvim_buf_get_lines(buf, row - 1, row, false)[1] or ""

      if line == "@" or line:match("%s@$") then
        local triggers = vim.tbl_keys(self._mention_handlers)
        table.sort(triggers)
        if #triggers == 0 then
          return
        end
        local col = #line - 1
        api.nvim_buf_set_text(buf, row - 1, col, row - 1, #line, { "" })
        vim.schedule(function()
          vim.ui.select(triggers, {
            prompt = "@",
            format_item = function(t)
              local entry = self._mention_handlers[t]
              return entry.desc and (t .. "  " .. entry.desc) or t
            end,
          }, function(choice)
            if choice and self._mention_handlers[choice] then
              self._mention_handlers[choice].handler()
            end
          end)
        end)
      end
    end,
  })
end

---@param header_or_lines string[]
---@param body? string[]
function ChatView:append_fenced(header_or_lines, body)
  local header = body and header_or_lines or {}
  local lines = body or header_or_lines
  local buf = self.input_buf
  if not api.nvim_buf_is_valid(buf) then
    return
  end
  local existing = api.nvim_buf_get_lines(buf, 0, -1, false)
  local to_append = {}
  if #existing > 0 and existing[#existing] ~= "" then
    to_append[#to_append + 1] = ""
  end
  vim.list_extend(to_append, header)
  to_append[#to_append + 1] = "```"
  vim.list_extend(to_append, lines)
  to_append[#to_append + 1] = "```"
  to_append[#to_append + 1] = ""
  api.nvim_buf_set_lines(buf, -1, -1, false, to_append)
end

function ChatView:open_file_manager()
  if #self._context_files == 0 then
    vim.notify("[emeth] No context files", vim.log.levels.INFO)
    return
  end

  local width = 60
  local height = math.min(#self._context_files + 2, 20)
  local float_buf = api.nvim_create_buf(false, true)
  local win = api.nvim_open_win(float_buf, true, {
    relative = "editor",
    width = width,
    height = height,
    row = math.floor((vim.o.lines - height) / 2),
    col = math.floor((vim.o.columns - width) / 2),
    style = "minimal",
    border = "rounded",
    title = " Context Files (d: remove, q: close) ",
    title_pos = "center",
  })
  vim.cmd("stopinsert")

  local function refresh()
    local lines = {}
    for _, f in ipairs(self._context_files) do
      lines[#lines + 1] = "  @ " .. vim.fn.fnamemodify(f, ":~:.")
    end
    if #lines == 0 then
      if api.nvim_win_is_valid(win) then
        api.nvim_win_close(win, true)
      end
      return
    end
    api.nvim_set_option_value("modifiable", true, { buf = float_buf })
    api.nvim_buf_set_lines(float_buf, 0, -1, false, lines)
    api.nvim_set_option_value("modifiable", false, { buf = float_buf })
  end

  refresh()
  api.nvim_set_option_value("modifiable", false, { buf = float_buf })
  api.nvim_set_option_value("buftype", "nofile", { buf = float_buf })
  api.nvim_set_option_value("cursorline", true, { win = win })

  local function remove_under_cursor()
    local row = api.nvim_win_get_cursor(win)[1]
    if row > 0 and row <= #self._context_files and self.on_remove_file then
      self.on_remove_file(row)
      refresh()
    end
  end

  local function close()
    if api.nvim_win_is_valid(win) then
      api.nvim_win_close(win, true)
    end
  end

  for _, key in ipairs({ "d", "x", "<C-x>" }) do
    api.nvim_buf_set_keymap(float_buf, "n", key, "", { noremap = true, silent = true, callback = remove_under_cursor })
  end
  for _, key in ipairs({ "q", "<Esc>" }) do
    api.nvim_buf_set_keymap(float_buf, "n", key, "", { noremap = true, silent = true, callback = close })
  end
end

---Pre-fill the input buffer with `/<name> ` (and the hint as a real-text
---placeholder if provided) and focus the input window in insert mode.
---When a hint is present, the cursor is placed at the start of the hint so
---a visual-mode select-replace is one keystroke away (`v$c`) — but the user
---can also just keep typing to append, or hit backspace to clear and replace.
---
---The mode switch is deferred via `vim.schedule` so it survives the picker
---plugin's close-time focus shuffling.
---@param name string command name without leading slash
---@param hint? string argument hint (e.g. "<model_id>"); inserted as real text
function ChatView:prefill_command(name, hint)
  local buf = self.input_buf
  if not api.nvim_buf_is_valid(buf) then
    return
  end

  local prefix = "/" .. name .. " "
  local has_hint = hint and hint ~= ""
  local line = has_hint and (prefix .. hint) or prefix
  api.nvim_buf_set_lines(buf, 0, -1, false, { line })
  self:set_context_files(self._context_files)

  local cursor_col = #prefix
  if not has_hint then
    cursor_col = #prefix
  end

  -- Defer focus + cursor + insert-mode entry to next tick. Picker plugins
  -- (snacks, telescope, etc.) close their UI synchronously on confirm and
  -- can leave focus or mode in unexpected states; scheduling lets that
  -- settle before we apply our intent.
  vim.schedule(function()
    if not api.nvim_buf_is_valid(buf) then
      return
    end
    for _, win in ipairs(api.nvim_list_wins()) do
      if api.nvim_win_is_valid(win) and api.nvim_win_get_buf(win) == buf then
        api.nvim_set_current_win(win)
        break
      end
    end
    pcall(api.nvim_win_set_cursor, 0, { 1, cursor_col })
    vim.cmd("startinsert")
  end)
end

---@param files string[]
function ChatView:set_context_files(files)
  self._context_files = files
end

return ChatView
