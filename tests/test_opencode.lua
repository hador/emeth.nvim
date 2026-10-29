local h = require("tests.helpers")
local OpenCode = require("emeth.integrations.opencode")
local transform = OpenCode._transform_update

local function reset()
  -- setup() re-initialises module state without touching the view.
  OpenCode.setup(nil, nil)
end

local function child_tag(title, id)
  return { ["opencode/child-session"] = { depth = 1, id = id, parentID = "ses_parent", title = title } }
end

local function launch(id, description, agent)
  return {
    sessionUpdate = "tool_call",
    name = "subagent",
    kind = "think",
    title = "subagent",
    toolCallId = id,
    rawInput = { agent = agent, description = description, prompt = "do it" },
  }
end

-- ── transform_update: tagged child calls ─────────────────────────

h.describe("opencode transform_update (child calls)", function()
  h.it("parents a child tool call on its launch and strips the description prefix", function()
    reset()
    transform(launch("call_L", "Review script comments", "general"))
    local u = {
      sessionUpdate = "tool_call",
      name = "shell",
      kind = "execute",
      title = "Review script comments: shell",
      toolCallId = "ses_child:call_1",
      rawInput = { command = "ls", cwd = "/x" },
      _meta = child_tag("Review script comments", "ses_child"),
    }
    h.is_nil(transform(u))
    h.eq("call_L", u.parent_tool_call_id)
    h.eq("shell", u.title)
  end)

  h.it("leaves the full command as the title once opencode fills it in", function()
    reset()
    transform(launch("call_L", "Find usages", "explore"))
    local u = {
      sessionUpdate = "tool_call_update",
      name = "grep",
      title = "Find usages: grep -rn transform lua/",
      status = "in_progress",
      toolCallId = "ses_c:call_2",
      _meta = child_tag("Find usages", "ses_c"),
    }
    transform(u)
    h.eq("call_L", u.parent_tool_call_id)
    h.eq("grep -rn transform lua/", u.title)
  end)

  h.it("does not mangle a child title that merely starts like the prefix", function()
    reset()
    transform(launch("call_L", "Find usages", "general"))
    local u = {
      sessionUpdate = "tool_call",
      name = "shell",
      title = "Find usages without the colon: ls",
      toolCallId = "ses_c:call_3",
      _meta = child_tag("Find usages", "ses_c"),
    }
    transform(u)
    -- Separator is `"<title>: "`; a title that merely contains the description
    -- is left alone.
    h.eq("Find usages without the colon: ls", u.title)
  end)

  h.it("resolves a child by session id once the launch completion has bound it", function()
    reset()
    transform(launch("call_L", "Some description", "general"))
    transform({
      sessionUpdate = "tool_call_update",
      name = "subagent",
      toolCallId = "call_L",
      status = "completed",
      rawOutput = { metadata = { sessionID = "ses_done", status = "completed", truncated = false } },
    })
    -- No description match on the tag — only the id should resolve.
    local u = {
      sessionUpdate = "tool_call",
      name = "shell",
      title = "unrelated: ls",
      toolCallId = "ses_done:call_9",
      _meta = { ["opencode/child-session"] = { depth = 1, id = "ses_done" } },
    }
    transform(u)
    h.eq("call_L", u.parent_tool_call_id)
  end)

  h.it("falls back to the last launch when the tag resolves no other way", function()
    reset()
    transform({
      sessionUpdate = "tool_call",
      name = "subagent",
      title = "subagent",
      toolCallId = "call_F",
      rawInput = vim.empty_dict(), -- rawInput not landed yet
    })
    local u = {
      sessionUpdate = "tool_call",
      name = "shell",
      title = "who knows: ls",
      toolCallId = "ses_x:call_1",
      _meta = { ["opencode/child-session"] = { depth = 1, id = "ses_x" } },
    }
    transform(u)
    h.eq("call_F", u.parent_tool_call_id)
  end)

  h.it("drops tagged prose chunks that would leak into our conversation", function()
    reset()
    transform(launch("call_L", "Any", "general"))
    local thought = {
      sessionUpdate = "agent_thought_chunk",
      content = { text = "The user wants me to", type = "text" },
      _meta = child_tag("Any", "ses_child"),
    }
    h.eq(false, transform(thought))
    local message = {
      sessionUpdate = "agent_message_chunk",
      content = { text = "it is done", type = "text" },
      _meta = child_tag("Any", "ses_child"),
    }
    h.eq(false, transform(message))
    h.eq(false, transform({ sessionUpdate = "plan", entries = {}, _meta = child_tag("Any", "ses_child") }))
  end)
end)

