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
- Enhanced session optimizer with resumption-focused prompt structure. Changed from 5-section comprehensive summary to 4-section resumption-optimized format: Current Focus (40% word budget), User Context (25%), Next Steps (25%), Resume With (10%). Default word target increased from 300 to 500 words to support better conversation continuation. (sources: lua/codecompanion/_extensions/reasoning/helpers/session_optimizer.lua, lua/codecompanion/_extensions/reasoning/config.lua)
- Completed comprehensive enhancement of session optimizer and project knowledge tools. Session optimizer now uses 4-section resumption-focused structure (Current Focus, User Context, Next Steps, Resume With) with 500-word default. Project knowledge tool now categorizes facts into Architecture, Workflow, Business Logic, and Constraints with enhanced validation and templates. Updated all tests, documentation, and configuration. (sources: lua/codecompanion/_extensions/reasoning/tools/project_knowledge.lua, lua/codecompanion/_extensions/reasoning/helpers/session_optimizer.lua, lua/codecompanion/_extensions/reasoning/config.lua, tests/test_project_knowledge_enhanced.lua, tests/test_session_optimizer_enhanced.lua, README.md)

## Constraints Facts
- MiniTest setup: Framework is initialized by minimal_init.lua - test files should NOT call helpers.setup() (non-existent function). Use MiniTest.new_set() pattern for test registration. (sources: scripts/minimal_init.lua, tests/test_init.lua, tests/test_project_knowledge_enhanced.lua)
- Session compaction title prefix bug fix: The original logic `compacted.title or 'Untitled'` only handled nil titles, not empty strings or whitespace-only titles. Fixed to properly check for empty/whitespace titles using vim.trim() before applying "[compacted]" prefix. (sources: lua/codecompanion/_extensions/reasoning/helpers/session_optimizer.lua)

## Workflow Facts
- Session browser duplicate functionality: Press 'y' in session picker UI to duplicate sessions. Creates copy with "(Copy)" suffix, new save_id, updated timestamps, and fresh metadata. (sources: lua/codecompanion/_extensions/reasoning/ui/session_picker.lua, lua/codecompanion/_extensions/reasoning/ui/session_manager_ui.lua)
- Session compaction automatically adds "[compacted]" prefix to chat titles. Happens in SessionOptimizer.compact_session for both command (CodeCompanionOptimizeSession) and UI (session picker 'c' key) optimization workflows. Prevents duplicate prefixes if already present. (sources: lua/codecompanion/_extensions/reasoning/helpers/session_optimizer.lua, lua/codecompanion/_extensions/reasoning/commands.lua, lua/codecompanion/_extensions/reasoning/ui/session_picker.lua, tests/test_compacted_title_prefix.lua)
