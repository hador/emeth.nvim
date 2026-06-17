vim.api.nvim_create_user_command("Emeth", function(args)
  local provider = args.args ~= "" and args.args or nil
  require("emeth").open(provider)
end, { nargs = "?", desc = "Open Emeth chat (optionally specify provider)" })

vim.api.nvim_create_user_command("EmethNew", function(args)
  local provider = args.args ~= "" and args.args or nil
  require("emeth").open(provider, { fresh = true })
end, { nargs = "?", desc = "Open Emeth chat with a new session (skip resume)" })

vim.api.nvim_create_user_command("EmethClose", function()
  require("emeth").close()
end, { desc = "Close Emeth sidebar" })

vim.api.nvim_create_user_command("EmethToggle", function()
  require("emeth").toggle()
end, { desc = "Toggle Emeth sidebar" })

vim.api.nvim_create_user_command("EmethZoom", function()
  require("emeth").zoom()
end, { desc = "Toggle zoom (fill screen) for the Emeth sidebar" })

vim.api.nvim_create_user_command("EmethHistory", function()
  require("emeth").history()
end, { desc = "Pick a previous chat session to resume" })

vim.api.nvim_create_user_command("EmethCancel", function()
  require("emeth").cancel()
end, { desc = "Cancel current AI request" })
