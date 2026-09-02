local M = {}

function M.check()
  vim.health.start("emeth.nvim")
  vim.health.ok("emeth.nvim loaded")

  vim.health.start("emeth.nvim: ACP providers")
  local config = require("emeth.acp").config
  local found_any = false
  for name, provider in pairs(config.providers) do
    if vim.fn.executable(provider.command) == 1 then
      vim.health.ok(name .. ": `" .. provider.command .. "` found")
      found_any = true
    else
      -- Neovim inherits PATH from whatever launched it, and a version manager
      -- that resolves tools per directory can leave the command missing here
      -- even though it resolves in a shell — so say where to look.
      vim.health.warn(name .. ": `" .. provider.command .. "` not found on PATH", {
        "If it works in your shell, Neovim's PATH differs from your shell's.",
        "Using mise/asdf? Check the version this directory pins is installed (`mise install`)",
        "— an uninstalled pinned version drops the tool from PATH entirely.",
      })
    end
  end
  if not found_any then
    vim.health.error("No ACP provider commands found on PATH")
  end
end

return M
