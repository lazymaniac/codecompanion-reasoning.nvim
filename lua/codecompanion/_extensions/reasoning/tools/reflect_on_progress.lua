---@class CodeCompanion.ReflectOnProgress

local log_ok, log = pcall(require, 'codecompanion.utils.log')
if not log_ok then
  log = {
    debug = function(...) end,
    error = function(...)
      vim.notify(string.format(...), vim.log.levels.ERROR)
    end,
  }
end
local fmt = string.format

local function handle_action(args)
  log:debug('[Reflect on Progress] Reflecting')

  return {
    status = 'success',
    data = args.content,
  }
end

---@class CodeCompanion.Tool.ReflectOnProgress: CodeCompanion.Tools.Tool
return {
  name = 'reflect_on_progress',
  cmds = {
    function(self, args, input)
      return handle_action(args)
    end,
  },
  schema = {
    type = 'function',
    ['function'] = {
      name = 'reflect_on_progress',
      description = [[
Universal reflection tool for reasoning agent. Analyzes current reasoning progress and provides insights.

REFLECTION CAPABILITIES
- Progress Assessment: Evaluates reasoning depth and coverage across different agent types
- Pattern Analysis: Identifies reasoning patterns, gaps, and areas for improvement
- Strategic Guidance: Suggests next steps based on current reasoning state and agent type
- Meta-Analysis: Provides insights into the reasoning process itself

AUTOMATIC AGENT DETECTION
- Detects which reasoning agent is currently active (Chain, Tree, or Graph)
- Adapts reflection output to match the agent's specific reasoning pattern
- Provides agent-appropriate insights and recommendations

WHEN TO USE
- After significant reasoning progress to assess direction
- When feeling stuck or uncertain about next steps
- To identify gaps in analysis or reasoning
- Before making major decisions or conclusions
- To synthesize findings from different reasoning branches

OUTPUT INCLUDES
- Current reasoning state summary
- Insights about reasoning patterns and progress
- Specific improvement suggestions for the active agent
- Your personal reflection if provided

EXAMPLE USAGE
- After exploring multiple problem angles: assess coverage and depth
- Before implementing solutions: validate reasoning completeness
- During complex problems: check if all dimensions are considered
- When switching between reasoning approaches: compare effectiveness
]],
      parameters = {
        type = 'object',
        properties = {
          content = {
            type = 'string',
            description = 'Your reflection on the current reasoning process. Share observations, insights, conclusions, or questions about your progress. This personalizes the analysis and helps contextualize the agent feedback.',
          },
        },
        required = { 'content' },
        additionalProperties = false,
      },
      strict = true,
    },
  },
  output = {
    success = function(self, tools, cmd, stdout)
      local chat = tools.chat
      return chat:add_tool_output(self, tostring(stdout[1]))
    end,
    error = function(self, tools, cmd, stderr)
      local chat = tools.chat
      return chat:add_tool_output(self, tostring(stderr[1]))
    end,
  },
}