-- ── transform_update: launches ───────────────────────────────────

h.describe("opencode transform_update (launches)", function()
  h.it("rewrites the launch title to description + agent once rawInput lands", function()
    reset()
    local pending = {
      sessionUpdate = "tool_call",
      name = "subagent",
      title = "subagent",
      toolCallId = "call_L",
      rawInput = vim.empty_dict(),
    }
    transform(pending)
    h.eq("subagent", pending.title) -- nothing to rewrite yet
    local running = {
      sessionUpdate = "tool_call_update",
      name = "subagent",
      toolCallId = "call_L",
      status = "in_progress",
      rawInput = { agent = "general", description = "Review script comments", prompt = "do it" },
    }
    transform(running)
    h.eq("Review script comments ⊳ general", running.title)
  end)

  h.it("rewrites to just the description when no agent is named", function()
    reset()
    local u = {
      sessionUpdate = "tool_call",
      name = "subagent",
      title = "subagent",
      toolCallId = "call_L",
      rawInput = { description = "Just a description", prompt = "p" },
    }
    transform(u)
    h.eq("Just a description", u.title)
  end)

  h.it("records a nested (tagged) launch under its parent and resolves its children", function()
    reset()
    transform(launch("call_L1", "Outer", "general"))
    local nested = {
      sessionUpdate = "tool_call",
      name = "subagent",
      title = "subagent",
      toolCallId = "call_L2",
      rawInput = { agent = "worker", description = "Inner", prompt = "p" },
      _meta = child_tag("Outer", "ses_outer"),
    }
    transform(nested)
    h.eq("call_L1", nested.parent_tool_call_id)
    h.eq("Inner ⊳ worker", nested.title)
    local u = {
      sessionUpdate = "tool_call",
      name = "shell",
      title = "Inner: ls",
      toolCallId = "ses_inner:call_1",
      _meta = { ["opencode/child-session"] = { depth = 2, id = "ses_inner", title = "Inner" } },
    }
    transform(u)
    h.eq("call_L2", u.parent_tool_call_id)
  end)

  h.it("a nested launch does not clobber the last-launch fallback", function()
    reset()
    transform(launch("call_L1", "Outer", "general"))
    transform({
      sessionUpdate = "tool_call",
      name = "subagent",
      title = "subagent",
      toolCallId = "call_L2",
      rawInput = { agent = "worker", description = "Inner", prompt = "p" },
      _meta = child_tag("Outer", "ses_outer"),
    })
    -- An unmatched depth-1 child must still land on the top-level launch, not
    -- the nested one.
    local u = {
      sessionUpdate = "tool_call",
      name = "shell",
      title = "mystery: ls",
      toolCallId = "ses_outer:call_2",
      _meta = { ["opencode/child-session"] = { depth = 1, id = "ses_unknown" } },
    }
    transform(u)
    h.eq("call_L1", u.parent_tool_call_id)
  end)

  h.it("binds the child session id on completion", function()
    reset()
    transform(launch("call_L", "D", "general"))
    local done = {
      sessionUpdate = "tool_call_update",
      name = "subagent",
      toolCallId = "call_L",
      status = "completed",
      content = { text = "done", type = "text" },
      rawOutput = { metadata = { sessionID = "ses_done", status = "completed" } },
    }
    h.is_nil(transform(done))
    local u = {
      sessionUpdate = "tool_call",
      name = "shell",
      title = "late: ls",
      toolCallId = "ses_done:call_5",
      _meta = { ["opencode/child-session"] = { depth = 1, id = "ses_done", title = "something else" } },
    }
    transform(u)
    h.eq("call_L", u.parent_tool_call_id)
  end)
end)

