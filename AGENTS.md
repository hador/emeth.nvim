# Agent Guide — emeth.nvim

ACP (Agent Client Protocol) chat sidebar for Neovim ≥ 0.10. Talks to coding agents
(claude-code, gemini-cli, goose, codex, kiro-cli, opencode) as ACP clients: they are
spawned as subprocesses, communicate over JSON-RPC, and emeth renders their transcripts
in a split sidebar with an edit-able input buffer.

## Commands

All from the repo root:

| Task | Command |
|---|---|
| Everything (lint + test + typecheck) | `make all` |
| Tests | `make test` |
| Lint (stylua + luacheck) | `make lint` |
| Typecheck | `make typecheck` |
| Human-readable render timings | `make bench` |

- Tests are a single headless nvim process: `nvim --headless -u tests/minimal_init.lua -c "lua dofile('tests/run.lua')"`.
- To run one test file, swap the last part: `-c "lua dofile('tests/test_chat_view.lua')"`.
- `tests/run.lua` dofile's every `tests/test_*.lua` in sorted (alphabetical) order in
  that one process — test files must not leave globals behind.
- **CI vs local drift:** CI checks `stylua --check lua/` only and `luacheck lua/ plugin/`
  (see `.github/workflows/ci.yml`); local `make lint` additionally covers `tests/`. A
  `make all` failure in `tests/` lint can still be CI-green.
- Typecheck uses `lua-language-server --check . --checklevel=Warning` with `.luarc.json`;
  that config sets `workspace.ignoreDir: ["tests"]`, so `tests/` is **not** typechecked.

## Architecture

Four layers, roughly top-to-bottom:

```
plugin/emeth.lua          User commands: :Emeth [provider], :EmethNew, :EmethClose,
                          :EmethToggle, :EmethZoom, :EmethHistory
lua/emeth/init.lua        Top level: config defaults (M.config), sidebar/view
                          lifecycle, provider resolution, resume/history.
                          API: setup, open(provider, opts), close, toggle, zoom,
                          resume, history, destroy_session, cancel, send_selection,
                          get_sidebar. Module state: file-locals _view/_sidebar,
                          exported fields M._integration/M._provider/M._closing.
lua/emeth/ui/*, layout/*  Rendering: ChatView (result + input buffers), prompt queue,
                          paste folding, winbar, pickers, sidebar layout
lua/emeth/acp/*           ACP core: JSON-RPC client, Session API, elicitations, types
lua/emeth/integrations/*  Glue between Session and ChatView + per-provider extensions
```

Support modules: `sessions.lua` (local session index), `message.lua` (protocol-agnostic
message model), `commands.lua` (slash-command registry), `target.lua` (source-window
routing for file opens), `util.lua`, `validity.lua` (can an indexed session still be
resumed), `health.lua` (provider PATH check; `:checkhealth emeth` resolves to
`require("emeth.health").check()` via Neovim's `lua/**/emeth/health.lua` rtp lookup
— so the command works out of the box as long as the plugin dir is on the runtimepath).

### ACP core (`lua/emeth/acp/`)

- `init.lua` — provider registry `M.config.providers` (each: required `command`,
  optional `args`, `env`, `pass_env`, `auth_method`, `capabilities`, `capabilities_meta`),
  plus `debug` and `auto_approve_tools` (default **false**).
- `client.lua` — JSON-RPC transport and session methods: `initialize`, `authenticate`,
  `session/new`, `session/load`, `session/prompt`, `session/cancel` (notification),
  `session/close`, `session/delete`, `session/fork`, `session/set_config_option`, plus
  generic `request`; inbound handlers for `session/update`, `session/request_permission`,
  `elicitation/create`, `fs/read_text_file`, `fs/write_text_file`, with fallback routing
  to provider extension `on_request`/`on_notification`.
- `session.lua` — `Session` class: lifecycle, event emitter
  (`on` events: `update`, `notification`, `file_written`, `permission`, `elicitation`).
- `elicitation.lua` — elicitation schema logic (pure spec, no UI knowledge).
- `types.lua` — `---@meta` type definitions for the protocol.

### Integration layer (`lua/emeth/integrations/`)

`acp.lua` is the generic glue: `M.setup_integration(view, session) → integration`,
assigned to `view.integration`. Its return table provides `connect`, `load_session`,
`connect_and_load`, `new_session`, `fork`, `rewind(meta)`, `disconnect`, `cancel`,
`add_file`, `resync_winbar`, plus the extension setters (`set_transform_update`,
`set_transform_elicitation`, `set_steering`) that a provider extension populates.

