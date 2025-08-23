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
  local MemoryEngine = require('codecompanion._extensions.reasoning.helpers.memory_engine')

  if args.action == 'store_file_knowledge' then
    if not args.file_path or not args.knowledge then
      return { status = 'error', data = '❌ ERROR: file_path and knowledge are required for store_file_knowledge' }
    end

    MemoryEngine.store_file_knowledge(args.file_path, args.knowledge)
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

    local knowledge = MemoryEngine.get_file_knowledge(args.file_path)
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

    MemoryEngine.store_user_preference(args.preference_key, args.preference_value)
    local summary = fmt('⚙️ PREF: %s = %s', args.preference_key, tostring(args.preference_value))
    return {
      status = 'success',
      data = summary,
    }
  elseif args.action == 'get_user_preference' then
    if not args.preference_key then
      return { status = 'error', data = '❌ ERROR: preference_key is required for get_user_preference' }
    end

    local value = MemoryEngine.get_user_preference(args.preference_key)
    if value ~= nil then
      local summary = fmt('⚙️ PREF: %s = %s', args.preference_key, tostring(value))
      local details =
        fmt('Preference: %s\nCurrent Value: %s\nType: %s', args.preference_key, tostring(value), type(value))
      return {
        status = 'success',
        data = summary .. '\\n\\n' .. details,
      }
    else
      return {
        status = 'success',
        data = fmt('📭 PREF: No preference found for %s', args.preference_key),
      }
    end
  elseif args.action == 'discover_context' then
    local context_summary, context_files = MemoryEngine.load_project_context()
    return {
      status = 'success',
      data = fmt('🔍 DISCOVERED: %d AI context files\n\n%s', #context_files, context_summary),
    }
  elseif args.action == 'get_enhanced_context' then
    local enhanced_context = MemoryEngine.get_enhanced_context()
    if enhanced_context then
      return {
        status = 'success',
        data = fmt('🧠 ENHANCED CONTEXT:\n\n%s', enhanced_context),
      }
    else
      return {
        status = 'success',
        data = '📭 No enhanced context available',
      }
    end
  else
    return {
      status = 'error',
      data = fmt('❌ ERROR: Unknown action "%s"', args.action or 'nil'),
    }
  end
end

---@class CodeCompanion.Tool.ProjectContext: CodeCompanion.Agent.Tool
return {
  name = 'project_context',
  cmds = {
    ---Execute memory commands
    ---@param self CodeCompanion.Tool.ProjectContext
    ---@param args table The arguments from the LLM's tool call
    ---@param input? any The output from the previous function call
    ---@return { status: "success"|"error", data: string }
    function(self, args, input)
      log:debug('[ProjectContext] Action: %s', args.action or 'none')
      return handle_memory_action(args)
    end,
  },
  schema = {
    type = 'function',
    ['function'] = {
      name = 'project_context',
      description = 'Unified project context system: store/retrieve project insights, discover AI context files (CLAUDE.md, .cursorrules, etc.), manage file knowledge, user preferences, and institutional codebase knowledge. Combines context management with popular AI tool configuration discovery.',
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
              'discover_context', -- Discover AI context files (CLAUDE.md, .cursorrules, etc.)
              'get_enhanced_context', -- Get enhanced context with memory insights
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
  output = {
    ---@param self CodeCompanion.Tool.ProjectContext
    ---@param agent CodeCompanion.Tools.Tool
    ---@param cmd table The command that was executed
    ---@param stdout table The output from the command
    success = function(self, agent, cmd, stdout)
      local chat = agent.chat
      local result = vim.iter(stdout):flatten():join('\n')

      log:debug('[ProjectContext] Success output generated, length: %d', #result)
      -- Format with content first, then any additional metadata
      local content_lines = vim.split(result, '\n', { plain = true })
      local formatted_output = table.concat(content_lines, '\n')
      chat:add_tool_output(self, formatted_output, formatted_output)
    end,

    ---@param self CodeCompanion.Tool.ProjectContext
    ---@param agent CodeCompanion.Tools.Tool
    ---@param cmd table
    ---@param stderr table The error output from the command
    error = function(self, agent, cmd, stderr)
      local chat = agent.chat
      local errors = vim.iter(stderr):flatten():join('\n')
      log:debug('[Memory] Error occurred: %s', errors)
      chat:add_tool_output(self, fmt('❌ Memory ERROR: %s', errors))
    end,
  },
}
