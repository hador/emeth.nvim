local h = require("tests.helpers")
local util = require("emeth.util")

h.describe("Util", function()
  h.it("fmt_err with nil returns unknown error", function()
    h.eq("unknown error", util.fmt_err(nil))
  end)

  h.it("fmt_err passes a bare string through", function()
    h.eq("socket closed", util.fmt_err("socket closed"))
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

h.describe("util.fmt_size", function()
  h.it("picks B / KB / MB", function()
    h.eq("812 B", util.fmt_size(812))
    h.eq("4.0 KB", util.fmt_size(4096))
    h.eq("1.5 MB", util.fmt_size(1572864))
  end)
end)

h.describe("util.blend", function()
  h.it("interpolates between two colours", function()
    h.eq("#000000", util.blend("#000000", "#ffffff", 0))
    h.eq("#ffffff", util.blend("#000000", "#ffffff", 1))
    h.eq("#7f7f7f", util.blend("#000000", "#ffffff", 0.5))
  end)
  h.it("reads a malformed component as 0 instead of erroring", function()
    h.eq("#000000", util.blend("bogus", "#000000", 0.5))
  end)
end)

h.describe("util.read_json", function()
  h.it("decodes a JSON file and is nil for a missing or malformed one", function()
    local path = vim.fn.tempname()
    vim.fn.writefile({ '{"a":1}' }, path)
    h.eq(1, util.read_json(path).a)
    vim.fn.writefile({ "not json" }, path)
    h.is_nil(util.read_json(path))
    vim.fn.delete(path)
    h.is_nil(util.read_json(path))
  end)
end)
