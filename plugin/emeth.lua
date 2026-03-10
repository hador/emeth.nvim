vim.api.nvim_create_user_command("EmethOpen", function()
  require("emeth").open()
end, { desc = "Open Emeth sidebar" })

vim.api.nvim_create_user_command("EmethClose", function()
  require("emeth").close()
end, { desc = "Close Emeth sidebar" })

vim.api.nvim_create_user_command("EmethToggle", function()
  require("emeth").toggle()
end, { desc = "Toggle Emeth sidebar" })

vim.api.nvim_create_user_command("EmethHistory", function()
  local integration = require("emeth")._integration
  if integration and integration.pick_session then
    integration.pick_session()
  else
    vim.notify("[emeth] No active ACP integration. Open a chat first with :EmethOpen", vim.log.levels.WARN)
  end
end, { desc = "Pick a previous chat session to resume" })
