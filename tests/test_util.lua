local h = require("tests.helpers")
local util = require("emeth.util")

h.describe("Util", function()
  h.it("fmt_err with nil returns unknown error", function()
    h.eq("unknown error", util.fmt_err(nil))
  end)

  h.it("fmt_err with message only", function()
    h.eq("something broke", util.fmt_err({ message = "something broke" }))
  end)

  h.it("fmt_err with message and data", function()
    h.eq("fail: details here", util.fmt_err({ message = "fail", data = "details here" }))
  end)

  h.it("fmt_err with no message field", function()
    h.eq("unknown error", util.fmt_err({}))
  end)

  h.it("fmt_err with no message but data", function()
    h.eq("unknown error: extra", util.fmt_err({ data = "extra" }))
  end)

  h.it("fmt_err with table data containing details", function()
    h.eq(
      'Internal error: Invalid session identifier "abc"',
      util.fmt_err({ message = "Internal error", data = { details = 'Invalid session identifier "abc"' } })
    )
  end)
end)

h.describe("Util.debounce", function()
  h.it("coalesces a burst of calls into a single deferred run", function()
    local runs = 0
    local d = util.debounce(5, function()
      runs = runs + 1
    end)
    for _ = 1, 10 do
      d.call()
    end
    -- Nothing has fired yet (it runs on a later tick).
    h.eq(0, runs)
    vim.wait(50, function()
      return runs > 0
    end)
    h.eq(1, runs, "10 calls in one burst should collapse to a single run")
    d.close()
  end)

  h.it("re-arms for a second burst after firing", function()
    local runs = 0
    local d = util.debounce(5, function()
      runs = runs + 1
    end)
    d.call()
    vim.wait(50, function()
      return runs == 1
    end)
    d.call() -- new burst
    vim.wait(50, function()
      return runs == 2
    end)
    h.eq(2, runs, "a call after the first run should schedule a second run")
    d.close()
  end)

  h.it("close is idempotent and safe before any call", function()
    local d = util.debounce(5, function() end)
    d.close()
    d.close() -- must not error on an already-closed timer
  end)
end)
