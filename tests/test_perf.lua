--- Performance guard tests.
---
--- These assert SCALING invariants via deterministic WORK COUNTS, never wall
--- clock. The invariant "streaming into the tail must not re-render the prefix"
--- is exactly "render_message runs a fixed number of times regardless of how
--- big the session already is" -- a count, which is machine-independent and
--- cannot flake. (An earlier version asserted a timing ratio; on a fast/loaded
--- CI runner the small measurement fell to the sub-millisecond timer-noise
--- floor and the ratio of two tiny samples spuriously tripped the threshold.
--- Wall-clock timings now live only in `make bench`, for humans.)
---
--- We measure at two session sizes (50 and 800 prior messages). An O(tail) path
--- yields an IDENTICAL count at both; an O(transcript) regression would scale
--- the count with the session size. We assert exact equality to the tail size.

local h = require("tests.helpers")
require("emeth").setup({})
local bench = require("tests.bench")

local SMALL, LARGE = 50, 800 -- 16x growth; a flat algorithm ignores the difference

h.describe("perf: render scaling stays flat as the session grows", function()
  h.it("streaming a chunk into the tail re-renders only the tail, not the prefix", function()
    -- 50 chunks streamed; each dirties only the tail message, so render_message
    -- runs exactly 50 times -- the same whether 50 or 800 messages precede it.
    local small = bench.count_render_calls(bench.stream_run(SMALL))
    local large = bench.count_render_calls(bench.stream_run(LARGE))
    h.eq(small, large) -- identical: work is independent of prior session size
    h.eq(
      large,
      50,
      string.format(
        "streaming 50 chunks re-rendered %d messages with %d in the transcript; "
          .. "expected 50 (tail only). A prefix rebuild or full re-render crept back in.",
        large,
        LARGE
      )
    )
  end)

  h.it("appending a message re-renders only the appended tail, not the prefix", function()
    -- 20 appends; each renders just the new message, so render_message runs
    -- exactly 20 times regardless of how many messages already exist.
    local small = bench.count_render_calls(bench.append_run(SMALL))
    local large = bench.count_render_calls(bench.append_run(LARGE))
    h.eq(small, large)
    h.eq(
      large,
      20,
      string.format(
        "appending 20 messages re-rendered %d with %d in the transcript; expected 20 (tail only).",
        large,
        LARGE
      )
    )
  end)
end)

h.describe("perf: a streaming tool body renders linearly (default collapsed)", function()
  -- A collapsed tool (the default until the user hits K) renders only its
  -- header, so its final buffer footprint is a fixed small number of lines no
  -- matter how large the body grew. Expanded, the footprint grows with the body.
  -- We assert the collapsed footprint is identical at 200 and 800 body lines --
  -- a deterministic count, so no timing and no flake.
  h.it("a collapsed tool's rendered footprint is independent of body size", function()
    local sv, srun = bench.tool_growth_scenario(200, false, nil)
    local lv, lrun = bench.tool_growth_scenario(800, false, nil)
    srun()
    lrun()
    local sl = vim.api.nvim_buf_line_count(sv.result_buf)
    local ll = vim.api.nvim_buf_line_count(lv.result_buf)
    h.eq(
      sl,
      ll,
      string.format(
        "collapsed tool rendered %d lines for a 200-line body but %d for an 800-line body; "
          .. "expected identical -- a collapsed tool must render only its header, not the body.",
        sl,
        ll
      )
    )
  end)

  -- The EXPANDED path (tool K'd open mid-stream) re-renders the whole growing
  -- body per chunk. The integration throttles it: chunks apply synchronously but
  -- paint at most once per interval. Modeling that coalescing, render_message
  -- must run far fewer times than one-per-chunk. This is a deterministic count:
  -- ~800 calls without the throttle vs ~1/coalesce of that with it. A regression
  -- that rendered every chunk again would push the throttled count back toward
  -- the per-chunk count and trip this.
  h.it("throttling an expanded streaming tool body coalesces renders", function()
    local _, every_run = bench.tool_growth_scenario(800, true, nil)
    local _, throttled_run = bench.tool_growth_scenario(800, true, 10)
    local every = bench.count_render_calls(every_run)
    local throttled = bench.count_render_calls(throttled_run)
    h.is_true(
      throttled * 3 < every,
      string.format(
        "throttled path made %d render_message calls vs %d per-chunk; expected the throttled "
          .. "count to be >3x smaller. The render throttle may be disconnected from defer_render/flush.",
        throttled,
        every
      )
    )
  end)
end)
