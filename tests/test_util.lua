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
