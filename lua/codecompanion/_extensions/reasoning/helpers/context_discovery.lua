---@class CodeCompanion.ContextDiscovery
---Discovers and loads AI context files from popular tools with smart memory system
local ContextDiscovery = {}

local fmt = string.format

-- Memory storage location
local MEMORY_DIR = '.codecompanion-reasoning'
local MEMORY_FILE = MEMORY_DIR .. '/memory.json'

-- Get logger with fallback
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

---Known AI context file patterns and their sources
local CONTEXT_FILES = {
  -- Claude Code
  { pattern = 'CLAUDE.md', source = 'Claude Code', priority = 1 },
  { pattern = '.claude.md', source = 'Claude Code', priority = 1 },

  -- Cursor
  { pattern = '.cursorrules', source = 'Cursor', priority = 2 },
  { pattern = 'cursor.md', source = 'Cursor', priority = 2 },

  -- GitHub Copilot
  { pattern = '.github/copilot-instructions.md', source = 'GitHub Copilot', priority = 3 },
  { pattern = 'copilot-instructions.md', source = 'GitHub Copilot', priority = 3 },

  -- Aider
  { pattern = '.aider.conf.yml', source = 'Aider', priority = 4 },
  { pattern = '.aiderignore', source = 'Aider', priority = 4 },

  -- Continue
  { pattern = '.continue/config.json', source = 'Continue', priority = 5 },

  -- Codeium
  { pattern = '.codeium/context.md', source = 'Codeium', priority = 6 },

  -- Generic AI context files
  { pattern = 'AI_CONTEXT.md', source = 'Generic', priority = 7 },
  { pattern = 'ai-context.md', source = 'Generic', priority = 7 },
  { pattern = '.ai-instructions.md', source = 'Generic', priority = 7 },
  { pattern = 'INSTRUCTIONS.md', source = 'Generic', priority = 8 },
}

---Default memory structure
local DEFAULT_MEMORY = {
  version = '1.0',
  created = 0,
  updated = 0,
  file_knowledge = {}, -- File purposes and insights
  reasoning_patterns = {}, -- Successful reasoning sequences
  user_preferences = {}, -- Discovered user patterns
  problem_solutions = {}, -- Problem-solution mappings
  tool_usage_patterns = {}, -- Which tools work best for what
}

