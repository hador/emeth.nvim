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
--- Extensions may also register two in-place transforms during `setup`, via
--- `integration.set_transform_update` and `set_transform_elicitation`.
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
  -- Per-turn streaming state: which message each streaming update kind is
  -- currently appending to, and the tool-call-id -> message-uuid map.
  ---@class acp.StreamState
  ---@field assistant_uuid string|nil  message the current agent text streams into
  ---@field thinking_uuid string|nil   message the current thought streams into
  ---@field plan_uuid string|nil       the live plan block, while it's still last
  ---@field tool_map table<string, string>  toolCallId -> message uuid

  -- Keyed by the session the updates belong to. `session/update` carries a
  -- sessionId, and a subagent's output arrives under its OWN session id, so two
  -- streams can be live at once — sharing one state table would let them append
  -- into each other's messages. Handlers receive their stream as an argument
  -- rather than closing over a single table.
  local streams = {} ---@type table<string, acp.StreamState>

  ---The stream for `session_id`, created on first use.
  ---@param session_id string|nil
  ---@return acp.StreamState
  local function stream_for(session_id)
    local key = session_id or "?"
    local s = streams[key]
    if not s then
      s = { tool_map = {} }
      streams[key] = s
    end
    return s
  end
  local selected_files = {} ---@type string[]
  -- FIFO of pending permission requests. Only the head claims the a/A/r/R keys
  -- at any time, so concurrent requests can't clobber each other's claims.
  local permission_queue = {} ---@type { tool_call: table, options: table[], callback: fun(option_id: string|nil), prompt_uuid?: string }[]
  -- FIFO of pending elicitations, same discipline as permissions: only the head
  -- claims <CR>, so concurrent requests can't clobber each other.
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
  local elicitation_queue = {} ---@type acp.PendingElicitation[]
  local roots = Roots.attach(view)
  local pending_reloads = {} ---@type table<string, number|true>  -- path → first_changed or true

  -- Coalesces the flood of tool_call_update content chunks into at most one
  -- render per interval. A streaming tool body arrives chunk-by-chunk, and each
  -- render of an *expanded* body is O(body); re-rendering the whole growing body
  -- on every chunk is O(body^2). We apply each chunk's data synchronously (so
  -- the model is always current) but only paint on this debounce's tick.
  local render_debounce = util.debounce(80, function()
    view:flush()
  end)
  local schedule_tool_render = render_debounce.call

  -- Forward-declared so handlers registered earlier can capture it.
  local render_mode ---@type fun(mode_id: string)
  local render_model ---@type fun()
  -- Defined with the elicitation UI further down; do_cancel is declared above it.
  local cancel_elicitations ---@type fun()
  -- Set while a prompt is waiting for free text from the input box; the next
  -- submission goes here instead of to the agent. Declared up here because
  -- `on_submit` is defined before the elicitation UI that arms it.
  local input_capture = nil ---@type fun(text: string)|nil
  -- (Re)registers a slash command per session config option (e.g. /model).
  -- Forward-declared so the config_option_update handler can call it.
  local register_config_option_commands ---@type fun()

  -- Hook for provider extensions to mutate session/update payloads in place
  -- before the integration consumes them. Registered via
  -- `integration.set_transform_update(fn)` from inside `ext.setup`.
  ---@type fun(update: table)|nil
  local transform_update_fn = nil
  -- Hook for provider extensions to enrich parsed elicitation fields (fold a
  -- provider's free-text companion field into its sibling, attach option
  -- previews, reorder). Returns the field list to use. Registered via
  -- `integration.set_transform_elicitation(fn)`.
  ---@type fun(fields: acp.ElicitationField[], request: table): acp.ElicitationField[]|nil
  local transform_elicitation_fn = nil

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

  local reload_debounce = util.debounce(1000, flush_reloads)
  local function schedule_reload(path, first_changed)
    pending_reloads[path] = first_changed or pending_reloads[path] or true
    reload_debounce.call()
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
    streams = {}
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
    -- Before the activity checks below: an open question always belongs to an
    -- agent request the user is now abandoning, and it can outlive `generating`
    -- (a question answered during the trailing update tail leaves activity
    -- idle). Answering `cancel` aborts the originating tool call cleanly instead
    -- of leaving a prompt nobody intends to answer. No-op when none are open.
    if cancel_elicitations then
      cancel_elicitations()
    end

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

  ---Prompt content for `text`: the @-mentioned files, then the text itself.
  ---@param text string
  ---@return table[]
  local function build_prompt(text)
    local prompt = {}
    for _, fpath in ipairs(selected_files) do
      prompt[#prompt + 1] = {
        type = "resource_link",
        uri = "file://" .. fpath,
        name = vim.fn.fnamemodify(fpath, ":t"),
      }
    end
    prompt[#prompt + 1] = { type = "text", text = text }
    return prompt
  end

  ---Render the user's turn in the transcript. The agent doesn't echo our own
  ---input back (a steered message's replay is consumed agent-side), so this is
  ---the only place a user message comes from.
  ---@param text string
  ---@return chat_ui.Message
  local function add_user_message(text)
    local exts = session.extensions or {}
    local msg = Message:new("user", text, {
      selected_files = vim.deepcopy(selected_files),
      provider = session.provider_name,
      model = exts.model_id,
      mode = exts.mode_id,
      badges = Winbar.get_badges(),
    })
    view:add_message(msg)
    if session.session_id then
      Sessions.touch(session.session_id)
      local entry = Sessions.get(session.session_id)
      if entry and not entry.title then
        Sessions.update_title(session.session_id, text:sub(1, 80):gsub("\n", " "))
      end
    end
    return msg
  end

  ---Start a fresh turn and own its completion.
  ---@param prompt table[]
  local function start_turn(prompt)
    reset_state()
    Winbar.clear_mode_tag()
    local token = begin("generating")
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

  ---Hand `text` back to the input buffer so a rejected submit isn't lost.
  ---@param text string
  local function restore_input(text)
    vim.api.nvim_buf_set_lines(view.input_buf, 0, -1, false, vim.split(text, "\n"))
    view:set_context_files(view._context_files)
  end

  view.on_submit = function(text)
    -- A prompt may have claimed the next submission (a free-text elicitation
    -- answer). It reuses the input box rather than a modal prompt so the user
    -- gets normal editing — multiline, paste folding — and nothing steals focus.
    if input_capture then
      local capture = input_capture
      input_capture = nil
      capture(text)
      return
    end

    -- Steering: while a turn is running, deliver the message *into* it instead
    -- of refusing the submit. Note this deliberately does NOT call begin() — the
    -- in-flight session/prompt still owns settling the activity state, and
    -- bumping the epoch would invalidate its callback, stranding the winbar in
    -- "generating" forever.
    if session:is_connected() and activity == "generating" and session:supports_steering() then
      local prompt = build_prompt(text)
      local msg = add_user_message(text)
      view:invalidate()
      session:steer(prompt, function(outcome, err)
        vim.schedule(function()
          if err then
            view:add_message(Message:new("system", "Error: " .. util.fmt_err(err)))
            view:invalidate()
            return
          end
          -- The turn finished between our check and the request landing. The
          -- agent left the content untouched precisely so we can send it as a
          -- normal prompt whose lifecycle we own.
          if outcome == "promptRequired" then
            start_turn(prompt)
            return
          end
          -- Mark it only now that the agent confirmed the injection. Marking at
          -- submit time would claim a steer for the `promptRequired` race, which
          -- is an ordinary turn. Reading back, "did this cut into a running turn
          -- or start one?" is otherwise unrecoverable.
          view:update_message(msg.uuid, function(m)
            m.metadata.steered = true
          end)
          view:invalidate()
        end)
      end)
      return
    end

    -- Accept input when the transport is up and nothing of ours is in flight.
    -- "cancelled" is idle-with-tail-suppression, so it accepts input too.
    if not session:is_connected() or activity == "generating" or activity == "connecting" then
      vim.notify("[emeth] Session not ready", vim.log.levels.WARN)
      restore_input(text)
      return
    end

    add_user_message(text)
    start_turn(build_prompt(text))
  end

  -- ── Session events ─────────────────────────────────────────────

  -- ── Update dispatch table ──────────────────────────────────────
  -- One handler per `sessionUpdate` type. Each closes over the integration
  -- state it needs (the `state` table, schedule_reload, render_mode, session,
  -- view).

  ---Each handler receives the update plus the streaming state for the session
  ---that update belongs to. Handlers that keep no streaming state ignore it.
  ---@type table<string, fun(update: table, stream: acp.StreamState)>
  local update_handlers = {}

  -- `sessionUpdate` types that are pure metadata and shouldn't flip the
  -- winbar to "generating" state.
  local non_streaming_updates = {
    available_commands_update = true,
    session_info_update = true,
    usage_update = true,
    current_mode_update = true,
    config_option_update = true,
  }

  function update_handlers.user_message_chunk(update)
    if update.content and update.content.type == "text" then
      view:add_message(Message:new("user", update.content.text))
    end
  end

  function update_handlers.agent_message_chunk(update, stream)
    if not (update.content and update.content.type == "text") then
      return
    end
    if stream.assistant_uuid then
      view:update_message(stream.assistant_uuid, function(msg)
        msg:append_text(update.content.text)
      end)
    else
      local msg = Message:new("assistant", update.content.text)
      stream.assistant_uuid = msg.uuid
      stream.thinking_uuid = nil
      view:add_message(msg)
    end
  end

  function update_handlers.agent_thought_chunk(update, stream)
    if not (update.content and update.content.type == "text" and update.content.text ~= "") then
      return
    end
    if stream.thinking_uuid then
      view:update_message(stream.thinking_uuid, function(msg)
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
      stream.thinking_uuid = msg.uuid
      stream.assistant_uuid = nil
      view:add_message(msg)
    end
  end

  ---Give a subagent's spawning tool an expand hook that shows/hides the calls
  ---nested under it. Installed on demand (the first child to arrive) and
  ---idempotent, since the parent tool_call is created before we know it has any.
  ---
  ---Takes over from the renderer's default `_expanded` toggle because the two
  ---have to move together: the parent's own body is empty for a subagent tool,
  ---and what the user wants to see is its children.
  ---@param parent chat_ui.Message
  local function attach_subagent_expand(parent)
    if parent.metadata.on_expand then
      return
    end
    parent.metadata.on_expand = function(msg)
      local expanded = msg.metadata._expanded ~= true
      msg.metadata._expanded = expanded
      for _, m in ipairs(view:get_messages()) do
        if m.metadata and m.metadata.parent_tool_call_id == msg.content[1].id then
          m.visible = expanded
        end
      end
    end
  end

  function update_handlers.tool_call(update, stream)
    stream.assistant_uuid = nil
    stream.thinking_uuid = nil
    local existing_uuid = stream.tool_map[update.toolCallId]
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
      local metadata = { tool_call = update }
      -- A tool run by a subagent is folded into the tool that spawned it: one
      -- subagent easily runs dozens of calls, and left at top level they bury
      -- the main conversation. `parent_tool_call_id` is set by a provider
      -- transform, so this stays namespace-agnostic.
      local parent_uuid = update.parent_tool_call_id and stream.tool_map[update.parent_tool_call_id]
      local parent = parent_uuid and view:get_message(parent_uuid) or nil
      if parent then
        metadata.parent_tool_call_id = update.parent_tool_call_id
      end
      local msg = Message:new("assistant", {
        type = "tool_use",
        name = update.kind or update.title or "tool",
        id = update.toolCallId,
        input = update.rawInput or {},
        status = update.status or "pending",
      }, metadata)
      if parent then
        -- Hidden while the parent is collapsed; a child arriving after the user
        -- expanded it shows up straight away.
        msg.visible = parent.metadata._expanded == true
        parent.metadata.subagent_children = (parent.metadata.subagent_children or 0) + 1
        attach_subagent_expand(parent)
        view:invalidate()
      end
      stream.tool_map[update.toolCallId] = msg.uuid
      view:add_message(msg)
    end
  end

  function update_handlers.tool_call_update(update, stream)
    local uuid = stream.tool_map[update.toolCallId]
    if uuid then
      -- A content/rawOutput-only chunk (the common case while a tool streams)
      -- is throttled: apply it now, paint on the timer. Anything that changes
      -- what the card *shows structurally* -- status, title, locations, input
      -- -- renders promptly so the header/box/icon never lags the model.
      local structural = update.status ~= nil
        or update.title ~= nil
        or update.rawInput ~= nil
        or update.locations ~= nil
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
      end, { defer_render = not structural })
      -- Structural updates rendered synchronously via update_message above (any
      -- content deferred earlier rides along in that same paint). Content-only
      -- chunks arm the throttle timer to paint shortly.
      if not structural then
        schedule_tool_render()
      end
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

  function update_handlers.plan(update, stream)
    -- Each `plan` update carries the FULL current plan and supersedes the
    -- previous one — it's a self-updating block, not an append. Render it once
    -- per turn and rewrite in place as entries progress. `stream.plan_uuid` is
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
    if stream.plan_uuid and last and last.uuid == stream.plan_uuid then
      view:update_message(stream.plan_uuid, function(msg)
        msg.content = { { type = "text", text = text } }
      end)
    else
      local msg = Message:new("system", text)
      stream.plan_uuid = msg.uuid
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

  -- Reconcile a fresh `configOptions` snapshot into session state: re-store the
  -- options (via _extract_session_info, so the provider's badge/model_id refresh
  -- runs) and re-register the slash commands so newly available options (e.g.
  -- /effort appearing after a model switch) appear and gone ones disappear.
  -- Shared by the agent-pushed `config_option_update` AND the response to a
  -- client-initiated set_config_option (the wrapper only *pushes* for
  -- agent-side changes; a user's /model switch comes back in the response).
  local function reconcile_config_options(config_options)
    if type(config_options) ~= "table" then
      return
    end
    session:_extract_session_info({ configOptions = config_options })
    -- model_id / mode_id may have changed; refresh their winbar surfaces.
    render_model()
    if (session.extensions or {}).mode_id then
      render_mode(session.extensions.mode_id)
    end
    register_config_option_commands()
  end

  function update_handlers.config_option_update(update)
    vim.schedule(function()
      reconcile_config_options(update.configOptions)
    end)
  end

  session:on("update", function(update, update_session_id)
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
      handler(update, stream_for(update_session_id))
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
    -- Keys must come from the set the view binds permanently, otherwise the
    -- claim would never fire and the option would be unanswerable. The four ACP
    -- kinds map 1:1; an unknown kind takes whichever slot is still free.
    local keys = {}
    local taken = {}
    for _, opt in ipairs(req.options or {}) do
      local key = kind_keys[opt.kind]
      if not key or taken[key] then
        for _, candidate in ipairs({ "a", "A", "r", "R" }) do
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

  -- Activate the request at the head of the queue: render its prompt and claim
  -- the a/A/r/R keys for it. Only ever one active at a time, so the fixed keys
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
      view:clear_prompt_keys("permission")
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

    -- Claim rather than bind: these keys are owned permanently by the view, so
    -- releasing the claim can't delete a binding something else relies on.
    local claims = {}
    for i, opt in ipairs(req.options or {}) do
      claims[keys[i]] = function()
        resolve(opt.optionId)
      end
    end
    view:set_prompt_keys("permission", claims)
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
      -- Render via the same path as a regular tool_call update. The permission
      -- event carries no session id, so attribute it to the main session — the
      -- same stream this tool call's real updates arrive on.
      if not stream_for(session.session_id).tool_map[tool_call.toolCallId] then
        local update = vim.tbl_extend("keep", tool_call, { sessionUpdate = "tool_call" })
        session:_emit("update", update, session.session_id)
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

  -- ── Elicitation ──────────────────────────────────────────────
  -- The agent asks the user a structured question and blocks its turn on the
  -- answer. Rendered inline in the transcript with cursor-positioned <CR>, not
  -- as a picker: elicitations arrive unpredictably, and a modal window would
  -- steal focus (and keystrokes) from whatever buffer the user is editing.

  -- Every agent-supplied string placed on a single line must be flattened
  -- first: the renderer splits embedded newlines into extra buffer rows, which
  -- would shift every row index after it and misalign the <CR> action map.
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

  ---Lines for the active field, plus the row->action map that makes <CR> work.
  ---Row keys are 1-based offsets within the rendered message, which line up
  ---1:1 with this array because system messages render one row per text line.
  ---@param req acp.PendingElicitation
  ---@return string[] lines, table<integer, table> rows
  local function elicitation_lines(req)
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
    if #elicitation_queue > 1 then
      lines[#lines + 1] = ("  (%d more waiting)"):format(#elicitation_queue - 1)
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
    local typing = req.awaiting_input ~= nil
    if field.kind == "text" or field.kind == "number" then
      lines[#lines + 1] = typing and "  ✎ answer in the input box below, then submit" or "  ▸ type an answer…"
      rows[#lines] = { kind = "input" }
    elseif field.custom_key then
      -- Provider hook folded a free-text companion into this field.
      lines[#lines + 1] = typing and "  ✎ answer in the input box below, then submit" or "  ▸ type your own…"
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

  local activate_elicitation
  local function elicitation_badge()
    if #elicitation_queue > 0 then
      Winbar.set_badge("ask", "❓ input needed")
    else
      Winbar.clear_badge("ask")
    end
  end

  ---Re-render the head prompt in place (selection changed, expanded, or the
  ---queue depth moved).
  local function refresh_elicitation()
    local req = elicitation_queue[1]
    if not req or not req.prompt_uuid then
      return
    end
    local lines, rows = elicitation_lines(req)
    req.rows = rows
    view:update_message(req.prompt_uuid, function(m)
      m.content = { { type = "text", text = table.concat(lines, "\n") } }
    end)
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

  ---Finish the head request and start the next one.
  ---@param response acp.CreateElicitationResponse
  local function finish_elicitation(response)
    local req = table.remove(elicitation_queue, 1)
    if not req then
      return
    end
    view:clear_prompt_keys("elicitation")
    -- Never leave the input box hijacked: an armed capture would swallow the
    -- user's next real prompt.
    if req.awaiting_input then
      req.awaiting_input = nil
      input_capture = nil
    end
    if req.prompt_uuid then
      local summary = elicitation_summary(req, response)
      view:update_message(req.prompt_uuid, function(m)
        m.metadata.on_expand = nil
        m.content = { { type = "text", text = summary } }
      end)
    end
    pcall(req.callback, response)
    elicitation_badge()
    if elicitation_queue[1] then
      activate_elicitation()
    end
  end

  ---Accept if we have everything required, otherwise decline — an accept
  ---carrying blanks would look like a real answer to the agent.
  local function submit_elicitation(req)
    local Elicit = require("emeth.acp.elicitation")
    if not Elicit.is_complete(req.fields, req.answers) then
      finish_elicitation({ action = "decline" })
      return
    end
    finish_elicitation({ action = "accept", content = Elicit.to_content(req.fields, req.answers) })
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
    refresh_elicitation()
  end

  ---Act on the row under the cursor.
  local function on_elicitation_cr()
    local req = elicitation_queue[1]
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
      finish_elicitation({ action = "decline" })
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
        refresh_elicitation()
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
          refresh_elicitation()
        end
      end
      refresh_elicitation()
      view:focus_input()
    end
  end

  activate_elicitation = function()
    local req = elicitation_queue[1]
    if not req then
      return
    end
    local lines, rows = elicitation_lines(req)
    req.rows = rows
    local prompt = Message:new("system", table.concat(lines, "\n"), {
      -- Picked up by the result buffer's K handler.
      on_expand = function()
        req.expanded = not req.expanded
        local l, r = elicitation_lines(req)
        req.rows = r
        local m = view:get_message(req.prompt_uuid)
        if m then
          m.content = { { type = "text", text = table.concat(l, "\n") } }
        end
      end,
    })
    view:add_message(prompt)
    req.prompt_uuid = prompt.uuid

    -- Claim <CR> rather than binding it: the view owns it permanently, so
    -- releasing the claim restores its default instead of deleting the mapping.
    view:set_prompt_keys("elicitation", { ["<CR>"] = on_elicitation_cr })
    elicitation_badge()
  end

  -- Drain every pending question, answering `cancel` (the turn is going away,
  -- so the originating tool call should abort rather than proceed answerless).
  -- Drains directly rather than looping finish_elicitation, which would render
  -- each queued prompt on its way to killing it.
  cancel_elicitations = function()
    if not elicitation_queue[1] then
      return
    end
    local queued = elicitation_queue
    elicitation_queue = {}
    view:clear_prompt_keys("elicitation")
    input_capture = nil
    for _, req in ipairs(queued) do
      if req.prompt_uuid then
        local summary = elicitation_summary(req, { action = "cancel" })
        view:update_message(req.prompt_uuid, function(m)
          m.metadata.on_expand = nil
          m.content = { { type = "text", text = summary } }
        end)
      end
      pcall(req.callback, { action = "cancel" })
    end
    elicitation_badge()
  end

  session:on("elicitation", function(request, callback)
    vim.schedule(function()
      local fields = require("emeth.acp.elicitation").parse(request.requestedSchema)
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

      elicitation_queue[#elicitation_queue + 1] = req
      if #elicitation_queue == 1 then
        activate_elicitation()
      else
        refresh_elicitation()
      end
      -- The transcript prompt and the winbar badge are both invisible when the
      -- sidebar is closed, and the agent stays blocked until it's answered — so
      -- that case needs an out-of-band nudge.
      local shown = false
      for _, win in ipairs(vim.api.nvim_list_wins()) do
        if vim.api.nvim_win_is_valid(win) and vim.api.nvim_win_get_buf(win) == view.result_buf then
          shown = true
          break
        end
      end
      if not shown then
        vim.notify("emeth: the agent is asking for input (:Emeth to answer)", vim.log.levels.INFO)
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
    set_transform_elicitation = function(fn)
      transform_elicitation_fn = fn
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

  -- Longest model string we'll put in the winbar before the generic fallback
  -- kicks in. The winbar truncates anyway, but a runaway id (e.g. a fully
  -- qualified Bedrock arn) would eat the whole bar, so cap it here first.
  local MODEL_DISPLAY_MAX = 24

  ---Provider-agnostic shortening applied *after* the provider hook, only when
  ---the string is still too long. Prefers the last dot-separated segment (so
  ---"global.anthropic.opus-4-8[1m]" → "opus-4-8[1m]"), then truncates keeping
  ---the tail (models usually differ in the suffix) with a leading ellipsis.
  ---@param s string
  ---@return string
  local function fit_model_display(s)
    if vim.fn.strdisplaywidth(s) <= MODEL_DISPLAY_MAX then
      return s
    end
    local tail = s:match("[^.]+$") -- last dot-separated segment
    if tail and vim.fn.strdisplaywidth(tail) <= MODEL_DISPLAY_MAX then
      return tail
    end
    s = tail or s
    if vim.fn.strdisplaywidth(s) <= MODEL_DISPLAY_MAX then
      return s
    end
    -- Keep the tail; strchars-based so we don't split a multibyte char.
    return "…" .. vim.fn.strcharpart(s, vim.fn.strchars(s) - (MODEL_DISPLAY_MAX - 1))
  end

  ---Render the current model into the winbar: the left segment shows
  ---`provider · model`, and the `model` badge (snapshotted into each prompt's
  ---metadata) tracks it too. The display string comes from the provider's
  ---optional `format_model` hook (e.g. claude shortens "claude-opus-4-6" →
  ---"opus-4-6"), then a generic length cap keeps it winbar-sized regardless of
  ---provider; with no hook the (capped) raw id is shown.
  render_model = function()
    local model = (session.extensions or {}).model_id
    local shown = nil
    if model and model ~= "" then
      shown = model
      if has_ext and type(ext.format_model) == "function" then
        local ok, s = pcall(ext.format_model, model)
        if ok and type(s) == "string" and s ~= "" then
          shown = s
        end
      end
      shown = fit_model_display(shown)
    end
    if shown then
      Winbar.set_badge("model", shown)
      Winbar.set_left(Winbar.fmt.plain(session.provider_name .. " · " .. shown))
    else
      Winbar.clear_badge("model")
      Winbar.set_left(Winbar.fmt.plain(session.provider_name))
    end
  end

  -- ── Session config options (model / mode / effort / agent / fast) ──
  -- These ride the standard ACP `configOptions` + `session/set_config_option`
  -- channel. Generic: we register one slash command per option the agent
  -- exposes and drive it through a single picker, so we don't hard-code
  -- "model". Providers using a bespoke mechanism (e.g. kiro-cli's own
  -- _kiro.dev/commands) never populate `config_options`, so this stays inert
  -- for them.

  ---Flatten a config option's select values into a picker list. `options` is
  ---either a flat array of `{ value, name, description }` or an array of
  ---groups `{ group, name, options = {...} }`; we render both flat.
  ---@param opt table  a SessionConfigOption (select type)
  ---@return { value: string, label: string, description?: string, group?: string }[]
  local function config_option_choices(opt)
    local out = {}
    for _, entry in ipairs(opt.options or {}) do
      if entry.options then
        for _, sub in ipairs(entry.options) do
          out[#out + 1] =
            { value = sub.value, label = sub.name or sub.value, description = sub.description, group = entry.name }
        end
      else
        out[#out + 1] = { value = entry.value, label = entry.name or entry.value, description = entry.description }
      end
    end
    return out
  end

  ---Open a picker for one config option and apply the selection.
  ---@param config_id string
  local function pick_config_option(config_id)
    local opts = (session.extensions or {}).config_options or {}
    local opt = opts[config_id]
    if not opt then
      vim.notify("[emeth] No '" .. config_id .. "' option for this session", vim.log.levels.WARN)
      return
    end
    ---Apply the response snapshot (only pushed for agent-side changes, so a
    ---user switch must reconcile the response) or surface an error.
    local function on_set(result, err)
      vim.schedule(function()
        if err then
          view:add_message(Message:new("system", "Failed to set " .. config_id .. ": " .. util.fmt_err(err)))
        elseif result and result.configOptions then
          reconcile_config_options(result.configOptions)
        end
      end)
    end

    if opt.type == "boolean" then
      -- No native boolean toggle from the picker; flip the current value.
      session:set_config_option(config_id, not opt.currentValue, on_set)
      return
    end
    local choices = config_option_choices(opt)
    if #choices == 0 then
      vim.notify("[emeth] No selectable values for '" .. config_id .. "'", vim.log.levels.WARN)
      return
    end
    vim.ui.select(choices, {
      prompt = "/" .. config_id,
      format_item = function(item)
        local s = item.label
        if item.value == opt.currentValue then
          s = "● " .. s
        end
        if item.group then
          s = s .. "  [" .. item.group .. "]"
        end
        if item.description and item.description ~= "" then
          s = s .. "  " .. item.description
        end
        return s
      end,
    }, function(choice)
      if not choice or choice.value == opt.currentValue then
        return
      end
      session:set_config_option(config_id, choice.value, on_set)
    end)
  end

  register_config_option_commands = function()
    Commands.clear_config()
    local opts = (session.extensions or {}).config_options or {}
    for id, opt in pairs(opts) do
      Commands.register(id, {
        desc = opt.description or opt.name or id,
        source = "config",
        has_picker = true,
        execute = function()
          pick_config_option(id)
        end,
      })
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
          vim.schedule(function()
            if exts.mode_id then
              render_mode(exts.mode_id)
            end
            render_model()
            -- Register /model (and any other config options the agent exposed
            -- on session/new or session/load).
            register_config_option_commands()
          end)
        end
        done(err)
      end)
    end, cb)
  end

  -- ── Public API ─────────────────────────────────────────────────

  ---Record which session the transcript now belongs to.
  ---
  ---Announced at every session boundary, not just connect: `/new` and loading a
  ---session both replace the session id, and previously said nothing about it, so
  ---there was no way to tell which session the transcript in front of you was.
  ---@param what string
  local function announce_session(what)
    vim.schedule(function()
      view:add_message(Message:new("system", ("%s  Session: %s"):format(what, session.session_id or "?")))
    end)
  end

  local integration = {
    connect = function(cb)
      lifecycle({ save = true }, function(opts, done)
        session:connect(opts, function(err)
          if not err then
            announce_session("Connected to " .. session.provider_name .. ".")
          end
          done(err)
        end)
      end, cb)
    end,

    load_session = function(session_id, cb)
      -- Hydrate roots from the persisted session entry before re-loading
      roots:hydrate_from(Sessions.get(session_id))
      lifecycle({ clear = true, touch = true }, function(opts, done)
        session:load(session_id, function(err)
          if not err then
            announce_session("Session loaded.")
          end
          done(err)
        end)
      end, cb)
    end,

    connect_and_load = function(session_id, cb)
      roots:hydrate_from(Sessions.get(session_id))
      lifecycle({ touch = true }, function(opts, done)
        session:connect_and_load(session_id, opts, function(err)
          if not err then
            announce_session("Connected to " .. session.provider_name .. ".")
          end
          done(err)
        end)
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
            announce_session("New session started.")
          end
          done(err)
        end)
      end)
    end,

    disconnect = function()
      if session.session_id then
        Sessions.touch(session.session_id)
      end
      Commands.clear_config()
      Winbar.detach()
      reload_debounce.close()
      render_debounce.close()
      view:flush() -- paint any final throttled tool content before we detach
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

    ---Register a function that enriches parsed elicitation fields before they
    ---are rendered, returning the list to use. Pass nil to clear.
    ---@param fn fun(fields: acp.ElicitationField[], request: table): acp.ElicitationField[]|nil
    set_transform_elicitation = function(fn)
      transform_elicitation_fn = fn
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
