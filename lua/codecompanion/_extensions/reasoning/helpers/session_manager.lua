---@class CodeCompanion.SessionManager
---Chat session storage and management for CodeCompanion reasoning extension
local SessionManager = {}

local fmt = string.format
local uv = vim.loop

-- Configuration
local CONFIG = {
  sessions_dir = vim.fn.stdpath('data') .. '/codecompanion-reasoning/sessions',
  session_file_pattern = 'session_%Y%m%d_%H%M%S.lua',
  max_sessions = 100, -- Keep last 100 sessions
  auto_save = true,
  auto_load_last_session = true,
}

-- Ensure sessions directory exists
local function ensure_sessions_dir()
  local sessions_dir = CONFIG.sessions_dir
  local stat = uv.fs_stat(sessions_dir)
  if not stat then
    -- Create parent directories if needed
    local parent_dir = vim.fn.fnamemodify(sessions_dir, ':h')
    local parent_stat = uv.fs_stat(parent_dir)
    if not parent_stat then
      -- Recursively create parent directories
      local success = vim.fn.mkdir(sessions_dir, 'p')
      if success == 0 then
        vim.notify(fmt('Failed to create sessions directory: %s', sessions_dir), vim.log.levels.ERROR)
        return false
      end
    else
      local success = uv.fs_mkdir(sessions_dir, 493) -- 0755 in octal
      if not success then
        vim.notify(fmt('Failed to create sessions directory: %s', sessions_dir), vim.log.levels.ERROR)
        return false
      end
    end
  elseif stat.type ~= 'directory' then
    vim.notify(fmt('Sessions path exists but is not a directory: %s', sessions_dir), vim.log.levels.ERROR)
    return false
  end
  return true
end

-- Generate session filename based on current timestamp
local function generate_session_filename()
  return os.date(CONFIG.session_file_pattern)
end

-- Get full path for session file
local function get_session_path(filename)
  return CONFIG.sessions_dir .. '/' .. filename
end

-- Lua serialization function that handles nested tables
---@param obj any The object to serialize
---@param indent? number Current indentation level
---@return string serialized_string
local function serialize_lua(obj, indent)
  indent = indent or 0
  local indent_str = string.rep('  ', indent)
  local next_indent_str = string.rep('  ', indent + 1)

  if type(obj) == 'table' then
    local parts = {}
    table.insert(parts, '{\n')

    for k, v in pairs(obj) do
      local key_str
      if type(k) == 'string' and k:match('^[%a_][%w_]*$') then
        key_str = k
      else
        key_str = '[' .. serialize_lua(k, 0) .. ']'
      end

      table.insert(parts, next_indent_str .. key_str .. ' = ' .. serialize_lua(v, indent + 1) .. ',\n')
    end

    table.insert(parts, indent_str .. '}')
    return table.concat(parts)
  elseif type(obj) == 'string' then
    return string.format('%q', obj)
  elseif type(obj) == 'number' or type(obj) == 'boolean' then
    return tostring(obj)
  elseif type(obj) == 'nil' then
    return 'nil'
  elseif type(obj) == 'function' then
    -- Skip functions entirely - don't serialize them
    return 'nil'
  else
    -- For userdata, threads, etc., convert to safe string representation
    local str = tostring(obj)
    -- Make sure the string is valid by escaping it properly
    return string.format('%q', 'unsupported_type: ' .. str)
  end
end

-- Deep clean function to remove non-serializable data
---@param obj any Object to clean
---@return any cleaned_obj
local function deep_clean_for_serialization(obj)
  if type(obj) == 'table' then
    local cleaned = {}
    for k, v in pairs(obj) do
      local clean_k = deep_clean_for_serialization(k)
      local clean_v = deep_clean_for_serialization(v)
      -- Only include if both key and value are serializable
      if type(clean_k) ~= 'nil' and type(clean_v) ~= 'nil' then
        cleaned[clean_k] = clean_v
      end
    end
    return cleaned
  elseif type(obj) == 'function' or type(obj) == 'userdata' or type(obj) == 'thread' then
    -- Skip non-serializable types
    return nil
  else
    -- Primitive types are fine
    return obj
  end
end

