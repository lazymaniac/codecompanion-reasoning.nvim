---@class CodeCompanion.SessionRestorer
---Session restoration logic for CodeCompanion chats
local SessionRestorer = {}

local fmt = string.format

---@param chat table|CodeCompanion.Chat|nil CodeCompanion chat object
local function prepare_existing_chat(chat, session_data)
  if not chat then
    return chat
  end

  chat:clear()
  chat.opts = chat.opts or {}
  chat:change_adapter(session_data.config.adapter, session_data.config.model)

  pcall(function()
    if chat.add_system_prompt then
      chat:add_system_prompt()
    end
  end)

  return chat
end

local function create_codecompanion_chat(session_data, existing_chat)
  local function normalize_role(role)
    if role == 'assistant' or role == 'llm' or role == 'model' then
      return 'llm'
    elseif role == 'function' then
      return 'tool'
    end
    return role
  end
  local config_ok, config = pcall(require, 'codecompanion.config')
  if not config_ok then
    return nil, 'CodeCompanion config not available'
  end

  if existing_chat then
    local prepared, err = prepare_existing_chat(existing_chat, session_data)
    if not prepared then
      return nil, err
    end
    return prepared, nil
  end

  local adapter_name = nil
  if session_data.config and session_data.config.adapter and session_data.config.adapter ~= 'unknown' then
    adapter_name = session_data.config.adapter
  end
  if not adapter_name then
    adapter_name = config.default_adapter
  end

  local success, chat_or_error = pcall(function()
    local Chat = require('codecompanion.strategies.chat')
    return Chat.new({
      adapter = adapter_name,
      auto_submit = false, -- Don't auto-submit, let user review first
      buffer_context = require('codecompanion.utils.context').get(vim.api.nvim_get_current_buf()),
      last_role = (function()
        local last = session_data.messages[#session_data.messages]
        return last and normalize_role(last.role) or 'user'
      end)(),
      settings = (function()
        local model = session_data.config and session_data.config.model
        if model and model ~= 'unknown' then
          return { model = model }
        end
        return nil
      end)(),
    })
  end)

  if not success then
    return nil, fmt('Failed to create CodeCompanion chat: %s', tostring(chat_or_error))
  end

  local chat = chat_or_error
  if not chat then
    return nil, 'Failed to create CodeCompanion chat'
  end

  if session_data.session_id then
    chat.id = session_data.session_id
  end

  chat._session_created_at = session_data.metadata and session_data.metadata.created_timestamp
    or session_data.timestamp
    or os.time()

  return chat, nil
end

-- Add tools to chat from session data
---@param chat table CodeCompanion chat object
---@param session_tools table Array of tool names
local function restore_chat_tools(chat, session_tools)
  local config_ok, config = pcall(require, 'codecompanion.config')
  if not config_ok then
    return
  end

  for _, tool_name in ipairs(session_tools or {}) do
    if not chat.tool_registry.in_use[tool_name] then
      local tool_config = config.strategies.chat.tools[tool_name]
      if tool_config then
        local prepared = vim.deepcopy(tool_config)
        local success, err = pcall(function()
          chat.tool_registry:add(tool_name, prepared, { visible = true })
        end)
        if not success then
          vim.notify(
            fmt('[SessionRestore] Failed to restore tool %s: %s', tool_name, tostring(err)),
            vim.log.levels.ERROR
          )
        end
      elseif config.strategies.chat.tools.groups and config.strategies.chat.tools.groups[tool_name] then
        local success, err = pcall(function()
          chat.tool_registry:add_group(tool_name, config.strategies.chat.tools)
        end)
        if not success then
          vim.notify(
            fmt('[SessionRestore] Failed to restore tool group %s: %s', tool_name, tostring(err)),
            vim.log.levels.ERROR
          )
        end
      else
        vim.notify(fmt('[SessionRestore] Tool not found in config: %s', tool_name), vim.log.levels.WARN)
      end
    end
  end
end

-- Message type handlers for clean restoration
local message_handlers = {}

-- Skip system messages as requested
message_handlers.system = function(chat, message, registry)
  -- System messages are omitted from restoration
end

-- Handle user messages
---@param chat table|CodeCompanion.Chat CodeCompanion chat object
message_handlers.user = function(chat, message, registry)
  chat:add_message(message)
  chat:add_buf_message(message)
end

-- Handle LLM messages with optional tool calls and reasoning
---@param chat table|CodeCompanion.Chat CodeCompanion chat object
message_handlers.llm = function(chat, message, registry)
  if message.reasoning then
    chat:add_buf_message({
      role = 'llm',
      content = message.reasoning.content,
    }, { type = chat.MESSAGE_TYPES.REASONING_MESSAGE })
  end

  -- Handle tool calls and register them
  if message.tool_calls then
    -- Register tool calls for later result linking
    for _, call in ipairs(message.tool_calls) do
      if call.id and call['function'] and call['function'].name then
        registry[call.id] = {
          name = call['function'].name,
          call = call,
        }
      end
    end
  end

  chat:add_message(message, { visible = true })

  if not message.reasoning then
    chat:add_buf_message(message)
  end
end

-- Handle tool results with proper linking
---@param chat table|CodeCompanion.Chat CodeCompanion chat object
message_handlers.tool = function(chat, message, registry)
  local tool_use_id = message.content.tool_use_id
  local content = message.content.content .. '\n'

  if tool_use_id and registry[tool_use_id] then
    local tool_obj = {}
    tool_obj.function_call = registry[tool_use_id].call

    pcall(function()
      chat:add_tool_output(tool_obj, content, content)
    end)
  else
    -- Tool result without proper call ID - fallback
    chat:add_message({
      role = 'tool',
      content = content,
    }, { visible = true })
  end
end

-- Handle assistant role (alias for llm)
message_handlers.assistant = function(chat, message, registry)
  message_handlers.llm(chat, message, registry)
end

-- Handle model role (alias for llm)
message_handlers.model = function(chat, message, registry)
  message_handlers.llm(chat, message, registry)
end

-- Add messages to chat using clean type-based handlers
---@param chat table|CodeCompanion.Chat|nil CodeCompanion chat object
---@param messages table Array of messages
local function restore_chat_messages(chat, messages)
  local tool_call_registry = {} -- Track tool calls for linking with results

  for _, message in ipairs(messages) do
    if message.role then
      local handler = message_handlers[message.role]
      if handler then
        pcall(function()
          handler(chat, message, tool_call_registry)
        end)
      else
        -- Unknown message type - log warning and skip
        vim.notify(fmt('[SessionRestore] Unknown message role: %s', tostring(message.role)), vim.log.levels.WARN)
      end
    end
  end
end

-- Sanitize message content for HTTP adapters
---@param chat table CodeCompanion chat object
local function sanitize_chat_messages(chat)
  pcall(function()
    if chat and chat.messages then
      for _, m in ipairs(chat.messages) do
        if m and m.content ~= nil and type(m.content) ~= 'string' then
          local ok, normalized = pcall(function()
            return m.content
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
end

-- Finalize chat for user interaction
---@param chat table|CodeCompanion.Chat|nil CodeCompanion chat object
local function finalize_chat_for_interaction(chat)
  local config_ok, config = pcall(require, 'codecompanion.config')
  if not config_ok then
    return
  end

  pcall(function()
    if chat and chat.tools_done then
      chat:tools_done({})
    else
      chat:add_buf_message({ role = config.constants.USER_ROLE, content = '' })
    end
  end)

  vim.schedule(function()
    vim.bo[chat.bufnr].modifiable = true

    local line_count = vim.api.nvim_buf_line_count(chat.bufnr)
    vim.api.nvim_win_set_cursor(0, { line_count, 0 })

    local util_ok, util = pcall(require, 'codecompanion.utils')
    if util_ok then
      util.fire('ChatCreated', { bufnr = chat.bufnr, from_prompt_library = false, id = chat.id })
    end
  end)
end

-- Restore session by creating a new CodeCompanion chat with history
---@param session_data table Loaded session data
---@param filename string Original session filename
---@return boolean success, string? error_message
function SessionRestorer.restore_session(session_data, filename, opts)
  opts = opts or {}
  if not session_data then
    return false, 'Invalid session data'
  end

  local existing_chat = opts.chat
  vim.notify('Existing chat: ' .. vim.inspect(existing_chat))
  local chat, err = create_codecompanion_chat(session_data, existing_chat)
  if not chat then
    return false, err
  end

  chat._session_filename = filename
  chat.opts = chat.opts or {}
  chat.opts.session_filename = filename

  restore_chat_tools(chat, session_data.tools)

  restore_chat_messages(chat, session_data.messages or {})

  sanitize_chat_messages(chat)

  finalize_chat_for_interaction(chat)

  vim.notify(fmt('Restored session: %s (%d messages)', filename, #(session_data.messages or {})), vim.log.levels.INFO)
  return true, chat
end

return SessionRestorer
