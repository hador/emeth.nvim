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

h.describe("Winbar.set_mode_tag", function()
  -- Mode tag state is module-level. Each test must clear it after.
  local function reset()
    Winbar.clear_mode_tag()
    Winbar.set_state("ready")
  end

  h.it("set_mode_tag with text and kind stores the tag", function()
    reset()
    -- Without an attached window, render() is a no-op for the bar but the
    -- internal state still updates. Re-setting an empty value should clear.
    Winbar.set_mode_tag("plan", "info")
    -- No public getter; verify clearing path doesn't error and that the
    -- combined cycle (set → clear) is symmetric.
    Winbar.clear_mode_tag()
  end)

  h.it("set_mode_tag with empty string clears the tag", function()
    reset()
    Winbar.set_mode_tag("plan", "info")
    Winbar.set_mode_tag("", "info") -- empty text should clear, not store
    Winbar.clear_mode_tag()
  end)

  h.it("set_mode_tag with nil clears the tag", function()
    reset()
    Winbar.set_mode_tag("plan", "info")
    Winbar.set_mode_tag(nil)
    Winbar.clear_mode_tag()
  end)

  h.it("detach clears the mode tag", function()
    reset()
    Winbar.set_mode_tag("bypass", "error")
    Winbar.detach()
    -- Setting again after detach should be safe
    Winbar.set_mode_tag("plan", "info")
    Winbar.clear_mode_tag()
  end)
end)

h.describe("Winbar badges", function()
  h.it("set_badge and get_badges roundtrip", function()
    Winbar.detach() -- start with clean state
    Winbar.set_badge("k1", "v1")
    Winbar.set_badge("k2", "v2")
    local badges = Winbar.get_badges()
    table.sort(badges)
    h.eq({ "v1", "v2" }, badges)
  end)

  h.it("clear_badge removes a single badge", function()
    Winbar.detach()
    Winbar.set_badge("a", "1")
    Winbar.set_badge("b", "2")
    Winbar.clear_badge("a")
    local badges = Winbar.get_badges()
    h.eq({ "2" }, badges)
    Winbar.detach()
  end)

  h.it("set_context updates ctx badge with formatted percentage", function()
    Winbar.detach()
    Winbar.set_context(42)
    local found = false
    for _, b in ipairs(Winbar.get_badges()) do
      if b == "ctx 42%" then
        found = true
      end
    end
    h.is_true(found, "expected 'ctx 42%' in badges, got: " .. vim.inspect(Winbar.get_badges()))
    h.eq(42, Winbar.get_context())
    Winbar.detach()
  end)
end)
