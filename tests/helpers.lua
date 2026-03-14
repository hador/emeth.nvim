--- Minimal test runner for headless Neovim.
-- Usage: nvim --headless -u tests/minimal_init.lua -c "lua require('tests.run')"

local M = {}
local passed, failed, errors = 0, 0, {}

function M.describe(name, fn)
  print("\n" .. name)
  fn()
end

function M.it(name, fn)
  local ok, err = pcall(fn)
  if ok then
    passed = passed + 1
    print("  ✓ " .. name)
  else
    failed = failed + 1
    errors[#errors + 1] = { name = name, err = err }
    print("  ✗ " .. name)
    print("    " .. tostring(err))
  end
end

function M.eq(expected, actual, msg)
  if not vim.deep_equal(expected, actual) then
    error((msg or "") .. "\n    expected: " .. vim.inspect(expected) .. "\n    actual:   " .. vim.inspect(actual), 2)
  end
end

function M.is_true(val, msg)
  if not val then
    error(msg or "expected truthy, got " .. tostring(val), 2)
  end
end

function M.is_nil(val, msg)
  if val ~= nil then
    error(msg or "expected nil, got " .. vim.inspect(val), 2)
  end
end

function M.summary()
  print("\n" .. string.rep("─", 40))
  print(string.format("%d passed, %d failed", passed, failed))
  if failed > 0 then
    print("\nFailures:")
    for _, e in ipairs(errors) do
      print("  " .. e.name .. ": " .. e.err)
    end
  end
  return failed
end

return M
