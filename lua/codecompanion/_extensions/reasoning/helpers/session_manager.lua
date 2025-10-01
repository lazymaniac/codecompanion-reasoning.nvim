---@class CodeCompanion.SessionManager
---Chat session storage and management for CodeCompanion reasoning extension
local SessionManager = {}

local fmt = string.format
local TitleGenerator = require('codecompanion._extensions.reasoning.helpers.session_title_generator')
local SessionStorage = require('codecompanion._extensions.reasoning.helpers.session_storage')
local SessionDataTransformer = require('codecompanion._extensions.reasoning.helpers.session_data_transformer')
local SessionRestorer = require('codecompanion._extensions.reasoning.helpers.session_restorer')
local config = require('codecompanion._extensions.reasoning.config')

local immediate_auto_load_scheduled = false
local pending_auto_load = nil

local function perform_auto_load(chat)
  if not pending_auto_load or pending_auto_load.executing then
    return
  end
  if not chat or not chat.bufnr or not vim.api.nvim_buf_is_valid(chat.bufnr) then
    return
  end

  pending_auto_load.executing = true
  local filename = pending_auto_load.filename

  vim.schedule(function()
    if not vim.api.nvim_buf_is_valid(chat.bufnr) then
      pending_auto_load = nil
      return
    end

    local session_data, load_err = SessionManager.load_session(filename)
    if not session_data then
      pending_auto_load = nil
      if load_err then
        vim.notify(fmt('Failed to load session "%s": %s', filename, load_err), vim.log.levels.WARN)
      end
      return
    end

    local ok, restored_chat_or_err = SessionRestorer.restore_session(session_data, filename, { chat = chat })
    pending_auto_load = nil
    if not ok then
      vim.notify(fmt('Failed to restore session "%s": %s', filename, restored_chat_or_err), vim.log.levels.WARN)
      return
    end

    local restored_chat = restored_chat_or_err or chat
    if restored_chat and restored_chat.bufnr and vim.api.nvim_buf_is_valid(restored_chat.bufnr) then
      local win = vim.fn.bufwinid(restored_chat.bufnr)
      if win ~= -1 and vim.api.nvim_win_is_valid(win) then
        pcall(vim.api.nvim_set_current_win, win)
      else
        pcall(vim.api.nvim_set_current_buf, restored_chat.bufnr)
      end
    end
  end)
end

local function attempt_pending_auto_load()
  if not pending_auto_load then
    return false
  end

  local ok_chat_mod, Chat = pcall(require, 'codecompanion.strategies.chat')
  if not ok_chat_mod or not Chat or not Chat.buf_get_chat then
    return false
  end

  local current_buf = vim.api.nvim_get_current_buf()
  if vim.api.nvim_buf_is_valid(current_buf) and vim.bo[current_buf].filetype == 'codecompanion' then
    local ok_chat, chat = pcall(Chat.buf_get_chat, current_buf)
    if ok_chat and chat then
      perform_auto_load(chat)
      return true
    end
  end

  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_valid(buf) and vim.bo[buf].filetype == 'codecompanion' then
      local ok_chat, chat = pcall(Chat.buf_get_chat, buf)
      if ok_chat and chat then
        perform_auto_load(chat)
        return true
      end
    end
  end

  return false
