SHELL := /bin/bash
CODECOMPANION_PATH ?= deps/codecompanion.nvim

.PHONY: format test deps

deps: deps/plenary.nvim deps/mini.nvim $(CODECOMPANION_PATH)
	@echo Pulling...

deps/plenary.nvim:
	@mkdir -p deps
	git clone --filter=blob:none https://github.com/nvim-lua/plenary.nvim.git $@

deps/mini.nvim:
	@mkdir -p deps
	git clone --filter=blob:none https://github.com/echasnovski/mini.nvim $@

deps/codecompanion.nvim:
	@mkdir -p deps
	git clone --filter=blob:none --branch v19.22.0 --single-branch https://github.com/olimorris/codecompanion.nvim.git $@

format:
	@echo Formatting...
	@stylua tests/ lua/ -f ./stylua.toml

test: deps
	@echo Testing...
	nvim --headless --noplugin -u ./scripts/minimal_init.lua -c "lua MiniTest.run()"

test_file: deps
	@echo Testing File...
	nvim --headless --noplugin -u ./scripts/minimal_init.lua -c "lua MiniTest.run_file('$(FILE)')"

all: deps format test
