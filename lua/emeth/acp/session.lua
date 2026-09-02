--- ACP Session Manager — high-level lifecycle management over the raw client.

local ACPClient = require("emeth.acp.client")

---@class acp.Session
---@field client acp.ACPClient
---@field session_id string|nil
---@field provider_name string
---@field extensions table|nil
---@field _state "disconnected"|"connecting"|"ready"|"error"
---@field _listeners table<string, fun(...)[]>
local Session = {}
Session.__index = Session

-- ── Event emitter ──────────────────────────────────────────────

---@alias acp.SessionEvent "update"|"error"|"notification"|"file_written"|"state_change"|"permission"|"elicitation"

---Register a listener for a session event.
---@param event acp.SessionEvent
---@param fn fun(...)
function Session:on(event, fn)
  self._listeners[event] = self._listeners[event] or {}
  self._listeners[event][#self._listeners[event] + 1] = fn
end

---Remove a listener for a session event.
---@param event acp.SessionEvent
---@param fn fun(...)
function Session:off(event, fn)
  local list = self._listeners[event]
  if not list then
    return
  end
  for i, f in ipairs(list) do
    if f == fn then
      table.remove(list, i)
      return
    end
  end
end

---Whether anything would observe `event` — a session listener or the global
---config fallback. Mirrors `_emit`'s two sources. Needed for events that answer
---a blocking agent request: with no observer the agent would wait forever, so
---the caller has to synthesize a refusal instead of emitting into the void.
---@param event acp.SessionEvent
---@return boolean
---@private
function Session:_has_listener(event)
  local list = self._listeners[event]
  if list and #list > 0 then
    return true
  end
  return require("emeth.acp").config["on_" .. event] ~= nil
end

---Emit an event to session listeners, then fall back to global config callback.
---@param event acp.SessionEvent
---@param ... any
---@private
function Session:_emit(event, ...)
  local list = self._listeners[event]
  if list then
    for _, fn in ipairs(list) do
      fn(...)
    end
  end
  -- Fallback: global config callbacks for standalone emeth_acp usage
  local config = require("emeth.acp").config
  local key = "on_" .. event
  if config[key] then
    config[key](...)
  end
end

-- ── Constructor ────────────────────────────────────────────────

---@param provider_name string
---@return acp.Session
function Session:new(provider_name)
  local config = require("emeth.acp").config
  local provider = config.providers[provider_name]
  if not provider then
    error("[emeth-acp] Unknown provider: " .. provider_name)
  end

  -- Forward-declare session so client handlers can reference it
  local session ---@type acp.Session

  -- Merge explicit env with forwarded env vars from the current process
  local env = provider.env and vim.deepcopy(provider.env) or {}
  for _, name in ipairs(provider.pass_env or {}) do
    if not env[name] then
      local val = vim.fn.getenv(name)
      if val and val ~= vim.NIL then
        env[name] = val
      end
    end
  end

  ---@type acp.ClientConfig
  local client_config = {
    transport_type = "stdio",
    command = provider.command,
    args = provider.args,
    env = env,
    auth_method = provider.auth_method,
    handlers = {
      on_session_update = function(update, update_session_id)
        session:_emit("update", update, update_session_id)
      end,
      on_error = function(err)
        session:_emit("error", err)
      end,
      on_notification = function(method, params, message_id)
        session:_emit("notification", method, params, message_id)
      end,
      on_request_permission = function(tool_call, options, callback)
        session:_emit("permission", tool_call, options, callback)
        if require("emeth.acp").config.auto_approve_tools then
          local fallback
          for _, opt in ipairs(options or {}) do
            if opt.kind == "allow_always" then
              callback(opt.optionId)
              return
            elseif opt.kind == "allow_once" and not fallback then
              fallback = opt.optionId
            end
          end
          callback(fallback or (options and #options > 0 and options[1].optionId) or nil)
        end
      end,
      on_elicitation = function(request, callback)
        -- No auto-answer counterpart to `auto_approve_tools` here: an
        -- elicitation asks for something only the user knows, so inventing an
        -- answer would put words in their mouth.
        --
        -- The agent's turn is blocked on this, and `_emit` is a no-op when
        -- nothing is listening (headless use, or a session with no view), so
        -- decline rather than emitting into the void and hanging the turn.
        if not session:_has_listener("elicitation") then
          callback({ action = "decline" })
          return
        end
        session:_emit("elicitation", request, callback)
      end,
      on_read_file = function(path, line, limit, callback, error_callback)
        vim.schedule(function()
          local ok, content = pcall(function()
            local lines = vim.fn.readfile(path)
            if line and limit then
              lines = vim.list_slice(lines, line, line + limit - 1)
            elseif line then
              lines = vim.list_slice(lines, line)
            end
            return table.concat(lines, "\n")
          end)
          if ok then
            callback(content)
          else
            error_callback(tostring(content))
          end
        end)
      end,
      on_write_file = function(path, content, callback)
        vim.schedule(function()
          local old_lines = vim.fn.filereadable(path) == 1 and vim.fn.readfile(path) or {}
          local ok, err = pcall(function()
            local dir = vim.fn.fnamemodify(path, ":h")
            vim.fn.mkdir(dir, "p")
            vim.fn.writefile(vim.split(content, "\n"), path)
          end)
          callback(ok and nil or tostring(err))
          if ok then
            local new_lines = vim.split(content, "\n")
            local first_changed = nil
            for i = 1, math.max(#old_lines, #new_lines) do
              if old_lines[i] ~= new_lines[i] then
                first_changed = i
                break
              end
            end
            session:_emit("file_written", path, first_changed)
          end
        end)
      end,
    },
    on_state_change = function(new_state, old_state)
      session:_emit("state_change", new_state, old_state)
    end,
  }

  session = setmetatable({
    client = ACPClient:new(client_config),
    session_id = nil,
    provider_name = provider_name,
    _state = "disconnected",
    _listeners = {},
  }, { __index = self })

  return session
end

-- ── Session info extraction ────────────────────────────────────

---Extract provider-specific fields from session/new or session/load responses.
---Standard ACP fields (`models.currentModelId`, `modes.currentModeId`) are
---read directly. Anything beyond the spec is delegated to the provider
---extension's `extract_session_info(result, extensions)` hook (if any), so
---claude-acp's `configOptions` shape stays out of this module.
---@private
function Session:_extract_session_info(result)
  if not result then
    return
  end
  self.extensions = self.extensions or {}
  if result.models and result.models.currentModelId then
    self.extensions.model_id = result.models.currentModelId
  end
  if result.modes and result.modes.currentModeId then
    self.extensions.mode_id = result.modes.currentModeId
  end
  -- Standard ACP session config options (model, mode, effort, agent, fast, ...).
  -- Keyed by id so the integration can drive a generic picker per option
  -- without knowing which ids an agent happens to expose. Present on
  -- session/new, session/load, and pushed via `config_option_update`.
  if type(result.configOptions) == "table" then
    self.extensions.config_options = self.extensions.config_options or {}
    for _, opt in ipairs(result.configOptions) do
      if opt.id then
        self.extensions.config_options[opt.id] = opt
        -- `model`/`mode` are standard config-option ids; mirror their current
        -- value into model_id/mode_id so a switch made via set_config_option
        -- (which reports back only through configOptions, not models/modes)
        -- updates the winbar badge and the per-prompt `model:` detail.
        if opt.id == "model" and type(opt.currentValue) == "string" then
          self.extensions.model_id = opt.currentValue
        elseif opt.id == "mode" and type(opt.currentValue) == "string" then
          self.extensions.mode_id = opt.currentValue
        end
      end
    end
  end
  if self.provider_name then
    local ok, ext = pcall(require, "emeth.integrations." .. self.provider_name)
    if ok and type(ext.extract_session_info) == "function" then
      pcall(ext.extract_session_info, result, self.extensions)
    end
  end
end

-- ── Lifecycle ──────────────────────────────────────────────────

---Normalize the (opts, cb) pair where opts may be the callback (back-compat).
---@return table|nil opts, fun(err: acp.ACPError|nil) cb
local function norm_args(opts, cb)
  if type(opts) == "function" then
    return nil, opts
  end
  return opts, cb or function() end
end

---Map public opts to session/new + session/load request opts.
local function req_opts(opts)
  return {
    additionalDirectories = opts and opts.additional_directories,
    meta = opts and opts.meta,
  }
end

---Shared tail of every lifecycle action: record the session, extract info,
---and flip to ready — or error out.
---@private
function Session:_finish(session_id, result, err, cb)
  if err then
    self._state = "error"
    cb(err)
    return
  end
  self.session_id = session_id
  self:_extract_session_info(result)
  self._state = "ready"
  cb(nil)
end

---Establish the transport, then run `next` (or fail out through cb).
---@private
function Session:_connect_then(cb, next)
  self._state = "connecting"
  self.client:connect(function(err)
    if err then
      self._state = "error"
      cb(err)
    else
      next()
    end
  end)
end

---@param opts? { additional_directories?: string[], meta?: table }|fun(err: acp.ACPError|nil)
---@param cb? fun(err: acp.ACPError|nil)
function Session:connect(opts, cb)
  opts, cb = norm_args(opts, cb)
  self:_connect_then(cb, function()
    self:new_session(opts, cb)
  end)
end

---Create a fresh session over an already-connected client (clean conversation
---without restarting the agent process).
---@param opts? { additional_directories?: string[], meta?: table }|fun(err: acp.ACPError|nil)
---@param cb? fun(err: acp.ACPError|nil)
function Session:new_session(opts, cb)
  opts, cb = norm_args(opts, cb)
  self._state = "connecting"
  self.client:create_session(vim.fn.getcwd(), {}, req_opts(opts), function(session_id, err, result)
    self:_finish(session_id, result, err, cb)
  end)
end

---@param content_items table[]
---@param cb? fun(result: table|nil, err: acp.ACPError|nil)
function Session:send_prompt(content_items, cb)
  if self._state ~= "ready" then
    if cb then
      cb(nil, { code = -1, message = "Session not ready (state: " .. self._state .. ")" })
    end
    return
  end
  self.client:send_prompt(self.session_id, content_items, function(result, err)
    if cb then
      cb(result, err)
    end
  end)
end

function Session:cancel()
  if self.session_id then
    self.client:cancel_session(self.session_id)
  end
end

---Whether this session's agent accepts steering.
---@return boolean
function Session:supports_steering()
  return self._state == "ready" and self.client:supports_steering()
end

---Steer the running turn: deliver `content_items` into it rather than queueing
---them as a separate prompt.
---
---`outcome` is `"injected"` when it landed in the running turn, or
---`"promptRequired"` when no turn was actually running — in which case the agent
---kept its hands off the content and the caller should send it as a normal
---prompt (whose own callback then owns the turn's completion).
---@param content_items table[]
---@param cb? fun(outcome: string|nil, err: acp.ACPError|nil)
function Session:steer(content_items, cb)
  cb = cb or function() end
  if self._state ~= "ready" then
    cb(nil, { code = -1, message = "Session not ready (state: " .. self._state .. ")" })
    return
  end
  self.client:steer(self.session_id, content_items, cb)
end

---Set a session config option (model/mode/effort/agent/fast). Ready-guarded
---like send_prompt. On success the agent also pushes a `config_option_update`
---session/update carrying the full refreshed set, so callers don't need to
---reconcile the response themselves.
---@param config_id string
---@param value string|boolean
---@param cb? fun(result: table|nil, err: acp.ACPError|nil)
function Session:set_config_option(config_id, value, cb)
  if self._state ~= "ready" then
    if cb then
      cb(nil, { code = -1, message = "Session not ready (state: " .. self._state .. ")" })
    end
    return
  end
  self.client:set_config_option(self.session_id, config_id, value, function(result, err)
    if cb then
      cb(result, err)
    end
  end)
end

---List previous sessions from the agent. Requires sessionCapabilities.list.
---@param cb fun(sessions: acp.SessionInfo[]|nil, err: acp.ACPError|nil)
function Session:list_sessions(cb)
  local cwd = vim.fn.getcwd()
  self.client:list_sessions(cwd, nil, function(sessions, _, err)
    cb(sessions, err)
  end)
end

---Load a previous session by ID.
---@param session_id string
---@param opts? { additional_directories?: string[], meta?: table }|fun(err: acp.ACPError|nil)
---@param cb? fun(err: acp.ACPError|nil)
function Session:load(session_id, opts, cb)
  opts, cb = norm_args(opts, cb)
  self._state = "connecting"
  self.client:load_session(session_id, vim.fn.getcwd(), {}, req_opts(opts), function(result, err)
    self:_finish(session_id, result, err, cb)
  end)
end

---Connect and immediately load a session, skipping session/new.
---@param session_id string
---@param opts? { additional_directories?: string[], meta?: table }|fun(err: acp.ACPError|nil)
---@param cb? fun(err: acp.ACPError|nil)
function Session:connect_and_load(session_id, opts, cb)
  opts, cb = norm_args(opts, cb)
  self:_connect_then(cb, function()
    self:load(session_id, opts, cb)
  end)
end

function Session:disconnect()
  self.client:stop()
  self.session_id = nil
  self._state = "disconnected"
  self._listeners = {}
end

---@return boolean
function Session:is_connected()
  return self._state == "ready"
end

---@return string
function Session:get_state()
  return self._state
end

return Session
