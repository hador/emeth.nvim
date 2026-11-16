--- File mentions: `@path` tokens in the prompt are the file context (emeth.mentions), sent for the
--- prompt that names them and no other.

local h = require("tests.helpers")
local H = require("tests.acp_harness")
local Mentions = require("emeth.mentions")

-- A scratch project: two files and a subdirectory, as the cwd tokens resolve against.
local root = vim.fn.tempname()
vim.fn.mkdir(root .. "/lua/sub", "p")
root = assert(vim.uv.fs_realpath(root)) -- macOS: /tmp is /private/tmp once we :cd into it
vim.fn.writefile({ "x" }, root .. "/a.lua")
vim.fn.writefile({ "y" }, root .. "/lua/sub/b.lua")
local A, B = root .. "/a.lua", root .. "/lua/sub/b.lua"

local function paths(found)
  return vim.tbl_map(function(m)
    return m.path
  end, found)
end

h.describe("Mentions.parse", function()
  h.it("resolves @path tokens against the cwd, with or without a line range", function()
    local found = Mentions.parse("look at @a.lua and @lua/sub/b.lua:L3-L9 please", root)
    h.eq({ A, B }, paths(found))
    h.eq("lua/sub/b.lua:L3-L9", found[2].token)
  end)

  h.it("accepts absolute paths and bare line numbers", function()
    h.eq({ A }, paths(Mentions.parse("@" .. A .. ":12", root)))
  end)

  h.it("drops sentence punctuation after a token", function()
    h.eq({ A, B }, paths(Mentions.parse("see @a.lua, then (@lua/sub/b.lua).", root)))
  end)

  h.it("lists a file once however often it is mentioned", function()
    h.eq({ A }, paths(Mentions.parse("@a.lua:L1 and again @a.lua:L5", root)))
  end)

  h.it("leaves alone what is not a readable file: directories, missing paths, user@host", function()
    h.eq({}, paths(Mentions.parse("@lua @nope.lua user@a.lua @workspace", root)))
  end)
end)

h.describe("Mentions.format", function()
  h.it("writes a cwd-relative token, with the line or range when given", function()
    h.eq("@a.lua", Mentions.format(A, nil, nil, root))
    h.eq("@lua/sub/b.lua:L4", Mentions.format(B, 4, nil, root))
    h.eq("@lua/sub/b.lua:L4", Mentions.format(B, 4, 4, root))
    h.eq("@lua/sub/b.lua:L4-L8", Mentions.format(B, 4, 8, root))
  end)

  h.it("round-trips through parse", function()
    local token = Mentions.format(B, 2, 7, root)
    h.eq({ B }, paths(Mentions.parse("diff " .. token .. ":", root)))
  end)
end)

