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

-- ── _fail_pending ──────────────────────────────────────────────

h.describe("ACPClient _fail_pending", function()
  h.it("fails every in-flight callback with the error and clears the queue", function()
    local c = make_client()
    local errs = {}
    c.callbacks[1] = function(_, err)
      errs[1] = err
    end
    c.callbacks[2] = function(_, err)
      errs[2] = err
    end

    c:_fail_pending(c:_create_error(-32603, "process exited"))
    vim.wait(0)

    h.eq("process exited", errs[1] and errs[1].message)
    h.eq("process exited", errs[2] and errs[2].message)
    h.is_nil(next(c.callbacks), "pending queue must be cleared")
  end)

  h.it("is a no-op when nothing is pending", function()
    local c = make_client()
    -- Must not throw or schedule anything.
    c:_fail_pending(c:_create_error(-32603, "process exited"))
    vim.wait(0)
    h.is_nil(next(c.callbacks))
  end)

  h.it("clears synchronously so a re-entrant teardown can't double-fire", function()
    local c = make_client()
    local calls = 0
    c.callbacks[1] = function(_, _)
      calls = calls + 1
      -- A callback that triggers another drain (mirrors teardown re-entry)
      -- must not see itself again: the queue was already snapshotted+cleared.
      c:_fail_pending(c:_create_error(-32603, "again"))
    end

    c:_fail_pending(c:_create_error(-32603, "first"))
    vim.wait(0)

    h.eq(1, calls, "callback must fire exactly once")
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

  h.it("routes elicitation/create only when message_id present", function()
    local c = make_client()
    local routed = false
    c._handle_elicitation = function()
      routed = true
    end
    -- A notification carries no id to respond to, so there is nothing to answer.
    c:_handle_incoming(nil, "elicitation/create", { sessionId = "s1", mode = "form" })
    h.eq(false, routed)
    c:_handle_incoming(7, "elicitation/create", { sessionId = "s1", mode = "form" })
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

-- ── _handle_elicitation ────────────────────────────────────────

h.describe("ACPClient _handle_elicitation", function()
  --- The agent blocks its turn on this response, so every path must answer.
  --- `decline` means "user provided nothing" and lets the turn continue;
  --- `cancel` aborts the originating tool call.
  h.it("declines when no on_elicitation handler is configured", function()
    local c, sent = make_client({})
    c:_handle_elicitation(1, { mode = "form", message = "?" })
    local decoded = vim.json.decode(sent[1])
    h.eq(1, decoded.id)
    h.eq("decline", decoded.result.action)
  end)

  h.it("declines a mode it cannot render rather than treating it as a form", function()
    local called = false
    local c, sent = make_client({
      on_elicitation = function()
        called = true
      end,
    })
    -- Only `form` is advertised; url/unknown modes must not reach the handler.
    c:_handle_elicitation(2, { mode = "url", url = "https://example.com" })
    h.eq(false, called)
    h.eq("decline", vim.json.decode(sent[1]).result.action)
  end)

  h.it("passes a form request to the handler and sends its response", function()
    local captured
    local c, sent = make_client({
      on_elicitation = function(request, callback)
        captured = request
        callback({ action = "accept", content = { q = "answer" } })
      end,
    })
    c:_handle_elicitation(3, { mode = "form", message = "pick", requestedSchema = { type = "object" } })
    vim.wait(50, function()
      return #sent > 0
    end)
    h.eq("pick", captured.message)
    local decoded = vim.json.decode(sent[1])
    h.eq("accept", decoded.result.action)
    h.eq({ q = "answer" }, decoded.result.content)
  end)

  h.it("answers only once even if the handler resolves twice", function()
    local c, sent = make_client({
      on_elicitation = function(_, callback)
        callback({ action = "accept", content = { a = "1" } })
        callback({ action = "cancel" })
      end,
    })
    c:_handle_elicitation(4, { mode = "form" })
    vim.wait(50, function()
      return #sent > 0
    end)
    h.eq(1, #sent, "a second response would break the JSON-RPC id contract")
    h.eq("accept", vim.json.decode(sent[1]).result.action)
  end)
end)

-- ── connect: transport start failure ───────────────────────────

h.describe("ACPClient connect when the agent cannot be started", function()
  --- A client whose transport refuses to start, the way uv.spawn does when the
  --- command is not on PATH.
  local function failing_client(reason)
    local c = make_client()
    c.state = "disconnected"
    c.transport = {
      start = function()
        return false, reason
      end,
      stop = function() end,
      send = function() end,
    }
    return c
  end

  -- Regression: this used to `error()`, so the callback never ran. The caller had
  -- already entered its "connecting" UI state and nothing was left to settle it,
  -- leaving the sidebar stuck with only a stack trace to explain why.
  h.it("reports the failure through the callback instead of raising", function()
    local c = failing_client("`npx` was not found on PATH")
    local got
    local ok = pcall(function()
      c:connect(function(err)
        got = err
      end)
    end)
    h.is_true(ok, "connect must not raise")
    h.is_true(got ~= nil, "callback must receive an error")
    h.is_true(got.message:find("not found on PATH", 1, true) ~= nil)
  end)

  h.it("does not proceed to initialize after a failed start", function()
    local c = failing_client("nope")
    local initialized = false
    c.initialize = function()
      initialized = true
    end
    c:connect(function() end)
    h.eq(false, initialized)
  end)
end)

-- ── generic request / respond ──────────────────────────────────
-- Steering is no longer a client concern: provider extensions drive their own
-- control methods (claude `_session/steering`, kiro `_session/steer`) through the
-- generic `request`/`respond`/`respond_error` + `on_request` plumbing below.

h.describe("ACPClient request/respond", function()
  h.it("sends an arbitrary request and reports the result", function()
    local c, sent = make_client()
    local got, got_err = nil, nil
    c:request("_session/steer", { sessionId = "s1", message = "hi" }, function(result, err)
      got, got_err = result, err
    end)
    local decoded = vim.json.decode(sent[1])
    h.eq("_session/steer", decoded.method)
    h.eq("hi", decoded.params.message)
    c:_handle_message({ jsonrpc = "2.0", id = decoded.id, result = { queued = true, messageId = "m1" } })
    h.eq("m1", got.messageId)
    h.is_nil(got_err)
  end)

  h.it("surfaces a request error", function()
    local c, sent = make_client()
    local got, got_err = nil, nil
    c:request("x", {}, function(result, err)
      got, got_err = result, err
    end)
    local id = vim.json.decode(sent[1]).id
    c:_handle_message({ jsonrpc = "2.0", id = id, error = { code = -1, message = "nope" } })
    h.is_nil(got)
    h.eq("nope", got_err.message)
  end)

  h.it("respond and respond_error answer an inbound request by id", function()
    local c, sent = make_client()
    c:respond(7, { success = true })
    local ok = vim.json.decode(sent[#sent])
    h.eq(7, ok.id)
    h.eq(true, ok.result.success)
    c:respond_error(8, "bad", -32602)
    local err = vim.json.decode(sent[#sent])
    h.eq(8, err.id)
    h.eq(-32602, err.error.code)
  end)
end)

h.describe("ACPClient inbound requests", function()
  h.it("routes an unknown agent->client request to on_request", function()
    local claimed = nil
    local c, sent = make_client({
      on_request = function(method, params, respond, _re)
        claimed = { method = method, params = params }
        respond({ success = true })
        return true
      end,
    })
    c:_handle_message({ jsonrpc = "2.0", id = 3, method = "_kiro/openExternalUrl", params = { url = "https://x" } })
    h.eq("_kiro/openExternalUrl", claimed.method)
    h.eq("https://x", claimed.params.url)
    local reply = vim.json.decode(sent[#sent])
    h.eq(3, reply.id)
    h.eq(true, reply.result.success)
  end)

  h.it("answers -32601 when nothing claims the request", function()
    local c, sent = make_client() -- no on_request
    c:_handle_message({ jsonrpc = "2.0", id = 4, method = "_kiro/unknown", params = {} })
    local reply = vim.json.decode(sent[#sent])
    h.eq(4, reply.id)
    h.eq(c.ERROR_CODES.METHOD_NOT_FOUND, reply.error.code)
  end)

  h.it("answers -32601 when on_request declines", function()
    local c, sent = make_client({
      on_request = function()
        return false
      end,
    })
    c:_handle_message({ jsonrpc = "2.0", id = 5, method = "_kiro/x", params = {} })
    local reply = vim.json.decode(sent[#sent])
    h.eq(c.ERROR_CODES.METHOD_NOT_FOUND, reply.error.code)
  end)

  h.it("treats a method with no id as a notification, not a request", function()
    local notified, requested = false, false
    local c = make_client({
      on_notification = function()
        notified = true
      end,
      on_request = function()
        requested = true
        return true
      end,
    })
    c:_handle_message({ jsonrpc = "2.0", method = "_kiro/mcp/status", params = {} })
    vim.wait(10)
    h.is_true(notified)
    h.eq(false, requested)
  end)
end)

-- ── session close / fork ───────────────────────────────────────

h.describe("ACPClient close/fork", function()
  h.it("close_session errors without the capability", function()
    local c = make_client()
    local err
    c:close_session("s1", function(_, e)
      err = e
    end)
    h.is_true(err ~= nil, "unsupported close must report an error, not send")
  end)

  h.it("close_session sends session/close when supported", function()
    local c, sent = make_client()
    c.agent_capabilities = { sessionCapabilities = { close = {} } }
    c:close_session("s1", function() end)
    local d = vim.json.decode(sent[1])
    h.eq("session/close", d.method)
    h.eq("s1", d.params.sessionId)
  end)

  h.it("delete_session errors without the capability", function()
    local c = make_client()
    local err
    c:delete_session("s1", function(_, e)
      err = e
    end)
    h.is_true(err ~= nil, "unsupported delete must report an error, not send")
  end)

  h.it("delete_session sends session/delete when supported", function()
    local c, sent = make_client()
    c.agent_capabilities = { sessionCapabilities = { delete = {} } }
    c:delete_session("s1", function() end)
    local d = vim.json.decode(sent[1])
    h.eq("session/delete", d.method)
    h.eq("s1", d.params.sessionId)
  end)

  h.it("fork_session errors without the capability", function()
    local c = make_client()
    local err
    c:fork_session("s1", "/cwd", {}, function(_, e)
      err = e
    end)
    h.is_true(err ~= nil)
  end)

  h.it("fork_session sends session/fork with meta and returns the new id", function()
    local c, sent = make_client()
    c.agent_capabilities = { sessionCapabilities = { fork = {} } }
    local got_id
    c:fork_session("s1", "/cwd", {}, { meta = { kiro = { messageId = "m9" } } }, function(id)
      got_id = id
    end)
    local d = vim.json.decode(sent[1])
    h.eq("session/fork", d.method)
    h.eq("s1", d.params.sessionId)
    h.eq("m9", d.params._meta.kiro.messageId)
    c:_handle_message({ jsonrpc = "2.0", id = d.id, result = { sessionId = "s2" } })
    h.eq("s2", got_id)
  end)

  h.it("fork_session errors when the response carries no sessionId", function()
    local c, sent = make_client()
    c.agent_capabilities = { sessionCapabilities = { fork = {} } }
    local got_id, got_err
    c:fork_session("s1", "/cwd", {}, function(id, e)
      got_id, got_err = id, e
    end)
    local d = vim.json.decode(sent[1])
    c:_handle_message({ jsonrpc = "2.0", id = d.id, result = {} })
    h.is_nil(got_id)
    h.is_true(got_err ~= nil)
  end)
end)

-- ── client capabilities ────────────────────────────────────────

h.describe("ACPClient capabilities", function()
  h.it("merges provider capabilities_meta into clientCapabilities._meta", function()
    local real = ACPClient:new({ command = "true", capabilities_meta = { kiro = { openExternalUrl = true } } })
    h.eq(true, real.capabilities._meta.kiro.openExternalUrl)
    -- Absent by default so non-kiro providers send no `_meta`.
    local plain = ACPClient:new({ command = "true" })
    h.is_nil(plain.capabilities._meta)
  end)

  h.it("advertises form elicitation as an empty object, not an array", function()
    local real = ACPClient:new({ command = "true" })
    -- A bare Lua `{}` would encode as `[]`; the spec requires an object here.
    h.eq('{"form":{}}', vim.json.encode(real.capabilities.elicitation))
  end)

  h.it("does not advertise url elicitation, which needs elicitation/complete", function()
    local real = ACPClient:new({ command = "true" })
    h.is_nil(real.capabilities.elicitation.url)
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