-- ── transform_update: pass-through ───────────────────────────────

h.describe("opencode transform_update (pass-through)", function()
  h.it("leaves untagged non-launch updates alone", function()
    reset()
    local msg = { sessionUpdate = "agent_message_chunk", content = { text = "hi", type = "text" } }
    h.is_nil(transform(msg))
    h.is_nil(msg.parent_tool_call_id)
    local tool = {
      sessionUpdate = "tool_call",
      name = "shell",
      title = "shell",
      toolCallId = "call_s",
      rawInput = { command = "ls" },
    }
    h.is_nil(transform(tool))
    h.eq("shell", tool.title)
    h.is_nil(tool.parent_tool_call_id)
  end)

  h.it("tolerates malformed input without erroring", function()
    reset()
    h.is_nil(transform(nil))
    h.is_nil(transform({ sessionUpdate = "tool_call", name = "subagent" })) -- no toolCallId
    -- Presence decides: a malformed value is still child traffic, so its prose
    -- is dropped rather than leaking out.
    local tagged = {
      sessionUpdate = "agent_message_chunk",
      content = { text = "x", type = "text" },
      _meta = { ["opencode/child-session"] = "nope" },
    }
    h.eq(false, transform(tagged))
  end)
end)

-- ── setup / state ────────────────────────────────────────────────

h.describe("opencode setup", function()
  h.it("registers the transform and clears it on cleanup", function()
    local hook
    local view = { integration = {
      set_transform_update = function(fn)
        hook = fn
      end,
    } }
    local cleanup = OpenCode.setup(nil, view)
    h.is_true(type(hook) == "function")
    cleanup()
    h.is_nil(hook)
  end)

  h.it("resets binding state between sessions", function()
    reset()
    transform(launch("call_old", "Old description", "general"))
    OpenCode.setup(nil, nil)
    local u = {
      sessionUpdate = "tool_call",
      name = "shell",
      title = "Old description: ls",
      toolCallId = "ses_fresh:call_1",
      _meta = child_tag("Old description", "ses_fresh"),
    }
    transform(u)
    h.is_nil(u.parent_tool_call_id) -- nothing left to resolve to
  end)
end)

-- ── format_mode ──────────────────────────────────────────────────

h.describe("opencode format_mode", function()
  h.it("nil/empty → nil", function()
    h.is_nil(OpenCode.format_mode(nil))
    h.is_nil(OpenCode.format_mode(""))
  end)

  h.it("build is the default mode: badge only, no bottom-bar tag", function()
    h.eq({ badge = "⚙ build" }, OpenCode.format_mode("build"))
  end)

  h.it("plan and worker carry a bottom-bar tag", function()
    h.eq({ badge = "⚙ plan", tag = "plan", tag_kind = "info" }, OpenCode.format_mode("plan"))
    h.eq({ badge = "⚙ worker", tag = "worker", tag_kind = "hint" }, OpenCode.format_mode("worker"))
  end)

  h.it("unknown modes fall back to a generic badge + tag", function()
    h.eq({ badge = "⚙ focus", tag = "focus", tag_kind = "hint" }, OpenCode.format_mode("focus"))
  end)
end)

-- ── format_model ─────────────────────────────────────────────────

h.describe("opencode format_model", function()
  h.it("strips the source prefix", function()
    h.eq("qwen3.8:27b", OpenCode.format_model("ollama/qwen3.8:27b"))
    h.eq("beam-free", OpenCode.format_model("opencode/beam-free"))
  end)

  h.it("strips only the first segment", function()
    h.eq("hf.co/bartowski/gemma-2-9b-it:Q5_K_M", OpenCode.format_model("ollama/hf.co/bartowski/gemma-2-9b-it:Q5_K_M"))
  end)

  h.it("passes un-prefixed ids through", function()
    h.eq("qwen3.8:27b", OpenCode.format_model("qwen3.8:27b"))
    h.eq("", OpenCode.format_model(""))
  end)
end)
