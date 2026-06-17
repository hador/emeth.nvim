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

-- ── Paste folding ──────────────────────────────────────────────
-- Drive the real `vim.paste` override (installed in :new) with the input
-- buffer focused, then assert on buffer contents, the off-buffer paste store,
-- and submit-time expansion.

--- Focus a view's input buffer in the current window and clear it.
local function focus_input(view)
  vim.api.nvim_set_current_win(0)
  vim.api.nvim_win_set_buf(0, view.input_buf)
  vim.api.nvim_buf_set_lines(view.input_buf, 0, -1, false, { "" })
  view:_clear_pastes()
  vim.api.nvim_win_set_cursor(0, { 1, 0 })
end

--- Count entries in the off-buffer paste store.
local function paste_count(view)
  local n = 0
  for _ in pairs(view._pastes) do
    n = n + 1
  end
  return n
end

h.describe("ChatView paste folding", function()
  h.it("leaves small pastes inline (below thresholds)", function()
    local view = make_view()
    focus_input(view)
    vim.paste({ "one", "two", "three" }, -1)
    local lines = vim.api.nvim_buf_get_lines(view.input_buf, 0, -1, false)
    h.eq({ "one", "two", "three" }, lines)
    h.eq(0, paste_count(view))
  end)

  h.it("folds a paste that exceeds the line threshold", function()
    local view = make_view()
    focus_input(view)
    local big = {}
    for i = 1, 30 do
      big[i] = "line " .. i
    end
    vim.paste(big, -1)
    local lines = vim.api.nvim_buf_get_lines(view.input_buf, 0, -1, false)
    -- A single placeholder line replaced the 30-line block.
    h.eq(1, #lines)
    h.is_true(lines[1]:match("^▌ pasted 30 lines") ~= nil, "placeholder text: " .. lines[1])
    h.eq(1, paste_count(view))
  end)

  h.it("folds a huge single-line paste (char threshold)", function()
    local view = make_view()
    focus_input(view)
    local blob = string.rep("x", 2000)
    vim.paste({ blob }, -1)
    local lines = vim.api.nvim_buf_get_lines(view.input_buf, 0, -1, false)
    h.eq(1, #lines)
    h.is_true(lines[1]:match("^▌ pasted 1 line ") ~= nil, "placeholder text: " .. lines[1])
    h.eq(1, paste_count(view))
  end)

  h.it("expands a folded paste back to original content at submit", function()
    local view = make_view()
    focus_input(view)
    local big = {}
    for i = 1, 30 do
      big[i] = "row" .. i
    end
    vim.paste(big, -1)
    local buf_lines = vim.api.nvim_buf_get_lines(view.input_buf, 0, -1, false)
    local expanded = view:_expand_pastes(buf_lines)
    h.eq(big, expanded)
  end)

  h.it("expands a fold surrounded by typed text", function()
    local view = make_view()
    focus_input(view)
    -- Type a line, then paste a big block after it.
    vim.api.nvim_buf_set_lines(view.input_buf, 0, -1, false, { "before" })
    vim.api.nvim_win_set_cursor(0, { 1, #"before" })
    local big = {}
    for i = 1, 20 do
      big[i] = "B" .. i
    end
    vim.paste(big, -1)
    -- Append a trailing typed line.
    vim.api.nvim_buf_set_lines(view.input_buf, -1, -1, false, { "after" })
    local expanded = view:_expand_pastes(vim.api.nvim_buf_get_lines(view.input_buf, 0, -1, false))
    local want = { "before" }
    for _, l in ipairs(big) do
      want[#want + 1] = l
    end
    want[#want + 1] = "after"
    h.eq(want, expanded)
  end)

  h.it("accumulates streamed chunks readfile-style across phases", function()
    local view = make_view()
    focus_input(view)
    -- Simulate a streamed paste: "AAA\nBB" then "B\nCCC" then end.
    -- Across chunks the boundary is mid-line, so phase-2's first element
    -- concatenates with the previous chunk's last element → "BBB".
    vim.paste({ "AAA", "BB" }, 1)
    vim.paste({ "B", "CCC" }, 2)
    -- pad to clear the line threshold so it folds and we can inspect content
    local pad = {}
    for i = 1, 30 do
      pad[i] = "P" .. i
    end
    pad[1] = "CCC" .. pad[1]
    vim.paste(pad, 3)
    local expanded = view:_expand_pastes(vim.api.nvim_buf_get_lines(view.input_buf, 0, -1, false))
    h.eq("AAA", expanded[1])
    h.eq("BBB", expanded[2])
    h.eq("CCCCCCP1", expanded[3])
    h.eq("P30", expanded[#expanded])
  end)

  h.it("survives empty streamed chunks without losing the paste", function()
    local view = make_view()
    focus_input(view)
    -- Regression: an empty continuation chunk used to crash the concat join.
    h.eq(true, vim.paste({ "AAA", "BBB" }, 1))
    h.eq(true, vim.paste({}, 2)) -- empty chunk
    h.eq(true, vim.paste({ "" }, 2)) -- empty non-final chunk
    local big = {}
    for i = 1, 30 do
      big[i] = "c" .. i
    end
    h.eq(true, vim.paste(big, 3))
    local expanded = view:_expand_pastes(vim.api.nvim_buf_get_lines(view.input_buf, 0, -1, false))
    h.eq("AAA", expanded[1])
    h.eq("BBBc1", expanded[2])
    h.eq("c30", expanded[#expanded])
  end)

  h.it("treats an edited placeholder line as literal (no expansion)", function()
    local view = make_view()
    focus_input(view)
    local big = {}
    for i = 1, 30 do
      big[i] = "z" .. i
    end
    vim.paste(big, -1)
    -- User edits the placeholder line — it no longer matches the stored text.
    vim.api.nvim_buf_set_lines(view.input_buf, 0, 1, false, { "i changed my mind" })
    local expanded = view:_expand_pastes(vim.api.nvim_buf_get_lines(view.input_buf, 0, -1, false))
    h.eq({ "i changed my mind" }, expanded)
  end)

  h.it("expand_paste_at_cursor replaces the placeholder line in place", function()
    local view = make_view()
    focus_input(view)
    vim.api.nvim_buf_set_lines(view.input_buf, 0, -1, false, { "before" })
    vim.api.nvim_win_set_cursor(0, { 1, #"before" })
    local big = {}
    for i = 1, 30 do
      big[i] = "X" .. i
    end
    vim.paste(big, -1)
    -- Move the cursor onto the placeholder line via its extmark.
    local pl_row
    for _, e in pairs(view._pastes) do
      pl_row = vim.api.nvim_buf_get_extmark_by_id(view.input_buf, view._paste_ns, e.mark, {})[1]
    end
    vim.api.nvim_win_set_cursor(0, { pl_row + 1, 0 })
    h.is_true(view:expand_paste_at_cursor(), "expand should succeed on a placeholder line")
    local lines = vim.api.nvim_buf_get_lines(view.input_buf, 0, -1, false)
    h.eq(31, #lines) -- "before" + 30
    h.eq("before", lines[1])
    h.eq("X1", lines[2])
    h.eq("X30", lines[#lines])
    h.eq(0, paste_count(view)) -- entry consumed
  end)

  h.it("expand_paste_at_cursor is a no-op off a placeholder line", function()
    local view = make_view()
    focus_input(view)
    vim.api.nvim_buf_set_lines(view.input_buf, 0, -1, false, { "just text" })
    vim.api.nvim_win_set_cursor(0, { 1, 0 })
    h.eq(false, view:expand_paste_at_cursor())
  end)

  h.it("_clear_pastes drops state and placeholder extmarks", function()
    local view = make_view()
    focus_input(view)
    local big = {}
    for i = 1, 30 do
      big[i] = "q" .. i
    end
    vim.paste(big, -1)
    h.eq(1, paste_count(view))
    view:_clear_pastes()
    h.eq(0, paste_count(view))
    local marks = vim.api.nvim_buf_get_extmarks(view.input_buf, view._paste_ns, 0, -1, {})
    h.eq({}, marks)
  end)

  h.it("does not fold when fold_pasted_text is disabled", function()
    local view = make_view()
    view._config = vim.tbl_deep_extend("force", vim.deepcopy(view._config), { fold_pasted_text = false })
    focus_input(view)
    local big = {}
    for i = 1, 30 do
      big[i] = "u" .. i
    end
    vim.paste(big, -1)
    local lines = vim.api.nvim_buf_get_lines(view.input_buf, 0, -1, false)
    h.eq(30, #lines)
    h.eq(0, paste_count(view))
  end)
end)

-- ── vim.paste lifecycle (global hygiene) ───────────────────────
h.describe("ChatView paste lifecycle", function()
  h.it("install wraps the global, detach restores the original", function()
    local sentinel = function()
      return true
    end
    vim.paste = sentinel
    local view = make_view() -- _setup_input installs the wrapper
    h.is_true(vim.paste ~= sentinel, "wrapper should be installed")
    view:detach()
    h.eq(sentinel, vim.paste)
  end)

  h.it("detach is idempotent", function()
    local sentinel = function()
      return true
    end
    vim.paste = sentinel
    local view = make_view()
    view:detach()
    view:detach() -- second call must not stomp anything
    h.eq(sentinel, vim.paste)
  end)

  h.it("detach does not stomp another plugin that wrapped over us", function()
    local sentinel = function()
      return true
    end
    vim.paste = sentinel
    local view = make_view()
    -- Another plugin wraps after us.
    local other = function()
      return true
    end
    vim.paste = other
    view:detach() -- we are no longer the top of the chain → leave it be
    h.eq(other, vim.paste)
  end)

  h.it("self-heals when its target buffer is wiped", function()
    local sentinel = function()
      return true
    end
    vim.paste = sentinel
    local view = make_view()
    h.is_true(vim.paste ~= sentinel, "wrapper installed")
    vim.api.nvim_buf_delete(view.input_buf, { force = true })
    -- Paste from a scratch buffer; the stale wrapper should restore the global.
    local scratch = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_set_current_buf(scratch)
    h.eq(true, vim.paste({ "x" }, -1))
    h.eq(sentinel, vim.paste)
  end)
end)
