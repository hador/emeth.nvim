--- File mentions in prompt text: `@path`, `@path:L12` or `@path:L12-L20`.
---
--- Context lives in the prompt the user typed: the `@` picker inserts these tokens,
--- `send_selection` writes one above the code it pastes, and on submit every token
--- naming a readable file goes to the agent as a `resource_link` for that prompt
--- only. Nothing is attached that isn't visible in the input, and nothing rides
--- along on later turns.

local M = {}

---@class emeth.Mention
---@field path string  absolute path
---@field token string  the text after `@`, as typed

---Characters that end a sentence rather than a path: `see @a.lua, then` names `a.lua`.
local TRAILING = "[%.,;:!%?%)%]}'\"`]+$"

---The token text for `path` (relative to `cwd` when under it, else `~`-relative or absolute), with an
---optional line or line range.
---@param path string
---@param first? integer  1-based first line
---@param last? integer  1-based last line (omit, or equal to first, for one line)
---@param cwd? string  default: getcwd()
---@return string token  including the leading `@`
function M.format(path, first, last, cwd)
  cwd = cwd or vim.fn.getcwd()
  local abs = vim.fn.fnamemodify(path, ":p")
  local prefix = cwd:sub(-1) == "/" and cwd or (cwd .. "/")
  local shown = abs:sub(1, #prefix) == prefix and abs:sub(#prefix + 1) or vim.fn.fnamemodify(abs, ":~")
  local token = "@" .. shown
  if first then
    token = token .. ":L" .. first
    if last and last ~= first then
      token = token .. "-L" .. last
    end
  end
  return token
end

---Resolve one token (the text after `@`) to an absolute readable file, or nil.
---@param token string
---@param cwd string
---@return string|nil
local function resolve(token, cwd)
  local path = token:gsub(":L?%d+%-?L?%d*$", "")
  if path == "" then
    return nil
  end
  if path:sub(1, 1) == "~" then
    path = vim.fn.expand(path)
  elseif path:sub(1, 1) ~= "/" then
    path = cwd .. "/" .. path
  end
  path = vim.fn.fnamemodify(path, ":p")
  if vim.fn.filereadable(path) == 1 then
    return path
  end
  return nil
end

---Every file mention in `text`, in order of first appearance, one per file. A token must start
---the text or follow whitespace or an opening bracket or quote (so `user@host` is not one), and
---must name a readable file; anything else is left as plain text.
---@param text string
---@param cwd? string  base for relative paths (default: getcwd())
---@return emeth.Mention[]
function M.parse(text, cwd)
  cwd = cwd or vim.fn.getcwd()
  local found, seen = {}, {}
  for token in (" " .. text):gmatch("[%s%(%[{'\"`]@([^%s]+)") do
    token = token:gsub(TRAILING, "")
    local path = resolve(token, cwd)
    if path and not seen[path] then
      seen[path] = true
      found[#found + 1] = { path = path, token = token }
    end
  end
  return found
end

return M
