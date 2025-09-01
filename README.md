# CodeCompanion Reasoning Extension

Advanced reasoning tools extension for [CodeCompanion.nvim](https://github.com/olimorris/codecompanion.nvim).

This extension provides AI reasoning capabilities (Chain/Tree/Graph of Thought agents, Meta agent, Ask User), project knowledge integration, and session management with titles and history.

## Features

- **Reasoning Agents**: Chain, Tree, and Graph of Thoughts; plus a **Meta Agent** that chooses the best approach.
- **Ask User**: Interactive decision-making tool for ambiguous choices or confirmations.
- **Project Knowledge**:
  - Auto-loads context from `.codecompanion/project-knowledge.md` into new chats.
  - `initialize_project_knowledge`: saves a comprehensive knowledge file provided by the model.
  - `project_knowledge`: proposes changelog entries and updates the knowledge file with user approval.
- **Session Management**:
  - Auto-save sessions, browse history, restore last session, and project-scoped views.
  - Title generation on first message and periodic refresh (configurable).
  - Optional startup dialog to continue last chat.
- **Tool Discovery**: `add_tools` lists available tools and adds them to the current chat on demand.
- **UI**:
  - Session picker UI; picker backends: `telescope`, `fzf-lua`, `snacks`, or default.
  - Reasoning visualization for agents.

## Requirements

- [CodeCompanion.nvim](https://github.com/olimorris/codecompanion.nvim) >= 17.13.0
- Neovim >= 0.9.0

## Installation

### Using [lazy.nvim](https://github.com/folke/lazy.nvim)

```lua
{
  "lazymaniac/codecompanion-reasoning.nvim",
  dependencies = {
    "olimorris/codecompanion.nvim",
  },
  config = function()
    require("codecompanion-reasoning").setup({
      chat_history = {
        auto_save = true,
        auto_load_last_session = false,
        auto_generate_title = true,
        sessions_dir = vim.fn.stdpath('data') .. '/codecompanion-reasoning/sessions',
        max_sessions = 100,
        enable_commands = true,
        picker = 'auto', -- 'telescope' | 'fzf-lua' | 'snacks' | 'default' | 'auto'
        continue_last_chat = false,
        title_generation_opts = {
          adapter = nil,
          model = nil,
          refresh_every_n_prompts = 3,
          max_refreshes = 3,
          format_title = nil,
        },
      },
    })
  end,
}
```

### Using [packer.nvim](https://github.com/wbthomason/packer.nvim)

```lua
use {
  "lazymaniac/codecompanion-reasoning.nvim",
  requires = { "olimorris/codecompanion.nvim" },
  config = function()
    require("codecompanion-reasoning").setup()
  end,
}
```

## Configuration

### Basic Setup

```lua
require("codecompanion-reasoning").setup({
  enabled = true,
})
```

### Integration with CodeCompanion

The extension automatically registers with CodeCompanion when installed. To manually register:

```lua
require("codecompanion").setup({
  extensions = {
    reasoning = { callback = 'codecompanion._extensions.reasoning', opts = { enabled = true } },
  },
})
```

## Available Tools

### Chain of Thoughts Agent

Sequential reasoning tool that breaks down complex problems into logical steps.

**Use cases:**

- Complex algorithmic problems
- Step-by-step debugging
- Methodical code refactoring

### Tree of Thoughts Agent

Explores multiple solution paths simultaneously, evaluating different approaches.

**Use cases:**

- Design decisions with multiple viable options
- Performance optimization with trade-offs
- Architecture planning

### Graph of Thoughts Agent

Network-based reasoning that connects related concepts and explores relationships.

**Use cases:**

- System integration problems
- Dependency analysis
- Complex refactoring across modules

### Ask User Tool

Interactive tool that consults the user when multiple valid approaches exist.

**Features:**

- Clear question formatting
- Multiple choice options
- Context explanation
- Custom response handling

**Example usage:**

```
The AI will automatically use this tool when it encounters:
- Multiple valid solutions
- Destructive operations requiring confirmation
- Architectural decisions
- Ambiguous requirements
```

### Meta Agent

Automatically selects the most appropriate reasoning agent based on the problem type.

### Tool Discovery

Dynamically discovers and suggests relevant tools for the current task.

### Project Knowledge

- `initialize_project_knowledge`: Create or overwrite `.codecompanion/project-knowledge.md` with provided markdown.
- `project_knowledge`: Propose and store changelog updates (with optional file list). This tool only updates the file; it does not load context.

Behavior:

- On chat start, if the knowledge file is missing, you will be prompted to initialize it. The request is auto-submitted to the model.
- Context is auto-injected by reading `.codecompanion/project-knowledge.md` directly and adding it as a hidden system message.

Examples:

- Initialize (auto or manual):
  - Start a new chat; if missing, you’ll get an initialization prompt which submits automatically.
  - Or run `:CodeCompanionInitProjectKnowledge` to queue the request in your current chat.
  - You can also ask: “Initialize project knowledge for this repo with overview, directory structure, empty changelog, and empty current features.” The AI will draft content and call the tool.
- Update changelog:
  - Ask: “Log today’s change: added auto-submit on initialization and simplified project root to cwd (files: helpers/chat_hooks.lua, tools/initialize_project_knowledge.lua, tools/project_knowledge.lua, reasoning/commands.lua).”
  - The tool will show an approval dialog and append an entry under “Changelog”.

## Usage

Once installed, the reasoning tools are automatically available in CodeCompanion chats. The AI will use them when appropriate, or you can request specific reasoning approaches:

```
User: "Use chain of thought to analyze this complex function"
User: "Apply tree of thought reasoning to find the best refactoring approach"
User: "Use the ask user tool to help me decide between these options"
User: "Initialize project knowledge for this repo"
```

### Commands

- `:CodeCompanionChatHistory`: Browse all sessions.
- `:CodeCompanionChatLast`: Restore the most recent session.
- `:CodeCompanionProjectHistory`: Browse sessions scoped to current cwd.
- `:CodeCompanionProjectKnowledge`: Open `.codecompanion/project-knowledge.md` if present.
- `:CodeCompanionInitProjectKnowledge`: Queue instructions to initialize project knowledge in the current chat.
- `:CodeCompanionRefreshSessionTitles`: Regenerate session titles in the background.

## Development

### Testing

```bash
make deps  # Install test dependencies
make test  # Run tests
```

### Formatting

```bash
make format  # Format code with stylua
```

## Contributing

1. Fork the repository
2. Create a feature branch
3. Make your changes
4. Add tests for new functionality
5. Run `make format` and `make test`
6. Submit a pull request

## License

MIT License - see LICENSE file for details.

## Credits

@olimorris for such a great plugin

---

Notes

- Project root is taken from Neovim `cwd` throughout the extension to match user workflow.
