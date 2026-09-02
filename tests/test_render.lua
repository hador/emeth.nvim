local h = require("tests.helpers")

-- Stub emeth config so render can access icons
package.loaded["emeth"] = {
  config = {
    icons = {
      user = "> ",
      assistant = "",
      thinking = "🤔 ",
      tool_generating = "⏳",
      tool_succeeded = "✓",
      tool_failed = "✗",
    },
  },
}

-- Stub highlights to return plain strings
package.loaded["emeth.highlights"] = setmetatable({}, {
  __index = function(_, k)
    return k
  end,
})

local Message = require("emeth.message")
local Render = require("emeth.ui.render")

h.describe("Render", function()
  h.it("renders user message", function()
    local msg = Message:new("user", "hello world")
    local lines = Render.render_message(msg, {})
    h.is_true(#lines >= 1)
    local all = ""
    for _, l in ipairs(lines) do
      all = all .. tostring(l) .. "\n"
    end
    h.is_true(all:find("hello world") ~= nil, "expected 'hello world' in output")
  end)

  h.it("renders assistant text message", function()
    local msg = Message:new("assistant", "response text")
    local lines = Render.render_message(msg, {})
    h.is_true(#lines >= 1)
    local all = ""
    for _, l in ipairs(lines) do
      all = all .. tostring(l) .. "\n"
    end
    h.is_true(all:find("response text") ~= nil, "expected 'response text' in output")
  end)

  h.it("renders system message", function()
    local msg = Message:new("system", "system info")
    local lines = Render.render_message(msg, {})
    h.is_true(#lines >= 1)
    local text = tostring(lines[1])
    h.is_true(text:find("system info") ~= nil)
  end)

  h.it("renders thinking block", function()
    local msg = Message:new("assistant", { type = "thinking", thinking = "let me think" })
    local lines = Render.render_message(msg, {})
    h.is_true(#lines >= 1)
    local all = ""
    for _, l in ipairs(lines) do
      all = all .. tostring(l) .. "\n"
    end
    h.is_true(all:find("let me think") ~= nil, "expected thinking text in output")
  end)

  h.it("renders tool_use with pending status", function()
    local msg = Message:new(
      "assistant",
      { type = "tool_use", name = "read", id = "t1", input = {}, status = "pending" },
      { tool_call = { toolCallId = "t1", status = "pending" } }
    )
    local lines = Render.render_message(msg, {})
    h.is_true(#lines >= 1)
  end)

  h.it("renders tool_use with completed status", function()
    local msg = Message:new(
      "assistant",
      { type = "tool_use", name = "write", id = "t2", input = {}, status = "completed" },
      { tool_call = { toolCallId = "t2", status = "completed" } }
    )
    local lines = Render.render_message(msg, {})
    h.is_true(#lines >= 1)
    local all = ""
    for _, l in ipairs(lines) do
      all = all .. tostring(l)
    end
    h.is_true(all:find("✓") ~= nil, "expected success icon")
  end)

  h.it("renders tool_use with failed status", function()
    local msg = Message:new(
      "assistant",
      { type = "tool_use", name = "write", id = "t3", input = {}, status = "failed" },
      { tool_call = { toolCallId = "t3", status = "failed" } }
    )
    local lines = Render.render_message(msg, {})
    local all = ""
    for _, l in ipairs(lines) do
      all = all .. tostring(l)
    end
    h.is_true(all:find("✗") ~= nil, "expected failure icon")
  end)

  h.it("renders diff tool_use with heavy box", function()
    local msg = Message:new("assistant", {
      type = "tool_use",
      name = "strReplace",
      id = "t4",
      input = { old_str = "foo", new_str = "bar" },
      status = "completed",
    }, { tool_call = { toolCallId = "t4", status = "completed" } })
    local lines = Render.render_message(msg, {})
    local all = ""
    for _, l in ipairs(lines) do
      all = all .. tostring(l) .. "\n"
    end
    h.is_true(all:find("┏━") ~= nil, "expected heavy box top")
    h.is_true(all:find("┗━") ~= nil, "expected heavy box bottom")
    h.is_true(all:find("```diff") ~= nil, "expected diff fence")
  end)

  h.it("non-diff tool_use uses light box when expanded", function()
    local msg = Message:new(
      "assistant",
      { type = "tool_use", name = "read", id = "t5", input = { path = "/a" }, status = "completed" },
      {
        tool_call = {
          toolCallId = "t5",
          status = "completed",
          content = { { type = "content", content = { type = "text", text = "hello" } } },
        },
      }
    )
    msg.metadata._expanded = true
    local lines = Render.render_message(msg, {})
    local all = ""
    for _, l in ipairs(lines) do
      all = all .. tostring(l) .. "\n"
    end
    h.is_true(all:find("╭─") ~= nil, "expected light box top")
    h.is_true(all:find("╰─") ~= nil, "expected light box bottom")
  end)

  h.it("diff context lines use double space prefix", function()
    local msg = Message:new("assistant", {
      type = "tool_use",
      name = "strReplace",
      id = "t6",
      input = { old_str = "a\nb\nc", new_str = "a\nX\nc" },
      status = "completed",
    }, { tool_call = { toolCallId = "t6", status = "completed" } })
    local lines = Render.render_message(msg, {})
    local found_context = false
    for _, l in ipairs(lines) do
      if tostring(l):match("^  a$") then
        found_context = true
        h.is_true(l.line_hl ~= nil, "expected line_hl on context line")
      end
    end
    h.is_true(found_context, "expected context line with double space prefix")
  end)

  h.it("render_message handles multiple messages in context", function()
    local msgs = {
      Message:new("user", "question"),
      Message:new("assistant", "answer"),
    }
    local lines = {}
    for _, msg in ipairs(msgs) do
      vim.list_extend(lines, Render.render_message(msg, msgs))
    end
    h.is_true(#lines >= 2)
  end)

  h.it("diff fence escalates when content contains backticks", function()
    local old = "before\n```lua\ncode()\n```\nafter"
    local new = "before\n```lua\ncode(changed)\n```\nafter"
    local msg = Message:new("assistant", {
      type = "tool_use",
      name = "strReplace",
      id = "t7",
      input = { old_str = old, new_str = new },
      status = "completed",
    }, { tool_call = { toolCallId = "t7", status = "completed" } })
    local lines = Render.render_message(msg, {})
    local all = ""
    for _, l in ipairs(lines) do
      all = all .. tostring(l) .. "\n"
    end
    h.is_true(all:find("````diff") ~= nil, "expected 4-tick fence, got:\n" .. all)
    h.is_true(all:find("\n````\n") ~= nil, "expected 4-tick closing fence")
  end)

  h.it("render_message returns empty for invisible messages", function()
    local msg = Message:new("user", "hidden")
    msg.visible = false
    -- Caller is responsible for skipping invisible messages;
    -- render_message itself always renders.
    local lines = Render.render_message(msg, { msg })
    h.is_true(#lines >= 1)
  end)

  h.it("strips ANSI escape codes from text", function()
    local msg = Message:new("assistant", "2 scenarios (\27[32m2 passed\27[39m)")
    local lines = Render.render_message(msg, { msg })
    local text = tostring(lines[1])
    h.eq("2 scenarios (2 passed)", text)
  end)
end)

h.describe("render: subagent nesting", function()
  local function tool_msg(opts)
    return Message:new("assistant", {
      type = "tool_use",
      name = opts.name or "Bash",
      id = opts.id or "t1",
      input = {},
      status = opts.status or "completed",
    }, opts.metadata or {})
  end

  h.it("reports how many calls are folded under a subagent tool", function()
    local msg = tool_msg({
      name = "Explore watchlist handling",
      metadata = { tool_call = { title = "Explore watchlist handling" }, subagent_children = 12 },
    })
    local text = tostring(Render.render_message(msg, { msg })[1])
    h.is_true(text:find("12 tools", 1, true) ~= nil, "collapsed row must show the count: " .. text)
  end)

  h.it("singularizes a lone nested call", function()
    local msg = tool_msg({ metadata = { tool_call = { title = "One step" }, subagent_children = 1 } })
    local text = tostring(Render.render_message(msg, { msg })[1])
    h.is_true(text:find("1 tool", 1, true) ~= nil)
    h.is_true(text:find("1 tools", 1, true) == nil, "no plural for one")
  end)

  h.it("says nothing when a tool has no nested calls", function()
    local msg = tool_msg({ metadata = { tool_call = { title = "Read x" } } })
    local text = tostring(Render.render_message(msg, { msg })[1])
    h.is_true(text:find("tool", 1, true) == nil or text:find("⊳", 1, true) == nil)
  end)

  h.it("indents a nested call so it reads as part of its parent", function()
    local child = tool_msg({
      id = "c1",
      metadata = { tool_call = { title = "grep -r foo" }, parent_tool_call_id = "toolu_parent" },
    })
    local nested = tostring(Render.render_message(child, { child })[1])
    local plain = tool_msg({ id = "c1", metadata = { tool_call = { title = "grep -r foo" } } })
    local top = tostring(Render.render_message(plain, { plain })[1])
    h.eq("  " .. top, nested, "nested rows are the same row, indented")
  end)
end)

h.describe("Line:indent", function()
  local Line = require("emeth.ui.line")

  h.it("prefixes the rendered text", function()
    h.eq("  ab", tostring(Line:new({ { "a" }, { "b" } }):indent("  ")))
  end)

  h.it("is a no-op for an empty prefix", function()
    local line = Line:new({ { "a" } })
    h.eq(1, #line:indent("").sections)
  end)

  h.it("leaves a blank line blank rather than adding trailing whitespace", function()
    h.eq("", tostring(Line:new({ { "" } }):indent("  ")))
  end)

  -- Highlight columns are derived by walking sections in order, so the prefix has
  -- to be its own section or every highlight after it would be off by its width.
  h.it("shifts highlight columns by the prefix width", function()
    local line = Line:new({ { "ab", "HlA" } }):indent("··")
    local marks = {}
    local orig = vim.api.nvim_buf_add_highlight
    vim.api.nvim_buf_add_highlight = function(_, _, hl, _, from, to)
      marks[#marks + 1] = { hl = hl, from = from, to = to }
    end
    local buf = vim.api.nvim_create_buf(false, true)
    line:set_highlights(0, buf, 0, nil)
    vim.api.nvim_buf_add_highlight = orig
    h.eq(1, #marks)
    h.eq("HlA", marks[1].hl)
    h.eq(#"··", marks[1].from, "highlight must start after the prefix")
  end)
end)

h.describe("render: steered marker", function()
  h.it("shows in the user header when the message cut into a running turn", function()
    local msg = Message:new("user", "use tabs", { steered = true })
    local header = tostring(Render.render_message(msg, { msg })[2])
    h.is_true(header:find("steered", 1, true) ~= nil, "header was: " .. header)
  end)

  h.it("says nothing for an ordinary prompt", function()
    local msg = Message:new("user", "hello", {})
    local header = tostring(Render.render_message(msg, { msg })[2])
    h.is_true(header:find("steered", 1, true) == nil)
  end)

  -- Visible without K: it explains why a user message appears mid-stream, which
  -- is no use if you have to know to go looking for it.
  h.it("is visible without expanding details", function()
    local msg = Message:new("user", "use tabs", { steered = true, model = "opus" })
    h.eq(false, msg._show_details == true)
    local text = table.concat(
      vim.tbl_map(tostring, Render.render_message(msg, { msg })),
      "\n"
    )
    h.is_true(text:find("steered", 1, true) ~= nil)
  end)
end)
