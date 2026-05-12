local h = require("tests.helpers")
local Roots = require("emeth.integrations.roots")

-- Stub winbar so badge calls are no-ops; restore at end of file.
local Winbar = package.loaded["emeth.ui.winbar"]
local _orig_set, _orig_clear = Winbar.set_badge, Winbar.clear_badge
Winbar.set_badge = function() end
Winbar.clear_badge = function() end

-- Stub vim.notify so the "added/not a directory" notifications don't
-- pollute test output.
local _orig_notify = vim.notify
vim.notify = function() end

local function fake_view()
  return {} -- module ignores view today; placeholder for future use
end

h.describe("Roots.attach", function()
  h.it("snapshot is empty initially", function()
    local r = Roots.attach(fake_view())
    h.eq({}, r:snapshot())
  end)

  h.it("save_field returns nil when empty", function()
    local r = Roots.attach(fake_view())
    h.is_nil(r:save_field())
  end)

  h.it("add stores absolute paths and snapshot reflects them", function()
    local r = Roots.attach(fake_view())
    r:add("/tmp")
    local snap = r:snapshot()
    h.eq(1, #snap)
    -- absolutize and trim trailing slash
    h.eq("/tmp", snap[1]:gsub("/$", ""))
  end)

  h.it("add is idempotent on the same path", function()
    local r = Roots.attach(fake_view())
    r:add("/tmp")
    r:add("/tmp")
    h.eq(1, #r:snapshot())
  end)

  h.it("add ignores non-directories silently", function()
    local r = Roots.attach(fake_view())
    r:add("/this/does/not/exist/probably/zzz")
    h.eq(0, #r:snapshot())
  end)

  h.it("add ignores nil and empty", function()
    local r = Roots.attach(fake_view())
    r:add(nil)
    r:add("")
    h.eq(0, #r:snapshot())
  end)

  h.it("remove by path drops the entry", function()
    local r = Roots.attach(fake_view())
    r:add("/tmp")
    r:remove("/tmp")
    h.eq(0, #r:snapshot())
  end)

  h.it("remove by index drops the entry", function()
    local r = Roots.attach(fake_view())
    r:add("/tmp")
    r:remove(1)
    h.eq(0, #r:snapshot())
  end)

  h.it("remove by unknown path is a no-op", function()
    local r = Roots.attach(fake_view())
    r:add("/tmp")
    r:remove("/not-tracked")
    h.eq(1, #r:snapshot())
  end)

  h.it("save_field returns a copy when non-empty", function()
    local r = Roots.attach(fake_view())
    r:add("/tmp")
    local saved = r:save_field()
    h.eq(1, #saved)
    -- mutating the snapshot must not affect roots' internal state
    saved[1] = "/garbage"
    h.eq(1, #r:snapshot())
    h.is_true(r:snapshot()[1] ~= "/garbage")
  end)

  h.it("hydrate_from restores roots from a session entry", function()
    local r = Roots.attach(fake_view())
    r:hydrate_from({ additional_directories = { "/a", "/b" } })
    h.eq({ "/a", "/b" }, r:snapshot())
  end)

  h.it("hydrate_from with no additional_directories is a no-op", function()
    local r = Roots.attach(fake_view())
    r:add("/tmp")
    r:hydrate_from({}) -- nothing to hydrate from
    h.eq(1, #r:snapshot())
  end)

  h.it("hydrate_from with nil entry is a no-op", function()
    local r = Roots.attach(fake_view())
    r:add("/tmp")
    r:hydrate_from(nil)
    h.eq(1, #r:snapshot())
  end)

  h.it("two attached instances are independent", function()
    local r1 = Roots.attach(fake_view())
    local r2 = Roots.attach(fake_view())
    r1:add("/tmp")
    h.eq(1, #r1:snapshot())
    h.eq(0, #r2:snapshot())
  end)

  h.it("mention_handlers includes workspace and roots", function()
    local r = Roots.attach(fake_view())
    local handlers = r:mention_handlers()
    h.is_true(handlers.workspace ~= nil)
    h.is_true(handlers.roots ~= nil)
    h.is_true(type(handlers.workspace.handler) == "function")
    h.is_true(type(handlers.workspace.desc) == "string")
  end)
end)

-- Restore stubs
Winbar.set_badge = _orig_set
Winbar.clear_badge = _orig_clear
vim.notify = _orig_notify
