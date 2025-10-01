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

This extension provides three reasoning agents that structure AI problem-solving through disciplined, evidence-based workflows. Each agent is designed around specific cognitive patterns that match different programming scenarios, ensuring that complex tasks are approached systematically with verifiable steps.

**Chain of Thoughts Agent** excels at linear problem-solving where there's a clear, sequential path from problem to solution. This agent works best for straightforward tasks like fixing a specific bug, implementing a well-defined feature, or making targeted configuration changes. It follows a disciplined workflow of analysis, evidence gathering, decision-making, and validation. For example, when debugging a failing test, the Chain agent would first analyze the error message, investigate the failing code path, propose a specific fix, implement the change, and then validate the solution through testing. The agent ensures each step builds logically on the previous one, making it ideal for tasks like methodical progression without exploring alternative approaches.

**Tree of Thoughts Agent** is engineered for scenarios requiring exploration of multiple viable solutions before converging on the optimal approach. This agent implements a mandatory multi-path exploration pattern that forces consideration of genuine alternatives rather than rushing to the first plausible solution. When tackling ambiguous problems like API design decisions, refactoring strategies, or debugging complex issues with multiple potential causes, the Tree agent creates structured branching paths that explore different problem decomposition angles. The agent's workflow mandates evidence investigation through task branches before proposing solutions, comparative evaluation of alternatives, and synthesis of insights from the best approaches. For instance, when designing a new authentication system, the Tree agent might simultaneously explore OAuth integration, custom JWT implementation, and session-based approaches, gathering evidence about security requirements, performance implications, and maintenance overhead before converging on the optimal solution.

**Graph of Thoughts Agent** handles the most complex scenarios involving interconnected systems, cross-cutting concerns, and multi-module changes where relationships between components are crucial. This agent maps dependencies across the codebase, analyzes ripple effects of changes, and synthesizes solutions that account for complex interactions. It's particularly valuable for features spanning multiple services, repository-wide refactors, or architectural changes that affect logging, authentication, or data flow patterns. The Graph agent excels at tasks requiring synthesis of new knowledge from multiple information sources, ensuring that solutions account for all affected subsystems.

**Meta Agent** serves as an intelligent dispatcher that automatically selects the most appropriate reasoning agent for your specific task. It analyzes the complexity, scope, and characteristics of your request to determine whether linear Chain reasoning, exploratory Tree reasoning, or interconnected Graph reasoning best fits the problem. The Meta Agent also automatically attaches essential companion tools including user consultation capabilities, project knowledge management, and dynamic tool discovery, ensuring right capabilities available from the start.

#### Node Types and Evidence-Based Workflow

The reasoning agents structure their work through four distinct node types that enforce evidence-based decision making:

**Analysis Nodes** perform multi-dimensional problem decomposition, breaking complex issues into distinct facets or angles. These nodes are mandatory starting points that prevent rushing to solutions without proper understanding. For example, when investigating a performance issue, analysis nodes might separately examine database queries, caching behavior, and algorithm complexity. The Tree and Graph agents require multiple analysis nodes to ensure comprehensive problem exploration.

**Task Nodes** conduct evidence investigation and implementation actions. These nodes are the foundation of evidence-based reasoning, requiring agents to gather contextual information, research existing patterns, and understand constraints before proposing solutions. Task nodes might investigate current codebase patterns, analyze similar implementations, examine error logs, or conduct focused research. Crucially, evidence-gathering task nodes must precede solution reasoning, ensuring decisions are grounded in observed facts rather than assumptions.

**Reasoning Nodes** propose specific solution hypotheses based on gathered evidence. These nodes present concrete approaches with explicit trade-offs, always building on insights discovered through task node investigation. The Tree agent mandates multiple reasoning alternatives per analysis branch, forcing consideration of different approaches. For example, after investigating authentication patterns through task nodes, reasoning nodes might propose implementing OAuth2, designing a custom JWT system, or extending existing session management.

**Validation Nodes** perform comparative verification of reasoning alternatives, testing feasibility, complexity, maintainability, and risk factors. These nodes ensure that multiple approaches are systematically evaluated before path selection. Validation might assess implementation time, breaking change risks, performance implications, or long-term maintenance burden. The Tree agent requires validation of multiple alternatives before convergence, preventing selection of suboptimal solutions.

#### Mandatory Patterns and Workflows

The reasoning agents implement strict workflow patterns that prevent common AI pitfalls like premature convergence, insufficient evidence gathering, and single-path thinking:

**Root Decomposition** requires creating 2-4 analysis children that explore different problem facets before any solution work begins. This ensures comprehensive problem understanding and prevents narrow thinking.

**Evidence Investigation** mandates task nodes that gather contextual information, research existing patterns, and understand constraints before proposing any solutions. Evidence gathering must precede reasoning in all workflows.

**Solution Alternatives** require generating 2-3 reasoning branches per major decision point, with different approaches and explicit trade-offs. This prevents anchoring on the first plausible solution.

