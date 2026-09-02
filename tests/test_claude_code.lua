local h = require("tests.helpers")
local CC = require("emeth.integrations.claude-code")

h.describe("claude-code format_mode", function()
  h.it("returns nil for nil input", function()
    h.is_nil(CC.format_mode(nil))
  end)

  h.it("returns nil for empty string", function()
    h.is_nil(CC.format_mode(""))
  end)

  h.it("default has badge but no tag (normal mode)", function()
    local desc = CC.format_mode("default")
    h.eq("⚙ ask", desc.badge)
    h.is_nil(desc.tag)
    h.is_nil(desc.tag_kind)
  end)

  h.it("auto has badge but no tag (normal mode)", function()
    local desc = CC.format_mode("auto")
    h.eq("⚙ auto", desc.badge)
    h.is_nil(desc.tag)
  end)

  h.it("plan emits badge + tag with info kind", function()
    local desc = CC.format_mode("plan")
    h.eq("⚙ plan", desc.badge)
    h.eq("plan", desc.tag)
    h.eq("info", desc.tag_kind)
  end)

  h.it("acceptEdits maps label to auto-edit with info kind", function()
    local desc = CC.format_mode("acceptEdits")
    h.eq("⚙ auto-edit", desc.badge)
    h.eq("auto-edit", desc.tag)
    h.eq("info", desc.tag_kind)
  end)

  h.it("dontAsk uses warn kind", function()
    local desc = CC.format_mode("dontAsk")
    h.eq("⚙ deny-default", desc.badge)
    h.eq("deny-default", desc.tag)
    h.eq("warn", desc.tag_kind)
  end)

  h.it("bypassPermissions uses error kind", function()
    local desc = CC.format_mode("bypassPermissions")
    h.eq("⚙ bypass", desc.badge)
    h.eq("bypass", desc.tag)
    h.eq("error", desc.tag_kind)
  end)

  h.it("falls back to raw mode_id with hint kind for unknown modes", function()
    local desc = CC.format_mode("customMode")
    h.eq("⚙ customMode", desc.badge)
    h.eq("customMode", desc.tag)
    h.eq("hint", desc.tag_kind)
  end)

  h.it("badge label has no leading icon when caller wants raw text", function()
    -- Tags never include an icon — generic acp.lua uses them verbatim
    -- without any post-processing. Verify by checking the plan label.
    local desc = CC.format_mode("plan")
    h.is_nil(desc.tag:find("⚙"))
  end)
end)

h.describe("claude-code build_session_meta", function()
  h.it("returns nil when claude_code config missing", function()
    h.is_nil(CC.build_session_meta({}))
  end)

  h.it("returns nil when extra_args is nil", function()
    h.is_nil(CC.build_session_meta({ claude_code = {} }))
  end)

  h.it("returns nil when extra_args is an empty table", function()
    h.is_nil(CC.build_session_meta({ claude_code = { extra_args = {} } }))
  end)

  h.it("returns nil when extra_args is the wrong type", function()
    h.is_nil(CC.build_session_meta({ claude_code = { extra_args = "agent=foo" } }))
  end)

  h.it("wraps extra_args in claudeCode.options.extraArgs envelope", function()
    local meta = CC.build_session_meta({
      claude_code = { extra_args = { agent = "flax-kitchen", verbose = true } },
    })
    h.eq({
      claudeCode = {
        options = {
          extraArgs = { agent = "flax-kitchen", verbose = true },
        },
      },
    }, meta)
  end)

  h.it("deep-copies extra_args so caller mutation does not leak", function()
    local args = { agent = "a" }
    local meta = CC.build_session_meta({ claude_code = { extra_args = args } })
    args.agent = "b"
    h.eq("a", meta.claudeCode.options.extraArgs.agent)
  end)
end)

h.describe("claude-code format_model", function()
  -- Capturing configOptions → model_id/mode_id now lives generically in
  -- session.lua (see test_acp_session.lua); the extension only shortens the
  -- model id for display.
  h.it("strips the claude- token and trailing release date", function()
    h.eq("opus-4-6", CC.format_model("claude-opus-4-6"))
    h.eq("sonnet-4-5", CC.format_model("claude-sonnet-4-5-20250101"))
  end)

  h.it("strips the claude- token even inside a Bedrock-style prefix", function()
    -- The generic length fallback in the core integration drops the dotted
    -- prefix; the hook only removes claude-family noise wherever it appears.
    h.eq("global.anthropic.opus-4-8[1m]", CC.format_model("global.anthropic.claude-opus-4-8[1m]"))
  end)

  h.it("leaves an already-short id unchanged", function()
    h.eq("opus", CC.format_model("opus"))
  end)
end)

