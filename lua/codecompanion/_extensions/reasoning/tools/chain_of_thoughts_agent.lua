---@class CodeCompanion.ChainOfThoughtAgent

local ChainOfThoughts = require('codecompanion._extensions.reasoning.helpers.chain_of_thoughts')
local ReasoningVisualizer = require('codecompanion._extensions.reasoning.helpers.reasoning_visualizer')
local log_ok, log = pcall(require, 'codecompanion.utils.log')
if not log_ok then
  -- Fallback logging when CodeCompanion log is not available
  log = {
    debug = function(...) end,
    error = function(...)
      vim.notify(string.format(...), vim.log.levels.ERROR)
    end,
  }
end
local fmt = string.format

local step_count = 0

local Actions = {}

function Actions.add_step(args, agent_state)
  if not args.content or args.content == '' then
    return { status = 'error', data = 'Step content cannot be empty' }
  end

  if not args.step_type or args.step_type == '' then
    return { status = 'error', data = 'Step type must be specified (analysis, reasoning, task, validation)' }
  end

  step_count = step_count + 1
  local success, message = agent_state.current_instance:add_step(args.step_type, args.content, step_count)
  if not success then
    return { status = 'error', data = message }
  end

  return {
    status = 'success',
    data = fmt('%s: %s', args.step_type, args.content),
  }
end

function Actions.reflect(args, agent_state)
  if #agent_state.current_instance.steps == 0 then
    return { status = 'error', data = 'No steps to reflect on. Add some steps first.' }
  end

  local reflection_analysis = agent_state.current_instance:reflect()

  local output_parts = {}

  table.insert(output_parts, 'Reflection Analysis')
  table.insert(output_parts, fmt('Total steps: %d', reflection_analysis.total_steps))

  if #reflection_analysis.insights > 0 then
    table.insert(output_parts, '\nInsights:')
    for _, insight in ipairs(reflection_analysis.insights) do
      table.insert(output_parts, fmt('• %s', insight))
    end
  end

  if #reflection_analysis.improvements > 0 then
    table.insert(output_parts, '\nSuggested Improvements:')
    for _, improvement in ipairs(reflection_analysis.improvements) do
      table.insert(output_parts, fmt('• %s', improvement))
    end
  end

  if args.content and args.content ~= '' then
    table.insert(output_parts, fmt('\nUser Reflection:\n%s', args.content))
  end

  return {
    status = 'success',
    data = table.concat(output_parts, '\n'),
  }
end

local function initialize(agent_state)
  if agent_state.current_instance then
    return nil
  end

  log:debug('[Chain of Thought Agent] Initializing')

  agent_state.session_id = tostring(os.time())
  agent_state.current_instance = ChainOfThoughts.new()
  agent_state.current_instance.agent_type = 'Chain of Thought Agent'
end

local function handle_action(args)
  local agent_state = _G._codecompanion_chain_of_thoughts_state or {}

  local action = Actions[args.action]
  if not action then
    return { status = 'error', data = 'Invalid action: ' .. (args.action or 'nil') }
  end

  local validation_rules = {
    add_step = { 'content', 'step_type' },
    reflect = { 'content' },
  }

  local required_fields = validation_rules[args.action] or {}
  for _, field in ipairs(required_fields) do
    if not args[field] or args[field] == '' then
      return { status = 'error', data = fmt('%s is required for %s action', field, args.action) }
    end
  end

  return action(args, agent_state)
end

---@class CodeCompanion.Tool.ChainOfThoughtsAgent: CodeCompanion.Tools.Tool
return {
  name = 'chain_of_thoughts_agent',
  cmds = {
    function(self, args, input)
      return handle_action(args)
    end,
  },
  schema = {
    type = 'function',
    ['function'] = {
      name = 'chain_of_thoughts_agent',
      description = 'Sequential step-by-step coding solver. SUGGESTED WORKFLOW: 1. Use project_context tool to discover project context 2. Call add_step with your first small step 3. Use ask_user for decisions/validation during reasoning if needed 4. Continue building the solution chain step-by-step 5. Call reflect to analyze progress and insights. Take small focused steps: find file → read → change → test. ALWAYS use companion tools: project_context for context, ask_user for decisions, add_tools for capabilities.',
      parameters = {
        type = 'object',
        properties = {
          action = {
            type = 'string',
            description = "The reasoning action to perform: 'add_step', 'reflect'",
            enum = { 'add_step', 'reflect' },
          },
          content = {
            type = 'string',
            description = "The reasoning step content or thought (required for 'add_step' and 'reflect')",
          },
          step_type = {
            type = 'string',
            description = "Type of reasoning step (required for 'add_step')",
            enum = { 'analysis', 'reasoning', 'task', 'validation' },
          },
        },
        required = { 'action' },
        additionalProperties = false,
      },
      strict = true,
    },
  },
  handlers = {
    setup = function(self, tools)
      local agent_state = _G._codecompanion_chain_of_thoughts_state or {}
      _G._codecompanion_chain_of_thoughts_state = agent_state
      initialize(agent_state)
    end,
    on_exit = function(agent)
      log:debug('[Chain of Thoughts Agent] Session ended')
    end,
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
