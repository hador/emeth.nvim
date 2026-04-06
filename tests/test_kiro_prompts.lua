local h = require("tests.helpers")
local build = require("emeth.integrations.kiro-cli").build_prompt_items

local function noop_on_select(fpath)
  return function() end
end

-- ── build_prompt_items ──────────────────────────────────────────

h.describe("build_prompt_items", function()
  h.it("server prompt with matching local file gets on_select and source=local", function()
    local server = { { label = "my-prompt", value = "my-prompt", serverName = "global" } }
    local local_files = { ["my-prompt"] = "/tmp/my-prompt.md" }
    local items = build(server, local_files, noop_on_select)
    h.eq(1, #items)
    h.eq("my-prompt", items[1].value)
    h.eq("local", items[1].source)
    h.is_true(items[1].on_select ~= nil, "should have on_select")
  end)

  h.it("server prompt without local file keeps server source and no on_select", function()
    local server = { { label = "mcp-prompt", value = "mcp-prompt", serverName = "builder-mcp", description = "desc" } }
    local items = build(server, {}, noop_on_select)
    h.eq(1, #items)
    h.eq("builder-mcp", items[1].source)
    h.eq("desc", items[1].description)
    h.is_nil(items[1].on_select)
  end)

  h.it("local-only file not in server list is included", function()
    local items = build({}, { ["extra"] = "/tmp/extra.md" }, noop_on_select)
    h.eq(1, #items)
    h.eq("extra", items[1].value)
    h.eq("local", items[1].source)
    h.is_true(items[1].on_select ~= nil)
  end)

  h.it("local file is not duplicated when also in server list", function()
    local server = { { label = "dup", value = "dup", serverName = "global" } }
    local local_files = { ["dup"] = "/tmp/dup.md" }
    local items = build(server, local_files, noop_on_select)
    h.eq(1, #items)
  end)

  h.it("server prompt with serverName=local and matching file gets on_select", function()
    local server = { { label = "old-style", value = "old-style", serverName = "local" } }
    local local_files = { ["old-style"] = "/tmp/old-style.md" }
    local items = build(server, local_files, noop_on_select)
    h.eq(1, #items)
    h.eq("local", items[1].source)
    h.is_true(items[1].on_select ~= nil)
  end)

  h.it("mixed: server-only, local-only, and overlapping prompts", function()
    local server = {
      { label = "s1", value = "s1", serverName = "mcp" },
      { label = "both", value = "both", serverName = "global" },
    }
    local local_files = { ["both"] = "/tmp/both.md", ["l1"] = "/tmp/l1.md" }
    local items = build(server, local_files, noop_on_select)
    -- s1 (server), both (local override), l1 (local-only)
    h.eq(3, #items)

    local by_name = {}
    for _, item in ipairs(items) do
      by_name[item.value] = item
    end
    h.eq("mcp", by_name["s1"].source)
    h.is_nil(by_name["s1"].on_select)
    h.eq("local", by_name["both"].source)
    h.is_true(by_name["both"].on_select ~= nil)
    h.eq("local", by_name["l1"].source)
    h.is_true(by_name["l1"].on_select ~= nil)
  end)

  h.it("preserves description from server prompt when local file matches", function()
    local server = { { label = "p", value = "p", serverName = "global", description = "server desc" } }
    local items = build(server, { ["p"] = "/tmp/p.md" }, noop_on_select)
    h.eq("server desc", items[1].description)
  end)

  h.it("passes correct fpath to make_on_select", function()
    local captured
    local items = build({}, { ["x"] = "/my/path.md" }, function(fpath)
      captured = fpath
      return function() end
    end)
    h.eq("/my/path.md", captured)
  end)
end)