h.describe("claude-code transform_update", function()
  local transform = CC._transform_update

  h.it("is a no-op for non-Task updates", function()
    local u = { sessionUpdate = "tool_call", title = "Read foo", _meta = { claudeCode = { toolName = "Read" } } }
    transform(u)
    h.eq("Read foo", u.title)
  end)

  h.it("is a no-op when update has no _meta", function()
    local u = { sessionUpdate = "tool_call", title = "x" }
    transform(u)
    h.eq("x", u.title)
  end)

  h.it("rewrites title from rawInput description + subagent_type", function()
    local u = {
      sessionUpdate = "tool_call",
      toolCallId = "t1",
      title = "Task",
      _meta = { claudeCode = { toolName = "Task" } },
      rawInput = { description = "Find references", subagent_type = "Explore" },
    }
    transform(u)
    h.eq("Find references ⊳ Explore", u.title)
  end)

  h.it("uses description alone when subagent_type missing", function()
    local u = {
      sessionUpdate = "tool_call",
      toolCallId = "t2",
      title = "Task",
      _meta = { claudeCode = { toolName = "Task" } },
      rawInput = { description = "Find references" },
    }
    transform(u)
    h.eq("Find references", u.title)
  end)

  h.it("falls back to existing title when rawInput has no description", function()
    local u = {
      sessionUpdate = "tool_call",
      toolCallId = "t3",
      title = "Task",
      _meta = { claudeCode = { toolName = "Task" } },
      rawInput = {},
    }
    transform(u)
    h.eq("Task", u.title)
  end)

  h.it("ignores empty-string subagent_type", function()
    local u = {
      sessionUpdate = "tool_call",
      toolCallId = "t4",
      title = "Task",
      _meta = { claudeCode = { toolName = "Task" } },
      rawInput = { description = "Find foo", subagent_type = "" },
    }
    transform(u)
    h.eq("Find foo", u.title)
  end)

  h.it("treats Agent toolName the same as Task", function()
    local u = {
      sessionUpdate = "tool_call",
      toolCallId = "a1",
      title = "Agent",
      _meta = { claudeCode = { toolName = "Agent" } },
      rawInput = { description = "Subagent A", subagent_type = "Plan" },
    }
    transform(u)
    h.eq("Subagent A ⊳ Plan", u.title)
  end)

  h.it("uses update.title as description fallback when rawInput empty", function()
    local u = {
      sessionUpdate = "tool_call",
      toolCallId = "t5",
      title = "Side quest",
      _meta = { claudeCode = { toolName = "Task" } },
      rawInput = {},
    }
    transform(u)
    h.eq("Side quest", u.title)
  end)
end)

h.describe("claude-code goal snapshot extraction", function()
  local from = CC._goal_from_update

  h.it("reads _meta.goal off a session_info_update", function()
    local goal = from({
      sessionUpdate = "session_info_update",
      _meta = { goal = { objective = "ship it", status = "active" } },
    })
    h.eq("ship it", goal.objective)
    h.eq("active", goal.status)
  end)

  h.it("ignores other update types carrying a goal-shaped _meta", function()
    h.is_nil(from({
      sessionUpdate = "agent_message_chunk",
      _meta = { goal = { objective = "x", status = "active" } },
    }))
  end)

  h.it("ignores a session_info_update with no goal", function()
    h.is_nil(from({ sessionUpdate = "session_info_update", title = "renamed" }))
    h.is_nil(from({ sessionUpdate = "session_info_update", _meta = {} }))
  end)

  h.it("treats a JSON-null goal as absent", function()
    -- A cleared goal arrives as an explicit null, not a missing key.
    h.is_nil(from({ sessionUpdate = "session_info_update", _meta = { goal = vim.NIL } }))
  end)

  h.it("tolerates malformed input", function()
    h.is_nil(from(nil))
    h.is_nil(from({ sessionUpdate = "session_info_update", _meta = vim.NIL }))
  end)
end)

h.describe("claude-code goal termination", function()
  local over = CC._goal_is_over

  h.it("is over when complete", function()
    h.is_true(over({ objective = "ship it", status = "complete" }))
  end)

  h.it("is over when the objective is gone", function()
    h.is_true(over({ status = "active" }))
    h.is_true(over({ objective = "", status = "active" }))
  end)

  h.it("is not over while the agent is still working or stuck", function()
    for _, status in ipairs({ "active", "paused", "blocked", "limited" }) do
      h.eq(false, over({ objective = "ship it", status = status }), status .. " is still a live goal")
    end
  end)
end)

