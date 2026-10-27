--- Tests for emeth's entry point (init.lua) that need no agent process.

local h = require("tests.helpers")

local emeth = require("emeth")
emeth.setup({})

h.describe("emeth.open without a provider", function()
  h.it("asks which provider when no default_provider is set; cancelling connects nothing", function()
    local saved_default = emeth.config.default_provider
    emeth.config.default_provider = nil
    local orig_select = vim.ui.select
    local items
    vim.ui.select = function(list, _, on_choice)
      items = list
      on_choice(nil) -- the user cancels
    end

    emeth.open()

    vim.ui.select = orig_select
    emeth.config.default_provider = saved_default
    local expected = vim.tbl_keys(require("emeth.acp").config.providers)
    table.sort(expected)
    h.eq(expected, items, "every configured provider is offered, sorted")
    h.is_nil(emeth._integration, "a cancelled pick must not connect anything")
  end)
end)
