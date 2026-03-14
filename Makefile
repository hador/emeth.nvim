.PHONY: all test lint typecheck

all: lint test typecheck

test:
	nvim --headless -u tests/minimal_init.lua -c "lua dofile('tests/run.lua')"

lint:
	stylua --check lua/ plugin/
	luacheck lua/ plugin/

typecheck:
	lua-language-server --check . --checklevel=Warning
