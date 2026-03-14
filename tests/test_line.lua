local h = require("tests.helpers")
local Line = require("emeth.ui.line")

h.describe("Line", function()
  h.it("tostring with single section", function()
    local l = Line:new({ { "hello" } })
    h.eq("hello", tostring(l))
  end)

  h.it("tostring concatenates multiple sections", function()
    local l = Line:new({ { "foo", "Hl1" }, { " bar", "Hl2" } })
    h.eq("foo bar", tostring(l))
  end)

  h.it("tostring with empty sections", function()
    local l = Line:new({})
    h.eq("", tostring(l))
  end)

  h.it("tostring ignores highlight info", function()
    local l = Line:new({ { "a", "SomeHl" }, { "b", nil }, { "c" } })
    h.eq("abc", tostring(l))
  end)

  h.it("new stores sections", function()
    local sections = { { "x", "Hl" } }
    local l = Line:new(sections)
    h.eq(1, #l.sections)
    h.eq("x", l.sections[1][1])
  end)
end)
