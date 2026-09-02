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

-- ── incremental render bookkeeping ─────────────────────────────
-- _render no longer rebuilds the prefix each call; it counts prefix lines and
-- maintains _line_to_msg incrementally. These guard the row->msg mapping (which
-- backs the K/r/e keymaps) and the shrink case.
h.describe("ChatView incremental line->msg map", function()
  local Message = require("emeth.message")

  h.it("maps every buffer row to its message after streaming into the tail", function()
    local view = make_view()
    view:add_message(Message:new("user", "first\nsecond"))
    local live = Message:new("assistant", "")
    view:add_message(live)
    view:_render()
    -- Stream several chunks into the last message (each a re-render).
    for _ = 1, 5 do
      view:update_message(live.uuid, function(m)
        m:append_text("x\n")
      end)
      view:_render()
    end
    local n = vim.api.nvim_buf_line_count(view.result_buf)
    -- Every rendered row resolves to a message, and the last row is the live one.
    for row = 1, n do
      h.is_true(view._line_to_msg[row] ~= nil, "row " .. row .. " has no message")
    end
    h.eq(live.uuid, view._line_to_msg[n].uuid)
  end)

  h.it("leaves no stale row->msg entries when the transcript shrinks", function()
    local view = make_view()
    view:add_message(Message:new("assistant", "a\nb\nc\nd\ne"))
    view:_render()
    local before = vim.api.nvim_buf_line_count(view.result_buf)
    h.is_true(view._line_to_msg[before] ~= nil, "seed row should map")
    -- Clear collapses to an empty transcript; no rows should map afterward.
    view:clear()
    for row = 1, before do
      h.is_nil(view._line_to_msg[row])
    end
  end)
end)

