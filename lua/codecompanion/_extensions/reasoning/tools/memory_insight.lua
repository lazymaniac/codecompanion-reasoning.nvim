local log_ok, log = pcall(require, 'codecompanion.utils.log')
if not log_ok then
  log = {
    debug = function(...) end,
    warn = function(...)
      vim.notify(string.format(...), vim.log.levels.WARN)
    end,
    error = function(...)
      vim.notify(string.format(...), vim.log.levels.ERROR)
    end,
  }
end

local fmt = string.format

local function handle_memory_action(args)
  local ContextDiscovery = require('codecompanion._extensions.reasoning.helpers.context_discovery')

  if args.action == 'store_file_knowledge' then
    if not args.file_path or not args.knowledge then
      return { status = 'error', data = 'file_path and knowledge are required for store_file_knowledge' }
    end

    ContextDiscovery.store_file_knowledge(args.file_path, args.knowledge)
    return {
      status = 'success',
      data = fmt('Stored knowledge for file: %s', args.file_path),
    }
  elseif args.action == 'get_file_knowledge' then
    if not args.file_path then
      return { status = 'error', data = 'file_path is required for get_file_knowledge' }
    end

    local knowledge = ContextDiscovery.get_file_knowledge(args.file_path)
    if knowledge then
      return {
        status = 'success',
        data = fmt('Knowledge for %s: %s', args.file_path, vim.inspect(knowledge)),
      }
    else
      return {
        status = 'success',
        data = fmt('No stored knowledge found for: %s', args.file_path),
      }
    end
  elseif args.action == 'store_reasoning_pattern' then
    if not args.problem_type or not args.reasoning_steps or not args.outcome then
      return {
        status = 'error',
        data = 'problem_type, reasoning_steps, and outcome are required for store_reasoning_pattern',
      }
    end

    ContextDiscovery.store_reasoning_pattern(args.problem_type, args.reasoning_steps, args.outcome)
    return {
      status = 'success',
      data = fmt('Stored reasoning pattern for problem type: %s', args.problem_type),
    }
  elseif args.action == 'get_reasoning_patterns' then
    if not args.problem_type then
      return { status = 'error', data = 'problem_type is required for get_reasoning_patterns' }
    end

    local patterns = ContextDiscovery.get_reasoning_patterns(args.problem_type)
    return {
      status = 'success',
      data = fmt('Found %d reasoning patterns for %s: %s', #patterns, args.problem_type, vim.inspect(patterns)),
    }
  elseif args.action == 'search_similar_problems' then
    if not args.keywords then
      return { status = 'error', data = 'keywords array is required for search_similar_problems' }
    end

    local matches = ContextDiscovery.search_similar_problems(args.keywords)
    return {
      status = 'success',
      data = fmt('Found %d similar problems: %s', #matches, vim.inspect(matches)),
    }
  elseif args.action == 'store_user_preference' then
    if not args.preference_key or args.preference_value == nil then
      return { status = 'error', data = 'preference_key and preference_value are required for store_user_preference' }
    end

    ContextDiscovery.store_user_preference(args.preference_key, args.preference_value)
    return {
      status = 'success',
      data = fmt('Stored user preference: %s = %s', args.preference_key, tostring(args.preference_value)),
    }
  elseif args.action == 'get_user_preference' then
    if not args.preference_key then
      return { status = 'error', data = 'preference_key is required for get_user_preference' }
    end

    local value = ContextDiscovery.get_user_preference(args.preference_key)
    if value ~= nil then
      return {
        status = 'success',
        data = fmt('User preference %s: %s', args.preference_key, tostring(value)),
      }
    else
      return {
        status = 'success',
        data = fmt('No user preference found for: %s', args.preference_key),
      }
    end
  elseif args.action == 'store_problem_solution' then
    if not args.problem_description or not args.solution_approach then
      return {
        status = 'error',
        data = 'problem_description and solution_approach are required for store_problem_solution',
      }
    end

    ContextDiscovery.store_problem_solution(args.problem_description, args.solution_approach, args.files_involved)
    return {
      status = 'success',
      data = 'Stored problem-solution mapping successfully',
    }
  elseif args.action == 'get_recommended_tools' then
    if not args.context_type then
      return { status = 'error', data = 'context_type is required for get_recommended_tools' }
    end

    local recommendations = ContextDiscovery.get_recommended_tools(args.context_type)
    return {
      status = 'success',
      data = fmt('Tool recommendations for %s: %s', args.context_type, vim.inspect(recommendations)),
    }
  else
    return {
      status = 'error',
      data = fmt(
        'Unknown action: %s. Available: store_file_knowledge, get_file_knowledge, store_reasoning_pattern, get_reasoning_patterns, search_similar_problems, store_user_preference, get_user_preference, store_problem_solution, get_recommended_tools',
        args.action or 'none'
      ),
    }
  end
end

---@class CodeCompanion.Tool.MemoryInsight: CodeCompanion.Agent.Tool
return {
  name = 'memory_insight',
  cmds = {
    ---Execute memory insight commands
    ---@param self CodeCompanion.Tool.MemoryInsight
    ---@param args table The arguments from the LLM's tool call
    ---@param input? any The output from the previous function call
    ---@return { status: "success"|"error", data: string }
    function(self, args, input)
      log:debug('[Memory Insight] Action: %s', args.action or 'none')
      return handle_memory_action(args)
    end,
  },
  schema = {
    type = 'function',
    ['function'] = {
      name = 'memory_insight',
      description = 'Store and retrieve project-specific insights, reasoning patterns, and learned knowledge to improve future problem-solving.',
      parameters = {
        type = 'object',
        properties = {
          action = {
            type = 'string',
            description = 'Memory action to perform',
            enum = {
              'store_file_knowledge', -- Store insights about what files contain
              'get_file_knowledge', -- Retrieve file insights
              'store_reasoning_pattern', -- Store successful reasoning sequences
              'get_reasoning_patterns', -- Get reasoning patterns for problem type
              'search_similar_problems', -- Find similar past problems
              'store_user_preference', -- Store user coding preferences
              'get_user_preference', -- Get user preference
              'store_problem_solution', -- Store problem-solution mapping
              'get_recommended_tools', -- Get tool recommendations based on past success
            },
          },
          file_path = {
            type = 'string',
            description = 'File path (for file knowledge actions)',
          },
          knowledge = {
            type = 'object',
            description = 'Knowledge object to store about the file (purpose, key_functions, patterns, etc.)',
          },
          problem_type = {
            type = 'string',
            description = 'Type of problem (e.g., authentication_bug, performance_issue, etc.)',
          },
          reasoning_steps = {
            type = 'array',
            items = { type = 'string' },
            description = 'Array of reasoning steps that led to success',
          },
          outcome = {
            type = 'string',
            description = 'Description of the successful outcome',
          },
          keywords = {
            type = 'array',
            items = { type = 'string' },
            description = 'Keywords to search for in past problems',
          },
          preference_key = {
            type = 'string',
            description = 'Preference identifier (e.g., coding_style, testing_approach)',
          },
          preference_value = {
            description = 'Preference value (can be string, boolean, number, etc.)',
          },
          problem_description = {
            type = 'string',
            description = 'Description of the problem that was solved',
          },
          solution_approach = {
            type = 'string',
            description = 'Description of how the problem was solved',
          },
          files_involved = {
            type = 'array',
            items = { type = 'string' },
            description = 'Array of file paths that were part of the solution',
          },
          context_type = {
            type = 'string',
            description = 'Type of task context (e.g., file_editing, debugging, testing)',
          },
        },
        required = { 'action' },
        additionalProperties = false,
      },
      strict = true,
    },
  },
  system_prompt = 'You enhance reasoning through project memory and learned insights. Store file knowledge, reasoning patterns, user preferences, and build institutional knowledge about the codebase.',
  output = {
    ---@param self CodeCompanion.Tool.MemoryInsight
    ---@param agent CodeCompanion.Tools.Tool
    ---@param cmd table The command that was executed
    ---@param stdout table The output from the command
    success = function(self, agent, cmd, stdout)
      local chat = agent.chat
      local result = vim.iter(stdout):flatten():join('\n')

      log:debug('[Memory Insight] Success output generated, length: %d', #result)
      chat:add_tool_output(self, result, result)
    end,

    ---@param self CodeCompanion.Tool.MemoryInsight
    ---@param agent CodeCompanion.Tools.Tool
    ---@param cmd table
    ---@param stderr table The error output from the command
    error = function(self, agent, cmd, stderr)
      local chat = agent.chat
      local errors = vim.iter(stderr):flatten():join('\n')
      log:debug('[Memory Insight] Error occurred: %s', errors)
      chat:add_tool_output(self, fmt('❌ Memory Insight ERROR: %s', errors))
    end,
  },
}

