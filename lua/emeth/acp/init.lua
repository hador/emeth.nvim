local Session = require("emeth.acp.session")

---@class acp.Config
---@field debug boolean
---@field auto_approve_tools boolean
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
---@field pass_env? string[]  Environment variable names to pass from the current process
---@field auth_method? string
---@field capabilities_meta? table  Merged into `clientCapabilities._meta` at initialize
---@field capabilities? table  Extra top-level `clientCapabilities` advertised at initialize

---@class acp.Module
---@field config acp.Config
local M = {}

---@type acp.Config
local defaults = {
  debug = false,
  auto_approve_tools = false,
  providers = {
    ["claude-code"] = {
      command = "npx",
      args = { "-y", "-g", "@agentclientprotocol/claude-agent-acp" },
      pass_env = { "ANTHROPIC_API_KEY", "ANTHROPIC_AUTH_TOKEN", "ANTHROPIC_BASE_URL", "CLAUDE_MODEL_CONFIG" },
      -- Without it claude-acp (>= ~0.86) reports a subagent as one opaque tool
      -- call and sends none of its work. With it, each subagent runs as a child
      -- session announced by `subagent_update` (ACP subagents RFD).
      capabilities = { subagents = vim.empty_dict() },
    },
    ["gemini-cli"] = {
      command = "gemini",
      args = { "--acp" },
      pass_env = { "GEMINI_API_KEY" },
    },
    ["goose"] = {
      command = "goose",
      args = { "acp" },
    },
    ["codex"] = {
      command = "npx",
      args = { "-y", "-g", "@zed-industries/codex-acp" },
      pass_env = { "OPENAI_API_KEY" },
    },
    ["kiro-cli"] = {
      command = "kiro-cli",
      -- v3 (Kiro Agent Server-backed) ACP. `acp` alone still defaults to the
      -- legacy v2 engine; v3 is selected explicitly. `--auth-method=cli` keeps
      -- token handling in the CLI relay (otherwise the client must implement
      -- `_kiro/auth/getAccessToken`).
      args = { "acp", "--agent-engine=v3", "--auth-method=cli" },
      -- Advertised so the agent drives its MCP OAuth flow through our
      -- `_kiro/openExternalUrl` request handler.
      capabilities_meta = { kiro = { openExternalUrl = true } },
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
