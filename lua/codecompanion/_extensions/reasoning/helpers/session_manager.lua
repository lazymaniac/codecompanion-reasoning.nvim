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
  auto_generate_title = true,
  expiration_days = 0, -- 0 to disable
  enable_index = true, -- Enable JSON index for fast access
}

-- Utils for project detection
local function find_project_root(path)
  path = path or vim.fn.getcwd()

  local indicators = {
    '.git',
    '.svn',
    '.hg', -- Version control
    'package.json',
    'Cargo.toml',
    'pyproject.toml', -- Language specific
    'Makefile',
    'CMakeLists.txt', -- Build systems
    '.project',
    '.root', -- Custom markers
  }

  local current = path
  while current ~= '/' do
    for _, indicator in ipairs(indicators) do
      if
        vim.fn.isdirectory(current .. '/' .. indicator) == 1
        or vim.fn.filereadable(current .. '/' .. indicator) == 1
      then
        return current
      end
    end
    current = vim.fn.fnamemodify(current, ':h')
  end

  return path -- fallback to provided path
end

-- Generate unique save ID
local function generate_save_id()
  return tostring(os.time() * 1000 + math.random(1000))
end

-- Generate simple title from first user message
local function generate_title_from_messages(messages)
  if not messages or #messages == 0 then
    return 'Empty Session'
  end

  -- Find first user message
  local first_user_msg = nil
  for _, message in ipairs(messages) do
    if message.role == 'user' and message.content then
      first_user_msg = message.content
      break
    end
  end

  if not first_user_msg then
    return 'No User Input'
  end

  -- Extract first line and truncate
  local first_line = first_user_msg:match('^[^\n\r]*') or first_user_msg
  if #first_line > 50 then
    return first_line:sub(1, 47) .. '...'
  end

  return first_line
end

-- Ensure sessions directory exists
local function ensure_sessions_dir()
  local sessions_dir = CONFIG.sessions_dir
  local stat = uv.fs_stat(sessions_dir)

  if stat then
    if stat.type ~= 'directory' then
      vim.notify(fmt('Sessions path exists but is not a directory: %s', sessions_dir), vim.log.levels.ERROR)
      return false
    end
    return true
  end

  -- Directory doesn't exist, create it with parents
  local success = vim.fn.mkdir(sessions_dir, 'p')
  if success == 0 then
    vim.notify(fmt('Failed to create sessions directory: %s', sessions_dir), vim.log.levels.ERROR)
    return false
  end

  -- Create index file if it doesn't exist
  if CONFIG.enable_index then
    local index_path = CONFIG.sessions_dir .. '/index.json'
    local index_stat = uv.fs_stat(index_path)
    if not index_stat then
      local empty_index = '{}'
      local file = io.open(index_path, 'w')
      if file then
        file:write(empty_index)
        file:close()
      end
    end
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

  if chat.messages then
    for _, message in ipairs(chat.messages) do
      if message.tool_calls then
        for _, tool_call in ipairs(message.tool_calls) do
          if tool_call['function'] and tool_call['function'].name then
            tools_used[tool_call['function'].name] = true
          end
        end
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

-- Update JSON index for fast session access
---@param session_data table Session data
---@param filename string Session filename
local function update_session_index(session_data, filename)
  if not CONFIG.enable_index then
    return true, nil
  end

  local index_path = CONFIG.sessions_dir .. '/index.json'
  local index = {}

  -- Try to read existing index
  local file = io.open(index_path, 'r')
  if file then
    local content = file:read('*all')
    file:close()
    if content and content ~= '' then
      local ok, parsed = pcall(vim.json.decode, content)
      if ok and type(parsed) == 'table' then
        index = parsed
      else
        -- Log warning about corrupted index but continue with empty index
        vim.notify('Warning: Corrupted session index, starting fresh', vim.log.levels.WARN)
      end
    end
  end

  -- Update index entry
  local entry_id = session_data.save_id or filename:gsub('%.lua$', '')
  index[entry_id] = {
    save_id = session_data.save_id,
    filename = filename,
    title = session_data.title or 'Untitled',
    created_at = session_data.created_at,
    updated_at = session_data.updated_at or session_data.timestamp,
    model = session_data.config.model,
    adapter = session_data.config.adapter,
    message_count = session_data.metadata.total_messages,
    token_estimate = session_data.metadata.token_estimate,
    cwd = session_data.cwd,
    project_root = session_data.project_root,
    tools_used = session_data.tools or {},
  }

  -- Write updated index
  local write_file = io.open(index_path, 'w')
  if not write_file then
    return false, 'Failed to open index file for writing'
  end

  local ok, json_str = pcall(vim.json.encode, index)
  if not ok or not json_str then
    write_file:close()
    return false, 'Failed to encode index to JSON: ' .. tostring(json_str or 'unknown error')
  end

  write_file:write(json_str)
  write_file:close()

  return true, nil
