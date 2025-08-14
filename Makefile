SHELL := /bin/bash

.PHONY: format test deps

deps: deps/plenary.nvim deps/nvim-treesitter deps/mini.nvim deps/panvimdoc
	@echo Pulling...

deps/plenary.nvim:
	@mkdir -p deps
	git clone --filter=blob:none https://github.com/nvim-lua/plenary.nvim.git $@

deps/nvim-treesitter:
	@mkdir -p deps
	git clone --filter=blob:none https://github.com/nvim-treesitter/nvim-treesitter.git $@

deps/mini.nvim:
	@mkdir -p deps
	git clone --filter=blob:none https://github.com/echasnovski/mini.nvim $@

deps/panvimdoc:
	@mkdir -p deps
	git clone --filter=blob:none https://github.com/kdheepak/panvimdoc $@

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
