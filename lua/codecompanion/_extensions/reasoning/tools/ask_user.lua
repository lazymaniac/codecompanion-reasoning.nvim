local fmt = string.format

---@class CodeCompanion.Tool.AskUser: CodeCompanion.Tools.Tool
return {
  name = 'ask_user',

  opts = {},

  cmds = {
    function(self, args, input, callback)
      self.args = args

      local question = args.question or 'No question provided'
      local context = args.context or ''
      local options = args.options or {}

      -- Show popup and use callback when response is received
      local Popup = require('codecompanion._extensions.reasoning.ui.popup')

      vim.schedule(function()
        Popup.ask_question(question, context, options, function(response, cancelled, selected_option)
          if cancelled then
            -- Call callback with error
            callback({
              status = 'error',
              data = 'User cancelled the question',
            })
          else
            -- Call callback with success and user response
            callback({
              status = 'success',
              data = { response or 'No response provided' },
            })
          end
        end)
      end)

      -- Don't return anything - callback will be called when response is ready
    end,
  },

  schema = {
    type = 'function',
    ['function'] = {
      name = 'ask_user',
      description = 'Interactive consultation: ask user for coding decisions when multiple valid approaches exist or when user expertise is needed.',
      parameters = {
        type = 'object',
        properties = {
          question = {
            type = 'string',
            description = 'Clear, specific question about coding decision that needs user input',
          },
          options = {
            type = 'array',
            items = { type = 'string' },
            description = 'Numbered choices for user (optional). User can select by number or provide custom response',
          },
          context = {
            type = 'string',
            description = 'Why this decision matters and what the implications are for the code',
          },
        },
        required = {
          'question',
        },
        additionalProperties = false,
      },
      strict = true,
    },
  },

  -- Output handler to process callback result
  output = {
    success = function(self, agent, cmd, stdout)
      local chat = agent.chat
      local result = vim.iter(stdout):flatten():join('\n')
      local question = self.args.question or 'No question provided'

      -- Format the user response for chat - put response summary first
      local response_summary = result:gsub('\n.*', '') -- Get first line only for summary
      if #response_summary > 80 then
        response_summary = response_summary:sub(1, 77) .. '...'
      end
      local output = fmt(
        '💬 User responded: %s\n\n**Full Response:**\n%s\n\n**Original Question:** %s',
        response_summary,
        result,
        question
      )
      chat:add_tool_output(self, output)
    end,

    error = function(self, agent, cmd, stderr)
      local chat = agent.chat
      local errors = vim.iter(stderr):flatten():join('\n')
      local question = self.args.question or 'No question provided'
      local output = fmt('❌ User cancelled or error occurred: %s\n\n**Original Question:** %s', errors, question)
      chat:add_tool_output(self, output)
    end,
  },

  system_prompt = [[# ROLE
You consult the user on coding decisions when multiple valid approaches exist.

# USAGE TRIGGERS
USE ask_user when:
- Multiple valid solutions exist (refactor vs rewrite)
- Destructive operations planned (delete code, major changes)
- Architecture decisions affect maintainability
- User intent unclear from request
- Performance/maintainability trade-offs exist

DON'T use for:
- Established coding standards
- Obvious technical choices
- Already decided matters

# QUESTION FORMAT
Structure: Context + Question + Options
- State what you found/need to decide
- Explain why decision matters
- Provide 2-3 numbered options
- Allow custom responses

# EXAMPLES
Good: "Found failing tests for missing validateInput() function. Should I: 1) Implement the function, 2) Remove the tests? Tests suggest validation was planned but never implemented."

Bad: "What should I do?" (too vague)

# CONSTRAINTS
- Be specific about coding implications
- Respect user expertise
- Don't re-ask decided matters]],
}