end

-- Prepare chat data for storage (extract only serializable parts)
---@param chat table CodeCompanion chat object
---@return table session_data
local function prepare_chat_data(chat)
  local current_time = os.time()
  local created_time = chat._session_created_at or current_time
  local session_duration = current_time - created_time
  local cwd = vim.fn.getcwd()
  local project_root = find_project_root(cwd)

  local session_data = {
    version = '2.0', -- Enhanced version
    save_id = chat.opts and chat.opts.save_id or generate_save_id(),
    title = chat.opts and chat.opts.title or nil, -- Will be generated if enabled
    timestamp = current_time,
    created_at = os.date('%Y-%m-%d %H:%M:%S', created_time),
    updated_at = current_time,

    -- Enhanced metadata
    chat_id = chat.id or 'unknown',
    cwd = cwd,
    project_root = project_root,

    config = {
      adapter = chat.adapter and chat.adapter.name or 'unknown',
      model = chat.model or 'unknown',
    },

    -- Enhanced tracking
    tools = extract_used_tools(chat),
    cycle = chat.cycle or 1,

    messages = {},
    metadata = {
      total_messages = 0,
      last_activity = os.date('%Y-%m-%d %H:%M:%S'),
      session_duration = session_duration,
      created_timestamp = created_time,
      title_refresh_count = (chat.opts and chat.opts.title_refresh_count) or 0,
      token_estimate = 0, -- Will be calculated
    },
  }

  if chat.messages and #chat.messages > 0 then
    for _, message in ipairs(chat.messages) do
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

      if clean_message and clean_message.role then
        table.insert(session_data.messages, clean_message)
      end
    end
  end
  session_data.metadata.total_messages = #session_data.messages

  -- Calculate token estimate (rough approximation: 4 chars = 1 token)
  local total_chars = 0
  for _, message in ipairs(session_data.messages) do
    if message.content then
      total_chars = total_chars + #tostring(message.content)
    end
  end
  session_data.metadata.token_estimate = math.floor(total_chars / 4)

  return session_data
end

-- Save chat session to file
---@param chat table CodeCompanion chat object
---@param filename? string Optional filename, generates one if not provided
---@return boolean success, string? error_message
function SessionManager.save_session(chat, filename)
  if not chat then
    return false, 'Chat object cannot be nil'
  end

  if not ensure_sessions_dir() then
    return false, 'Failed to create sessions directory'
  end

  filename = filename or generate_session_filename()
  if not filename or filename == '' then
    return false, 'Invalid filename generated'
  end

  local session_path = get_session_path(filename)
  local session_data = prepare_chat_data(chat)

  -- Generate title if enabled and not already set
  if CONFIG.auto_generate_title and not session_data.title and session_data.messages and #session_data.messages > 0 then
    session_data.title = generate_title_from_messages(session_data.messages)
  end

  -- Write session data as Lua code using vim.inspect
  local lua_content = 'return ' .. vim.inspect(session_data)

  local file, open_err = io.open(session_path, 'w')
  if not file then
    return false, fmt('Failed to open session file for writing %s: %s', session_path, tostring(open_err))
  end

  local write_success, write_err = pcall(function()
    file:write(lua_content)
  end)

  file:close()

  if not write_success then
    return false, fmt('Failed to write session data to %s: %s', session_path, tostring(write_err))
  end

  -- Update index
  local index_success, index_err = update_session_index(session_data, filename)
  if not index_success then
    vim.notify('Warning: Failed to update session index: ' .. (index_err or 'unknown error'), vim.log.levels.WARN)
  end

  return true, filename
