--- Benchmark harness for emeth render hot paths.
---
--- Two consumers, with a deliberate split:
---   * `make bench` → runs every scenario and prints a WALL-CLOCK timing table
---     for humans. Timings are inherently machine- and load-dependent.
---   * tests/test_perf.lua → asserts the scaling invariants via WORK COUNTS
---     (how many times render_message runs), never timings. A count is
---     deterministic, so the guard can't flake -- unlike a ratio of two tiny
---     wall-clock samples, which sits at the timer-noise floor on a fast/loaded
---     CI runner and produces spurious ratios. The count IS the invariant we
---     care about: "streaming into the tail must not re-render the prefix."
---
--- The scenarios all drive a real ChatView against real buffers (headless nvim),
--- exercising `_render` exactly as the integration does during streaming.

local ChatView = require("emeth.ui.chat_view")
local Message = require("emeth.message")
local Render = require("emeth.ui.render")

local M = {}

-- ── work counting ──────────────────────────────────────────────
--- Count render_message invocations while running `fn`. render_message is the
--- per-message render cost, so its call count is a proxy for render work that
--- is independent of timer noise: a prefix rebuild / full re-render would call
--- it once per visible message per render, whereas the incremental path calls
--- it only for the dirty tail.
---@param fn fun()
---@return integer calls
function M.count_render_calls(fn)
  local calls = 0
  local orig = Render.render_message
  Render.render_message = function(...)
    calls = calls + 1
    return orig(...)
  end
  local ok, err = pcall(fn)
  Render.render_message = orig
  if not ok then
    error(err)
  end
  return calls
end

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
-- Each scenario exposes its work as a `*_run(prior)` closure driving the real
-- render path. `M.time` wraps it for wall-clock (make bench);
-- `M.count_render_calls` wraps it for the deterministic guard (test_perf).

local STREAM_CHUNKS = 50
local APPEND_COUNT = 20

--- Returns a closure that streams STREAM_CHUNKS chunks into the tail message of
--- a session already holding `prior` messages. The invariant: work here must be
--- O(tail) -- i.e. render_message runs once per chunk (STREAM_CHUNKS total),
--- independent of `prior`. A prefix rebuild would make it scale with `prior`.
---@param prior integer
---@return fun() run
function M.stream_run(prior)
  local v = fresh_view()
  seed(v, prior)
  local live = Message:new("assistant", "")
  v:add_message(live)
  v:_render()
  local uuid = live.uuid
  return function()
    for _ = 1, STREAM_CHUNKS do
      v:update_message(uuid, function(m)
        m:append_text("token ")
      end)
      v:_render()
    end
  end
end

--- Returns a closure that appends APPEND_COUNT new messages to a session
--- holding `prior` messages. Work must be O(new): render_message runs once per
--- appended message (APPEND_COUNT total), independent of `prior`.
---@param prior integer
---@return fun() run
function M.append_run(prior)
  local v = fresh_view()
  seed(v, prior)
  return function()
    for _ = 1, APPEND_COUNT do
      v:add_message(Message:new("assistant", PARAGRAPH))
      v:_render()
    end
  end
end

--- Wall-clock cost of streaming STREAM_CHUNKS chunks into the tail (make bench).
---@param prior integer
---@return number ms
function M.stream_chunk_cost(prior)
  return M.time(M.stream_run(prior))
end

--- Wall-clock cost of appending APPEND_COUNT messages (make bench).
---@param prior integer
---@return number ms
function M.append_cost(prior)
  return M.time(M.append_run(prior))
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

--- A streaming tool whose body grows to `n_lines`, one chunk per line. Returns
--- the view (so callers can inspect final buffer line count) and a run closure.
---
--- `coalesce` nil: render every chunk (what happens without the throttle).
--- `coalesce` N:   apply chunks deferred, paint once per N (models the acp
---                 integration's render throttle deterministically -- no timer,
---                 so the bench stays time-independent).
---@param n_lines integer
---@param expanded boolean  true forces the heavy body path (K'd open mid-stream)
---@param coalesce? integer  paint once per this many chunks (nil = every chunk)
---@return chat_ui.ChatView view, fun() run
function M.tool_growth_scenario(n_lines, expanded, coalesce)
  local v = fresh_view()
  local msg = Message:new("assistant", {
    { type = "tool_use", id = "t1", name = "Bash", input = {}, status = "in_progress" },
  })
  msg.metadata.tool_call = { content = { { type = "content", content = { text = "" } } }, status = "in_progress" }
  msg.metadata._expanded = expanded
  v:add_message(msg)
  local uuid = msg.uuid
  local chunk = string.rep("x", 40)
  local run = function()
    local acc = {}
    for i = 1, n_lines do
      acc[i] = "  line_" .. i .. "  |  " .. chunk
      local text = table.concat(acc, "\n")
      local defer = coalesce ~= nil
      v:update_message(uuid, function(m)
        m.metadata.tool_call.content = { { type = "content", content = { text = text } } }
      end, { defer_render = defer })
      if coalesce and i % coalesce == 0 then
        v:flush()
        v:_render()
      elseif not coalesce then
        v:_render()
      end
    end
    if coalesce then
      v:flush()
      v:_render()
    end
  end
  return v, run
end

--- Wall-clock cost of a growing tool body (make bench).
--- expanded=false (DEFAULT) is the collapsed path -- a single header line
--- regardless of body size, so O(N). expanded=true re-renders the whole growing
--- body per chunk -- O(N^2); only reachable when a tool is K'd open mid-stream.
---@param n_lines integer
---@param expanded? boolean
---@return number ms_total
function M.streaming_tool_growth(n_lines, expanded)
  local _, run = M.tool_growth_scenario(n_lines, expanded or false, nil)
  return M.time(run, 3)
end

--- Wall-clock cost of the same body with the render throttle modeled (make bench).
---@param n_lines integer
---@param coalesce integer
---@return number ms_total
function M.streaming_tool_growth_throttled(n_lines, coalesce)
  local _, run = M.tool_growth_scenario(n_lines, true, coalesce)
  return M.time(run, 3)
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
