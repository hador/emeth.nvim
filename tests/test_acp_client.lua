local h = require("tests.helpers")
local ACPClient = require("emeth.acp.client")

-- Silence capability-warning notifications surfaced via vim.schedule.
-- They fire after the originating tests have completed, so a per-test stub
-- doesn't help; suppress for the whole module instead.
local _orig_notify = vim.notify
vim.notify = function(msg, _)
  if type(msg) == "string" and msg:find("[emeth-acp]", 1, true) then
    return
  end
  return _orig_notify(msg)
end

--- Build a client with a no-op transport stub so no process is spawned.
---@param handlers table|nil
---@return acp.ACPClient, table
local function make_client(handlers)
  local sent = {} -- captures transport:send() calls
  local client = setmetatable({
    id_counter = 0,
    protocol_version = 1,
    capabilities = {},
    agent_capabilities = nil,
    auth_methods = {},
    _log_file = nil,
    _log_path = nil,
    callbacks = {},
    transport = {
      send = function(_, data)
        sent[#sent + 1] = data
      end,
      start = function() end,
      stop = function() end,
    },
    config = { handlers = handlers or {} },
    state = "disconnected",
    reconnect_count = 0,
  }, { __index = ACPClient })
  return client, sent
end

-- ── _next_id ───────────────────────────────────────────────────

h.describe("ACPClient _next_id", function()
  h.it("increments monotonically", function()
    local c = make_client()
    h.eq(1, c:_next_id())
    h.eq(2, c:_next_id())
    h.eq(3, c:_next_id())
  end)
end)

-- ── _create_error ──────────────────────────────────────────────

h.describe("ACPClient _create_error", function()
  h.it("returns structured error", function()
    local c = make_client()
    local err = c:_create_error(-32600, "bad request", "extra")
    h.eq(-32600, err.code)
    h.eq("bad request", err.message)
    h.eq("extra", err.data)
  end)
end)

-- ── _handle_message dispatch ───────────────────────────────────

h.describe("ACPClient _handle_message", function()
  h.it("dispatches response to registered callback", function()
    local c = make_client()
    local got_result, got_err
    c.callbacks[1] = function(result, err)
      got_result = result
      got_err = err
    end
    c:_handle_message({ id = 1, result = { ok = true } })
    h.eq({ ok = true }, got_result)
    h.is_nil(got_err)
    -- callback should be cleaned up
    h.is_nil(c.callbacks[1])
  end)

  h.it("dispatches error response to callback", function()
    local c = make_client()
    local got_err
    c.callbacks[2] = function(_, err)
      got_err = err
    end
    c:_handle_message({ id = 2, error = { code = -1, message = "fail" } })
    h.eq(-1, got_err.code)
  end)

  h.it("ignores response with no matching callback", function()
    local c = make_client()
    -- should not error
    c:_handle_message({ id = 999, result = {} })
  end)

  h.it("routes notification to _handle_incoming", function()
    local c = make_client()
    local called = false
    c._handle_incoming = function(_, msg_id, method, params)
      called = true
      h.eq("test/event", method)
      h.eq({ foo = 1 }, params)
    end
    c:_handle_message({ method = "test/event", params = { foo = 1 } })
    h.is_true(called)
  end)
end)

-- ── _handle_session_update ─────────────────────────────────────

h.describe("ACPClient _handle_session_update", function()
  h.it("calls on_session_update handler with update payload", function()
    local received, received_sid
    local c = make_client({
      on_session_update = function(update, session_id)
        received = update
        received_sid = session_id
      end,
    })
    c:_handle_session_update({ sessionId = "s1", update = { title = "hi" } })
    h.eq({ title = "hi" }, received)
    h.eq("s1", received_sid)
  end)

  h.it("ignores when sessionId missing", function()
    local called = false
    local c = make_client({
      on_session_update = function()
        called = true
      end,
    })
    c:_handle_session_update({ update = { title = "hi" } })
    h.eq(false, called)
  end)

  h.it("ignores when update missing", function()
    local called = false
    local c = make_client({
      on_session_update = function()
        called = true
      end,
    })
    c:_handle_session_update({ sessionId = "s1" })
    h.eq(false, called)
  end)
end)

-- ── _handle_incoming routing ────────────────────────────────────

h.describe("ACPClient _handle_incoming routing", function()
  h.it("routes session/update to _handle_session_update", function()
    local c = make_client()
    local routed = false
    c._handle_session_update = function(_, params)
      routed = true
      h.eq("s1", params.sessionId)
    end
    c:_handle_incoming(nil, "session/update", { sessionId = "s1", update = {} })
    h.is_true(routed)
  end)

  h.it("routes session/request_permission only when message_id present", function()
    local c = make_client()
    local routed = false
    c._handle_request_permission = function()
      routed = true
    end
    -- no message_id → should NOT route
    c:_handle_incoming(nil, "session/request_permission", { sessionId = "s1", toolCall = {} })
    h.eq(false, routed)
    -- with message_id → should route
    c:_handle_incoming(42, "session/request_permission", { sessionId = "s1", toolCall = {} })
    h.is_true(routed)
  end)

  h.it("routes fs/read_text_file only when message_id present", function()
    local c = make_client()
    local routed = false
    c._handle_read_text_file = function()
      routed = true
    end
    c:_handle_incoming(nil, "fs/read_text_file", { sessionId = "s1", path = "/a" })
    h.eq(false, routed)
    c:_handle_incoming(10, "fs/read_text_file", { sessionId = "s1", path = "/a" })
    h.is_true(routed)
  end)

  h.it("routes fs/write_text_file only when message_id present", function()
    local c = make_client()
    local routed = false
    c._handle_write_text_file = function()
      routed = true
    end
    c:_handle_incoming(nil, "fs/write_text_file", { sessionId = "s1", path = "/a", content = "x" })
    h.eq(false, routed)
    c:_handle_incoming(10, "fs/write_text_file", { sessionId = "s1", path = "/a", content = "x" })
    h.is_true(routed)
  end)
end)

-- ── _send_error / _send_result wire format ─────────────────────

h.describe("ACPClient send helpers", function()
  h.it("_send_result encodes JSON-RPC result", function()
    local c, sent = make_client()
    c:_send_result(7, { content = "hello" })
    local decoded = vim.json.decode(sent[1])
    h.eq("2.0", decoded.jsonrpc)
    h.eq(7, decoded.id)
    h.eq("hello", decoded.result.content)
  end)

  h.it("_send_error encodes JSON-RPC error with default code", function()
    local c, sent = make_client()
    c:_send_error(3, "boom")
    local decoded = vim.json.decode(sent[1])
    h.eq(3, decoded.id)
    h.eq("boom", decoded.error.message)
    h.eq(ACPClient.ERROR_CODES.INTERNAL_ERROR, decoded.error.code)
  end)

  h.it("_send_error uses custom code", function()
    local c, sent = make_client()
    c:_send_error(3, "nope", ACPClient.ERROR_CODES.INVALID_PARAMS)
    local decoded = vim.json.decode(sent[1])
    h.eq(ACPClient.ERROR_CODES.INVALID_PARAMS, decoded.error.code)
  end)
end)

-- ── _handle_read_text_file validation ──────────────────────────

h.describe("ACPClient _handle_read_text_file", function()
  h.it("sends error when sessionId missing", function()
    local c, sent = make_client()
    c:_handle_read_text_file(1, { path = "/a" })
    local decoded = vim.json.decode(sent[1])
    h.eq(1, decoded.id)
    h.is_true(decoded.error ~= nil)
  end)

  h.it("sends error when path missing", function()
    local c, sent = make_client()
    c:_handle_read_text_file(1, { sessionId = "s1" })
    local decoded = vim.json.decode(sent[1])
    h.is_true(decoded.error ~= nil)
  end)

  h.it("sends error when no on_read_file handler configured", function()
    local c, sent = make_client({})
    c:_handle_read_text_file(1, { sessionId = "s1", path = "/a" })
    local decoded = vim.json.decode(sent[1])
    h.eq(ACPClient.ERROR_CODES.METHOD_NOT_FOUND, decoded.error.code)
  end)
end)

-- ── _handle_write_text_file validation ─────────────────────────

h.describe("ACPClient _handle_write_text_file", function()
  h.it("sends error when params incomplete", function()
    local c, sent = make_client()
    c:_handle_write_text_file(1, { sessionId = "s1", path = "/a" }) -- missing content
    local decoded = vim.json.decode(sent[1])
    h.is_true(decoded.error ~= nil)
  end)

  h.it("sends error when no on_write_file handler configured", function()
    local c, sent = make_client({})
    c:_handle_write_text_file(1, { sessionId = "s1", path = "/a", content = "x" })
    local decoded = vim.json.decode(sent[1])
    h.eq(ACPClient.ERROR_CODES.METHOD_NOT_FOUND, decoded.error.code)
  end)
end)

-- ── create_session additionalDirectories ──────────────────────

h.describe("ACPClient create_session", function()
  h.it("3rd arg may be a callback (back-compat with no opts)", function()
    local c, sent = make_client()
    c:create_session("/cwd", {}, function(_, _, _) end)
    -- Should have sent a session/new request without additionalDirectories
    local decoded = vim.json.decode(sent[1])
    h.eq("session/new", decoded.method)
    h.eq("/cwd", decoded.params.cwd)
    h.is_nil(decoded.params.additionalDirectories)
  end)

  h.it("forwards additionalDirectories when capability is advertised", function()
    local c, sent = make_client()
    c.agent_capabilities = { sessionCapabilities = { additionalDirectories = true } }
    c:create_session("/cwd", {}, { additionalDirectories = { "/a", "/b" } }, function() end)
    local decoded = vim.json.decode(sent[1])
    h.eq({ "/a", "/b" }, decoded.params.additionalDirectories)
  end)

  h.it("strips additionalDirectories when capability is not advertised", function()
    local c, sent = make_client()
    c.agent_capabilities = { sessionCapabilities = {} }
    c:create_session("/cwd", {}, { additionalDirectories = { "/a" } }, function() end)
    local decoded = vim.json.decode(sent[1])
    h.is_nil(decoded.params.additionalDirectories)
  end)

  h.it("strips additionalDirectories when agent_capabilities is nil", function()
    local c, sent = make_client()
    c.agent_capabilities = nil
    c:create_session("/cwd", {}, { additionalDirectories = { "/a" } }, function() end)
    local decoded = vim.json.decode(sent[1])
    h.is_nil(decoded.params.additionalDirectories)
  end)

  h.it("ignores empty additionalDirectories list", function()
    local c, sent = make_client()
    c.agent_capabilities = { sessionCapabilities = { additionalDirectories = true } }
    c:create_session("/cwd", {}, { additionalDirectories = {} }, function() end)
    local decoded = vim.json.decode(sent[1])
    h.is_nil(decoded.params.additionalDirectories)
  end)

  h.it("forwards opts.meta as request _meta", function()
    local c, sent = make_client()
    c:create_session(
      "/cwd",
      {},
      { meta = { claudeCode = { options = { extraArgs = { agent = "x" } } } } },
      function() end
    )
    local decoded = vim.json.decode(sent[1])
    h.eq({ claudeCode = { options = { extraArgs = { agent = "x" } } } }, decoded.params._meta)
  end)

  h.it("omits _meta when opts.meta is nil or empty", function()
    local c, sent = make_client()
    c:create_session("/cwd", {}, { meta = {} }, function() end)
    local decoded = vim.json.decode(sent[1])
    h.is_nil(decoded.params._meta)
  end)
end)

-- ── load_session additionalDirectories ────────────────────────

h.describe("ACPClient load_session", function()
  h.it("3rd-arg-as-callback back-compat path", function()
    local c, sent = make_client()
    c.agent_capabilities = { loadSession = true }
    c:load_session("sid", "/cwd", {}, function() end)
    local decoded = vim.json.decode(sent[1])
    h.eq("session/load", decoded.method)
    h.eq("sid", decoded.params.sessionId)
    h.is_nil(decoded.params.additionalDirectories)
  end)

  h.it("forwards additionalDirectories when both loadSession and dir cap supported", function()
    local c, sent = make_client()
    c.agent_capabilities = {
      loadSession = true,
      sessionCapabilities = { additionalDirectories = true },
    }
    c:load_session("sid", "/cwd", {}, { additionalDirectories = { "/x" } }, function() end)
    local decoded = vim.json.decode(sent[1])
    h.eq({ "/x" }, decoded.params.additionalDirectories)
  end)

  h.it("returns error when loadSession capability missing", function()
    local c = make_client()
    c.agent_capabilities = nil
    local got_err
    c:load_session("sid", "/cwd", {}, function(_, err)
      got_err = err
    end)
    h.is_true(got_err ~= nil)
  end)

  h.it("forwards opts.meta as request _meta on session/load", function()
    local c, sent = make_client()
    c.agent_capabilities = { loadSession = true }
    c:load_session("sid", "/cwd", {}, { meta = { provider = { foo = 1 } } }, function() end)
    local decoded = vim.json.decode(sent[1])
    h.eq({ provider = { foo = 1 } }, decoded.params._meta)
  end)
end)

-- ── _set_state ─────────────────────────────────────────────────

h.describe("ACPClient _set_state", function()
  h.it("updates state and calls on_state_change", function()
    local transitions = {}
    local c = make_client()
    c.config.on_state_change = function(new, old)
      transitions[#transitions + 1] = { old = old, new = new }
    end
    c:_set_state("connecting")
    c:_set_state("ready")
    h.eq("ready", c.state)
    h.eq(2, #transitions)
    h.eq("disconnected", transitions[1].old)
    h.eq("connecting", transitions[1].new)
    h.eq("connecting", transitions[2].old)
    h.eq("ready", transitions[2].new)
  end)
end)
