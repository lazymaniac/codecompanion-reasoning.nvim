SHELL := /bin/bash

.PHONY: format test deps

deps:
	mkdir -p deps
	cd deps && \
	git clone --depth 1 https://github.com/nvim-lua/plenary.nvim.git plenary.nvim && \
	git clone --depth 1 https://github.com/echasnovski/mini.nvim.git mini.nvim

format:
	stylua lua/ -f ./stylua.toml

test:
	nvim --headless --noplugin -u ./scripts/minimal_init.lua -c "lua MiniTest.run_file('tests/test_init.lua')"


all: deps format test
