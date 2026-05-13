--- Tests for ChatView:prefill_command — the slash-command pre-fill flow.

local h = require("tests.helpers")

require("emeth").setup({})

local ChatView = require("emeth.ui.chat_view")

-- Build a real ChatView (it needs real buffers). The headless tests run with
-- `vim.opt.swapfile = false` so this is safe.
local function make_view()
  return ChatView:new({ config = require("emeth").config })
end

h.describe("ChatView:prefill_command", function()
  h.it("writes /<name> ' ' to the input buffer when no hint", function()
    local view = make_view()
    view:prefill_command("model")
    local lines = vim.api.nvim_buf_get_lines(view.input_buf, 0, -1, false)
    h.eq({ "/model " }, lines)
  end)

  h.it("appends hint as real text when present", function()
    local view = make_view()
    view:prefill_command("model", "<model_id>")
    local lines = vim.api.nvim_buf_get_lines(view.input_buf, 0, -1, false)
    h.eq({ "/model <model_id>" }, lines)
  end)

  h.it("treats empty-string hint as no hint", function()
    local view = make_view()
    view:prefill_command("clear", "")
    local lines = vim.api.nvim_buf_get_lines(view.input_buf, 0, -1, false)
    h.eq({ "/clear " }, lines)
  end)

  h.it("handles long command names", function()
    local view = make_view()
    view:prefill_command("mcp-flax-builder-mcp-internal-code-search")
    local lines = vim.api.nvim_buf_get_lines(view.input_buf, 0, -1, false)
    h.eq({ "/mcp-flax-builder-mcp-internal-code-search " }, lines)
  end)
end)
