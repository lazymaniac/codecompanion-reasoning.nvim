---@class CodeCompanion.SessionManager
---Chat session storage and management for CodeCompanion reasoning extension
local SessionManager = {}

local fmt = string.format
local uv = vim.loop
local TitleGenerator = require('codecompanion._extensions.reasoning.helpers.title_generator')

-- Configuration
local CONFIG = {
  sessions_dir = vim.fn.stdpath('data') .. '/codecompanion-reasoning/sessions',
  session_file_pattern = 'session_%Y%m%d_%H%M%S.lua',
  max_sessions = 100, -- Keep last 100 sessions
  auto_save = true,
  auto_load_last_session = true,
  auto_generate_title = true,
  expiration_days = 0, -- 0 to disable
}

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

-- Extract tools that were used in the chat from tool_registry
---@param chat table CodeCompanion chat object
---@return table tools_used
local function extract_used_tools(chat)
  local tools_used = {}

  -- First, check if chat has tool_registry with in_use tools
  if chat.tool_registry and chat.tool_registry.in_use then
    for tool_name, _ in pairs(chat.tool_registry.in_use) do
      tools_used[tool_name] = true
    end
  end

  -- Fallback: extract from messages if tool_registry not available
  if next(tools_used) == nil and chat.messages then
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

-- Prepare chat data for storage (extract only serializable parts)
---@param chat table CodeCompanion chat object
---@return table session_data
local function prepare_chat_data(chat)
  local current_time = os.time()
  local created_time = chat._session_created_at or current_time
  local session_duration = current_time - created_time
  local cwd = vim.fn.getcwd()

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
    project_root = cwd,

    config = {
      adapter = (chat.adapter and (chat.adapter.name or chat.adapter.formatted_name)) or 'unknown',
      model = (function()
        if chat.adapter and chat.adapter.type == 'http' then
          if chat.settings and chat.settings.model then
            return chat.settings.model
          end
          local def = chat.adapter.schema and chat.adapter.schema.model and chat.adapter.schema.model.default
          if type(def) == 'function' then
            local ok, val = pcall(def, chat.adapter)
            if ok and val then
              return val
            end
          elseif def then
            return def
          end
        end
        return 'unknown'
      end)(),
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
      local clean_message = {
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
      }

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
---@return boolean success, string? error_message
function SessionManager.save_session(chat)
  if not chat then
    return false, 'Chat object cannot be nil'
  end

  if not ensure_sessions_dir() then
    return false, 'Failed to create sessions directory'
  end

  local existing_title = (chat.opts and chat.opts.title) or nil
  local filename = chat._session_filename or generate_session_filename()
  if not filename or filename == '' then
    return false, 'Invalid filename generated'
  end

  local session_path = get_session_path(filename)
  local session_data = prepare_chat_data(chat)

  -- Include title in stored data now if available (fallback initial)
  if existing_title and existing_title ~= '' then
    session_data.title = existing_title
  elseif CONFIG.auto_generate_title and session_data.messages and #session_data.messages > 0 then
    -- provisional fallback title until async generation completes
    session_data.title = generate_title_from_messages(session_data.messages)
  end

  -- Write session data (create or overwrite)
  do
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
  end

  -- Remember filename on chat for subsequent overwrites (avoid multiple files per session)
  chat._session_filename = filename
  chat.opts = chat.opts or {}
  chat.opts.session_filename = filename

  -- Kick off async title generation and persist title (no rename required)
  if CONFIG.auto_generate_title then
    pcall(function()
      local tg = TitleGenerator.new({
        auto_generate_title = true,
      })
      tg:generate(chat, function(new_title)
        if not new_title or new_title == '' then
          return
        end
        -- Update content with title in place (keep filename stable)
        local updated = vim.deepcopy(session_data)
        updated.title = new_title
        local lua_content2 = 'return ' .. vim.inspect(updated)
        local wf = io.open(session_path, 'w')
        if wf then
          wf:write(lua_content2)
          wf:close()
        end
      end)
    end)
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

  -- Scan files directly
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

          -- Asynchronously (re)generate titles for existing sessions
          ---@param filter_opts? table Optional filter for list_sessions
          function SessionManager.refresh_session_titles(filter_opts)
            local sessions = SessionManager.list_sessions(filter_opts)
            if #sessions == 0 then
              return
            end

            local tg = TitleGenerator.new({ auto_generate_title = true })

            for _, meta in ipairs(sessions) do
              -- Load full session content
              local session_data = SessionManager.load_session(meta.filename)
              if
                session_data
                and (
                  not session_data.title
                  or session_data.title == ''
                  or session_data.title == SessionManager.get_session_preview(session_data)
                )
              then
                -- Build minimal pseudo chat for TitleGenerator
                local chat = {
                  messages = session_data.messages or {},
                  adapter = (function()
                    local adapters_ok, adapters = pcall(require, 'codecompanion.adapters')
                    if adapters_ok and adapters.resolve and session_data.config and session_data.config.adapter then
                      return adapters.resolve(session_data.config.adapter)
                    end
                    -- fallback to current adapter (if any) or nil
                    return nil
                  end)(),
                  settings = (function()
                    local schema_ok, schema = pcall(require, 'codecompanion.schema')
                    if schema_ok and session_data.config and session_data.config.model and chat and chat.adapter then
                      return schema.get_default(chat.adapter, { model = session_data.config.model })
                    end
                    return nil
                  end)(),
                }

                -- Generate and persist
                pcall(function()
                  tg:generate(chat, function(new_title)
                    if not new_title or new_title == '' then
                      return
                    end

                    -- Read original file, update title, and write in place
                    local session_path = get_session_path(meta.filename)
                    local file = io.open(session_path, 'r')
                    if not file then
                      return
                    end
                    local content = file:read('*all')
                    file:close()

                    local loader = load
                    local ok1, chunk = pcall(
                      loader,
                      content,
                      nil,
                      't',
                      { pairs = pairs, ipairs = ipairs, type = type, tostring = tostring, tonumber = tonumber }
                    )
                    if not ok1 or not chunk then
                      return
                    end
                    local ok2, data = pcall(chunk)
                    if not ok2 or type(data) ~= 'table' then
                      return
                    end
                    data.title = new_title

                    local updated = 'return ' .. vim.inspect(data)
                    local wf = io.open(session_path, 'w')
                    if wf then
                      wf:write(updated)
                      wf:close()
                    end
                  end)
                end)
              end
            end
          end

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
              title = session_data.title,
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

  local success, result = SessionManager.save_session(chat)

  if not success then
    vim.notify(fmt('Failed to auto-save session: %s', result), vim.log.levels.WARN)
  else
    vim.notify(fmt('Auto-saved session'), vim.log.levels.DEBUG)
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

  -- De-duplicate messages saved due to earlier bugs while preserving content
  pcall(function()
    local ok_opt, SessionOptimizer = pcall(require, 'codecompanion._extensions.reasoning.helpers.session_optimizer')
    if ok_opt then
      local optimizer = SessionOptimizer.new({
        remove_duplicate_messages = true,
        max_consecutive_duplicates = 1,
        remove_empty_messages = false,
        compact_tool_outputs = false,
        max_message_length = 10000000,
      })
      local optimized = optimizer:optimize_session({
        messages = vim.deepcopy(session_data.messages or {}),
        metadata = session_data.metadata or {},
      })
      session_data.messages = optimized.messages or session_data.messages
      session_data.metadata = optimized.metadata or session_data.metadata
    end
  end)

  -- Try to access CodeCompanion and its config
  local config_ok, config = pcall(require, 'codecompanion.config')
  if not config_ok then
    return false, 'CodeCompanion config not available'
  end

  -- Resolve adapter name from session config or use default
  local adapter_name = nil
  if session_data.config and session_data.config.adapter and session_data.config.adapter ~= 'unknown' then
    adapter_name = session_data.config.adapter
  end
  if not adapter_name then
    adapter_name = config.default_adapter
  end

  -- Convert session messages to CodeCompanion format, preserving structure
  local function flatten_table_parts(tbl)
    local parts = {}
    for _, v in ipairs(tbl) do
      if type(v) == 'string' then
        table.insert(parts, v)
      elseif type(v) == 'table' then
        if type(v.text) == 'string' then
          table.insert(parts, v.text)
        elseif type(v.content) == 'string' then
          table.insert(parts, v.content)
        elseif type(v.value) == 'string' then
          table.insert(parts, v.value)
        end
      end
    end
    return parts
  end

  local function normalize_content(content)
    if type(content) == 'string' then
      return content
    elseif type(content) == 'table' then
      -- Try to extract concatenated text fields from arrays of parts
      local parts = flatten_table_parts(content)
      if #parts > 0 then
        return table.concat(parts, '\n')
      end
      return tostring(vim.inspect(content))
    else
      return tostring(content)
    end
  end

  local function extract_any_content(msg)
    -- prefer explicit content
    local c = normalize_content(msg.content)
    if c and c ~= 'nil' and vim.trim(c) ~= '' then
      return c
    end
    -- fallbacks commonly seen in stored tool messages
    local candidates = {
      msg.output,
      msg.result,
      msg.text,
      msg.message,
      msg.data,
      msg.delta,
      msg.response,
      msg.stdout,
      msg.stderr,
      msg.for_user,
      msg.for_llm,
      msg.display,
      msg.value,
      msg.user_output,
    }
    for _, cand in ipairs(candidates) do
      local s = normalize_content(cand)
      if s and s ~= 'nil' and vim.trim(s) ~= '' then
        return s
      end
    end
    return ''
  end
  local messages = {}
  local tool_call_map = {}
  local last_tool_call = nil
  for _, message in ipairs(session_data.messages) do
    if message.role then
      -- Skip system messages only
      local is_system_prompt = message.role == 'system'

      if not is_system_prompt then
        -- Normalize role for older dumps (function -> tool)
        local role = message.role
        if role == 'function' then
          role = 'tool'
          if not message.tool_call_id and message.id then
            message.tool_call_id = message.id
          end
          if not message.tool_name and message.name then
            message.tool_name = message.name
          end
        elseif role == 'llm' or role == 'model' then
          role = 'llm'
        end
        -- Preserve the full message structure for proper CodeCompanion display
        local restored_message = {
          role = role,
          content = extract_any_content(message),
        }

        -- Restore all preserved fields
        if message.tool_calls then
          restored_message.tool_calls = message.tool_calls
          -- Record tool call ids to map subsequent tool outputs
          for _, call in ipairs(message.tool_calls) do
            local call_id = (call and (call.id or (call['function'] and call['function'].id)))
            local call_name = (call and call['function'] and call['function'].name) or message.tool_name or message.name
            if call_id and call_name then
              tool_call_map[call_id] = { name = call_name }
              last_tool_call = { id = call_id, name = call_name }
            end
          end
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
          restored_message.opts = vim.deepcopy(message.opts)
        else
          restored_message.opts = {}
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
        -- Force visibility for normal conversation and tool outputs on restore
        if role == 'user' or role == 'llm' or role == 'tool' then
          restored_message.visible = true
          restored_message.opts.visible = true
        elseif message.visible ~= nil then
          restored_message.visible = message.visible
          if restored_message.opts.visible == nil then
            restored_message.opts.visible = message.visible
          end
        end
        if message.timestamp then
          restored_message.timestamp = message.timestamp
        end

        -- If this is an assistant tool-call message with no content, synthesize a readable summary
        if
          restored_message.role == 'llm'
          and (not restored_message.content or restored_message.content == '')
          and restored_message.tool_calls
        then
          local parts = {}
          for _, call in ipairs(restored_message.tool_calls) do
            local fname = (call['function'] and call['function'].name) or 'tool'
            table.insert(parts, string.format('called %s', fname))
          end
          restored_message.content = table.concat(parts, '; ')
        end

        -- For tool outputs with no textual content, provide a placeholder to avoid rendering 'nil'
        if restored_message.role == 'tool' and (not restored_message.content or restored_message.content == '') then
          local name = restored_message.tool_name or restored_message.name or 'tool'
          restored_message.content = string.format('[%s output]', name)
        end

        -- If this is a tool output without an id, associate it to the last assistant tool call
        if restored_message.role == 'tool' and not restored_message.tool_call_id and last_tool_call then
          restored_message.tool_call_id = last_tool_call.id
          restored_message.tool_name = restored_message.tool_name or last_tool_call.name
        end

        table.insert(messages, restored_message)
      end
    end
  end

  -- Create chat using CodeCompanion's Chat strategy
  local success, chat_or_error = pcall(function()
    local Chat = require('codecompanion.strategies.chat')
    local chat = Chat.new({
      adapter = adapter_name,
      auto_submit = false, -- Don't auto-submit, let user review first
      buffer_context = require('codecompanion.utils.context').get(vim.api.nvim_get_current_buf()),
      last_role = messages[#messages] and messages[#messages].role or 'user',
      settings = (function()
        local model = session_data.config and session_data.config.model
        if model and model ~= 'unknown' then
          return { model = model }
        end
        return nil
      end)(),
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
  -- Preserve original session filename for subsequent saves
  chat._session_filename = filename
  chat.opts = chat.opts or {}
  chat.opts.session_filename = filename

  --
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

  local added_reasoning = {}
  for _, message in ipairs(messages) do
    pcall(function()
      -- If this is an assistant reasoning chunk, render it first using CC's reasoning formatter
      if message.role == 'llm' and message.reasoning and type(message.reasoning) == 'table' then
        local rtext = normalize_content(message.reasoning.content)
        local key = tostring(message.id or '') .. ':' .. tostring(#rtext)
        if rtext and vim.trim(rtext) ~= '' and not added_reasoning[key] then
          added_reasoning[key] = true
          chat:add_buf_message({ role = config.constants.LLM_ROLE, content = rtext }, {
            type = chat.MESSAGE_TYPES.REASONING_MESSAGE,
          })
        end
      end

      -- Render tool outputs via add_tool_output when possible to preserve linkage
      if message.tool_call_id and message.role == 'tool' then
        local mapping = tool_call_map[message.tool_call_id]
        local tool_name = (message.tool_name or message.name or (mapping and mapping.name))
        local tool_config = tool_name and config.strategies.chat.tools[tool_name] or nil
        local tool_impl = tool_config and tool_config.callback or nil

        local tool_obj = { function_call = { id = message.tool_call_id, name = tool_name or 'unknown_tool' } }
        if tool_impl then
          -- Attach schema and fallback methods for better fidelity
          tool_obj.schema = tool_impl.schema
          tool_obj.id = tool_impl.id or ('restored:' .. (tool_name or 'tool'))
          setmetatable(tool_obj, { __index = tool_impl })
        end

        -- Fallback to generic rendering if add_tool_output errors
        local ok = pcall(function()
          -- Some implementations accept (tool, content) or (tool, content, display)
          local out_text = extract_any_content(message)
          chat:add_tool_output(tool_obj, out_text, out_text)
        end)
        if not ok then
          local is_visible = (message.role == 'user' or message.role == 'llm' or message.role == 'tool') and true
            or message.visible ~= false
          -- Ensure user-visible tool block formatting in UI
          local out_text = extract_any_content(message)
          chat:add_message(vim.tbl_extend('force', message, { content = out_text }), { visible = is_visible })
          chat:add_buf_message({ role = config.constants.LLM_ROLE, content = out_text }, {
            type = chat.MESSAGE_TYPES.TOOL_MESSAGE,
          })
        end
      else
        -- Regular chat message
        local is_visible = (message.role == 'user' or message.role == 'llm' or message.role == 'tool') and true
          or message.visible ~= false
        chat:add_message(message, { visible = is_visible })
        -- Use explicit message type for UI rendering
        local ui_type = nil
        if message.role == 'llm' then
          ui_type = chat.MESSAGE_TYPES.LLM_MESSAGE
        elseif message.role == 'tool' then
          ui_type = chat.MESSAGE_TYPES.TOOL_MESSAGE
        end
        chat:add_buf_message(message, ui_type and { type = ui_type } or {})
      end
    end)
  end

  -- Sanitize all stored messages to ensure HTTP adapters receive strings
  pcall(function()
    if chat and chat.messages then
      for _, m in ipairs(chat.messages) do
        if m and m.content ~= nil and type(m.content) ~= 'string' then
          -- Try to normalize tables into strings; otherwise, empty string
          local ok, normalized = pcall(function()
            return normalize_content(m.content)
          end)
          if ok and normalized then
            m.content = normalized
          else
            m.content = ''
          end
        end
      end
    end
  end)

  -- Ensure the chat is ready for next user input with a visible user header
  pcall(function()
    if chat and chat.tools_done then
      chat:tools_done({})
    else
      -- Fallback: explicitly add a user header in the buffer
      chat:add_buf_message({ role = config.constants.USER_ROLE, content = '' })
    end
  end)

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

  return true, nil
end

-- Generate new save ID (utility for UI operations)
---@return string save_id
function SessionManager.generate_save_id()
  return generate_save_id()
end

-- Find project root (utility for UI operations)
---@return string project_root
function SessionManager.find_project_root()
  return vim.fn.getcwd()
end

-- Generate session filename (utility for UI operations)
---@return string filename
function SessionManager.generate_session_filename()
  return generate_session_filename()
end

return SessionManager
