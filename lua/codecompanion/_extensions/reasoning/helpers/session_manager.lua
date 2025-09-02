---@class CodeCompanion.SessionManager
---Chat session storage and management for CodeCompanion reasoning extension
local SessionManager = {}

local fmt = string.format
local TitleGenerator = require('codecompanion._extensions.reasoning.helpers.title_generator')
local SessionStorage = require('codecompanion._extensions.reasoning.helpers.session_storage')
local SessionDataTransformer = require('codecompanion._extensions.reasoning.helpers.session_data_transformer')
local SessionRestorer = require('codecompanion._extensions.reasoning.helpers.session_restorer')

-- Configuration
local CONFIG = {
  auto_save = true,
  auto_load_last_session = true,
  auto_generate_title = true,
}

-- Save chat session to file
---@param chat table CodeCompanion chat object
---@return boolean success, string? error_message
function SessionManager.save_session(chat)
  if not chat then
    return false, 'Chat object cannot be nil'
  end

  local existing_title = (chat.opts and chat.opts.title) or nil
  local filename = chat._session_filename or SessionStorage.generate_filename()
  if not filename or filename == '' then
    return false, 'Invalid filename generated'
  end

  local session_data = SessionDataTransformer.prepare_chat_data(chat)

  if existing_title and existing_title ~= '' then
    session_data.title = existing_title
  elseif CONFIG.auto_generate_title and session_data.messages and #session_data.messages > 0 then
    session_data.title = SessionDataTransformer.generate_simple_title(session_data.messages)
  end

  local success, err = SessionStorage.write_session(session_data, filename)
  if not success then
    return false, err
  end

  chat._session_filename = filename
  chat.opts = chat.opts or {}
  chat.opts.session_filename = filename

  if CONFIG.auto_generate_title then
    pcall(function()
      local tg = TitleGenerator.new({
        auto_generate_title = true,
      })
      tg:generate(chat, function(new_title)
        if not new_title or new_title == '' then
          return
        end
        local updated = vim.deepcopy(session_data)
        updated.title = new_title
        SessionStorage.write_session(updated, filename)
      end)
    end)
  end

  return true, filename
end

-- Load chat session from file
---@param filename string Session filename
---@return table? session_data, string? error_message
function SessionManager.load_session(filename)
  local raw_session_data, err = SessionStorage.read_session(filename)
  if not raw_session_data then
    return nil, err
  end

  return {
    messages = raw_session_data.messages or {},
    config = raw_session_data.config or {},
    metadata = raw_session_data.metadata or {},
    session_id = raw_session_data.chat_id,
    created_at = raw_session_data.created_at,
    timestamp = raw_session_data.timestamp,
    version = raw_session_data.version,
    tools = raw_session_data.tools or {},
    title = raw_session_data.title,
  },
    nil
end

-- List all available sessions with optional filtering
---@param filter_opts? table Optional filter options {project_root, adapter, date_range}
---@return table sessions List of session info objects
function SessionManager.list_sessions(filter_opts)
  local sessions = {}
  filter_opts = filter_opts or {}

  local session_files = SessionStorage.list_session_files()

  for _, file_info in ipairs(session_files) do
    local raw_session_data, err = SessionStorage.read_session(file_info.filename)
    if raw_session_data then
      table.insert(sessions, {
        filename = file_info.filename,
        created_at = raw_session_data.created_at or 'Unknown',
        timestamp = raw_session_data.timestamp or file_info.stat.mtime.sec,
        total_messages = raw_session_data.metadata and raw_session_data.metadata.total_messages or 0,
        model = raw_session_data.config and raw_session_data.config.model or 'Unknown',
        chat_id = raw_session_data.chat_id or 'unknown',
        file_size = file_info.stat.size,
        title = raw_session_data.title,
        preview = SessionDataTransformer.get_session_preview(raw_session_data),
      })
    else
      vim.notify(fmt('Failed to read session %s: %s', file_info.filename, tostring(err)), vim.log.levels.WARN)
    end
  end

  table.sort(sessions, function(a, b)
    return a.timestamp > b.timestamp
  end)

  return sessions
end

-- Asynchronously (re)generate titles for existing sessions
---@param filter_opts? table Optional filter for list_sessions
function SessionManager.refresh_session_titles(filter_opts)
  local sessions = SessionManager.list_sessions(filter_opts)
  if #sessions == 0 then
    return
  end

  local tg = TitleGenerator.new({ auto_generate_title = true })

  for _, meta in ipairs(sessions) do
    local session_data = SessionManager.load_session(meta.filename)
    if
      session_data
      and (
        not session_data.title
        or session_data.title == ''
        or session_data.title == SessionDataTransformer.get_session_preview(session_data)
      )
    then
      local chat = {
        messages = session_data.messages or {},
        adapter = (function()
          local adapters_ok, adapters = pcall(require, 'codecompanion.adapters')
          if adapters_ok and adapters.resolve and session_data.config and session_data.config.adapter then
            return adapters.resolve(session_data.config.adapter)
          end
          return nil
        end)(),
        settings = (function()
          local schema_ok, schema = pcall(require, 'codecompanion.schema')
          if schema_ok and session_data.config and session_data.config.model then
            local adapters_ok2, adapters2 = pcall(require, 'codecompanion.adapters')
            if adapters_ok2 and adapters2.resolve and session_data.config.adapter then
              local adapter = adapters2.resolve(session_data.config.adapter)
              if adapter then
                return schema.get_default(adapter, { model = session_data.config.model })
              end
            end
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
          local raw_session_data, read_err = SessionStorage.read_session(meta.filename)
          if not raw_session_data then
            return
          end

          raw_session_data.title = new_title
          SessionStorage.write_session(raw_session_data, meta.filename)
        end)
      end)
    end
  end
end

-- Get a brief preview of session content
---@param session_data table
---@return string preview
function SessionManager.get_session_preview(session_data)
  return SessionDataTransformer.get_session_preview(session_data)
end

-- Delete session file
---@param filename string Session filename
---@return boolean success, string? error_message
function SessionManager.delete_session(filename)
  return SessionStorage.delete_session(filename)
end

-- Clean up old sessions (keep only the most recent sessions based on config)
function SessionManager.cleanup_old_sessions()
  local sessions = SessionManager.list_sessions()
  local max_sessions = SessionStorage.get_max_sessions()

  if #sessions <= max_sessions then
    return
  end

  -- Delete oldest sessions
  for i = max_sessions + 1, #sessions do
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
  return SessionRestorer.restore_session(session_data, filename)
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
  return SessionStorage.get_sessions_dir()
end

-- Update configuration
---@param new_config table
function SessionManager.setup(new_config)
  if new_config then
    CONFIG = vim.tbl_deep_extend('force', CONFIG, new_config)
    -- Propagate storage-related options such as sessions_dir, patterns, limits
    SessionStorage.setup(new_config)
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

  return SessionStorage.write_session(session_data, filename)
end

-- Generate new save ID (utility for UI operations)
---@return string save_id
function SessionManager.generate_save_id()
  return SessionDataTransformer.generate_save_id()
end

-- Find project root (utility for UI operations)
---@return string project_root
function SessionManager.find_project_root()
  return vim.fn.getcwd()
end

-- Generate session filename (utility for UI operations)
---@return string filename
function SessionManager.generate_session_filename()
  return SessionStorage.generate_filename()
end

return SessionManager
