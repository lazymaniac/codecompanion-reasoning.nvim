# CodeCompanion Reasoning Extension

An add‑on for [CodeCompanion.nvim](https://github.com/olimorris/codecompanion.nvim) that gives your chats structured “reasoning agents”, interactive tools, and practical session history.

It helps LLM work in small, safe, and verifiable steps: picks an agent that fits the job, attaches only the tools LLM needs, and keeps a searchable record of your sessions with useful titles.

Example session run (poor quality)

https://github.com/user-attachments/assets/00f93891-4712-4197-95a5-35ed97fc819c

Session browser

https://github.com/user-attachments/assets/f947509b-05bf-410e-af7b-877f0282d63d

Ask User tool:

<img width="782" height="687" alt="Screenshot 2025-10-01 at 16 50 29" src="https://github.com/user-attachments/assets/7b7dcfe1-5d46-4d30-b6ba-e2ff0dabfaf5" />

## Goals

- Human id the loop - make work with LLMs more interactive, more like code companion
- Fully automatic - no need to manually add tools when needed
- Automatic Project Context initialization (conventions, how to run, test, directory structure...)
- Integrated session history browser with automatic naming
- Grow with project - keep track of recent changes
- At least partially usable with open source models
- Token efficient

## Features

### Reasoning Agents

This extension provides three reasoning agents that structure AI problem-solving through disciplined, evidence-based workflows. Each agent is designed around specific cognitive patterns that match different programming scenarios, ensuring that complex tasks are approached systematically with verifiable steps.

- **Chain of Thoughts Agent** excels at linear problem-solving where there's a clear, sequential path from problem to solution. This agent works best for straightforward tasks like fixing a specific bug, implementing a well-defined feature, or making targeted configuration changes. It follows a disciplined workflow of analysis, evidence gathering, decision-making, and validation. The agent should ensure each step builds logically on the previous one, making it ideal for tasks like methodical progression without exploring alternative approaches.

- **Tree of Thoughts Agent** for scenarios requiring exploration of multiple viable solutions before converging on the optimal approach. This agent implements a mandatory multi-path exploration pattern that forces consideration of genuine alternatives rather than rushing to the first plausible solution. When tackling problems with multiple potential causes, the Tree agent creates structured branching paths that explore different problem decomposition angles. The agent's workflow mandates evidence investigation through task branches before proposing solutions, comparative evaluation of alternatives, and synthesis of insights from the best approaches.

- **Graph of Thoughts Agent** for most complex scenarios. This agent maps dependencies across the codebase, analyzes ripple effects of changes, and synthesizes solutions that account for complex interactions. It's particularly valuable for features spanning multiple services, repository-wide refactors, or architectural changes that affect logging, authentication, or data flow patterns. The Graph agent excels at tasks requiring synthesis of new knowledge from multiple information sources, ensuring that solutions account for all affected subsystems.

- **Meta Agent** serves as an intelligent dispatcher that automatically selects the most appropriate reasoning agent for your specific task. It analyzes the complexity, scope, and characteristics of your request to determine whether linear Chain reasoning, exploratory Tree reasoning, or interconnected Graph reasoning best fits the problem. The Meta Agent also automatically attaches essential companion tools including user consultation capabilities, project knowledge management, and dynamic tool discovery, ensuring right capabilities available from the start.

#### Node Types and Evidence-Based Workflow

The reasoning agents structure their work through four distinct node types that enforce evidence-based decision making:

**Analysis Nodes** perform multi-dimensional problem decomposition, breaking complex issues into distinct facets or angles. These nodes are mandatory starting points that prevent rushing to solutions without proper understanding. The Tree and Graph agents require multiple analysis nodes to ensure comprehensive problem exploration.

**Task Nodes** conduct evidence investigation and implementation actions. These nodes are the foundation of evidence-based reasoning, requiring agents to gather contextual information, research existing patterns, and understand constraints before proposing solutions. Task nodes might investigate current codebase patterns, analyze similar implementations, examine error logs, or conduct focused research. Crucially, evidence-gathering task nodes must precede solution reasoning, ensuring decisions are grounded in observed facts rather than assumptions.

**Reasoning Nodes** propose specific solution hypotheses based on gathered evidence. These nodes present concrete approaches with explicit trade-offs, always building on insights discovered through task node investigation. The Tree agent mandates multiple reasoning alternatives per analysis branch, forcing consideration of different approaches.

**Validation Nodes** perform comparative verification of reasoning alternatives, testing feasibility, complexity, maintainability, and risk factors. These nodes ensure that multiple approaches are systematically evaluated before path selection. The Tree agent requires validation of multiple alternatives before convergence, preventing selection of suboptimal solutions.

#### Mandatory Patterns and Workflows

The reasoning agents implement strict workflow patterns that prevent common AI pitfalls like premature convergence, insufficient evidence gathering, and single-path thinking:

**Root Decomposition** requires creating 2-4 analysis children that explore different problem facets before any solution work begins. This ensures comprehensive problem understanding and prevents narrow thinking.

**Evidence Investigation** mandates task nodes that gather contextual information, research existing patterns, and understand constraints before proposing any solutions. Evidence gathering must precede reasoning in all workflows.

**Solution Alternatives** require generating 2-3 reasoning branches per major decision point, with different approaches and explicit trade-offs. This prevents anchoring on the first plausible solution.

**Comparative Evaluation** demands validation branches that systematically compare alternatives on criteria like complexity, maintainability, risk, and alignment with project goals before path selection.

**Synthesis Convergence** combines insights from the best alternative approaches into integrated implementations, ensuring final solutions benefit from multi-path exploration.

These patterns should ensure that AI assistants work through problems systematically, gather sufficient evidence, explore genuine alternatives, and make well-informed decisions rather than rushing to implementation. The structured approach is particularly valuable for complex software engineering tasks where hasty decisions can create technical debt, introduce bugs, or miss better architectural solutions.

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

**Purpose**: Dynamically attaches optional tools (core tools, MCP tools, local tools) to current chat based on emerging needs, enabling just-in-time capability addition without cluttering the initial tool set.

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

Session Management provides comprehensive development workspace persistence with intelligent session handling, automatic metadata generation, and advanced organization features. This system transforms CodeCompanion from a single-use chat into a persistent knowledge base that grows with your projects.

#### Functionality-Specific Adapters

**Purpose**: Optimize performance and cost by using different AI models for different background tasks, allowing you to reserve premium models for actual development work while using efficient models for maintenance tasks.

**Smart Resource Allocation**:

```
   Development Session
         │
         ├── Main Chat ──────────► Premium Model (GPT-4/Claude)
         │   (Your actual work)
         │
         ├── Title Generation ───► Creative Model (GPT-4)
         │   (Descriptive names)
         │
         ├── Session Optimization ► Fast Model (Ollama/gpt-oss)
         │   (Compress long chats)
         │
         ├── Tag Generation ─────► Standard Model (GPT-3.5)
         │   (Auto-categorization)
         │
         └── Meta Agent ─────────► Configured Model
             (Agent selection)
```

**Benefits**:

• **Cost Control**: Use expensive models only where quality matters most
• **Performance**: Fast local models for background tasks like compression
• **Quality Focus**: Creative models for user-facing features like titles
• **Flexibility**: Fine-tune model selection per functionality

#### Advanced Session Features

**Auto-Generated Session Tags**:

Sessions automatically receive intelligent tags based on conversation content. The system analyzes your chat to generate relevant categorization tags.

```
Session Content Analysis
         │
         v
    ┌─────────────────────────────────────┐
    │ Extract topics from conversation    │ ◄─ "authentication", "debugging"
    └─────────────────────────────────────┘
         │
         v
    ┌─────────────────────────────────────┐
    │ Generate relevant tags via LLM      │ ◄─ ["python", "auth", "middleware"]
    └─────────────────────────────────────┘
         │
         v
    ┌─────────────────────────────────────┐
    │ Store with session metadata         │
    └─────────────────────────────────────┘
```

**Session Favorites System**:

Mark important sessions as favorites for priority access and protection from cleanup.

```
╭─────────────────────────────────────────────────────────────╮
│ Session Browser                                             │
│ ─────────────────────────────────────────────────────────── │
│ ★ Fix authentication middleware timeout + retry logic       │ ◄─ Favorite
│ ★ Debug database connection pool                            │ ◄─ Favorite
╰─────────────────────────────────────────────────────────────╯
```

**Token Estimation and Size Tracking**:

Every session tracks estimated token usage and file size for resource management.

#### Session Optimization and Compaction

**Purpose**: Compress long conversations into concise summaries while preserving essential context, enabling continued development without token limit issues.

**Optimization Workflow**:

```
    Long Session (50+ messages)
              │
              v
    ┌─────────────────────────────────────┐
    │ Preserve system prompt              │ ◄─ Keep original configuration
    └─────────────────────────────────────┘
              │
              v
    ┌─────────────────────────────────────┐
    │ Analyze conversation content        │ ◄─ Extract key developments
    └─────────────────────────────────────┘
              │
              v
    ┌─────────────────────────────────────┐
    │ Generate comprehensive summary      │ ◄─ Use session_optimizer model
    └─────────────────────────────────────┘
              │
              v
    ┌─────────────────────────────────────┐
    │ Replace messages with summary       │ ◄─ System + Summary + Continue
    └─────────────────────────────────────┘
```

**Benefits**:

• **Token Efficiency**: Reduce 50+ messages to 2-3 essential messages
• **Context Preservation**: Maintain development history and decisions
• **Continued Development**: Resume work without starting from scratch
• **Performance**: Faster loading and processing of optimized sessions

#### History and Restoration

**Auto-Save System**:

Every message is automatically saved with rich metadata, creating a comprehensive development audit trail.

**Session Metadata Tracking**:

```
Session File Contents:
├── messages[]           ◄─ Full conversation history
├── metadata
│   ├── total_messages   ◄─ Message count
│   ├── token_estimate   ◄─ Estimated token usage
│   ├── tags[]           ◄─ Auto-generated topic tags
│   ├── favorite         ◄─ Favorite status
│   └── project_root     ◄─ Associated project
├── config
│   ├── adapter          ◄─ AI model used
│   ├── model            ◄─ Specific model version
│   └── settings         ◄─ Model parameters
├── title               ◄─ Auto-generated descriptive title
├── created_at          ◄─ Session start timestamp
├── updated_at          ◄─ Last modification time
└── session_id          ◄─ Unique identifier
```

**Project-Scoped Organization**:

Sessions are automatically associated with project directories, enabling focused browsing and team collaboration.

```
    Project A Sessions          Project B Sessions
    ├── auth-middleware-fix     ├── react-dashboard-ui
    ├── database-optimization   ├── api-error-handling
    └── ci-cd-pipeline         └── payment-refactor
```

#### Smart Title Generation

**Purpose**: Automatically creates searchable, descriptive titles that evolve with conversation content, eliminating generic session names.

### UI Features

UI Features provide intuitive interfaces for managing your development history with advanced filtering, preview capabilities, and efficient navigation. The interface transforms session management from background functionality into an active part of your development workflow.

#### Session Browser Interface

**Purpose**: Fast, searchable access to your entire development history with rich metadata display and instant previews.

**Session Information Display**:

• Stars for favorites, icons for status
• Date, model, message count at a glance
• Favorites first, then by recency
• See resource usage per session

#### Integration with Development Workflow

**Seamless Project Integration**:

```
    Development Context
           │
           v
    ┌─────────────────────────────────────┐
    │ Auto-detect current project         │ ◄─ Use vim.fn.getcwd()
    └─────────────────────────────────────┘
           │
           v
    ┌─────────────────────────────────────┐
    │ Filter sessions by project          │ ◄─ :CodeCompanionProjectHistory
    └─────────────────────────────────────┘
           │
           v
    ┌─────────────────────────────────────┐
    │ Show relevant session history       │
    └─────────────────────────────────────┘
```

**Auto-Continue Workflow**:

```
    Neovim Startup
         │
         v
    ┌─────────────────────────────────────┐
    │ continue_chat enabled?             │
    └─────────────────────────────────────┘
         │ yes                    │ no
         v                        v
    ┌─────────────────────┐   [Start clean]
    │ Find last session   │
    └─────────────────────┘
         │
         v
    ┌─────────────────────┐
    │ Auto-restore chat   │ ◄─ Resume exactly where you left off
    └─────────────────────┘
         │
         v
    ┌─────────────────────┐
    │ Continue working    │
    └─────────────────────┘
```

These UI features create a comprehensive development workspace where your AI-assisted conversations become organized, searchable knowledge that builds systematically over time, supporting both individual development and team collaboration patterns.

## Requirements

- [CodeCompanion.nvim](https://github.com/olimorris/codecompanion.nvim) >= 17.13.0
- Neovim >= 0.9.0

## Installation

### Using [lazy.nvim](https://github.com/folke/lazy.nvim)

```lua
{
  "olimorris/codecompanion.nvim",
  dependencies = {
    "lazymaniac/codecompanion-reasoning.nvim",
  },
  config = function()
    require("codecompanion").setup({
      ...
      extensions = {
        reasoning = {
          callback = 'codecompanion._extensions.reasoning',
          opts = {
            project_knowledge_initialization = {
              adapter = nil, -- e.g. 'ollama', defaults to chat adapter
              model = nil, -- e.g. 'gpt-oss' defaults to chat model
            },
            session_optimizer = {
              adapter = nil, -- e.g. 'ollama', defaults to chat adapter
              model = nil, -- e.g. 'gpt-oss' defaults to chat model
              summary_max_words = 300, -- target number of words in generated summary
            },
            session_title_generator = {
              adapter = nil, -- e.g. 'ollama', defaults to chat adapter
              model = nil, -- e.g. 'gpt-oss' defaults to chat model
              refresh_every_n_user_prompts = 3,
              max_words_per_title = 6,
              format_title = nil, -- function
            },
            session_history = {
              auto_save = true, -- auto save each session
              auto_generate_title = true, -- auto generate title for each session
              continue_last_session = false, -- load last session on chat open
              picker = 'default', -- currently only default is available
              max_sessions = 100, -- how many sessions to store on disk
              sessions_dir = vim.fn.stdpath 'data' .. '/codecompanion-reasoning/sessions',
              session_file_pattern = 'session_%Y%m%d_%H%M%S.lua',
            },
            enabled = true,
          },
        },
      },
      strategies = {
        chat = {
          tools = {
            opts = {
              default_tools = {
                'meta_agent',
              },
            },
          },
        }
      }
      ...
    })
  end,
}
```

## Usage

Once installed, the meta_agent is automatically available in CodeCompanion chats. The AI will use it when appropriate, or you can request specific reasoning approaches:

```
User: "Use chain of thought to analyze this function"
User: "Try tree of thought to compare refactoring options"
```

### Commands

- `:CodeCompanionChatHistory`: Browse all sessions.
- `:CodeCompanionChatLast`: Restore the most recent session.
- `:CodeCompanionProjectHistory`: Browse sessions scoped to current cwd.
- `:CodeCompanionProjectKnowledge`: Open `.codecompanion/project-knowledge.md` (if present) to view or edit.
- `:CodeCompanionInitProjectKnowledge`: Queue instructions to initialize project knowledge in the current chat.
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
5. Run `make all`
6. Submit a pull request

## TODO
- [ ] Fix active session compaction. It should reload active session with compacted version so user can contniue conversation.
- [ ] Improve prompts for session compaction to extract more useful information.
- [ ] Make better use of ask_user tool. Maybe instruct LLM to use it at the start of the task to ask clarification questions.
- [ ] Refine project_knowledge updates. Maybe instead of storing recent changes it would be better to store key insights gathered during regular usage (like: auth logic is in AuthController.java and is using JWT)
- [ ] Add optimization algorithm. Implement a filter running before request to LLM is made. Currently whole chat is acting as context or short term memory. It may be possible to use open or cheap models for context filtering to sent only relevant messages from chat history.
- [ ] Refactor used tool restoration in historical session to use tags like @{ask_user} instead of manually adding it to tool_registry.
- [ ] Use sessions history as context in current chat. Select it from session picker and use as context.
- [ ] Maybe allow LLM to look through sessions via tags, or full text search?
## License

MIT License - see LICENSE file for details.
