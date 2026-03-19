--- ACP integration glue — wires emeth_acp Session to a ChatView.

local Commands = require("emeth.commands")
local Message = require("emeth.message")
local Sessions = require("emeth.sessions")
local Winbar = require("emeth.ui.winbar")
local util = require("emeth.util")

local M = {}

---@param view chat_ui.ChatView
---@param session acp.Session
---@return table
function M.setup_integration(view, session)
  local current_assistant_uuid = nil
  local current_thinking_uuid = nil
  local tool_message_map = {} ---@type table<string, string>
  local selected_files = {} ---@type string[]
  local reload_timer = vim.uv.new_timer()
  local pending_reloads = {} ---@type table<string, number|true>  -- path → first_changed or true

  local function flush_reloads()
    local target_win = util.find_source_win()
    local first_path = nil
    for p, first_changed in pairs(pending_reloads) do
      local abs = vim.fn.fnamemodify(p, ":p")
      local buf = vim.fn.bufnr(abs)
      if buf ~= -1 and vim.api.nvim_buf_is_loaded(buf) then
        vim.bo[buf].modified = false
        vim.api.nvim_buf_call(buf, function()
          vim.cmd("checktime")
        end)
      end
      if not first_path then
        first_path = { abs = abs, line = type(first_changed) == "number" and first_changed or nil }
      end
    end
    if first_path and target_win then
      vim.api.nvim_win_call(target_win, function()
        vim.cmd("edit " .. vim.fn.fnameescape(first_path.abs))
      end)
      if first_path.line then
        vim.api.nvim_set_current_win(target_win)
        vim.schedule(function()
          if not vim.api.nvim_win_is_valid(target_win) then
            return
          end
          pcall(vim.api.nvim_win_set_cursor, target_win, { first_path.line, 0 })
          vim.cmd("normal! zz")
        end)
      end
    end
    pending_reloads = {}
  end

  local function schedule_reload(path, first_changed)
    pending_reloads[path] = first_changed or pending_reloads[path] or true
    if not reload_timer:is_active() then
      reload_timer:start(1000, 0, vim.schedule_wrap(flush_reloads))
    end
  end

  local function reset_state()
    current_assistant_uuid = nil
    current_thinking_uuid = nil
    tool_message_map = {}
  end

  local function refresh_file_display()
    view:set_context_files(selected_files)
  end

  -- ── Lifecycle wrapper ──────────────────────────────────────────

  ---Run a session lifecycle action with standard boilerplate.
  ---@param opts { clear?: boolean, save?: boolean, touch?: boolean }
  ---@param action fun(done: fun(err: any))
  ---@param cb? fun(err: any)
  local function with_lifecycle(opts, action, cb)
    if opts.clear then
      view:clear()
      reset_state()
    end
    local emeth = require("emeth")
    local sidebar = emeth.get_sidebar()
    if sidebar and sidebar.result_win then
      Winbar.attach(sidebar.result_win, sidebar.input_win)
      Winbar.set_left(Winbar.fmt.plain(session.provider_name))
    end
    Winbar.set_state("connecting")
    action(function(err)
      vim.schedule(function()
        Winbar.set_state("ready")
        view:invalidate()
        if err then
          view:add_message(Message:new("system", "Error: " .. util.fmt_err(err)))
        else
          if opts.save and session.session_id then
            Sessions.save({
              session_id = session.session_id,
              provider = session.provider_name,
              cwd = vim.fn.getcwd(),
            })
          end
          if opts.touch and session.session_id then
            Sessions.touch(session.session_id)
          end
        end
      end)
      if cb then
        cb(err)
      end
    end)
  end

  -- ── File context ───────────────────────────────────────────────

  view.on_remove_file = function(idx)
    table.remove(selected_files, idx)
    refresh_file_display()
  end

  local function add_file(path)
    path = vim.fn.fnamemodify(path, ":p")
    if not vim.tbl_contains(selected_files, path) then
      selected_files[#selected_files + 1] = path
      refresh_file_display()
    end
  end

  -- ── @mention handlers ──────────────────────────────────────────

  view._mention_handlers = {
    file = {
      desc = "Add a file from the project",
      handler = function()
        local cwd = vim.fn.getcwd()
        local files
        local git_out =
          vim.fn.systemlist({ "git", "-C", cwd, "ls-files", "--cached", "--others", "--exclude-standard" })
        if vim.v.shell_error == 0 and #git_out > 0 then
          files = git_out
        else
          files = vim.fn.glob(cwd .. "/**/*", false, true)
          files = vim.tbl_filter(function(f)
            return vim.fn.isdirectory(f) == 0
          end, files)
          for i, f in ipairs(files) do
            files[i] = vim.fn.fnamemodify(f, ":.")
          end
        end
        vim.ui.select(files, { prompt = "Add file to context:" }, function(choice)
          if choice then
            add_file(choice)
          end
        end)
      end,
    },
    buffers = {
      desc = "Add all open buffers",
      handler = function()
        local added = 0
        for _, buf in ipairs(vim.api.nvim_list_bufs()) do
          if vim.api.nvim_buf_is_loaded(buf) and vim.bo[buf].buflisted then
            local name = vim.api.nvim_buf_get_name(buf)
            if name ~= "" and vim.fn.filereadable(name) == 1 and not vim.tbl_contains(selected_files, name) then
              selected_files[#selected_files + 1] = name
              added = added + 1
            end
          end
        end
        refresh_file_display()
        vim.notify(("[emeth] Added %d buffer(s) to context"):format(added), vim.log.levels.INFO)
      end,
    },
    files = {
      desc = "Manage context files",
      handler = function()
        view:open_file_manager()
      end,
    },
    diagnostics = {
      desc = "LSP diagnostics from current buffer",
      handler = function()
        local win = util.find_source_win()
        if not win then
          vim.notify("[emeth] No source buffer found", vim.log.levels.WARN)
          return
        end
        local buf = vim.api.nvim_win_get_buf(win)
        local diags = vim.diagnostic.get(buf)
        if #diags == 0 then
          vim.notify("[emeth] No diagnostics", vim.log.levels.INFO)
          return
        end
        local fname = vim.fn.fnamemodify(vim.api.nvim_buf_get_name(buf), ":.")
        local header = { "Diagnostics for " .. fname .. ":" }
        local lines = {}
        local severity_map = { "ERROR", "WARN", "INFO", "HINT" }
        for _, d in ipairs(diags) do
          local sev = severity_map[d.severity] or "?"
          local msg = d.message:gsub("\n", " ")
          lines[#lines + 1] = ("[%s] line %d: %s"):format(sev, d.lnum + 1, msg)
        end
        view:append_fenced(header, lines)
      end,
    },
    prompts = {
      desc = "Use a prompt template",
      handler = function()
        local items = {}
        for _, dir in ipairs(view._config.prompt_dirs) do
          local expanded = vim.fn.expand(dir)
          for _, path in ipairs(vim.fn.glob(expanded .. "/*.md", false, true)) do
            local name = vim.fn.fnamemodify(path, ":t:r")
            local first = ""
            local f = io.open(path)
            if f then
              for line in f:lines() do
                if line:match("%S") then
                  first = line
                  break
                end
              end
              f:close()
            end
            items[#items + 1] = { name = name, path = path, first = first }
          end
        end
        if #items == 0 then
          vim.notify("[emeth] No prompts found", vim.log.levels.INFO)
          return
        end
        vim.ui.select(items, {
          prompt = "Prompt:",
          format_item = function(item)
            return item.name .. "  " .. item.first
          end,
        }, function(choice)
          if not choice then
            return
          end
          local content = table.concat(vim.fn.readfile(choice.path), "\n")
          vim.api.nvim_buf_set_lines(view.input_buf, 0, -1, false, vim.split(content, "\n"))
          vim.cmd("startinsert!")
        end)
      end,
    },
  }

  local function do_cancel()
    if session:get_state() ~= "prompting" then
      return
    end
    session:cancel()
    Winbar.set_state("ready")
    for _, msg in ipairs(view:get_messages()) do
      for _, item in ipairs(msg.content) do
        if item.type == "tool_use" and item.status and item.status ~= "completed" and item.status ~= "failed" then
          item.status = "cancelled"
        end
      end
    end
    view:add_message(Message:new("system", "⏹ Prompt cancelled"))
  end
  for _, b in ipairs({ view.result_buf, view.input_buf }) do
    vim.api.nvim_buf_set_keymap(b, "n", "<C-c>", "", { noremap = true, silent = true, callback = do_cancel })
    vim.api.nvim_buf_set_keymap(b, "i", "<C-c>", "", { noremap = true, silent = true, callback = do_cancel })
  end

  -- ── Submit ─────────────────────────────────────────────────────

  view.on_submit = function(text)
    if session:get_state() ~= "ready" then
      vim.notify("[emeth] Session not ready", vim.log.levels.WARN)
      vim.api.nvim_buf_set_lines(view.input_buf, 0, -1, false, vim.split(text, "\n"))
      view:set_context_files(view._context_files)
      return
    end

    local prompt = {}
    for _, fpath in ipairs(selected_files) do
      prompt[#prompt + 1] = {
        type = "resource_link",
        uri = "file://" .. fpath,
        name = vim.fn.fnamemodify(fpath, ":t"),
      }
    end
    prompt[#prompt + 1] = { type = "text", text = text }

    local msg = Message:new("user", text, {
      selected_files = vim.deepcopy(selected_files),
      provider = session.provider_name,
      model = session.extensions and session.extensions.model_id,
      agent = session.extensions and session.extensions.mode_id,
      badges = Winbar.get_badges(),
    })
    view:add_message(msg)
    reset_state()
    Winbar.set_state("generating")
    if session.session_id then
      Sessions.touch(session.session_id)
      local entry = Sessions.get(session.session_id)
      if entry and not entry.title then
        Sessions.update_title(session.session_id, text:sub(1, 80):gsub("\n", " "))
      end
    end
    session:send_prompt(prompt, function(_, err)
      vim.schedule(function()
        Winbar.set_state("ready")
        if err then
          view:add_message(Message:new("system", "Error: " .. util.fmt_err(err)))
        end
        view:invalidate()
      end)
    end)
  end

  -- ── Session events ─────────────────────────────────────────────

  session:on("update", function(update)
    -- Only flip to "generating" for streaming response updates, not metadata updates
    -- like available_commands_update or session_info_update.
    local metadata_updates = { available_commands_update = true, session_info_update = true }
    if not metadata_updates[update.sessionUpdate] then
      Winbar.set_state("generating")
    end

    if update.sessionUpdate == "user_message_chunk" then
      if update.content and update.content.type == "text" then
        view:add_message(Message:new("user", update.content.text))
      end
    elseif update.sessionUpdate == "agent_message_chunk" then
      if update.content and update.content.type == "text" then
        if current_assistant_uuid then
          view:update_message(current_assistant_uuid, function(msg)
            msg:append_text(update.content.text)
          end)
        else
          local msg = Message:new("assistant", update.content.text)
          current_assistant_uuid = msg.uuid
          current_thinking_uuid = nil
          view:add_message(msg)
        end
      end
    elseif update.sessionUpdate == "agent_thought_chunk" then
      if update.content and update.content.type == "text" then
        if current_thinking_uuid then
          view:update_message(current_thinking_uuid, function(msg)
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
          current_thinking_uuid = msg.uuid
          current_assistant_uuid = nil
          view:add_message(msg)
        end
      end
    elseif update.sessionUpdate == "tool_call" then
      current_assistant_uuid = nil
      current_thinking_uuid = nil
      local existing_uuid = tool_message_map[update.toolCallId]
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
        local msg = Message:new("assistant", {
          type = "tool_use",
          name = update.kind or update.title or "tool",
          id = update.toolCallId,
          input = update.rawInput or {},
          status = update.status or "pending",
        }, { tool_call = update })
        tool_message_map[update.toolCallId] = msg.uuid
        view:add_message(msg)
      end
    elseif update.sessionUpdate == "tool_call_update" then
      local uuid = tool_message_map[update.toolCallId]
      if uuid then
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
        end)
      end

      -- Debounced buffer reload for completed tool calls that wrote files
      if update.status == "completed" and uuid then
        local tc = (view:get_message(uuid) or {}).metadata
        tc = tc and tc.tool_call
        if tc and tc.content then
          local first_line = tc.locations and tc.locations[1] and tc.locations[1].line
          for _, c in ipairs(tc.content) do
            if c.type == "diff" and c.path then
              schedule_reload(c.path, first_line)
            end
          end
        end
      end
    elseif update.sessionUpdate == "plan" then
      local parts = { "**Plan:**" }
      for _, entry in ipairs(update.entries or {}) do
        local icon = entry.status == "completed" and "✓" or entry.status == "in_progress" and "→" or "○"
        parts[#parts + 1] = icon .. " " .. entry.content
      end
      view:add_message(Message:new("system", table.concat(parts, "\n")))
    elseif update.sessionUpdate == "available_commands_update" then
      Commands.clear_acp()
      for _, cmd in ipairs(update.availableCommands or {}) do
        local name = cmd.name:gsub("^/", "")
        Commands.register(name, {
          desc = cmd.description or name,
          source = "acp",
          execute = function(args, ctx)
            if ctx.view.on_submit then
              ctx.view.on_submit("/" .. name .. (args ~= "" and (" " .. args) or ""))
            end
          end,
        })
      end
    elseif update.sessionUpdate == "session_info_update" then
      if update.title then
        view._session_title = update.title
        if session.session_id then
          Sessions.update_title(session.session_id, update.title)
        end
      end
    end
  end)

  session:on("error", function(err)
    view:add_message(Message:new("assistant", "**Error:** " .. util.fmt_err(err)))
  end)

  session:on("file_written", function(path, first_changed)
    schedule_reload(path, first_changed)
  end)

  -- Load provider-specific extensions (e.g. kiro-cli)
  local provider_mod = "emeth.integrations." .. session.provider_name
  local has_ext, ext = pcall(require, provider_mod)
  local ext_cleanup
  if has_ext and ext.setup then
    ext_cleanup = ext.setup(session, view)
  end

  -- ── Public API ─────────────────────────────────────────────────

  local integration = {
    connect = function(cb)
      with_lifecycle({ save = true }, function(done)
        session:connect(function(err)
          if not err then
            vim.schedule(function()
              view:add_message(
                Message:new(
                  "system",
                  "Connected to " .. session.provider_name .. ".  Session: " .. (session.session_id or "?")
                )
              )
            end)
          end
          done(err)
        end)
      end, cb)
    end,

    load_session = function(session_id, cb)
      with_lifecycle({ clear = true, touch = true }, function(done)
        session:load(session_id, done)
      end, cb)
    end,

    connect_and_load = function(session_id, cb)
      with_lifecycle({ touch = true }, function(done)
        session:connect_and_load(session_id, done)
      end, cb)
    end,

    pick_session = function()
      local function load_choice(item)
        with_lifecycle({ clear = true }, function(done)
          session:load(item.session_id, function(err)
            if err then
              Sessions.remove(item.session_id)
            end
            done(err)
          end)
        end)
      end

      local function show_picker(items)
        if #items == 0 then
          vim.notify("[emeth] No previous sessions found", vim.log.levels.INFO)
          return
        end
        vim.ui.select(items, {
          prompt = "Resume session:",
          format_item = function(item)
            return item.label
          end,
        }, function(choice)
          if choice and choice.session_id ~= session.session_id then
            load_choice(choice)
          end
        end)
      end

      session:list_sessions(function(sessions, err)
        vim.schedule(function()
          if not err and sessions and #sessions > 0 then
            local items = {}
            for _, s in ipairs(sessions) do
              items[#items + 1] = {
                label = (s.title or s.sessionId) .. (s.updatedAt and ("  " .. s.updatedAt) or ""),
                session_id = s.sessionId,
              }
            end
            show_picker(items)
          else
            local local_sessions = Sessions.list(vim.fn.getcwd(), session.provider_name)
            local items = {}
            for _, s in ipairs(local_sessions) do
              items[#items + 1] = {
                label = (s.title or s.session_id:sub(1, 12)) .. "  " .. (s.updated_at or ""),
                session_id = s.session_id,
              }
            end
            show_picker(items)
          end
        end)
      end)
    end,

    new_session = function()
      view:clear()
      reset_state()
      selected_files = {}
      refresh_file_display()
      with_lifecycle({ save = true }, function(done)
        local cwd = vim.fn.getcwd()
        session.client:create_session(cwd, {}, function(session_id, err, result)
          if not err then
            session.session_id = session_id
            session:_extract_session_info(result)
            session._state = "ready"
            vim.schedule(function()
              view:add_message(Message:new("system", "New session started."))
            end)
          end
          done(err)
        end)
      end)
    end,

    disconnect = function()
      if session.session_id then
        Sessions.touch(session.session_id)
      end
      Winbar.detach()
      if not reload_timer:is_closing() then
        reload_timer:stop()
        reload_timer:close()
      end
      if ext_cleanup then
        ext_cleanup()
      end
      session:disconnect()
    end,

    cancel = function()
      session:cancel()
      Winbar.set_state("ready")
    end,

    add_file = add_file,

    remove_file = function(path)
      path = vim.fn.fnamemodify(path, ":p")
      for i, f in ipairs(selected_files) do
        if f == path then
          table.remove(selected_files, i)
          refresh_file_display()
          return
        end
      end
    end,

    get_selected_files = function()
      return selected_files
    end,

    add_fenced = function(header_or_lines, body)
      view:append_fenced(header_or_lines, body)
    end,
  }

  view.integration = integration
  return integration
end

return M
