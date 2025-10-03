---@class CodeCompanion.ChainOfThoughtAgent

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
local step_count = 0

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

function ChainOfThoughts:table_to_strings(t)
  local result = {}
  for k, v in pairs(t) do
    table.insert(result, k .. ':' .. tostring(v))
  end
  return result
end

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

  local validation_rules = {
    add_step = { 'content', 'step_type' },
  }

  local required_fields = validation_rules[args.action] or {}
  for _, field in ipairs(required_fields) do
    if not args[field] or args[field] == '' then
      return { status = 'error', data = fmt('%s is required for %s action', field, args.action) }
    end
  end

  return Actions.add_step(args, agent_state)
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
      description = [[
Deep Sequential (Chain of Thoughts pattern) Reasoning Agent. This tool is designed to help you guide you through problem solving process and sort your thoughts in a Chain of Thought pattern. Use it often - it's your best friend.

DEPTH REQUIREMENTS (MANDATORY)
- DECOMPOSITION: Break requests into 2-3 analysis steps exploring different problem angles before reasoning
- EVIDENCE GATHERING: Use task steps to investigate context (files, constraints, patterns) before proposing solutions
- VALIDATION MANDATE: Every reasoning conclusion MUST be followed by validation step with concrete verification
- REFLECTION FREQUENCY: Reflect every 4-5 steps to assess completeness and adjust direction

ENFORCED WORKFLOW PATTERN
1) ANALYSIS phase: 2 or more analysis steps examining different aspects of the problem
2) EVIDENCE phase: Task steps gathering contextual information (check existing code, constraints, requirements)
3) REASONING phase: Logical deduction based on gathered evidence
4) IMPLEMENTATION phase: Concrete task steps with specific actions
5) VALIDATION phase: Verify each major reasoning step with tests/checks

EXAMPLE (use as reference)
- Review AVAILABLE TOOLS section to identify optional helpers
- `add_tools(tool_name="list_files")`  — discover code locations fast
- `list_files(dir="lua", glob="**/*validate*.*")`  — find relevant files
- `chain_of_thoughts_agent(step_type="analysis", content="Problem angle 1: failing tests reference utils/validation.lua edge‑case")`
- `chain_of_thoughts_agent(step_type="analysis", content="Problem angle 2: empty string handling inconsistency across codebase")`
- `chain_of_thoughts_agent(step_type="task", content="Check existing validation patterns and empty string handling in codebase")`
- `chain_of_thoughts_agent(step_type="reasoning", content="Root cause: treated empty as truthy based on evidence from validation patterns")`
- `chain_of_thoughts_agent(step_type="task", content="Update validate_input to handle empty/whitespace; preserve existing API")`
- `chain_of_thoughts_agent(step_type="validation", content="Run tests; confirm validate_input cases pass and no regressions")`

FORBIDDEN: Single analysis→reasoning→task chains without evidence gathering or validation
FORBIDDEN: Solutions without investigating existing context first
REQUIRED: Minimum 6 steps for complex tasks (analysis×2, task×2, reasoning×1, validation×1)
]],
      parameters = {
        type = 'object',
        properties = {
          content = {
            type = 'string',
            description = 'The reasoning step content or thought (required for `add_step` and `reflect`). Make it concise, focused and thoughtful.',
          },
          step_type = {
            type = 'string',
            description = [[
Step types:

`analysis` - MANDATORY multi-angle problem exploration. Must examine different aspects/dimensions of the problem. FORBIDDEN: single-perspective analysis. REQUIRED: investigate 2 or more different angles before reasoning.

`task` - Dual purpose: (1) Evidence collection (investigate existing code, patterns, constraints, requirements) OR (2) Concrete implementation actions. MANDATORY: evidence-gathering tasks must precede reasoning steps.

`reasoning` - Evidence-based logical deduction ONLY. MUST reference specific evidence gathered from task steps. FORBIDDEN: reasoning without prior evidence collection. REQUIRED: cite specific findings from investigation.

`validation` - MANDATORY verification after reasoning conclusions. MUST include specific testing/checking steps (run tests, verify functionality, check for regressions). REQUIRED: concrete validation actions, not abstract confirmations.
]],
            enum = { 'analysis', 'reasoning', 'task', 'validation' },
          },
        },
        required = { 'content', 'step_type' },
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
