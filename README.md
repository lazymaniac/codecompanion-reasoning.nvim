# CodeCompanion Reasoning Extension

Advanced reasoning tools extension for [CodeCompanion.nvim](https://github.com/olimorris/codecompanion.nvim).

This extension provides AI reasoning capabilities (Chain/Tree/Graph of Thought agents, Meta agent, Ask User), project knowledge integration, and session management with titles and history.

## Features

### Reasoning Agents

This extension provides three powerful reasoning agents, each specialized for different types of programming tasks:

- **Chain of Thoughts Agent**
  - Best for: Simple, linear tasks with a clear path forward
  - Examples: Small bug fixes, single-file changes, config updates
  - Features: Sequential reasoning with evidence and reflection
  - Workflow: Analysis → Action → Validation → Next Step

- **Tree of Thoughts Agent**
  - Best for: Tasks with multiple viable approaches
  - Examples: API design, refactoring strategies, debugging complex issues
  - Features: Explores multiple solution paths in parallel
  - Workflow: Generate alternatives → Compare outcomes → Choose best path

- **Graph of Thoughts Agent**
  - Best for: Cross-cutting concerns and multi-module changes
  - Examples: Features spanning services, repository-wide updates
  - Features: Maps relationships, merges insights across branches
  - Workflow: Map dependencies → Analyze impacts → Synthesize solution

- **Meta Agent**
  - Automatically selects the best reasoning agent for your task
  - Attaches essential companion tools (Ask User, Project Knowledge, Add Tools)
  - Guides the workflow: Analysis → Decision → Change → Validate

### Interactive Tools

- **Ask User**
  - Interactive decision-making for ambiguous choices
  - Required before destructive changes (deletions, rewrites)
  - Presents numbered options with explanations
  - Example: "Found failing tests. Should I: 1) Implement missing function, 2) Update tests?"

- **Project Knowledge**
  - Maintains `.codecompanion/project-knowledge.md` as source of truth
  - Auto-loads into new chats for consistent context
  - Records changes with `project_knowledge` tool
  - Example changelog: "Added user authentication to API endpoints (auth.js, routes.js)"

- **Tool Discovery**
  - Dynamic tool management via `add_tools`
  - Lists available capabilities
  - Adds specific tools to current chat
  - Example: `add_tools(action="list_tools")` then `add_tools(action="add_tool", tool_name="<tool_from_list>")`

### Session Management

- **History and Restoration**
  - Auto-saves chat sessions
  - Browse history with UI picker
  - Restore previous sessions
  - Project-scoped session views

- **Smart Titles**
  - Auto-generates descriptive titles
  - Updates based on conversation progress
  - Configurable refresh intervals
  - Example: "Debugging authentication middleware timeout"

### UI Features

- **Session Navigation**
  - Multiple picker backends:
    - telescope
    - fzf-lua
    - snacks
    - default
  - Fast session switching
  - Search and filter capabilities

- **Reasoning Visualization**
  - Visual representation of agent thought processes
  - Track decision trees and graph relationships
  - Monitor validation steps
  - Review synthesis points

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


## Usage

Once installed, the meta_agent is automatically available in CodeCompanion chats. The AI will use it when appropriate, or you can request specific reasoning approaches:

```
User: "Use chain of thought to analyze this complex function"
User: "Apply tree of thought reasoning to find the best refactoring approach"
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
