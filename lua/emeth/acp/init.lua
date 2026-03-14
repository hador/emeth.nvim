local Session = require("emeth.acp.session")

---@class acp.Config
---@field debug boolean
---@field log_file string
---@field providers table<string, acp.ProviderConfig>
---@field on_update? fun(update: table) Fallback: session update (prefer session:on("update"))
---@field on_error? fun(err: table) Fallback: error (prefer session:on("error"))
---@field on_notification? fun(method: string, params: table, message_id: number|nil) Fallback
---@field on_file_written? fun(path: string, first_changed: number|nil) Fallback
---@field on_state_change? fun(state: acp.ConnectionState, old_state: acp.ConnectionState) Fallback

---@class acp.ProviderConfig
---@field command string
---@field args? string[]
---@field env? table<string, string>
---@field auth_method? string

---@class acp.Module
---@field config acp.Config
local M = {}

---@type acp.Config
local defaults = {
  debug = false,
  log_file = vim.fn.stdpath("log") .. "/emeth-acp.log",
  providers = {
    ["claude-code"] = {
      command = "npx",
      args = { "-y", "-g", "@zed-industries/claude-code-acp" },
    },
    ["gemini-cli"] = {
      command = "gemini",
      args = { "--experimental-acp" },
    },
    ["goose"] = {
      command = "goose",
      args = { "acp" },
    },
    ["codex"] = {
      command = "npx",
      args = { "-y", "-g", "@zed-industries/codex-acp" },
    },
    ["kiro-cli"] = {
      command = "kiro-cli",
      args = { "acp" },
    },
  },
  on_update = nil,
  on_error = nil,
  on_notification = nil,
  on_file_written = nil,
  on_state_change = nil,
}

M.config = vim.deepcopy(defaults)

---@param opts? table
function M.setup(opts)
  M.config = vim.tbl_deep_extend("force", vim.deepcopy(defaults), opts or {})
end

---@param provider_name string
---@return acp.Session
function M.create_session(provider_name)
  return Session:new(provider_name)
end

return M
