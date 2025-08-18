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

local function truncate_path(file_path, max_length)
  max_length = max_length or 40
  if #file_path <= max_length then
    return file_path
  end
  local parts = vim.split(file_path, '/')
  if #parts > 1 then
    return '...' .. parts[#parts]
  end
  return file_path:sub(1, max_length - 3) .. '...'
end

local function handle_memory_action(args)
  local ContextDiscovery = require('codecompanion._extensions.reasoning.helpers.context_discovery')

  if args.action == 'store_file_knowledge' then
    if not args.file_path or not args.knowledge then
      return { status = 'error', data = '❌ ERROR: file_path and knowledge are required for store_file_knowledge' }
    end

    ContextDiscovery.store_file_knowledge(args.file_path, args.knowledge)
    local short_path = truncate_path(args.file_path, 35)
    local summary = fmt('💾 STORED: File knowledge for %s', short_path)
    return {
      status = 'success',
      data = summary,
    }
  elseif args.action == 'get_file_knowledge' then
    if not args.file_path then
      return { status = 'error', data = '❌ ERROR: file_path is required for get_file_knowledge' }
    end

    local knowledge = ContextDiscovery.get_file_knowledge(args.file_path)
    local short_path = truncate_path(args.file_path, 35)

    if knowledge then
      local summary = fmt('📖 FOUND: Knowledge for %s', short_path)
      local details =
        fmt('File: %s\n\nStored Knowledge:\n%s', args.file_path, vim.inspect(knowledge, { indent = '  ', depth = 3 }))
      return {
        status = 'success',
        data = summary .. details,
      }
    else
      return {
        status = 'success',
        data = fmt('📭 NOT FOUND: No knowledge stored for %s', short_path),
      }
    end
  elseif args.action == 'store_user_preference' then
    if not args.preference_key or args.preference_value == nil then
      return {
        status = 'error',
        data = '❌ ERROR: preference_key and preference_value are required for store_user_preference',
      }
    end

    ContextDiscovery.store_user_preference(args.preference_key, args.preference_value)
    local summary = fmt('⚙️ PREF: %s = %s', args.preference_key, tostring(args.preference_value))
    return {
      status = 'success',
      data = summary,
    }
  elseif args.action == 'get_user_preference' then
    if not args.preference_key then
      return { status = 'error', data = '❌ ERROR: preference_key is required for get_user_preference' }
    end

    local value = ContextDiscovery.get_user_preference(args.preference_key)
    if value ~= nil then
      local summary = fmt('⚙️ PREF: %s = %s', args.preference_key, tostring(value))
      local details =
        fmt('Preference: %s\nCurrent Value: %s\nType: %s', args.preference_key, tostring(value), type(value))
      return {
        status = 'success',
        data = summary + details,
      }
    else
      return {
        status = 'success',
        data = fmt('📭 PREF: No preference found for %s', args.preference_key),
      }
    end
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
      description = 'Store and retrieve project-specific insights and learned knowledge to improve future problem-solving.',
      parameters = {
        type = 'object',
        properties = {
          action = {
            type = 'string',
            description = 'Memory action to perform',
            enum = {
              'store_file_knowledge', -- Store insights about what files contain
              'get_file_knowledge', -- Retrieve file insights
              'store_user_preference', -- Store user coding preferences
              'get_user_preference', -- Get user preference
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
          preference_key = {
            type = 'string',
            description = 'Preference identifier (e.g., coding_style, testing_approach)',
          },
          preference_value = {
            description = 'Preference value (can be string, boolean, number, etc.)',
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
      -- Format with content first, then any additional metadata
      local content_lines = vim.split(result, '\n', { plain = true })
      local formatted_output = table.concat(content_lines, '\n')
      chat:add_tool_output(self, formatted_output, formatted_output)
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
