--- Session lifecycle tests for `emeth.integrations.acp`: connect/abort, cancel,
--- steering, buffer reloads, session config options (/model etc.) and the
--- session-id announcements at each boundary.

local h = require("tests.helpers")
local H = require("tests.acp_harness")
local Session = require("emeth.acp.session")
local Acp = require("emeth.integrations.acp")
local Winbar = H.winbar()
local make_view = H.make_view
local make_setup = H.setup
local flush = H.flush
local press = H.press

-- Global stubs; released at the bottom of this file.
local restore = H.install()

h.describe("acp integration: abort stuck connect", function()
  h.it("Ctrl+C during a pending handshake tears down and messages the user", function()
    local session = Session:new("test")
    local view = make_view()
    local integration = Acp.setup_integration(view, session)

    -- Simulate a handshake that never completes (e.g. a launcher running
    -- updates before it execs the agent): connect() never calls back, so
    -- activity stays "connecting".
    session.connect = function() end
    local disconnected = false
    session.disconnect = function()
      disconnected = true
    end

    integration.connect()

    -- <C-c> is bound to do_cancel; pressing it should abort the connect.
    h.is_true(press("<C-c>"), "C-c keymap should be bound")
    h.is_true(disconnected, "session should be torn down on abort")
    local last = view.messages[#view.messages]
    h.is_true(last:text():find("aborted", 1, true) ~= nil, "should report the abort to the user")
  end)

  h.it("Ctrl+C does nothing when idle and connected", function()
    local session, view = make_setup() -- _state = "ready", activity = "idle"
    local before = #view.messages
    press("<C-c>")
    h.eq(before, #view.messages)
  end)
end)

h.describe("acp integration: cancel during auto-resumed streaming", function()
  -- Reproduces: claude auto-resumes a session — session/prompt callback has
  -- fired (activity → idle), then updates start streaming again on the same
  -- session (activity → generating). Cancel must still work.
  h.it("Ctrl+C cancels when updates stream while session state is ready", function()
    local session, view = make_setup() -- _state = "ready"
    local cancelled = false
    session.cancel = function()
      cancelled = true
    end

    -- Streaming resumes with no prompt in flight.
    session:_emit("update", { sessionUpdate = "agent_message_chunk", content = { type = "text", text = "resumed" } })

    h.is_true(press("<C-c>"), "C-c keymap should be bound")
    h.is_true(cancelled, "session:cancel() must fire when activity is generating")
    local last = view.messages[#view.messages]
    h.is_true(last:text():find("cancelled", 1, true) ~= nil, "should report the cancel")
  end)

  h.it("Ctrl+C stays a no-op when idle and nothing is streaming", function()
    local session, view = make_setup()
    local cancelled = false
    session.cancel = function()
      cancelled = true
    end
    local before = #view.messages
    press("<C-c>")
    h.is_true(not cancelled, "no cancel when idle")
    h.eq(before, #view.messages)
  end)

  h.it("metadata-only updates do not arm cancel", function()
    local session, view = make_setup()
    local cancelled = false
    session.cancel = function()
      cancelled = true
    end
    session:_emit("update", { sessionUpdate = "usage_update", used = 10, size = 100 })
    flush()
    local before = #view.messages
    press("<C-c>")
    h.is_true(not cancelled, "usage_update alone must not arm cancel")
    h.eq(before, #view.messages)
  end)

  h.it("trailing updates after cancel do not re-arm cancel", function()
    local session, view = make_setup()
    local cancel_count = 0
    session.cancel = function()
      cancel_count = cancel_count + 1
    end

    session:_emit("update", { sessionUpdate = "agent_message_chunk", content = { type = "text", text = "x" } })
    press("<C-c>")
    h.eq(1, cancel_count)

    -- Trailing chunk arrives after the cancel; a second C-c must be a no-op.
    session:_emit("update", { sessionUpdate = "agent_message_chunk", content = { type = "text", text = "tail" } })
    local before = #view.messages
    press("<C-c>")
    h.eq(1, cancel_count, "trailing updates must not re-arm cancel")
    h.eq(before, #view.messages)
  end)
end)

h.describe("acp integration: slow-connect nudge", function()
  h.it("posts a nudge if the handshake is still pending after the threshold", function()
    local emeth = require("emeth")
    local prev = emeth.config.slow_connect_ms
    emeth.config.slow_connect_ms = 10 -- fire almost immediately

    local session = Session:new("test")
    local view = make_view()
    local integration = Acp.setup_integration(view, session)
    session.connect = function() end -- never completes → activity stays "connecting"

    integration.connect()
    vim.wait(200, function()
      local last = view.messages[#view.messages]
      return last and last:text():find("Taking longer", 1, true) ~= nil
    end)

    local last = view.messages[#view.messages]
    h.is_true(last and last:text():find("Taking longer", 1, true) ~= nil, "nudge should post")
    h.is_true(last:text():find("<C-c>", 1, true) ~= nil, "nudge should point at the abort")

    emeth.config.slow_connect_ms = prev
  end)

  h.it("does not nudge once the connect has completed", function()
    local emeth = require("emeth")
    local prev = emeth.config.slow_connect_ms
    emeth.config.slow_connect_ms = 10

    local session = Session:new("test")
    local view = make_view()
    local integration = Acp.setup_integration(view, session)
    -- Completes synchronously: done(nil) bumps epoch before the timer fires.
    -- Called as session:connect(opts, cb) → (self, opts, cb).
    session.connect = function(_self, _opts, cb)
      cb(nil)
    end
    session.session_id = "sess-1"

    integration.connect()
    vim.wait(100)

    for _, m in ipairs(view.messages) do
      h.is_true(m:text():find("Taking longer", 1, true) == nil, "no nudge after completion")
    end

    emeth.config.slow_connect_ms = prev
  end)

  h.it("is disabled when slow_connect_ms is 0", function()
    local emeth = require("emeth")
    local prev = emeth.config.slow_connect_ms
    emeth.config.slow_connect_ms = 0

    local session = Session:new("test")
    local view = make_view()
    local integration = Acp.setup_integration(view, session)
    session.connect = function() end

    integration.connect()
    vim.wait(100)

    for _, m in ipairs(view.messages) do
      h.is_true(m:text():find("Taking longer", 1, true) == nil, "no nudge when disabled")
    end

    emeth.config.slow_connect_ms = prev
  end)
end)

h.describe("acp integration: buffer reload focus", function()
  h.it("shows the edited file in the source window without stealing focus from emeth", function()
    local session = Session:new("test")
    session._state = "ready"
    session.session_id = "sess-1"
    local view = make_view()
    Acp.setup_integration(view, session)

    -- A real file the "agent" wrote, with enough lines to jump to.
    local tmp = vim.fn.tempname() .. ".txt"
    local lines = {}
    for i = 1, 20 do
      lines[i] = "line " .. i
    end
    vim.fn.writefile(lines, tmp)

    -- Two real windows: source (normal buffer) + emeth (named emeth://…).
    -- find_source_win picks the non-emeth one; the user sits in the emeth one.
    vim.cmd("only")
    local source_win = vim.api.nvim_get_current_win()
    vim.cmd("vsplit")
    local emeth_win = vim.api.nvim_get_current_win()
    local emeth_buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_name(emeth_buf, "emeth://test-chat")
    vim.api.nvim_win_set_buf(emeth_win, emeth_buf)
    h.is_true(source_win ~= emeth_win, "need two distinct windows")

    -- Agent writes the file while the user's cursor is in the emeth window.
    -- Resolve via uv.fs_realpath so /tmp symlink on macOS (/private/tmp) matches.
    local abs_tmp = vim.uv.fs_realpath(tmp) or vim.fn.fnamemodify(tmp, ":p")
    session:_emit("file_written", tmp, 12)

    -- Wait out the 1s reload debounce + the scheduled cursor positioning.
    -- Check both that the buffer shows the file AND cursor hit line 12.
    local ok = vim.wait(5000, function()
      if not vim.api.nvim_win_is_valid(source_win) then
        return false
      end
      local buf = vim.api.nvim_win_get_buf(source_win)
      local buf_name = vim.api.nvim_buf_get_name(buf)
      if buf_name ~= abs_tmp then
        return false
      end
      return vim.api.nvim_win_get_cursor(source_win)[1] == 12
    end, 20)

    h.is_true(ok, "source window should show the edited file at the changed line")
    h.eq(emeth_win, vim.api.nvim_get_current_win(), "focus must stay in the emeth window")

    -- Cleanup
    vim.cmd("only")
    pcall(vim.api.nvim_buf_delete, emeth_buf, { force = true })
    vim.fn.delete(tmp)
  end)
end)

h.describe("acp integration: session config options (/model etc.)", function()
  local Commands = require("emeth.commands")

  -- Stub vim.ui.select to auto-pick by predicate; returns what was offered.
  local _orig_select = vim.ui.select
  local function with_select(pick, body)
    local offered
    vim.ui.select = function(items, _opts, on_choice)
      offered = items
      on_choice(pick(items))
    end
    local ok, err = pcall(body, function()
      return offered
    end)
    vim.ui.select = _orig_select
    if not ok then
      error(err)
    end
  end

  local MODEL_OPT = {
    id = "model",
    type = "select",
    name = "Model",
    description = "AI model to use",
    currentValue = "opus",
    options = {
      { value = "opus", name = "Opus", description = "big" },
      { value = "sonnet", name = "Sonnet", description = "fast" },
    },
  }

  h.it("registers a /model command from a config_option_update snapshot", function()
    Commands.clear_config()
    local session = make_setup()
    session:_emit("update", { sessionUpdate = "config_option_update", configOptions = { MODEL_OPT } })
    flush()
    local cmd = Commands.get("model")
    h.is_true(cmd ~= nil, "/model should be registered")
    h.eq("config", cmd.source)
    h.is_true(cmd.has_picker == true)
    Commands.clear_config()
  end)

  h.it("picking a different model sets it and reconciles the response snapshot", function()
    Commands.clear_config()
    local session, view = make_setup()
    local sent
    -- Mimic the wrapper: return the updated configOptions in the response
    -- (it does NOT push config_option_update for a user-initiated switch).
    session.set_config_option = function(_, config_id, value, cb)
      sent = { config_id = config_id, value = value }
      cb({
        configOptions = {
          {
            id = "model",
            type = "select",
            currentValue = value,
            options = MODEL_OPT.options,
          },
        },
      }, nil)
    end
    session:_emit("update", { sessionUpdate = "config_option_update", configOptions = { MODEL_OPT } })
    flush()

    with_select(function(items)
      for _, it in ipairs(items) do
        if it.value == "sonnet" then
          return it
        end
      end
    end, function()
      Commands.get("model").execute("", { view = view, integration = view.integration })
    end)
    flush()

    h.eq("model", sent.config_id)
    h.eq("sonnet", sent.value)
    -- The response snapshot must land in session state so the prompt's
    -- `model:` detail and the winbar badge reflect the switch.
    h.eq("sonnet", session.extensions.config_options.model.currentValue)
    h.eq("sonnet", session.extensions.model_id)
    Commands.clear_config()
  end)

  h.it("selecting the current value is a no-op (no request)", function()
    Commands.clear_config()
    local session, view = make_setup()
    local called = false
    session.set_config_option = function()
      called = true
    end
    session:_emit("update", { sessionUpdate = "config_option_update", configOptions = { MODEL_OPT } })
    flush()

    with_select(function(items)
      for _, it in ipairs(items) do
        if it.value == "opus" then -- currentValue
          return it
        end
      end
    end, function()
      Commands.get("model").execute("", { view = view, integration = view.integration })
    end)

    h.is_true(not called, "re-selecting the current model must not send a request")
    Commands.clear_config()
  end)

  h.it("a forwarded ACP /model does not override the config-sourced one", function()
    Commands.clear_config()
    local session, view = make_setup()
    session:_emit("update", { sessionUpdate = "config_option_update", configOptions = { MODEL_OPT } })
    flush()
    -- Agent later forwards its own /model slash command.
    session:_emit("update", {
      sessionUpdate = "available_commands_update",
      availableCommands = { { name = "/model", description = "server model" } },
    })
    local cmd = Commands.get("model")
    h.eq("config", cmd.source, "config command stays authoritative for /model")
    h.is_true(cmd.has_picker == true)
    Commands.clear_config()
    Commands.clear_acp()
  end)

  h.it("renders provider · model in the winbar left segment and updates on switch", function()
    Commands.clear_config()
    -- Capture set_left for this test only, then restore the stub.
    local left
    local stub = Winbar.set_left
    Winbar.set_left = function(_, plain)
      left = plain
    end

    local session, view = make_setup()
    session.extensions = { model_id = "opus" }
    session.set_config_option = function(_, _config_id, value, cb)
      cb(
        { configOptions = { { id = "model", type = "select", currentValue = value, options = MODEL_OPT.options } } },
        nil
      )
    end
    -- Seed the picker options + render the initial left segment.
    session:_emit("update", { sessionUpdate = "config_option_update", configOptions = { MODEL_OPT } })
    flush()
    h.is_true(left ~= nil and left:find("test", 1, true) ~= nil, "left shows provider")
    h.is_true(left:find("opus", 1, true) ~= nil, "left shows initial model")

    with_select(function(items)
      for _, it in ipairs(items) do
        if it.value == "sonnet" then
          return it
        end
      end
    end, function()
      Commands.get("model").execute("", { view = view, integration = view.integration })
    end)
    flush()
    h.is_true(left:find("sonnet", 1, true) ~= nil, "left updates to switched model")

    Winbar.set_left = stub
    Commands.clear_config()
  end)

  h.it("shortens an over-long model id generically (last dotted segment)", function()
    Commands.clear_config()
    local left
    local stub = Winbar.set_left
    Winbar.set_left = function(_, plain)
      left = plain
    end

    -- The `test` provider has no format_model hook, so this exercises the
    -- generic core fallback directly on a Bedrock-style id.
    local LONG = "global.anthropic.claude-opus-4-8[1m]"
    local session = make_setup()
    session.extensions = { model_id = LONG }
    session:_emit("update", {
      sessionUpdate = "config_option_update",
      configOptions = { { id = "model", type = "select", currentValue = LONG, options = {} } },
    })
    flush()

    h.is_true(left:find("test", 1, true) ~= nil, "left still shows provider")
    -- Collapsed to the last dot-separated segment, dotted prefix dropped.
    h.is_true(left:find("claude-opus-4-8[1m]", 1, true) ~= nil, "shows last dotted segment")
    h.is_true(left:find("global.anthropic", 1, true) == nil, "drops the dotted prefix")

    Winbar.set_left = stub
    Commands.clear_config()
  end)

  h.it("disconnect clears config commands", function()
    Commands.clear_config()
    local session, _, integration = make_setup()
    session:_emit("update", { sessionUpdate = "config_option_update", configOptions = { MODEL_OPT } })
    flush()
    h.is_true(Commands.get("model") ~= nil)
    integration.disconnect()
    h.is_nil(Commands.get("model"))
  end)
end)

h.describe("acp integration: steering", function()
  --- A session whose agent supports steering, with the wire call captured.
  local function steer_setup(supported)
    local session, view, integration = make_setup()
    local calls = {} ---@type { prompt: table[], cb: fun(outcome: string|nil, err: table|nil) }[]
    session.client.agent_meta = supported and { steering = { supported = true } } or nil
    -- Stub at the client boundary: the wire format is covered by the client
    -- tests, what matters here is which path the integration chooses.
    session.client.steer = function(_, _sid, prompt, cb)
      calls[#calls + 1] = { prompt = prompt, cb = cb }
    end
    local prompts = {} ---@type table[][]
    session.client.send_prompt = function(_, _sid, prompt, _cb)
      prompts[#prompts + 1] = prompt
    end
    return session, view, integration, calls, prompts
  end

  h.it("steers instead of refusing when a turn is running", function()
    local _, view, _, calls, prompts = steer_setup(true)
    view.on_submit("first")
    h.eq(1, #prompts, "the first submit starts a normal turn")
    view.on_submit("actually use tabs")
    h.eq(1, #calls, "the second submit steers")
    h.eq("actually use tabs", calls[1].prompt[1].text)
    h.eq(1, #prompts, "and does not start a second turn")
  end)

  h.it("renders the steered message as a user turn", function()
    local _, view = steer_setup(true)
    view.on_submit("first")
    view.on_submit("and also this")
    local last = view.messages[#view.messages]
    h.eq("user", last.role)
    h.eq("and also this", last:text())
  end)

  -- The in-flight session/prompt callback still owns settling the activity
  -- state. Bumping the epoch (as begin() does) would invalidate it and strand
  -- the winbar in "generating" forever.
  h.it("leaves the running turn owning completion, so it still settles", function()
    -- Record winbar states for this test only; the module-level stub swallows them.
    local states = {}
    local prev = Winbar.set_state
    Winbar.set_state = function(s)
      states[#states + 1] = s
    end

    local session, view, _, calls = steer_setup(true)
    local captured
    session.client.send_prompt = function(_, _sid, _prompt, cb)
      captured = cb
    end
    view.on_submit("first")
    h.eq("generating", states[#states])

    local n = #states
    view.on_submit("steered")
    h.eq(1, #calls)
    h.eq(n, #states, "steering must not re-enter a generating phase")

    -- The original turn finishing must still return the UI to ready. If the
    -- steer had bumped the epoch, this callback would be ignored as stale.
    captured(nil, nil)
    vim.wait(20)
    h.eq("ready", states[#states], "the original turn must still settle the UI")

    Winbar.set_state = prev
  end)

  h.it("falls back to a normal prompt when the turn already ended", function()
    local _, view, _, calls, prompts = steer_setup(true)
    view.on_submit("first")
    view.on_submit("steered")
    h.eq(1, #calls)
    -- The agent found no running turn and left the content alone.
    calls[1].cb("promptRequired", nil)
    vim.wait(20)
    h.eq(2, #prompts, "the steered content must be sent as its own turn")
    h.eq("steered", prompts[2][1].text)
  end)

  h.it("does not re-send when the steer was injected", function()
    local _, view, _, calls, prompts = steer_setup(true)
    view.on_submit("first")
    view.on_submit("steered")
    calls[1].cb("injected", nil)
    vim.wait(20)
    h.eq(1, #prompts, "injected content is already in the running turn")
  end)

  h.it("reports a steer error in the transcript", function()
    local _, view, _, calls = steer_setup(true)
    view.on_submit("first")
    view.on_submit("steered")
    calls[1].cb(nil, { code = -32000, message = "session ended" })
    vim.wait(20)
    local last = view.messages[#view.messages]
    h.is_true(last:text():find("session ended", 1, true) ~= nil)
  end)

  h.it("still refuses mid-turn input when the agent has no steering support", function()
    local _, view, _, calls, prompts = steer_setup(false)
    view.on_submit("first")
    local before = #view.messages
    view.on_submit("second")
    h.eq(0, #calls, "must not steer an agent that never advertised it")
    h.eq(1, #prompts)
    h.eq(before, #view.messages, "the refused submit adds no user message")
  end)

  h.it("sends a normal prompt when idle even though steering is supported", function()
    local _, view, _, calls, prompts = steer_setup(true)
    view.on_submit("only")
    h.eq(0, #calls)
    h.eq(1, #prompts)
  end)

  h.it("marks the message as steered once the agent confirms the injection", function()
    local _, view, _, calls = steer_setup(true)
    view.on_submit("first")
    view.on_submit("steered")
    local msg = view.messages[#view.messages]
    h.is_nil(msg.metadata.steered, "not claimed before the outcome is known")
    calls[1].cb("injected", nil)
    vim.wait(20)
    h.eq(true, msg.metadata.steered)
  end)

  -- The marker must not lie: promptRequired means the turn had already ended and
  -- the content went out as an ordinary prompt.
  h.it("does not mark it when the steer became a normal prompt", function()
    local _, view, _, calls = steer_setup(true)
    view.on_submit("first")
    view.on_submit("steered")
    local msg = view.messages[#view.messages]
    calls[1].cb("promptRequired", nil)
    vim.wait(20)
    h.is_nil(msg.metadata.steered)
  end)

  h.it("does not mark it when the steer failed", function()
    local _, view, _, calls = steer_setup(true)
    view.on_submit("first")
    view.on_submit("steered")
    local msg = view.messages[#view.messages]
    calls[1].cb(nil, { code = -32000, message = "session ended" })
    vim.wait(20)
    h.is_nil(msg.metadata.steered)
  end)

  h.it("leaves an ordinary prompt unmarked", function()
    local _, view = steer_setup(true)
    view.on_submit("only")
    h.is_nil(view.messages[#view.messages].metadata.steered)
  end)
end)

h.describe("acp integration: session id at every boundary", function()
  -- /new and load used to replace the session id while saying nothing about it,
  -- leaving no way to tell which session the transcript in front of you was.
  local function texts(view)
    local out = {}
    for _, m in ipairs(view.messages) do
      out[#out + 1] = m:text()
    end
    return table.concat(out, "\n")
  end

  h.it("names the session when a new one is started", function()
    local session, view = make_setup()
    session.client.create_session = function(_, _cwd, _mcp, _opts, cb)
      cb("sess-new", nil, {})
    end
    view.integration.new_session()
    vim.wait(50)
    h.is_true(texts(view):find("New session started", 1, true) ~= nil)
    h.is_true(texts(view):find("sess-new", 1, true) ~= nil, "the new id must be recorded")
  end)
end)

restore()
