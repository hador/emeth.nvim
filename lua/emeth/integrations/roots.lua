--- Workspace roots subsystem — wraps the ACP `additionalDirectories`
--- capability into a small per-session feature with `@workspace`/`@roots`
--- @mention handlers, a winbar badge, and persistence.
---
--- The generic ACP integration calls `M.attach(view)` once per session and
--- gets back a small object with the API it needs:
---   - `:add(dir)` / `:remove(idx_or_path)` — programmatic mutators
---   - `:snapshot()` — copy of current roots, for `lifecycle_opts()`
---   - `:hydrate_from(entry)` — restore from a `Sessions.get(...)` record
---   - `:save_field()` — value to stash on `Sessions.save(...)`
---   - `:mention_handlers()` — table to merge into `view._mention_handlers`
---   - `:cleanup()` — clear the badge

local Winbar = require("emeth.ui.winbar")

local M = {}

---@class emeth.RootsHandle
---@field add fun(self, dir: string)
---@field remove fun(self, idx_or_path: number|string)
---@field snapshot fun(self): string[]
---@field hydrate_from fun(self, entry: table|nil)
---@field save_field fun(self): string[]|nil  value for Sessions.save's `additional_directories`
---@field mention_handlers fun(self): table<string, { desc: string, handler: fun() }>
---@field cleanup fun(self)

---Create a roots handle scoped to one session/integration. State is held in
---the closure; nothing leaks to module level.
---@param view chat_ui.ChatView
---@return emeth.RootsHandle
function M.attach(view)
  local roots = {} ---@type string[]

  local function refresh_badge()
    if #roots > 0 then
      Winbar.set_badge("roots", string.format("📁 %d root%s", #roots, #roots == 1 and "" or "s"))
    else
      Winbar.clear_badge("roots")
    end
  end

  ---@param dir string
  local function add(dir)
    if not dir or dir == "" then
      return
    end
    dir = vim.fn.fnamemodify(dir, ":p"):gsub("/$", "")
    if vim.fn.isdirectory(dir) ~= 1 then
      vim.notify("[emeth] Not a directory: " .. dir, vim.log.levels.WARN)
      return
    end
    if not vim.tbl_contains(roots, dir) then
      roots[#roots + 1] = dir
      refresh_badge()
      vim.notify("[emeth] Added workspace root: " .. dir .. " — applies on next session start", vim.log.levels.INFO)
    end
  end

  ---@param idx_or_path number|string
  local function remove(idx_or_path)
    if type(idx_or_path) == "number" then
      table.remove(roots, idx_or_path)
    else
      local path = vim.fn.fnamemodify(idx_or_path, ":p"):gsub("/$", "")
      for i, r in ipairs(roots) do
        if r == path then
          table.remove(roots, i)
          break
        end
      end
    end
    refresh_badge()
  end

  -- Suppress unused warning on `view`; reserved for future use (e.g. surfacing
  -- a buffer-rooted picker).
  local _ = view

  ---@type emeth.RootsHandle
  return {
    add = function(_, dir)
      add(dir)
    end,

    remove = function(_, idx_or_path)
      remove(idx_or_path)
    end,

    snapshot = function(_)
      return vim.deepcopy(roots)
    end,

    hydrate_from = function(_, entry)
      if entry and entry.additional_directories then
        roots = vim.deepcopy(entry.additional_directories)
        refresh_badge()
      end
    end,

    save_field = function(_)
      return #roots > 0 and vim.deepcopy(roots) or nil
    end,

    mention_handlers = function(self)
      return {
        workspace = {
          desc = "Add a workspace root directory (additionalDirectories)",
          handler = function()
            local function with_dir(dir)
              if dir and dir ~= "" then
                self:add(vim.fn.expand(dir))
              end
            end
            if vim.ui.input then
              vim.ui.input({
                prompt = "Add workspace root: ",
                completion = "dir",
                default = vim.fn.getcwd(),
              }, with_dir)
            else
              with_dir(vim.fn.input({
                prompt = "Add workspace root: ",
                completion = "dir",
                default = vim.fn.getcwd(),
              }))
            end
          end,
        },
        roots = {
          desc = "Manage workspace roots",
          handler = function()
            if #roots == 0 then
              vim.notify("[emeth] No workspace roots. Use @workspace to add one.", vim.log.levels.INFO)
              return
            end
            vim.ui.select(roots, {
              prompt = "Remove workspace root:",
              format_item = function(r)
                return vim.fn.fnamemodify(r, ":~")
              end,
            }, function(choice)
              if choice then
                self:remove(choice)
              end
            end)
          end,
        },
      }
    end,

    cleanup = function(_)
      Winbar.clear_badge("roots")
    end,
  }
end

return M
