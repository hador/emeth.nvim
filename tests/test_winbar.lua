local h = require("tests.helpers")
local Winbar = require("emeth.ui.winbar")

h.describe("Winbar.fmt", function()
  h.it("gradient raw output escapes % for winbar", function()
    local raw, plain = Winbar.fmt.gradient(85)
    h.eq("85%", plain)
    -- raw must contain %% so winbar renders a literal %
    h.is_true(raw:find("85%%%%") ~= nil, "expected '85%%%%' in raw, got: " .. raw)
  end)

  h.it("plain returns raw and plain", function()
    local raw, plain = Winbar.fmt.plain("hello")
    h.eq("hello", plain)
    h.is_true(raw:find("hello") ~= nil)
    h.is_true(raw:find("%%#") ~= nil, "expected highlight escape in raw")
  end)

  h.it("badge wraps text in highlight group", function()
    local raw, plain = Winbar.fmt.badge("test", "DiagnosticInfo")
    h.eq("test", plain)
    h.eq("%#DiagnosticInfo#test", raw)
  end)
end)
