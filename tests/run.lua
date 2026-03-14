--- Test runner — discovers and runs all test_*.lua files.
local test_dir = vim.fn.getcwd() .. "/tests"
local files = vim.fn.glob(test_dir .. "/test_*.lua", false, true)
table.sort(files)

for _, f in ipairs(files) do
  dofile(f)
end

local h = require("tests.helpers")
local failed = h.summary()
if failed > 0 then
  vim.cmd("cq!")
else
  vim.cmd("qa!")
end
