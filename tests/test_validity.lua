local h = require("tests.helpers")
local V = require("emeth.validity")

local DAY = 86400

-- A controllable environment: no real filesystem, clock, or sqlite touched.
---@param overrides table
---@return table
local function env(overrides)
  local base = {
    now = 1000 * DAY, -- an arbitrary fixed "now"
    home = "/home/me",
    file_mtime = function()
      return nil
    end,
    read_json = function()
      return nil
    end,
    kiro_present = function()
      return nil
    end,
  }
  return vim.tbl_extend("force", base, overrides or {})
end

h.describe("validity.sanitize_cwd", function()
  h.it("maps / and . to -", function()
    h.eq("-Volumes-workplace-emeth-nvim", V.sanitize_cwd("/Volumes/workplace/emeth.nvim"))
  end)
  h.it("leaves other chars alone", function()
    h.eq("-Users-me-Dark_room", V.sanitize_cwd("/Users/me/Dark_room"))
  end)
end)

h.describe("validity.claude_transcript_path", function()
  h.it("builds the projects/<sanitized>/<id>.jsonl path", function()
    h.eq(
      "/home/me/.claude/projects/-tmp-proj/abc.jsonl",
      V.claude_transcript_path("/tmp/proj", "abc", "/home/me")
    )
  end)
end)

h.describe("validity.claude_retention_days", function()
  h.it("defaults to 30 when nothing is set", function()
    h.eq(30, V.claude_retention_days("/tmp/proj", "/home/me", function()
      return nil
    end))
  end)
  h.it("reads cleanupPeriodDays from user settings", function()
    h.eq(7, V.claude_retention_days("/tmp/proj", "/home/me", function(path)
      if path == "/home/me/.claude/settings.json" then
        return { cleanupPeriodDays = 7 }
      end
    end))
  end)
  h.it("project-local wins over user and project", function()
    local days = V.claude_retention_days("/tmp/proj", "/home/me", function(path)
      if path == "/home/me/.claude/settings.json" then
        return { cleanupPeriodDays = 10 }
      elseif path == "/tmp/proj/.claude/settings.json" then
        return { cleanupPeriodDays = 20 }
      elseif path == "/tmp/proj/.claude/settings.local.json" then
        return { cleanupPeriodDays = 5 }
      end
    end)
    h.eq(5, days)
  end)
end)

h.describe("validity.check — claude-code", function()
  local entry = { session_id = "abc", provider = "claude-code", cwd = "/tmp/proj" }

  h.it("gone when the transcript is missing", function()
    h.eq("gone", V.check(entry, env({ file_mtime = function()
      return nil
    end })))
  end)

  h.it("valid when fresh (within retention)", function()
    h.eq(
      "valid",
      V.check(entry, env({
        file_mtime = function()
          return 1000 * DAY - 5 * DAY -- 5 days old
        end,
      }))
    )
  end)

  h.it("stale when past the retention window", function()
    h.eq(
      "stale",
      V.check(entry, env({
        file_mtime = function()
          return 1000 * DAY - 40 * DAY -- 40 days old, default window 30
        end,
      }))
    )
  end)

  h.it("honours a shortened retention window", function()
    h.eq(
      "stale",
      V.check(entry, env({
        file_mtime = function()
          return 1000 * DAY - 8 * DAY -- 8 days old
        end,
        read_json = function(path)
          if path == "/home/me/.claude/settings.json" then
            return { cleanupPeriodDays = 7 }
          end
        end,
      }))
    )
  end)

  h.it("gone when cwd is empty", function()
    h.eq("gone", V.check({ session_id = "abc", provider = "claude-code", cwd = "" }, env({})))
  end)
end)

h.describe("validity.check — kiro-cli", function()
  local entry = { session_id = "u-1", provider = "kiro-cli", cwd = "/tmp/proj" }

  h.it("valid when the row is present", function()
    h.eq("valid", V.check(entry, env({ kiro_present = function()
      return true
    end })))
  end)

  h.it("gone when the row is absent", function()
    h.eq("gone", V.check(entry, env({ kiro_present = function()
      return false
    end })))
  end)

  h.it("lenient (valid) when the store can't be checked", function()
    h.eq("valid", V.check(entry, env({ kiro_present = function()
      return nil
    end })))
  end)
end)

h.describe("validity.check_all", function()
  h.it("batches kiro ids into one present-set lookup", function()
    local calls = 0
    local verdicts = V.check_all({
      { session_id = "k1", provider = "kiro-cli", cwd = "/a" },
      { session_id = "k2", provider = "kiro-cli", cwd = "/b" },
    }, env({
      kiro_present_set = function(ids)
        calls = calls + 1
        h.eq(2, #ids)
        return { k1 = true } -- k2 absent
      end,
    }))
    h.eq(1, calls, "one query for the whole batch")
    h.eq("valid", verdicts.k1)
    h.eq("gone", verdicts.k2)
  end)

  h.it("stays lenient when the kiro store is unreachable", function()
    local verdicts = V.check_all({ { session_id = "k1", provider = "kiro-cli", cwd = "/a" } }, env({
      kiro_present_set = function()
        return nil
      end,
    }))
    h.eq("valid", verdicts.k1)
  end)

  h.it("mixes providers, keeping claude verdicts per-entry", function()
    local verdicts = V.check_all({
      { session_id = "c1", provider = "claude-code", cwd = "/tmp/p" },
      { session_id = "k1", provider = "kiro-cli", cwd = "/a" },
    }, env({
      file_mtime = function()
        return nil -- claude transcript missing
      end,
      kiro_present_set = function()
        return { k1 = true }
      end,
    }))
    h.eq("gone", verdicts.c1)
    h.eq("valid", verdicts.k1)
  end)
end)

h.describe("validity.check — fallback providers", function()
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

h.describe("validity.transcript_size", function()
  -- Hermetic: a real but throwaway home dir holding one claude transcript.
  local home = vim.fn.tempname()
  local proj = home .. "/.claude/projects/-tmp-proj"
  vim.fn.mkdir(proj, "p")
  vim.fn.writefile({ "0123456789" }, proj .. "/abc.jsonl") -- 10 bytes + newline

  h.it("returns the transcript's byte size for claude-code", function()
    h.eq(11, V.transcript_size({ provider = "claude-code", cwd = "/tmp/proj", session_id = "abc" }, home))
  end)
  h.it("is nil when the transcript file is absent", function()
    h.eq(nil, V.transcript_size({ provider = "claude-code", cwd = "/tmp/proj", session_id = "missing" }, home))
  end)
  h.it("is nil for non-claude providers (no cheap single-file answer)", function()
    h.eq(nil, V.transcript_size({ provider = "kiro-cli", cwd = "/tmp/proj", session_id = "abc" }, home))
  end)
  h.it("is nil when the session has no working dir", function()
    h.eq(nil, V.transcript_size({ provider = "claude-code", cwd = "", session_id = "abc" }, home))
  end)

  vim.fn.delete(home, "rf")
end)