h.describe("acp integration: mentions are the prompt's file context", function()
  local restore = H.install()
  -- Files that run earlier (test_init) reset the acp config the harness seeded on first require.
  local providers = require("emeth.acp").config.providers
  local had_test = providers.test
  providers.test = providers.test or { command = "echo", args = {} }

  ---Run `fn` with the scratch project as cwd, restoring the cwd even when it fails (a leaked cwd breaks
  ---every later test file's requires).
  local function in_root(fn)
    local prev = vim.fn.getcwd()
    vim.cmd.cd(root)
    local ok, err = pcall(fn)
    vim.cmd.cd(prev)
    if not ok then
      error(err, 0)
    end
  end

  ---A ready session that records each prompt it is asked to send.
  local function sending()
    local session, view = H.setup()
    local sent = {}
    session.client.send_prompt = function(_, _sid, prompt, cb)
      sent[#sent + 1] = prompt
      cb({ stopReason = "end_turn" }, nil)
    end
    return view, sent
  end

  local function links(prompt)
    local out = {}
    for _, item in ipairs(prompt) do
      if item.type == "resource_link" then
        out[#out + 1] = item.uri
      end
    end
    return out
  end

  h.it("sends a resource_link per mentioned file, then the text as typed", function()
    in_root(function()
      local view, sent = sending()
      view.on_submit("compare @a.lua with @lua/sub/b.lua:L2")
      H.flush()
      h.eq({ "file://" .. A, "file://" .. B }, links(sent[1]))
      h.eq("compare @a.lua with @lua/sub/b.lua:L2", sent[1][#sent[1]].text)
    end)
  end)

  h.it("does not carry a file over to the next prompt", function()
    in_root(function()
      local view, sent = sending()
      view.on_submit("read @a.lua")
      H.flush()
      view.on_submit("now something else")
      H.flush()
      h.eq(1, #links(sent[1]))
      h.eq({}, links(sent[2]), "a file mentioned once must not ride along on later turns")
    end)
  end)

  h.it("records the prompt's files on its transcript message, and only those", function()
    in_root(function()
      local view = sending()
      view.on_submit("read @a.lua")
      H.flush()
      view.on_submit("plain")
      H.flush()
      local users = vim.tbl_filter(function(m)
        return m.role == "user"
      end, view.messages)
      h.eq({ A }, users[1].metadata.selected_files)
      h.eq({}, users[2].metadata.selected_files)
    end)
  end)

  h.it("the @ picker offers file, current and diagnostics, and no hidden-list entries", function()
    local _, view = H.setup()
    for _, name in ipairs({ "file", "current", "diagnostics" }) do
      h.is_true(view._mention_handlers[name] ~= nil, "missing @" .. name)
    end
    for _, name in ipairs({ "buffers", "files" }) do
      h.is_nil(view._mention_handlers[name], "@" .. name .. " belonged to the removed attached-files list")
    end
  end)

  providers.test = had_test
  restore()
end)

h.describe("ChatView:insert_mention", function()
  local ChatView = require("emeth.ui.chat_view")
  local function view_with(lines)
    local view = ChatView:new({ config = require("emeth").config })
    vim.api.nvim_buf_set_lines(view.input_buf, 0, -1, false, lines)
    return view
  end
  local function input(view)
    return vim.api.nvim_buf_get_lines(view.input_buf, 0, -1, false)
  end

  h.it("puts the token where the @ was typed", function()
    local view = view_with({ "compare  with that" })
    view._mention_at = { 0, 8 }
    view:insert_mention("@a.lua")
    h.eq({ "compare @a.lua  with that" }, input(view))
  end)

  h.it("gives the @ back when the pick is cancelled", function()
    local view = view_with({ "mail me " })
    view._mention_at = { 0, 8 }
    view:insert_mention(nil)
    h.eq({ "mail me @" }, input(view))
  end)

  h.it("a put-back @ does not reopen the picker, a typed one does", function()
    local view = view_with({ "and " })
    view._mention_handlers = { file = { desc = "", handler = function() end } }
    local win = vim.api.nvim_open_win(view.input_buf, true, { split = "below" })
    local opened = 0
    local orig = vim.ui.select
    vim.ui.select = function()
      opened = opened + 1
    end
    local function text_changed()
      vim.api.nvim_win_set_cursor(win, { 1, #vim.api.nvim_get_current_line() })
      vim.api.nvim_exec_autocmds("TextChangedI", { buffer = view.input_buf })
      vim.wait(0)
    end
    local ok, err = pcall(function()
      view._mention_at = { 0, 4 }
      view:insert_mention(nil) -- the pick was cancelled: "and @"
      text_changed()
      h.eq(0, opened, "restoring the @ re-triggered the picker; the next keystrokes would land in it")
      vim.api.nvim_buf_set_lines(view.input_buf, 0, -1, false, { "then @" }) -- as if typed
      text_changed()
      h.eq(1, opened, "a typed @ must still open the picker")
    end)
    vim.ui.select = orig
    vim.cmd("stopinsert")
    vim.api.nvim_win_close(win, true)
    assert(ok, err)
  end)

  h.it("appends at the end when no @ opened the picker", function()
    local view = view_with({ "first", "last line " })
    view:insert_mention("@a.lua")
    h.eq({ "first", "last line @a.lua " }, input(view))
  end)
end)

vim.fn.delete(root, "rf")