-- ── deferred render (streaming throttle primitive) ─────────────
h.describe("ChatView:update_message defer_render + flush", function()
  local Message = require("emeth.message")

  h.it("applies the mutation synchronously but does not schedule a render", function()
    local view = make_view()
    local m = Message:new("assistant", "start")
    view:add_message(m)
    view:_render()
    view._render_pending = false -- clear the add's scheduled render

    view:update_message(m.uuid, function(msg)
      msg:append_text(" more")
    end, { defer_render = true })

    -- Model is current immediately...
    h.eq("start more", view:get_message(m.uuid):text())
    -- ...but no render was scheduled and the cache entry was dropped (dirty).
    h.is_true(not view._render_pending, "deferred update must not schedule a render")
    h.is_nil(view._line_cache[m.uuid], "deferred update should still mark the message dirty")
  end)

  h.it("flush schedules the pending render", function()
    local view = make_view()
    local m = Message:new("assistant", "x")
    view:add_message(m)
    view:_render()
    view._render_pending = false

    view:update_message(m.uuid, function(msg)
      msg:append_text("y")
    end, { defer_render = true })
    view:flush()
    h.is_true(view._render_pending, "flush should schedule a render when dirty")
  end)

  h.it("flush is a no-op when nothing is dirty", function()
    local view = make_view()
    view:add_message(Message:new("assistant", "x"))
    view:_render() -- clears _dirty_from
    view._render_pending = false
    view:flush()
    h.is_true(not view._render_pending, "flush with no dirty state must not render")
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

h.describe("ChatView:cursor_message_line", function()
  local Message = require("emeth.message")

  --- Render a multi-line system message and put the cursor on one of its rows.
  ---@param body string
  ---@param row_of string  substring identifying the row to move the cursor to
  local function place(body, row_of)
    local view = make_view()
    local msg = Message:new("system", body)
    view:add_message(msg)
    view:_render()
    vim.api.nvim_win_set_buf(0, view.result_buf)
    local lines = vim.api.nvim_buf_get_lines(view.result_buf, 0, -1, false)
    for i, l in ipairs(lines) do
      if l:find(row_of, 1, true) then
        vim.api.nvim_win_set_cursor(0, { i, 0 })
        return view, msg
      end
    end
    error("row not found: " .. row_of .. " in\n" .. table.concat(lines, "\n"))
  end

  -- The elicitation UI maps a row->action table keyed by this offset, so an
  -- off-by-N here would select the wrong option.
  h.it("reports the 1-based line offset within the message", function()
    local view, msg = place("first\nsecond\nthird", "second")
    local got, offset = view:cursor_message_line()
    h.eq(msg.uuid, got.uuid)
    h.eq(2, offset)
  end)

  h.it("offsets stay aligned for the last line of a long message", function()
    local body = {}
    for i = 1, 12 do
      body[#body + 1] = "line " .. i
    end
    local view = make_view()
    local msg = Message:new("system", table.concat(body, "\n"))
    view:add_message(msg)
    view:_render()
    vim.api.nvim_win_set_buf(0, view.result_buf)
    local total = vim.api.nvim_buf_line_count(view.result_buf)
    vim.api.nvim_win_set_cursor(0, { total, 0 })
    local got, offset = view:cursor_message_line()
    h.eq(msg.uuid, got.uuid)
    h.eq(12, offset, "last row of a 12-line message must be offset 12")
  end)

  h.it("offsets are relative to the message, not the buffer", function()
    -- A preceding message must not shift the second message's offsets.
    local view = make_view()
    view:add_message(Message:new("system", "earlier\nmessage"))
    local msg = Message:new("system", "alpha\nbeta")
    view:add_message(msg)
    view:_render()
    vim.api.nvim_win_set_buf(0, view.result_buf)
    local lines = vim.api.nvim_buf_get_lines(view.result_buf, 0, -1, false)
    for i, l in ipairs(lines) do
      if l:find("beta", 1, true) then
        vim.api.nvim_win_set_cursor(0, { i, 0 })
      end
    end
    local got, offset = view:cursor_message_line()
    h.eq(msg.uuid, got.uuid)
    h.eq(2, offset)
  end)

  h.it("returns nil when the result buffer is not current", function()
    local view = make_view()
    view:add_message(Message:new("system", "x"))
    view:_render()
    vim.api.nvim_win_set_buf(0, view.input_buf)
    h.is_nil((view:cursor_message_line()))
  end)
end)

h.describe("ChatView prompt key claims", function()
  local Message = require("emeth.message")

  --- Press a key in the result buffer the way a user would, so the real
  --- buffer-local dispatch (claims first, then the key's default) is exercised.
  local function press(view, key)
    vim.api.nvim_win_set_buf(0, view.result_buf)
    vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes(key, true, false, true), "x", false)
  end

  h.it("routes a claimed key to the claiming prompt", function()
    local view = make_view()
    view:add_message(Message:new("system", "prompt"))
    view:_render()
    local hits = 0
    view:set_prompt_keys("permission", {
      a = function()
        hits = hits + 1
      end,
    })
    press(view, "a")
    h.eq(1, hits)
  end)

  -- Regression: answering a permission request used to `del_keymap` its keys,
  -- which destroyed the permanent `r` retry binding for the rest of the session.
  h.it("restores r to retry after a prompt claims and releases it", function()
    local view = make_view()
    local submitted = {}
    view.on_submit = function(text)
      submitted[#submitted + 1] = text
    end
    view:add_message(Message:new("user", "resend me"))
    view:_render()

    -- A prompt claims `r` (as a reject_once option would) and then releases it.
    local rejected = 0
    view:set_prompt_keys("permission", {
      r = function()
        rejected = rejected + 1
      end,
    })
    vim.api.nvim_win_set_cursor(0, { 1, 0 })
    press(view, "r")
    h.eq(1, rejected)
    h.eq(0, #submitted, "the claim consumes r while the prompt is active")

    view:clear_prompt_keys("permission")
    -- Cursor on the user message: r must retry again.
    vim.api.nvim_win_set_buf(0, view.result_buf)
    for row = 1, vim.api.nvim_buf_line_count(view.result_buf) do
      if (vim.api.nvim_buf_get_lines(view.result_buf, row - 1, row, false)[1] or ""):find("resend me", 1, true) then
        vim.api.nvim_win_set_cursor(0, { row, 0 })
        break
      end
    end
    press(view, "r")
    h.eq({ "resend me" }, submitted, "retry must survive a prompt claiming r")
  end)

  h.it("lets two prompts hold disjoint keys at once", function()
    local view = make_view()
    view:add_message(Message:new("system", "prompt"))
    view:_render()
    local seen = {}
    view:set_prompt_keys("permission", {
      a = function()
        seen[#seen + 1] = "perm"
      end,
    })
    view:set_prompt_keys("elicitation", {
      ["<CR>"] = function()
        seen[#seen + 1] = "elicit"
      end,
    })
    press(view, "a")
    press(view, "<CR>")
    h.eq({ "perm", "elicit" }, seen)
  end)

  h.it("clearing one owner leaves the other's claim intact", function()
    local view = make_view()
    view:add_message(Message:new("system", "prompt"))
    view:_render()
    local hits = 0
    view:set_prompt_keys("permission", { a = function() end })
    view:set_prompt_keys("elicitation", {
      ["<CR>"] = function()
        hits = hits + 1
      end,
    })
    view:clear_prompt_keys("permission")
    press(view, "<CR>")
    h.eq(1, hits)
  end)

  h.it("re-claiming replaces that owner's previous keys rather than stacking", function()
    local view = make_view()
    view:add_message(Message:new("system", "prompt"))
    view:_render()
    local first, second = 0, 0
    view:set_prompt_keys("permission", {
      a = function()
        first = first + 1
      end,
    })
    view:set_prompt_keys("permission", {
      a = function()
        second = second + 1
      end,
    })
    press(view, "a")
    h.eq(0, first)
    h.eq(1, second)
  end)

  h.it("<CR> still moves down a line when no prompt claims it", function()
    local view = make_view()
    view:add_message(Message:new("system", "one\ntwo\nthree"))
    view:_render()
    vim.api.nvim_win_set_buf(0, view.result_buf)
    vim.api.nvim_win_set_cursor(0, { 1, 0 })
    press(view, "<CR>")
    h.eq(2, vim.api.nvim_win_get_cursor(0)[1], "builtin line-down motion must survive")
  end)
end)