-- Extract tools that were used in the chat from messages or context
---@param chat table CodeCompanion chat object
---@return table tools_used
local function extract_used_tools(chat)
  local tools_used = {}

  -- Method 1: Check tool registry if available
  if chat.tool_registry and chat.tool_registry.in_use then
    for tool_name, in_use in pairs(chat.tool_registry.in_use) do
      if in_use then
        tools_used[tool_name] = true
      end
    end
  end

  -- Method 2: Parse messages for tool references and tool calls
  if chat.messages then
    for _, message in ipairs(chat.messages) do
      if message.content then
        -- Look for tool context patterns like "> - <tool>meta_agent</tool>"
        for tool_match in message.content:gmatch('<tool>([^<]+)</tool>') do
          tools_used[tool_match] = true
        end

        -- Look for tool names mentioned in tool content (like your example)
        -- Extract tool names from patterns like "- tool_name: Description"
        for tool_match in message.content:gmatch('%-[%s]*([%w_]+):[%s]*[%w%s]+') do
          -- Common reasoning tools
          if
            tool_match:match('agent$')
            or tool_match:match('^meta_')
            or tool_match:match('^add_')
            or tool_match:match('^project_')
            or tool_match:match('^ask_')
          then
            tools_used[tool_match] = true
          end
        end
      end

      -- Check for tool calls in message structure
      if message.tool_calls then
        for _, tool_call in ipairs(message.tool_calls) do
          if tool_call['function'] and tool_call['function'].name then
            tools_used[tool_call['function'].name] = true
          end
        end
      end

      -- Check if message role indicates tool usage and extract tool_name
      if message.role == 'tool' then
        -- Direct tool name from message structure (most reliable)
        if message.tool_name then
          tools_used[message.tool_name] = true
        end

        -- Fallback: identify tool from content patterns
        if message.content then
          -- Look for common reasoning tool patterns
          if message.content:match('add_tools') then
            tools_used['add_tools'] = true
          elseif message.content:match('meta_agent') then
            tools_used['meta_agent'] = true
          elseif message.content:match('project_context') then
            tools_used['project_context'] = true
          elseif message.content:match('chain_of_thoughts') then
            tools_used['chain_of_thoughts_agent'] = true
          elseif message.content:match('tree_of_thoughts') then
            tools_used['tree_of_thoughts_agent'] = true
          elseif message.content:match('graph_of_thoughts') then
            tools_used['graph_of_thoughts_agent'] = true
          elseif message.content:match('ask_user') then
            tools_used['ask_user'] = true
          end
        end
      end
    end
  end

  -- Method 3: Check buffer content if available
  if chat.bufnr and vim.api.nvim_buf_is_valid(chat.bufnr) then
    local lines = vim.api.nvim_buf_get_lines(chat.bufnr, 0, -1, false)
    for _, line in ipairs(lines) do
      -- Look for tool context patterns
      for tool_match in line:gmatch('<tool>([^<]+)</tool>') do
        tools_used[tool_match] = true
      end
    end
  end

  -- Convert to array and sort for consistent output
  local tools_array = {}
  for tool_name, _ in pairs(tools_used) do
    table.insert(tools_array, tool_name)
  end
  table.sort(tools_array)

  return tools_array
end

-- Prepare chat data for storage (extract only serializable parts)
---@param chat table CodeCompanion chat object
---@return table session_data
local function prepare_chat_data(chat)
  -- Create a clean copy with only serializable data
  local session_data = {
    version = '1.0',
    timestamp = os.time(),
    created_at = os.date('%Y-%m-%d %H:%M:%S'),
    chat_id = chat.id or 'unknown',

    -- Chat configuration (only serializable parts)
    config = {
      adapter = chat.adapter and chat.adapter.name or 'unknown',
      model = chat.model or 'unknown',
    },

    -- Tools that were used in this chat
    tools = extract_used_tools(chat),

    -- Messages history (clean copy)
    messages = {},

    -- Session metadata
    metadata = {
      total_messages = 0,
      last_activity = os.date('%Y-%m-%d %H:%M:%S'),
      session_duration = 0,
    },
  }

  -- Extract messages, cleaning non-serializable parts and filtering system prompts
  if chat.messages and #chat.messages > 0 then
    for _, message in ipairs(chat.messages) do
      -- Skip system messages and very long messages that look like system prompts
      local is_system_prompt = message.role == 'system'
        or (
          message.role == 'assistant'
          and message.content
          and #message.content > 500
          and message.content:match('You are an AI programming assistant')
        )

      if not is_system_prompt then
        -- Preserve the full CodeCompanion message structure
        local clean_message = deep_clean_for_serialization({
          role = message.role,
          content = message.content,
          timestamp = message.timestamp or os.time(),
          tool_calls = message.tool_calls,
          tool_call_id = message.tool_call_id,
          tool_name = message.tool_name,
          name = message.name,
          cycle = message.cycle,
          id = message.id,
          opts = message.opts,
          reasoning = message.reasoning,
          tag = message.tag,
          context_id = message.context_id,
          visible = message.visible,
        })

        if clean_message and clean_message.role and clean_message.content then
          table.insert(session_data.messages, clean_message)
        end
      end
    end
    session_data.metadata.total_messages = #session_data.messages
  end

  return session_data
