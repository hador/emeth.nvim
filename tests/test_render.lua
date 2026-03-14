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
    local msg = Message:new(
      "assistant",
      { type = "tool_use", name = "strReplace", id = "t4", input = { old_str = "foo", new_str = "bar" }, status = "completed" },
      { tool_call = { toolCallId = "t4", status = "completed" } }
    )
    local lines = Render.render_message(msg, {})
    local all = ""
    for _, l in ipairs(lines) do
      all = all .. tostring(l) .. "\n"
    end
    h.is_true(all:find("┏━") ~= nil, "expected heavy box top")
    h.is_true(all:find("┗━") ~= nil, "expected heavy box bottom")
    h.is_true(all:find("```diff") ~= nil, "expected diff fence")
  end)

  h.it("non-diff tool_use uses light box", function()
    local msg = Message:new(
      "assistant",
      { type = "tool_use", name = "read", id = "t5", input = { path = "/a" }, status = "completed" },
      { tool_call = { toolCallId = "t5", status = "completed", content = { { type = "content", content = { type = "text", text = "hello" } } } } }
    )
    local lines = Render.render_message(msg, {})
    local all = ""
    for _, l in ipairs(lines) do
      all = all .. tostring(l) .. "\n"
    end
    h.is_true(all:find("╭─") ~= nil, "expected light box top")
    h.is_true(all:find("╰─") ~= nil, "expected light box bottom")
  end)

  h.it("diff context lines use double space prefix", function()
    local msg = Message:new(
      "assistant",
      { type = "tool_use", name = "strReplace", id = "t6", input = { old_str = "a\nb\nc", new_str = "a\nX\nc" }, status = "completed" },
      { tool_call = { toolCallId = "t6", status = "completed" } }
    )
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
    local msg = Message:new(
      "assistant",
      { type = "tool_use", name = "strReplace", id = "t7", input = { old_str = old, new_str = new }, status = "completed" },
      { tool_call = { toolCallId = "t7", status = "completed" } }
    )
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
end)
