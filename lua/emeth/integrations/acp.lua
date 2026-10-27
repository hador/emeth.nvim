--- ACP integration glue — wires emeth_acp Session to a ChatView.
---
--- Provider-specific behaviour is injected through optional hooks exported by
--- a module at `lua/emeth/integrations/<provider>.lua`:
---
---   setup(session, view) → cleanup           streaming events / @mentions / state
---   build_session_meta(emeth_config) → meta  `_meta` payload for session/new+load
---   format_mode(mode_id) → render_desc       { badge?, tag?, tag_kind? }
---
--- Extensions may also register two in-place transforms during `setup`, via
--- `integration.set_transform_update` and `set_transform_elicitation`.
---
--- This file knows nothing about claude-code, kiro-cli, etc. — it only knows
--- the shape of these hooks.

local AcpPrompts = require("emeth.integrations.acp_prompts")
local AcpUpdates = require("emeth.integrations.acp_updates")
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
  ---@field assistant_message_id string|nil  agent messageId streaming into assistant_uuid (a change = new message)
  ---@field thinking_uuid string|nil   message the current thought streams into
  ---@field plan_uuid string|nil       the live plan block, while it's still last
  ---@field tool_map table<string, string>  toolCallId -> message uuid, across the session and its subagents
  ---@field subagents table<string, true>  child session ids announced by `subagent_update`

  -- One stream per transcript. A subagent's work arrives under its own child
  -- session id, but only its tool calls are rendered (nested under the tool that
  -- spawned it), so the text/thought/plan anchors only ever belong to the main
  -- session. Tool call ids are agent-unique, so one tool map serves both — which
  -- is what lets a child's call find its parent card.
  ---@return acp.StreamState
  local function new_stream()
    return { tool_map = {}, subagents = {} }
  end
  local stream = new_stream()
  local selected_files = {} ---@type string[]

  local roots = Roots.attach()
  local pending_reloads = {} ---@type table<string, { line?: integer, follow: boolean }>  -- path → reload record
  -- Abs path emeth last navigated the source window to on a file write. Lets
  -- `flush_reloads` tell "the pane is still on the file I put there" from "the
  -- user has taken the wheel to read something else" and stop yanking it away.
  local last_followed_abs = nil ---@type string|nil

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
  -- The agent-to-client prompts (permission requests, elicitations; see
  -- acp_prompts.lua). Attached further down, once the update dispatcher exists;
  -- do_cancel and on_submit, defined above that, reach it through this upvalue.
  -- Every caller runs from a handler wired after setup finishes, so it is
  -- assigned by then -- do_cancel still guards, since it is reachable during a
  -- failed setup.
  local prompts ---@type acp_prompts.Handle|nil
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
  -- Steering strategy, registered by a provider extension via
  -- `integration.set_steering({ supported, steer })`. `supported` is a boolean
  -- or a predicate; `steer(prompt, text, cb)` delivers a message into the running
  -- turn and reports back through `cb(outcome, err, info)`:
  --   * "injected"       landed in the live turn (claude) — mark it steered now
  --   * "promptRequired"  no turn was running (claude) — send as a normal prompt
  --   * "queued"          accepted into the agent's queue (kiro) — the provider
  --                       flips it to steered via its own lifecycle updates,
  --                       keyed by `info.message_id`
  ---@class acp.SteeringStrategy
  ---@field supported boolean|fun():boolean
  ---@field steer fun(prompt: table[], text: string, cb: fun(outcome: string|nil, err: any, info: table|nil))
  ---@type acp.SteeringStrategy|nil
  local steering = nil
  local function steering_supported()
    if not steering then
      return false
    end
    local s = steering.supported
    if type(s) == "function" then
      return s() == true
    end
    return s == true
  end

  local function flush_reloads()
    local target_win = util.find_source_win()
    local first_path = nil
    for p, rec in pairs(pending_reloads) do
      local abs = vim.fn.fnamemodify(p, ":p")
      local buf = vim.fn.bufnr(abs)
      if buf ~= -1 and vim.api.nvim_buf_is_loaded(buf) then
        vim.bo[buf].modified = false
        vim.api.nvim_buf_call(buf, function()
          vim.cmd("checktime")
        end)
      end
      -- Every write reloads an open buffer in place; only a follow-eligible one
      -- can steer the source window. A subagent's writes reload but never
      -- follow, so a background agent can't yank the pane around.
      if not first_path and rec.follow then
        first_path = { abs = abs, line = rec.line }
      end
    end
    if first_path and target_win then
      -- Hands-off: only follow the write if the source window is still showing
      -- the file emeth last steered it to. Once the user opens something else
      -- there to read it, we stop re-pointing the pane (buffers above still
      -- reload in place); following resumes when they return to that file. The
      -- first write (last_followed_abs == nil) always follows, to show where
      -- work began.
      local cur = vim.fn.fnamemodify(vim.api.nvim_buf_get_name(vim.api.nvim_win_get_buf(target_win)), ":p")
      local user_moved_away = last_followed_abs ~= nil and cur ~= last_followed_abs
      if not user_moved_away then
        -- Route through the shared opener with focus = false: hands-off follow
        -- (position + center the changed line without stealing the cursor from
        -- the chat). The write-follow *policy* — the user_moved_away gate above
        -- — stays here; target.open owns only the window mechanics.
        require("emeth.target").open({
          path = first_path.abs,
          line = first_path.line,
          win = target_win,
          focus = false,
        })
        -- Record the name the buffer actually ended up with (nvim canonicalizes
        -- it -- e.g. resolves the /tmp -> /private/tmp symlink on macOS), so the
        -- next flush's `cur` comparison is apples-to-apples and we don't mistake
        -- our own navigation for the user moving away.
        last_followed_abs = vim.fn.fnamemodify(vim.api.nvim_buf_get_name(vim.api.nvim_win_get_buf(target_win)), ":p")
      end
    end
    pending_reloads = {}
  end

  local reload_debounce = util.debounce(1000, flush_reloads)
  ---@param path string
  ---@param first_changed? integer  the line to center when following
  ---@param no_follow? boolean  reload an open buffer but never steer the pane (subagent writes)
  local function schedule_reload(path, first_changed, no_follow)
    local rec = pending_reloads[path] or { follow = false }
    rec.line = first_changed or rec.line
    -- Once any write to this path is follow-eligible it stays so: a subagent and
    -- the main agent may both touch it, and the main agent's write should follow.
    rec.follow = rec.follow or not no_follow
    pending_reloads[path] = rec
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
  -- Outstanding `session/prompt` requests. Counted separately from `activity`
  -- because a cancel invalidates the prompt's callback (epoch) without the
  -- request itself being answered yet. Zero means any streaming is unsolicited.
  local prompts_in_flight = 0
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
    stream = new_stream()
  end

  local function refresh_file_display()
    view:set_context_files(selected_files)
  end

  -- ── Lifecycle wrapper ──────────────────────────────────────────

  ---@class acp.LifecycleOpts
  ---@field clear? boolean
  ---@field touch? boolean
  ---@field kind? "new"|"load"

  ---Run a session lifecycle action with standard boilerplate.
  ---@param opts acp.LifecycleOpts
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
    if prompts then
      prompts.cancel()
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

  ---Upsert this session's index entry. The cwd is the session's bound one, not
  ---nvim's current one: they differ once the user has :cd'd away, and the index
  ---must point at the directory the transcript actually lives in (the same
  ---source the fork/load requests use). A fork or rewind passes its parent.
  ---@param id string
  ---@param forked_from? string
  local function save_entry(id, forked_from)
    Sessions.save({
      session_id = id,
      provider = session.provider_name,
      cwd = session.cwd or vim.fn.getcwd(),
      additional_directories = roots:save_field(),
      forked_from = forked_from,
    })
  end

  ---Enter this session in the local index, keyed on its first prompt.
  ---
  ---Deliberately not at connect time: connecting is what `:Emeth` does on open,
  ---so recording there entered a session for every sidebar the user opened and
  ---closed without saying anything. Those have no conversation to resume into and
  ---the agent never persists them, yet they filled the session list -- 45 of 352
  ---entries, none of them useful. A session earns an entry by being used.
  ---
  ---Safe to call per prompt: `Sessions.save` upserts on `session_id` and bumps
  ---`updated_at`, which is what the old `touch` call here did anyway. It leaves
  ---`cwd` at its insert-time value, so the recorded directory stays the one the
  ---session actually ran in.
  ---@param first_text string  fallback title, until the agent sends a real one
  local function record_session(first_text)
    local id = session.session_id
    if not id then
      return
    end
    save_entry(id)
    local entry = Sessions.get(id)
    if entry and not entry.title then
      Sessions.update_title(id, first_text:sub(1, 80):gsub("\n", " "))
    end
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
      model = exts.model_id,
      mode = exts.mode_id,
      badges = Winbar.get_badges(),
    })
    view:add_message(msg)
    record_session(text)
    return msg
  end

  ---Start a fresh turn and own its completion.
  ---@param prompt table[]
  local function start_turn(prompt)
    reset_state()
    Winbar.clear_mode_tag()
    local token = begin("generating")
    prompts_in_flight = prompts_in_flight + 1
    session:send_prompt(prompt, function(_, err)
      vim.schedule(function()
        prompts_in_flight = math.max(0, prompts_in_flight - 1)
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
  end

  view.on_submit = function(text)
    -- A prompt may have claimed the next submission (a free-text elicitation
    -- answer). It reuses the input box rather than a modal prompt so the user
    -- gets normal editing — multiline, paste folding — and nothing steals focus.
    if prompts and prompts.take_submit(text) then
      return
    end

    -- Steering: while a turn is running, deliver the message *into* it instead
    -- of refusing the submit. Note this deliberately does NOT call begin() — the
    -- in-flight session/prompt still owns settling the activity state, and
    -- bumping the epoch would invalidate its callback, stranding the winbar in
    -- "generating" forever.
    if session:is_connected() and activity == "generating" and steering_supported() then
      local strat = assert(steering) -- steering_supported() implies it
      local prompt = build_prompt(text)
      local msg = add_user_message(text)
      -- Close the text/thought blocks the turn was streaming into. They sit
      -- ABOVE the message we just appended, so leaving them open sends the
      -- agent's reply to the steer into a block that renders before the prompt
      -- that caused it -- the transcript then reads as if the steer were never
      -- answered, which is exactly what a glance at the tail is checking for.
      -- Only the anchors: `tool_map` stays, since tool calls already in flight
      -- must keep resolving to their own rows, and `plan_uuid` re-displays
      -- itself once it is no longer the last block.
      stream.assistant_uuid = nil
      stream.thinking_uuid = nil
      strat.steer(prompt, text, function(outcome, err, info)
        vim.schedule(function()
          if err then
            view:add_message(Message:new("system", "Error: " .. util.fmt_err(err)))
            return
          end
          -- The turn finished between our check and the request landing. The
          -- agent left the content untouched precisely so we can send it as a
          -- normal prompt whose lifecycle we own. (claude only — kiro never
          -- reports this; it queues instead, see below.)
          if outcome == "promptRequired" then
            start_turn(prompt)
            return
          end
          -- Queued (kiro): accepted into the agent's queue but not yet injected.
          -- It will be injected at the next inference boundary — within this turn
          -- if one is still running, otherwise not until the next prompt. The
          -- provider's own steering lifecycle flips it to "steered" (keyed by the
          -- message id) or "not delivered" if the turn ends without injecting it.
          if outcome == "queued" then
            view:update_message(msg.uuid, function(m)
              m.metadata.steer_state = "queued"
              m.metadata.steer_message_id = info and info.message_id or nil
            end)
            return
          end
          -- Injected (claude): confirmed into the running turn. Mark it only now
          -- that the agent confirmed — marking at submit time would claim a steer
          -- for the `promptRequired` race, which is an ordinary turn.
          view:update_message(msg.uuid, function(m)
            m.metadata.steer_state = "steered"
          end)
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

  -- Reconcile a fresh `configOptions` snapshot into session state: re-store the
  -- options (via _extract_session_info, which also mirrors the model/mode
  -- options into model_id/mode_id) and re-register the slash commands so newly available options (e.g.
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

  local update_handlers = AcpUpdates.handlers({
    view = view,
    session = session,
    schedule_tool_render = schedule_tool_render,
    schedule_reload = schedule_reload,
    reconcile_config_options = reconcile_config_options,
    -- Wrapped, not passed: `render_mode` is only assigned further down this
    -- function, so a direct reference would capture nil here. Handing over a
    -- closure defers the lookup to when an update actually arrives. Collapsing
    -- this to `render_mode = render_mode` breaks the mode badge silently — the
    -- resulting nil call happens inside vim.schedule, which swallows it. The
    -- current_mode_update tests exist to catch exactly that.
    render_mode = function(mode_id)
      render_mode(mode_id)
    end,
  })

  session:on("update", function(update, update_session_id)
    -- Provider extensions may rewrite the update in-place (e.g. enrich a
    -- tool_call's title) before we consume it. Keep this lightweight —
    -- transforms run on every event.
    if transform_update_fn then
      -- A transform may also DROP an update by returning false (e.g. kiro's
      -- empty replay boundary chunk, which would otherwise render as a blank
      -- user message).
      local ok, keep = pcall(transform_update_fn, update)
      if ok and keep == false then
        return
      end
    end

    -- A subagent shows only as the tool calls it makes, nested under the call
    -- that spawned it; its own prose (sent as thought chunks), prompt and plans
    -- stay out of the transcript. It also never drives the winbar: a background
    -- subagent can keep reporting after the main turn ended.
    local from_subagent = update_session_id ~= nil and stream.subagents[update_session_id] ~= nil
    if from_subagent and not AcpUpdates.SUBAGENT_DISPATCHED[update.sessionUpdate] then
      return
    end

    -- Update-driven activity transition: streaming content → generating.
    -- connecting/cancelled absorb updates (stay put); only idle transitions.
    -- Replayed history (session/load) must not flip us to generating — the
    -- transform marks it `update.replay`.
    if
      not from_subagent
      and not AcpUpdates.NON_STREAMING[update.sessionUpdate]
      and activity == "idle"
      and not update.replay
    then
      set_activity("generating")
    end

    -- ...and the matching exit. An unsolicited turn (claude-acp: one Claude Code
    -- starts with no prompt open, e.g. to answer a background-task notification)
    -- has no `session/prompt` response to settle it, so the flip above would
    -- strand the winbar in "generating". Its end is the turn result's
    -- `usage_update` -- the only one that carries `cost` -- which the agent sends
    -- after the turn's last chunk, cancelled or not. With a prompt in flight the
    -- response owns settling, so this stays out of the way.
    if
      not from_subagent
      and update.sessionUpdate == "usage_update"
      and type(update.cost) == "table"
      and prompts_in_flight == 0
      and (activity == "generating" or activity == "cancelled")
    then
      set_activity("idle")
    end

    local handler = update_handlers[update.sessionUpdate]
    if handler then
      handler(update, stream, update_session_id)
    end
  end)

  -- ── Cancel one subagent (C) ──────────────────────────────────
  -- A subagent runs as its own child session (ACP subagents RFD). `C` on its
  -- card stops just that child, leaving the main turn running. Gated to a card
  -- whose child is still live and advertised `cancel`, so it is absent on a
  -- finished subagent and on ordinary tool calls. Capital, so it reads as
  -- deliberate.
  view:add_action({
    key = "C",
    hint = "C: cancel subagent",
    when = function(m)
      local meta = m.metadata
      return meta ~= nil
        and meta.subagent_session_id ~= nil
        and meta.subagent_cancellable == true
        and (meta.subagent_state == "running" or meta.subagent_state == "requires_action")
    end,
    run = function(m)
      session:cancel(m.metadata.subagent_session_id)
      local title = m.metadata.tool_call and m.metadata.tool_call.title
      view:add_message(Message:new("system", "⏹ Cancelled subagent" .. (title and (": " .. title) or "")))
    end,
  })

  prompts = AcpPrompts.attach({
    view = view,
    session = session,
    get_stream = function()
      return stream
    end,
    get_transform_elicitation = function()
      return transform_elicitation_fn
    end,
  })

  session:on("file_written", function(path, first_changed)
    schedule_reload(path, first_changed)
  end)

  -- The per-session setters an extension calls *during* setup, before the real
  -- `integration` table exists (it's built below). The real table carries the
  -- same functions, so a provider's cleanup can clear its hooks at disconnect.
  local ext_integration = {
    ---Register a function that mutates session/update payloads in place
    ---before the integration consumes them (return false to drop). nil clears.
    ---@param fn fun(update: table): boolean|nil
    set_transform_update = function(fn)
      transform_update_fn = fn
    end,
    ---Register a function that enriches parsed elicitation fields before they
    ---are rendered, returning the list to use. nil clears.
    ---@param fn fun(fields: acp.ElicitationField[], request: table): acp.ElicitationField[]|nil
    set_transform_elicitation = function(fn)
      transform_elicitation_fn = fn
    end,
    ---Install the provider's steering strategy (`{ supported, steer }`). nil clears.
    set_steering = function(s)
      steering = s
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
  ---provider extension what meta it wants to attach. `kind` ("new"|"load") lets
  ---the extension distinguish a fresh session from a resumed one — e.g. kiro
  ---applies its default `modeId` only to new sessions, so resuming keeps the
  ---mode the session already had.
  ---@param kind "new"|"load"
  ---@return table|nil
  local function build_session_meta(kind)
    if has_ext and type(ext.build_session_meta) == "function" then
      local emeth_config = require("emeth").config
      local ok, meta = pcall(ext.build_session_meta, emeth_config, kind)
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

  -- ── Session config options (model / mode / effort / ultracode ...) ──
  -- These ride the standard ACP `configOptions` + `session/set_config_option`
  -- channel, which both claude-acp and kiro-cli's v3 engine use. Generic: we
  -- register one slash command per option the agent exposes and drive it
  -- through a single picker, so no option id is hard-coded.

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
  ---@param kind "new"|"load"
  local function lifecycle_opts(kind)
    local opts = {}
    local snap = roots:snapshot()
    if #snap > 0 then
      opts.additional_directories = snap
    end
    local meta = build_session_meta(kind)
    if meta then
      opts.meta = meta
    end
    return next(opts) and opts or nil
  end

  ---Run a session lifecycle method through with_lifecycle, applying the
  ---shared post-ready fixups (render any reported mode) on success. `run`
  ---receives (opts, done) and calls the session method.
  ---@param wl_opts acp.LifecycleOpts
  ---@param run fun(opts: table|nil, done: fun(err: any))
  ---@param cb? fun(err: any)
  local function lifecycle(wl_opts, run, cb)
    with_lifecycle(wl_opts, function(done)
      run(lifecycle_opts(wl_opts.kind or "new"), function(err)
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
      lifecycle({}, function(opts, done)
        session:connect(opts, function(err)
          if not err then
            announce_session("Connected to " .. session.provider_name .. ".")
          end
          done(err)
        end)
      end, cb)
    end,

    load_session = function(session_id, cb)
      -- Release the session we're leaving before loading another over the same
      -- live client (best-effort; keeps its history). connect_and_load starts a
      -- fresh process, so it has nothing to close.
      if session.session_id and session.session_id ~= session_id then
        session:close(session.session_id)
      end
      -- Hydrate roots from the persisted session entry before re-loading
      roots:hydrate_from(Sessions.get(session_id))
      lifecycle({ clear = true, touch = true, kind = "load" }, function(opts, done)
        session:load(session_id, opts, function(err)
          if not err then
            announce_session("Session loaded.")
          end
          done(err)
        end)
      end, cb)
    end,

    connect_and_load = function(session_id, cb)
      roots:hydrate_from(Sessions.get(session_id))
      -- Carried past lifecycle (which forwards only `err`) so the caller can
      -- tell a failed agent start from an unknown session id.
      local failed_stage
      lifecycle({ touch = true, kind = "load" }, function(opts, done)
        session:connect_and_load(session_id, opts, function(err, stage)
          failed_stage = stage
          if not err then
            announce_session("Connected to " .. session.provider_name .. ".")
          end
          done(err)
        end)
      end, cb and function(err)
        cb(err, failed_stage)
      end)
    end,

    new_session = function()
      -- Release the session we're leaving (live client is reused). Best-effort.
      if session.session_id then
        session:close(session.session_id)
      end
      view:clear()
      reset_state()
      selected_files = {}
      refresh_file_display()
      -- Keep roots as-is so a new session inherits the user's roots.
      lifecycle({}, function(opts, done)
        session:new_session(opts, function(err)
          if not err then
            announce_session("New session started.")
          end
          done(err)
        end)
      end)
    end,

    ---Fork the current session into a new branch and adopt it. A whole-session
    ---clone, so the on-screen transcript is the shared history and is kept, not
    ---cleared. Uses `kind = "load"` so a configured default mode doesn't override
    ---the forked state. An agent that doesn't support fork surfaces the error in
    ---the transcript.
    fork = function(cb)
      local parent = session.session_id
      lifecycle({ kind = "load" }, function(opts, done)
        session:fork(opts, function(err)
          if not err then
            -- Record the fork eagerly (unlike the lazy first-prompt record): it
            -- is a deliberate branch, and capturing `forked_from` now is the only
            -- moment the parent id is known. Chains nest naturally — each fork
            -- points at its direct parent.
            if session.session_id then
              save_entry(session.session_id, parent)
            end
            announce_session("Forked session.")
          end
          done(err)
        end)
      end, cb)
    end,

    ---Rewind: fork the current session at a provider-targeted point (`meta` rides
    ---on the fork request's `_meta`), then rebuild the transcript from the fork's
    ---truncated replay. Generic — the meaning of `meta` is the provider's (kiro
    ---passes `{ kiro = { messageId = … } }`).
    ---@param meta table
    ---@param cb? fun(err: any)
    rewind = function(meta, cb)
      local parent = session.session_id
      lifecycle({ kind = "load" }, function(opts, done)
        opts = opts or {}
        opts.meta = vim.tbl_deep_extend("force", opts.meta or {}, meta or {})
        session:fork(opts, function(err)
          if err then
            done(err)
            return
          end
          local fork_id = session.session_id
          if not fork_id then
            done(nil)
            return
          end
          save_entry(fork_id, parent)
          -- Rebuild from the fork's truncated replay. Cleared only now, so the
          -- old transcript stays up until the replay is ready (no empty gap).
          vim.schedule(function()
            view:clear()
            reset_state()
            session:load(fork_id, lifecycle_opts("load"), function(err2)
              if not err2 then
                announce_session("↩ Rewound (forked at the selected message).")
              end
              done(err2)
            end)
          end)
        end)
      end, cb)
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

    ---Re-assert what the winbar caches. It is only written on transitions, so one
    ---that missed a change would otherwise stay wrong for the rest of the turn.
    resync_winbar = function()
      Winbar.set_left(Winbar.fmt.plain(session.provider_name))
      set_activity(activity)
    end,
  }
  for k, v in pairs(ext_integration) do
    integration[k] = v
  end

  view.integration = integration
  return integration
end

return M
