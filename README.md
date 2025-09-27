# CodeCompanion Reasoning Extension

An add‑on for [CodeCompanion.nvim](https://github.com/olimorris/codecompanion.nvim) that gives your chats structured “reasoning agents”, interactive tools, and practical session history.

It helps LLM work in small, safe, and verifiable steps: pick an agent that fits the job, attach only the tools you need, and keep a searchable record of your sessions with useful titles.

## Goals
- Human id the loop - make work with LLMs more interactive
- Fully automatic - no need to manually add tools when needed
- Automatic Project Context initialization (conventions, how to run, test, directory structure...)
- Integrated session history browser with automatic naming
- Grow with project - keep track of recent changes
- At least partially usable with open source models
- Token efficient

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

- **List Files**
  - Fast file listing (respects `.gitignore` when in a Git repo)
  - Filter by directory and glob (e.g., `dir="lua"`, `glob="**/*.lua"`)
  - Great for quick repo orientation inside the chat

- **Project Knowledge (Initializer)**
  - `initialize_project_knowledge` bootstraps a `.codecompanion/project-knowledge.md` guide for your repo
  - Captures conventions, how to run/test, and key directories so the model has reliable context

### Session Management

- **Functionality-Specific Adapters**
  - Configure different adapters/models per functionality
  - Session optimization with fast local models (e.g., Ollama)
  - Title generation with creative models (e.g., GPT-4)
  - Cost and quality optimization per use case

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
  - Command: `:CodeCompanionRefreshSessionTitles` regenerates titles for saved sessions

### UI Features

- **Session Navigation**
  - Built-in picker for browsing sessions
  - Fast session switching
  - Search and filter capabilities

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
      functionality_adapters = {
        session_optimizer = {
          adapter = nil, -- e.g., "ollama", defaults to session adapter
          model = nil,   -- e.g., "gpt-oss", defaults to session model
        },
        title_generator = {
          adapter = nil, -- e.g., "openai" 
          model = nil,   -- e.g., "gpt-4"
        },
        -- meta_agent and reasoning_agents also available
      },
      chat_history = {
        auto_save = true,
        auto_load_last_session = true,
        auto_generate_title = true,
        sessions_dir = vim.fn.stdpath('data') .. '/codecompanion-reasoning/sessions',
        max_sessions = 100,
        enable_commands = true,
        picker = 'default', -- only 'default' is supported ('auto' remains an alias)
        continue_last_chat = true,
        title_generation_opts = {
          adapter = nil,   -- override to force a specific adapter for title generation
          model = nil,     -- override to force a specific model for title generation
          refresh_every_n_prompts = 3,
          format_title = nil, -- optional function to post-process the generated title
        },
        keymaps = {
          rename = { n = 'r', i = '<M-r>' },
          delete = { n = 'd', i = '<M-d>' },
          duplicate = { n = '<C-y>', i = '<C-y>' },
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

### Functionality-Specific Adapters

You can configure different adapters and models for each functionality, allowing you to optimize for different use cases:

```lua
require("codecompanion-reasoning").setup({
  functionality_adapters = {
    session_optimizer = {
      adapter = "ollama",        -- Use Ollama for session optimization
      model = "gpt-oss",         -- With a lightweight model
    },
    meta_agent = {
      adapter = "ollama",        -- Meta agent selection
      model = "llama3",          -- Can use a different model
    },
    reasoning_agents = {
      adapter = "anthropic",     -- Reasoning agents don't make LLM calls
      model = "claude-3-sonnet", -- But config here for future features
    },
    title_generator = {
      adapter = "openai",        -- Use OpenAI for title generation
      model = "gpt-4",           -- With GPT-4 for better titles
    },
  },
  -- ... other configuration
})
```

#### Available Functionalities

- **`session_optimizer`**: Used when compacting chat sessions (`:CodeCompanionOptimizeSession`)
  - Summarizes long conversations into concise overviews
  - Good candidate for lightweight, fast models like `ollama/gpt-oss`

- **`title_generator`**: Generates descriptive titles for chat sessions
  - Creates meaningful names for session history
  - Benefits from creative models like `gpt-4` or `claude-3-sonnet`

- **`meta_agent`**: Selects appropriate reasoning agents (future feature)
  - Currently just structures conversations
  - Reserved for future LLM-based agent selection

- **`reasoning_agents`**: Chain/Tree/Graph of Thoughts agents
  - Currently only structure conversations without separate LLM calls
  - Configuration reserved for future reasoning enhancements

#### Adapter Priority

The adapter resolver uses this precedence order:
1. **Override config** (passed at runtime)
2. **Functionality config** (your setup configuration)  
3. **Session defaults** (current chat's adapter/model)

#### Example Use Cases

**Cost-Optimized Setup**: Use local models for background tasks:
```lua
functionality_adapters = {
  session_optimizer = { adapter = "ollama", model = "gpt-oss" },
  title_generator = { adapter = "ollama", model = "llama3" },
}
```

**Quality-Focused Setup**: Use premium models for important tasks:
```lua
functionality_adapters = {
  title_generator = { adapter = "openai", model = "gpt-4" },
  session_optimizer = { adapter = "anthropic", model = "claude-3-sonnet" },
}
```

**Mixed Setup**: Optimize per functionality:
```lua
functionality_adapters = {
  session_optimizer = { adapter = "ollama", model = "gpt-oss" },      -- Fast local
  title_generator = { adapter = "openai", model = "gpt-4" },          -- High quality
}
```

**Legacy/Fallback**: Leave empty to use session adapter for all functionalities:
```lua
functionality_adapters = {
  -- All functionalities will use the current chat's adapter/model
}
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

Add meta-agent as a default tool:

```lua
  strategies = {
    chat = {
      tools = {
        opts = {
          default_tools = {
            'meta_agent',
          },
        },
      },
...
```

## Usage

Once installed, the meta_agent is automatically available in CodeCompanion chats. The AI will use it when appropriate, or you can request specific reasoning approaches:

```
User: "Use chain of thought to analyze this function"
User: "Try tree of thought to compare refactoring options"
```

### Tools & Agents at a Glance

- Agents: `chain_of_thoughts_agent`, `tree_of_thoughts_agent`, `graph_of_thoughts_agent`, `meta_agent` (auto‑picks an agent and adds companion tools).
- Companion tools: `ask_user` (decisions), `project_knowledge` (write to project knowledge), `add_tools` (discover/attach tools).
- Utility tools: `list_files` (fast repo listing), `initialize_project_knowledge` (bootstrap the knowledge file).

Attach optional tools before using them:
- `add_tools(action="list_tools")`
- `add_tools(action="add_tool", tool_name="<exact_name_from_list>")`

### Commands

- `:CodeCompanionChatHistory`: Browse all sessions.
- `:CodeCompanionChatLast`: Restore the most recent session.
- `:CodeCompanionProjectHistory`: Browse sessions scoped to current cwd.
- `:CodeCompanionProjectKnowledge`: Open `.codecompanion/project-knowledge.md` (if present) to view or edit.
- `:CodeCompanionInitProjectKnowledge`: Queue instructions to initialize project knowledge in the current chat.
- `:CodeCompanionRefreshSessionTitles`: Regenerate and persist titles for saved sessions.
- `:CodeCompanionOptimizeSession`: Compact the current chat into a one‑message summary (keeps the system prompt and inserts a concise user summary).

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