Provider extensions are **optional hooks** loaded from
`lua/emeth/integrations/<provider>.lua` (only `claude-code.lua`, `opencode.lua`,
`kiro-cli.lua` exist): `setup(session, view) → cleanup`, `build_session_meta(emeth_config, kind)`,
`format_mode(mode_id)`, `format_model(model_id)`. Extensions may also register in-place
transforms (`set_transform_update` / `set_transform_elicitation`) or steering (`set_steering`) during `setup`.
The generic layer knows only this shape — it knows nothing about specific agents.

Split-out submodules: `acp_updates.lua` (one handler per `sessionUpdate` type),
`acp_prompts.lua` (permission + elicitation prompt rendering), `roots.lua`
(workspace roots / `additionalDirectories` + `@workspace`/`@roots` mentions).

### UI (`lua/emeth/ui/`, `lua/emeth/layout/`)

- `chat_view.lua` — owns two buffers named `emeth://result` (transcript) and
  `emeth://input` (editable prompt). Dirty rendering via
  `_line_cache`, `_dirty`, `_dirty_all`, `_dirty_from`.
- `prompt_queue.lua` — one FIFO mechanism behind *both* tool permissions and agent
  elicitations; only the head prompt is live.
- `paste_fold.lua` — collapses large pastes in the input buffer to one placeholder line.
- `render.lua` — pure message renderer: `render_message(msg, messages) → Line[]` (testable without a window).
- `winbar.lua`, `session_picker.lua`, `line.lua`, `highlights.lua`; `layout/sidebar.lua`
  arranges the result/input split.

## Invariants & gotchas (verified against the code)

- **One live client at a time.** `client.lua` keeps a module-global `active_client`;
  starting a new client stops the previous one. Two concurrent provider sessions are
  not supported.
- **Auto-approve is decided in exactly one place**: `auto_approve_choice` in
  `acp/session.lua` (the single source of truth). It answers `allow_always` first,
  then `allow_once`, else `options[1]`; returns `nil` (ask the user) when
  `auto_approve_tools` is off, when the request `kind == "switch_mode"` (a plan-mode
  gate is never auto-approved), or when no options are offered. Do not add a second
  policy in the UI layer.
- **Prompt keys are claimed, not bound.** `prompt_queue.lua` calls
  `view:set_prompt_keys(spec.owner, claims)` at activation and
  `view:clear_prompt_keys(spec.owner)` on close/drain. The view owns the keymaps
  permanently; releasing a claim must restore the previous binding, not remove the
  mapping.
- **Paste text never lives in the input buffer.** `paste_fold.lua` stores raw text in
  `ChatView._pastes` (id → `{text, placeholder, mark}`) with an extmark per placeholder;
  a placeholder is honored only while its line text exactly equals the placeholder.
  It works by overriding the *global* `vim.paste` while the view is up — teardown must
  restore the true original (tracked so re-install wraps the original, not a wrapper).
- **Session index** is `stdpath("state")/emeth/sessions.json` (`sessions.lua`), entries:
  `{ session_id, provider, cwd, title?, additional_directories?, forked_from?,
  created_at, updated_at }`. `forked_from` is **write-once** (lineage must survive
  later lazy saves). It is the *only* cross-directory source of sessions — the agent's
  own `session/list` is per-cwd and needs a live connection.
- **Tests share one process.** `tests/minimal_init.lua` sandboxes
  `XDG_STATE_HOME`/`XDG_DATA_HOME`/`XDG_CACHE_HOME` to a temp dir — but `stdpath("config")`
  is *not* sandboxed; don't write there in tests. `tests/acp_harness.lua` mutates
  globals (Winbar, keymaps) and requires each test file to use `install()` and call its
  returned restore — leaking the stubs breaks `test_winbar.lua`, which runs later
  (alphabetically) and asserts against the *real* Winbar.
- **Rewind = fork + reload** (`integrations/acp.lua`): rewind forks at a
  provider-specific point (`meta` rides the fork's `_meta`), saves the new entry with
  `forked_from`, then clears the transcript and `session/load`s the fork — the old
  transcript stays on screen until the replay is ready.

## Conventions

- **stylua** (`stylua.toml`): 120 cols, 2-space indent, `AutoPreferDouble` quotes,
  always parens, Unix line endings. Run `make lint` before committing.
- **luacheck** (`.luacheckrc`): `std = "luajit"`, `globals = { "vim" }`, ignores
  `212/self` and `631` (line length).
- Comments are prose-heavy and explain *why*; preserve that style when touching
  adjacent code. LuaDoc annotations use `chat_ui.*`, `acp.*`, `emeth.*` type families.
- Keep the generic/provider split: agent-specific knowledge belongs in the provider
  extension module, reached only through the optional hooks above. If a hook doesn't
  exist, add one to `acp.lua`'s hook surface rather than special-casing the provider
  name in the generic path (opencode subagents and kiro's `_kiro/*` namespace are
  existing examples of this boundary).
