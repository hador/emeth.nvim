-- Minimal init for headless test runs.
-- Adds the plugin to runtimepath so require("emeth.*") works.
vim.opt.rtp:prepend(vim.fn.getcwd())
vim.opt.swapfile = false
