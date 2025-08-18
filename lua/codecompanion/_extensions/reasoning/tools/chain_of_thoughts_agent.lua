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

local Actions = {}

function Actions.reflect(args, agent_state)
  if not agent_state.current_instance then
    return { status = 'error', data = 'Agent not initialized. This should not happen with auto-initialization.' }
  end

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

  if args.reflection and args.reflection ~= '' then
    table.insert(output_parts, fmt('\nUser Reflection:\n%s', args.reflection))
  end

  return {
    status = 'success',
    data = table.concat(output_parts, '\n'),
  }
end

function Actions.add_step(args, agent_state)
  if not agent_state.current_instance then
    return { status = 'error', data = 'Agent not initialized. This should not happen with auto-initialization.' }
  end

  if not args.content or args.content == '' then
    return { status = 'error', data = 'Step content cannot be empty' }
  end

  if not args.step_id or args.step_id == '' then
    return { status = 'error', data = 'Step ID cannot be empty' }
  end

  if not args.step_type or args.step_type == '' then
    return { status = 'error', data = 'Step type must be specified (analysis, reasoning, task, validation)' }
  end

  for _, step in ipairs(agent_state.current_instance.steps) do
    if step.id == args.step_id then
      return { status = 'error', data = fmt("Step ID '%s' already exists. Please use a unique ID.", args.step_id) }
    end
  end

  local success, message =
    agent_state.current_instance:add_step(args.step_type, args.content, args.step_id)
  if not success then
    return { status = 'error', data = message }
  end

  return {
    status = 'success',
    data = fmt(
      [[Step %d: %s

NEXT: Continue reasoning! Call add_step again with step_id="%s" for your next micro-action.
Keep building the chain until problem is solved!]],
      agent_state.current_instance.current_step,
      args.content,
      'step' .. (agent_state.current_instance.current_step + 1)
    ),
  }
end

-- Auto-initialize agent on first use
local function auto_initialize(agent_state, problem)
  if agent_state.current_instance then
    return nil
  end

  log:debug('[Chain of Thought Agent] Initializing with problem: %s', problem)

  agent_state.session_id = tostring(os.time())
  agent_state.current_instance = ChainOfThoughts.new(problem)
  agent_state.current_instance.agent_type = 'Chain of Thought Agent'

  -- Load project context
  local MemoryEngine = require('codecompanion._extensions.reasoning.helpers.memory_engine')
  local context_summary, context_files = MemoryEngine.load_project_context()
  agent_state.project_context = context_files

  local init_message = fmt(
    [[🔗 Chain of Thoughts Agent activated for: %s

INITIALIZED: Ready for micro step-by-step reasoning!

START: Call add_step with your first micro-action, than continue to build the problem solving chain.

REMEMBER: Take small focused steps - find file → read content → make change → test → ...]],
    problem
  )

  if #context_files > 0 then
    init_message = init_message .. '\n\n' .. context_summary
  end

  return init_message
end

-- Create the tool definition with auto-initialization
local function handle_action(args)
  local agent_state = _G._codecompanion_chain_of_thoughts_state or {}
  _G._codecompanion_chain_of_thoughts_state = agent_state

  if not agent_state.current_instance then
    local problem = args.content or 'Coding task requested'
    local init_message = auto_initialize(agent_state, problem)

    if init_message then
      if args.action == 'add_step' then
        local step_result = Actions.add_step(args, agent_state)
        return {
          status = 'success',
          data = init_message .. '\n\n---\n\n' .. step_result.data,
        }
      elseif args.action == 'reflect' then
        local reflect_result = Actions.reflect(args, agent_state)
        return {
          status = 'success',
          data = init_message .. '\n\n---\n\n' .. reflect_result.data,
        }
      else
        return { status = 'success', data = init_message }
      end
    end
  end

  local action = Actions[args.action]
  if not action then
    return { status = 'error', data = 'Invalid action: ' .. (args.action or 'nil') }
  end

  local validation_rules = {
    add_step = { 'step_id', 'content', 'step_type' },
    reflect = {},
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
      description = 'Sequential micro-step coding solver: auto-initializes on first use. Use for debugging, implementing features, refactoring step-by-step. WORKFLOW: Take ONE small action → Analyze result → Ask user if needed → Next micro-step → REPEAT. Call add_step with your FIRST action, then CONTINUE with multiple calls. Take small focused steps: find file → read → change → test. Use ask_user for decisions.',
      parameters = {
        type = 'object',
        properties = {
          action = {
            type = 'string',
            description = "The reasoning action to perform: 'add_step', 'reflect'",
          },
          step_id = {
            type = 'string',
            description = "Unique identifier for the reasoning step (required for 'add_step')",
          },
          content = {
            type = 'string',
            description = "The reasoning step content or thought (required for 'add_step')",
          },
          step_type = {
            type = 'string',
            description = "Type of reasoning step: 'analysis', 'reasoning', 'task', 'validation' (required for 'add_step')",
          },
          reflection = {
            type = 'string',
            description = "Reflection on the reasoning process and outcomes (optional for 'reflect')",
          },
        },
        required = { 'action' },
        additionalProperties = false,
      },
      strict = true,
    },
  },
}
