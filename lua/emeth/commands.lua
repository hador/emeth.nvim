--- Slash command registry for emeth.
---@diagnostic disable: undefined-field

---@class emeth.Command
---@field desc string
---@field execute fun(args: string, ctx: { view: chat_ui.ChatView, integration: table })
---@field source "builtin"|"acp"
---@field has_args? boolean
---@field has_picker? boolean  Command handles its own arg collection (e.g. selection picker)

local M = {}

---@type table<string, emeth.Command>
local commands = {}

---@param name string without leading /
---@param cmd emeth.Command
function M.register(name, cmd)
  local existing = commands[name]
  if existing and (existing.source == "builtin" or existing._builtin) and cmd.source == "acp" then
    local builtin_execute = existing._builtin or existing.execute
    local acp_execute = cmd.execute
    cmd._builtin = builtin_execute
    cmd.source = "builtin"
    cmd.execute = function(args, ctx)
      builtin_execute(args, ctx)
      acp_execute(args, ctx)
    end
  end
  commands[name] = cmd
end

---@param name string
function M.unregister(name)
  commands[name] = nil
end

---@return { name: string, desc: string, source: string }[]
function M.list()
  local result = {}
  for name, cmd in pairs(commands) do
    result[#result + 1] = { name = name, desc = cmd.desc, source = cmd.source }
  end
  table.sort(result, function(a, b)
    return a.name < b.name
  end)
  return result
end

---@param name string
---@return emeth.Command?
function M.get(name)
  return commands[name]
end

function M.clear_acp()
  for name, cmd in pairs(commands) do
    if cmd.source == "acp" then
      commands[name] = nil
    elseif cmd._builtin then
      cmd.execute = cmd._builtin
      cmd._builtin = nil
    end
  end
end

--- Register builtins.
function M.register_builtins()
  M.register("clear", {
    desc = "Clear chat messages",
    source = "builtin",
    execute = function(_, ctx)
      ctx.view:clear()
    end,
  })

  M.register("new", {
    desc = "Start a new session",
    source = "builtin",
    execute = function(_, ctx)
      if ctx.integration and ctx.integration.new_session then
        ctx.integration.new_session()
      end
    end,
  })

  M.register("help", {
    desc = "List available commands",
    source = "builtin",
    execute = function(_, ctx)
      local Message = require("emeth.message")
      local lines = { "**Available commands:**" }
      for _, cmd in ipairs(M.list()) do
        lines[#lines + 1] = ("  `/%s` — %s"):format(cmd.name, cmd.desc)
      end
      ctx.view:add_message(Message:new("system", table.concat(lines, "\n")))
    end,
  })
end

return M