end

-- Load chat session from file
---@param filename string Session filename
---@return table? session_data, string? error_message
function SessionManager.load_session(filename)
  if not filename or filename == '' then
    return nil, 'Filename cannot be empty'
  end

  local session_path = get_session_path(filename)

  local file, open_err = io.open(session_path, 'r')
  if not file then
    return nil, fmt('Failed to open session file %s: %s', session_path, tostring(open_err))
  end

  local content, read_err = file:read('*all')
  file:close()

  if not content then
    return nil, fmt('Failed to read session file %s: %s', session_path, tostring(read_err))
  end

  if content == '' then
    return nil, fmt('Session file is empty: %s', session_path)
  end

  -- Create a safe sandbox environment for loading session data
  local safe_env = {
    -- Allow only safe operations for data structures
    pairs = pairs,
    ipairs = ipairs,
    next = next,
    type = type,
    tostring = tostring,
    tonumber = tonumber,
    -- No access to io, os, require, loadfile, dofile, etc.
  }

  -- Load Lua data safely with sandbox
  local chunk, err = load(content, nil, 't', safe_env) -- 't' = text only, no binary
  if not chunk then
    return nil, fmt('Failed to parse session file: %s', err)
  end

  local ok, session_data = pcall(chunk)
  if not ok then
    return nil, fmt('Failed to execute session data: %s', session_data)
  end

  -- Validate that the result is a table
  if type(session_data) ~= 'table' then
    return nil, 'Session data is not a valid table structure'
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
    tools = session_data.tools or {},
  },
    nil
end

-- List all available sessions with optional filtering
---@param filter_opts? table Optional filter options {project_root, adapter, date_range}
---@return table sessions List of session info objects
function SessionManager.list_sessions(filter_opts)
  if not ensure_sessions_dir() then
    return {}
  end

  local sessions = {}
  filter_opts = filter_opts or {}

  -- Try to use index for faster access if available
  if CONFIG.enable_index then
    local index_path = CONFIG.sessions_dir .. '/index.json'
    local file = io.open(index_path, 'r')
    if file then
      local content = file:read('*all')
      file:close()

      if content and content ~= '' then
        local ok, index = pcall(vim.json.decode, content)
        if ok and type(index) == 'table' then
          -- Convert index to session list format
          for _, entry in pairs(index) do
            -- Apply filters
            local include = true
            if filter_opts.project_root and entry.project_root ~= filter_opts.project_root then
              include = false
            end
            if filter_opts.adapter and entry.adapter ~= filter_opts.adapter then
              include = false
            end

            if include then
              table.insert(sessions, {
                filename = entry.filename,
                created_at = entry.created_at or 'Unknown',
                timestamp = entry.updated_at or 0,
                total_messages = entry.message_count or 0,
                model = entry.model or 'Unknown',
                adapter = entry.adapter or 'Unknown',
                chat_id = entry.save_id or 'unknown',
                title = entry.title or 'Untitled',
                project_root = entry.project_root,
                token_estimate = entry.token_estimate or 0,
                preview = entry.title or 'No preview available',
              })
            end
          end

          -- Sort by timestamp (newest first)
          table.sort(sessions, function(a, b)
            return (a.timestamp or 0) > (b.timestamp or 0)
          end)

          return sessions
        else
          vim.notify('Warning: Failed to parse session index, using fallback', vim.log.levels.WARN)
        end
      end
    end
  end

  -- Fallback to file scanning if index not available
  local handle = uv.fs_scandir(CONFIG.sessions_dir)

  if not handle then
    return sessions
  end

  while true do
    local name, file_type = uv.fs_scandir_next(handle)
    if not name then
      break
    end

    if file_type == 'file' and name:match('%.lua$') then
      local session_path = get_session_path(name)
      local stat = uv.fs_stat(session_path)

      if stat then
        -- Try to load session metadata quickly
        local file = io.open(session_path, 'r')
        if file then
          local content = file:read('*all')
          file:close()

          -- Use same safe sandbox as load_session
          local safe_env = {
            pairs = pairs,
            ipairs = ipairs,
            next = next,
            type = type,
            tostring = tostring,
            tonumber = tonumber,
          }

          local chunk, compile_err = load(content, nil, 't', safe_env)
          local ok, session_data = false, nil
          if chunk then
            ok, session_data = pcall(chunk)
            -- Validate result is a table
            if ok and type(session_data) ~= 'table' then
              ok = false
              session_data = 'Invalid session data structure'
            end
          else
            vim.notify(
              string.format('Failed to compile session %s: %s', name, tostring(compile_err)),
              vim.log.levels.WARN
            )
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
  if not filename or filename == '' then
    return false, 'Filename cannot be empty'
  end

  local session_path = get_session_path(filename)

  -- Use vim.uv.fs_unlink directly (modern approach)
  local err = vim.uv.fs_unlink(session_path)
  if err then
    return false, fmt('Failed to delete session file %s: %s', session_path, err)
  end

  -- Remove from index if enabled
  if CONFIG.enable_index then
    local index_path = CONFIG.sessions_dir .. '/index.json'
    local file = io.open(index_path, 'r')
    if file then
      local content = file:read('*all')
      file:close()

      if content and content ~= '' then
        local ok, index = pcall(vim.json.decode, content)
        if ok and type(index) == 'table' then
          -- Find and remove entries with this filename
          for entry_id, entry in pairs(index) do
            if entry.filename == filename then
              index[entry_id] = nil
              break
            end
          end

          -- Write updated index
          local write_file = io.open(index_path, 'w')
          if write_file then
            local json_ok, json_str = pcall(vim.json.encode, index)
            if json_ok and json_str then
              write_file:write(json_str)
            else
              vim.notify('Warning: Failed to encode updated index', vim.log.levels.WARN)
            end
            write_file:close()
          end
        else
          vim.notify('Warning: Failed to parse index for deletion cleanup', vim.log.levels.WARN)
        end
      end
    end
  end

  return true, nil