end

-- Save chat session to file
---@param chat table CodeCompanion chat object
---@param filename? string Optional filename, generates one if not provided
---@return boolean success, string? error_message
function SessionManager.save_session(chat, filename)
  if not ensure_sessions_dir() then
    return false, 'Failed to create sessions directory'
  end

  filename = filename or generate_session_filename()
  local session_path = get_session_path(filename)

  local session_data = prepare_chat_data(chat)

  -- Write session data as Lua code
  local lua_content = 'return ' .. serialize_lua(session_data)

  local file = io.open(session_path, 'w')
  if not file then
    return false, fmt('Failed to open session file for writing: %s', session_path)
  end

  file:write(lua_content)
  file:close()

  return true, filename
end

-- Load chat session from file
---@param filename string Session filename
---@return table? session_data, string? error_message
function SessionManager.load_session(filename)
  local session_path = get_session_path(filename)

  local file = io.open(session_path, 'r')
  if not file then
    return nil, fmt('Failed to open session file: %s', session_path)
  end

  local content = file:read('*all')
  file:close()

  if not content or content == '' then
    return nil, 'Session file is empty'
  end

  -- Load Lua data safely
  local chunk, err = load(content)
  if not chunk then
    return nil, fmt('Failed to parse session file: %s', err)
  end

  local ok, session_data = pcall(chunk)
  if not ok then
    return nil, fmt('Failed to execute session data: %s', session_data)
  end

  -- Return the data directly (already in the right format)
  return {
    messages = session_data.messages or {},
    config = session_data.config or {},
    metadata = session_data.metadata or {},
    session_id = session_data.chat_id,
    created_at = session_data.created_at,
    timestamp = session_data.timestamp,
    version = session_data.version,
  },
    nil
end

-- List all available sessions
---@return table sessions List of session info objects
function SessionManager.list_sessions()
  if not ensure_sessions_dir() then
    return {}
  end

  local sessions = {}
  local handle = uv.fs_scandir(CONFIG.sessions_dir)

  if not handle then
    return sessions
  end

  while true do
    local name, type = uv.fs_scandir_next(handle)
    if not name then
      break
    end

    if type == 'file' and name:match('%.lua$') then
      local session_path = get_session_path(name)
      local stat = uv.fs_stat(session_path)

      if stat then
        -- Try to load session metadata quickly
        local file = io.open(session_path, 'r')
        if file then
          local content = file:read('*all')
          file:close()

          local chunk = load(content)
          local ok, session_data = false, nil
          if chunk then
            ok, session_data = pcall(chunk)
          end
          if ok and session_data then
            table.insert(sessions, {
              filename = name,
              created_at = session_data.created_at or 'Unknown',
              timestamp = session_data.timestamp or stat.mtime.sec,
              total_messages = session_data.metadata and session_data.metadata.total_messages or 0,
              model = session_data.config and session_data.config.model or 'Unknown',
              chat_id = session_data.chat_id or 'unknown',
              file_size = stat.size,
              preview = SessionManager.get_session_preview(session_data),
            })
          end
        end
      end
    end
  end

  -- Sort sessions by timestamp (newest first)
  table.sort(sessions, function(a, b)
    return a.timestamp > b.timestamp
  end)

  return sessions
end

