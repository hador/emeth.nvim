--- Times in the transcript: message times (agent-supplied or arrival), when a message shows one
--- (emeth.ui.timestamps), and how the chat view paints them (right-aligned, day dividers).

local h = require("tests.helpers")
local H = require("tests.acp_harness")
local Message = require("emeth.message")
local Timestamps = require("emeth.ui.timestamps")
local api = vim.api

local restore = H.install()
-- Files run before this one call emeth.setup(), which resets the acp config the harness set up.
require("emeth.acp").config.providers.test = { command = "echo", args = {} }

-- 2026-11-17 14:32:00 local time, and helpers to build messages at a given minute offset.
local T0 = os.time({ year = 2026, month = 11, day = 17, hour = 14, min = 32, sec = 0 })
local function at(role, minutes, text, meta)
  local m = Message:new(role, text or role, meta)
  m:set_time(T0 + minutes * 60)
  return m
end
local CFG = { enabled = true, format = "%H:%M", day_format = "%a %d %b", gap_minutes = 5 }

h.describe("Message times", function()
  h.it("a new message has the creation time; set_time replaces it, nil makes it unknown", function()
    local m = Message:new("user", "hi")
    h.is_true(type(m.at) == "number" and math.abs(m.at - os.time()) <= 1)
    m:set_time(T0 + 0.9)
    h.eq(T0, m.at)
    h.eq(os.date("%Y-%m-%d %H:%M:%S", T0), m.timestamp)
    m:set_time(nil)
    h.eq(nil, m.at)
    h.eq("", m.timestamp)
  end)
end)

h.describe("emeth.ui.timestamps", function()
  h.it("an agent reply after your message shows its time; the next agent message in the turn does not", function()
    local user = at("user", 0)
    local reply = at("assistant", 1)
    local more = at("assistant", 2)
    h.eq({ right = "14:33" }, Timestamps.marks(reply, user, user.at, CFG))
    h.eq({}, Timestamps.marks(more, reply, reply.at, CFG))
  end)

  h.it("an agent message after a quiet gap shows its time (a pass, a worker report)", function()
    local before = at("assistant", 0)
    h.eq({ right = "14:37" }, Timestamps.marks(at("assistant", 5), before, before.at, CFG))
    h.eq({}, Timestamps.marks(at("assistant", 4), before, before.at, CFG), "under the gap")
  end)

  h.it(
    "a new day gets a divider (also the first timed message); unknown times, nested and system rows get nothing",
    function()
      local first = at("user", 0)
      h.eq({ day = os.date("%a %d %b", T0) }, Timestamps.marks(first, nil, nil, CFG))
      local next_day = at("user", 24 * 60)
      h.eq({ day = os.date("%a %d %b", T0 + 86400) }, Timestamps.marks(next_day, first, first.at, CFG))
      local unknown = Message:new("assistant", "x")
      unknown:set_time(nil)
      h.eq({}, Timestamps.marks(unknown, first, first.at, CFG))
      h.eq({}, Timestamps.marks(at("assistant", 9, "c", { parent_tool_call_id = "p" }), first, first.at, CFG))
      h.eq({}, Timestamps.marks(at("system", 9), first, first.at, CFG))
      h.eq({}, Timestamps.marks(at("assistant", 9), first, first.at, { enabled = false }))
    end
  )

  h.it("a user message's header shows its time, or nothing when unknown", function()
    local Render = require("emeth.ui.render")
    local function header(msg)
      for _, line in ipairs(Render.render_message(msg, {})) do
        local text = tostring(line)
        if text:find("hi", 1, true) == nil and text:match("%S") and not text:find("─", 1, true) then
          return text
        end
      end
    end
    h.eq("14:32 ", header(at("user", 0, "hi")))
    local unknown = Message:new("user", "hi")
    unknown:set_time(nil)
    h.eq(nil, header(unknown), "no header text at all")
  end)
end)

h.describe("acp integration: message times from updates", function()
  h.it("an update's timestamp (epoch ms) becomes its message's time; without one a live message has now", function()
    local session, view = H.setup()
    session:_emit("update", {
      sessionUpdate = "agent_message_chunk",
      content = { type = "text", text = "hello" },
      timestamp = T0 * 1000,
    })
    h.eq(T0, view.messages[1].at)
    session:_emit("update", { sessionUpdate = "user_message_chunk", content = { type = "text", text = "live" } })
    h.is_true(math.abs(view.messages[2].at - os.time()) <= 1)
  end)

  h.it("replayed history without times (a load) has no time, rather than the load's", function()
    local session, view, integration = H.setup()
    session.load = function(_, sid, _opts, cb)
      session:_emit("update", { sessionUpdate = "user_message_chunk", content = { type = "text", text = "old" } })
      session:_emit("update", {
        sessionUpdate = "agent_message_chunk",
        content = { type = "text", text = "stamped" },
        timestamp = T0 * 1000,
      })
      session.session_id, session._state = sid, "ready"
      cb(nil)
    end
    integration.load_session("other-sess")
    H.flush()
    local by_text = {}
    for _, m in ipairs(view.messages) do
      by_text[m:text()] = m
    end
    h.eq(nil, by_text.old.at)
    h.eq(T0, by_text.stamped.at)
    -- After the load, live updates take the arrival time again.
    session:_emit("update", { sessionUpdate = "user_message_chunk", content = { type = "text", text = "after" } })
    h.is_true(type(view.messages[#view.messages].at) == "number")
  end)
end)

h.describe("ChatView: times in the transcript", function()
  h.it("paints a right-aligned time on a reply that starts a turn and a divider for the day", function()
    local ChatView = require("emeth.ui.chat_view")
    local view = ChatView:new({ config = require("emeth").config })
    view:add_message(at("user", 0, "question"))
    view:add_message(at("assistant", 1, "answer"))
    view:add_message(at("assistant", 2, "more"))
    view:_render()
    local right, days = {}, {}
    for _, m in ipairs(api.nvim_buf_get_extmarks(view.result_buf, view._ns_id, 0, -1, { details = true })) do
      local d = m[4]
      if d.virt_text then
        right[#right + 1] = { row = m[2], text = d.virt_text[1][1] }
      end
      if d.virt_lines then
        days[#days + 1] = d.virt_lines[1][1][1]
      end
    end
    h.eq(1, #right, "only the reply that starts the turn")
    h.eq("14:33", right[1].text)
    h.eq("answer", api.nvim_buf_get_lines(view.result_buf, right[1].row, right[1].row + 1, false)[1])
    h.eq({ "── " .. os.date("%a %d %b", T0) .. " ──" }, days)
  end)
end)

restore()
