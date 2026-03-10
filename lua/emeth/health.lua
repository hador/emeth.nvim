local M = {}

function M.check()
  vim.health.start("emeth.nvim")
  vim.health.ok("emeth.nvim loaded successfully")
end

return M
