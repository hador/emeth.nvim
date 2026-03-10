--- ACP integration glue — wires emeth_acp Session to a ChatView.

local Message = require("emeth.message")
local Winbar = require("emeth.winbar")

local M = {}

---@param view chat_ui.ChatView
---@param session acp.Session
---@return { connect: fun(cb?: fun(err: any)), disconnect: fun(), add_file: fun(path: string), remove_file: fun(path: string), pick_file: fun(), selected_files: fun(): string[] }
function M.setup_integration(view, session)
  -- Track the current streaming assistant message uuid
  local current_assistant_uuid = nil
  local current_thinking_uuid = nil
  local tool_message_map = {} ---@type table<string, string> toolCallId -> message uuid
  local selected_files = {} ---@type string[] absolute paths

  local function refresh_file_display()
    view:set_context_files(selected_files)
  end

  -- Wire file removal from input buffer
  view.on_remove_file = function(idx)
    table.remove(selected_files, idx)
    refresh_file_display()
  end

  -- Wire @mention handlers
  view._mention_handlers = {
    file = function()
      local cwd = vim.fn.getcwd()
      local files
      local git_out = vim.fn.systemlist({ "git", "-C", cwd, "ls-files", "--cached", "--others", "--exclude-standard" })
      if vim.v.shell_error == 0 and #git_out > 0 then
        files = git_out
      else
        files = vim.fn.glob(cwd .. "/**/*", false, true)
        files = vim.tbl_filter(function(f) return vim.fn.isdirectory(f) == 0 end, files)
        for i, f in ipairs(files) do files[i] = vim.fn.fnamemodify(f, ":.") end
      end
      vim.ui.select(files, { prompt = "Add file to context:" }, function(choice)
        if not choice then return end
        local abs = vim.fn.fnamemodify(choice, ":p")
        if not vim.tbl_contains(selected_files, abs) then
          selected_files[#selected_files + 1] = abs
          refresh_file_display()
        end
      end)
    end,
    buffers = function()
      for _, buf in ipairs(vim.api.nvim_list_bufs()) do
        if vim.api.nvim_buf_is_loaded(buf) and vim.bo[buf].buflisted then
          local name = vim.api.nvim_buf_get_name(buf)
          if name ~= "" and vim.fn.filereadable(name) == 1
            and not vim.tbl_contains(selected_files, name) then
            selected_files[#selected_files + 1] = name
          end
        end
      end
      refresh_file_display()
    end,
    files = function()
      view:open_file_manager()
    end,
  }

  -- Wire user input to ACP
  view.on_submit = function(text)
    -- Build prompt: resource_links for selected files + text
    local prompt = {}
    for _, fpath in ipairs(selected_files) do
      local name = vim.fn.fnamemodify(fpath, ":t")
      prompt[#prompt + 1] = {
        type = "resource_link",
        uri = "file://" .. fpath,
        name = name,
      }
    end
    prompt[#prompt + 1] = { type = "text", text = text }

    local msg = Message:new("user", text, { selected_files = vim.deepcopy(selected_files) })
    view:add_message(msg)
    current_assistant_uuid = nil
    current_thinking_uuid = nil
    Winbar.set_state("generating")
    session:send_prompt(prompt, function()
      vim.schedule(function() Winbar.set_state("ready") end)
    end)
  end

  -- Wire ACP session updates to ChatView
  local acp = require("emeth_acp")
  local prev_on_session_update = acp.config.on_session_update

  acp.config.on_session_update = function(update)
    vim.schedule(function()
      if update.sessionUpdate == "user_message_chunk" then
        -- Replayed user message from session/load
        if update.content and update.content.type == "text" then
          local msg = Message:new("user", update.content.text)
          view:add_message(msg)
        end

      elseif update.sessionUpdate == "agent_message_chunk" then
        if update.content and update.content.type == "text" then
          if current_assistant_uuid then
            view:update_message(current_assistant_uuid, function(msg)
              msg:append_text(update.content.text)
            end)
          else
            local msg = Message:new("assistant", update.content.text)
            current_assistant_uuid = msg.uuid
            current_thinking_uuid = nil
            view:add_message(msg)
          end
        end

      elseif update.sessionUpdate == "agent_thought_chunk" then
        if update.content and update.content.type == "text" then
          if current_thinking_uuid then
            view:update_message(current_thinking_uuid, function(msg)
              if type(msg.content) == "table" then
                for _, item in ipairs(msg.content) do
                  if item.type == "thinking" then
                    item.thinking = (item.thinking or "") .. update.content.text
                    return
                  end
                end
              end
            end)
          else
            local msg = Message:new("assistant", {
              type = "thinking",
              thinking = update.content.text,
            })
            current_thinking_uuid = msg.uuid
            current_assistant_uuid = nil
            view:add_message(msg)
          end
        end

      elseif update.sessionUpdate == "tool_call" then
        current_assistant_uuid = nil
        current_thinking_uuid = nil
        local status = update.status or "pending"
        local msg = Message:new("assistant", {
          type = "tool_use",
          name = update.kind or update.title or "tool",
          id = update.toolCallId,
          input = update.rawInput or {},
          status = status,
        }, {
          tool_call = update,
        })
        tool_message_map[update.toolCallId] = msg.uuid
        view:add_message(msg)

      elseif update.sessionUpdate == "tool_call_update" then
        local uuid = tool_message_map[update.toolCallId]
        if uuid then
          view:update_message(uuid, function(msg)
            if type(msg.content) == "table" then
              for _, item in ipairs(msg.content) do
                if item.type == "tool_use" and item.id == update.toolCallId then
                  if update.status then item.status = update.status end
                  if update.title then item.name = update.title end
                  if update.rawInput then item.input = update.rawInput end
                end
              end
            end
            -- Merge tool_call metadata
            if msg.metadata.tool_call then
              if update.content and next(update.content) ~= nil then
                msg.metadata.tool_call.content = update.content
              end
              if update.status then msg.metadata.tool_call.status = update.status end
              if update.title then msg.metadata.tool_call.title = update.title end
              if update.rawOutput then msg.metadata.tool_call.rawOutput = update.rawOutput end
              if update.locations then msg.metadata.tool_call.locations = update.locations end
            end
          end)
        end

      elseif update.sessionUpdate == "plan" then
        -- Render plan as a system message
        local parts = { "**Plan:**" }
        for _, entry in ipairs(update.entries or {}) do
          local icon = entry.status == "completed" and "✓"
            or entry.status == "in_progress" and "→"
            or "○"
          parts[#parts + 1] = icon .. " " .. entry.content
        end
        local msg = Message:new("system", table.concat(parts, "\n"))
        view:add_message(msg)

      elseif update.sessionUpdate == "session_info_update" then
        -- Store title on the view for display/picker use
        if update.title then
          view._session_title = update.title
        end
      end
    end)

    if prev_on_session_update then prev_on_session_update(update) end
  end

  -- Wire errors
  local prev_on_error = acp.config.on_error
  acp.config.on_error = function(err)
    vim.schedule(function()
      local text = "**Error:** " .. (err.message or vim.inspect(err))
      view:add_message(Message:new("assistant", text))
    end)
    if prev_on_error then prev_on_error(err) end
  end

  -- Wire kiro-cli specific notifications (context usage, compaction)
  local prev_on_notification = acp.config.on_notification
  acp.config.on_notification = function(method, params, message_id)
    if method == "_kiro.dev/metadata" then
      local pct = params and params.contextUsagePercentage
      if pct then
        vim.schedule(function() Winbar.set_context(pct) end)
      end
    elseif method == "_kiro.dev/compaction/status" then
      local status_type = params and params.status and params.status.type
      vim.schedule(function() Winbar.set_compacting(status_type == "started") end)
    end
    if prev_on_notification then prev_on_notification(method, params, message_id) end
  end

  return {
    connect = function(cb)
      -- Attach winbar immediately so we can show "connecting"
      local emeth = require("emeth")
      local sidebar = emeth.get_sidebar()
      if sidebar and sidebar.result_win then
        Winbar.attach(sidebar.result_win)
      end
      Winbar.set_state("connecting")

      session:connect(function(err)
        if err then
          vim.schedule(function()
            Winbar.set_state("idle")
            view:add_message(Message:new("system", "Failed to connect: " .. (err.message or "unknown error")))
          end)
        else
          vim.schedule(function()
            Winbar.set_state("ready")
            view:add_message(Message:new("system", "Connected to " .. session.provider_name .. ". Type your message below."))
          end)
        end
        if cb then cb(err) end
      end)
    end,
    ---Load a previous session. Agent replays conversation via session/update.
    ---@param session_id string
    ---@param cb? fun(err: any)
    load_session = function(session_id, cb)
      view:clear()
      current_assistant_uuid = nil
      current_thinking_uuid = nil
      tool_message_map = {}
      session:load(session_id, function(err)
        if err then
          vim.schedule(function()
            view:add_message(Message:new("system", "Failed to load session: " .. (err.message or "unknown error")))
          end)
        end
        if cb then cb(err) end
      end)
    end,
    ---List sessions and let user pick one to resume.
    pick_session = function()
      session:list_sessions(function(sessions, err)
        if err or not sessions or #sessions == 0 then
          vim.schedule(function()
            vim.notify("[emeth] " .. (err and err.message or "No previous sessions found"), vim.log.levels.INFO)
          end)
          return
        end
        vim.schedule(function()
          local items = {}
          for _, s in ipairs(sessions) do
            items[#items + 1] = {
              label = (s.title or s.sessionId) .. (s.updatedAt and ("  " .. s.updatedAt) or ""),
              session_id = s.sessionId,
            }
          end
          vim.ui.select(items, {
            prompt = "Resume session:",
            format_item = function(item) return item.label end,
          }, function(choice)
            if not choice then return end
            view:clear()
            current_assistant_uuid = nil
            current_thinking_uuid = nil
            tool_message_map = {}
            session:load(choice.session_id, function(load_err)
              if load_err then
                vim.schedule(function()
                  view:add_message(Message:new("system", "Failed to load: " .. (load_err.message or "unknown")))
                end)
              end
            end)
          end)
        end)
      end)
    end,
    disconnect = function()
      Winbar.detach()
      session:disconnect()
      acp.config.on_session_update = prev_on_session_update
      acp.config.on_error = prev_on_error
      acp.config.on_notification = prev_on_notification
    end,

    ---@param path string absolute path
    add_file = function(path)
      path = vim.fn.fnamemodify(path, ":p")
      if not vim.tbl_contains(selected_files, path) then
        selected_files[#selected_files + 1] = path
        refresh_file_display()
      end
    end,

    ---@param path string absolute path
    remove_file = function(path)
      path = vim.fn.fnamemodify(path, ":p")
      for i, f in ipairs(selected_files) do
        if f == path then
          table.remove(selected_files, i)
          refresh_file_display()
          return
        end
      end
    end,

    ---@return string[]
    get_selected_files = function()
      return selected_files
    end,
  }
end

return M
