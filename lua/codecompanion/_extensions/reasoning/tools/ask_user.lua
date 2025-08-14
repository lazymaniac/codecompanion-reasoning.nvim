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
      description = 'Ask the user a question when multiple valid approaches exist or when user input is needed for decision making.',
      parameters = {
        type = 'object',
        properties = {
          question = {
            type = 'string',
            description = 'The question to ask the user. Be clear and specific about what decision needs to be made.',
          },
          options = {
            type = 'array',
            items = { type = 'string' },
            description = 'Optional list of predefined choices. If provided, user can select by number or provide custom response.',
          },
          context = {
            type = 'string',
            description = 'Additional context about why this decision is needed and what the implications are.',
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

      -- Format the user response for chat
      local output = fmt('**User Response:**\n%s\n\n**Original Question:** %s', result, question)
      chat:add_tool_output(self, output)
    end,

    error = function(self, agent, cmd, stderr)
      local chat = agent.chat
      local errors = vim.iter(stderr):flatten():join('\n')
      local question = self.args.question or 'No question provided'
      local output = fmt('**User cancelled:** %s\n\n**Original Question:** %s', errors, question)
      chat:add_tool_output(self, output)
    end,
  },

  -- System prompt
  system_prompt = fmt([[# Ask User Tool (`ask_user`)

## CONTEXT
- You have access to an interactive question tool that allows you to ask the user for input when facing decision points.
- Use this tool when there are multiple valid approaches and user expertise/preference is needed.
- This enables collaborative problem-solving rather than making assumptions about user intent.

## WHEN TO USE
- **Multiple Valid Solutions:** When there are several reasonable approaches (e.g., refactor vs rewrite, remove test vs implement feature)
- **Destructive Operations:** Before making potentially unwanted changes (e.g., deleting code, major refactoring)
- **Architectural Decisions:** When design patterns or technology choices affect long-term maintainability
- **Ambiguous Requirements:** When user intent is unclear from the original request
- **Trade-off Decisions:** When there are performance/maintainability/complexity trade-offs to consider

## WHEN NOT TO USE
- **Clear Best Practices:** Don't ask about well-established coding standards
- **Simple Implementation Details:** Don't ask about obvious technical choices
- **Already Specified:** Don't re-ask about things the user has already decided

## RESPONSE FORMAT
- Ask clear, specific questions that help guide the solution
- Provide context about why the decision matters
- Include numbered options when there are clear alternatives
- Allow for custom responses beyond the provided options

## EXAMPLES
Good: "I found failing tests for a missing `validateInput()` function. Should I: 1) Implement the missing function, or 2) Remove the failing tests? The tests suggest input validation was planned but never implemented."

Bad: "What should I do?" (too vague)
Bad: "Should I use camelCase or snake_case?" (established by project conventions)

## COLLABORATION APPROACH
- Present the decision clearly with relevant context
- Explain the implications of different choices
- Respect user expertise and preferences
- Use their input to guide subsequent implementation]]),
}
