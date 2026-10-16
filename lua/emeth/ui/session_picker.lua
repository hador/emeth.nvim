--- Cross-directory session picker — "where was I?" across every project.
---
--- The per-directory history (`:EmethHistory`) answers "what did I do *here*".
--- This answers the harder one: you remember the conversation, not the folder it
--- lived in. The local index is global (every session, with the cwd it ran in),
--- so the list is built from it rather than from the agent's `session/list`,
--- which is scoped to one cwd and needs a live connection.
---
--- Sessions whose directory has since been deleted are dropped, not dimmed:
--- resuming one cannot work (the agent is handed that cwd), and in a real index
--- they were 41% of entries — mostly transient per-review workspaces. The count
--- is reported so they aren't hidden silently.

local Sessions = require("emeth.sessions")

local M = {}

---Seconds between two `os.date("!%Y-%m-%dT%H:%M:%SZ")` stamps.
---
---Both sides are parsed with `os.time`, which reads the table as *local* time.
---That is wrong for a UTC stamp, but identically wrong for both, so the bias
---cancels in the subtraction — which avoids needing a timezone offset at all.
---@param iso string
---@param now_iso string
---@return integer|nil
local function seconds_since(iso, now_iso)
  local function epoch(s)
    if type(s) ~= "string" then
      return nil
    end
    local y, mo, d, h, mi, sec = s:match("(%d+)-(%d+)-(%d+)T(%d+):(%d+):(%d+)Z")
    if not y then
      return nil
    end
    -- `or 0` only to satisfy the type checker: the pattern already matched digits.
    return os.time({
      year = tonumber(y) or 0,
      month = tonumber(mo) or 0,
      day = tonumber(d) or 0,
      hour = tonumber(h) or 0,
      min = tonumber(mi) or 0,
      sec = tonumber(sec) or 0,
      isdst = false,
    })
  end
  local a, b = epoch(now_iso), epoch(iso)
  if not a or not b then
    return nil
  end
  return a - b
end

---Coarse age, in the largest unit that still reads as a number.
---@param iso string  UTC stamp from the index
---@param now_iso? string  injectable for tests
---@return string
function M.ago(iso, now_iso)
  local now = now_iso or os.date("!%Y-%m-%dT%H:%M:%SZ") --[[@as string]]
  local diff = seconds_since(iso, now)
  if not diff then
    return "?"
  end
  if diff < 0 then
    diff = 0
  end
  local units = {
    { 60, 1, "s" },
    { 3600, 60, "m" },
    { 86400, 3600, "h" },
    { 604800, 86400, "d" },
    { 2592000, 604800, "w" },
    { math.huge, 2592000, "mo" },
  }
  for _, u in ipairs(units) do
    if diff < u[1] then
      return ("%d%s"):format(math.floor(diff / u[2]), u[3])
    end
  end
  return "?"
end

local TITLE_MAX = 60
local DIR_MAX = 30

---Trim to `max` characters, adding an ellipsis when anything was cut.
---@param s string
---@param max integer
---@return string
local function clamp(s, max)
  -- Byte length bounds character length, so the cheap test gates the vim call.
  if #s <= max or vim.fn.strchars(s) <= max then
    return s
  end
  return vim.fn.strcharpart(s, 0, max) .. "…"
end

---A directory short enough for a one-line label but still identifying.
---
---A bare basename is ambiguous in a Brazil-shaped tree, where a dozen projects
---all end in `src` — so long paths keep their parent too. `src` itself is skipped
---when it would *be* that parent: for `.../FTV/FOS/src/FireTvLauncher` the useful
---pair is `FOS/FireTvLauncher`, not `src/FireTvLauncher`.
---@param dir string
---@return string
function M.short_dir(dir)
  if type(dir) ~= "string" or dir == "" then
    return "?"
  end
  local home = vim.fn.expand("~")
  if dir == home then
    return "~"
  end
  local tilde = vim.fn.fnamemodify(dir, ":~")
  if #tilde <= DIR_MAX then
    return tilde
  end
  local base = vim.fn.fnamemodify(dir, ":t")
  local head = vim.fn.fnamemodify(dir, ":h")
  local parent = vim.fn.fnamemodify(head, ":t")
  if parent == "src" then
    parent = vim.fn.fnamemodify(head, ":h:t")
  end
  return parent ~= "" and (parent .. "/" .. base) or base
