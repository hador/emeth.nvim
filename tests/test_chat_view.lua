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
    view:prefill_command("new", "")
    local lines = vim.api.nvim_buf_get_lines(view.input_buf, 0, -1, false)
    h.eq({ "/new " }, lines)
  end)

  h.it("handles long command names", function()
    local view = make_view()
    view:prefill_command("mcp-example-server-mcp-internal-code-search")
    local lines = vim.api.nvim_buf_get_lines(view.input_buf, 0, -1, false)
    h.eq({ "/mcp-example-server-mcp-internal-code-search " }, lines)
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

  h.it("renders a message inserted mid-transcript in place, after a prior render", function()
    local view = make_view()
    local first = Message:new("assistant", "first")
    view:add_message(first)
    local last = Message:new("assistant", "last")
    view:add_message(last)
    view:_render()
    view:insert_message_after(first.uuid, Message:new("assistant", "middle"))
    view:_render()
    local text = table.concat(vim.api.nvim_buf_get_lines(view.result_buf, 0, -1, false), "\n")
    local a, b, c = text:find("first", 1, true), text:find("middle", 1, true), text:find("last", 1, true)
    h.is_true(a and b and c and a < b and b < c, "expected first < middle < last in:\n" .. text)
    h.eq(last.uuid, view._line_to_msg[vim.api.nvim_buf_line_count(view.result_buf)].uuid)
  end)

  h.it("appends when the anchor message is gone", function()
    local view = make_view()
    view:add_message(Message:new("assistant", "only"))
    local orphan = Message:new("assistant", "orphan")
    view:insert_message_after("no-such-uuid", orphan)
    h.eq(orphan.uuid, view.messages[#view.messages].uuid)
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
    -- ...but no render was scheduled, and the message is marked dirty.
    h.is_true(not view._render_pending, "deferred update must not schedule a render")
    h.is_true(view._dirty[m.uuid], "deferred update should still mark the message dirty")
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

h.describe("ChatView prompt key contract", function()
  local Message = require("emeth.message")

  -- prompt_keys() tells callers which slots they may claim. Every one of them
  -- must actually be bound, or a prompt would offer an option that no keypress
  -- can ever reach — the failure mode this indirection exists to prevent.
  h.it("every advertised key is dispatched", function()
    local view = make_view()
    view:add_message(Message:new("system", "prompt"))
    view:_render()
    local keys = view:prompt_keys()
    h.is_true(#keys > 0)

    local seen = {}
    local claims = {}
    for _, key in ipairs(keys) do
      claims[key] = function()
        seen[key] = true
      end
    end
    view:set_prompt_keys("test", claims)

    vim.api.nvim_win_set_buf(0, view.result_buf)
    for _, key in ipairs(keys) do
      vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes(key, true, false, true), "x", false)
      h.is_true(seen[key], "advertised key never dispatched: " .. key)
    end
  end)

  h.it("does not hand out the confirm key as an option slot", function()
    local view = make_view()
    for _, key in ipairs(view:prompt_keys()) do
      h.is_true(key ~= "<CR>", "<CR> means 'act on the row under the cursor', not an option")
    end
  end)

  h.it("returns a copy so a caller cannot mutate the shared list", function()
    local view = make_view()
    local first = view:prompt_keys()
    table.remove(first)
    h.is_true(#view:prompt_keys() > #first, "the module list must be unaffected")
  end)
end)

h.describe("ChatView:is_visible", function()
  h.it("is true when the transcript is on screen", function()
    local view = make_view()
    vim.api.nvim_win_set_buf(0, view.result_buf)
    h.is_true(view:is_visible())
  end)

  h.it("is false when no window shows it", function()
    local view = make_view()
    local scratch = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_win_set_buf(0, scratch)
    h.eq(false, view:is_visible())
  end)
end)

-- `K` flips `metadata._expanded`, which starts nil. A small diff renders
-- expanded while still nil, so flipping the raw field would leave it expanded
-- and make the key look broken -- it has to toggle away from what's on screen.
h.describe("ChatView K on a diff tool call", function()
  local Message = require("emeth.message")
  local Render = require("emeth.ui.render")

  ---@param old string
  ---@param new string
  local function diff_msg(old, new)
    return Message:new("assistant", {
      type = "tool_use",
      name = "Write",
      id = "k1",
      input = { path = "/tmp/x.lua", old_str = old, new_str = new },
      status = "completed",
    }, { tool_call = { toolCallId = "k1", status = "completed", title = "/tmp/x.lua" } })
  end

  ---Render, park the cursor on the tool row, and press K as a user would so the
  ---real buffer-local mapping runs.
  ---@param msg chat_ui.Message
  local function press_k_on(msg)
    local view = make_view()
    view:add_message(msg)
    view:_render()
    vim.api.nvim_win_set_buf(0, view.result_buf)
    for row, m in pairs(view._line_to_msg) do
      if m.uuid == msg.uuid then
        vim.api.nvim_win_set_cursor(0, { row, 0 })
        break
      end
    end
    vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("K", true, false, true), "x", false)
    return view
  end

  local function big()
    local body = {}
    for i = 1, 200 do
      body[i] = "line " .. i
    end
    return diff_msg("", table.concat(body, "\n"))
  end

  h.it("collapses a small diff that was expanded by default", function()
    local msg = diff_msg("a\nb\nc", "a\nX\nc")
    h.eq(true, Render.is_expanded(msg), "precondition: starts expanded")
    press_k_on(msg)
    h.eq(false, Render.is_expanded(msg), "K did not collapse it")
  end)

  h.it("expands a big diff that was folded by default", function()
    local msg = big()
    h.eq(false, Render.is_expanded(msg), "precondition: starts folded")
    press_k_on(msg)
    h.eq(true, Render.is_expanded(msg), "K did not expand it")
  end)

  ---The contextual-help text currently painted in the result buffer.
  ---@param view chat_ui.ChatView
  local function hint_text(view)
    local ns = vim.api.nvim_create_namespace("emeth_help_hints")
    local out = {}
    for _, m in ipairs(vim.api.nvim_buf_get_extmarks(view.result_buf, ns, 0, -1, { details = true })) do
      for _, chunk in ipairs(m[4].virt_text or {}) do
        out[#out + 1] = chunk[1]
      end
    end
    return table.concat(out)
  end

  h.it("hints what K will do to what's on screen, and repaints after K", function()
    local msg = diff_msg("a\nb\nc", "a\nX\nc") -- small: expanded while _expanded is nil
    local view = make_view()
    view:add_message(msg)
    view:_render()
    vim.api.nvim_win_set_buf(0, view.result_buf)
    for row, m in pairs(view._line_to_msg) do
      if m.uuid == msg.uuid then
        vim.api.nvim_win_set_cursor(0, { row, 0 })
        break
      end
    end
    vim.api.nvim_exec_autocmds("CursorMoved", { buffer = view.result_buf })
    h.is_true(hint_text(view):find("K: collapse", 1, true) ~= nil, "got: " .. hint_text(view))
    -- K without moving the cursor: the hint must follow the new state.
    vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("K", true, false, true), "x", false)
    h.is_true(hint_text(view):find("K: expand", 1, true) ~= nil, "got: " .. hint_text(view))
  end)

  h.it("hints K on a prompt that has more to show", function()
    local view = make_view()
    local prompt = Message:new("system", "Pick one", { on_expand = function() end })
    view:add_message(prompt)
    view:_render()
    vim.api.nvim_win_set_buf(0, view.result_buf)
    vim.api.nvim_win_set_cursor(0, { 1, 0 })
    vim.api.nvim_exec_autocmds("CursorMoved", { buffer = view.result_buf })
    h.is_true(hint_text(view):find("K: details", 1, true) ~= nil, "got: " .. hint_text(view))
  end)

  h.it("takes the diff body out of the buffer when it collapses", function()
    local msg = big()
    msg.metadata._expanded = true
    local view = press_k_on(msg)
    view:_render()
    local text = table.concat(vim.api.nvim_buf_get_lines(view.result_buf, 0, -1, false), "\n")
    h.is_true(text:find("line 150", 1, true) == nil, "diff body survived the collapse")
  end)
end)

h.describe("ChatView:add_action", function()
  h.it("runs on the message under the cursor and defers to an active prompt", function()
    local view = make_view()
    local Message = require("emeth.message")
    local msg = Message:new("user", "hello")
    view._line_to_msg = { [1] = msg }
    vim.api.nvim_win_set_buf(0, view.result_buf)
    vim.api.nvim_win_set_cursor(0, { 1, 0 })

    local ran = {}
    view:add_action({
      key = "R",
      hint = "R: rewind",
      run = function(m)
        ran[#ran + 1] = m
      end,
    })

    local cb
    for _, km in ipairs(vim.api.nvim_buf_get_keymap(view.result_buf, "n")) do
      if km.lhs == "R" and km.callback then
        cb = km.callback
      end
    end
    h.is_true(cb ~= nil, "R keymap was bound")

    -- An active prompt claiming R answers it; the action must not fire.
    local claimed = false
    view._prompt_key_owners = {
      {
        owner = "p",
        keys = {
          R = function()
            claimed = true
            return true
          end,
        },
      },
    }
    cb()
    h.is_true(claimed)
    h.eq(0, #ran, "deferred to the active prompt")

    -- No prompt: the action runs on the message under the cursor.
    view._prompt_key_owners = {}
    cb()
    h.eq(1, #ran)
    h.eq(msg, ran[1])

    -- Removing the action (kiro disconnect) must leave R working as a prompt
    -- key: the view outlives a provider switch, so deleting the keymap would
    -- strand reject_always for the rest of the session.
    view:remove_action("R")
    local after
    for _, km in ipairs(vim.api.nvim_buf_get_keymap(view.result_buf, "n")) do
      if km.lhs == "R" and km.callback then
        after = km.callback
      end
    end
    h.is_true(after ~= nil, "R stays bound after remove_action")
    claimed = false
    view._prompt_key_owners = {
      {
        owner = "p",
        keys = {
          R = function()
            claimed = true
            return true
          end,
        },
      },
    }
    after()
    h.is_true(claimed, "a prompt still receives R")
    view._prompt_key_owners = {}
    after()
    h.eq(1, #ran, "the removed action no longer runs")
  end)

  h.it("binds and unbinds a key that is not a prompt key", function()
    local view = make_view()
    local function bound()
      for _, km in ipairs(vim.api.nvim_buf_get_keymap(view.result_buf, "n")) do
        if km.lhs == "X" then
          return true
        end
      end
      return false
    end
    view:add_action({ key = "X", run = function() end })
    h.is_true(bound(), "a custom action key gets its own keymap")
    view:remove_action("X")
    h.is_true(not bound(), "and loses it on remove")
  end)
end)

-- ── incremental render == full render ──────────────────────────
-- `_render` only redoes what changed; after every step of a seeded random walk
-- over the integration's operations, text, row owners and highlights must match
-- a from-scratch render.
h.describe("ChatView incremental render", function()
  local Message = require("emeth.message")
  local Render = require("emeth.ui.render")
  local api = vim.api

  local function expected(view)
    local text, owners, marks = {}, {}, {}
    for _, msg in ipairs(view.messages) do
      if msg.visible ~= false then
        for _, line in ipairs(ChatView._expand(Render.render_message(msg, view.messages))) do
          local row = #text
          text[row + 1] = tostring(line)
          owners[row + 1] = msg
          if line.line_hl then
            marks[#marks + 1] = ("%d:line:%s"):format(row, line.line_hl)
          end
          local col = 0
          for _, s in ipairs(line.sections) do
            local hl = type(s[2]) == "function" and s[2]() or s[2]
            if hl and #s[1] > 0 then
              marks[#marks + 1] = ("%d:%d-%d:%s"):format(row, col, col + #s[1], hl)
            end
            col = col + #s[1]
          end
        end
      end
    end
    if #text == 0 then
      text = { "" }
    end
    table.sort(marks)
    return text, owners, marks
  end

  local function actual_marks(view)
    local out = {}
    for _, m in ipairs(api.nvim_buf_get_extmarks(view.result_buf, view._ns_id, 0, -1, { details = true })) do
      local row, col, d = m[2], m[3], m[4]
      if d.line_hl_group then
        out[#out + 1] = ("%d:line:%s"):format(row, d.line_hl_group)
      end
      -- A zero-width highlight paints nothing, wherever it ends up.
      if d.hl_group and not (d.end_row == row and d.end_col == col) then
        out[#out + 1] = ("%d:%d-%d:%s"):format(row, col, d.end_col, d.hl_group)
      end
    end
    table.sort(out)
    return out
  end

  local function check(view, step)
    -- The integration's throttle timer flushes deferred updates.
    view:flush()
    vim.wait(0)
    local text, owners, marks = expected(view)
    h.eq(text, api.nvim_buf_get_lines(view.result_buf, 0, -1, false), "buffer text diverged at step " .. step)
    for row = 1, #owners do
      if view._line_to_msg[row] ~= owners[row] then
        error(("row %d owned by the wrong message at step %d"):format(row, step))
      end
    end
    h.is_nil(view._line_to_msg[#owners + 1], "stale row owner past the end at step " .. step)
    h.eq(marks, actual_marks(view), "highlights diverged at step " .. step)
  end

  local function body(rng)
    local lines = {}
    for i = 1, rng(1, 5) do
      lines[i] = ("line %d %s"):format(i, string.rep("w", rng(0, 12)))
    end
    return table.concat(lines, "\n")
  end

  local STATUSES = { "pending", "in_progress", "completed", "failed" }

  local function new_message(rng, id)
    local kind = rng(1, 3)
    if kind == 1 then
      return Message:new("assistant", body(rng))
    elseif kind == 2 then
      return Message:new("user", body(rng))
    end
    local msg = Message:new("assistant", {
      type = "tool_use",
      id = "t" .. id,
      name = "Bash",
      input = { command = "ls " .. id },
      status = STATUSES[rng(1, #STATUSES)],
    }, { tool_call = { title = "ls " .. id, status = "pending", content = {} } })
    msg.metadata._expanded = rng(0, 1) == 1
    return msg
  end

  local function mutate(rng, m)
    if Render.tool_use(m) then
      m.content[1].status = STATUSES[rng(1, #STATUSES)]
      m.metadata.tool_call.content = { { type = "content", content = { text = body(rng) } } }
      m.metadata._expanded = rng(0, 1) == 1
    else
      m.content = { { type = "text", text = body(rng) } }
    end
  end

  h.it("matches a full render after every step of a random walk", function()
    local view = make_view()
    view:clear()
    math.randomseed(20261028)
    local rng = math.random
    local id = 0
    for step = 1, 400 do
      local n = #view.messages
      local op = n < 3 and 1 or rng(1, 9)
      if op == 1 then
        id = id + 1
        view:add_message(new_message(rng, id))
      elseif op == 2 or op == 3 then
        view:update_message(view.messages[rng(1, n)].uuid, function(m)
          mutate(rng, m)
        end)
      elseif op == 4 then
        id = id + 1
        local child = new_message(rng, id)
        child.visible = rng(0, 2) > 0 -- mostly hidden, like a collapsed card's
        view:insert_message_after(view.messages[rng(1, n)].uuid, child)
      elseif op == 5 then
        view:update_message(view.messages[rng(1, n)].uuid, function(m)
          m.visible = m.visible == false
        end)
      elseif op == 6 then
        -- Flip later messages from an earlier one's update, as a card expanding.
        local i = rng(1, n)
        view:update_message(view.messages[i].uuid, function()
          for j = i + 1, math.min(n, i + 3) do
            view.messages[j].visible = view.messages[j].visible == false
          end
        end)
      elseif op == 7 then
        local m = view.messages[rng(1, n)]
        view:update_message(m.uuid, function(x)
          mutate(rng, x)
        end)
      elseif op == 8 then
        view:update_message(view.messages[rng(1, n)].uuid, function(m)
          mutate(rng, m)
        end, { defer_render = true })
        if rng(0, 1) == 1 then
          view:flush()
        end
      else
        view:invalidate()
      end
      check(view, step)
    end
  end)
end)