-- Get a brief preview of session content
---@param session_data table
---@return string preview
function SessionManager.get_session_preview(session_data)
  if not session_data.messages or #session_data.messages == 0 then
    return 'Empty session'
  end

  local first_user_message = nil
  for _, message in ipairs(session_data.messages) do
    if message.role == 'user' and message.content then
      first_user_message = message.content
      break
    end
  end

  if first_user_message then
    -- Truncate to first line and limit length
    local first_line = first_user_message:match('^[^\n\r]*')
    if #first_line > 60 then
      return first_line:sub(1, 57) .. '...'
    end
    return first_line
  end

  return fmt('%d messages', #session_data.messages)
end

-- Delete session file
---@param filename string Session filename
---@return boolean success, string? error_message
function SessionManager.delete_session(filename)
  local session_path = get_session_path(filename)
  local success = uv.fs_unlink(session_path)

  if success then
    return true
  else
    return false, fmt('Failed to delete session file: %s', session_path)
  end
end

-- Clean up old sessions (keep only the most recent MAX_SESSIONS)
function SessionManager.cleanup_old_sessions()
  local sessions = SessionManager.list_sessions()

  if #sessions <= CONFIG.max_sessions then
    return
  end

  -- Delete oldest sessions
  for i = CONFIG.max_sessions + 1, #sessions do
    SessionManager.delete_session(sessions[i].filename)
  end
end

-- Auto-save session after each new message
---@param chat table CodeCompanion chat object
function SessionManager.auto_save_session(chat)
  if not CONFIG.auto_save then
    return
  end

  if not chat then
    return
  end

  -- Use a persistent filename based on chat ID
  local session_filename = fmt('session_%s.lua', chat.id or 'default')
  local success, result = SessionManager.save_session(chat, session_filename)

  if not success then
    vim.notify(fmt('Failed to auto-save session: %s', result), vim.log.levels.WARN)
  end
end

-- Get the most recent session filename
---@return string? filename, string? error_message
function SessionManager.get_last_session()
  local sessions = SessionManager.list_sessions()

  if #sessions == 0 then
    return nil, 'No sessions found'
  end

  -- Sessions are already sorted by timestamp (newest first)
  return sessions[1].filename, nil
end

-- Restore session by creating a new CodeCompanion chat with history
---@param filename string Session filename
---@return boolean success, string? error_message
function SessionManager.restore_session(filename)
  local session_data, err = SessionManager.load_session(filename)
  if not session_data then
    return false, err
  end

  -- Try to access CodeCompanion and its config
  local codecompanion_ok, codecompanion = pcall(require, 'codecompanion')
  if not codecompanion_ok then
    return false, 'CodeCompanion not available'
  end

  local config_ok, config = pcall(require, 'codecompanion.config')
  if not config_ok then
    return false, 'CodeCompanion config not available'
  end

  -- Resolve adapter from session config or use default
  local adapter = nil
  if session_data.config and session_data.config.adapter and session_data.config.adapter ~= 'unknown' then
    adapter = config.adapters[session_data.config.adapter]
  end

  -- Fall back to default adapter if session adapter not available
  if not adapter then
    adapter = config.adapters[config.default_adapter]
  end

  -- Convert session messages to CodeCompanion format, preserving structure
  local messages = {}
  for _, message in ipairs(session_data.messages) do
    if message.role and message.content then
      -- Skip system messages and long assistant messages that look like system prompts
      local is_system_prompt = message.role == 'system'
        or (
          message.role == 'assistant'
          and #message.content > 500
          and message.content:match('You are an AI programming assistant')
        )

      if not is_system_prompt then
        -- Preserve the full message structure for proper CodeCompanion display
        local restored_message = {
          role = message.role,
          content = message.content,
        }

        -- Add CodeCompanion-specific fields if they exist
        if message.tool_calls then
          restored_message.tool_calls = message.tool_calls
        end
        if message.tool_call_id then
          restored_message.tool_call_id = message.tool_call_id
        end
        if message.tool_name then
          restored_message.tool_name = message.tool_name
        end
        if message.name then
          restored_message.name = message.name
        end
        if message.cycle then
          restored_message.cycle = message.cycle
        end
        if message.id then
          restored_message.id = message.id
        end
        if message.opts then
          restored_message.opts = message.opts
        end
        if message.reasoning then
          restored_message.reasoning = message.reasoning
        end
        if message.tag then
          restored_message.tag = message.tag
        end
        if message.context_id then
          restored_message.context_id = message.context_id
        end
        if message.visible ~= nil then
          restored_message.visible = message.visible
        end
        if message.timestamp then
          restored_message.timestamp = message.timestamp
        end

        table.insert(messages, restored_message)
      end
    end
  end

  -- Create chat using CodeCompanion's native system
  local success, chat_or_error = pcall(function()
    return require('codecompanion.strategies.chat').new({
      adapter = adapter,
      messages = messages,
      auto_submit = false, -- Don't auto-submit, let user review first
      -- System prompts are now filtered during session saving
      buffer_context = require('codecompanion.utils.context').get(vim.api.nvim_get_current_buf()),
      last_role = 'user', -- Ensure user can immediately continue
    })
  end)

  if not success then
    return false, fmt('Failed to create CodeCompanion chat: %s', chat_or_error)
  end

  local chat = chat_or_error
  if not chat then
    return false, 'Failed to create CodeCompanion chat'
  end

  -- Add only the tools that were used in the original session
  local restored_tools = {}
  local session_tools = session_data.tools or {}

  -- For older format sessions without tool data, don't add default tools
  -- Let CodeCompanion handle tool display naturally

  for _, tool_name in ipairs(session_tools) do
    local tool_config = config.strategies.chat.tools[tool_name]
    if tool_config then
      table.insert(restored_tools, tool_name)
      -- Try to add to tool registry
      local add_ok, add_err = pcall(function()
        chat.tool_registry:add(tool_name, tool_config)
      end)
      if not add_ok then
        -- Try group addition as fallback
        if config.strategies.chat.tools.groups and config.strategies.chat.tools.groups[tool_name] then
          pcall(function()
            chat.tool_registry:add_group(tool_name, config.strategies.chat.tools)
          end)
        end
      end
    end
  end

  -- Ensure the chat buffer shows a user prompt section ready for input with tools context
  vim.schedule(function()
    if chat.bufnr and vim.api.nvim_buf_is_valid(chat.bufnr) then
      local lines = vim.api.nvim_buf_get_lines(chat.bufnr, -2, -1, false)
      local last_line = lines[1] or ''

      -- If the last section isn't a user section, add one
      if not last_line:match('^## Me') then
        -- Simple user section - let CodeCompanion handle tool context naturally
        local user_section_lines = {
          '',
          '## Me',
          '',
        }

        -- Only add tool context if there were actual tools saved in the session
        if #restored_tools > 0 then
          table.insert(user_section_lines, '> Context:')
          for _, tool_name in ipairs(restored_tools) do
            table.insert(user_section_lines, string.format('> - <tool>%s</tool>', tool_name))
          end
          table.insert(user_section_lines, '')
        end

        vim.api.nvim_buf_set_lines(chat.bufnr, -1, -1, false, user_section_lines)
      end
    end
  end)

  vim.notify(fmt('Restored session: %s (%d messages)', filename, #session_data.messages), vim.log.levels.INFO)
  return true
end

-- Auto-load last session if enabled
function SessionManager.auto_load_last_session()
  if not CONFIG.auto_load_last_session then
    return
  end

  local last_session, err = SessionManager.get_last_session()
  if not last_session then
    -- No sessions to load, no action needed
    return
  end

  -- Restore the last session
  local success, restore_err = SessionManager.restore_session(last_session)
  if not success then
    vim.notify(fmt('Failed to auto-load last session: %s', restore_err), vim.log.levels.WARN)
  end
end

-- Get sessions directory path
function SessionManager.get_sessions_dir()
  return CONFIG.sessions_dir
end

-- Update configuration
---@param new_config table
function SessionManager.setup(new_config)
  if new_config then
    CONFIG = vim.tbl_deep_extend('force', CONFIG, new_config)
  end

  -- Set up auto-load if enabled
  if CONFIG.auto_load_last_session then
    -- Create autocommand to auto-load on VimEnter
    local group = vim.api.nvim_create_augroup('CodeCompanionSessionAutoLoad', { clear = true })
    vim.api.nvim_create_autocmd('VimEnter', {
      group = group,
      callback = function()
        -- Delay slightly to ensure everything is loaded
        vim.defer_fn(function()
          SessionManager.auto_load_last_session()
        end, 100)
      end,
    })
  end
end

return SessionManager