h.describe("claude-code goal rendering", function()
  local Winbar = require("emeth.ui.winbar")

  --- Fake session + view, with the winbar badge calls recorded.
  local function goal_setup()
    local listeners = {}
    local session = {
      on = function(_, _event, fn)
        listeners[#listeners + 1] = fn
      end,
      off = function(_, _event, fn)
        for i = #listeners, 1, -1 do
          if listeners[i] == fn then
            table.remove(listeners, i)
          end
        end
      end,
    }
    local view = { messages = {} }
    function view:add_message(m)
      table.insert(self.messages, m)
    end

    local badges = {}
    local set, clear = Winbar.set_badge, Winbar.clear_badge
    Winbar.set_badge = function(k, v)
      badges[k] = v
    end
    Winbar.clear_badge = function(k)
      badges[k] = nil
    end

    local cleanup = CC._attach_goal(session, view)
    local function emit(goal)
      for _, fn in ipairs(listeners) do
        fn({ sessionUpdate = "session_info_update", _meta = { goal = goal } })
      end
      vim.wait(20)
    end
    local function restore()
      Winbar.set_badge, Winbar.clear_badge = set, clear
    end
    return view, badges, emit, cleanup, restore
  end

  local function texts(view)
    local out = {}
    for _, m in ipairs(view.messages) do
      out[#out + 1] = m:text()
    end
    return out
  end

  h.it("announces a new goal and shows its status in the winbar", function()
    local view, badges, emit, _, restore = goal_setup()
    emit({ objective = "ship elicitation", status = "active" })
    h.eq({ "🎯 Goal: ship elicitation" }, texts(view))
    h.eq("🎯 active", badges.goal)
    restore()
  end)

  -- Snapshots repeat on every session_info_update, so an unchanged one must not
  -- add another transcript line.
  h.it("stays quiet when the same snapshot repeats", function()
    local view, _, emit, _, restore = goal_setup()
    emit({ objective = "ship it", status = "active" })
    emit({ objective = "ship it", status = "active" })
    emit({ objective = "ship it", status = "active" })
    h.eq(1, #view.messages)
    restore()
  end)

  h.it("reports a blocked goal with its reason", function()
    local view, badges, emit, _, restore = goal_setup()
    emit({ objective = "ship it", status = "active" })
    emit({ objective = "ship it", status = "blocked", lastReason = "needs credentials" })
    h.eq(2, #view.messages)
    h.is_true(view.messages[2]:text():find("blocked", 1, true) ~= nil)
    h.is_true(view.messages[2]:text():find("needs credentials", 1, true) ~= nil)
    h.eq("🎯 blocked", badges.goal)
    restore()
  end)

  h.it("does not announce a status change that carries no signal", function()
    local view, _, emit, _, restore = goal_setup()
    emit({ objective = "ship it", status = "blocked" })
    -- active is the normal working state; going back to it is not news.
    emit({ objective = "ship it", status = "active" })
    h.eq(1, #view.messages)
    restore()
  end)

  h.it("announces a new objective when the goal is replaced", function()
    local view, _, emit, _, restore = goal_setup()
    emit({ objective = "first goal", status = "active" })
    emit({ objective = "second goal", status = "active" })
    h.eq({ "🎯 Goal: first goal", "🎯 Goal: second goal" }, texts(view))
    restore()
  end)

  h.it("clears the badge and names the finished goal on completion", function()
    local view, badges, emit, _, restore = goal_setup()
    emit({ objective = "ship it", status = "active" })
    emit({ objective = "ship it", status = "complete" })
    h.eq("🎯 Goal complete: ship it", view.messages[2]:text())
    h.is_nil(badges.goal)
    restore()
  end)

  h.it("shows the iteration count once the agent has looped", function()
    local _, badges, emit, _, restore = goal_setup()
    emit({ objective = "ship it", status = "active", iterations = 3 })
    h.eq("🎯 active ×3", badges.goal)
    restore()
  end)

  h.it("stops listening and drops the badge on cleanup", function()
    local view, badges, emit, cleanup, restore = goal_setup()
    emit({ objective = "ship it", status = "active" })
    cleanup()
    h.is_nil(badges.goal)
    emit({ objective = "another", status = "active" })
    h.eq(1, #view.messages, "no updates after cleanup")
    restore()
  end)
end)
