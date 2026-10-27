local h = require("tests.helpers")
local V = require("emeth.validity")

local DAY = 86400

-- A store that answers from a fixed path table, so the core is tested without
-- any real provider's layout.
local FAKE = {
  transcript_path = function(entry, home)
    if entry.session_id == "no-path" then
      return nil
    end
    return home .. "/store/" .. entry.session_id
  end,
  is_stale = function(_, mtime, env)
    return env.now - mtime >= 10 * DAY
  end,
}

-- A controllable environment: no real filesystem, clock or provider modules.
---@param overrides table
---@return table
local function env(overrides)
  local base = {
    now = 1000 * DAY,
    home = "/home/me",
    file_mtime = function()
      return nil
    end,
    read_json = function()
      return nil
    end,
    store_for = function(provider)
      return provider == "fake" and FAKE or nil
    end,
  }
  return vim.tbl_extend("force", base, overrides or {})
end

local function mtime_at(age_days)
  return function(path)
    return path == "/home/me/store/s1" and (1000 - age_days) * DAY or nil
  end
end

h.describe("validity.check — provider store", function()
  local entry = { session_id = "s1", provider = "fake", cwd = "/tmp/p" }

  h.it("valid when the store's transcript exists and isn't stale", function()
    h.eq("valid", V.check(entry, env({ file_mtime = mtime_at(2) })))
  end)

  h.it("stale when the store's is_stale rule says so", function()
    h.eq("stale", V.check(entry, env({ file_mtime = mtime_at(12) })))
  end)

  h.it("gone when the transcript is missing", function()
    h.eq("gone", V.check(entry, env({})))
  end)

  h.it("gone when the store says the entry can't have a transcript", function()
    h.eq("gone", V.check({ session_id = "no-path", provider = "fake" }, env({ file_mtime = mtime_at(0) })))
  end)

  h.it("never stale for a store without an is_stale rule", function()
    local plain = { transcript_path = FAKE.transcript_path }
    local e = env({
      file_mtime = mtime_at(500),
      store_for = function()
        return plain
      end,
    })
    h.eq("valid", V.check(entry, e))
  end)
end)

h.describe("validity.check — providers without a store", function()
  h.it("valid when the directory exists", function()
    local dir = vim.fn.tempname()
    vim.fn.mkdir(dir, "p")
    h.eq("valid", V.check({ session_id = "x", provider = "goose", cwd = dir }, env({})))
    vim.fn.delete(dir, "d")
  end)

  h.it("gone when the directory does not exist", function()
    h.eq("gone", V.check({ session_id = "x", provider = "goose", cwd = "/no/such/dir/here" }, env({})))
  end)
end)

h.describe("validity.check_all", function()
  h.it("one verdict per entry, across stores", function()
    local verdicts = V.check_all({
      { session_id = "s1", provider = "fake" },
      { session_id = "s2", provider = "fake" },
      { session_id = "g1", provider = "goose", cwd = "/no/such/dir/here" },
    }, env({ file_mtime = mtime_at(1) }))
    h.eq({ s1 = "valid", s2 = "gone", g1 = "gone" }, verdicts)
  end)
end)

-- The real lookup: each built-in provider with a store exports one from its
-- integrations module; the rest have none.
h.describe("validity: provider stores are looked up from the integrations", function()
  local saved_kiro_home = vim.env.KIRO_HOME
  vim.env.KIRO_HOME = nil

  h.it("resolves claude-code and kiro-cli through their session_store", function()
    h.eq(
      "/home/me/.claude/projects/-tmp-proj/abc.jsonl",
      V.transcript_path({ provider = "claude-code", cwd = "/tmp/proj", session_id = "abc" }, "/home/me")
    )
    h.eq(
      "/home/me/.kiro/sessions/cli/k1.jsonl",
      V.transcript_path({ provider = "kiro-cli", session_id = "k1" }, "/home/me")
    )
  end)

  h.it("has no store for providers without one", function()
    h.is_nil(V.transcript_path({ provider = "goose", cwd = "/tmp", session_id = "x" }, "/home/me"))
    h.is_nil(V.transcript_path({ provider = "no-such-provider", session_id = "x" }, "/home/me"))
  end)

  vim.env.KIRO_HOME = saved_kiro_home
end)

h.describe("validity.transcript_size", function()
  -- Hermetic: a throwaway home dir holding one transcript per provider.
  local saved_kiro_home = vim.env.KIRO_HOME
  vim.env.KIRO_HOME = nil
  local home = vim.fn.tempname()
  local proj = home .. "/.claude/projects/-tmp-proj"
  vim.fn.mkdir(proj, "p")
  vim.fn.writefile({ "0123456789" }, proj .. "/abc.jsonl") -- 10 bytes + newline
  vim.fn.mkdir(home .. "/.kiro/sessions/cli", "p")
  vim.fn.writefile({ "01234" }, home .. "/.kiro/sessions/cli/k1.jsonl") -- 5 bytes + newline

  h.it("stats the provider's transcript", function()
    h.eq(11, V.transcript_size({ provider = "claude-code", cwd = "/tmp/proj", session_id = "abc" }, home))
    h.eq(6, V.transcript_size({ provider = "kiro-cli", session_id = "k1" }, home))
  end)
  h.it("is nil when the transcript file is absent", function()
    h.is_nil(V.transcript_size({ provider = "claude-code", cwd = "/tmp/proj", session_id = "missing" }, home))
  end)
  h.it("is nil for providers without a store", function()
    h.is_nil(V.transcript_size({ provider = "goose", cwd = "/tmp/proj", session_id = "abc" }, home))
  end)

  vim.fn.delete(home, "rf")
  vim.env.KIRO_HOME = saved_kiro_home
end)
