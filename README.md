# CodeCompanion Reasoning Extension

An add‑on for [CodeCompanion.nvim](https://github.com/olimorris/codecompanion.nvim) that gives your chats structured “reasoning agents”, interactive tools, and practical session history.

It helps LLM work in small, safe, and verifiable steps: picks an agent that fits the job, attaches only the tools LLM needs, and keeps a searchable record of your sessions with useful titles.

Example session run (poor quality)

<https://github.com/user-attachments/assets/00f93891-4712-4197-95a5-35ed97fc819c>

Session browser

<https://github.com/user-attachments/assets/f947509b-05bf-410e-af7b-877f0282d63d>

Ask User tool:

<img width="782" height="687" alt="Screenshot 2025-10-01 at 16 50 29" src="https://github.com/user-attachments/assets/7b7dcfe1-5d46-4d30-b6ba-e2ff0dabfaf5" />

<img width="1115" height="730" alt="Screenshot 2025-10-02 at 15 28 23" src="https://github.com/user-attachments/assets/d687e021-2c71-4def-a340-d1c5dda6368f" />

## Goals

- Human id the loop - make work with LLMs more interactive, more like code companion
- Fully automatic - no need to manually add tools when needed
- Automatic Project Context initialization (conventions, how to run, test, directory structure...)
- Integrated session history browser with automatic naming
- Grow with project - keep track of recent changes
- At least partially usable with open source models

## Features

### System Prompt

The system prompt transforms CodeCompanion into a disciplined, evidence-based programming assistant that collaborates systematically with developers through structured workflows and professional standards.

#### Disciplined Workflow Management

Prevents AI from rushing to solutions by enforcing structured problem-solving workflows:

```
Request ──► Meta Agent ──► Agent Selection ──► Tool Attachment ──► Evidence Gathering ──► Solution ──► Validation
   │            │               │                  │                      │                   │         │
   │            ▼               │                  ▼                      ▼                   ▼         │
   │      Analyze task          │            add_tools()            Research context       Implement    │
   │      complexity            │            Review available       Read files             changes      │
   │                            │            capabilities           Run commands                        │
   │                            ▼                                                                       │
   │                      Chain/Tree/Graph                                                              │
   │                      reasoning agent                                                               │
   │                                                                                                    │
   └──────────────────────────────── ask_user (when ambiguous) ◄────────────────────────────────────────┘
```

**Key Enforcement Patterns:**

- **Agent Selection First**: Every session starts with `meta_agent` selection (Chain/Tree/Graph)
- **Clarify Before Code**: Proactive `ask_user` for vague requests or multiple valid approaches
- **Tools Then Actions**: `add_tools` → verify → use (prevents capability errors)
- **Evidence Before Solutions**: Analysis → research → reasoning → implementation → validation

#### Engineering Excellence Standards

Embeds professional software engineering practices into every AI response:

```
        Security Foundation
              │
         ┌────┴────┐
         │         │
    Code Quality ──┼── Performance
         │         │      │
         └─────────┼──────┘
                   │
              Testing &
            Maintainability
```

**Security-First:** Input validation, least privilege, no arbitrary execution, secure secrets
**Code Quality:** Descriptive naming, single-purpose functions, DRY principles, clear interfaces
**Performance:** Linear algorithms, batch operations, safe caching, hot-path optimization
**Testing:** MiniTest integration, deterministic patterns, error path coverage
**Maintainability:** Backwards compatibility, systematic refactoring, change impact validation

#### Communication Standards

Establishes consistent, professional output that enhances developer experience:

```
Input Request ──► Analysis ──► Evidence ──► Reasoning ──► Output
      │               │           │            │           │
      │               ▼           ▼            ▼           ▼
      │         Break down    Research     Ground in    Markdown
      │         problem       context      observed     + Code
      │         angles                     facts        blocks
      │                                                   │
      └──────────────── Concise, actionable ◄─────────────┘
```

**Format Standards:** English-only, Markdown structure, four-backtick code blocks with filepaths
**Evidence-Based:** All decisions cite specific files, test output, or line references
**Token Efficiency:** Low usage without quality sacrifice, focused output discipline

#### Project Context Integration

Ensures consistent understanding and knowledge accumulation across sessions:

```
    New Chat ──────────► Auto-load project context
        │                        │
        │                        ▼
        │                .codecompanion/project-knowledge.md
        │                        │
        │                        ▼
        ▼                 Architecture Facts
   Work with full           Workflow Facts
   context from             Business Logic
   session start           Constraints Facts
        │                        │
        │                        ▼
        └───► New insights ──► Capture via project_knowledge
```

**Knowledge Management:** Auto-loads project context, treats as single source of truth
**Fact Capture:** Records durable insights (where features live, how to build/test, business rules)
**Session Continuity:** Maintains context across chats, enables resumption exactly where left off

This comprehensive system prompt creates a reliable programming assistant that works systematically, maintains professional standards, and builds institutional knowledge over time.

### Reasoning Agents

Three structured agents provide disciplined, evidence-based AI problem-solving with automatic tool attachment and intelligent agent selection.

#### Agent Selection Overview

```
    Problem ────────► Meta Agent ────────► Reasoning Agent
         │                 │                      │
         │                 ▼                      │
         │          ┌─────────────┐               │
         │          │ Analyze:    │               │
         └─────────►│ • Scope     │               │
                    │ • Complexity│               │
                    │ • Approach  │               │
                    └─────────────┘               │
                           │                      │
                           ▼                      │
                    ┌─────────────┐               │
                    │ Select:     │               │
                    │ Chain/Tree/ │◄──────────────┘
                    │ Graph Agent │
                    └─────────────┘
                           │
                           ▼
                    Auto-attach tools
                    (ask_user, project_knowledge, add_tools)
```

#### Agent Comparison

| Agent     | Use Cases                                                        | Workflow Pattern                                           | Best For                               |
| --------- | ---------------------------------------------------------------- | ---------------------------------------------------------- | -------------------------------------- |
| **Chain** | Bug fixes, targeted features, config changes                     | Analysis → Evidence → Reasoning → Validation               | Linear problems with clear paths       |
| **Tree**  | Multiple solutions, refactoring options, architectural decisions | Analysis × N → Evidence → Reasoning × N → Compare → Select | Exploring alternatives before deciding |
| **Graph** | Cross-system features, complex refactors, dependency analysis    | Multi-dimensional analysis → Synthesis → Integration       | Complex interconnected changes         |

#### Agent Workflow Patterns

**Chain of Thoughts** - Linear progression:

```
Problem ──► Analysis ──► Evidence ──► Reasoning ──► Validation ──► Solution
    │           │           │            │             │            │
    └───────────┼───────────┼────────────┼─────────────┼────────────┘
                Sequential steps building on each other
```

**Tree of Thoughts** - Multi-path exploration:

```
                 Problem
                    │
              ┌─────┼─────┐
              │     │     │
         Analysis1 Analysis2 Analysis3
              │     │     │
           ┌──┴──┐  │  ┌──┴──┐
       Reason1 Reason2  Reason3 Reason4
           │     │       │       │
           └─────┼───────┼───────┘
                 │       │
              Compare & Select
                 │
              Solution
```

**Graph of Thoughts** - Interconnected analysis:

```
        Problem
           │
    ┌──────┼──────┐
    │      │      │
  Deps   Core   Effects
    │      │      │
    └──┬───┼───┬──┘
       │   │   │
    Synthesis │ Integration
       │   │   │
       └───┼───┘
           │
       Solution
```

#### Evidence-Based Node Types

All agents structure work through four node types that enforce evidence-based decision making:

```
┌─────────────┐    ┌─────────────┐    ┌─────────────┐    ┌─────────────┐
│ ANALYSIS    │───►│ TASK        │───►│ REASONING   │───►│ VALIDATION  │
│ Problem     │    │ Evidence    │    │ Solutions   │    │ Verify &    │
│ breakdown   │    │ gathering   │    │ based on    │    │ compare     │
│ into angles │    │ & research  │    │ evidence    │    │ approaches  │
└─────────────┘    └─────────────┘    └─────────────┘    └─────────────┘
      │                   │                   │                   │
      ▼                   ▼                   ▼                   ▼
   Multiple            Context           Concrete           Systematic
  perspectives        investigation      hypotheses         evaluation
```

#### Mandatory Quality Patterns

**Root Decomposition**: 2-4 analysis branches explore different problem facets

```
    Root Problem
         │
    ┌────┼────┐
    │    │    │
    A1   A2   A3  ◄── Different angles required
    │    │    │
    └────┼────┘
         ▼
    Evidence tasks must follow before solutions
```

**Evidence Before Solutions**: Task nodes gather context before reasoning

```
❌ FORBIDDEN:  Analysis ──► Reasoning ──► Task
✅ REQUIRED:   Analysis ──► Task ──► Reasoning ──► Validation
                            │
                         Evidence gathering must precede solutions
```

**Multi-Path Validation**: Tree/Graph agents compare 2-3 alternatives

```
         Evidence
             │
      ┌──────┼──────┐
      │      │      │
  Solution1 Solution2 Solution3
      │      │      │
      └──────┼──────┘
             │
         Compare
    (complexity, risk, maintainability)
             │
       Best approach
```

This structured approach prevents AI from rushing to solutions, ensures evidence-based decisions, and systematically explores alternatives for complex engineering tasks.

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

**Purpose**: Maintains categorized project context in `.codecompanion/project-knowledge.md`, providing structured institutional memory that reduces discovery time and token usage across sessions.

**Core Functionality**:

- Auto-loads existing project knowledge into every new chat
- Captures durable project facts with an approval workflow
- Highlights where key subsystems live, which patterns or libraries they use, and other reusable context
- Serves as single source of truth for project conventions

**Fact Categories**:

```
Architecture Facts ──────> Where features are implemented
    ├─ "Authentication logic is in src/auth/ (JWT + middleware pattern)"
    ├─ "Database models are in app/models/ (Sequelize ORM)"
    └─ "API routes are in routes/api/ (Express.js with validation)"

Workflow Facts ──────────> How to build, test, and deploy
    ├─ "Testing: Run `npm test` (requires Docker running)"
    ├─ "Database setup: Run `npm run db:migrate` then `npm run db:seed`"
    └─ "Build process: Uses Webpack with hot reload in dev mode"

Business Logic Facts ────> How features work and business rules
    ├─ "User permissions: Role-based (admin/user/guest) defined in User.role"
    ├─ "Payment processing: Stripe integration in src/payments/ (webhooks + async)"
    └─ "File uploads: Limited to 10MB, stored in S3 with presigned URLs"

Constraints Facts ───────> Technical limitations and requirements
    ├─ "Performance constraint: API responses must be <200ms (monitored)"
    ├─ "Security requirement: All API endpoints require JWT authentication"
    └─ "Database constraint: MySQL 8.0+ required for JSON column features"
```

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
     │ Architecture Facts │ ◄─ Code locations and patterns
     └────────────────────┘
              │
              v
     ┌────────────────────┐
     │ Workflow Facts     │ ◄─ Commands and processes
     └────────────────────┘
              │
              v
     ┌────────────────────┐
     │ Business Logic     │ ◄─ Feature behavior and rules
     └────────────────────┘
              │
              v
     ┌────────────────────┐
     │ Constraints Facts  │ ◄─ Technical limitations
     └────────────────────┘
              │
              v
     ┌────────────────────┐
     │ Auto-loaded into   │ ◄─ Every new chat gets this context
     │ New Chat Sessions  │
     └────────────────────┘
```

**Quality Guidelines**:

✅ **Capture These:**

- "Authentication middleware is in src/middleware/auth.js (JWT validation)"
- "User uploads go to S3 bucket via src/storage/s3.js (10MB limit)"
- "Database migrations: `npm run migrate` (requires PostgreSQL 13+)"

❌ **Avoid These:**

- "Fixed a bug in the login form" (temporary, not architectural)
- "The code is well structured" (opinion, not actionable)
- "Working on user dashboard" (current activity, not durable knowledge)

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
Project Knowledge: Capture new fact
                     │
                     v
User: ◄──── Show approval dialog
                     │
                     v
User ──────────────> Approve knowledge update
                     │
                     v
                   File: Append fact entry
```

#### Add Tools (Dynamic Capability Discovery)

**Purpose**: Dynamically attaches optional tools (core tools, MCP tools, local tools) to current chat based on emerging needs, enabling just-in-time capability addition without cluttering the initial tool set.

**Core Functionality**:

- Reviews AVAILABLE TOOLS catalog in system prompt
- Validates tool availability and enablement status
- Adds tools to current chat's tool registry
- Prevents addition of excluded tools (reasoning agents, auto-added tools)

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
- **Key Facts**: Placeholder guidance for durable facts captured later via `project_knowledge`

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

**Purpose**: Transform conversations into resumption-focused summaries that enable seamless continuation exactly where you left off, optimized for "conversation time-travel".

**Enhanced Resumption Design**:
The session optimizer creates resumption-specific summaries with four focused sections designed for natural conversation continuation:

```
## Current Focus (40% of summary)
├── Immediate technical problem or task being addressed
├── Specific files, functions, or components currently in scope
├── Tools, libraries, frameworks, or methodologies in active use
├── Current implementation approach or solution strategy
└── Code, configurations, or technical details immediately relevant

## User Context (25% of summary)
├── Technical expertise level and relevant experience
├── Communication preferences and explanation style they respond to
├── Current understanding of the problem domain and knowledge gaps
├── Goals, constraints, deadlines, or success criteria driving decisions
└── Mental state: methodical, exploring, frustrated, excited, stuck, progressing

## Next Steps (25% of summary)
├── Next logical step or decision point in the workflow
├── Specific questions they will likely ask or areas they want to explore
├── Known blockers, dependencies, or issues that need resolution
├── Quick wins or immediate progress opportunities available
└── Alternative approaches or options they might want to consider

## Resume With (10% of summary)
└── 2-3 sentences that smoothly restart the conversation, acknowledging where
    we left off and naturally transitioning to the next step using their
    established terminology and communication style
```

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
    │ Analyze conversation for resumption │ ◄─ Extract current focus & user state
    └─────────────────────────────────────┘
              │
              v
    ┌─────────────────────────────────────┐
    │ Generate resumption-focused summary │ ◄─ 4-section structure (500+ words)
    └─────────────────────────────────────┘
              │
              v
    ┌─────────────────────────────────────┐
    │ Replace with resumption bridge      │ ◄─ Ready-to-continue conversation
    └─────────────────────────────────────┘
```

**Benefits**:

• **Token Efficiency**: Reduce 50+ messages to 2-3 essential messages
• **Seamless Resumption**: Continue exactly where you left off with full context
• **Natural Flow**: AI can restart conversation as if no interruption occurred
• **Mental State Preservation**: Maintains user's cognitive and emotional context
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
              summary_max_words = 500, -- target words for resumption-focused summary (minimum recommended)
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

- [x] Fix active session compaction. It should reload active session with compacted version so user can continue conversation.
- [x] Improve prompts for session compaction to extract more useful information.
- [x] Make better use of ask_user tool. Maybe instruct LLM to use it at the start of the task to ask clarification questions.
- [x] Refine project_knowledge updates. Maybe instead of storing recent changes it would be better to store key insights gathered during regular usage (like: auth logic is in AuthController.java and is using JWT)
- [ ] Add optimization algorithm. Implement a filter running before request to LLM is made. Currently whole chat is acting as context or short term memory. It may be possible to use open or cheap models for context filtering to sent only relevant messages from chat history.
- [ ] Refactor used tool restoration in historical session to use tags like @{ask_user} instead of manually adding it to tool_registry.
- [ ] Use compacted sessions history as context in current chat. Select it from session picker and use as context.
- [ ] Maybe allow LLM to look through sessions via tags, or full text search?

## License

MIT License - see LICENSE file for details.
