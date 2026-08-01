--- ACP integration glue — wires emeth_acp Session to a ChatView.
---
--- Provider-specific behaviour is injected through optional hooks exported by
--- a module at `lua/emeth/integrations/<provider>.lua`:
---
---   setup(session, view) → cleanup           streaming events / @mentions / state
---   build_session_meta(emeth_config) → meta  `_meta` payload for session/new+load
---   format_mode(mode_id) → render_desc       { badge?, tag?, tag_kind? }
---   extract_session_info(result, extensions) populate non-spec session info
---
--- This file knows nothing about claude-code, kiro-cli, etc. — it only knows
--- the shape of these hooks.

local Commands = require("emeth.commands")
local Message = require("emeth.message")
local Roots = require("emeth.integrations.roots")
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
  local current_plan_uuid = nil
  local tool_message_map = {} ---@type table<string, string>
  local selected_files = {} ---@type string[]
  -- FIFO of pending permission requests. Only the head owns the a/r keymaps at
  -- any time, so concurrent requests can't clobber each other's bindings.
  local permission_queue = {} ---@type { tool_call: table, options: table[], callback: fun(option_id: string|nil), prompt_uuid?: string }[]
  local roots = Roots.attach(view)
  local reload_timer = vim.uv.new_timer()
  local pending_reloads = {} ---@type table<string, number|true>  -- path → first_changed or true

  -- Forward-declared so handlers registered earlier can capture it.
  local render_mode ---@type fun(mode_id: string)

  -- Hook for provider extensions to mutate session/update payloads in place
  -- before the integration consumes them. Registered via
  -- `integration.set_transform_update(fn)` from inside `ext.setup`.
  ---@type fun(update: table)|nil
  local transform_update_fn = nil

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
        -- Position and center the target window on the changed line without
        -- stealing focus: if the user is reading emeth output, their cursor
        -- stays put while the source window shows the edit next door.
        vim.schedule(function()
          if not vim.api.nvim_win_is_valid(target_win) then
            return
          end
          pcall(vim.api.nvim_win_set_cursor, target_win, { first_path.line, 0 })
          vim.api.nvim_win_call(target_win, function()
            vim.cmd("normal! zz")
          end)
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

  -- ── Activity state ─────────────────────────────────────────────
  -- Single source of truth for "what is the UI doing right now"; the winbar
  -- is a pure projection of it. "cancelled" is idle-with-tail-suppression: it
  -- absorbs trailing updates after a cancel instead of flipping back to
  -- generating. `epoch` is the staleness token for async continuations:
  -- capture it when a phase starts, check it before acting; begin() bumps it,
  -- atomically invalidating everything previously in flight.
  ---@type "idle"|"connecting"|"generating"|"cancelled"
  local activity = "idle"
  local epoch = 0
  local WINBAR = { idle = "ready", cancelled = "ready", connecting = "connecting", generating = "generating" }

  local function set_activity(a)
    activity = a
    Winbar.set_state(WINBAR[a])
  end

  ---Enter a new activity phase, invalidating all prior async continuations.
  ---@return number token compare against `epoch` before acting later
  local function begin(a)
    epoch = epoch + 1
    set_activity(a)
    return epoch
  end

  local function reset_state()
    current_assistant_uuid = nil
    current_thinking_uuid = nil
    current_plan_uuid = nil
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
    local token = begin("connecting")
    -- Nudge if the handshake is still in flight after a while (e.g. a
    -- launcher running updates before it execs the agent). Purely time/state
    -- based — reads nothing from the child process.
    local slow_ms = require("emeth").config.slow_connect_ms or 0
    if slow_ms > 0 then
      vim.defer_fn(function()
        if epoch == token then
          view:add_message(
            Message:new(
              "system",
              "⏳ Taking longer than usual. The agent's launcher may be running updates — press <C-c> to abort and retry."
            )
          )
        end
      end, slow_ms)
    end
    action(function(err)
      if epoch ~= token then
        return -- superseded: cancelled or a newer lifecycle took over
      end
      -- Bump synchronously so the nudge timer can't fire between now and the
      -- scheduled completion below.
      epoch = epoch + 1
      vim.schedule(function()
        set_activity("idle")
        Winbar.clear_mode_tag()
        view:invalidate()
        if err then
          view:add_message(Message:new("system", "Error: " .. util.fmt_err(err)))
        else
          if opts.save and session.session_id then
            Sessions.save({
              session_id = session.session_id,
              provider = session.provider_name,
              cwd = vim.fn.getcwd(),
              additional_directories = roots:save_field(),
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
  }

  -- Merge in roots' @workspace / @roots handlers
  for k, v in pairs(roots:mention_handlers()) do
    view._mention_handlers[k] = v
  end

  ---Cancel is a total function: converge the UI to ready, cancelling whatever
  ---that requires based on `activity` alone.
  local function do_cancel()
    if activity == "connecting" then
      -- Abort a stuck handshake (no session to cancel yet). Tear down fully
      -- and clear the module-level integration so the next :Emeth reconnects
      -- fresh instead of focusing a dead session.
      begin("idle")
      view:add_message(Message:new("system", "⏹ Connection aborted. Retry with :Emeth (or :EmethNew)."))
      if view.integration and view.integration.disconnect then
        view.integration.disconnect()
      else
        session:disconnect()
      end
      require("emeth")._set_integration(nil, nil)
      return
    end

    if activity ~= "generating" then
      return -- idle or already cancelled: nothing in flight
    end

    session:cancel()
    -- Entering "cancelled" absorbs the trailing update tail (it won't flip
    -- the winbar back to generating); the epoch bump from begin() invalidates
    -- any in-flight prompt callback so it can't overwrite this state.
    begin("cancelled")
    Winbar.clear_mode_tag()
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
    -- Accept input when the transport is up and nothing of ours is in flight.
    -- "cancelled" is idle-with-tail-suppression, so it accepts input too.
    if not session:is_connected() or activity == "generating" or activity == "connecting" then
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

    local exts = session.extensions or {}
    local msg = Message:new("user", text, {
      selected_files = vim.deepcopy(selected_files),
      provider = session.provider_name,
      model = exts.model_id,
      mode = exts.mode_id,
      badges = Winbar.get_badges(),
    })
    view:add_message(msg)
    reset_state()
    Winbar.clear_mode_tag()
    local token = begin("generating")
    if session.session_id then
      Sessions.touch(session.session_id)
      local entry = Sessions.get(session.session_id)
      if entry and not entry.title then
        Sessions.update_title(session.session_id, text:sub(1, 80):gsub("\n", " "))
      end
    end
    session:send_prompt(prompt, function(_, err)
      vim.schedule(function()
        if epoch == token then
          set_activity("idle")
        end
        if err then
          view:add_message(Message:new("system", "Error: " .. util.fmt_err(err)))
        end
        view:invalidate()
      end)
    end)
  end

  -- ── Session events ─────────────────────────────────────────────

  -- ── Update dispatch table ──────────────────────────────────────
  -- One handler per `sessionUpdate` type. Each closes over the integration
  -- state it needs (uuids, tool_message_map, schedule_reload, render_mode,
  -- session, view).

  ---@type table<string, fun(update: table)>
  local update_handlers = {}

  -- `sessionUpdate` types that are pure metadata and shouldn't flip the
  -- winbar to "generating" state.
  local non_streaming_updates = {
    available_commands_update = true,
    session_info_update = true,
    usage_update = true,
    current_mode_update = true,
  }

  function update_handlers.user_message_chunk(update)
    if update.content and update.content.type == "text" then
      view:add_message(Message:new("user", update.content.text))
    end
  end

  function update_handlers.agent_message_chunk(update)
    if not (update.content and update.content.type == "text") then
      return
    end
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

  function update_handlers.agent_thought_chunk(update)
    if not (update.content and update.content.type == "text" and update.content.text ~= "") then
      return
    end
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

  function update_handlers.tool_call(update)
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
  end

  function update_handlers.tool_call_update(update)
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
  end

  function update_handlers.plan(update)
    -- Each `plan` update carries the FULL current plan and supersedes the
    -- previous one — it's a self-updating block, not an append. Render it once
    -- per turn and rewrite in place as entries progress. `current_plan_uuid` is
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
    if current_plan_uuid and last and last.uuid == current_plan_uuid then
      view:update_message(current_plan_uuid, function(msg)
        msg.content = { { type = "text", text = text } }
      end)
    else
      local msg = Message:new("system", text)
      current_plan_uuid = msg.uuid
      view:add_message(msg)
    end
  end

  function update_handlers.available_commands_update(update)
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
        execute = function(args, ctx)
          if ctx.view.on_submit then
            ctx.view.on_submit("/" .. name .. (args ~= "" and (" " .. args) or ""))
          end
        end,
      })
    end
  end

  function update_handlers.session_info_update(update)
    if update.title then
      view._session_title = update.title
      if session.session_id then
        Sessions.update_title(session.session_id, update.title)
      end
    end
  end

  function update_handlers.usage_update(update)
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

  function update_handlers.current_mode_update(update)
    -- Standard ACP permission/mode update.
    if update.currentModeId then
      vim.schedule(function()
        session.extensions = session.extensions or {}
        session.extensions.mode_id = update.currentModeId
        render_mode(update.currentModeId)
      end)
    end
  end

  session:on("update", function(update)
    -- Provider extensions may rewrite the update in-place (e.g. enrich a
    -- tool_call's title) before we consume it. Keep this lightweight —
    -- transforms run on every event.
    if transform_update_fn then
      pcall(transform_update_fn, update)
    end

    -- Update-driven activity transition: streaming content → generating.
    -- connecting/cancelled absorb updates (stay put); only idle transitions.
    if not non_streaming_updates[update.sessionUpdate] and activity == "idle" then
      set_activity("generating")
    end

    local handler = update_handlers[update.sessionUpdate]
    if handler then
      handler(update)
    end
  end)

  local kind_keys = { allow_once = "a", allow_always = "A", reject_once = "r", reject_always = "R" }

  --- Build the prompt body for a queued permission request. The tool_call card
  --- is rendered directly above this prompt, so we keep it terse: a short tool
  --- identity (truncated — kiro titles are the whole command), the count of
  --- other requests waiting, then one line per option.
  ---@param req { tool_call: table, options: table[] }
  ---@return string[] lines, string[] keys  keys aligned to req.options order
  local function permission_lines(req)
    local tool_name = req.tool_call.title or req.tool_call.kind or "tool"
    tool_name = tool_name:gsub("%s+", " ")
    if vim.fn.strdisplaywidth(tool_name) > 60 then
      tool_name = vim.fn.strcharpart(tool_name, 0, 59) .. "…"
    end
    local lines = { "Agent wants permission for: " .. tool_name }
    if #permission_queue > 1 then
      lines[#lines + 1] = ("  (%d more pending)"):format(#permission_queue - 1)
    end
    local keys = {}
    for _, opt in ipairs(req.options or {}) do
      local key = kind_keys[opt.kind] or opt.kind:sub(1, 1)
      keys[#keys + 1] = key
      lines[#lines + 1] = "  [" .. key .. "] " .. (opt.name or opt.kind)
    end
    return lines, keys
  end

  -- Activate the request at the head of the queue: render its prompt and bind
  -- the a/A/r/R keys to it. Only ever one active at a time, so the fixed keys
  -- can't collide across concurrent requests. Forward-declared for recursion.
  local activate_permission
  activate_permission = function()
    local req = permission_queue[1]
    if not req then
      return
    end

    local lines, keys = permission_lines(req)
    local prompt_msg = Message:new("system", table.concat(lines, "\n"))
    view:add_message(prompt_msg)
    req.prompt_uuid = prompt_msg.uuid

    local function resolve(option_id)
      for _, key in ipairs(keys) do
        pcall(vim.api.nvim_buf_del_keymap, view.result_buf, "n", key)
      end
      view:update_message(prompt_msg.uuid, function(m)
        m.visible = false
      end)
      req.callback(option_id)
      -- Pop the head and activate the next queued request, if any.
      table.remove(permission_queue, 1)
      if permission_queue[1] then
        activate_permission()
      end
    end

    for i, opt in ipairs(req.options or {}) do
      vim.api.nvim_buf_set_keymap(view.result_buf, "n", keys[i], "", {
        noremap = true,
        silent = true,
        callback = function()
          resolve(opt.optionId)
        end,
      })
    end
  end

  -- Re-render the head prompt's pending count when the queue depth changes
  -- (so the first/active prompt reflects requests that arrived behind it).
  local function refresh_head_pending()
    local head = permission_queue[1]
    if not head or not head.prompt_uuid then
      return
    end
    local lines = permission_lines(head)
    view:update_message(head.prompt_uuid, function(m)
      m.content = { { type = "text", text = table.concat(lines, "\n") } }
    end)
  end

  session:on("permission", function(tool_call, options, callback)
    vim.schedule(function()
      -- Render via the same path as a regular tool_call update
      if not tool_message_map[tool_call.toolCallId] then
        local update = vim.tbl_extend("keep", tool_call, { sessionUpdate = "tool_call" })
        session:_emit("update", update)
      end

      -- If auto-approve is on, session layer already called the callback
      if require("emeth.acp").config.auto_approve_tools then
        return
      end

      -- Enqueue; only the head request binds keys. This serializes the UI for
      -- concurrent requests so their fixed a/r keymaps don't overwrite each
      -- other (which previously left earlier requests unanswerable → hang).
      permission_queue[#permission_queue + 1] = { tool_call = tool_call, options = options, callback = callback }
      if #permission_queue == 1 then
        activate_permission()
      else
        -- Something queued behind the active prompt; bump its pending count.
        refresh_head_pending()
      end
    end)
  end)

  session:on("error", function(err)
    view:add_message(Message:new("assistant", "**Error:** " .. util.fmt_err(err)))
  end)

  session:on("file_written", function(path, first_changed)
    schedule_reload(path, first_changed)
  end)

  -- Stub integration that exposes only the per-session setters extensions
  -- need *during* setup. The real `integration` table is built below; we
  -- set `view.integration` to it later. Any setter the extension calls here
  -- mutates the same upvalue the real integration's method will mutate.
  local ext_integration = {
    set_transform_update = function(fn)
      transform_update_fn = fn
    end,
  }

  -- Load provider-specific extensions (e.g. claude-code, kiro-cli).
  local provider_mod = "emeth.integrations." .. session.provider_name
  local has_ext, ext = pcall(require, provider_mod)
  local ext_cleanup
  if has_ext and ext.setup then
    -- Temporarily expose the stub so extensions calling
    -- `view.integration.set_transform_update(...)` work during setup. The
    -- real integration table replaces this at the end of setup_integration.
    view.integration = ext_integration
    ext_cleanup = ext.setup(session, view)
  end

  ---Build the session/new (and session/load) `_meta` payload by asking the
  ---provider extension what meta it wants to attach.
  ---@return table|nil
  local function build_session_meta()
    if has_ext and type(ext.build_session_meta) == "function" then
      local emeth_config = require("emeth").config
      local ok, meta = pcall(ext.build_session_meta, emeth_config)
      if ok and type(meta) == "table" and next(meta) ~= nil then
        return meta
      end
    end
    return nil
  end

  ---Render a mode update via the provider extension's `format_mode` hook.
  ---The extension returns a description table — this function knows nothing
  ---about specific mode names or icons.
  ---@param mode_id string
  render_mode = function(mode_id)
    ---@type { badge?: string, tag?: string, tag_kind?: string }|nil
    local desc = nil
    if has_ext and type(ext.format_mode) == "function" then
      local ok, r = pcall(ext.format_mode, mode_id)
      if ok and type(r) == "table" then
        desc = r
      end
    end
    desc = desc or { badge = mode_id }

    if desc.badge and desc.badge ~= "" then
      Winbar.set_badge("mode", desc.badge)
    else
      Winbar.clear_badge("mode")
    end
    if desc.tag and desc.tag ~= "" then
      Winbar.set_mode_tag(desc.tag, desc.tag_kind)
    else
      Winbar.clear_mode_tag()
    end
  end

  ---Build options carrying the current workspace roots and provider meta, if any.
  local function lifecycle_opts()
    local opts = {}
    local snap = roots:snapshot()
    if #snap > 0 then
      opts.additional_directories = snap
    end
    local meta = build_session_meta()
    if meta then
      opts.meta = meta
    end
    return next(opts) and opts or nil
  end

  ---Run a session lifecycle method through with_lifecycle, applying the
  ---shared post-ready fixups (render any reported mode) on success. `run`
  ---receives (opts, done) and calls the session method.
  ---@param wl_opts table
  ---@param run fun(opts: table|nil, done: fun(err: any))
  ---@param cb? fun(err: any)
  local function lifecycle(wl_opts, run, cb)
    with_lifecycle(wl_opts, function(done)
      run(lifecycle_opts(), function(err)
        if not err then
          local exts = session.extensions or {}
          if exts.mode_id then
            vim.schedule(function()
              render_mode(exts.mode_id)
            end)
          end
        end
        done(err)
      end)
    end, cb)
  end

  -- ── Public API ─────────────────────────────────────────────────

  local integration = {
    connect = function(cb)
      lifecycle({ save = true }, function(opts, done)
        session:connect(opts, function(err)
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
      -- Hydrate roots from the persisted session entry before re-loading
      roots:hydrate_from(Sessions.get(session_id))
      lifecycle({ clear = true, touch = true }, function(opts, done)
        session:load(session_id, opts, done)
      end, cb)
    end,

    connect_and_load = function(session_id, cb)
      roots:hydrate_from(Sessions.get(session_id))
      lifecycle({ touch = true }, function(opts, done)
        session:connect_and_load(session_id, opts, done)
      end, cb)
    end,

    pick_session = function()
      local function load_choice(item)
        lifecycle({ clear = true }, function(opts, done)
          session:load(item.session_id, opts, function(err)
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
      -- Keep roots as-is so a new session inherits the user's roots.
      lifecycle({ save = true }, function(opts, done)
        session:new_session(opts, function(err)
          if not err then
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
      roots:cleanup()
      session:disconnect()
    end,

    cancel = do_cancel,

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

    add_root = function(dir)
      roots:add(dir)
    end,
    remove_root = function(idx_or_path)
      roots:remove(idx_or_path)
    end,

    ---Register a function that mutates session/update payloads in place
    ---before the integration consumes them. Pass nil to clear.
    ---@param fn fun(update: table)|nil
    set_transform_update = function(fn)
      transform_update_fn = fn
    end,
  }

  -- Transfer any extra fields the provider extension added to the temporary
  -- stub onto the real integration table so they remain accessible after the
  -- stub is replaced.
  for k, v in pairs(ext_integration) do
    if integration[k] == nil then
      integration[k] = v
    end
  end

  view.integration = integration
  return integration
end

return M
