--- Shared utilities for emeth.nvim

local M = {}

---Find the first non-emeth window (source editor window).
---@return number|nil win_id
function M.find_source_win()
  for _, win in ipairs(vim.api.nvim_list_wins()) do
    local buf = vim.api.nvim_win_get_buf(win)
    local name = vim.api.nvim_buf_get_name(buf)
    if not name:match("^emeth://") then
      return win
    end
  end
end

---A trailing debounce over a libuv timer. The first `call()` arms a one-shot
---timer for `ms`; further `call()`s while it is still pending are absorbed (the
---timer is NOT reset), so a burst of calls collapses into a single deferred run
---of `fn`. `fn` is invoked on the main loop (scheduled), so it may touch buffers
---and windows safely. After it fires the handle re-arms on the next `call()`.
---
---Callers keep their own pending state (the accumulated payload); this only owns
---the timer mechanics. `close()` must be called in teardown to free the timer.
---@param ms integer  debounce window in milliseconds
---@param fn fun()  runs once per burst, on the main loop
---@return { call: fun(), close: fun() }
function M.debounce(ms, fn)
  local timer = vim.uv.new_timer()
  return {
    call = function()
      if not timer:is_active() then
        timer:start(ms, 0, vim.schedule_wrap(fn))
      end
    end,
    close = function()
      if not timer:is_closing() then
        timer:stop()
        timer:close()
      end
    end,
  }
end

---Compact byte-size label: "812 B", "4.2 KB", "32.8 MB".
---@param n integer
---@return string
function M.fmt_size(n)
  if n < 1024 then
    return n .. " B"
  end
  if n < 1024 * 1024 then
    return string.format("%.1f KB", n / 1024)
  end
  return string.format("%.1f MB", n / 1048576)
end

---Mix two "#rrggbb" colours: `t` = 0 gives `a`, 1 gives `b`. Malformed
---components read as 0 and the result is clamped, so it never errors.
---@param a string
---@param b string
---@param t number
---@return string
function M.blend(a, b, t)
  local ar, ag, ab = tonumber(a:sub(2, 3), 16) or 0, tonumber(a:sub(4, 5), 16) or 0, tonumber(a:sub(6, 7), 16) or 0
  local br, bg, bb = tonumber(b:sub(2, 3), 16) or 0, tonumber(b:sub(4, 5), 16) or 0, tonumber(b:sub(6, 7), 16) or 0
  local function clamp(v)
    return math.max(0, math.min(255, math.floor(v)))
  end
  return string.format("#%02x%02x%02x", clamp(ar + (br - ar) * t), clamp(ag + (bg - ag) * t), clamp(ab + (bb - ab) * t))
end

---Decode a JSON file, or nil when it is missing, unreadable or not a JSON
---object/array.
---@param path string
---@return table|nil
function M.read_json(path)
  if vim.fn.filereadable(path) ~= 1 then
    return nil
  end
  local ok, data = pcall(function()
    return vim.json.decode(table.concat(vim.fn.readfile(path), "\n"))
  end)
  return ok and type(data) == "table" and data or nil
end

---Format an ACP error, including .data when present. A bare string (some
---callbacks pass one) is returned as is.
---@param err table|string|nil
---@return string
function M.fmt_err(err)
  if not err then
    return "unknown error"
  end
  if type(err) ~= "table" then
    return tostring(err)
  end
  local msg = err.message or "unknown error"
  if err.data then
    local detail = type(err.data) == "table" and (err.data.details or vim.inspect(err.data)) or tostring(err.data)
    msg = msg .. ": " .. detail
  end
  return msg
end

return M
