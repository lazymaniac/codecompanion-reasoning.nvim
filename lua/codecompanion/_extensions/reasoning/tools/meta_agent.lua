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
        [[# CODING TASK ANALYSIS
Problem: %s

## ALGORITHM OPTIONS
• **Chain**: Sequential tasks (debug → implement → refactor → fix)
• **Tree**: Design decisions (architecture, API patterns, solution exploration)
• **Graph**: Complex systems (microservices, dependencies, integrations)

## WORKFLOW
1. Analyze problem → 2. Pick optimal algorithm → 3. Deploy immediately

Analyzing and selecting optimal approach...]],
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
      description = 'Analyzes coding tasks and immediately deploys optimal reasoning algorithm. Use select_algorithm to analyze, then add_algorithm to deploy.',
      parameters = {
        type = 'object',
        properties = {
          action = {
            type = 'string',
            description = "STEP 1: 'select_algorithm' to analyze problem, STEP 2: 'add_algorithm' to deploy chosen algorithm",
            enum = { 'select_algorithm', 'add_algorithm' },
          },
          problem = {
            type = 'string',
            description = 'Your coding task: be specific about what you need to accomplish',
          },
          algorithm = {
            type = 'string',
            description = 'Selected algorithm: chain_of_thoughts_agent (sequential), tree_of_thoughts_agent (design), graph_of_thoughts_agent (systems)',
            enum = { 'chain_of_thoughts_agent', 'tree_of_thoughts_agent', 'graph_of_thoughts_agent' },
          },
        },
        required = { 'action' },
        additionalProperties = false,
      },
      strict = true,
    },
  },
  system_prompt = [[# ROLE
Expert coding algorithm selector. Analyze problems and immediately deploy the optimal reasoning approach.

# DECISION MATRIX
Chain: Step-by-step progression (find→read→change→test one thing at a time)
Tree: Explore alternatives (try small experiments, compare approaches, ask user)
Graph: System building (map components, trace connections, evolve architecture)

# MANDATORY WORKFLOW
1. When user asks for algorithm selection:
   → First call: meta_agent with select_algorithm
   → Analyze problem and pick algorithm
   → Second call: meta_agent with add_algorithm
   → Deploy the chosen algorithm

# OUTPUT FORMAT (for select_algorithm)
Problem: [task type in 3-4 words]
Algorithm: [chain|tree|graph] [confidence%]
Reason: [why this algorithm in 5-6 words]

# ALGORITHM MAPPING
chain → chain_of_thoughts_agent
tree → tree_of_thoughts_agent
graph → graph_of_thoughts_agent

# CRITICAL: After select_algorithm analysis, you MUST immediately call add_algorithm

# EXAMPLES
Input: "Fix authentication bug"
Step 1 Output:
Problem: Authentication bug troubleshooting
Algorithm: chain 95%
Reason: Sequential debugging steps required

Step 2: IMMEDIATELY call add_algorithm with algorithm="chain_of_thoughts_agent"

Input: "Design REST API"
Step 1 Output:
Problem: REST API design patterns
Algorithm: tree 90%
Reason: Multiple design approaches to explore

Step 2: IMMEDIATELY call add_algorithm with algorithm="tree_of_thoughts_agent"

# CONSTRAINTS
- NEVER stop after step 1
- ALWAYS follow analysis with deployment
- Be decisive and complete workflow]],
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

          -- Add companion tools (ask_user and add_tools) for full functionality
          local companion_tools = { 'ask_user', 'add_tools' }
          local added_companions = {}

          for _, tool_name in ipairs(companion_tools) do
            local tool_config = tools_config[tool_name]
            if tool_config then
              chat.tool_registry:add(tool_name, tool_config)
              table.insert(added_companions, tool_name)
            end
          end

          local success_message =
            fmt([[✅ %s ready! Companion tools: %s]], algorithm, table.concat(added_companions, ', '))

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
