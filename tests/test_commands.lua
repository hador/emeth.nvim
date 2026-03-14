local h = require("tests.helpers")
local Commands = require("emeth.commands")

-- Reset state between describes
local function reset()
  for _, cmd in ipairs(Commands.list()) do
    Commands.unregister(cmd.name)
  end
end

h.describe("Commands", function()
  h.it("register and get", function()
    reset()
    Commands.register("test", { desc = "a test", source = "builtin", execute = function() end })
    local cmd = Commands.get("test")
    h.is_true(cmd ~= nil)
    h.eq("a test", cmd.desc)
    h.eq("builtin", cmd.source)
  end)

  h.it("list returns sorted commands", function()
    reset()
    Commands.register("zebra", { desc = "z", source = "acp", execute = function() end })
    Commands.register("alpha", { desc = "a", source = "acp", execute = function() end })
    local list = Commands.list()
    h.eq(2, #list)
    h.eq("alpha", list[1].name)
    h.eq("zebra", list[2].name)
  end)

  h.it("unregister removes command", function()
    reset()
    Commands.register("tmp", { desc = "t", source = "acp", execute = function() end })
    Commands.unregister("tmp")
    h.is_nil(Commands.get("tmp"))
  end)

  h.it("clear_acp removes only acp commands", function()
    reset()
    Commands.register("builtin_cmd", { desc = "b", source = "builtin", execute = function() end })
    Commands.register("acp_cmd", { desc = "a", source = "acp", execute = function() end })
    Commands.clear_acp()
    h.is_true(Commands.get("builtin_cmd") ~= nil)
    h.is_nil(Commands.get("acp_cmd"))
  end)

  h.it("acp command with same name as builtin merges execute", function()
    reset()
    local calls = {}
    Commands.register("dual", {
      desc = "builtin",
      source = "builtin",
      execute = function()
        calls[#calls + 1] = "builtin"
      end,
    })
    Commands.register("dual", {
      desc = "acp",
      source = "acp",
      execute = function()
        calls[#calls + 1] = "acp"
      end,
    })
    local cmd = Commands.get("dual")
    h.eq("builtin", cmd.source)
    cmd.execute("", {})
    h.eq({ "builtin", "acp" }, calls)
  end)

  h.it("clear_acp restores builtin from merged command", function()
    reset()
    local calls = {}
    Commands.register("dual", {
      desc = "builtin",
      source = "builtin",
      execute = function()
        calls[#calls + 1] = "builtin"
      end,
    })
    Commands.register("dual", {
      desc = "acp",
      source = "acp",
      execute = function()
        calls[#calls + 1] = "acp"
      end,
    })
    Commands.clear_acp()
    local cmd = Commands.get("dual")
    h.is_true(cmd ~= nil)
    h.eq("builtin", cmd.source)
    cmd.execute("", {})
    h.eq({ "builtin" }, calls)
  end)

  h.it("get returns nil for unknown command", function()
    reset()
    h.is_nil(Commands.get("nonexistent"))
  end)
end)
