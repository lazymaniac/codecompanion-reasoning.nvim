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
Interactive consultation for coding decisions. This tool is designed to help you work together with user not alone.

PROACTIVE USE (at task start):
- Request is vague or lacks specifics ("make this better", "fix issues", "improve performance")
- Multiple valid solutions exist with different trade-offs (refactor vs rewrite, library choices, implement code vs remove test)
- Missing key details (target files, scope, constraints, success criteria)
- User intent unclear or assumptions need validation
- Destructive operations planned (delete code, breaking changes, major refactors)

ONGOING USE (during work) example use cases:
- Architecture decisions affecting maintainability
- Performance/maintainability trade-offs
- Before irreversible changes
- You need guidance to make sure what user want
- You need assistance to point you in the right direction
- You want to be proactive and propose improvements to the code you encountered
- You want to create new file instead of editing exisiting one
- You need to confirm your thinking is correct

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
            description = 'Clear, concise and specific question that needs user input. State what you found/need to decide, explain why decision matters. STRUCTURE: Context + Reasoning. EXAMPLES:\n\nPROACTIVE: "Your request to \'improve the validation code\' could mean several things. Knowing the focus helps me provide the right solution."\n\nONGOING: "Found failing tests for missing validateInput() function. Tests suggest validation was planned but never implemented."\n\nBAD: "What should I do?" (too vague)',
          },
          options = {
            type = 'array',
            items = { type = 'string' },
            description = 'Numbered choices for user. Provide numbered options allowing custom responses. User can select by number or provide custom response. Example: ["Implement the missing function", "Remove the failing tests", "Refactor approach entirely"]',
          },
        },
        required = {
          'question',
          'options',
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
