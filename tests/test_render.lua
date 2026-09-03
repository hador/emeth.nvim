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

-- The sidebar wraps, so an unclamped header is not "one line" -- Bash sends the
-- entire command as its title, and an inline heredoc script was costing over a
-- hundred screen rows for a row that reads as collapsed.
h.describe("render: oversized tool headers", function()
  local SCRIPT = 'python3 -c "\nimport sys\nprint(sys.path)\nfor i in range(10):\n    print(i)\n"'

  local function bash_msg(command, extra)
    local msg = Message:new("assistant", {
      type = "tool_use",
      name = "Bash",
      id = "b1",
      input = { command = command },
      status = "completed",
    }, { tool_call = { toolCallId = "b1", status = "completed", title = command } })
    for k, v in pairs(extra or {}) do
      msg.metadata[k] = v
    end
    return msg
  end

  h.it("keeps a collapsed row to a single line", function()
    local lines = Render.render_message(bash_msg(SCRIPT), {})
    local content = vim.tbl_filter(function(l)
      return tostring(l) ~= ""
    end, lines)
    h.eq(1, #content, "collapsed tool row must be one line, got: " .. vim.inspect(vim.tbl_map(tostring, lines)))
  end)

  h.it("shows the first physical line, not the flattened whole", function()
    local text = tostring(Render.render_message(bash_msg(SCRIPT), {})[1])
    h.is_true(text:find('python3 -c "', 1, true) ~= nil, "lost the invocation: " .. text)
    h.is_true(text:find("import sys", 1, true) == nil, "later lines must not be inlined: " .. text)
  end)

  h.it("reports how many lines it withheld", function()
    local text = tostring(Render.render_message(bash_msg(SCRIPT), {})[1])
    -- SCRIPT has 5 newlines and no trailing one, so 5 lines are out of sight.
    h.is_true(text:find("+5 lines", 1, true) ~= nil, "expected a withheld count: " .. text)
  end)

  h.it("says nothing about withheld lines for an ordinary one-line command", function()
    local text = tostring(Render.render_message(bash_msg("ls -la"), {})[1])
    h.is_true(text:find("line", 1, true) == nil, "clean row picked up a marker: " .. text)
  end)

  h.it("singularizes a single withheld line", function()
    local text = tostring(Render.render_message(bash_msg("echo a\necho b"), {})[1])
    h.is_true(text:find("+1 line", 1, true) ~= nil, text)
    h.is_true(text:find("+1 lines", 1, true) == nil, "no plural for one")
  end)

  h.it("does not count a trailing newline as a withheld line", function()
    local text = tostring(Render.render_message(bash_msg("ls -la\n"), {})[1])
    h.is_true(text:find("line", 1, true) == nil, "trailing newline hides nothing: " .. text)
  end)

  h.it("clamps a long single-line command to the configured budget", function()
    local long = "grep -rn " .. string.rep("x", 400)
    local text = tostring(Render.render_message(bash_msg(long), {})[1])
    h.is_true(text:find("…", 1, true) ~= nil, "expected an ellipsis: " .. text)
    -- Budget (100) plus the box, icon and ellipsis -- nowhere near the 409 raw.
    h.is_true(vim.fn.strchars(text) < 120, "header still oversized: " .. vim.fn.strchars(text))
  end)

  h.it("clamps on characters, not bytes, so multibyte text is not split", function()
    local long = string.rep("é", 400)
    local text = tostring(Render.render_message(bash_msg(long), {})[1])
    h.eq(text, vim.fn.strcharpart(text, 0), "header must stay valid utf-8")
    h.is_true(vim.fn.strchars(text) < 120, "header still oversized")
  end)

  h.it("prints a command that doubles as the title only once", function()
    local text = tostring(Render.render_message(bash_msg("ls -la /tmp"), {})[1])
    local _, count = text:gsub("ls %-la /tmp", "")
    h.eq(1, count, "command printed twice: " .. text)
  end)

  h.it("still shows a param that is not already in the title", function()
    local msg = Message:new("assistant", {
      type = "tool_use",
      name = "Read",
      id = "r1",
      input = { path = "/tmp/a.lua" },
      status = "completed",
    }, { tool_call = { toolCallId = "r1", status = "completed", title = "Read a file" } })
    local text = tostring(Render.render_message(msg, {})[1])
    h.is_true(text:find("Read a file", 1, true) ~= nil, text)
    h.is_true(text:find("/tmp/a.lua", 1, true) ~= nil, "param was dropped: " .. text)
  end)

  -- Clamping the header removed the only place a long command ever appeared: a
  -- tool's body is its output, not its invocation. Expanding has to bring it back
  -- or the command is unreachable at every expand state.
  h.describe("expanding reaches the command the header cut", function()
    local function expanded(msg)
      msg.metadata._expanded = true
      return table.concat(vim.tbl_map(tostring, Render.render_message(msg, {})), "\n")
    end

    h.it("shows every line of a multi-line command", function()
      local out = expanded(bash_msg(SCRIPT))
      h.is_true(out:find("import sys", 1, true) ~= nil, "lost the script body: " .. out)
      h.is_true(out:find("print(sys.path)", 1, true) ~= nil, out)
      h.is_true(out:find("for i in range(10):", 1, true) ~= nil, out)
    end)

    h.it("shows a long single-line command in full, unelided", function()
      local long = "grep -rn " .. string.rep("x", 400)
      local out = expanded(bash_msg(long))
      h.is_true(out:find(long, 1, true) ~= nil, "command was not restored in full")
    end)

    h.it("does not repeat a command that already fit in the header", function()
      local out = expanded(bash_msg("ls -la"))
      local _, count = out:gsub("ls %-la", "")
      h.eq(1, count, "short command echoed twice: " .. out)
    end)

    h.it("keeps the command above the output", function()
      local msg = bash_msg(SCRIPT)
      msg.metadata.tool_call.content =
        { { type = "content", content = { type = "text", text = "OUTPUT_MARKER" } } }
      local out = expanded(msg)
      local cmd_at = out:find("import sys", 1, true)
      local out_at = out:find("OUTPUT_MARKER", 1, true)
      h.is_true(cmd_at ~= nil and out_at ~= nil, "expected both: " .. out)
      h.is_true(cmd_at < out_at, "command must come before its output")
    end)

    -- The fence line already names the file, so restoring a clamped path above
    -- the diff would print it twice and give back the height the clamp saved.
    h.it("does not repeat a long path the diff fence already shows", function()
      local long = "/tmp/" .. string.rep("deep/", 30) .. "x.lua"
      local msg = Message:new("assistant", {
        type = "tool_use",
        name = "Edit",
        id = "p1",
        input = { path = long, old_str = "a\nb\nc", new_str = "a\nX\nc" },
        status = "completed",
      }, { tool_call = { toolCallId = "p1", status = "completed", title = long } })
      msg.metadata._expanded = true
      local out = table.concat(vim.tbl_map(tostring, Render.render_message(msg, {})), "\n")
      local _, count = out:gsub(vim.pesc(long), "")
      h.eq(1, count, "path printed " .. count .. " times: " .. out)
    end)

    -- The fence label usually comes from a content diff's own `path`, not from
    -- `rawInput.path` (frequently absent). Looking only at rawInput misses it, and
    -- the header's absolute path then gets restored above a fence already naming it.
    h.it("dedupes against a path carried on the content diff", function()
      local long = "/Volumes/ws/" .. string.rep("deep/", 30) .. "Executor.kt"
      local msg = Message:new("assistant", {
        type = "tool_use",
        name = "Edit",
        id = "p2",
        input = { file_path = long },
        status = "completed",
      }, {
        tool_call = {
          toolCallId = "p2",
          status = "completed",
          title = "Edit Executor.kt",
          content = { { type = "diff", path = long, oldText = "a\nb\nc", newText = "a\nX\nc" } },
        },
      })
      msg.metadata._expanded = true
      local out = table.concat(vim.tbl_map(tostring, Render.render_message(msg, {})), "\n")
      local _, count = out:gsub(vim.pesc(long), "")
      h.eq(1, count, "path printed " .. count .. " times: " .. out)
    end)

    h.it("keeps the path out of the header when the fence already names it", function()
      local path = "/Volumes/ws/src/Executor.kt"
      local msg = Message:new("assistant", {
        type = "tool_use",
        name = "Edit",
        id = "p3",
        input = { path = path },
        status = "completed",
      }, {
        tool_call = {
          toolCallId = "p3",
          status = "completed",
          title = "Edit Executor.kt",
          content = { { type = "diff", path = path, oldText = "a\nb\nc", newText = "a\nX\nc" } },
        },
      })
      local header = tostring(Render.render_message(msg, {})[1])
      h.is_true(header:find(path, 1, true) == nil, "path duplicated into the header: " .. header)
      h.is_true(header:find("Edit Executor.kt", 1, true) ~= nil, "lost the title: " .. header)
    end)

    -- Deliberately not the path: `diff_to_lines` puts the path on the fence line,
    -- so a path-based title would pass whether or not the box restores it.
    h.it("restores a cut title on a diff too", function()
      local title = "Rewrite the config\nsecond line of the title"
      local msg = Message:new("assistant", {
        type = "tool_use",
        name = "Write",
        id = "w9",
        input = { path = "/tmp/x.lua", old_str = "a\nb\nc", new_str = "a\nX\nc" },
        status = "completed",
      }, { tool_call = { toolCallId = "w9", status = "completed", title = title } })
      local out = expanded(msg)
      h.is_true(out:find("second line of the title", 1, true) ~= nil, "cut title unreachable: " .. out)
    end)
  end)

  h.it("honours tool_header_max_chars", function()
    local emeth = package.loaded["emeth"]
    local long = "grep -rn " .. string.rep("x", 400)
    emeth.config.tool_header_max_chars = 20
        local short = vim.fn.strchars(tostring(Render.render_message(bash_msg(long), {})[1]))
    emeth.config.tool_header_max_chars = 200
    local wide = vim.fn.strchars(tostring(Render.render_message(bash_msg(long), {})[1]))
    emeth.config.tool_header_max_chars = nil
    h.is_true(wide > short, ("config ignored: %d vs %d"):format(wide, short))
  end)
end)

-- The model sends a one-line summary of what a call is for alongside the command
-- (`rawInput.description`). It's short, it says intent, and it makes a far better
-- header than any truncation of the command -- which then goes in the body in full.
h.describe("render: model-supplied summary as the header", function()
  local function exec_msg(opts)
    local input = { command = opts.command }
    if opts.desc then
      input.description = opts.desc
    end
    return Message:new("assistant", {
      type = "tool_use",
      name = "execute",
      id = "e1",
      input = input,
      status = "completed",
    }, {
      tool_call = {
        toolCallId = "e1",
        kind = opts.kind or "execute",
        status = "completed",
        title = opts.command,
        content = opts.output and { { type = "content", content = { type = "text", text = opts.output } } } or nil,
      },
    })
  end

  local function render(msg)
    return table.concat(vim.tbl_map(tostring, Render.render_message(msg, {})), "\n")
  end

  local function expand(msg)
    msg.metadata._expanded = true
    return render(msg)
  end

  h.it("labels the collapsed row with the summary, not the command", function()
    local row = tostring(Render.render_message(
      exec_msg({ command = "grep -rn foo src/ | head -50", desc = "Find the cache API" }),
      {}
    )[1])
    h.is_true(row:find("Find the cache API", 1, true) ~= nil, "summary missing: " .. row)
    h.is_true(row:find("grep -rn", 1, true) == nil, "command should not be in the header: " .. row)
  end)

  h.it("keeps that row to one line even for a huge command", function()
    local msg = exec_msg({ command = "python3 -c \"\n" .. string.rep("print(1)\n", 200) .. '"', desc = "Run a script" })
    local content = vim.tbl_filter(function(l)
      return tostring(l) ~= ""
    end, Render.render_message(msg, {}))
    h.eq(1, #content)
  end)

  h.it("falls back to the command when no summary was sent", function()
    local row = tostring(Render.render_message(exec_msg({ command = "ls -la /tmp" }), {})[1])
    h.is_true(row:find("ls -la /tmp", 1, true) ~= nil, row)
  end)

  h.it("ignores a multi-line description, which would defeat the point", function()
    local row = tostring(Render.render_message(
      exec_msg({ command = "ls -la", desc = "line one\nline two" }),
      {}
    )[1])
    h.is_true(row:find("line two", 1, true) == nil, "multi-line summary leaked into the header: " .. row)
    h.is_true(row:find("ls -la", 1, true) ~= nil, "should have fallen back to the command: " .. row)
  end)

  h.it("shows the command in full in the body, since the header no longer has it", function()
    local cmd = "grep -rn foo src/ | head -50"
    local out = expand(exec_msg({ command = cmd, desc = "Find the cache API" }))
    h.is_true(out:find(cmd, 1, true) ~= nil, "command unreachable: " .. out)
  end)

  -- Column 0 is the point: markdown treesitter only opens a fence after at most
  -- three spaces of indent, so a decorated body could never be highlighted.
  h.it("fences the command as shell at column zero for an execute tool", function()
    local out = expand(exec_msg({ command = "ls -la", desc = "List files" }))
    h.is_true(out:find("\n```bash\n", 1, true) ~= nil, "expected an unindented bash fence: " .. out)
  end)

  h.it("does not claim shell for a non-execute tool", function()
    local out = expand(exec_msg({ command = "SELECT 1", desc = "Query", kind = "other" }))
    h.is_true(out:find("```bash", 1, true) == nil, "bash fence on a non-execute tool: " .. out)
  end)

  h.it("escalates the fence when the command contains backticks", function()
    local out = expand(exec_msg({ command = 'echo "```oops```"', desc = "Echo" }))
    h.is_true(out:find("````bash", 1, true) ~= nil, "fence must outrun the content: " .. out)
  end)

  h.it("divides the command from the output", function()
    local out = expand(exec_msg({ command = "ls", desc = "List", output = "a.txt" }))
    h.is_true(out:find("├─ output", 1, true) ~= nil, "expected a divider: " .. out)
    h.is_true(out:find("ls", 1, true) < out:find("├─ output", 1, true), "divider must follow the command")
    h.is_true(out:find("├─ output", 1, true) < out:find("a.txt", 1, true), "divider must precede the output")
  end)

  h.it("skips the divider when there is no command block above it", function()
    local msg = exec_msg({ command = "ls", output = "a.txt" })
    -- No summary and a short command, so the header shows it and the body is
    -- output only -- nothing to divide from.
    local out = expand(msg)
    h.is_true(out:find("├─ output", 1, true) == nil, "divider with nothing above it: " .. out)
  end)

  -- Agents send output pre-fenced 63% of the time; re-wrapping would nest fences
  -- and highlight neither block.
  h.it("passes pre-fenced output through without nesting a second fence", function()
    local out = expand(exec_msg({ command = "ls", desc = "List", output = "```console\na.txt\n```" }))
    local _, fences = out:gsub("```console", "")
    h.eq(1, fences, "console fence duplicated: " .. out)
    h.is_true(out:find("````console", 1, true) == nil, "output got re-wrapped: " .. out)
  end)
end)

-- `Write` sends an empty oldText, so the whole file arrives as one hunk. Left
-- unfolded that buries the conversation; `Edit`'s few-line hunks are the case
-- worth keeping inline.
h.describe("render: diff folding", function()
  local function diff_msg(old, new)
    return Message:new("assistant", {
      type = "tool_use",
      name = "Write",
      id = "d1",
      input = { path = "/tmp/big.lua", old_str = old, new_str = new },
      status = "completed",
    }, { tool_call = { toolCallId = "d1", status = "completed", title = "/tmp/big.lua" } })
  end

  local function big()
    local body = {}
    for i = 1, 200 do
      body[i] = "line " .. i
    end
    return diff_msg("", table.concat(body, "\n"))
  end

  local function render(msg)
    return table.concat(vim.tbl_map(tostring, Render.render_message(msg, {})), "\n")
  end

  h.it("folds a whole-file write by default", function()
    local msg = big()
    local out = render(msg)
    h.is_true(out:find("┏━", 1, true) == nil, "big diff should not be expanded")
    h.is_true(out:find("line 150", 1, true) == nil, "diff body leaked into a folded row")
  end)

  h.it("says how many diff lines it folded away", function()
    h.is_true(render(big()):find("+20", 1, true) ~= nil, "expected a withheld count: " .. render(big()))
  end)

  h.it("keeps a small edit hunk inline", function()
    local out = render(diff_msg("a\nb\nc", "a\nX\nc"))
    h.is_true(out:find("┏━", 1, true) ~= nil, "small diff must stay expanded: " .. out)
    h.is_true(out:find("+ a?X", 1, false) ~= nil or out:find("X", 1, true) ~= nil, out)
  end)

  h.it("expands a folded diff once asked", function()
    local msg = big()
    msg.metadata._expanded = true
    local out = render(msg)
    h.is_true(out:find("┏━", 1, true) ~= nil, "expected the heavy box back")
    h.is_true(out:find("line 150", 1, true) ~= nil, "expected the full body")
  end)

  h.it("folds a small diff once asked", function()
    local msg = diff_msg("a\nb\nc", "a\nX\nc")
    msg.metadata._expanded = false
    local out = render(msg)
    h.is_true(out:find("┏━", 1, true) == nil, "explicit collapse ignored: " .. out)
  end)

  h.it("honours diff_collapse_lines", function()
    local emeth = package.loaded["emeth"]
    local msg = diff_msg("a\nb\nc", "a\nX\nc")
    emeth.config.diff_collapse_lines = 1
    local folded = render(msg)
    emeth.config.diff_collapse_lines = nil
    h.is_true(folded:find("┏━", 1, true) == nil, "config ignored: " .. folded)
  end)

  -- `K` flips `_expanded`, which starts nil. A small diff is already on screen
  -- at that point, so the keymap has to ask what's rendered rather than assume
  -- the field means "collapsed".
  h.describe("is_expanded reports the effective state", function()
    h.it("true for a small diff that has never been toggled", function()
      h.eq(true, Render.is_expanded(diff_msg("a\nb\nc", "a\nX\nc")))
    end)

    h.it("false for a big diff that has never been toggled", function()
      h.eq(false, Render.is_expanded(big()))
    end)

    h.it("false for a non-diff tool call", function()
      local msg = Message:new(
        "assistant",
        { type = "tool_use", name = "Bash", id = "x1", input = { command = "ls" }, status = "completed" },
        { tool_call = { toolCallId = "x1", status = "completed" } }
      )
      h.eq(false, Render.is_expanded(msg))
    end)

    h.it("defers to an explicit toggle", function()
      local msg = big()
      msg.metadata._expanded = true
      h.eq(true, Render.is_expanded(msg))
    end)
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
