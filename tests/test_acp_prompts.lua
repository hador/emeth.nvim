--- Transient inline prompt tests: tool permissions and agent elicitations,
--- both driven by `emeth.ui.prompt_queue`. Covers queueing, key claims, and
--- the free-text answer path through the input box.

local h = require("tests.helpers")
local H = require("tests.acp_harness")
local make_setup = H.setup
local flush = H.flush
local press_on = H.press_on

-- Global stubs; released at the bottom of this file.
local restore = H.install()

h.describe("acp integration: permission queue", function()
  -- Build a session whose request_permission round-trips through the integration
  -- like the real client: each call records the chosen optionId.
  local function perm_setup()
    local session, view = make_setup()
    local resolved = {} ---@type table[]
    --- Mimic a permission request arriving from the agent.
    local function request(tool_call, options)
      session:_emit("permission", tool_call, options, function(option_id)
        resolved[#resolved + 1] = { id = tool_call.toolCallId, option = option_id }
      end)
    end
    return session, view, resolved, request
  end

  local OPTS = {
    { kind = "allow_once", name = "Yes", optionId = "allow_once" },
    { kind = "reject_once", name = "No", optionId = "reject_once" },
  }

  h.it("resolves a single request when its key is pressed", function()
    local _, view, resolved, request = perm_setup()
    request({ toolCallId = "t1", title = "Read a.lua" }, OPTS)
    flush()
    h.is_true(press_on(view, "a"), "allow key should be bound")
    h.eq(1, #resolved)
    h.eq("t1", resolved[1].id)
    h.eq("allow_once", resolved[1].option)
  end)

  h.it("serializes concurrent requests: answering the head activates the next", function()
    local _, view, resolved, request = perm_setup()
    -- Two requests arrive before the user answers either.
    request({ toolCallId = "t1", title = "Read a.lua" }, OPTS)
    request({ toolCallId = "t2", title = "Read b.lua" }, OPTS)
    flush()

    -- Only the head (t1) is answerable right now.
    h.is_true(press_on(view, "a"), "head keymap bound")
    h.eq(1, #resolved)
    h.eq("t1", resolved[1].id)
    h.eq("allow_once", resolved[1].option)

    -- The second request is now active; the same key resolves it (no collision).
    h.is_true(press_on(view, "r"), "next keymap rebound after head resolved")
    h.eq(2, #resolved)
    h.eq("t2", resolved[2].id)
    h.eq("reject_once", resolved[2].option)
  end)

  h.it("shows pending count on the active prompt when a request queues behind it", function()
    local _, view, _, request = perm_setup()
    request({ toolCallId = "t1", title = "Read a.lua" }, OPTS)
    flush()
    -- Head prompt is the last message; no pending line yet.
    local head = view.messages[#view.messages]
    h.is_true(head:text():find("more pending") == nil, "no pending line with one request")

    -- A second request arrives behind it — head prompt should now show it.
    request({ toolCallId = "t2", title = "Read b.lua" }, OPTS)
    flush()
    h.is_true(head:text():find("1 more pending") ~= nil, "head prompt should report 1 pending")
  end)

  -- Regression: the claims have to go when the queue empties, not just get
  -- replaced by the next request's. A lingering claim leaves the key hijacked by
  -- an already-answered prompt, so `r` would never fall through to retry again.
  h.it("releases its key claims once the last request is answered", function()
    local _, view, resolved, request = perm_setup()
    request({ toolCallId = "t1", title = "Read a.lua" }, OPTS)
    flush()
    h.is_true(press_on(view, "a"), "allow key claimed while pending")
    h.eq(1, #resolved)

    h.eq(false, press_on(view, "a"), "claim should be released after answering")
    h.eq(false, press_on(view, "r"), "no reject claim should linger either")
    h.eq(1, #resolved, "a released key must not resolve anything a second time")
  end)

  h.it("preserves FIFO order across three requests", function()
    local _, view, resolved, request = perm_setup()
    request({ toolCallId = "t1" }, OPTS)
    request({ toolCallId = "t2" }, OPTS)
    request({ toolCallId = "t3" }, OPTS)
    flush()
    press_on(view, "a")
    press_on(view, "a")
    press_on(view, "a")
    h.eq(3, #resolved)
    h.eq("t1", resolved[1].id)
    h.eq("t2", resolved[2].id)
    h.eq("t3", resolved[3].id)
  end)
end)

h.describe("acp integration: elicitation", function()
  --- Emit an elicitation the way the session layer does and capture the reply.
  local function elicit_setup()
    local session, view = make_setup()
    local replies = {} ---@type table[]
    ---@param schema table
    local function ask(schema, message)
      session:_emit("elicitation", {
        mode = "form",
        message = message or "Pick one",
        requestedSchema = schema,
      }, function(response)
        replies[#replies + 1] = response
      end)
    end
    return session, view, replies, ask
  end

  local TWO_OPTIONS = {
    type = "object",
    properties = {
      choice = {
        type = "string",
        oneOf = {
          { const = "a", title = "Option A", description = "first" },
          { const = "b", title = "Option B", description = "second" },
        },
      },
    },
  }

  --- Rendered layout for a single 2-option select:
  ---   1 header, 2 option A, 3 option B, 4 skip, 5 hint
  local ROW_A, ROW_B, ROW_SKIP = 2, 3, 4

  h.it("accepts the option under the cursor", function()
    local _, view, replies, ask = elicit_setup()
    ask(TWO_OPTIONS)
    flush()
    view._cursor_offset = ROW_B
    h.is_true(press_on(view, "<CR>"), "<CR> should be bound while a question is open")
    h.eq(1, #replies)
    h.eq("accept", replies[1].action)
    h.eq({ choice = "b" }, replies[1].content)
  end)

  -- The prompt and the winbar badge are both off-screen with the sidebar closed,
  -- and the agent stays blocked until the question is answered — so that case is
  -- the one place an elicitation has to reach outside the transcript.
  h.it("nudges out of band when the sidebar is closed", function()
    local _, view, _, ask = elicit_setup()
    local notes = {}
    local restore = vim.notify
    vim.notify = function(msg)
      notes[#notes + 1] = msg
    end

    view._visible = false
    ask(TWO_OPTIONS)
    flush()
    vim.notify = restore

    h.eq(1, #notes, "a blocked question behind a closed sidebar should notify")
    h.is_true(notes[1]:find(":Emeth") ~= nil, "the nudge should say how to get to it")
  end)

  h.it("stays quiet when the sidebar is already showing", function()
    local _, view, _, ask = elicit_setup()
    local notes = {}
    local restore = vim.notify
    vim.notify = function(msg)
      notes[#notes + 1] = msg
    end

    view._visible = true
    ask(TWO_OPTIONS)
    flush()
    vim.notify = restore

    h.eq(0, #notes, "the inline prompt is visible; no nudge needed")
  end)

  -- Regression: <CR> is the confirm key the view owns permanently. A claim left
  -- behind by an answered question would swallow it, costing <CR> its normal
  -- line-down motion in the transcript.
  h.it("releases the <CR> claim once the question is answered", function()
    local _, view, replies, ask = elicit_setup()
    ask(TWO_OPTIONS)
    flush()
    view._cursor_offset = ROW_B
    h.is_true(press_on(view, "<CR>"), "<CR> claimed while the question is open")
    h.eq(1, #replies)

    h.eq(false, press_on(view, "<CR>"), "claim should be released after answering")
    h.eq(1, #replies, "a released <CR> must not answer a second time")
  end)

  h.it("declines when the skip line is chosen", function()
    local _, view, replies, ask = elicit_setup()
    ask(TWO_OPTIONS)
    flush()
    view._cursor_offset = ROW_SKIP
    press_on(view, "<CR>")
    h.eq("decline", replies[1].action)
    h.is_nil(replies[1].content)
  end)

  h.it("ignores <CR> on a line with no action", function()
    local _, view, replies, ask = elicit_setup()
    ask(TWO_OPTIONS)
    flush()
    view._cursor_offset = 1 -- the header
    press_on(view, "<CR>")
    h.eq(0, #replies, "the question must stay open")
  end)

  h.it("declines a schema with nothing renderable instead of showing a dead prompt", function()
    local _, _, replies, ask = elicit_setup()
    ask({ type = "object", properties = { odd = { type = "_customThing" } } })
    flush()
    h.eq(1, #replies)
    h.eq("decline", replies[1].action)
  end)

  h.it("serializes concurrent questions and answers them in order", function()
    local _, view, replies, ask = elicit_setup()
    ask(TWO_OPTIONS, "first question")
    ask(TWO_OPTIONS, "second question")
    flush()
    -- The head prompt reports the one waiting behind it, which shifts its rows
    -- down by one (header, pending, optA, optB, skip, hint).
    local head = view.messages[#view.messages]
    h.is_true(head:text():find("1 more waiting") ~= nil, "head should report the queued question")

    view._cursor_msg = head
    view._cursor_offset = ROW_A + 1
    press_on(view, "<CR>")
    h.eq(1, #replies)
    h.eq({ choice = "a" }, replies[1].content)

    -- The second question is now active with no pending line, so rows shift back.
    view._cursor_msg = nil
    view._cursor_offset = ROW_B
    h.is_true(press_on(view, "<CR>"), "<CR> should be rebound for the next question")
    h.eq(2, #replies)
    h.eq({ choice = "b" }, replies[2].content)
  end)

  h.it("toggles multi-select entries and submits them together", function()
    local _, view, replies, ask = elicit_setup()
    ask({
      type = "object",
      properties = {
        feats = {
          type = "array",
          items = { anyOf = { { const = "x", title = "X" }, { const = "y", title = "Y" } } },
        },
      },
    })
    flush()
    -- Layout: 1 header, 2 X, 3 Y, 4 submit, 5 skip, 6 hint
    view._cursor_offset = 2
    press_on(view, "<CR>")
    h.eq(0, #replies, "toggling must not submit")
    view._cursor_offset = 3
    press_on(view, "<CR>")
    view._cursor_offset = 4 -- submit
    press_on(view, "<CR>")
    h.eq(1, #replies)
    h.eq("accept", replies[1].action)
    h.eq({ "x", "y" }, replies[1].content.feats)
  end)

  h.it("untoggles an entry that is selected twice", function()
    local _, view, replies, ask = elicit_setup()
    ask({
      type = "object",
      properties = {
        feats = { type = "array", items = { anyOf = { { const = "x", title = "X" } } } },
      },
    })
    flush()
    -- Layout: 1 header, 2 X, 3 submit, 4 skip, 5 hint
    view._cursor_offset = 2
    press_on(view, "<CR>")
    press_on(view, "<CR>") -- toggle back off
    view._cursor_offset = 3
    press_on(view, "<CR>")
    -- The field is optional, so submitting with nothing ticked is a real answer
    -- ("none of these") rather than a skip — but it must not send an empty list.
    h.eq("accept", replies[1].action)
    h.is_nil(replies[1].content.feats)
  end)

  h.it("walks a multi-field form one question at a time", function()
    local _, view, replies, ask = elicit_setup()
    ask({
      type = "object",
      properties = {
        -- Titles matter here: the per-field label line is only rendered when the
        -- field has a title or description of its own.
        question_0 = { type = "string", title = "First", oneOf = { { const = "a1", title = "A1" } } },
        question_1 = { type = "string", title = "Second", oneOf = { { const = "b1", title = "B1" } } },
      },
    })
    flush()
    -- Multi-field layout adds a per-field label line:
    --   1 header (n/2), 2 label, 3 option, 4 skip, 5 hint
    view._cursor_offset = 3
    press_on(view, "<CR>")
    h.eq(0, #replies, "answering the first field advances rather than submitting")
    view._cursor_offset = 3
    press_on(view, "<CR>")
    h.eq(1, #replies)
    h.eq({ question_0 = "a1", question_1 = "b1" }, replies[1].content)
  end)

  h.it("replaces the prompt with a record of the answer", function()
    local _, view, _, ask = elicit_setup()
    ask(TWO_OPTIONS, "Which one?")
    flush()
    local prompt = view.messages[#view.messages]
    view._cursor_offset = ROW_A
    press_on(view, "<CR>")
    local text = prompt:text()
    h.is_true(text:find("Which one?", 1, true) ~= nil, "keeps the question")
    h.is_true(text:find("Option A", 1, true) ~= nil, "records the chosen label, not the wire value")
    h.is_true(text:find("skip", 1, true) == nil, "no leftover live controls")
  end)

  h.it("K expands option descriptions in place", function()
    local _, view, _, ask = elicit_setup()
    ask(TWO_OPTIONS)
    flush()
    local prompt = view.messages[#view.messages]
    h.is_true(type(prompt.metadata.on_expand) == "function", "prompt must carry the K hook")
    prompt.metadata.on_expand(prompt)
    h.is_true(prompt:text():find("first", 1, true) ~= nil, "expanded shows full descriptions")
  end)

  h.it("cancels open questions when the turn is cancelled", function()
    local _, view, replies, ask = elicit_setup()
    ask(TWO_OPTIONS)
    ask(TWO_OPTIONS)
    flush()
    -- Ctrl-C path: the turn is going away, so the tool call should abort rather
    -- than proceed with no answer.
    view.integration.cancel()
    h.eq(2, #replies)
    h.eq("cancel", replies[1].action)
    h.eq("cancel", replies[2].action)
  end)
end)

h.describe("acp integration: elicitation free-text via the input box", function()
  local function elicit_setup()
    local session, view = make_setup()
    local replies = {}
    local function ask(schema, message)
      session:_emit("elicitation", {
        mode = "form",
        message = message or "Pick one",
        requestedSchema = schema,
      }, function(response)
        replies[#replies + 1] = response
      end)
    end
    return session, view, replies, ask
  end

  -- A select field whose provider-folded companion offers free text, which is
  -- the shape claude-acp sends for AskUserQuestion.
  local WITH_CUSTOM = {
    type = "object",
    properties = {
      colour = { type = "string", oneOf = { { const = "red", title = "Red" } } },
    },
  }

  --- Layout with one option: 1 header, 2 option, 3 type-your-own, 4 skip, 5 hint
  local ROW_OPTION, ROW_INPUT, ROW_SKIP = 2, 3, 4

  local function with_custom_field(session)
    -- Stand in for the claude transform folding a `_custom` companion in.
    session.client.agent_meta = nil
    return WITH_CUSTOM
  end

  h.it("claims the input box instead of opening a modal prompt", function()
    local session, view, _, ask = elicit_setup()
    -- vim.ui.input must not be used for this any more.
    local ui_input_calls = 0
    local orig = vim.ui.input
    vim.ui.input = function()
      ui_input_calls = ui_input_calls + 1
    end

    view.integration.set_transform_elicitation(function(fields)
      fields[1].custom_key = "colour_custom"
      return fields
    end)
    ask(with_custom_field(session))
    flush()
    view._cursor_offset = ROW_INPUT
    press_on(view, "<CR>")

    h.eq(0, ui_input_calls, "no modal prompt")
    h.eq(1, view.focus_input_count, "focus moves to the input box")
    vim.ui.input = orig
  end)

  h.it("routes the next submission to the answer, not the agent", function()
    local session, view, replies, ask = elicit_setup()
    local prompts = {}
    session.client.send_prompt = function(_, _sid, prompt)
      prompts[#prompts + 1] = prompt
    end
    view.integration.set_transform_elicitation(function(fields)
      fields[1].custom_key = "colour_custom"
      return fields
    end)
    ask(with_custom_field(session))
    flush()
    view._cursor_offset = ROW_INPUT
    press_on(view, "<CR>")

    view.on_submit("chartreuse")
    h.eq(0, #prompts, "the text must not be sent as a prompt")
    h.eq(1, #replies)
    h.eq("accept", replies[1].action)
    h.eq("chartreuse", replies[1].content.colour_custom)
  end)

  h.it("shows in the prompt that the input box is claimed", function()
    local session, view, _, ask = elicit_setup()
    view.integration.set_transform_elicitation(function(fields)
      fields[1].custom_key = "colour_custom"
      return fields
    end)
    ask(with_custom_field(session))
    flush()
    local prompt = view.messages[#view.messages]
    h.is_true(prompt:text():find("type your own", 1, true) ~= nil)
    view._cursor_offset = ROW_INPUT
    press_on(view, "<CR>")
    h.is_true(prompt:text():find("input box below", 1, true) ~= nil, "state must be visible")
  end)

  -- The escape hatch: an empty submission never reaches on_submit, so picking
  -- another row has to be what abandons a pending free-text answer.
  h.it("picking another option abandons the pending free-text answer", function()
    local session, view, replies, ask = elicit_setup()
    local prompts = {}
    session.client.send_prompt = function(_, _sid, prompt)
      prompts[#prompts + 1] = prompt
    end
    view.integration.set_transform_elicitation(function(fields)
      fields[1].custom_key = "colour_custom"
      return fields
    end)
    ask(with_custom_field(session))
    flush()
    view._cursor_offset = ROW_INPUT
    press_on(view, "<CR>")
    view._cursor_offset = ROW_OPTION
    press_on(view, "<CR>")
    h.eq("red", replies[1].content.colour)

    -- The input box must be the user's own again.
    view.on_submit("a normal message")
    h.eq(1, #prompts, "a later submission goes to the agent")
  end)

  h.it("does not leave the input box claimed after the prompt is skipped", function()
    local session, view, replies, ask = elicit_setup()
    local prompts = {}
    session.client.send_prompt = function(_, _sid, prompt)
      prompts[#prompts + 1] = prompt
    end
    view.integration.set_transform_elicitation(function(fields)
      fields[1].custom_key = "colour_custom"
      return fields
    end)
    ask(with_custom_field(session))
    flush()
    view._cursor_offset = ROW_INPUT
    press_on(view, "<CR>")
    view._cursor_offset = ROW_SKIP
    press_on(view, "<CR>")
    h.eq("decline", replies[1].action)
    view.on_submit("a normal message")
    h.eq(1, #prompts)
  end)

  h.it("does not leave the input box claimed after a cancel", function()
    local session, view, _, ask = elicit_setup()
    local prompts = {}
    session.client.send_prompt = function(_, _sid, prompt)
      prompts[#prompts + 1] = prompt
    end
    view.integration.set_transform_elicitation(function(fields)
      fields[1].custom_key = "colour_custom"
      return fields
    end)
    ask(with_custom_field(session))
    flush()
    view._cursor_offset = ROW_INPUT
    press_on(view, "<CR>")
    view.integration.cancel()
    view.on_submit("a normal message")
    h.eq(1, #prompts)
  end)

  h.it("keeps the question open when an empty answer arrives", function()
    local session, view, replies, ask = elicit_setup()
    view.integration.set_transform_elicitation(function(fields)
      fields[1].custom_key = "colour_custom"
      return fields
    end)
    ask(with_custom_field(session))
    flush()
    view._cursor_offset = ROW_INPUT
    press_on(view, "<CR>")
    view.on_submit("")
    h.eq(0, #replies, "an empty answer must not resolve the question")
  end)
end)

restore()