end

-- A non-resumable session used to be dropped from the list and only counted.
-- That hid exactly the entries a user most wants to act on (prune, or notice a
-- workspace is gone), so they are now shown with a badge instead. `stale` is
-- claude-only: on disk now, but past its retention window and due to be pruned
-- on claude's next launch.
local BADGE = {
  stale = { text = "stale", mark = "⚠", hl = "WarningMsg" },
  gone = { text = "gone", mark = "✖", hl = "DiagnosticError" },
}

---Build the picker rows: most recent first. Nothing is dropped; each row carries
---its validity verdict so the UI can badge (and later act on) dead entries.
---@param entries table[]  raw index entries
---@param now_iso? string  injectable for tests
---@param verdicts? table<string, "valid"|"stale"|"gone">  from validity.check_all; missing ⇒ valid
---@return table[] items
function M.items(entries, now_iso, verdicts)
  verdicts = verdicts or {}

  -- Resolve a fork's parent to a readable name for the lineage marker.
  local title_by_id = {}
  for _, e in ipairs(entries) do
    title_by_id[e.session_id] = e.title
  end

  local items = {}
  for _, e in ipairs(entries) do
    -- Titles need clamping, not just wrapping: most are the first prompt
    -- (capped at 80 bytes), but an agent-sent one reached 201 characters in a
    -- real index, which buries the directory and age that follow it.
    local title = clamp(e.title or e.session_id:sub(1, 8), TITLE_MAX)
    local short = M.short_dir(e.cwd)
    local age = M.ago(e.updated_at or e.created_at, now_iso)
    local validity = verdicts[e.session_id] or "valid"

    -- A forked session reads as unrelated otherwise; name its parent (or just
    -- flag it as a fork when the parent isn't in the index).
    local fork
    if e.forked_from then
      local parent = title_by_id[e.forked_from]
      fork = parent and clamp(parent, 30) or "fork"
    end

    local label = ("%s  ·  %s  ·  %s"):format(title, short, age)
    if fork then
      label = label .. "  ·  ⑂ " .. fork
    end
    local badge = BADGE[validity]
    if badge then
      label = label .. ("  ·  %s %s"):format(badge.mark, badge.text)
    end

    items[#items + 1] = {
      entry = e,
      validity = validity,
      title = title,
      short = short,
      age = age,
      fork = fork,
      label = label,
      -- the matcher filters on this; include dir so "project" narrows too.
      text = (e.title or e.session_id) .. " " .. short,
    }
  end
  return items
end

---Count non-valid rows for the picker title.
---@param items table[]
---@return integer stale, integer gone
local function count_bad(items)
  local stale, gone = 0, 0
  for _, it in ipairs(items) do
    if it.validity == "stale" then
      stale = stale + 1
    elseif it.validity == "gone" then
      gone = gone + 1
    end
  end
  return stale, gone
end

---Multi-line detail for the preview pane: everything the one-line row can't fit.
---@param item table
---@return string text, string ft
function M.preview_text(item)
  local e = item.entry
  local lines = {
    "# " .. (e.title or "(untitled)"),
    "",
    "- **provider:** " .. (e.provider or "?"),
    "- **directory:** " .. (e.cwd or "?"),
    "- **last used:** " .. M.ago(e.updated_at or e.created_at) .. " ago",
    "- **session id:** `" .. e.session_id .. "`",
  }
  if item.fork then
    lines[#lines + 1] = "- **forked from:** " .. item.fork
  end
  local detail = ({
    valid = "resumable",
    stale = "on disk but past the retention window — claude will prune it on its next launch",
    gone = "not resumable — nothing left to load",
  })[item.validity]
  lines[#lines + 1] = "- **status:** " .. item.validity .. " (" .. detail .. ")"
  return table.concat(lines, "\n"), "markdown"
end

---Partition an index into the entries to keep and the ids to prune. A `gone`
---session cannot be resumed, so a sync removes it; `stale` is kept (it is still
---loadable right now). Pure so the sync contract is testable without a picker.
---@param entries table[]
---@param verdicts table<string, "valid"|"stale"|"gone">
---@return table[] kept, string[] removed_ids
function M.prune_gone(entries, verdicts)
  local kept, removed = {}, {}
  for _, e in ipairs(entries) do
    if verdicts[e.session_id] == "gone" then
      removed[#removed + 1] = e.session_id
    else
      kept[#kept + 1] = e
    end
  end
  return kept, removed
end

---Title with a trailing `(N stale, M gone)` summary when any row is not valid.
---@param items table[]
---@return string
local function picker_title(items)
  local stale, gone = count_bad(items)
  local suffix = {}
  if stale > 0 then
    suffix[#suffix + 1] = stale .. " stale"
  end
  if gone > 0 then
    suffix[#suffix + 1] = gone .. " gone"
  end
  return #suffix > 0 and ("Resume session (" .. table.concat(suffix, ", ") .. ")") or "Resume session"
end

-- Row actions, shared by the input and list windows. `desc` drives both the `?`
-- help and the footer hint bar. Normal-mode only (the input is insert mode for
-- type-to-filter); `<CR>` resumes and is just relabelled here.
local ACTION_KEYS = {
  ["<CR>"] = { "confirm", mode = { "i", "n" }, desc = "resume" },
  ["r"] = { "emeth_rename", mode = { "n" }, desc = "rename" },
  ["d"] = { "emeth_delete", mode = { "n" }, desc = "forget (emeth only)" },
  ["D"] = { "emeth_destroy", mode = { "n" }, desc = "delete (agent + emeth)" },
  ["S"] = { "emeth_sync", mode = { "n" }, desc = "sync (prune dead)" },
}

---Snacks-native picker: wide, columned, with a preview pane, validity badges, and
---per-row actions. `state` is mutable — the actions edit the index and the
---closure's `entries`/`verdicts`, then `picker:refresh()` re-runs the finder.
---@param state { entries: table[], verdicts: table, on_destroy?: fun(entry: table): boolean, string? }
---@param on_pick fun(entry: table)
local function pick_snacks(state, on_pick)
  local Snacks = require("snacks")
  local Validity = require("emeth.validity")
  local align = Snacks.picker.util.align

  -- Rebuilt from current state each finder run, so actions show up immediately.
  local function finder()
    local items = M.items(state.entries, nil, state.verdicts)
    local fitems = {}
    for i, it in ipairs(items) do
      local text, ft = M.preview_text(it)
      fitems[#fitems + 1] = {
        idx = i,
        text = it.text,
        item = it,
        entry = it.entry,
        preview = { text = text, ft = ft },
      }
    end
    return fitems
  end

  Snacks.picker.pick({
    source = "emeth_sessions",
    title = picker_title(M.items(state.entries, nil, state.verdicts)),
    finder = finder,
    preview = "preview",
    format = function(fi)
      local it = fi.item
      local ret = {}
      ret[#ret + 1] = { align(it.title, TITLE_MAX + 1), it.validity == "gone" and "Comment" or nil }
      ret[#ret + 1] = { "  " }
      ret[#ret + 1] = { align(it.short, DIR_MAX), "SnacksPickerDir" }
      ret[#ret + 1] = { "  " }
      ret[#ret + 1] = { align(it.age, 5), "SnacksPickerTime" }
      if it.fork then
        ret[#ret + 1] = { "  ⑂ " .. it.fork, "SnacksPickerSpecial" }
      end
      local badge = BADGE[it.validity]
      if badge then
        ret[#ret + 1] = { "  " .. badge.mark .. " " .. badge.text, badge.hl }
      end
      return ret
    end,
    confirm = function(picker, fi)
      picker:close()
      if fi then
        on_pick(fi.entry)
      end
    end,
    actions = {
      emeth_rename = function(picker)
        local fi = picker:current()
        if not fi then
          return
        end
        local e = fi.entry
        vim.ui.input({ prompt = "Rename session: ", default = e.title or "" }, function(input)
          if not input or input == "" then
            return
          end
          Sessions.update_title(e.session_id, input)
          e.title = input -- same table instance the finder rebuilds from
          picker:refresh()
        end)
      end,
      emeth_delete = function(picker)
        local fi = picker:current()
        if not fi then
          return
        end
        local e = fi.entry
        local label = e.title or e.session_id:sub(1, 8)
        local ok = vim.fn.confirm(("Forget '%s' from emeth history?"):format(label), "&Yes\n&No", 2) == 1
        if not ok then
          return
        end
        Sessions.remove(e.session_id)
        state.entries = M.prune_gone(state.entries, { [e.session_id] = "gone" })
        picker:refresh()
      end,
      emeth_destroy = function(picker)
        local fi = picker:current()
        if not fi or not state.on_destroy then
          return
        end
        local e = fi.entry
        local label = e.title or e.session_id:sub(1, 8)
        local ok = vim.fn.confirm(
          ("Delete '%s' everywhere (emeth index + agent history)?\nThis cannot be undone."):format(label),
          "&Yes\n&No",
          2
        ) == 1
        if not ok then
          return
        end
        local done, reason = state.on_destroy(e)
        if not done then
          vim.notify("[emeth] " .. (reason or "could not delete"), vim.log.levels.WARN)
          return
        end
        state.entries = M.prune_gone(state.entries, { [e.session_id] = "gone" })
        picker:refresh()
      end,
      emeth_sync = function(picker)
        state.verdicts = Validity.check_all(state.entries)
        local kept, removed = M.prune_gone(state.entries, state.verdicts)
        for _, id in ipairs(removed) do
          Sessions.remove(id)
        end
        state.entries = kept
        picker:refresh()
        vim.notify(
          ("[emeth] sync: pruned %d dead session%s"):format(#removed, #removed == 1 and "" or "s"),
          vim.log.levels.INFO
        )
      end,
    },
    -- Actions are normal-mode only (the input is insert for type-to-filter). The
    -- `desc`s surface in the `?` help and in the footer hint bar below.
    win = {
      input = {
        keys = ACTION_KEYS,
        -- Always-visible hint bar so the keys don't have to be guessed.
        footer_keys = { "<CR>", "r", "d", "D", "S" },
      },
      list = {
        keys = ACTION_KEYS,
        footer_keys = { "<CR>", "r", "d", "D", "S" },
      },
    },
  })
end

---Prompt for a session across all directories.
---@param on_pick fun(entry: table)
---@param opts? { on_destroy?: fun(entry: table): boolean, string? }
function M.open(on_pick, opts)
  opts = opts or {}
  local entries = Sessions.list_all()
  local verdicts = require("emeth.validity").check_all(entries)
  if #entries == 0 then
    vim.notify("[emeth] No sessions recorded yet", vim.log.levels.INFO)
    return
  end

  if pcall(require, "snacks.picker") then
    pick_snacks({ entries = entries, verdicts = verdicts, on_destroy = opts.on_destroy }, on_pick)
    return
  end

  -- Fallback: no snacks. vim.ui.select can't bind per-row keys, so rename/delete/
  -- sync are unavailable here — resume only, badge folded into the one-line label.
  local items = M.items(entries, nil, verdicts)
  vim.ui.select(items, {
    prompt = picker_title(items) .. ":",
    format_item = function(item)
      return item.label
    end,
  }, function(choice)
    if choice then
      on_pick(choice.entry)
    end
  end)
end

return M
