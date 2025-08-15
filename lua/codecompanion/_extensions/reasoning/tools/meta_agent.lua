local config_ok, config = pcall(require, 'codecompanion.config')
if not config_ok then
  config = { strategies = { chat = { tools = {} } } }
end

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

-- Simple meta agent: problem in, agent out
-- The LLM reads the descriptions and picks the best match
-- Then dynamically adds the selected agent to the chat

-- Store the algorithm to add in global state so success handler can access it
local pending_algorithm_addition = nil

local function handle_action(args)
  if args.action == 'select_algorithm' then
    if not args.problem then
      return { status = 'error', data = 'problem is required' }
    end

    log:debug('[Meta Agent] Selecting algorithm for: %s', args.problem)

    return {
      status = 'success',
      data = fmt(
        [[# Algorithm Selection for Problem

**Problem:** %s

## Available Reasoning Algorithms:

### chain_of_thoughts_agent
**Best for:** Step-by-step problems, debugging, sequential analysis, linear reasoning
**Description:** Follows logical steps one by one, good for systematic problem solving

### tree_of_thoughts_agent
**Best for:** Exploring multiple solutions, creative problems, coding tasks, when you need different approaches
**Description:** Explores multiple solution paths in a tree structure, evaluates different approaches

### graph_of_thoughts_agent
**Best for:** Complex workflows, operations with dependencies, parallel processing, structured tasks
**Description:** Creates operation graphs with dependencies, handles complex multi-step workflows

## Instructions:
1. Read the problem and algorithm descriptions above
2. Pick the algorithm that best matches the problem type
3. Use 'add_algorithm' action with the selected algorithm name

The selected algorithm will be dynamically added to this chat and become available for use.]],
        args.problem
      ),
    }
  elseif args.action == 'add_algorithm' then
    if not args.algorithm then
      return { status = 'error', data = 'algorithm is required' }
    end

    local valid_algorithms = { 'chain_of_thoughts_agent', 'tree_of_thoughts_agent', 'graph_of_thoughts_agent' }
    if not vim.tbl_contains(valid_algorithms, args.algorithm) then
      return {
        status = 'error',
        data = fmt('Invalid algorithm. Must be one of: %s', table.concat(valid_algorithms, ', ')),
      }
    end

    log:debug('[Meta Agent] Preparing to add algorithm: %s', args.algorithm)

    -- Store algorithm for success handler to process
    pending_algorithm_addition = args.algorithm

    return {
      status = 'success',
      data = fmt('Preparing to add %s to chat...', args.algorithm),
    }
  else
    return { status = 'error', data = "Actions supported: 'select_algorithm', 'add_algorithm'" }
  end
end

---@class CodeCompanion.Tool.MetaAgent: CodeCompanion.Tools.Tool
return {
  name = 'meta_agent',
  cmds = {
    function(self, args, input)
      return handle_action(args)
    end,
  },
  schema = {
    type = 'function',
    ['function'] = {
      name = 'meta_agent',
      description = 'Algorithm selector that shows available reasoning algorithms and dynamically adds the selected one to the chat',
      parameters = {
        type = 'object',
        properties = {
          action = {
            type = 'string',
            description = "The action to perform: 'select_algorithm' or 'add_algorithm'",
          },
          problem = {
            type = 'string',
            description = "The problem to solve (required for 'select_algorithm')",
          },
          algorithm = {
            type = 'string',
            description = "The algorithm to add to chat (required for 'add_algorithm'): 'chain_of_thoughts_agent', 'tree_of_thoughts_agent', or 'graph_of_thoughts_agent'",
          },
        },
        required = { 'action' },
        additionalProperties = false,
      },
      strict = true,
    },
  },
  system_prompt = [[# Meta Agent: Algorithm Selector & Dynamic Tool Manager

You help select the best reasoning algorithm for a problem and dynamically add it to the chat.

**Instructions**:
1. First call `select_algorithm` with the problem - shows algorithm options
2. Then call `add_algorithm` with chosen algorithm - adds it to the chat dynamically

**Result**:
After adding, selected algorithm will be available in the chat.]],
  output = {
    success = function(self, agent, cmd, stdout)
      local chat = agent.chat
      local result = vim.iter(stdout):flatten():join('\n')

      -- Check if we need to add an algorithm to the chat
      if pending_algorithm_addition then
        local algorithm = pending_algorithm_addition
        pending_algorithm_addition = nil -- Clear the pending state

        log:debug('[Meta Agent] Adding algorithm to chat: %s', algorithm)

        -- Get the tool configuration
        local tools_config = config.strategies.chat.tools
        local algorithm_config = tools_config[algorithm]

        if algorithm_config and chat.tool_registry then
          -- Add the reasoning algorithm
          chat.tool_registry:add(algorithm, algorithm_config)

          -- Add companion tools (ask_user and tool_discovery) for full functionality
          local companion_tools = { 'ask_user', 'tool_discovery' }
          local added_companions = {}

          for _, tool_name in ipairs(companion_tools) do
            local tool_config = tools_config[tool_name]
            if tool_config then
              chat.tool_registry:add(tool_name, tool_config)
              table.insert(added_companions, tool_name)
            end
          end

          local companions_list = #added_companions > 0 and (', ' .. table.concat(added_companions, ', ')) or ''
          local success_message = fmt(
            [[✅ Reasoning agent '%s' selected and ready! 🎯

The %s%s have been dynamically added to this chat.

## Next Steps:
You can now use the %s directly to solve your problem. The algorithm will act as the governor and coordinate the entire problem-solving workflow.

**Available companion tools:** %s - Use these for interactive decision-making and tool discovery.]],
            algorithm,
            algorithm,
            companions_list,
            algorithm,
            table.concat(added_companions, ', ')
          )

          chat:add_tool_output(self, success_message, success_message)
        else
          chat:add_tool_output(
            self,
            fmt('❌ FAILED to add reasoning algorithm: %s (algorithm config unavailable)', algorithm)
          )
        end
      else
        chat:add_tool_output(self, result, result)
      end
    end,
    error = function(self, agent, cmd, stderr)
      local chat = agent.chat
      local errors = vim.iter(stderr):flatten():join('\n')
      pending_algorithm_addition = nil -- Clear pending state on error
      chat:add_tool_output(self, fmt('❌ Meta Agent ERROR: %s', errors))
    end,
  },
}
