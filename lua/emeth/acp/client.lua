--- ACP Client — JSON-RPC transport and protocol implementation
--- Ported from avante.nvim's libs/acp_client.lua, made standalone.

--- Track the single active client for cleanup on VimLeave.
---@type acp.ACPClient|nil
local active_client = nil
local vim_leave_registered = false

local function get_config()
  return require("emeth.acp").config
end

local function debug_log_print(...)
  if get_config().debug then
    local parts = {}
    for i = 1, select("#", ...) do
      parts[i] = tostring(select(i, ...))
    end
    vim.notify("[emeth-acp] " .. table.concat(parts, " "), vim.log.levels.DEBUG)
  end
end

---@class acp.ACPClient
---@field protocol_version number
---@field capabilities acp.ClientCapabilities
---@field agent_capabilities acp.AgentCapabilities|nil
---@field agent_meta table|nil  InitializeResponse `_meta` (extension capabilities)
---@field auth_methods acp.AuthMethod[]
---@field config acp.ClientConfig
---@field callbacks table<number, fun(result: table|nil, err: acp.ACPError|nil)>
---@field _log_file file*|nil
---@field _log_path string|nil  datetime-based path, created on first write
---@field id_counter number
---@field transport acp.ACPTransport
---@field state acp.ConnectionState
---@field reconnect_count number
local ACPClient = {}
ACPClient.__index = ACPClient

ACPClient.ERROR_CODES = {
  PARSE_ERROR = -32700,
  INVALID_REQUEST = -32600,
  METHOD_NOT_FOUND = -32601,
  INVALID_PARAMS = -32602,
  INTERNAL_ERROR = -32603,
  AUTH_REQUIRED = -32000,
  PROTOCOL_ERROR = -32001,
  RESOURCE_NOT_FOUND = -32002,
  TIMEOUT_ERROR = -32003,
}

---@param config acp.ClientConfig
---@return acp.ACPClient
function ACPClient:new(config)
  local client = setmetatable({
    id_counter = 0,
    protocol_version = 1,
    -- `elicitation.form` must be an empty *object* per spec; a bare `{}` would
    -- serialize to `[]`. Only `form` is advertised: `url` mode additionally
    -- requires handling the `elicitation/complete` notification.
    capabilities = {
      fs = { readTextFile = true, writeTextFile = true },
      elicitation = { form = vim.empty_dict() },
    },
    agent_capabilities = nil,
    agent_meta = nil,
    auth_methods = {},
    _log_file = nil,
    _log_path = nil,
    callbacks = {},
    transport = nil,
    config = config or {},
    state = "disconnected",
    reconnect_count = 0,
  }, { __index = self })
  client:_setup_transport()
  return client
end

---@param message string
function ACPClient:_debug_log(message)
  if not get_config().debug then
    self:_close_debug_log()
    return
  end
  if not self._log_file then
    local dir = vim.fn.stdpath("state") .. "/emeth/logs"
    vim.fn.mkdir(dir, "p")
    if not self._log_path then
      self._log_path = dir .. "/" .. os.date("%Y-%m-%d_%H-%M-%S") .. ".log"
    end
    self._log_file = io.open(self._log_path, "a")
  end
  if self._log_file then
    self._log_file:write(message)
    self._log_file:flush()
  end
end

function ACPClient:_close_debug_log()
  if self._log_file then
    self._log_file:close()
    self._log_file = nil
  end
end

function ACPClient:_setup_transport()
  local transport_type = self.config.transport_type or "stdio"
  if transport_type == "stdio" then
    self.transport = self:_create_stdio_transport()
  else
    error("Unsupported transport type: " .. transport_type)
  end
end

---@param state acp.ConnectionState
function ACPClient:_set_state(state)
  local old_state = self.state
  self.state = state
  if self.config.on_state_change then
    self.config.on_state_change(state, old_state)
  end
end

---@param code number
---@param message string
---@param data any?
---@return acp.ACPError
function ACPClient:_create_error(code, message, data)
  return { code = code, message = message, data = data }
end

