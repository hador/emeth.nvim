--- Benchmark harness for emeth render hot paths.
---
--- Two consumers:
---   * `make bench` → runs every scenario and prints a timing table (human use).
---   * tests/test_perf.lua → asserts the *scaling* invariants that guard against
---     re-introducing quadratic renders. We assert ratios, never absolute
---     milliseconds, so the checks are machine-independent and non-flaky.
---
--- The scenarios all drive a real ChatView against real buffers (headless nvim),
--- exercising `_render` exactly as the integration does during streaming.

local ChatView = require("emeth.ui.chat_view")
local Message = require("emeth.message")

local M = {}

-- ── timing ─────────────────────────────────────────────────────
--- Median wall-clock (ms) of `fn` over `reps` runs. Median, not mean, so a
--- one-off GC pause or scheduler hiccup doesn't skew the number.
---@param fn fun()
---@param reps? integer
---@return number ms
function M.time(fn, reps)
  reps = reps or 5
  local samples = {}
  for i = 1, reps do
    local t0 = vim.uv.hrtime()
    fn()
    samples[i] = (vim.uv.hrtime() - t0) / 1e6
  end
  table.sort(samples)
  return samples[math.ceil(#samples / 2)]
end

-- ── fixtures ───────────────────────────────────────────────────
local PARAGRAPH
do
  local body = {}
  for i = 1, 40 do
    body[i] = "line " .. i .. " of a fairly typical assistant paragraph blah blah"
  end
  PARAGRAPH = table.concat(body, "\n")
end

---A fresh view with a clean slate.
local function fresh_view()
  local v = ChatView:new({ config = require("emeth").config })
  v.messages = {}
  v._line_cache = {}
  v._dirty_from = nil
  v._line_to_msg = {}
  v._line_to_msg_max = nil
  return v
end

---Seed `n` finished assistant messages, warm the cache with one render.
---@param v chat_ui.ChatView
---@param n integer
local function seed(v, n)
  for _ = 1, n do
    v:add_message(Message:new("assistant", PARAGRAPH))
  end
  v:_render()
end

---A tool_use message whose result body is `n_lines` long.
---@param n_lines integer
---@return chat_ui.Message
local function tool_message(n_lines)
  local out = {}
  for i = 1, n_lines do
    out[i] = "  file_" .. i .. ".lua  |  " .. string.rep("x", 40)
  end
  local body = table.concat(out, "\n")
  local msg = Message:new("assistant", {
    { type = "tool_use", id = "t1", name = "Bash", input = { command = "ls -R" }, status = "completed" },
  })
  msg.metadata.tool_call = { content = { { type = "content", content = { text = body } } }, status = "completed" }
  msg.metadata._expanded = true -- force the heavy (expanded) body path
  return msg
end

-- ── scenarios ──────────────────────────────────────────────────
-- Each returns a numeric result the assertions can reason about.

--- Cost of one streaming chunk into the tail, as a function of prior session
--- size. The invariant: this must stay ~flat (O(tail), not O(transcript)).
---@param prior integer
---@return number ms_per_chunk
function M.stream_chunk_cost(prior)
  local v = fresh_view()
  seed(v, prior)
  local live = Message:new("assistant", "")
  v:add_message(live)
  local uuid = live.uuid
  return M.time(function()
    for _ = 1, 50 do
      v:update_message(uuid, function(m)
        m:append_text("token ")
      end)
      v:_render()
    end
  end)
end

--- Cost of appending a brand-new message, as a function of prior session size.
--- Also must stay ~flat.
---@param prior integer
---@return number ms_per_add
function M.append_cost(prior)
  local v = fresh_view()
  seed(v, prior)
  return M.time(function()
    for _ = 1, 20 do
      v:add_message(Message:new("assistant", PARAGRAPH))
      v:_render()
    end
  end)
end

--- Cost of a SINGLE render of one heavy (expanded) tool result of `n_lines`.
--- Expected to scale ~linearly with n_lines (inherent: N lines → N Line objects).
---@param n_lines integer
---@return number ms
function M.heavy_tool_render(n_lines)
  local v = fresh_view()
  v:add_message(tool_message(n_lines))
  return M.time(function()
    v:invalidate() -- force a full re-render of the heavy body
    v:_render()
  end)
end

--- Cost of a streaming tool whose body GROWS to `n_lines`, re-rendered on each
--- chunk (mirrors tool_call_update replacing full content).
---
--- `expanded=false` (the DEFAULT, and how tools render until the user hits K)
--- is linear: a collapsed tool renders a single header line regardless of body
--- size, so N chunks => O(N).
---
--- `expanded=true` exposes the O(body^2) path: each chunk re-renders the whole
--- growing body, so N chunks => O(N^2). Only reachable when a tool is expanded
--- WHILE still streaming (or on the diff-box path, which always renders body).
---@param n_lines integer
---@param expanded? boolean  default false (realistic collapsed path)
---@return number ms_total
function M.streaming_tool_growth(n_lines, expanded)
  local v = fresh_view()
  local msg = Message:new("assistant", {
    { type = "tool_use", id = "t1", name = "Bash", input = {}, status = "in_progress" },
  })
  msg.metadata.tool_call = { content = { { type = "content", content = { text = "" } } }, status = "in_progress" }
  msg.metadata._expanded = expanded or false
  v:add_message(msg)
  local uuid = msg.uuid
  local chunk = string.rep("x", 40)
  return M.time(function()
    local acc = {}
    for i = 1, n_lines do
      acc[i] = "  line_" .. i .. "  |  " .. chunk
      local text = table.concat(acc, "\n")
      v:update_message(uuid, function(m)
        m.metadata.tool_call.content = { { type = "content", content = { text = text } } }
      end)
      v:_render()
    end
  end, 3)
end

--- Same growing expanded tool body, but with the integration's render throttle
--- modeled: chunks are applied with defer_render=true and painted only once per
--- `coalesce` chunks (the timer coalesces a burst into one render). This is what
--- the acp integration does via schedule_tool_render(); here we model the
--- coalescing deterministically so the bench is time-independent. Cost drops
--- from O(N^2) (render every chunk) to O(N^2 / coalesce) -- still the same shape,
--- but divided down by however many chunks land within one throttle interval,
--- which in practice makes it a non-issue at streaming rates.
---@param n_lines integer
---@param coalesce integer  chunks coalesced into one render (models the timer)
---@return number ms_total
function M.streaming_tool_growth_throttled(n_lines, coalesce)
  local v = fresh_view()
  local msg = Message:new("assistant", {
    { type = "tool_use", id = "t1", name = "Bash", input = {}, status = "in_progress" },
  })
  msg.metadata.tool_call = { content = { { type = "content", content = { text = "" } } }, status = "in_progress" }
  msg.metadata._expanded = true
  v:add_message(msg)
  local uuid = msg.uuid
  local chunk = string.rep("x", 40)
  return M.time(function()
    local acc = {}
    for i = 1, n_lines do
      acc[i] = "  line_" .. i .. "  |  " .. chunk
      local text = table.concat(acc, "\n")
      v:update_message(uuid, function(m)
        m.metadata.tool_call.content = { { type = "content", content = { text = text } } }
      end, { defer_render = true })
      if i % coalesce == 0 then
        v:flush()
        v:_render()
      end
    end
    v:flush()
    v:_render()
  end, 3)
end

-- ── runner (make bench) ────────────────────────────────────────
function M.run()
  print("emeth render benchmarks (median ms)\n")

  print("streaming chunk into tail — should be FLAT vs prior size:")
  for _, p in ipairs({ 0, 100, 400, 800 }) do
    print(string.format("  prior=%-5d  %7.3f ms / 50 chunks", p, M.stream_chunk_cost(p)))
  end

  print("\nappend new message — should be FLAT vs prior size:")
  for _, p in ipairs({ 0, 100, 400, 800 }) do
    print(string.format("  prior=%-5d  %7.3f ms / 20 adds", p, M.append_cost(p)))
  end

  print("\nheavy tool result, single render — LINEAR vs body size:")
  for _, n in ipairs({ 100, 400, 1600 }) do
    print(string.format("  lines=%-5d  %7.3f ms", n, M.heavy_tool_render(n)))
  end

  print("\nstreaming tool body growth (collapsed, DEFAULT) — should be LINEAR:")
  for _, n in ipairs({ 100, 400, 800 }) do
    print(string.format("  final_lines=%-5d  %7.3f ms total", n, M.streaming_tool_growth(n, false)))
  end

  print("\nstreaming tool body growth (expanded, render every chunk) — QUADRATIC:")
  for _, n in ipairs({ 100, 400, 800 }) do
    print(string.format("  final_lines=%-5d  %7.3f ms total", n, M.streaming_tool_growth(n, true)))
  end

  print("\nstreaming tool body growth (expanded, throttled ~1 render/10 chunks) — the fix:")
  for _, n in ipairs({ 100, 400, 800 }) do
    print(string.format("  final_lines=%-5d  %7.3f ms total", n, M.streaming_tool_growth_throttled(n, 10)))
  end
end

return M