end

-- Clean up old sessions (keep only the most recent sessions based on config)
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

  if not chat or not chat.id then
    return
  end

  -- Only save if there are actual messages to preserve
  if not chat.messages or #chat.messages == 0 then
    return
  end

  -- Initialize session creation timestamp if not set
  if not chat._session_created_at then
    chat._session_created_at = os.time()
  end

  -- Use a persistent filename based on chat ID
  local session_filename = fmt('session_%s.lua', chat.id)
  local success, result = SessionManager.save_session(chat, session_filename)

  if not success then
    vim.notify(fmt('Failed to auto-save session: %s', result), vim.log.levels.WARN)
  else
    -- Optionally log successful saves for debugging
    vim.notify(fmt('Auto-saved session: %s', session_filename), vim.log.levels.DEBUG)
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
  local last_session = sessions[1]
  if not last_session or not last_session.filename or last_session.filename == '' then
    return nil, 'Invalid session data'
  end
  
  return last_session.filename, nil
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
    if message.role then
      -- Skip system messages only
      local is_system_prompt = message.role == 'system'

      if not is_system_prompt then
        -- Preserve the full message structure for proper CodeCompanion display
        local restored_message = {
          role = message.role,
          content = message.content,
        }

        -- Restore all preserved fields
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

  -- Create chat using CodeCompanion's Chat strategy
  local success, chat_or_error = pcall(function()
    local Chat = require('codecompanion.strategies.chat')
    local chat = Chat.new({
      adapter = adapter,
      auto_submit = false, -- Don't auto-submit, let user review first
      buffer_context = require('codecompanion.utils.context').get(vim.api.nvim_get_current_buf()),
      last_role = messages[#messages] and messages[#messages].role or 'user',
    })

    -- Preserve the original session ID to maintain continuity
    if session_data.session_id then
      chat.id = session_data.session_id
    end

    -- Set session creation timestamp for duration tracking
    chat._session_created_at = session_data.metadata and session_data.metadata.created_timestamp
      or session_data.timestamp
      or os.time()

    return chat
  end)

  if not success then
    return false, fmt('Failed to create CodeCompanion chat: %s', tostring(chat_or_error))
  end

  local chat = chat_or_error
  if not chat then
    return false, 'Failed to create CodeCompanion chat'
  end

  -- Add only the tools that were used in the original session
  local session_tools = session_data.tools or {}

  for _, tool_name in ipairs(session_tools) do
    -- Check if tool is already in use to avoid duplicates
    if chat.tool_registry.in_use[tool_name] then
      vim.notify(string.format('[SessionRestore] Tool %s already in use, skipping', tool_name), vim.log.levels.DEBUG)
    else
      local tool_config = config.strategies.chat.tools[tool_name]
      if tool_config then
        local success, err = pcall(function()
          chat.tool_registry:add(tool_name, tool_config, { visible = true })
        end)
        if not success then
          vim.notify(
            string.format('[SessionRestore] Failed to restore tool %s: %s', tool_name, tostring(err)),
            vim.log.levels.ERROR
          )
        end
      elseif config.strategies.chat.tools.groups and config.strategies.chat.tools.groups[tool_name] then
        -- Try group addition as fallback
        local success, err = pcall(function()
          chat.tool_registry:add_group(tool_name, config.strategies.chat.tools)
        end)
        if not success then
          vim.notify(
            string.format('[SessionRestore] Failed to restore tool group %s: %s', tool_name, tostring(err)),
            vim.log.levels.ERROR
          )
        end
      else
        vim.notify(string.format('[SessionRestore] Tool not found in config: %s', tool_name), vim.log.levels.WARN)
      end
    end
  end

  for _, message in ipairs(messages) do
    pcall(function()
      -- Check if this is a tool output message
      if message.tool_call_id and message.role == 'tool' then
        -- For tool output messages, we need to create a mock tool object
        -- to use with add_tool_output
        local mock_tool = {
          function_call = {
            id = message.tool_call_id,
            name = message.tool_name or message.name or 'unknown_tool',
          },
        }
        chat:add_tool_output(mock_tool, message.content, '')
      else
        -- First add to message history
        chat:add_message(message, { visible = false })
        -- Then add to buffer display
        chat:add_buf_message(message, {})
      end
    end)
  end

  -- Ensure buffer is ready for user input
  vim.schedule(function()
    -- Make buffer modifiable
    vim.bo[chat.bufnr].modifiable = true

    -- Set cursor to end of buffer
    local line_count = vim.api.nvim_buf_line_count(chat.bufnr)
    vim.api.nvim_win_set_cursor(0, { line_count, 0 })

    -- Fire ChatCreated event to ensure UI is properly initialized
    local util_ok, util = pcall(require, 'codecompanion.utils')
    if util_ok then
      util.fire('ChatCreated', { bufnr = chat.bufnr, from_prompt_library = false, id = chat.id })
    end
  end)

  vim.notify(fmt('Restored session: %s (%d messages)', filename, #session_data.messages), vim.log.levels.INFO)
  return true, nil
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

-- Save session data directly (utility for UI operations)
---@param session_data table Session data to save
---@param filename string Target filename
---@return boolean success, string? error_message
function SessionManager.save_session_data(session_data, filename)
  if not session_data or not filename then
    return false, 'Invalid session data or filename'
  end

  if not ensure_sessions_dir() then
    return false, 'Failed to create sessions directory'
  end

  local session_path = get_session_path(filename)

  -- Write session data as Lua code using vim.inspect
  local lua_content = 'return ' .. vim.inspect(session_data)

  local file, open_err = io.open(session_path, 'w')
  if not file then
    return false, fmt('Failed to open session file for writing %s: %s', session_path, tostring(open_err))
  end

  local write_success, write_err = pcall(function()
    file:write(lua_content)
  end)

  file:close()

  if not write_success then
    return false, fmt('Failed to write session data to %s: %s', session_path, tostring(write_err))
  end

  -- Update index
  local index_success, index_err = update_session_index(session_data, filename)
  if not index_success then
    vim.notify('Warning: Failed to update session index: ' .. (index_err or 'unknown error'), vim.log.levels.WARN)
  end

  return true, nil
end

-- Generate new save ID (utility for UI operations)
---@return string save_id
function SessionManager.generate_save_id()
  return generate_save_id()
end

-- Find project root (utility for UI operations)
---@param path? string Path to start from
---@return string project_root
function SessionManager.find_project_root(path)
  return find_project_root(path)
end

-- Generate session filename (utility for UI operations)
---@return string filename
function SessionManager.generate_session_filename()
  return generate_session_filename()
end

return SessionManager
