# emeth.nvim

[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)
[![Neovim](https://img.shields.io/badge/Neovim-%E2%89%A5%200.10-green.svg)](https://neovim.io)

AI chat sidebar for Neovim, powered by [ACP](https://agentclientprotocol.com).

"Emeth" (אמת, *truth*) is the word inscribed on a golem's forehead to animate it — erase the א and you get מת (*death*), returning it to clay.

![emeth.nvim screenshot](assets/2026-03-11-07-48-29.png)

## Table of Contents

- [Features](#features)
- [Requirements](#requirements)
- [Installation](#installation)
- [Configuration](#configuration)
- [Usage](#usage)
- [Statusline](#statusline)
- [Adding a Provider](#adding-a-provider)
- [Health](#health)
- [Similar Projects](#similar-projects)
- [Contributing](#contributing)
- [License](#license)

## Features

- Chat sidebar with result + input split
- Markdown rendering with treesitter highlighting
- Tool call visualization with box-drawing, inline diffs, status glyphs
- Thinking/reasoning blocks (collapsible)
- Winbar with spinner, context usage %, compaction indicator
- File context mentions: `@file`, `@buffers`, `@files`
- Prompt templates: `@prompts` (loads `.md` files from configured dirs)
- Session history: list, load, resume previous conversations
- Provider switching on the fly (`:Emeth <provider>`)
- Send visual selections to chat
- Configurable layout, keymaps, icons

## Requirements

- Neovim ≥ 0.10
- At least one ACP-compatible agent CLI (claude-code, gemini-cli, goose, codex, kiro-cli)

## Installation

### [lazy.nvim](https://github.com/folke/lazy.nvim)

Minimal:

```lua
{
  "hador/emeth.nvim",
  cmd = { "Emeth", "EmethToggle", "EmethHistory" },
  keys = {
    { "<leader>ee", "<cmd>Emeth<cr>" },
    { "<leader>et", "<cmd>EmethToggle<cr>" },
    { "<leader>eh", "<cmd>EmethHistory<cr>" },
    { "<leader>es", function() require("emeth").send_selection() end, mode = "v" },
  },
  opts = {
    default_provider = "kiro-cli",
  },
}
```

Full example:

```lua
{
  "hador/emeth.nvim",
  cmd = { "Emeth", "EmethClose", "EmethToggle", "EmethHistory" },
  keys = {
    { "<leader>ee", "<cmd>Emeth<cr>", desc = "Emeth: open chat" },
    { "<leader>et", "<cmd>EmethToggle<cr>", desc = "Emeth: toggle" },
    { "<leader>eh", "<cmd>EmethHistory<cr>", desc = "Emeth: history" },
    { "<leader>es", function() require("emeth").send_selection() end, mode = "v", desc = "Emeth: send selection" },
  },
  opts = {
    default_provider = "kiro-cli",
    resume_last_session = true,
    auto_add_current_file = true,
    prompt_dirs = { "~/.config/prompts" },
    sidebar = {
      position = "right",
      width = 50,
      input_height = 8,
    },
    acp = {
      providers = {
        ["kiro-cli"]    = { command = "kiro-cli", args = { "acp", "--agent", "acp-skills" } },
        ["gemini-cli"]  = { command = "gemini", args = { "--experimental-acp" } },
        ["claude-code"] = { command = "npx", args = { "-y", "-g", "@zed-industries/claude-code-acp" } },
      },
    },
  },
}
```

## Configuration

Default values:

```lua
require("emeth").setup({
  sidebar = {
    position = "right",  -- "right" | "left" | "bottom"
    width = 40,          -- columns (or % of screen for bottom)
    input_height = 8,    -- lines
  },
  mappings = {
    submit = { insert = "<C-s>", normal = "<CR>" },
    close = { normal = { "q", "<Esc>" } },
    switch_window = { normal = "<Tab>" },
  },
  icons = {
    user = "> ",
    assistant = "",
    thinking = "🤔 ",
    tool_generating = "⏳",
    tool_succeeded = "✓",
    tool_failed = "✗",
  },
  default_provider = nil,       -- required if multiple providers configured
  resume_last_session = false,  -- auto-resume last session on open
  auto_add_current_file = true, -- add current buffer as context on open
  prompt_dirs = {},             -- e.g. { "~/.config/prompts", ".prompts" }
  acp = {
    debug = false,
    log_file = vim.fn.stdpath("log") .. "/emeth-acp.log",
    providers = {
      ["claude-code"] = { command = "npx", args = { "-y", "-g", "@zed-industries/claude-code-acp" } },
      ["gemini-cli"]  = { command = "gemini", args = { "--experimental-acp" } },
      ["goose"]       = { command = "goose", args = { "acp" } },
      ["codex"]       = { command = "npx", args = { "-y", "-g", "@zed-industries/codex-acp" } },
      ["kiro-cli"]    = { command = "kiro-cli", args = { "acp", "--agent", "acp-skills" } },
    },
  },
})
```

## Usage

### Commands

| Command | Description |
|---------|-------------|
| `:Emeth [provider]` | Open sidebar and connect (switch provider if different) |
| `:EmethToggle` | Toggle sidebar |
| `:EmethClose` | Close sidebar and disconnect |
| `:EmethHistory` | Pick and resume a previous session |
| `:EmethCancel` | Cancel current AI request |

### Lua API

| Function | Description |
|----------|-------------|
| `require("emeth").open(provider?)` | Open/focus sidebar, optionally switch provider |
| `require("emeth").close()` | Close sidebar and disconnect |
| `require("emeth").toggle(provider?)` | Toggle sidebar |
| `require("emeth").history()` | Pick and resume a previous session |
| `require("emeth").cancel()` | Cancel current AI request |
| `require("emeth").send_selection()` | Send visual selection to chat |

### Provider switching

Switch providers on the fly without closing the sidebar:

```vim
:Emeth kiro-cli     " connect to kiro
:Emeth gemini-cli   " disconnect kiro, connect to gemini
:Emeth              " focus sidebar (no switch)
```

When switching, the chat clears and a fresh session starts. If `resume_last_session` is set, the last session for the new provider is resumed automatically.

### Input buffer

| Key | Mode | Action |
|-----|------|--------|
| `<C-s>` | Insert | Send message |
| `<CR>` | Normal | Send message |
| `<Tab>` | Normal | Switch between input/result |
| `q` / `<Esc>` | Normal | Close sidebar |

### Mentions

Type these in the input buffer:

| Mention | Action |
|---------|--------|
| `@file` | Pick a project file to add as context |
| `@buffers` | Attach all open buffers as context |
| `@files` | Review/remove attached context files |
| `@prompts` | Pick a prompt template from `prompt_dirs` |

## Statusline

emeth.nvim sets `filetype=emeth` on the result buffer. If you use a statusline plugin (lualine, etc.), add `emeth` to its disabled filetypes to keep the sidebar clean:

```lua
-- lualine example
require("lualine").setup({
  options = {
    disabled_filetypes = { statusline = { "emeth" } },
  },
})
```

## Adding a Provider

emeth.nvim works with any ACP-compatible agent CLI. Adding a new provider requires only a config entry. Provider-specific extensions are optional and loaded dynamically.

### Minimal setup

Add an entry to `acp.providers` in your config:

```lua
require("emeth").setup({
  default_provider = "my-agent",
  acp = {
    providers = {
      ["my-agent"] = {
        command = "my-agent",
        args = { "acp" },
        env = { MY_API_KEY = os.getenv("MY_API_KEY") or "" },  -- optional
        auth_method = "my-auth",                                 -- optional
      },
    },
  },
})
```

That's it. The provider will appear in the health check (`:checkhealth emeth`) and can be selected when opening a session.

### What works out of the box

Everything driven by the ACP protocol is handled generically:

- **Streaming** — `agent_message_chunk`, `agent_thought_chunk` render in the result buffer
- **Tool calls** — `tool_call` / `tool_call_update` with status glyphs, inline diffs, box-drawing
- **Slash commands** — `available_commands_update` registers commands in the `/` picker
- **Plans** — `plan` updates render as checklists
- **Session info** — `session_info_update` updates the title
- **File writes** — buffers auto-reload when the agent writes files
- **Winbar** — spinner states (`connecting` → `generating` → `ready`) work for all providers

### Provider-specific extensions (optional)

If your provider sends custom notifications beyond the ACP spec, create a module at:

```
lua/emeth/integrations/<provider-name>.lua
```

It will be loaded automatically when a session uses that provider. The module should export a `setup` function:

```lua
local Winbar = require("emeth.winbar")

local M = {}

---@param session acp.Session
---@param view chat_ui.ChatView
---@return fun() cleanup  -- called on disconnect
function M.setup(session, view)
  local function on_notification(method, params)
    if method == "my_provider/context_usage" then
      -- Update winbar context percentage (0-100)
      vim.schedule(function() Winbar.set_context(params.percentage) end)
    end
  end

  session:on("notification", on_notification)

  return function()
    session:off("notification", on_notification)
  end
end

return M
```

### Winbar API

Extensions can drive the winbar through these functions:

| Function | Description |
|----------|-------------|
| `Winbar.set_state(s)` | Set status: `"connecting"`, `"ready"`, `"generating"`, `"compacting"` |
| `Winbar.set_context(pct)` | Show context window usage (0–100%), color-coded green→yellow→red |

### Session extensions

Providers that return `models` or `modes` in their `createSession` response get them stored in `session.extensions`:

- `session.extensions.model_id` — current model
- `session.extensions.mode_id` — current mode/agent

These are displayed in session metadata and can be updated via custom notifications.

## Health

Run `:checkhealth emeth` to verify the plugin loaded and ACP providers are available.

## Similar Projects

- [avante.nvim](https://github.com/yetone/avante.nvim) — Cursor-style AI editing with diff previews. The original inspiration for this project.
- [codecompanion.nvim](https://github.com/olimorris/codecompanion.nvim) — Multi-adapter chat and inline completions. Broad feature set, adapter-based architecture.
- [copilot-chat.nvim](https://github.com/CopilotC-Nvim/CopilotChat.nvim) — GitHub Copilot chat integration. Copilot-only.

emeth.nvim takes a different approach: it speaks [ACP](https://agentclientprotocol.com) — a standard protocol for agent communication. Any CLI that implements ACP works as a provider with zero glue code. The plugin handles the UI; the agent handles the intelligence.

## Contributing

Contributions are welcome! Feel free to open issues and pull requests.

## License

MIT
