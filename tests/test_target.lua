--- Tests for emeth.target — path-ref parsing, resolution, and source-window
--- routing (the "open files next door, never in the chat" policy).

local h = require("tests.helpers")

package.loaded["emeth"] = nil
require("emeth").setup({})

local Target = require("emeth.target")
local ChatView = require("emeth.ui.chat_view")
local Sidebar = require("emeth.layout.sidebar")
local api = vim.api

h.describe("Target.parse_ref", function()
  h.it("parses a bare path", function()
    local p, l = Target.parse_ref("foo/bar.lua")
    h.eq("foo/bar.lua", p)
    h.is_nil(l)
  end)

  h.it("splits a :LINE suffix", function()
    local p, l = Target.parse_ref("foo/bar.lua:42")
    h.eq("foo/bar.lua", p)
    h.eq(42, l)
  end)

  h.it("splits a :LINE:COL suffix, keeping the line", function()
    local p, l = Target.parse_ref("src/x.lua:10:5")
    h.eq("src/x.lua", p)
    h.eq(10, l)
  end)

  h.it("strips wrapping backticks", function()
    local p, l = Target.parse_ref("`foo/bar.lua:7`")
    h.eq("foo/bar.lua", p)
    h.eq(7, l)
  end)

  h.it("strips wrapping parens and trailing punctuation", function()
    local p, l = Target.parse_ref("(src/x.lua:10),")
    h.eq("src/x.lua", p)
    h.eq(10, l)
  end)

  h.it("strips a trailing comma off a bare path", function()
    local p, l = Target.parse_ref("path/to/file.lua,")
    h.eq("path/to/file.lua", p)
    h.is_nil(l)
  end)

  h.it("keeps an absolute path intact", function()
    local p, l = Target.parse_ref("/abs/path.lua:3")
    h.eq("/abs/path.lua", p)
    h.eq(3, l)
  end)

  h.it("returns nil on an empty token", function()
    h.is_nil(Target.parse_ref(""))
    h.is_nil(Target.parse_ref(nil))
  end)
end)

h.describe("Target.resolve", function()
  h.it("returns a readable absolute path", function()
    local tmp = vim.fn.tempname() .. ".lua"
    vim.fn.writefile({ "x" }, tmp)
    h.eq(vim.fn.fnamemodify(tmp, ":p"), Target.resolve(tmp))
    os.remove(tmp)
  end)

  h.it("returns nil when nothing on disk matches", function()
    h.is_nil(Target.resolve("/no/such/emeth/file/here.lua"))
  end)
end)

h.describe("Target.open", function()
  h.it("opens the file in the source window, not the chat", function()
    vim.o.columns = 200
    vim.o.lines = 50
    -- A known source window with a real buffer.
    vim.cmd("enew")
    local src_win = api.nvim_get_current_win()

    local view = ChatView:new({ config = require("emeth").config })
    local sb = Sidebar:new(require("emeth").config)
    sb:open(view)

    local tmp = vim.fn.tempname() .. ".lua"
    vim.fn.writefile({ "line1", "line2", "line3" }, tmp)

    local win = Target.open({ path = tmp, line = 2, focus = true })

    h.eq(src_win, win, "should route to the pre-existing source window")
    local opened = api.nvim_buf_get_name(api.nvim_win_get_buf(src_win))
    -- Resolve both sides: nvim canonicalizes the buffer name (e.g. the macOS
    -- /tmp -> /private/tmp symlink), so a raw :p comparison would mismatch.
    h.eq(vim.fn.resolve(vim.fn.fnamemodify(tmp, ":p")), vim.fn.resolve(vim.fn.fnamemodify(opened, ":p")))
    -- Chat result buffer is untouched.
    h.is_true(
      api.nvim_win_get_buf(sb.result_win) == view.result_buf,
      "result window must still show the chat buffer"
    )
    -- focus = true moved us to the source window.
    h.eq(src_win, api.nvim_get_current_win(), "focus should move to the source window")

    sb:close()
    os.remove(tmp)
  end)
end)

h.describe("Sidebar auto-eject", function()
  h.it("bounces a file opened into the chat window to the source window", function()
    vim.o.columns = 200
    vim.o.lines = 50
    vim.cmd("enew")
    local src_win = api.nvim_get_current_win()

    local view = ChatView:new({ config = require("emeth").config })
    local sb = Sidebar:new(require("emeth").config)
    sb:open(view)

    -- Simulate any picker/LSP/gf that drops a file into the chat window.
    local tmp = vim.fn.tempname() .. ".lua"
    vim.fn.writefile({ "a", "b", "c" }, tmp)
    local fbuf = vim.fn.bufadd(tmp)
    vim.fn.bufload(fbuf)
    api.nvim_set_current_win(sb.result_win)
    api.nvim_win_set_buf(sb.result_win, fbuf)

    -- Relocation is scheduled; let the event loop flush it.
    vim.wait(500, function()
      return api.nvim_win_is_valid(src_win)
        and api.nvim_win_get_buf(src_win) == fbuf
        and api.nvim_win_get_buf(sb.result_win) == view.result_buf
    end)

    h.eq(view.result_buf, api.nvim_win_get_buf(sb.result_win), "chat buffer must be restored")
    h.eq(fbuf, api.nvim_win_get_buf(src_win), "file must be ejected to the source window")

    sb:close()
    os.remove(tmp)
  end)
end)
