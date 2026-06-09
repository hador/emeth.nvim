--- Slash command registry for emeth.
---@diagnostic disable: undefined-field

---@class emeth.Command
---@field desc string
---@field execute fun(args: string, ctx: { view: chat_ui.ChatView, integration: table })
---@field source "builtin"|"acp"
---@field hint? string         Argument hint shown as virt-text after prefill (e.g. "<model_id>")
---@field has_picker? boolean  Command runs its own picker UI; bypass the prefill flow
---@field immediate? boolean   Run execute() immediately on selection (no prefill)

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
    immediate = true,
    execute = function(_, ctx)
      ctx.view:clear()
    end,
  })

  M.register("new", {
    desc = "Start a new session",
    source = "builtin",
    immediate = true,
    execute = function(_, ctx)
      if ctx.integration and ctx.integration.new_session then
        ctx.integration.new_session()
      end
    end,
  })

  M.register("help", {
    desc = "List available commands",
    source = "builtin",
    immediate = true,
    execute = function(_, ctx)
      local Message = require("emeth.message")
      local lines = { "**Available commands:**" }
      for _, cmd in ipairs(M.list()) do
        lines[#lines + 1] = ("  `/%s` — %s"):format(cmd.name, cmd.desc)
      end
      ctx.view:add_message(Message:new("system", table.concat(lines, "\n")))
    end,
  })

  M.register("prompts", {
    desc = "Insert a prompt from prompt_dirs",
    source = "builtin",
    has_picker = true,
    execute = function(_, ctx)
      -- If an ACP provider also registered /prompts (e.g. kiro-cli), it
      -- handles local+server prompt merging itself — skip the builtin picker
      -- to avoid showing two pickers in sequence.
      local self_cmd = commands["prompts"]
      if self_cmd and self_cmd._builtin then
        return
      end

      local config = require("emeth").config
      local dirs = config.prompt_dirs or {}
      if #dirs == 0 then
        vim.notify("[emeth] No prompt_dirs configured", vim.log.levels.WARN)
        return
      end

      -- Discover local .md prompt files
      local items = {} ---@type { label: string, path: string }[]
      for _, dir in ipairs(dirs) do
        for _, path in ipairs(vim.fn.glob(vim.fn.expand(dir) .. "/*.md", false, true)) do
          items[#items + 1] = {
            label = vim.fn.fnamemodify(path, ":t:r"),
            path = path,
          }
        end
      end

      if #items == 0 then
        vim.notify("[emeth] No .md prompts found in prompt_dirs", vim.log.levels.INFO)
        return
      end

      vim.ui.select(items, {
        prompt = "Prompt:",
        format_item = function(item)
          return item.label
        end,
      }, function(choice)
        if not choice then
          return
        end
        local content = table.concat(vim.fn.readfile(choice.path), "\n")
        if config.prompt_edit_before_send then
          local wins = vim.fn.win_findbuf(ctx.view.input_buf)
          if wins[1] then
            vim.api.nvim_set_current_win(wins[1])
          end
          vim.api.nvim_buf_set_lines(ctx.view.input_buf, 0, -1, false, vim.split(content, "\n"))
          vim.cmd("startinsert!")
        elseif ctx.view.on_submit then
          ctx.view.on_submit(content)
        end
      end)
    end,
  })
end

return M
