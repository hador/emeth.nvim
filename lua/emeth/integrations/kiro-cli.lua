--- Kiro CLI ACP extensions (_kiro.dev/* notifications).

local Commands = require("emeth.commands")
local Message = require("emeth.message")
local Winbar = require("emeth.ui.winbar")

local M = {}

---Hook kiro-cli-specific notifications into the ACP integration.
---@param session acp.Session
---@param view chat_ui.ChatView
---@return fun() cleanup
function M.setup(session, view)
  local function on_notification(method, params)
    if method == "_kiro.dev/metadata" then
      local pct = params and params.contextUsagePercentage
      if pct then
        vim.schedule(function()
          Winbar.set_context(pct)
        end)
      end
    elseif method == "_kiro.dev/compaction/status" then
      local status_type = params and params.status and params.status.type
      vim.schedule(function()
        if status_type == "started" then
          Winbar.set_state("compacting")
        elseif status_type == "completed" or status_type == "failed" then
          Winbar.set_state("ready")
          if status_type == "completed" and params.summary and params.summary ~= "" then
            view:add_message(Message:new("system", params.summary))
          elseif status_type == "failed" and params.status.error then
            view:add_message(Message:new("system", "Compaction failed: " .. tostring(params.status.error)))
          end
        end
      end)
    elseif method == "_kiro.dev/agent/switched" then
      if params.agentName and session.extensions then
        vim.schedule(function()
          session.extensions.mode_id = params.agentName
        end)
      end
    elseif method == "_kiro.dev/commands/available" then
      vim.schedule(function()
        Commands.clear_acp()
        for _, cmd in ipairs(params and params.commands or {}) do
          if not (cmd.meta and cmd.meta["local"]) then
            local name = cmd.name:gsub("^/", "")
            Commands.register(name, {
              desc = cmd.description or name,
              source = "acp",
              has_args = cmd.meta and cmd.meta.optionsMethod ~= nil,
              execute = function(args, ctx)
                if ctx.view.on_submit then
                  ctx.view.on_submit(cmd.name .. (args ~= "" and (" " .. args) or ""))
                end
              end,
            })
          end
        end
      end)
    end
  end

  session:on("notification", on_notification)

  return function()
    session:off("notification", on_notification)
  end
end

return M
