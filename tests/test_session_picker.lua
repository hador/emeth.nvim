--- Tests for the cross-directory session picker: age formatting, directory
--- shortening, and row building.

local h = require("tests.helpers")
local P = require("emeth.ui.session_picker")

local NOW = "2026-09-04T12:00:00Z"

h.describe("session_picker.ago", function()
  h.it("counts seconds, minutes, hours, days, weeks and months", function()
    h.eq("30s", P.ago("2026-09-04T11:59:30Z", NOW))
    h.eq("5m", P.ago("2026-09-04T11:55:00Z", NOW))
    h.eq("3h", P.ago("2026-09-04T09:00:00Z", NOW))
    h.eq("2d", P.ago("2026-09-02T12:00:00Z", NOW))
    h.eq("2w", P.ago("2026-08-21T12:00:00Z", NOW))
    h.eq("2mo", P.ago("2026-07-04T12:00:00Z", NOW))
  end)

  -- The stamps are UTC but os.time reads its table as local time. That bias is
  -- identical on both sides and cancels in the subtraction, so no offset math is
  -- needed -- this asserts the cancellation actually holds.
  h.it("is timezone-independent", function()
    local orig = vim.env.TZ
    local seen = {}
    for _, tz in ipairs({ "UTC", "America/Los_Angeles", "Asia/Tokyo" }) do
      vim.env.TZ = tz
      seen[#seen + 1] = P.ago("2026-09-04T09:00:00Z", NOW)
    end
    vim.env.TZ = orig
    h.eq({ "3h", "3h", "3h" }, seen)
  end)

  h.it("clamps a future stamp to zero rather than going negative", function()
    h.eq("0s", P.ago("2026-09-04T12:00:30Z", NOW))
  end)

  h.it("degrades to ? on an unparseable stamp", function()
    h.eq("?", P.ago("not a date", NOW))
    h.eq("?", P.ago(nil, NOW))
  end)
end)

h.describe("session_picker.short_dir", function()
  h.it("keeps a short path as-is", function()
    h.eq("/tmp/proj", P.short_dir("/tmp/proj"))
  end)

  h.it("collapses home to a tilde", function()
    h.eq("~", P.short_dir(vim.fn.expand("~")))
    h.eq("~/Notes", P.short_dir(vim.fn.expand("~") .. "/Notes"))
  end)

  -- A Brazil workspace is `<workspace>/src/<Package>`, so the component above the
  -- package is a bare `src` that identifies nothing. The workspace name does.
  h.it("skips a bare src component when shortening", function()
    h.eq(
      "FOS/FireTvLauncher",
      P.short_dir("/Volumes/workplace/FTV/FOS/src/FireTvLauncher")
    )
  end)

  h.it("keeps the parent for other long paths", function()
    h.eq(
      "deep/leaf",
      P.short_dir("/Volumes/workplace/some/very/long/path/deep/leaf")
    )
  end)

  h.it("survives a nil or empty dir", function()
    h.eq("?", P.short_dir(nil))
    h.eq("?", P.short_dir(""))
  end)
end)

h.describe("session_picker.items", function()
  local dir = vim.fn.tempname()

  local function entry(over)
    local e = {
      session_id = "abcdef01-2345-6789-abcd-ef0123456789",
      provider = "claude-code",
      cwd = dir,
      title = "Fix the parser",
      updated_at = "2026-09-04T09:00:00Z",
    }
    for k, v in pairs(over or {}) do
      e[k] = v
    end
    return e
  end

  h.it("builds a title / directory / age row", function()
    vim.fn.mkdir(dir, "p")
    local items = P.items({ entry() }, NOW)
    h.eq(1, #items)
    h.is_true(items[1].label:find("Fix the parser", 1, true) ~= nil, items[1].label)
    h.is_true(items[1].label:find("3h", 1, true) ~= nil, items[1].label)
    vim.fn.delete(dir, "rf")
  end)

  -- Resuming hands the agent the recorded cwd, so a session whose directory is
  -- gone cannot work. In a real index these were 126 of 306 entries.
  h.it("drops sessions whose directory no longer exists, and counts them", function()
    local items, dropped = P.items({ entry({ cwd = "/definitely/not/here" }) }, NOW)
    h.eq(0, #items)
    h.eq(1, dropped)
  end)

  h.it("clamps an over-long title so the directory stays visible", function()
    vim.fn.mkdir(dir, "p")
    local long = string.rep("x", 200)
    local items = P.items({ entry({ title = long }) }, NOW)
    h.is_true(vim.fn.strchars(items[1].label) < 120, "label was " .. vim.fn.strchars(items[1].label))
    h.is_true(items[1].label:find("…", 1, true) ~= nil, "expected an ellipsis")
    h.is_true(items[1].label:find("3h", 1, true) ~= nil, "age must survive the clamp")
    vim.fn.delete(dir, "rf")
  end)

  -- Built inline rather than via `entry({ title = nil })`: Lua does not store nil
  -- values, so that override would silently keep the default title.
  h.it("falls back to a short id when there is no title", function()
    vim.fn.mkdir(dir, "p")
    local items = P.items({
      {
        session_id = "abcdef01-2345-6789-abcd-ef0123456789",
        provider = "claude-code",
        cwd = dir,
        updated_at = "2026-09-04T09:00:00Z",
      },
    }, NOW)
    h.is_true(items[1].label:find("abcdef01", 1, true) ~= nil, items[1].label)
    vim.fn.delete(dir, "rf")
  end)

  h.it("carries the entry through so the caller can resume it", function()
    vim.fn.mkdir(dir, "p")
    local items = P.items({ entry() }, NOW)
    h.eq("claude-code", items[1].entry.provider)
    h.eq(dir, items[1].entry.cwd)
    vim.fn.delete(dir, "rf")
  end)
end)

h.describe("Sessions.list_all", function()
  local Sessions = require("emeth.sessions")
  local tmp = vim.fn.tempname()
  local orig = vim.fn.stdpath
  ---@diagnostic disable-next-line: duplicate-set-field
  vim.fn.stdpath = function(what)
    return what == "state" and tmp or orig(what)
  end
  vim.fn.mkdir(tmp, "p")

  h.it("returns sessions from every directory, newest first", function()
    Sessions.save({ session_id = "old", provider = "p", cwd = "/a" })
    Sessions.save({ session_id = "new", provider = "p", cwd = "/b" })
    -- save stamps both with the same second, so order them explicitly.
    local f = tmp .. "/emeth/sessions.json"
    vim.fn.writefile({
      '[{"session_id":"old","provider":"p","cwd":"/a","updated_at":"2026-01-01T00:00:00Z"},'
        .. '{"session_id":"new","provider":"p","cwd":"/b","updated_at":"2026-09-01T00:00:00Z"}]',
    }, f)
    local all = Sessions.list_all()
    h.eq(2, #all, "both directories must appear")
    h.eq("new", all[1].session_id, "newest first")
  end)

  h.it("filters by provider when asked", function()
    local f = tmp .. "/emeth/sessions.json"
    vim.fn.writefile({
      '[{"session_id":"a","provider":"claude-code","cwd":"/a"},{"session_id":"b","provider":"kiro-cli","cwd":"/b"}]',
    }, f)
    local got = Sessions.list_all("kiro-cli")
    h.eq(1, #got)
    h.eq("b", got[1].session_id)
  end)

  vim.fn.stdpath = orig
  vim.fn.delete(tmp, "rf")
end)
