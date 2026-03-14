--- ACP Session Manager — high-level lifecycle management over the raw client.

local ACPClient = require("emeth.acp.client")

---@class acp.Session
---@field client acp.ACPClient
---@field session_id string|nil
---@field provider_name string
---@field extensions table|nil
---@field _state "disconnected"|"connecting"|"ready"|"prompting"|"error"
---@field _listeners table<string, fun(...)[]>
local Session = {}
Session.__index = Session

-- ── Event emitter ──────────────────────────────────────────────

---@alias acp.SessionEvent "update"|"error"|"notification"|"file_written"|"state_change"

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

  ---@type acp.ClientConfig
  local client_config = {
    transport_type = "stdio",
    command = provider.command,
    args = provider.args,
    env = provider.env,
    auth_method = provider.auth_method,
    handlers = {
      on_session_update = function(update)
        session:_emit("update", update)
      end,
      on_error = function(err)
        session:_emit("error", err)
      end,
      on_notification = function(method, params, message_id)
        session:_emit("notification", method, params, message_id)
      end,
      on_request_permission = function(_, options, callback)
        -- Auto-approve: find first allow option
        for _, opt in ipairs(options or {}) do
          if opt.kind == "allow_always" or opt.kind == "allow_once" then
            callback(opt.optionId)
            return
          end
        end
        if options and #options > 0 then
          callback(options[1].optionId)
        else
          callback(nil)
        end
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
end

-- ── Lifecycle ──────────────────────────────────────────────────

---@param cb? fun(err: acp.ACPError|nil)
function Session:connect(cb)
  cb = cb or function() end
  self._state = "connecting"
  self.client:connect(function(err)
    if err then
      self._state = "error"
      cb(err)
      return
    end
    local cwd = vim.fn.getcwd()
    self.client:create_session(cwd, {}, function(session_id, create_err, result)
      if create_err then
        self._state = "error"
        cb(create_err)
        return
      end
      self.session_id = session_id
      self:_extract_session_info(result)
      self._state = "ready"
      cb(nil)
    end)
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
  self._state = "prompting"
  self.client:send_prompt(self.session_id, content_items, function(result, err)
    self._state = "ready"
    if cb then
      cb(result, err)
    end
  end)
end

function Session:cancel()
  if self.session_id then
    self.client:cancel_session(self.session_id)
  end
  if self._state == "prompting" then
    self._state = "ready"
  end
end

---Send a raw JSON-RPC request to the agent.
---@param method string
---@param params? table
---@param cb? fun(result: table|nil, err: table|nil)
function Session:request(method, params, cb)
  self.client:_send_request(method, params or {}, cb or function() end)
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
---@param cb? fun(err: acp.ACPError|nil)
function Session:load(session_id, cb)
  cb = cb or function() end
  local cwd = vim.fn.getcwd()
  self._state = "connecting"
  self.client:load_session(session_id, cwd, {}, function(result, err)
    if err then
      self._state = "error"
      cb(err)
      return
    end
    self.session_id = session_id
    self:_extract_session_info(result)
    self._state = "ready"
    cb(nil)
  end)
end

---Connect and immediately load a session, skipping session/new.
---@param session_id string
---@param cb? fun(err: acp.ACPError|nil)
function Session:connect_and_load(session_id, cb)
  cb = cb or function() end
  self._state = "connecting"
  self.client:connect(function(err)
    if err then
      self._state = "error"
      cb(err)
      return
    end
    self:load(session_id, cb)
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
  return self._state == "ready" or self._state == "prompting"
end

---@return string
function Session:get_state()
  return self._state
end

return Session
