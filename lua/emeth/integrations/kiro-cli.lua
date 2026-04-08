--- Kiro CLI ACP extensions (_kiro.dev/* notifications).

local Commands = require("emeth.commands")
local Message = require("emeth.message")
local Winbar = require("emeth.ui.winbar")

local M = {}

---Build the merged prompt list from server prompts and local .md files.
---@param server_prompts { label: string, value: string, description?: string, serverName: string }[]
---@param local_files table<string, string>  name → file path
---@param make_on_select fun(fpath: string): fun(ctx: table)
---@return { label: string, value: string, description?: string, source: string, on_select?: fun(ctx: table) }[]
function M.build_prompt_items(server_prompts, local_files, make_on_select)
  local items = {}
  local seen = {}

  for _, p in ipairs(server_prompts) do
    seen[p.value] = true
    local fpath = local_files[p.value]
    if fpath then
      items[#items + 1] = {
        label = p.value,
        value = p.value,
        description = p.description,
        source = "local",
        on_select = make_on_select(fpath),
      }
    else
      items[#items + 1] = { label = p.label, value = p.value, description = p.description, source = p.serverName }
    end
  end

  for pname, fpath in pairs(local_files) do
    if not seen[pname] then
      items[#items + 1] = {
        label = pname,
        value = pname,
        source = "local",
        on_select = make_on_select(fpath),
      }
    end
  end

  return items
end

---Hook kiro-cli-specific notifications into the ACP integration.
---@param session acp.Session
---@param view chat_ui.ChatView
---@return fun() cleanup
function M.setup(session, view)
  -- Server-pushed data cached from _kiro.dev/commands/available
  session.extensions = session.extensions or {}
  session.extensions.server_prompts = {}
  session.extensions.server_agents = {}
  session.extensions.server_models = {}

  ---Build selection options for a command from cached notification data.
  ---@param name string command name without /
  ---@return { label: string, value: string, description?: string, on_select?: fun(ctx: table) }[]|nil
  local function get_selection_options(name)
    local ext = session.extensions or {}
    if name == "agent" then
      return ext.server_agents
    elseif name == "model" then
      return ext.server_models
    elseif name == "prompts" then
      local config = require("emeth").config

      -- Discover local .md prompt files
      local local_files = {} ---@type table<string, string>  name → path
      for _, dir in ipairs(vim.list_extend({ "~/.kiro/prompts" }, config.prompt_dirs or {})) do
        for _, path in ipairs(vim.fn.glob(vim.fn.expand(dir) .. "/*.md", false, true)) do
          local pname = vim.fn.fnamemodify(path, ":t:r")
          local_files[pname] = local_files[pname] or path
        end
      end

      return M.build_prompt_items(ext.server_prompts or {}, local_files, function(fpath)
        return function(ctx)
          local content = table.concat(vim.fn.readfile(fpath), "\n")
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
        end
      end)
    end
  end

  ---Create the execute function for an ACP command, handling selection/panel/freeform.
  ---@param cmd_name string without /
  ---@param cmd_meta table|nil
  ---@return fun(args: string, ctx: table)
  local function make_execute(cmd_name, cmd_meta)
    return function(args, ctx)
      -- If args already provided, send directly
      if args ~= "" then
        if ctx.view.on_submit then
          ctx.view.on_submit("/" .. cmd_name .. " " .. args)
        end
        return
      end

      local input_type = cmd_meta and cmd_meta.inputType
      if input_type == "selection" then
        local options = get_selection_options(cmd_name)
        if options and #options > 0 then
          vim.ui.select(options, {
            prompt = "/" .. cmd_name,
            format_item = function(item)
              local s = item.label or item.value
              if item.description then
                s = s .. "  " .. item.description
              end
              if item.source then
                s = s .. "  [" .. item.source .. "]"
              end
              return s
            end,
          }, function(choice)
            if choice then
              if choice.on_select then
                choice.on_select(ctx)
              elseif ctx.view.on_submit then
                ctx.view.on_submit("/" .. cmd_name .. " " .. choice.value)
              end
            end
          end)
          return
        end
      end

      -- Freeform: pre-fill with hint or just the command
      local hint = cmd_meta and cmd_meta.hint
      if hint and hint ~= "" then
        vim.api.nvim_buf_set_lines(ctx.view.input_buf, 0, -1, false, { "/" .. cmd_name .. " " })
        -- Show hint as virtual text
        local ns = vim.api.nvim_create_namespace("emeth_cmd_hint")
        vim.api.nvim_buf_set_extmark(ctx.view.input_buf, ns, 0, #cmd_name + 2, {
          virt_text = { { hint, "Comment" } },
          virt_text_pos = "overlay",
        })
        -- Clear hint on next edit
        vim.api.nvim_create_autocmd({ "TextChangedI", "TextChanged" }, {
          buffer = ctx.view.input_buf,
          once = true,
          callback = function()
            vim.api.nvim_buf_clear_namespace(ctx.view.input_buf, ns, 0, -1)
          end,
        })
        vim.cmd("startinsert!")
      else
        if ctx.view.on_submit then
          ctx.view.on_submit("/" .. cmd_name)
        end
      end
    end
  end

  local function on_notification(method, params)
    if method == "_kiro.dev/metadata" then
      local pct = params and params.contextUsagePercentage
      if pct then
        vim.schedule(function()
          Winbar.set_context(pct)
        end)
      end
    elseif method == "_kiro.dev/subagent/list_update" then
      vim.schedule(function()
        local ext = session.extensions or {}
        ext.subagent_sessions = ext.subagent_sessions or {}
        -- Rebuild the sessionId → name map from the latest list
        local map = {}
        local active = {}
        for _, sa in ipairs(params.subagents or {}) do
          if sa.sessionId then
            map[sa.sessionId] = sa.sessionName or sa.agentName or sa.sessionId
          end
          if sa.status and sa.status.type == "working" then
            active[#active + 1] = sa.sessionName or sa.agentName or "subagent"
          end
        end
        ext.subagent_sessions = map
        -- Winbar badge
        if #active > 0 then
          Winbar.set_badge("subagent", "⑂ " .. table.concat(active, ", "))
        else
          Winbar.clear_badge("subagent")
        end
        -- Wire up the resolver if integration is available
        if view.integration and view.integration.set_resolve_sender then
          view.integration.set_resolve_sender(function(sid)
            return ext.subagent_sessions[sid]
          end)
        end
      end)
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
        local ext = session.extensions or {}

        -- Cache prompts from notification
        ext.server_prompts = {}
        for _, p in ipairs(params.prompts or {}) do
          ext.server_prompts[#ext.server_prompts + 1] = {
            label = p.name,
            value = p.name,
            description = p.description ~= vim.NIL and p.description or nil,
            serverName = p.serverName,
            arguments = p.arguments,
          }
        end

        -- Cache agents/models from session/new result (already in extensions)
        -- These are populated by _extract_session_info; here we just build
        -- the options list from the modes/models if present in the notification
        -- (they aren't in commands/available, but we keep the cache from session/new)

        -- Register commands
        Commands.clear_acp()
        for _, cmd in ipairs(params.commands or {}) do
          if not (cmd.meta and cmd.meta["local"]) then
            local name = cmd.name:gsub("^/", "")
            local meta = cmd.meta
            local is_picker = meta and meta.inputType == "selection"
            local has_hint = meta and meta.hint and meta.hint ~= ""
            Commands.register(name, {
              desc = cmd.description or name,
              source = "acp",
              has_args = is_picker or has_hint,
              has_picker = is_picker,
              execute = make_execute(name, meta),
            })
          end
        end
      end)
    end
  end

  session:on("notification", on_notification)

  -- Also cache agents/models from session/new result into selection options
  local orig_extract = session._extract_session_info
  ---@diagnostic disable-next-line: duplicate-set-field
  function session:_extract_session_info(result)
    orig_extract(self, result)
    if not result then
      return
    end
    local ext = self.extensions or {}
    if result.modes and result.modes.availableModes then
      ext.server_agents = {}
      for _, m in ipairs(result.modes.availableModes) do
        ext.server_agents[#ext.server_agents + 1] = {
          label = m.name or m.id,
          value = m.id,
          description = m.description,
        }
      end
    end
    if result.models and result.models.availableModels then
      ext.server_models = {}
      for _, m in ipairs(result.models.availableModels) do
        ext.server_models[#ext.server_models + 1] = {
          label = m.name or m.modelId,
          value = m.modelId,
          description = m.description,
        }
      end
    end
  end

  return function()
    session:off("notification", on_notification)
    session._extract_session_info = orig_extract
  end
end

return M
