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
      vim.health.warn(name .. ": `" .. provider.command .. "` not found on PATH")
    end
  end
  if not found_any then
    vim.health.error("No ACP provider commands found on PATH")
  end
end

return M
