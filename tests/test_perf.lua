--- Performance guard tests.
---
--- These do NOT assert absolute timings (those are machine-dependent and
--- flaky). They assert SCALING invariants: the per-operation render cost must
--- stay roughly flat as the transcript grows. A regression that reintroduces an
--- O(transcript) or O(body^2) render shows up as a large ratio here.
---
--- Growth factor between the small and large fixtures is 16x (50 -> 800 prior
--- messages). Flat scaling keeps the ratio near 1; we allow up to 4x to absorb
--- CI noise, GC, and the small residual O(prior) prefix-count loop. A true
--- linear/quadratic regression would blow well past 16x.

local h = require("tests.helpers")
require("emeth").setup({})
local bench = require("tests.bench")

local SMALL, LARGE = 50, 800 -- 16x growth
local MAX_RATIO = 4.0

--- Median ratio over a few paired samples, so a single scheduler hiccup on the
--- large run doesn't fail the build. We take the best (min) ratio across reps:
--- if ANY rep shows flat scaling, the algorithm is flat and the others were
--- noise. A genuine regression is flat-slow on every rep and can't produce a
--- small ratio.
---@param fn fun(n: integer): number
---@return number ratio, number small_ms, number large_ms
local function scaling_ratio(fn)
  local best, bs, bl = math.huge, 0, 0
  for _ = 1, 3 do
    local small = fn(SMALL)
    local large = fn(LARGE)
    local r = large / math.max(small, 1e-6)
    if r < best then
      best, bs, bl = r, small, large
    end
  end
  return best, bs, bl
end

h.describe("perf: render scaling stays flat as the session grows", function()
  h.it("streaming a chunk into the tail is O(tail), not O(transcript)", function()
    local ratio, s, l = scaling_ratio(bench.stream_chunk_cost)
    h.is_true(
      ratio < MAX_RATIO,
      string.format(
        "streaming chunk cost scaled %.2fx over a 16x larger session (small=%.3fms large=%.3fms); "
          .. "expected < %.1fx. A prefix rebuild or full re-render likely crept back in.",
        ratio,
        s,
        l,
        MAX_RATIO
      )
    )
  end)

  h.it("appending a new message is O(new), not O(transcript)", function()
    local ratio, s, l = scaling_ratio(bench.append_cost)
    h.is_true(
      ratio < MAX_RATIO,
      string.format(
        "append cost scaled %.2fx over a 16x larger session (small=%.3fms large=%.3fms); expected < %.1fx.",
        ratio,
        s,
        l,
        MAX_RATIO
      )
    )
  end)
end)

h.describe("perf: a streaming tool body renders linearly (default collapsed)", function()
  -- A tool whose output streams in (tool_call_update replacing full content)
  -- renders collapsed by default -- a single header line regardless of body
  -- size -- so N chunks cost O(N). Growth factor here is 4x lines (200 -> 800);
  -- linear is ~4x, so we cap at 8x to absorb noise.
  h.it("total cost of a growing collapsed tool body scales ~linearly", function()
    local small = bench.streaming_tool_growth(200, false)
    local large = bench.streaming_tool_growth(800, false)
    local ratio = large / math.max(small, 1e-6)
    h.is_true(
      ratio < 8.0,
      string.format(
        "collapsed streaming tool body cost scaled %.2fx over 4x more lines (small=%.3fms large=%.3fms); "
          .. "expected < 8x. A collapsed tool should render only its header, independent of body size.",
        ratio,
        small,
        large
      )
    )
  end)

  -- The EXPANDED path (tool K'd open mid-stream) re-renders the whole growing
  -- body per chunk -- O(N^2). The integration throttles it: chunks are applied
  -- synchronously but painted at most once per interval. Modeling that
  -- coalescing must cut total render cost substantially vs painting every chunk.
  -- We require the throttled path to be at least 3x cheaper at 800 lines; in
  -- practice it is ~9x. This guards that the throttle stays wired to the
  -- deferred-render primitive (a regression that rendered every chunk again
  -- would collapse the ratio toward 1x and trip this).
  h.it("throttling an expanded streaming tool body beats rendering every chunk", function()
    local every_chunk = bench.streaming_tool_growth(800, true)
    local throttled = bench.streaming_tool_growth_throttled(800, 10)
    h.is_true(
      every_chunk / math.max(throttled, 1e-6) > 3.0,
      string.format(
        "throttled render (%.3fms) should be >3x cheaper than per-chunk render (%.3fms); "
          .. "the streaming render throttle may have become disconnected from defer_render/flush.",
        throttled,
        every_chunk
      )
    )
  end)
end)
