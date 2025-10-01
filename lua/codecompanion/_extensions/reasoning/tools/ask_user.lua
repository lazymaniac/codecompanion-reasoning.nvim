local fmt = string.format

---@class CodeCompanion.Tool.AskUser: CodeCompanion.Tools.Tool
return {
  name = 'ask_user',
  opts = {},
  cmds = {
    function(self, args, input, callback)
      self.args = args

      local question = args.question or 'No question provided'
      local options = args.options or {}

      local Popup = require('codecompanion._extensions.reasoning.ui.popup')

      vim.schedule(function()
        Popup.ask_question(question, options, function(response, cancelled, selected_option)
          if cancelled then
            callback({
              status = 'error',
              data = 'User cancelled the question',
            })
          else
            callback({
              status = 'success',
              data = { response or selected_option },
            })
          end
        end)
      end)
    end,
  },
  schema = {
    type = 'function',
    ['function'] = {
      name = 'ask_user',
      description = [[
Interactive consultation for coding decisions when multiple valid approaches exist.

PROACTIVE USE (at task start):
- Request is vague or lacks specifics ("make this better", "fix issues", "improve performance")
- Multiple valid solutions exist with different trade-offs (refactor vs rewrite, library choices, implement code vs remove test)
- Missing key details (target files, scope, constraints, success criteria)
- User intent unclear or assumptions need validation
- Destructive operations planned (delete code, breaking changes, major refactors)
- You want to create new file instead of editing exisiting one

ONGOING USE (during work):
- Architecture decisions affecting maintainability
- Performance/maintainability trade-offs
- Before irreversible changes
- When encountering unexpected issues requiring direction
- You need consultation with user

DON'T use for:
- Established coding standards or obvious technical choices
- Already decided matters or clear requirements
- Simple implementation details with one obvious approach
]],
      parameters = {
        type = 'object',
        properties = {
          question = {
            type = 'string',
            description = 'Clear, concise and specific question about any ambiguity that needs user input. State what you found/need to decide, explain why decision matters. STRUCTURE: Context + Options + Reasoning. EXAMPLES:\n\nPROACTIVE: "Your request to \'improve the validation code\' could mean several things. Should I: 1) Fix specific bugs in existing validators, 2) Add missing validation cases, 3) Refactor for better performance? Knowing the focus helps me provide the right solution."\n\nONGOING: "Found failing tests for missing validateInput() function. Should I: 1) Implement the function, 2) Remove the tests? Tests suggest validation was planned but never implemented."\n\nBAD: "What should I do?" (too vague)',
          },
          options = {
            type = 'array',
            items = { type = 'string' },
            description = 'Numbered choices for user (optional). Provide 2-3 numbered options allowing custom responses. User can select by number or provide custom response. Example: ["Implement the missing function", "Remove the failing tests", "Refactor approach entirely"]',
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

      return chat:add_tool_output(self, fmt('Answer: %s', result))
    end,

    error = function(self, agent, cmd, stderr)
      local chat = agent.chat
      local errors = vim.iter(stderr):flatten():join('\n')

      chat:add_tool_output(self, fmt('Cancelled: %s', errors))
    end,
  },
}
