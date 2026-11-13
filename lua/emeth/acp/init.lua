local Session = require("emeth.acp.session")

---@class acp.Config
---@field debug boolean
---@field auto_approve_tools boolean
---@field providers table<string, acp.ProviderConfig>

---@class acp.ProviderConfig
---@field command string
---@field args? string[]
---@field env? table<string, string>
---@field pass_env? string[]  Environment variable names to pass from the current process
---@field auth_method? string
---@field capabilities_meta? table  Merged into `clientCapabilities._meta` at initialize
---@field capabilities? table  Extra top-level `clientCapabilities` advertised at initialize
---@field remote? boolean  Agent runs on another host (e.g. over ssh): session cwds are remote paths, so
---  emeth never checks or `cd`s into them; the agent's own session/load decides resumability.
---@field map_path? fun(path: string, ctx: { provider: string, session_id?: string }): string|false|nil
---  Where a path this agent reports opens locally (gf/gd), e.g. `"oil-ssh://host/" .. path`; `ctx` names
---  the session it came from. Return false when it can't be opened, nil for the default (as when unset):
---  a remote provider's paths don't open; anyone else's open as-is.

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
      args = { "-y", "@agentclientprotocol/claude-agent-acp" },
      pass_env = { "ANTHROPIC_API_KEY", "ANTHROPIC_AUTH_TOKEN", "ANTHROPIC_BASE_URL", "CLAUDE_MODEL_CONFIG" },
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
      args = { "-y", "@zed-industries/codex-acp" },
      pass_env = { "OPENAI_API_KEY" },
    },
    ["kiro-cli"] = {
      command = "kiro-cli",
      -- v3 (Kiro Agent Server-backed) ACP. `acp` alone still defaults to the
      -- legacy v2 engine (`acp --help`, 2.34.2), so v3 is selected explicitly.
      -- `--auth-method=cli` (the current default, pinned here) keeps token
      -- handling in the CLI relay; "client" would require emeth to implement
      -- `_kiro/auth/getAccessToken`.
      args = { "acp", "--agent-engine=v3", "--auth-method=cli" },
    },
    ["opencode"] = {
      command = "opencode",
      args = { "acp" },
    },
  },
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