**Comparative Evaluation** demands validation branches that systematically compare alternatives on criteria like complexity, maintainability, risk, and alignment with project goals before path selection.

**Synthesis Convergence** combines insights from the best alternative approaches into integrated implementations, ensuring final solutions benefit from multi-path exploration.

These patterns ensure that AI assistants work through problems systematically, gather sufficient evidence, explore genuine alternatives, and make well-informed decisions rather than rushing to implementation. The structured approach is particularly valuable for complex software engineering tasks where hasty decisions can create technical debt, introduce bugs, or miss better architectural solutions.

### Interactive Tools

The extension provides powerful interactive tools that transform AI-assisted development from passive Q&A into dynamic collaboration. These tools address real development challenges: making decisions when multiple approaches are valid, maintaining project context across sessions, discovering capabilities dynamically, and keeping systematic records of your work.

#### Example diagram of helper tools

```
  Development Problem
         |
         v
    Need Decision?  ----yes----> ask_user
         |                         |
         no                       User Choice
         |                         |
         v                         v
    Need Context?  ----yes----> project_knowledge
         |                         |
         no                   Update Records
         |                         |
         v                         v
    Need Tools?    ----yes----> add_tools
         |                         |
         no                    Tool Ready
         |                         |
         v                         v
    Need Files?    ----yes----> list_files
         |                         |
         no                    Files Listed
         |                         |
         v                         v
    Continue Work  <---------  Problem Solved
```

#### Ask User Tool

**Purpose**: Interactive consultation for coding decisions when multiple valid approaches exist, preventing AI from making arbitrary choices on ambiguous problems.

**Core Functionality**:

- Presents clear questions with numbered options for complex decisions
- Blocks destructive operations until user approval
- Handles architecture choices that affect long-term maintainability
- Manages performance vs. maintainability trade-offs

**Schema Parameters**:

- `question` (required): Clear, specific question explaining the decision context and why it matters
- `options` (optional): Array of 2-3 numbered choices, allowing custom responses

**Use Cases**:

```
User ────> AI: "Refactor this legacy code"
           │
           v
          AI: Discovers multiple approaches
           │
           v
        Ask User Tool: Present options with context
           │
           v
        User: "Found legacy authentication code.
               Options:
               1) Gradual refactor (safer, slower)
               2) Complete rewrite (faster, riskier)
               3) Extract to new module"
           │
           v
        User: Select option 1
           │
           v
          AI: User chose gradual refactor
           │
           v
        User: ◄──── Implement chosen approach
```

#### Project Knowledge Tool

**Purpose**: Maintains project context in `.codecompanion/project-knowledge.md`, providing persistent memory across chat sessions and team members.

**Core Functionality**:

- Auto-loads existing project knowledge into every new chat
- Records significant changes with approval workflow
- Maintains chronological changelog of development decisions
- Serves as single source of truth for project conventions

**Schema Parameters**:

- `description` (required): Brief description of accomplished work or learned insights
- `files` (optional): Array of involved files (auto-detects from git if not provided)

**Knowledge Structure**:

```
  .codecompanion/project-knowledge.md
              │
              v
     ┌────────────────────┐
     │ Project Overview   │  ◄─ High-level description, tech stack, how to run or test
     └────────────────────┘
              │
              v
     ┌────────────────────┐
     │ Directory Structure│ ◄─ Key directories and purposes
     └────────────────────┘
              │
              v
     ┌────────────────────┐
     │ Changelog          │ ◄─ Chronological development log
     └────────────────────┘
              │
              v
     ┌────────────────────┐
     │ Auto-loaded into   │ ◄─ Every new chat gets this context
     │ New Chat Sessions  │
     └────────────────────┘
```

**Workflow Integration**:

```
User ──────────────> AI: Start new chat
                     │
                     v
Project Knowledge: Auto-load context
                     │
                     v
                    AI: Load .codecompanion/project-knowledge.md
                     │
                     v
User: ◄─────────────AI: "I see this is a React app with custom auth..."

User ──────────────> AI: Implement feature
                     │
                     v
User: ◄─────────────AI: Complete feature implementation
                     │
                     v
Project Knowledge: Record changes
                     │
                     v
User: ◄──── Show approval dialog
                     │
                     v
User ──────────────> Approve knowledge update
                     │
                     v
                   File: Update changelog
```

#### Add Tools (Dynamic Capability Discovery)

**Purpose**: Dynamically attaches optional tools to current chat based on emerging needs, enabling just-in-time capability addition without cluttering the initial tool set.

**Core Functionality**:

- Reviews AVAILABLE TOOLS catalog in system prompt
- Validates tool availability and enablement status
- Adds tools to current chat's tool registry
- Prevents addition of excluded tools (reasoning agents, auto-added tools)

**Schema Parameters**:

- `tool_name` (required): Exact tool name matching AVAILABLE TOOLS section

**Tool Discovery Workflow**:

```
    [Start] AI needs new capability
        │
        v
    Review Tools: Read AVAILABLE TOOLS section
        │
        v
    Check Catalog: Find exact tool name
        │
        v
    Validate Tool ──────────────────────┐
        │                               │
        v                               v
    Add Tool: add_tools(tool_name="...")  Error: Tool not found/disabled
        │                               │
        v                               v
    Tool Ready: "tool_name ready!"    [End]
        │
        v
    Use Feature: AI can now call the tool
        │
        v
     [End]
```

#### List Files Tool

**Purpose**: Provides fast, intelligent file system navigation that respects project structure and ignore patterns, enabling AI to understand codebase organization and locate relevant files.

**Core Functionality**:

- Leverages git for smart file listing (respects `.gitignore`)
- Falls back to filesystem scan with sensible ignore patterns
- Supports directory scoping and glob pattern filtering
- Optimized for large repositories with result limits

**Schema Parameters**:

- `dir` (optional): Base directory (absolute or relative to project root)
- `glob` (optional): Pattern filter (e.g., `**/*.lua`, `*test*`, `api/**/*.js`)

**Intelligent Behavior**:

```
    list_files() call
          │
          v
    ┌─────────────┐
    │ Git repo?   │────no────► Filesystem scan
    └─────────────┘              with ignore patterns
          │                     (node_modules, .git, etc.)
         yes
          │
          v
    ┌─────────────┐
    │ Use git     │
    │ ls-files    │
    │ (respects   │
    │ .gitignore) │
    └─────────────┘
          │
          v
    Format results with project root context
```

#### Initialize Project Knowledge Tool

**Purpose**: Bootstraps comprehensive project documentation by analyzing repository structure, extracting conventions, and creating the foundational `.codecompanion/project-knowledge.md` file.

**Core Functionality**:

- Analyzes project structure and identifies technology stack
- Discovers build/test/run commands from common files (`package.json`, `Makefile`, etc.)
- Documents directory organization and key architectural patterns
- Creates template that AI can reference in future sessions

**Use Cases**:

• **New Project Setup**: First-time documentation of project conventions and structure

• **Team Onboarding**: Systematic capture of tribal knowledge for new team members

• **Legacy Projects**: Documentation of existing codebases lacking formal documentation

• **Context Recovery**: Re-establishing project understanding after long breaks

**Generated Knowledge Structure**:

- **Project Overview**: Technology stack, purpose, key dependencies
- **Directory Structure**: Explanation of module organization
- **Development Workflow**: How to run, test, build, and deploy
- **Conventions**: Coding standards, naming patterns, architectural decisions
- **Recent Changes**: Foundation for ongoing changelog tracking

#### Tool Interaction Patterns

**Sequential Tool Usage**:

```
User ─────────────> AI: "Add user authentication"
                    │
                    v
               Add Tools: add_tools(tool_name="list_files")
                    │
                    v
                   AI: ◄─── "list_files ready to use!"
                    │
                    v
              List Files: list_files(glob="**/*auth*")
                    │
                    v
                   AI: ◄─── Show existing auth files
                    │
                    v
                Ask User: "Found partial auth. Complete or rewrite?"
                    │
                    v
User: ◄──────── Present options
                    │
                    v
User ─────────────> "Complete existing"
                    │
                    v
                   AI: ◄─── User decision
                    │
                    v
               Add Tools: add_tools(tool_name="neovim__edit_file")
                    │
                    v
User: ◄─────────   AI: Implement completion
                    │
                    v
        Project Knowledge: Record changes
```

These interactive tools transform AI assistance from reactive responses into proactive collaboration, ensuring decisions are user-guided, context is preserved, capabilities grow with needs, and knowledge accumulates systematically across development sessions.

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
          adapter = nil, -- override adapter for title generation, defaults to session adapter
          model = nil,   -- override model for title generation, defaults to session model
        }
        -- meta_agent and reasoning_agents also available
      },
      chat_history = {
        auto_save = true,
        auto_generate_title = true,
        sessions_dir = vim.fn.stdpath('data') .. '/codecompanion-reasoning/sessions',
        max_sessions = 100,
        enable_commands = true,
        picker = 'default', -- only 'default' is supported ('auto' remains an alias)
        continue_chat = true, -- true (auto load last session), false (disable auto load)
        title_generation_opts = {
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

### Chat History Continuation

Control startup behaviour with `chat_history.continue_chat`:

- `true` _(default)_ — automatically reopen the latest saved chat when CodeCompanion starts.
- `false` — skip the automatic restore.

Legacy `auto_load_last_session` and `continue_last_chat` booleans still work; they emit a deprecation warning and map to the new boolean internally.

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

- Review AVAILABLE TOOLS section in the system prompt
- `add_tools(tool_name="<exact_name_from_catalog>")`

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