---Find AI context files in the project
---@param start_path? string Starting directory (defaults to cwd)
---@return table[] Array of found context files with metadata
function ContextDiscovery.find_context_files(start_path)
  start_path = start_path or vim.fn.getcwd()
  local found_files = {}

  log:debug('[Context Discovery] Searching from: %s', start_path)

  -- Search up the directory tree (like git does)
  local current_dir = start_path
  local search_depth = 0
  local max_depth = 10 -- Prevent infinite loops

  while search_depth < max_depth do
    log:debug('[Context Discovery] Checking directory: %s', current_dir)

    -- Check each known context file pattern
    for _, context_file in ipairs(CONTEXT_FILES) do
      local file_path = vim.fn.resolve(current_dir .. '/' .. context_file.pattern)

      -- Check if file exists and is readable
      if vim.fn.filereadable(file_path) == 1 then
        local file_info = {
          path = file_path,
          relative_path = vim.fn.fnamemodify(file_path, ':~:.'),
          pattern = context_file.pattern,
          source = context_file.source,
          priority = context_file.priority,
          directory = current_dir,
          size = vim.fn.getfsize(file_path),
        }

        -- Get file modification time
        local stat = vim.loop.fs_stat(file_path)
        if stat then
          file_info.modified = stat.mtime.sec
        end

        table.insert(found_files, file_info)
        log:debug('[Context Discovery] Found %s file: %s', context_file.source, file_path)
      end
    end

    -- Move up one directory
    local parent_dir = vim.fn.fnamemodify(current_dir, ':h')
    if parent_dir == current_dir then
      -- Reached filesystem root
      break
    end

    current_dir = parent_dir
    search_depth = search_depth + 1
  end

  -- Sort by priority (lower numbers = higher priority)
  table.sort(found_files, function(a, b)
    if a.priority == b.priority then
      -- If same priority, prefer files closer to start directory
      return #a.relative_path < #b.relative_path
    end
    return a.priority < b.priority
  end)

  log:debug('[Context Discovery] Found %d context files', #found_files)
  return found_files
end

---Read and process a context file
---@param file_info table File information from find_context_files
---@return string? content File content, nil if failed to read
---@return string? error Error message if reading failed
function ContextDiscovery.read_context_file(file_info)
  local file_path = file_info.path

  -- Check file size (avoid reading huge files)
  local max_size = 100 * 1024 -- 100KB limit
  if file_info.size and file_info.size > max_size then
    local error_msg = fmt('Context file too large (%d bytes, max %d)', file_info.size, max_size)
    log:warn('[Context Discovery] %s: %s', error_msg, file_path)
    return nil, error_msg
  end

  -- Read file content
  local file = io.open(file_path, 'r')
  if not file then
    local error_msg = fmt('Failed to open file: %s', file_path)
    log:warn('[Context Discovery] %s', error_msg)
    return nil, error_msg
  end

  local content = file:read('*all')
  file:close()

  if not content or content == '' then
    local error_msg = 'File is empty or unreadable'
    log:warn('[Context Discovery] %s: %s', error_msg, file_path)
    return nil, error_msg
  end

  log:debug('[Context Discovery] Read %d characters from %s', #content, file_path)
  return content, nil
end

---Generate context summary for chat
---@param context_files table[] Array of context file info with content
---@return string Formatted context summary
function ContextDiscovery.format_context_summary(context_files)
  if #context_files == 0 then
    return '🔍 No AI context files found in project'
  end

  local output = {}

  -- Header
  table.insert(output, fmt('🧠 **Project Context Loaded** (%d files)', #context_files))
  table.insert(output, '')

  -- Context files summary
  for i, file_info in ipairs(context_files) do
    local size_info = file_info.size and fmt(' (%d bytes)', file_info.size) or ''
    table.insert(output, fmt('**%d. %s** (%s)%s', i, file_info.relative_path, file_info.source, size_info))

    if file_info.content then
      -- Show first few lines as preview
      local lines = vim.split(file_info.content, '\n')
      local preview_lines = math.min(3, #lines)

      for j = 1, preview_lines do
        local line = lines[j]:gsub('^%s*', ''):gsub('%s*$', '') -- Trim
        if line ~= '' then
          local preview = #line > 80 and (line:sub(1, 77) .. '...') or line
          table.insert(output, fmt('   • %s', preview))
        end
      end

      if #lines > preview_lines then
        table.insert(output, fmt('   • ... (%d more lines)', #lines - preview_lines))
      end
    elseif file_info.error then
      table.insert(output, fmt('   ❌ %s', file_info.error))
    end

    table.insert(output, '')
  end

  -- Usage guidance
  table.insert(output, '💡 **Context is now available for all reasoning agents**')
  table.insert(output, '• Agents will use this context to understand project conventions')
  table.insert(output, '• File patterns, coding standards, and preferences are loaded')
  table.insert(output, '• Context helps agents make better decisions for your specific project')

  return table.concat(output, '\n')
end

---Load project context and return formatted summary
---@param start_path? string Starting directory (defaults to cwd)
---@return string Formatted context summary
---@return table[] Raw context files data
function ContextDiscovery.load_project_context(start_path)
  local context_files = ContextDiscovery.find_context_files(start_path)

  -- Read content for each file
  for _, file_info in ipairs(context_files) do
    file_info.content, file_info.error = ContextDiscovery.read_context_file(file_info)
  end

  local summary = ContextDiscovery.format_context_summary(context_files)

  log:debug('[Context Discovery] Generated summary with %d files', #context_files)
  return summary, context_files
end

---Get project context as a system message for reasoning agents
---@param start_path? string Starting directory (defaults to cwd)
---@return string? System message with project context, nil if no context
function ContextDiscovery.get_system_context(start_path)
  local context_files = ContextDiscovery.find_context_files(start_path)

  if #context_files == 0 then
    return nil
  end

  local system_parts = {}
  table.insert(system_parts, '# PROJECT CONTEXT')
  table.insert(system_parts, '')
  table.insert(system_parts, 'The following project context has been automatically discovered:')
  table.insert(system_parts, '')

  for _, file_info in ipairs(context_files) do
    local content, error = ContextDiscovery.read_context_file(file_info)

    if content then
      table.insert(system_parts, fmt('## %s (%s)', file_info.relative_path, file_info.source))
      table.insert(system_parts, '')
      table.insert(system_parts, content)
      table.insert(system_parts, '')
    else
      table.insert(system_parts, fmt('## %s (%s) - Error', file_info.relative_path, file_info.source))
      table.insert(system_parts, fmt('Could not read file: %s', error or 'unknown error'))
      table.insert(system_parts, '')
    end
  end

  table.insert(system_parts, '---')
  table.insert(system_parts, '')
  table.insert(system_parts, 'Use this context to understand:')
  table.insert(system_parts, '- Project coding standards and conventions')
  table.insert(system_parts, '- Preferred tools and frameworks')
  table.insert(system_parts, '- Architecture patterns and decisions')
  table.insert(system_parts, '- Any special requirements or constraints')
  table.insert(system_parts, '')
  table.insert(system_parts, 'Apply this context to all your reasoning and recommendations.')

  return table.concat(system_parts, '\n')
end

---Check if context discovery is available in current environment
---@return boolean available True if context discovery can be used
---@return string? error Error message if not available
function ContextDiscovery.check_availability()
  -- Check if we can access file system
  if not vim.fn or not vim.fn.getcwd then
    return false, 'Vim functions not available'
  end

  -- Check if we can read current directory
  local cwd = vim.fn.getcwd()
  if not cwd or cwd == '' then
    return false, 'Cannot determine current working directory'
  end

  -- Check if directory is readable
  if vim.fn.isdirectory(cwd) ~= 1 then
    return false, 'Current directory is not accessible'
  end

  return true, nil
end

---Get memory file path relative to project root
---@return string Memory file path
---@return string Memory directory path
function ContextDiscovery.get_memory_paths()
  local cwd = vim.fn.getcwd()
  local memory_dir = cwd .. '/' .. MEMORY_DIR
  local memory_file = cwd .. '/' .. MEMORY_FILE
  return memory_file, memory_dir
end

---Load memory from disk
---@return table Memory data
function ContextDiscovery.load_memory()
  local memory_file, _ = ContextDiscovery.get_memory_paths()

  -- Check if memory file exists
  if vim.fn.filereadable(memory_file) ~= 1 then
    log:debug('[Context Discovery] No memory file found, using defaults')
    return vim.deepcopy(DEFAULT_MEMORY)
  end

  local file = io.open(memory_file, 'r')
  if not file then
    log:warn('[Context Discovery] Failed to open memory file: %s', memory_file)
    return vim.deepcopy(DEFAULT_MEMORY)
  end

  local content = file:read('*all')
  file:close()

  if not content or content == '' then
    log:warn('[Context Discovery] Memory file is empty')
    return vim.deepcopy(DEFAULT_MEMORY)
  end

  local ok, memory = pcall(vim.json.decode, content)
  if not ok or type(memory) ~= 'table' then
    log:warn('[Context Discovery] Failed to parse memory file, using defaults')
    return vim.deepcopy(DEFAULT_MEMORY)
  end

  -- Merge with defaults to handle version upgrades
  local merged = vim.deepcopy(DEFAULT_MEMORY)
  for key, value in pairs(memory) do
    merged[key] = value
  end

  log:debug(
    '[Context Discovery] Loaded memory with %d file knowledge entries',
    vim.tbl_count(merged.file_knowledge or {})
  )

  return merged
end

---Save memory to disk
---@param memory table Memory data to save
---@return boolean success True if saved successfully
function ContextDiscovery.save_memory(memory)
  local memory_file, memory_dir = ContextDiscovery.get_memory_paths()

  -- Create memory directory if it doesn't exist
  if vim.fn.isdirectory(memory_dir) ~= 1 then
    local ok = vim.fn.mkdir(memory_dir, 'p')
    if ok ~= 1 then
      log:error('[Context Discovery] Failed to create memory directory: %s', memory_dir)
      return false
    end
  end

  -- Update timestamp
  memory.updated = os.time()
  if not memory.created or memory.created == 0 then
    memory.created = memory.updated
  end

  -- Serialize to JSON
  local ok, json_content = pcall(vim.json.encode, memory)
  if not ok then
    log:error('[Context Discovery] Failed to serialize memory data')
    return false
  end

  -- Write to file
  local file = io.open(memory_file, 'w')
  if not file then
    log:error('[Context Discovery] Failed to open memory file for writing: %s', memory_file)
    return false
  end

  file:write(json_content)
  file:close()

  log:debug('[Context Discovery] Saved memory to %s', memory_file)
  return true
end

---Store file knowledge (what files are for, key functions, etc.)
---@param file_path string File path
---@param knowledge table Knowledge about the file
function ContextDiscovery.store_file_knowledge(file_path, knowledge)
  local memory = ContextDiscovery.load_memory()

  -- Normalize file path
  local relative_path = vim.fn.fnamemodify(file_path, ':~:.')

  -- Update or create file knowledge entry
  if not memory.file_knowledge[relative_path] then
    memory.file_knowledge[relative_path] = {
      created = os.time(),
      access_count = 0,
    }
  end

  local entry = memory.file_knowledge[relative_path]
  entry.updated = os.time()
  entry.access_count = (entry.access_count or 0) + 1

  -- Merge knowledge
  for key, value in pairs(knowledge) do
    entry[key] = value
  end

  ContextDiscovery.save_memory(memory)
  log:debug('[Context Discovery] Stored knowledge for file: %s', relative_path)
end

---Get file knowledge
---@param file_path string File path
---@return table? Knowledge about the file, nil if not found
function ContextDiscovery.get_file_knowledge(file_path)
  local memory = ContextDiscovery.load_memory()
  local relative_path = vim.fn.fnamemodify(file_path, ':~:.')
  return memory.file_knowledge[relative_path]
end

---Store user preference
---@param preference_key string Preference identifier
---@param preference_value any Preference value
function ContextDiscovery.store_user_preference(preference_key, preference_value)
  local memory = ContextDiscovery.load_memory()

  memory.user_preferences[preference_key] = {
    value = preference_value,
    updated = os.time(),
    usage_count = (
      memory.user_preferences[preference_key] and memory.user_preferences[preference_key].usage_count or 0
    ) + 1,
  }

  ContextDiscovery.save_memory(memory)
  log:debug('[Context Discovery] Stored user preference: %s', preference_key)
end

---Get user preference
---@param preference_key string Preference identifier
---@return any? Preference value, nil if not found
function ContextDiscovery.get_user_preference(preference_key)
  local memory = ContextDiscovery.load_memory()
  local pref = memory.user_preferences[preference_key]
  return pref and pref.value or nil
end

---Get enhanced context with memory insights
---@param start_path? string Starting directory
---@return string Enhanced context including memory insights
function ContextDiscovery.get_enhanced_context(start_path)
  local base_context = ContextDiscovery.get_system_context(start_path)
  local memory = ContextDiscovery.load_memory()

  local context_parts = {}

  if base_context then
    table.insert(context_parts, base_context)
    table.insert(context_parts, '')
  end

  -- Add memory insights if available
  local has_memory = vim.tbl_count(memory.file_knowledge) > 0
    or vim.tbl_count(memory.reasoning_patterns) > 0
    or vim.tbl_count(memory.user_preferences) > 0

  if has_memory then
    table.insert(context_parts, '# PROJECT MEMORY INSIGHTS')
    table.insert(context_parts, '')

    -- File knowledge summary
    local file_count = vim.tbl_count(memory.file_knowledge)
    if file_count > 0 then
      table.insert(context_parts, fmt('**File Knowledge:** %d files with stored insights', file_count))

      -- Show most accessed files
      local files_by_access = {}
      for path, knowledge in pairs(memory.file_knowledge) do
        table.insert(files_by_access, { path = path, access_count = knowledge.access_count or 0 })
      end
      table.sort(files_by_access, function(a, b)
        return a.access_count > b.access_count
      end)

      for i = 1, math.min(3, #files_by_access) do
        local file = files_by_access[i]
        table.insert(context_parts, fmt('- %s (accessed %d times)', file.path, file.access_count))
      end
      table.insert(context_parts, '')
    end

    -- User preferences
    local pref_count = vim.tbl_count(memory.user_preferences)
    if pref_count > 0 then
      table.insert(context_parts, fmt('**User Preferences:** %d stored preferences', pref_count))
      for key, pref in pairs(memory.user_preferences) do
        table.insert(context_parts, fmt('- %s: %s', key, tostring(pref.value)))
      end
      table.insert(context_parts, '')
    end

    -- Reasoning patterns
    local pattern_count = vim.tbl_count(memory.reasoning_patterns)
    if pattern_count > 0 then
      table.insert(
        context_parts,
        fmt('**Reasoning Patterns:** %d problem types with successful patterns', pattern_count)
      )
      table.insert(context_parts, '')
    end

    table.insert(
      context_parts,
      '💡 **Memory Usage:** Use stored insights to make better decisions and follow established patterns.'
    )
    table.insert(context_parts, '')
  end

  return table.concat(context_parts, '\n')
end

return ContextDiscovery
