-- Minimal init for headless test runs.
-- Adds the plugin to runtimepath so require("emeth.*") works.
vim.opt.rtp:prepend(vim.fn.getcwd())
vim.opt.swapfile = false

-- Sandbox every XDG dir before anything resolves `stdpath`. Without this the
-- suite writes into the developer's own state: `Sessions.save` persists to
-- `stdpath("state")/emeth/sessions.json`, so a test that starts a session left
-- fake entries ("sess-1", "sess-new") in the real session list, and the debug
-- logger would append real log files too.
local sandbox = vim.fn.tempname()
vim.env.XDG_STATE_HOME = sandbox .. "/state"
vim.env.XDG_DATA_HOME = sandbox .. "/data"
vim.env.XDG_CACHE_HOME = sandbox .. "/cache"
