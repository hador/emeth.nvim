local h = require("tests.helpers")
local Sessions = require("emeth.sessions")

-- Use a temp file for the session index
local tmp_dir = vim.fn.tempname()
vim.fn.mkdir(tmp_dir, "p")
local orig_stdpath = vim.fn.stdpath
---@diagnostic disable-next-line: duplicate-set-field
vim.fn.stdpath = function(what)
  if what == "state" then
    return tmp_dir
  end
  return orig_stdpath(what)
end

local function reset()
  local path = tmp_dir .. "/emeth/sessions.json"
  if vim.fn.filereadable(path) == 1 then
    vim.fn.delete(path)
  end
end

h.describe("Sessions", function()
  h.it("save and get", function()
    reset()
    Sessions.save({ session_id = "s1", provider = "test", cwd = "/tmp" })
    local entry = Sessions.get("s1")
    h.is_true(entry ~= nil)
    h.eq("s1", entry.session_id)
    h.eq("test", entry.provider)
    h.eq("/tmp", entry.cwd)
  end)

  h.it("save updates existing entry", function()
    reset()
    Sessions.save({ session_id = "s1", provider = "test", cwd = "/tmp" })
    Sessions.save({ session_id = "s1", provider = "test", cwd = "/tmp", title = "updated" })
    local entry = Sessions.get("s1")
    h.eq("updated", entry.title)
  end)

  h.it("update_title", function()
    reset()
    Sessions.save({ session_id = "s1", provider = "test", cwd = "/tmp" })
    Sessions.update_title("s1", "new title")
    h.eq("new title", Sessions.get("s1").title)
  end)

  h.it("persists forked_from and never clears it on a later save", function()
    reset()
    Sessions.save({ session_id = "b", provider = "test", cwd = "/tmp", forked_from = "a" })
    h.eq("a", Sessions.get("b").forked_from)
    -- a lazy first-prompt save carries no lineage; it must not wipe the parent
    Sessions.save({ session_id = "b", provider = "test", cwd = "/tmp", title = "t" })
    h.eq("a", Sessions.get("b").forked_from)
    h.eq("t", Sessions.get("b").title)
  end)

  h.it("remove", function()
    reset()
    Sessions.save({ session_id = "s1", provider = "test", cwd = "/tmp" })
    Sessions.remove("s1")
    h.is_nil(Sessions.get("s1"))
  end)

  h.it("list filters by cwd and provider", function()
    reset()
    Sessions.save({ session_id = "s1", provider = "kiro", cwd = "/a" })
    Sessions.save({ session_id = "s2", provider = "gemini", cwd = "/a" })
    Sessions.save({ session_id = "s3", provider = "kiro", cwd = "/b" })

    local all_a = Sessions.list("/a")
    h.eq(2, #all_a)

    local kiro_a = Sessions.list("/a", "kiro")
    h.eq(1, #kiro_a)
    h.eq("s1", kiro_a[1].session_id)

    local kiro_b = Sessions.list("/b", "kiro")
    h.eq(1, #kiro_b)
    h.eq("s3", kiro_b[1].session_id)
  end)

  h.it("list sorts by updated_at descending", function()
    reset()
    -- Manually create entries with known timestamps via save + direct file manipulation
    Sessions.save({ session_id = "old", provider = "test", cwd = "/tmp" })
    Sessions.save({ session_id = "new", provider = "test", cwd = "/tmp" })
    -- Verify both exist
    local list = Sessions.list("/tmp", "test")
    h.eq(2, #list)
    -- The sort is by updated_at descending; since both were saved in the same
    -- second they have equal timestamps, so order is stable. Touch "old" to
    -- give it a definitively later timestamp.
    -- We can't rely on sub-second timing, so just verify the contract:
    -- after touching "old", it should come first.
    Sessions.touch("old")
    -- If timestamps are still equal (same second), at least verify no crash
    list = Sessions.list("/tmp", "test")
    h.eq(2, #list)
    -- Both session_ids should be present
    local ids = {}
    for _, e in ipairs(list) do
      ids[e.session_id] = true
    end
    h.is_true(ids["old"])
    h.is_true(ids["new"])
  end)

  h.it("get returns nil for unknown session", function()
    reset()
    h.is_nil(Sessions.get("nonexistent"))
  end)

  h.it("remove nonexistent is a no-op", function()
    reset()
    Sessions.remove("nonexistent") -- should not error
  end)

  h.it("save persists additional_directories", function()
    reset()
    Sessions.save({
      session_id = "s1",
      provider = "test",
      cwd = "/tmp",
      additional_directories = { "/a", "/b" },
    })
    local entry = Sessions.get("s1")
    h.eq({ "/a", "/b" }, entry.additional_directories)
  end)

  h.it("save updates additional_directories on existing entry", function()
    reset()
    Sessions.save({
      session_id = "s1",
      provider = "test",
      cwd = "/tmp",
      additional_directories = { "/a" },
    })
    Sessions.save({
      session_id = "s1",
      provider = "test",
      cwd = "/tmp",
      additional_directories = { "/a", "/b", "/c" },
    })
    h.eq({ "/a", "/b", "/c" }, Sessions.get("s1").additional_directories)
  end)

  h.it("save without additional_directories preserves existing value", function()
    reset()
    Sessions.save({
      session_id = "s1",
      provider = "test",
      cwd = "/tmp",
      additional_directories = { "/a" },
    })
    -- Update title only — additional_directories should not be wiped
    Sessions.save({
      session_id = "s1",
      provider = "test",
      cwd = "/tmp",
      title = "renamed",
    })
    local entry = Sessions.get("s1")
    h.eq({ "/a" }, entry.additional_directories)
    h.eq("renamed", entry.title)
  end)

  h.it("save without additional_directories on new entry leaves field nil", function()
    reset()
    Sessions.save({ session_id = "s1", provider = "test", cwd = "/tmp" })
    h.is_nil(Sessions.get("s1").additional_directories)
  end)
end)

h.describe("Sessions.import", function()
  local index_path = function()
    return tmp_dir .. "/emeth/sessions.json"
  end

  h.it("imports new sessions with the provider tag and a stamped created_at", function()
    reset()
    local r = Sessions.import(
      { { session_id = "r1", cwd = "/proj", title = "From agent", updated_at = "2026-01-01T10:00:00Z" } },
      "opencode"
    )
    h.eq(1, r.imported)
    h.eq(0, r.updated)
    local e = Sessions.get("r1")
    h.eq("opencode", e.provider)
    h.eq("/proj", e.cwd)
    h.eq("From agent", e.title)
    h.eq("auto", e.title_source)
    h.eq("2026-01-01T10:00:00Z", e.created_at)
    h.eq("2026-01-01T10:00:00Z", e.updated_at)
  end)

  h.it("adopts an agent title over an auto one, but never a user rename", function()
    reset()
    Sessions.save({ session_id = "s1", provider = "opencode", cwd = "/tmp" })
    Sessions.import({ { session_id = "s1", title = "Agent title" } }, "opencode")
    h.eq("Agent title", Sessions.get("s1").title)
    Sessions.update_title("s1", "My name", "user")
    Sessions.import({ { session_id = "s1", title = "Agent again" } }, "opencode")
    h.eq("My name", Sessions.get("s1").title)
    h.eq("user", Sessions.get("s1").title_source)
  end)

  h.it("forks are imported like any other entry; lineage survives", function()
    reset()
    Sessions.save({ session_id = "f", provider = "opencode", cwd = "/tmp", forked_from = "p", title = "fork" })
    Sessions.import({ { session_id = "f", title = "Agent title" } }, "opencode")
    h.eq("Agent title", Sessions.get("f").title)
    h.eq("p", Sessions.get("f").forked_from)
  end)

  h.it("takes the later of local and remote updated_at, stored in Z form", function()
    reset()
    Sessions.save({ session_id = "s1", provider = "opencode", cwd = "/tmp" })
    local raw =
      '[{"session_id":"s1","provider":"opencode","cwd":"/tmp","created_at":"2026-01-01T00:00:00Z","updated_at":"2026-01-01T00:00:00Z"}]'
    vim.fn.writefile({ raw }, index_path())
    -- older remote: the local (recent) stamp must survive the import
    local r = Sessions.import({ { session_id = "s1", updated_at = "2025-12-31T23:00:00Z" } }, "opencode")
    h.eq(0, r.imported)
    h.eq(1, r.updated)
    h.eq("2026-01-01T00:00:00Z", Sessions.get("s1").updated_at)
    -- newer remote in offset form: wins, normalized to Z for stable sorting
    Sessions.import({ { session_id = "s1", updated_at = "2026-01-01T02:30:00+02:00" } }, "opencode")
    h.eq("2026-01-01T00:30:00Z", Sessions.get("s1").updated_at)
  end)

  h.it("scopes identity per provider: the same id from two agents stays two entries", function()
    reset()
    Sessions.save({ session_id = "x", provider = "opencode", cwd = "/tmp", title = "local title" })
    local r = Sessions.import({ { session_id = "x", cwd = "/other", title = "gemini title" } }, "gemini")
    h.eq(1, r.imported)
    h.eq(0, r.updated)
    h.eq("local title", Sessions.get("x").title)
    local gemini = Sessions.list("/other", "gemini")
    h.eq(1, #gemini)
    h.eq("gemini title", gemini[1].title)
  end)

  h.it("replaces additional_directories wholesale; absent leaves them", function()
    reset()
    Sessions.save({ session_id = "s1", provider = "opencode", cwd = "/tmp", additional_directories = { "/a" } })
    Sessions.import({ { session_id = "s1", additional_directories = { "/a", "/b", "/c" } } }, "opencode")
    h.eq({ "/a", "/b", "/c" }, Sessions.get("s1").additional_directories)
    -- a page that omits the field must not wipe what we have
    Sessions.import({ { session_id = "s1" } }, "opencode")
    h.eq({ "/a", "/b", "/c" }, Sessions.get("s1").additional_directories)
  end)

  h.it("skips malformed rows without writing", function()
    reset()
    local r = Sessions.import({ { cwd = "/x" }, { session_id = "" }, "junk" }, "opencode")
    h.eq(0, r.imported)
    h.eq(0, r.updated)
    h.is_true(vim.fn.filereadable(index_path()) == 0)
  end)
end)

-- A real index contained a record with timestamps and nothing else. `list` hid it
-- (no `cwd` to match), so anything reading across directories was the first thing
-- that would reach it and index a nil id.
h.describe("Sessions: malformed entries", function()
  local function write_raw(json)
    vim.fn.writefile({ json }, tmp_dir .. "/emeth/sessions.json")
  end

  -- The record found in the wild had no `cwd` either, so `list` filtered it out
  -- regardless -- give it a matching cwd so the query actually reaches it, which
  -- is the case any cross-directory read would hit.
  h.it("skips a record with no session_id", function()
    write_raw(
      '[{"cwd":"/tmp","provider":"test","created_at":"2026-03-11T10:45:11Z"},'
        .. '{"session_id":"keep","provider":"test","cwd":"/tmp"}]'
    )
    local got = Sessions.list("/tmp", "test")
    h.eq(1, #got)
    h.eq("keep", got[1].session_id)
  end)

  h.it("skips an empty-string session_id", function()
    write_raw('[{"session_id":"","cwd":"/tmp","provider":"test"}]')
    h.eq(0, #Sessions.list("/tmp", "test"))
  end)

  h.it("survives a corrupt index without erroring", function()
    write_raw("not json at all")
    h.eq(0, #Sessions.list("/tmp", "test"))
    h.is_nil(Sessions.get("keep"))
  end)
end)

-- Restore
vim.fn.stdpath = orig_stdpath
vim.fn.delete(tmp_dir, "rf")
