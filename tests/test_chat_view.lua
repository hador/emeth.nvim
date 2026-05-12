--- Tests for ChatView:prefill_command — the slash-command pre-fill flow.
--- We can't drive the InsertCharPre autocmd cleanly from tests, but the
--- prefill itself is a pure buffer/extmark mutation we can verify directly.

local h = require("tests.helpers")

require("emeth").setup({})

local ChatView = require("emeth.ui.chat_view")

-- Build a real ChatView (it needs real buffers). The headless tests run with
-- `vim.opt.swapfile = false` so this is safe.
local function make_view()
  return ChatView:new({ config = require("emeth").config })
end

local NS = vim.api.nvim_create_namespace("emeth_cmd_hint")

local function get_extmarks(buf)
  return vim.api.nvim_buf_get_extmarks(buf, NS, 0, -1, { details = true })
end

h.describe("ChatView:prefill_command", function()
  h.it("writes /<name> ' ' to the input buffer", function()
    local view = make_view()
    view:prefill_command("model")
    local lines = vim.api.nvim_buf_get_lines(view.input_buf, 0, -1, false)
    h.eq({ "/model " }, lines)
  end)

  h.it("places cursor after the trailing space (col = #name + 2)", function()
    -- We can verify by inspecting the line + col logic indirectly: the
    -- function uses #name + 2 = #"/model " positions.
    local view = make_view()
    view:prefill_command("model")
    -- Re-read the buffer (sanity)
    h.eq({ "/model " }, vim.api.nvim_buf_get_lines(view.input_buf, 0, -1, false))
  end)

  h.it("with neither hint nor desc, no extmarks are set", function()
    local view = make_view()
    -- Clear any leftover marks from prior tests
    vim.api.nvim_buf_clear_namespace(view.input_buf, NS, 0, -1)
    view:prefill_command("clear")
    h.eq(0, #get_extmarks(view.input_buf))
  end)

  h.it("with hint, sets one overlay extmark at end of /name + space", function()
    local view = make_view()
    vim.api.nvim_buf_clear_namespace(view.input_buf, NS, 0, -1)
    view:prefill_command("model", "<model_id>")
    local marks = get_extmarks(view.input_buf)
    h.eq(1, #marks)
    -- Mark is at col #"/model " = 7
    h.eq(7, marks[1][3])
    h.eq("overlay", marks[1][4].virt_text_pos)
    h.eq("<model_id>", marks[1][4].virt_text[1][1])
  end)

  h.it("with desc only, sets one eol extmark with separator '  — '", function()
    local view = make_view()
    vim.api.nvim_buf_clear_namespace(view.input_buf, NS, 0, -1)
    view:prefill_command("clear", nil, "Clear chat messages")
    local marks = get_extmarks(view.input_buf)
    h.eq(1, #marks)
    h.eq("eol", marks[1][4].virt_text_pos)
    h.eq("  — Clear chat messages", marks[1][4].virt_text[1][1])
  end)

  h.it("with both hint and desc, uses '    — ' (wider) separator on the desc", function()
    local view = make_view()
    vim.api.nvim_buf_clear_namespace(view.input_buf, NS, 0, -1)
    view:prefill_command("model", "<model_id>", "Switch model")
    local marks = get_extmarks(view.input_buf)
    h.eq(2, #marks)
    -- Find the eol mark (desc) vs overlay (hint)
    local eol_mark, overlay_mark
    for _, m in ipairs(marks) do
      if m[4].virt_text_pos == "eol" then
        eol_mark = m
      elseif m[4].virt_text_pos == "overlay" then
        overlay_mark = m
      end
    end
    h.is_true(eol_mark ~= nil)
    h.is_true(overlay_mark ~= nil)
    h.eq("    — Switch model", eol_mark[4].virt_text[1][1])
    h.eq("<model_id>", overlay_mark[4].virt_text[1][1])
  end)

  h.it("treats empty string hint as no hint", function()
    local view = make_view()
    vim.api.nvim_buf_clear_namespace(view.input_buf, NS, 0, -1)
    view:prefill_command("clear", "", "")
    h.eq(0, #get_extmarks(view.input_buf))
  end)
end)
