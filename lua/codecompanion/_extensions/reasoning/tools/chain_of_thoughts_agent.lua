---@class CodeCompanion.ChainOfThoughtAgent

-- ChainOfThoughts class (merged from helpers/chain_of_thoughts.lua)
local ChainOfThoughts = {}
ChainOfThoughts.__index = ChainOfThoughts

function ChainOfThoughts.new()
  local self = setmetatable({}, ChainOfThoughts)
  self.steps = {}
  self.current_step = 0
  return self
end

local STEP_TYPES = {
  analysis = true,
  reasoning = true,
  task = true,
  validation = true,
}

-- Add a step to the chain
function ChainOfThoughts:add_step(step_type, content, step_id)
  if STEP_TYPES[step_type] == nil then
    return false, 'Invalid step type. Valid types are: ' .. table.concat(vim.tbl_keys(STEP_TYPES), ', ')
  end

  if not content or content == '' then
    return false, 'Step content cannot be empty'
  end

  if not step_id or step_id == '' then
    return false, 'Step ID cannot be empty'
  end

  self.current_step = self.current_step + 1
  local step = {
    id = step_id,
    type = step_type,
    content = content,
    step_number = self.current_step,
    timestamp = os.time(),
  }

  table.insert(self.steps, step)
  return true, 'Step added successfully'
end

-- Reflect on the reasoning process
function ChainOfThoughts:reflect()
  local insights = {}
  local improvements = {}

  -- Handle empty chain
  if #self.steps == 0 then
    return {
      total_steps = 0,
      insights = { 'No steps to analyze' },
      improvements = { 'Add reasoning steps to begin analysis' },
    }
  end

  -- Analyze step distribution
  local step_counts = {}
  for _, step in ipairs(self.steps) do
    step_counts[step.type] = (step_counts[step.type] or 0) + 1
  end

  table.insert(insights, string.format('Step distribution: %s', table.concat(self:table_to_strings(step_counts), ', ')))

  -- Check for logical progression
  local has_analysis = step_counts.analysis and step_counts.analysis > 0
  local has_reasoning = step_counts.reasoning and step_counts.reasoning > 0
  local has_tasks = step_counts.task and step_counts.task > 0
  local has_validation = step_counts.validation and step_counts.validation > 0

  if has_analysis and has_reasoning and has_tasks then
    table.insert(insights, 'Good logical progression from analysis to implementation')
  else
    if not has_analysis then
      table.insert(improvements, 'Consider adding analysis steps to explore the problem')
    end
    if not has_reasoning then
      table.insert(improvements, 'Consider adding reasoning steps for logical deduction')
    end
    if not has_tasks then
      table.insert(improvements, 'Consider adding task steps for actionable implementation')
    end
  end

  if not has_validation then
    table.insert(improvements, 'Add validation steps to verify reasoning')
  end

  -- Check for reasoning quality
  local steps_with_reasoning = 0
  for _, step in ipairs(self.steps) do
    if step.reasoning and step.reasoning ~= '' then
      steps_with_reasoning = steps_with_reasoning + 1
    end
  end

  if steps_with_reasoning < #self.steps * 0.5 then
    table.insert(improvements, 'Consider adding more detailed reasoning explanations to steps')
  else
    table.insert(insights, 'Good coverage of reasoning explanations across steps')
  end

  return {
    total_steps = #self.steps,
    insights = insights,
    improvements = improvements,
  }
end

-- Helper function to convert table to strings
function ChainOfThoughts:table_to_strings(t)
  local result = {}
  for k, v in pairs(t) do
    table.insert(result, k .. ':' .. tostring(v))
  end
  return result
end

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

  -- Add visual representation first
  local visualization = ReasoningVisualizer.visualize_chain(agent_state.current_instance)
  table.insert(output_parts, visualization)
  table.insert(output_parts, '')

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
      description = [[Sequential step-by-step software engineering problem solver.

SUGGESTED WORKFLOW:
1. Use `project_context` to understand more about the project you will work on
2. Call `add_step` with your first chunk of the problem to analyze
3. Use `ask_user` for decisions/validation during reasoning if needed
4. Continue building the solution, each time by small step-by-step
5. Call `reflect` to analyze progress and get some insights.

IMPORTANT:
Take small focused steps: analysis → find file → read → change part of code → test → change another part of code → test → reasoning → analysis...
ALWAYS use companion tools:
 - `project_context` to get information about project like styling, testing, code structure etc.
 - `ask_user` for decisions, user help and opinions
 - `add_tools` for enhanced capabilities (like tools designed for looking for files, editing code, getting context of code symbols, executing bash commands to run tests...).
 ALWAYS take small but thoughtful and precise steps to maintain highest quality of produced solution.
 ALWAYS try to keep your token usage as low as possible BUT without sacrificing quality.
 ALWAYS try to squeeze as much of this tool as possible, it is designed to help you with reasoning, deduction, logical thinking, reflection and actually solving the problem in a best possible way without shortcuts or any guesses.
]],
      parameters = {
        type = 'object',
        properties = {
          action = {
            type = 'string',
            description = 'The reasoning action to perform: `add_step`, `reflect`',
            enum = { 'add_step', 'reflect' },
          },
          content = {
            type = 'string',
            description = 'The reasoning step content or thought (required for `add_step` and `reflect`). Make it concise, focused and thoughtful.',
          },
          step_type = {
            type = 'string',
            description = [[Node type: `analysis`, `reasoning`, `task`, `validation` (required for `add_step`)

Instructions:
'analysis' - Analysis and exploration of the chunk of the problem.
'reasoning' - Logical deduction and inference based on evidence.
'task' - Small actionable step towards the final goal.
'validation' - Actionable step that actually verifies current progress (like running test suite or removing, edititng or adding new test cases...)
]],
            enum = { 'analysis', 'reasoning', 'task', 'validation' },
          },
        },
        required = { 'action', 'content' },
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
