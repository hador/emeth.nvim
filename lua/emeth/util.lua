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

---Format an ACP error, including .data when present.
---@param err table|nil
---@return string
function M.fmt_err(err)
  if not err then
    return "unknown error"
  end
  local msg = err.message or "unknown error"
  if err.data then
    local detail = type(err.data) == "table" and (err.data.details or vim.inspect(err.data)) or tostring(err.data)
    msg = msg .. ": " .. detail
  end
  return msg
end

return M
