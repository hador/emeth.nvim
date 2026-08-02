.PHONY: all test lint typecheck bench

all: lint test typecheck

test:
	nvim --headless -u tests/minimal_init.lua -c "lua dofile('tests/run.lua')"

# Human-readable render timings. The scaling invariants behind these numbers are
# guarded (non-flakily) by tests/test_perf.lua, which runs as part of `test`.
bench:
	nvim --headless -u tests/minimal_init.lua -c "lua require('emeth').setup({}); require('tests.bench').run()" -c "qa!"

lint:
	stylua --check lua/ plugin/
	luacheck lua/ plugin/

typecheck:
	lua-language-server --check . --checklevel=Warning
