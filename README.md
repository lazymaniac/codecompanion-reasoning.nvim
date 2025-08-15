# CodeCompanion Reasoning Extension

Advanced reasoning tools extension for [CodeCompanion.nvim](https://github.com/olimorris/codecompanion.nvim).

This extension provides sophisticated AI reasoning capabilities including Chain of Thought, Tree of Thought, and Graph of Thought agents, plus interactive user consultation tools.

## Features

- **Chain of Thoughts Agent**: Sequential reasoning for complex problems
- **Tree of Thoughts Agent**: Explores multiple solution branches
- **Graph of Thoughts Agent**: Network-based reasoning with interconnected thoughts
- **Ask User Tool**: Interactive decision-making with user consultation
- **Meta Agent**: Automatically selects the best reasoning approach
- **Tool Discovery**: Dynamic tool exploration and selection
- **Reasoning Visualization**: Visual representation of thought processes

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
    require("codecompanion-reasoning").setup()
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

The extension automatically registers with CodeCompanion when installed. You can
also manually register it:

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

## Usage

Once installed, the reasoning tools are automatically available in CodeCompanion chats. The AI will use them when appropriate, or you can request specific reasoning approaches:

```
User: "Use chain of thought to analyze this complex function"
User: "Apply tree of thought reasoning to find the best refactoring approach"
User: "Use the ask user tool to help me decide between these options"
```

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
