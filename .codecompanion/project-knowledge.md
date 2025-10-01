# CodeCompanion Reasoning

## Project Overview

A Neovim plugin that extends [CodeCompanion.nvim](https://github.com/olimorris/codecompanion.nvim) with advanced AI reasoning capabilities. Provides Chain of Thought, Tree of Thought, and Graph of Thought reasoning agents along with interactive user consultation tools for enhanced AI-assisted coding.

### Tech Stack
- **Language**: Lua (Neovim 0.9.0+)
- **Dependencies**: CodeCompanion.nvim >= 17.13.0, plenary.nvim
- **Testing**: MiniTest framework from mini.nvim
- **Code Style**: Stylua with 2-space indents, 120-char width
- **Build**: Makefile-based workflow

### How to Run/Test
```bash
make deps      # Clone test dependencies into deps/
make test      # Run all tests with MiniTest
make format    # Format code with stylua
make all       # deps + format + test
```

## Directory Structure

- **`lua/`**: Source code
  - `codecompanion-reasoning.lua` - Main plugin interface and setup
  - `codecompanion/_extensions/reasoning/` - Extension implementation
    - `tools/` - Reasoning agents and interactive tools
    - `helpers/` - Core reasoning engines and utilities
    - `ui/` - User interface components
- **`plugin/`**: Neovim plugin loader (`codecompanion-reasoning.lua`)
- **`tests/`**: MiniTest specifications
  - `test_*.lua` - Component tests
  - `reasoning/` - Individual reasoning engine tests
  - `helpers.lua` - Test utilities
- **`scripts/`**: Development scripts
  - `minimal_init.lua` - Headless test environment setup
- **`prompts/`**: AI prompt templates (development only, not shipped)
- **`deps/`**: Test dependencies (git-ignored)
- **`Makefile`**, **`stylua.toml`**: Development tooling

### Key Features
- **Reasoning Agents**: Chain of Thought, Tree of Thought, Graph of Thought
- **Interactive Tools**: User consultation, project context management
- **Chat History**: Auto-save/resume functionality for CodeCompanion sessions
- **Meta Agent**: Intelligent algorithm selection
- **Tool Discovery**: Dynamic capability addition to chats

## Key Facts

- Reasoning agents (Chain, Tree, Graph) live under `lua/codecompanion/_extensions/reasoning/tools/` and are auto-attached via `meta_agent` for new chats (sources: `lua/codecompanion/_extensions/reasoning/tools/meta_agent.lua`).
- The `ask_user` workflow enforces proactive clarification in the system prompt and question builder (sources: `lua/codecompanion/_extensions/reasoning/helpers/system_prompt.lua`, `lua/codecompanion/_extensions/reasoning/tools/ask_user.lua`).
- Headless tests run through MiniTest using `scripts/minimal_init.lua`; dependencies such as plenary.nvim and mini.nvim are cloned into `deps/` via `make deps` (sources: `scripts/minimal_init.lua`, `Makefile`).
- Session history saves to `vim.fn.stdpath('data') .. '/codecompanion-reasoning/sessions'` with configurable limits and titles (sources: `lua/codecompanion/_extensions/reasoning/config.lua`).
- Formatting uses Stylua with settings from `stylua.toml`, executed via `make format` (sources: `Makefile`, `stylua.toml`).
