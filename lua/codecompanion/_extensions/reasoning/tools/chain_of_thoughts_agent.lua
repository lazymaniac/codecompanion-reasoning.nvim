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

  -- Short-term memory trace (last 6 steps)
  local function trace()
    local items = {}
    local steps = agent_state.current_instance.steps
    local start = math.max(1, #steps - 5)
    for i = start, #steps do
      local s = steps[i]
      local snippet = s.content
      if #snippet > 40 then
        snippet = snippet:sub(1, 37) .. '...'
      end
      table.insert(items, string.format('#%d %s', s.step_number or i, s.type))
    end
    return table.concat(items, ' → ')
  end

  return {
    status = 'success',
    data = fmt('%s: %s\nTrace: %s', args.step_type, args.content, trace()),
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
      description = [[Structured, stepwise software reasoning agent for complex tasks. Records labeled steps (analysis, reasoning, task, validation), and performs periodic reflection to improve plan and execution.

USE WHEN
- Multi-step changes, unclear code paths, or cross-file impact.

WORKFLOW
1) Use the auto-injected project knowledge for conventions. Discover and add needed tools via `add_tools` (list first, then add).
2) Add small steps with `action="add_step"` and `step_type` in {analysis, reasoning, task, validation}.
3) Reflect with `action="reflect"` after every 3–5 steps to adjust plan.
4) Use `ask_user` before destructive changes or when multiple viable paths exist.

RULES
- Precision: One decision/change per step; keep step content ≤ 280 chars.
- Validation: After any code edit, immediately add a validation step (run tests, lint, or a verifiable check).
-- Evidence: Ground your actions in observed facts (file paths, test output, diffs, line refs). Include this in your reasoning.
- Tooling: First `add_tools(action="list_tools")`, then `add_tools(action="add_tool", tool_name="<from list>")`. Do not assume tool names.
- Safety: Use `ask_user` before deletions, large rewrites, or API changes.
- Output: Do not dump raw chain-of-thought; provide concise reasoning and the next concrete action.

IF TESTS ARE ABSENT
- Create minimal tests or `ask_user` to confirm an alternative verification strategy.

COMPLETION
- After successful implementation, call `project_knowledge` with a concise description and affected files.

STOP WHEN
- Success criteria met; waiting on user input; destructive action requires confirmation; repeated failures demand strategy change.

EXAMPLE (minimal)
- `add_tools(action="list_tools")`
- `add_tools(action="add_tool", tool_name="<needed_tool_from_list>")`
- `chain_of_thoughts_agent(action="add_step", step_type="analysis", content="Locate failing tests for validateInput and expected behavior")`
- [use read/edit tools]
- `chain_of_thoughts_agent(action="add_step", step_type="task", content="Implement missing validateInput behavior")`
- `chain_of_thoughts_agent(action="add_step", step_type="validation", content="Run tests and confirm validateInput passes")`
- `chain_of_thoughts_agent(action="reflect", content="Summarize progress and next steps")`
- `project_knowledge(description="Implemented validateInput; added tests", files=["<files...>"])`
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
'validation' - MANDATORY step that verifies current progress, especially REQUIRED after any code changes. This includes: running test suite, creating new tests, updating existing tests, executing code to verify functionality, checking for errors/failures.
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