end

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
  elseif config.get().session_history.auto_generate_title and session_data.messages and #session_data.messages > 0 then
    session_data.title = SessionDataTransformer.generate_simple_title(session_data.messages)
  end

  local success, err = SessionStorage.write_session(session_data, filename)
  if not success then
    return false, err
  end

  chat._session_filename = filename
  chat.opts = chat.opts or {}
  chat.opts.session_filename = filename

  -- Auto-generate title if enabled
  if config.get().session_history.auto_generate_title then
    pcall(function()
      local tg = TitleGenerator.new()
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

  -- Auto-generate tags for new sessions if we have enough content
  if session_data.messages and #session_data.messages >= 2 then
    pcall(function()
      SessionManager._generate_session_tags(session_data, function(tags)
        if tags and #tags > 0 then
          local updated = vim.deepcopy(session_data)
          updated.metadata = updated.metadata or {}
          updated.metadata.tags = tags
          SessionStorage.write_session(updated, filename)
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
      -- Calculate token estimation
      local token_estimate = nil
      if raw_session_data.metadata and raw_session_data.metadata.token_estimate then
        token_estimate = raw_session_data.metadata.token_estimate
      else
        -- Rough estimation: 4 characters per token
        token_estimate = math.floor(file_info.stat.size / 4)
      end

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
        tags = raw_session_data.metadata and raw_session_data.metadata.tags or {},
        is_favorite = raw_session_data.metadata and raw_session_data.metadata.favorite or false,
        token_estimate = token_estimate,
      })
    else
      vim.notify(fmt('Failed to read session %s: %s', file_info.filename, tostring(err)), vim.log.levels.WARN)
    end
  end

  -- Sort sessions: favorites first, then by timestamp
  table.sort(sessions, function(a, b)
    if a.is_favorite ~= b.is_favorite then
      return a.is_favorite -- favorites come first
    end
    return a.timestamp > b.timestamp -- then by timestamp (newest first)
  end)

  return sessions
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

  for i = max_sessions + 1, #sessions do
    SessionManager.delete_session(sessions[i].filename)
  end
end

-- Auto-save session after each new message
---@param chat table CodeCompanion chat object
function SessionManager.auto_save_session(chat)
  if not config.get().session_history.auto_save then
    return
  end

  if not chat or not chat.id then
    return
  end

  if not chat.messages or #chat.messages == 0 then
    return
  end

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

  local last_session = sessions[1]
  if not last_session or not last_session.filename or last_session.filename == '' then
    return nil, 'Invalid session data'
  end

  return last_session.filename, nil
end

---@param filename string Session filename
---@param opts? table Optional restore options (e.g. existing chat instance)
---@return boolean success, string? error_message
function SessionManager.restore_session(filename, opts)
  local session_data, err = SessionManager.load_session(filename)
  if not session_data then
    return false, err
  end
  return SessionRestorer.restore_session(session_data, filename, opts)
end

-- Auto-load last session if enabled
function SessionManager.continue_last_session()
  if not config.get().session_history.continue_last_chat then
    return
  end

  local last_session = SessionManager.get_last_session()
  if not last_session then
    return
  end

  pending_auto_load = pending_auto_load or { executing = false }
  pending_auto_load.filename = last_session
  pending_auto_load.executing = false

  attempt_pending_auto_load()
end

-- Update configuration
function SessionManager.setup()
  SessionStorage.setup()

  pending_auto_load = nil
  immediate_auto_load_scheduled = false

  if config.get().session_history.continue_last_chat then
    local group = vim.api.nvim_create_augroup('CodeCompanionSessionAutoLoad', { clear = true })
    vim.api.nvim_create_autocmd('VimEnter', {
      group = group,
      callback = function()
        vim.defer_fn(function()
          SessionManager.continue_last_session()
        end, 100)
      end,
    })

    if vim.v.vim_did_enter == 1 and not immediate_auto_load_scheduled then
      immediate_auto_load_scheduled = true
      vim.defer_fn(function()
        SessionManager.continue_last_session()
      end, 100)
    end

    vim.api.nvim_create_autocmd('User', {
      pattern = 'CodeCompanionChatCreated',
      group = group,
      callback = function(event)
        if not pending_auto_load then
          return
        end

        if not event or not event.data or not event.data.bufnr then
          return
        end

        local ok_chat_mod, Chat = pcall(require, 'codecompanion.strategies.chat')
        if not ok_chat_mod or not Chat or not Chat.buf_get_chat then
          return
        end

        local ok_chat, chat = pcall(Chat.buf_get_chat, event.data.bufnr)
        if not ok_chat or not chat then
          return
        end

        perform_auto_load(chat)
      end,
    })
  else
    pcall(vim.api.nvim_del_augroup_by_name, 'CodeCompanionSessionAutoLoad')
  end
end

SessionManager.auto_load_last_session = SessionManager.continue_last_session

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

-- Generate tags for a session using LLM (internal function)
---@param session_data table Session data
---@param callback function Callback to receive tags array
function SessionManager._generate_session_tags(session_data, callback)
  if not session_data.messages or #session_data.messages == 0 then
    if callback then
      callback({})
    end
    return
  end

  -- Create a conversation context similar to title generation
  local relevant_messages = vim.tbl_filter(function(msg)
    local normalized_content = msg.content and normalize_content(msg.content) or ''
    local has_content = vim.trim(normalized_content) ~= ''
    local is_relevant_role = msg.role == 'user' or msg.role == 'assistant'
    local not_tagged = not (msg.opts and (msg.opts.tag or msg.opts.reference or msg.opts.context_id))
    return has_content and is_relevant_role and not_tagged
  end, session_data.messages)

  if #relevant_messages == 0 then
    if callback then
      callback({})
    end
    return
  end

  local conversation_lines = {}
  for i = 1, math.min(10, #relevant_messages) do -- Limit to first 10 messages for tagging
    local message = relevant_messages[i]
    local role_prefix = message.role == 'user' and 'User' or 'Assistant'
    local content = vim.trim(message.content)

    if #content > 500 then
      content = content:sub(1, 500) .. ' [truncated]'
    end

    table.insert(conversation_lines, role_prefix .. ': ' .. content)
  end

  local conversation_context = table.concat(conversation_lines, '\n')

  local prompt = fmt(
    [[Generate 3-5 relevant tags for this chat conversation. Tags should be:
- Single words or short phrases (2-3 words max)
- Descriptive of the main topics, technologies, or themes
- Useful for categorization and search
- Lowercase with no special characters

Examples of good tags: "python", "debugging", "web development", "code review", "api design"

Conversation:
%s

Respond with only a comma-separated list of tags, nothing else.

Tags:]],
    conversation_context
  )

  SessionManager._make_llm_request(session_data, prompt, function(response)
    if response and response ~= '' then
      -- Parse the response into tags
      local tags = {}
      for tag in response:gmatch('[^,]+') do
        tag = vim.trim(tag):lower()
        if tag ~= '' and #tag <= 20 then -- Reasonable tag length limit
          table.insert(tags, tag)
        end
      end

      -- Limit to 5 tags maximum
      if #tags > 5 then
        tags = vim.list_slice(tags, 1, 5)
      end

      if callback then
        callback(tags)
      end
    else
      if callback then
        callback({})
      end
    end
  end)
end

-- Make LLM requests for tags and other operations (internal function)
---@param session_data table Session data for context
---@param prompt string Prompt to send to LLM
---@param callback function Callback to receive response
function SessionManager._make_llm_request(session_data, prompt, callback)
  local client_ok, client = pcall(require, 'codecompanion.http')
  local schema_ok, schema = pcall(require, 'codecompanion.schema')
  local adapters_ok, adapters = pcall(require, 'codecompanion.adapters')

  if not client_ok or not schema_ok or not adapters_ok then
    if callback then
      callback(nil)
    end
    return
  end

  local function resolve_adapter(value)
    if not value then
      return nil
    end
    if type(value) == 'table' then
      return value
    end
    return adapters.resolve(value)
  end

  local adapter = resolve_adapter(session_data.config and session_data.config.adapter)
  if not adapter then
    if callback then
      callback(nil)
    end
    return
  end

  local settings = session_data.config and vim.deepcopy(session_data.config) or {}
  settings = schema.get_default(adapter, settings)
  settings = vim.deepcopy(adapter:map_schema_to_params(settings))
  settings.opts = settings.opts or {}
  settings.opts.stream = false

  local payload = {
    messages = adapter:map_roles({
      { role = 'user', content = prompt },
    }),
  }

  client.new({ adapter = settings }):request(payload, {
    callback = function(err, data, _adapter)
      if err and err.stderr ~= '{}' then
        if callback then
          callback(nil)
        end
        return
      end

      if data and _adapter and _adapter.handlers and _adapter.handlers.chat_output then
        local result = _adapter.handlers.chat_output(_adapter, data)
        if result and result.status == 'success' then
          local response = vim.trim(result.output.content or '')
          if callback then
            callback(response)
          end
          return
        end
      end

      if callback then
        callback(nil)
      end
    end,
  }, {
    silent = true,
  })
end

return SessionManager
