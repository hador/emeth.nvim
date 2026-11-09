local h = require("tests.helpers")
local OpenCode = require("emeth.integrations.opencode")
local Elicit = require("emeth.acp.elicitation")
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

-- ── child_update (advertised capability) ─────────────────────────
-- `opencode/session/child_update` is the notification opencode sends for each
-- child event once we advertise `opencode/child-session-updates`. Content is
-- re-emitted through the update pipeline; terminal status is stamped onto the
-- launch card's `subagent_state`.

local function mock_session()
  local s = { session_id = "ses_parent", _emitted = {} }
  function s:_emit(event, ...)
    self._emitted[#self._emitted + 1] = { event = event, args = { ... } }
  end
  function s:on(event, fn)
    self._listeners = self._listeners or {}
    self._listeners[event] = self._listeners[event] or {}
    self._listeners[event][#self._listeners[event] + 1] = fn
  end
  function s:off(event, fn)
    local list = self._listeners and self._listeners[event]
    if not list then
      return
    end
    for i, f in ipairs(list) do
      if f == fn then
        table.remove(list, i)
        return
      end
    end
  end
  return s
end

local function mock_msg(uuid, tool_call_id)
  return { uuid = uuid, content = { { id = tool_call_id } }, metadata = {} }
end

local function mock_view(msgs)
  return {
    get_messages = function()
      return msgs
    end,
    update_message = function(_, uuid, fn)
      for _, m in ipairs(msgs) do
        if m.uuid == uuid then
          fn(m)
          return
        end
      end
    end,
  }
end

h.describe("opencode child_update (content)", function()
  h.it("re-emits a child content update through the update pipeline", function()
    reset()
    transform(launch("call_L", "Review", "general"))
    local s = mock_session()
    local v = mock_view({ mock_msg("uuid_L", "call_L") })
    local projected = {
      sessionUpdate = "tool_call",
      name = "shell",
      title = "Review: ls",
      toolCallId = "ses_child:call_1",
      _meta = child_tag("Review", "ses_child"),
    }
    OpenCode._handle_child_update(s, v, {
      type = "update",
      childSessionId = "ses_child",
      title = "Review",
      update = projected,
    })
    h.eq(1, #s._emitted)
    h.eq("update", s._emitted[1].event)
    h.eq(projected, s._emitted[1].args[1])
    h.eq("ses_parent", s._emitted[1].args[2])
  end)

  h.it("tolerates a missing update payload", function()
    local s = mock_session()
    OpenCode._handle_child_update(s, nil, { type = "update" })
    h.eq(0, #s._emitted)
    OpenCode._handle_child_update(s, nil, nil)
    h.eq(0, #s._emitted)
  end)
end)

h.describe("opencode child_update (status)", function()
  h.it("stamps a failed child onto its launch card with the error", function()
    reset()
    transform(launch("call_L", "Review", "general"))
    local card = mock_msg("uuid_L", "call_L")
    OpenCode._handle_child_update(mock_session(), mock_view({ card }), {
      type = "status",
      childSessionId = "ses_child",
      title = "Review",
      status = "failed",
      error = { type = "boom", message = "the child exploded" },
    })
    h.eq("failed", card.metadata.subagent_state)
    h.eq("the child exploded", card.metadata.subagent_error)
  end)

  h.it("stamps a completed child as the success state", function()
    reset()
    transform(launch("call_L", "Review", "general"))
    local card = mock_msg("uuid_L", "call_L")
    OpenCode._handle_child_update(mock_session(), mock_view({ card }), {
      type = "status",
      childSessionId = "ses_child",
      title = "Review",
      status = "completed",
    })
    h.eq("idle", card.metadata.subagent_state)
    h.is_nil(card.metadata.subagent_error)
  end)

  h.it("treats an interrupted child as a non-success", function()
    reset()
    transform(launch("call_L", "Review", "general"))
    local card = mock_msg("uuid_L", "call_L")
    OpenCode._handle_child_update(mock_session(), mock_view({ card }), {
      type = "status",
      childSessionId = "ses_child",
      title = "Review",
      status = "interrupted",
    })
    h.eq("failed", card.metadata.subagent_state)
  end)

  h.it("ignores non-terminal states (created/running)", function()
    reset()
    transform(launch("call_L", "Review", "general"))
    local card = mock_msg("uuid_L", "call_L")
    local v = mock_view({ card })
    OpenCode._handle_child_update(mock_session(), v, { type = "status", title = "Review", status = "running" })
    h.is_nil(card.metadata.subagent_state)
    OpenCode._handle_child_update(mock_session(), v, { type = "status", title = "Review", status = "created" })
    h.is_nil(card.metadata.subagent_state)
  end)

  h.it("resolves the launch by bound child id once completion has recorded it", function()
    reset()
    transform(launch("call_L", "Review", "general"))
    transform({
      sessionUpdate = "tool_call_update",
      name = "subagent",
      toolCallId = "call_L",
      status = "completed",
      rawOutput = { metadata = { sessionID = "ses_bound" } },
    })
    local card = mock_msg("uuid_L", "call_L")
    OpenCode._handle_child_update(mock_session(), mock_view({ card }), {
      type = "status",
      childSessionId = "ses_bound",
      status = "failed",
    })
    h.eq("failed", card.metadata.subagent_state)
  end)
end)

h.describe("opencode child_update (setup wiring)", function()
  h.it("routes child_update notifications and cleanup unsubscribes", function()
    local s = mock_session()
    local card = mock_msg("uuid_L", "call_L")
    local v = mock_view({ card })
    local cleanup = OpenCode.setup(s, v)
    transform(launch("call_L", "Review", "general"))
    local listeners = s._listeners and s._listeners["notification"] or {}
    h.eq(1, #listeners)
    listeners[1]("opencode/session/child_update", {
      type = "status",
      childSessionId = "ses_child",
      title = "Review",
      status = "failed",
    })
    h.eq("failed", card.metadata.subagent_state)
    -- An unrelated notification is ignored.
    listeners[1]("_other/thing", { type = "status", status = "failed" })
    cleanup()
    h.eq(0, #(s._listeners and s._listeners["notification"] or {}))
  end)
end)

-- ── transform_elicitation ────────────────────────────────────────
-- opencode's `question` tool arrives as `q<N>` (a select) + `q<N>_custom`
-- (free text) pairs. Folding the companion in asks the user once.

local function question_schema(n)
  local properties = {}
  for i = 0, n - 1 do
    properties["q" .. i] = {
      type = "string",
      title = "Q" .. i,
      description = "question " .. i,
      oneOf = {
        { const = "a" .. i, title = "Option A", description = "does a" },
        { const = "b" .. i, title = "Option B", description = "does b" },
      },
    }
    properties["q" .. i .. "_custom"] = {
      type = "string",
      title = "Q" .. i .. " (other)",
      description = "Type your own answer",
    }
  end
  return { type = "object", properties = properties, required = {} }
end

h.describe("opencode transform_elicitation", function()
  h.it("folds each qN_custom companion into its question", function()
    local fields = OpenCode._transform_elicitation(Elicit.parse(question_schema(3)))
    h.eq(3, #fields, "companions are folded away, not rendered as own prompts")
    h.eq("q0", fields[1].key)
    h.eq("q0_custom", fields[1].custom_key)
    h.eq("q2", fields[3].key)
    h.eq("q2_custom", fields[3].custom_key)
  end)

  h.it("orders q<N> numerically, not lexicographically", function()
    local fields = OpenCode._transform_elicitation(Elicit.parse(question_schema(12)))
    local keys = {}
    for _, f in ipairs(fields) do
      keys[#keys + 1] = f.key
    end
    h.eq("q0", keys[1])
    h.eq("q2", keys[3])
    h.eq("q11", keys[12])
    h.eq(12, #keys)
  end)

  h.it("is idempotent", function()
    local fields = OpenCode._transform_elicitation(Elicit.parse(question_schema(2)))
    local re = OpenCode._transform_elicitation(fields)
    h.eq(2, #re)
    h.eq("q0_custom", re[1].custom_key, "a second pass must not undo the fold")
    h.eq("q1_custom", re[2].custom_key)
  end)

  h.it("routes a typed answer under the companion's own key", function()
    local fields = OpenCode._transform_elicitation(Elicit.parse(question_schema(1)))
    h.eq({ q0_custom = "wsl only" }, Elicit.to_content(fields, { q0_custom = "wsl only" }))
    h.eq({ q0 = "a0", q0_custom = "override" }, Elicit.to_content(fields, { q0 = "a0", q0_custom = "override" }))
  end)

  h.it("does not fold when the base field has no options", function()
    local fields = OpenCode._transform_elicitation(Elicit.parse({
      type = "object",
      properties = {
        note = { type = "string", title = "Note" },
        note_custom = { type = "string", title = "Note (other)" },
      },
    }))
    h.eq(2, #fields, "two text fields are two real questions")
    for _, f in ipairs(fields) do
      h.is_nil(f.custom_key)
    end
  end)

  h.it("leaves an unrelated form untouched", function()
    local fields = OpenCode._transform_elicitation(Elicit.parse({
      type = "object",
      properties = { token = { type = "string", title = "Token" }, remember = { type = "boolean" } },
    }))
    h.eq(2, #fields)
    for _, f in ipairs(fields) do
      h.is_nil(f.custom_key)
    end
  end)
end)

-- ── setup / state ────────────────────────────────────────────────

h.describe("opencode setup", function()
  h.it("registers the update and elicitation transforms, clearing them on cleanup", function()
    local update_hook
    local elicit_hook
    local view = {
      integration = {
        set_transform_update = function(fn)
          update_hook = fn
        end,
        set_transform_elicitation = function(fn)
          elicit_hook = fn
        end,
      },
    }
    local cleanup = OpenCode.setup(nil, view)
    h.is_true(type(update_hook) == "function")
    h.is_true(type(elicit_hook) == "function")
    h.eq(OpenCode._transform_elicitation, elicit_hook)
    cleanup()
    h.is_nil(update_hook)
    h.is_nil(elicit_hook)
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
