local h = require("tests.helpers")
local CC = require("emeth.integrations.claude-code")

h.describe("claude-code format_mode", function()
  h.it("returns nil for nil input", function()
    h.is_nil(CC.format_mode(nil))
  end)

  h.it("returns nil for empty string", function()
    h.is_nil(CC.format_mode(""))
  end)

  h.it("default has badge but no tag (normal mode)", function()
    local desc = CC.format_mode("default")
    h.eq("⚙ ask", desc.badge)
    h.is_nil(desc.tag)
    h.is_nil(desc.tag_kind)
  end)

  h.it("auto has badge but no tag (normal mode)", function()
    local desc = CC.format_mode("auto")
    h.eq("⚙ auto", desc.badge)
    h.is_nil(desc.tag)
  end)

  h.it("plan emits badge + tag with info kind", function()
    local desc = CC.format_mode("plan")
    h.eq("⚙ plan", desc.badge)
    h.eq("plan", desc.tag)
    h.eq("info", desc.tag_kind)
  end)

  h.it("acceptEdits maps label to auto-edit with info kind", function()
    local desc = CC.format_mode("acceptEdits")
    h.eq("⚙ auto-edit", desc.badge)
    h.eq("auto-edit", desc.tag)
    h.eq("info", desc.tag_kind)
  end)

  h.it("dontAsk uses warn kind", function()
    local desc = CC.format_mode("dontAsk")
    h.eq("⚙ deny-default", desc.badge)
    h.eq("deny-default", desc.tag)
    h.eq("warn", desc.tag_kind)
  end)

  h.it("bypassPermissions uses error kind", function()
    local desc = CC.format_mode("bypassPermissions")
    h.eq("⚙ bypass", desc.badge)
    h.eq("bypass", desc.tag)
    h.eq("error", desc.tag_kind)
  end)

  h.it("falls back to raw mode_id with hint kind for unknown modes", function()
    local desc = CC.format_mode("customMode")
    h.eq("⚙ customMode", desc.badge)
    h.eq("customMode", desc.tag)
    h.eq("hint", desc.tag_kind)
  end)

  h.it("badge label has no leading icon when caller wants raw text", function()
    -- Tags never include an icon — generic acp.lua uses them verbatim
    -- without any post-processing. Verify by checking the plan label.
    local desc = CC.format_mode("plan")
    h.is_nil(desc.tag:find("⚙"))
  end)
end)

h.describe("claude-code build_session_meta", function()
  h.it("returns nil when claude_code config missing", function()
    h.is_nil(CC.build_session_meta({}))
  end)

  h.it("returns nil when extra_args is nil", function()
    h.is_nil(CC.build_session_meta({ claude_code = {} }))
  end)

  h.it("returns nil when extra_args is an empty table", function()
    h.is_nil(CC.build_session_meta({ claude_code = { extra_args = {} } }))
  end)

  h.it("returns nil when extra_args is the wrong type", function()
    h.is_nil(CC.build_session_meta({ claude_code = { extra_args = "agent=foo" } }))
  end)

  h.it("wraps extra_args in claudeCode.options.extraArgs envelope", function()
    local meta = CC.build_session_meta({
      claude_code = { extra_args = { agent = "flax-kitchen", verbose = true } },
    })
    h.eq({
      claudeCode = {
        options = {
          extraArgs = { agent = "flax-kitchen", verbose = true },
        },
      },
    }, meta)
  end)

  h.it("deep-copies extra_args so caller mutation does not leak", function()
    local args = { agent = "a" }
    local meta = CC.build_session_meta({ claude_code = { extra_args = args } })
    args.agent = "b"
    h.eq("a", meta.claudeCode.options.extraArgs.agent)
  end)
end)

h.describe("claude-code extract_session_info", function()
  -- extract_session_info schedules a winbar update; suppress to keep tests
  -- focused on the extension-side state mutation.
  local function noop_schedule(fn)
    return fn
  end
  local orig_schedule = vim.schedule
  vim.schedule = noop_schedule

  h.it("populates model_id and mode_id from configOptions", function()
    local exts = {}
    CC.extract_session_info({
      configOptions = {
        { id = "model", currentValue = "claude-opus-4-7" },
        { id = "mode", currentValue = "plan" },
        { id = "effort", currentValue = "high" }, -- ignored
      },
    }, exts)
    h.eq("claude-opus-4-7", exts.model_id)
    h.eq("plan", exts.mode_id)
  end)

  h.it("ignores configOptions entries with non-string currentValue", function()
    local exts = {}
    CC.extract_session_info({
      configOptions = {
        { id = "model", currentValue = nil },
        { id = "mode", currentValue = 42 },
      },
    }, exts)
    h.is_nil(exts.model_id)
    h.is_nil(exts.mode_id)
  end)

  h.it("is a no-op when result has no configOptions", function()
    local exts = { existing = "kept" }
    CC.extract_session_info({}, exts)
    h.eq("kept", exts.existing)
    h.is_nil(exts.model_id)
  end)

  vim.schedule = orig_schedule
end)
