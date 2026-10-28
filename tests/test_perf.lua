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

h.describe("perf: subagent activity leaves the transcript around its card alone", function()
  -- A subagent card sits at its spawn point, mid-transcript, while the main
  -- session keeps writing below it. Rewriting buffer rows strips every extmark on
  -- them -- render-markdown's decorations included -- even when the new text is
  -- byte-identical, so the text below the card flipped between formatted and raw
  -- for as long as a subagent ran. These count rows written, at two tail sizes:
  -- the work must be what the update changed, not how much was said since.

  h.it("a hidden child's update writes no rows and renders nothing", function()
    for _, tail in ipairs({ SMALL, LARGE }) do
      local s, run = bench.subagent_child_update_run(tail)
      local renders
      local writes = bench.count_buffer_writes(s.view.result_buf, function()
        renders = bench.count_render_calls(run)
      end)
      h.eq(
        0,
        writes.rows,
        string.format(
          "20 updates to hidden children wrote %d rows below a card with %d messages after it; "
            .. "expected 0 -- nothing on screen changed.",
          writes.rows,
          tail
        )
      )
      h.eq(
        0,
        renders,
        string.format("hidden-child updates re-rendered %d messages (tail=%d); expected 0", renders, tail)
      )
    end
  end)

  h.it("a new nested tool rewrites only the card's header row", function()
    for _, tail in ipairs({ SMALL, LARGE }) do
      local s, run = bench.subagent_spawn_run(tail)
      local writes = bench.count_buffer_writes(s.view.result_buf, run)
      h.eq(
        20,
        writes.rows,
        string.format(
          "20 new nested tools wrote %d rows with %d messages after the card; expected 20 "
            .. "(the '⊳ N tools' header, once each).",
          writes.rows,
          tail
        )
      )
    end
  end)

  h.it("a re-render that changes nothing writes nothing", function()
    local s = bench.subagent_scenario(SMALL)
    local writes = bench.count_buffer_writes(s.view.result_buf, function()
      s.view:invalidate()
      vim.wait(0)
    end)
    h.eq(0, writes.rows, string.format("an identical full re-render wrote %d rows; expected 0", writes.rows))
  end)

  h.it("decorations below the card survive subagent activity", function()
    -- What render-markdown does: a ranged extmark on a line well below the card.
    local s = bench.subagent_scenario(SMALL)
    local buf = s.view.result_buf
    local ns = vim.api.nvim_create_namespace("emeth_test_decor")
    local row = vim.api.nvim_buf_line_count(buf) - 5
    local id = vim.api.nvim_buf_set_extmark(buf, ns, row, 0, { end_row = row, end_col = 4 })
    local before = vim.api.nvim_buf_get_extmark_by_id(buf, ns, id, { details = true })
    s.update(s.children[1], 1)
    vim.wait(0)
    s.spawn()
    vim.wait(0)
    local after = vim.api.nvim_buf_get_extmark_by_id(buf, ns, id, { details = true })
    h.eq(before[1], after[1], "decoration moved off its row")
    h.eq(before[2], after[2], "decoration moved off its column")
    h.eq(before[3].end_row, after[3].end_row, "decoration's range collapsed (end_row)")
    h.eq(before[3].end_col, after[3].end_col, "decoration's range collapsed (end_col)")
    vim.api.nvim_buf_clear_namespace(buf, ns, 0, -1)
  end)
end)