---Fail every in-flight request with `err` and clear the pending queue. Called
---when the transport dies (process exit / stdout error) so a request waiting on
---a response that will never arrive doesn't hang forever — which otherwise
---strands the UI in "connecting" (the orphaned `initialize` callback) or
---"generating" (an orphaned `session/prompt`). Snapshots and clears the queue
---synchronously so a drained callback that triggers another teardown can't
---re-enter the same set; the invocations themselves are scheduled because the
---callbacks touch the editor API and we may be on the libuv thread.
---@param err acp.ACPError
function ACPClient:_fail_pending(err)
  if not next(self.callbacks) then
    return
  end
  local pending = self.callbacks
  self.callbacks = {}
  vim.schedule(function()
    for _, callback in pairs(pending) do
      pcall(callback, nil, err)
    end
  end)
end

function ACPClient:_create_stdio_transport()
  local uv = vim.uv or vim.loop
  local transport = { stdin = nil, stdout = nil, process = nil }

  function transport.send(transport_self, data)
    if transport_self.stdin and not transport_self.stdin:is_closing() then
      transport_self.stdin:write(data .. "\n")
      return true
    end
    return false
  end

  ---Close pipes that were opened for a spawn that never happened, so a failed
  ---start doesn't leak file descriptors.
  local function close_pipes(...)
    for _, pipe in ipairs({ ... }) do
      if pipe and not pipe:is_closing() then
        pipe:close()
      end
    end
  end

  ---Start the agent process.
  ---@return boolean ok, string|nil err  a human-readable reason when ok is false
  function transport.start(transport_self, on_message)
    self:_set_state("connecting")
    local stdin = uv.new_pipe(false)
    local stdout = uv.new_pipe(false)
    local stderr = uv.new_pipe(false)
    if not stdin or not stdout or not stderr then
      close_pipes(stdin, stdout, stderr)
      self:_set_state("error")
      return false, "Failed to create pipes for the ACP agent"
    end

    local args = vim.deepcopy(self.config.args or {})
    local env = self.config.env
    local final_env = {}
    local path = vim.fn.getenv("PATH")
    if path then
      final_env[#final_env + 1] = "PATH=" .. path
    end
    local home = vim.fn.getenv("HOME")
    if home then
      final_env[#final_env + 1] = "HOME=" .. home
    end
    if env then
      for k, v in pairs(env) do
        final_env[#final_env + 1] = k .. "=" .. v
      end
    end

    ---@diagnostic disable-next-line: missing-fields
    local handle, pid, err_name = uv.spawn(self.config.command, {
      args = args,
      env = final_env,
      stdio = { stdin, stdout, stderr },
    }, function(code, signal)
      debug_log_print("ACP agent exited with code " .. code .. " and signal " .. signal)
      self:_set_state("disconnected")
      -- The process is gone: any request still awaiting a response never will
      -- get one. Fail them so the UI leaves "connecting"/"generating" and shows
      -- the reason instead of hanging silently.
      self:_fail_pending(
        self:_create_error(
          self.ERROR_CODES.INTERNAL_ERROR,
          ("ACP agent process exited (code %s, signal %s)"):format(code, signal)
        )
      )
      if transport_self.process then
        transport_self.process:close()
        transport_self.process = nil
      end
      if self.config.reconnect and self.reconnect_count < (self.config.max_reconnect_attempts or 3) then
        self.reconnect_count = self.reconnect_count + 1
        vim.defer_fn(function()
          if self.state == "disconnected" then
            self:connect(function() end)
          end
        end, 2000)
      end
    end)

    if not handle then
      -- `pid` carries the message and `err_name` the code when spawn fails.
      close_pipes(stdin, stdout, stderr)
      self:_set_state("error")
      local command = self.config.command or "?"
      if err_name == "ENOENT" then
        -- Overwhelmingly the interesting case, and the one whose default message
        -- ("no such file or directory") sends people looking for the wrong thing.
        -- Neovim's PATH is inherited from whatever launched it, so a version
        -- manager that resolves tools per directory (mise, asdf) can leave the
        -- command missing here even though it works in a shell.
        return false,
          ("`%s` was not found on PATH. Neovim's PATH may differ from your shell's — if you use a version manager (mise, asdf), check that the tool version this directory pins is actually installed. `:checkhealth emeth` lists provider commands."):format(
            command
          )
      end
      return false, ("Failed to start `%s`: %s"):format(command, tostring(pid or err_name or "unknown error"))
    end
    debug_log_print("Spawned ACP agent process with PID " .. tostring(pid))

    transport_self.process = handle
    transport_self.stdin = stdin
    transport_self.stdout = stdout
    self:_set_state("connected")

    local buf_parts = {}
    stdout:read_start(function(err, data)
      if err then
        vim.schedule(function()
          vim.notify("ACP stdout error: " .. err, vim.log.levels.ERROR)
        end)
        self:_set_state("error")
        self:_fail_pending(self:_create_error(self.ERROR_CODES.INTERNAL_ERROR, "ACP stdout error: " .. err))
        return
      end
      if data then
        buf_parts[#buf_parts + 1] = data
        local combined = table.concat(buf_parts)
        local lines = vim.split(combined, "\n", { plain = true })
        buf_parts = { lines[#lines] }
        for i = 1, #lines - 1 do
          local line = vim.trim(lines[i])
          if line ~= "" then
            local ok, message = pcall(vim.json.decode, line)
            if ok then
              on_message(message)
            end
          end
        end
      end
    end)

    stderr:read_start(function(_, data)
      if data then
        self:_debug_log("stderr: " .. data .. "\n")
      end
    end)
    return true
  end

  function transport.stop(transport_self)
    if transport_self.process and not transport_self.process:is_closing() then
      local process = transport_self.process
      transport_self.process = nil
      if process then
        pcall(function()
          process:kill(15)
        end)
        -- Allow 200ms for graceful shutdown before SIGKILL
        local kill_timer = uv.new_timer()
        kill_timer:start(200, 0, function()
          kill_timer:close()
          if not process:is_closing() then
            pcall(function()
              process:kill(9)
            end)
            process:close()
          end
        end)
      end
    end
    if transport_self.stdin then
      transport_self.stdin:close()
      transport_self.stdin = nil
    end
    if transport_self.stdout then
      transport_self.stdout:close()
      transport_self.stdout = nil
    end
    self:_set_state("disconnected")
  end

  return transport
end

---@return number
function ACPClient:_next_id()
  self.id_counter = self.id_counter + 1
  return self.id_counter
end

---@param method string
---@param params table?
---@param callback fun(result: table|nil, err: acp.ACPError|nil)
function ACPClient:_send_request(method, params, callback)
  local id = self:_next_id()
  local message = { jsonrpc = "2.0", id = id, method = method, params = params or {} }
  self.callbacks[id] = callback
  local data = vim.json.encode(message)
  self:_debug_log("request: " .. data .. "\n" .. string.rep("=", 80) .. "\n")
  self.transport:send(data)
end

---@param method string
---@param params table?
function ACPClient:_send_notification(method, params)
  local message = { jsonrpc = "2.0", method = method, params = params or {} }
  local data = vim.json.encode(message)
  self:_debug_log("notification: " .. data .. "\n" .. string.rep("=", 80) .. "\n")
  self.transport:send(data)
end

---@param id number
---@param result table|string|nil
function ACPClient:_send_result(id, result)
  local message = { jsonrpc = "2.0", id = id, result = result }
  local data = vim.json.encode(message)
  self:_debug_log("result: " .. data .. "\n" .. string.rep("=", 80) .. "\n")
  self.transport:send(data)
end

---@param id number
---@param message string
---@param code? number
function ACPClient:_send_error(id, message, code)
  code = code or self.ERROR_CODES.INTERNAL_ERROR
  local msg = { jsonrpc = "2.0", id = id, error = { code = code, message = message } }
  local data = vim.json.encode(msg)
  self.transport:send(data)
end

---@param message table
function ACPClient:_handle_message(message)
  if message.method and not message.result and not message.error then
    self:_handle_incoming(message.id, message.method, message.params)
  elseif message.id and (message.result or message.error) then
    self:_debug_log("response: " .. vim.inspect(message) .. "\n" .. string.rep("=", 80) .. "\n")
    local callback = self.callbacks[message.id]
    if callback then
      callback(message.result, message.error)
      self.callbacks[message.id] = nil
    end
  end
end

---Handle an incoming JSON-RPC method call (request with id, or notification without).
---@param message_id number|nil  present for requests that expect a response
---@param method string
---@param params table
function ACPClient:_handle_incoming(message_id, method, params)
  self:_debug_log("method: " .. method .. "\n" .. vim.inspect(params) .. "\n" .. string.rep("=", 80) .. "\n")
  if method == "session/update" then
    self:_handle_session_update(params)
  elseif method == "session/request_permission" then
    if message_id then
      self:_handle_request_permission(message_id, params)
    end
  elseif method == "elicitation/create" then
    if message_id then
      self:_handle_elicitation(message_id, params)
    end
  elseif method == "fs/read_text_file" then
    if message_id then
      self:_handle_read_text_file(message_id, params)
    end
  elseif method == "fs/write_text_file" then
    if message_id then
      self:_handle_write_text_file(message_id, params)
    end
  else
    if self.config.handlers and self.config.handlers.on_notification then
      vim.schedule(function()
        self.config.handlers.on_notification(method, params, message_id)
      end)
    end
  end
end

---@param params table
function ACPClient:_handle_session_update(params)
  if not params.sessionId or not params.update then
    return
  end
  if self.config.handlers and self.config.handlers.on_session_update then
    self.config.handlers.on_session_update(params.update, params.sessionId)
  end
end

---@param message_id number
---@param params table
function ACPClient:_handle_request_permission(message_id, params)
  if not params.sessionId or not params.toolCall then
    return
  end
  if self.config.handlers and self.config.handlers.on_request_permission then
    vim.schedule(function()
      self.config.handlers.on_request_permission(params.toolCall, params.options, function(option_id)
        self:_send_result(message_id, { outcome = { outcome = "selected", optionId = option_id } })
      end)
    end)
  end
end

---Handle an inbound `elicitation/create`.
---
---The agent blocks its turn on this response, so every path must answer exactly
---once: a missing handler or an unrenderable mode replies `decline` rather than
---leaving the turn hanging. `decline` (not `cancel`) is the right refusal — it
---means "the user provided nothing", which lets the agent carry on, whereas
---`cancel` aborts the originating tool call.
---@param message_id number
---@param params table
function ACPClient:_handle_elicitation(message_id, params)
  -- Guard the response: the UI resolves from keymaps and callbacks that could
  -- otherwise fire twice (e.g. answered just as the session tears down).
  local answered = false
  local function respond(response)
    if answered then
      return
    end
    answered = true
    self:_send_result(message_id, response)
  end

  local handler = self.config.handlers and self.config.handlers.on_elicitation
  -- We only advertise `form`, so any other mode is either a spec violation or a
  -- future/custom mode we must not render as if it were a known one.
  if not handler or type(params) ~= "table" or params.mode ~= "form" then
    respond({ action = "decline" })
    return
  end

  vim.schedule(function()
    handler(params, respond)
  end)
end

---@param message_id number
---@param params table
function ACPClient:_handle_read_text_file(message_id, params)
  if not params.sessionId or not params.path then
    self:_send_error(message_id, "Invalid fs/read_text_file params", self.ERROR_CODES.INVALID_PARAMS)
    return
  end
  if self.config.handlers and self.config.handlers.on_read_file then
    vim.schedule(function()
      self.config.handlers.on_read_file(
        params.path,
        params.line ~= vim.NIL and params.line or nil,
        params.limit ~= vim.NIL and params.limit or nil,
        function(content)
          self:_send_result(message_id, { content = content })
        end,
        function(err, code)
          self:_send_error(message_id, err or "Failed to read file", code)
        end
      )
    end)
  else
    self:_send_error(message_id, "fs/read_text_file handler not configured", self.ERROR_CODES.METHOD_NOT_FOUND)
  end
end

---@param message_id number
---@param params table
function ACPClient:_handle_write_text_file(message_id, params)
  if not params.sessionId or not params.path or not params.content then
    self:_send_error(message_id, "Invalid fs/write_text_file params", self.ERROR_CODES.INVALID_PARAMS)
    return
  end
  if self.config.handlers and self.config.handlers.on_write_file then
    vim.schedule(function()
      self.config.handlers.on_write_file(params.path, params.content, function(err)
        self:_send_result(message_id, err == nil and vim.NIL or err)
      end)
    end)
  else
    self:_send_error(message_id, "fs/write_text_file handler not configured", self.ERROR_CODES.METHOD_NOT_FOUND)
  end
end

---@param callback? fun(err: acp.ACPError|nil)
function ACPClient:connect(callback)
  callback = callback or function() end
  if self.state ~= "disconnected" then
    callback(nil)
    return
  end

  -- Kill any existing client before starting a new one
  if active_client and active_client ~= self then
    pcall(function()
      active_client:stop()
    end)
  end
  active_client = self

  if not vim_leave_registered then
    vim_leave_registered = true
    vim.api.nvim_create_autocmd("VimLeavePre", {
      callback = function()
        if active_client then
          pcall(function()
            active_client:stop()
          end)
        end
      end,
    })
  end

  -- A failed start is reported through the callback, not raised: the caller owns
  -- the UI state it entered to connect, and an uncaught error here would leave it
  -- stuck in "connecting" with only a stack trace to explain why.
  local ok, start_err = self.transport:start(vim.schedule_wrap(function(message)
    self:_handle_message(message)
  end))
  if ok == false then
    active_client = nil
    callback(self:_create_error(self.ERROR_CODES.INTERNAL_ERROR, start_err or "Failed to start the ACP agent"))
    return
  end
  self:initialize(callback)
end

function ACPClient:stop()
  if active_client == self then
    active_client = nil
  end
  self.transport:stop()
  self:_close_debug_log()
  self.reconnect_count = 0
end

---@param callback fun(err: acp.ACPError|nil)
function ACPClient:initialize(callback)
  callback = callback or function() end
  if self.state ~= "connected" then
    callback(self:_create_error(self.ERROR_CODES.PROTOCOL_ERROR, "Cannot initialize: client not connected"))
    return
  end
  self:_set_state("initializing")
  self:_send_request("initialize", {
    protocolVersion = self.protocol_version,
    clientCapabilities = self.capabilities,
  }, function(result, err)
    if err or not result then
      self:_set_state("error")
      vim.schedule(function()
        vim.notify(
          "[emeth-acp] Failed to initialize: "
            .. (err and (err.message or "") .. (err.data and (": " .. tostring(err.data)) or "") or "missing result"),
          vim.log.levels.ERROR
        )
      end)
      callback(err or self:_create_error(self.ERROR_CODES.PROTOCOL_ERROR, "Failed to initialize: missing result"))
      return
    end
    self.protocol_version = result.protocolVersion
    self.agent_capabilities = result.agentCapabilities
    -- Extension capabilities that aren't part of `agentCapabilities` ride on the
    -- InitializeResponse's own `_meta` (claude-acp advertises steering, goal and
    -- its AIR capabilities there, while `agentCapabilities._meta` carries only
    -- `claudeCode`). Keep it so feature probes can consult it.
    self.agent_meta = type(result._meta) == "table" and result._meta or nil
    self.auth_methods = result.authMethods or {}
    local auth_method = self.config.auth_method
    if auth_method then
      self:authenticate(auth_method, function(auth_err)
        if auth_err then
          callback(auth_err)
        else
          self:_set_state("ready")
          callback(nil)
        end
      end)
    else
      self:_set_state("ready")
      callback(nil)
    end
  end)
end

---Whether the agent accepts steering — injecting a message into the turn that is
---already running instead of queueing it behind that turn.
---
---Advertised on the InitializeResponse `_meta` rather than in `agentCapabilities`,
---so it is a `_meta` probe rather than a spec capability check.
---@return boolean
function ACPClient:supports_steering()
  local steering = self.agent_meta and self.agent_meta.steering
  return type(steering) == "table" and steering.supported == true
end

---Inject `prompt` into the in-flight turn.
---
---`idleBehavior = "promptRequired"` is deliberate. Without it, an agent that
---finds no turn running starts one itself, detached — its result never reaches
---our `session/prompt` callback, so our activity state would never settle. With
---it, the agent instead answers `promptRequired` and leaves the content alone,
---so the caller can send it as a normal prompt whose lifecycle we own. That race
---is real: a turn can finish between deciding to steer and this request landing.
---@param session_id string
---@param prompt acp.Content[]
---@param callback fun(outcome: string|nil, err: acp.ACPError|nil)
function ACPClient:steer(session_id, prompt, callback)
  callback = callback or function() end
  self:_send_request("_session/steering", {
    sessionId = session_id,
    prompt = prompt,
    _meta = { steering = { idleBehavior = "promptRequired" } },
  }, function(result, err)
    if err then
      callback(nil, err)
      return
    end
    callback(type(result) == "table" and result.outcome or nil, nil)
  end)
end

---@param method_id string
---@param callback fun(err: acp.ACPError|nil)
function ACPClient:authenticate(method_id, callback)
  callback = callback or function() end
  self:_send_request("authenticate", { methodId = method_id }, function(_, err)
    callback(err)
  end)
end

---@param cwd string
---@param mcp_servers table[]?
---@param opts_or_cb table|fun(session_id: string|nil, err: acp.ACPError|nil, result: table|nil)
---@param maybe_cb? fun(session_id: string|nil, err: acp.ACPError|nil, result: table|nil)
function ACPClient:create_session(cwd, mcp_servers, opts_or_cb, maybe_cb)
  -- Backward-compatible: 3rd arg may be a callback (no opts).
  local opts, callback
  if type(opts_or_cb) == "function" then
    opts, callback = nil, opts_or_cb
  else
    opts, callback = opts_or_cb, maybe_cb
  end
  callback = callback or function() end
  local params = { cwd = cwd, mcpServers = mcp_servers or {} }
  if opts and opts.additionalDirectories and #opts.additionalDirectories > 0 then
    local supported = self.agent_capabilities
      and self.agent_capabilities.sessionCapabilities
      and self.agent_capabilities.sessionCapabilities.additionalDirectories
    if supported then
      params.additionalDirectories = opts.additionalDirectories
    else
      vim.schedule(function()
        vim.notify(
          "[emeth-acp] Agent does not advertise additionalDirectories capability — workspace roots ignored",
          vim.log.levels.WARN
        )
      end)
    end
  end
  if opts and opts.meta and next(opts.meta) ~= nil then
    params._meta = opts.meta
  end
  self:_send_request("session/new", params, function(result, err)
    if err then
      vim.schedule(function()
        vim.notify(
          "[emeth-acp] Failed to create session: " .. err.message .. (err.data and (": " .. tostring(err.data)) or ""),
          vim.log.levels.ERROR
        )
      end)
      callback(nil, err)
      return
    end
    if not result then
      callback(nil, self:_create_error(self.ERROR_CODES.PROTOCOL_ERROR, "Failed to create session: missing result"))
      return
    end
    callback(result.sessionId, nil, result)
  end)
end

---@param session_id string
---@param cwd string
---@param mcp_servers table[]?
---@param opts_or_cb table|fun(result: table|nil, err: acp.ACPError|nil)
---@param maybe_cb? fun(result: table|nil, err: acp.ACPError|nil)
function ACPClient:load_session(session_id, cwd, mcp_servers, opts_or_cb, maybe_cb)
  local opts, callback
  if type(opts_or_cb) == "function" then
    opts, callback = nil, opts_or_cb
  else
    opts, callback = opts_or_cb, maybe_cb
  end
  callback = callback or function() end
  if not self.agent_capabilities or not self.agent_capabilities.loadSession then
    callback(nil, self:_create_error(self.ERROR_CODES.PROTOCOL_ERROR, "Agent does not support loading sessions"))
    return
  end
  local params = {
    sessionId = session_id,
    cwd = cwd,
    mcpServers = mcp_servers or {},
  }
  if opts and opts.additionalDirectories and #opts.additionalDirectories > 0 then
    local supported = self.agent_capabilities.sessionCapabilities
      and self.agent_capabilities.sessionCapabilities.additionalDirectories
    if supported then
      params.additionalDirectories = opts.additionalDirectories
    end
  end
  if opts and opts.meta and next(opts.meta) ~= nil then
    params._meta = opts.meta
  end
  self:_send_request("session/load", params, callback)
end

---@param cwd? string
---@param cursor? string
---@param callback fun(sessions: acp.SessionInfo[]|nil, next_cursor: string|nil, err: acp.ACPError|nil)
function ACPClient:list_sessions(cwd, cursor, callback)
  callback = callback or function() end
  if
    not self.agent_capabilities
    or not (self.agent_capabilities.sessionCapabilities and self.agent_capabilities.sessionCapabilities.list)
  then
    callback(nil, nil, self:_create_error(self.ERROR_CODES.PROTOCOL_ERROR, "Agent does not support listing sessions"))
    return
  end
  local params = {}
  if cwd then
    params.cwd = cwd
  end
  if cursor then
    params.cursor = cursor
  end
  self:_send_request("session/list", params, function(result, err)
    if err then
      callback(nil, nil, err)
    else
      callback(result and result.sessions or {}, result and result.nextCursor, nil)
    end
  end)
end

---@param session_id string
---@param prompt table[]
---@param callback fun(result: table|nil, err: acp.ACPError|nil)
function ACPClient:send_prompt(session_id, prompt, callback)
  return self:_send_request("session/prompt", { sessionId = session_id, prompt = prompt }, callback)
end

---@param session_id string
function ACPClient:cancel_session(session_id)
  self:_send_notification("session/cancel", { sessionId = session_id })
end

---Set a session configuration option (model, mode, effort, agent, fast, ...).
---Standard ACP `session/set_config_option`. The value is either a select
---option id (string) or a boolean for boolean-typed options — the wire schema
---tags the boolean variant with `type = "boolean"`. Returns the full updated
---`configOptions` array in `result.configOptions`.
---@param session_id string
---@param config_id string
---@param value string|boolean
---@param callback fun(result: table|nil, err: acp.ACPError|nil)
function ACPClient:set_config_option(session_id, config_id, value, callback)
  local params = { sessionId = session_id, configId = config_id, value = value }
  if type(value) == "boolean" then
    params.type = "boolean"
  end
  self:_send_request("session/set_config_option", params, callback)
end

-- Content helpers

---@param text string
---@param annotations table?
---@return acp.TextContent
local function create_text_content(text, annotations)
  return { type = "text", text = text, annotations = annotations }
end

---@param uri string
---@param name string
---@param description string?
---@param mime_type string?
---@param size number?
---@param title string?
---@param annotations table?
---@return acp.ResourceLinkContent
local function create_resource_link_content(uri, name, description, mime_type, size, title, annotations)
  return {
    type = "resource_link",
    uri = uri,
    name = name,
    description = description,
    mimeType = mime_type,
    size = size,
    title = title,
    annotations = annotations,
  }
end

---@param data string
---@param mime_type string
---@param uri string?
---@param annotations table?
---@return acp.ImageContent
local function create_image_content(data, mime_type, uri, annotations)
  return { type = "image", data = data, mimeType = mime_type, uri = uri, annotations = annotations }
end

---@param session_id string
---@param text string
---@param callback fun(result: table|nil, err: acp.ACPError|nil)
function ACPClient:send_text_prompt(session_id, text, callback)
  self:send_prompt(session_id, { create_text_content(text) }, callback)
end

ACPClient.create_text_content = create_text_content
ACPClient.create_resource_link_content = create_resource_link_content
ACPClient.create_image_content = create_image_content

return ACPClient
