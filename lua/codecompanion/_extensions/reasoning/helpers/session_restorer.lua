---@class CodeCompanion.SessionRestorer
---Session restoration logic for CodeCompanion chats
local SessionRestorer = {}

local fmt = string.format
-- Access CodeCompanion config for roles and tool registry
local ok_cfg, config = pcall(require, 'codecompanion.config')
if not ok_cfg then
  config = { constants = { USER_ROLE = 'user', LLM_ROLE = 'assistant' }, strategies = { chat = { tools = {} } } }
end

-- Normalize content to string format
---@param content any
---@return string normalized
local function normalize_content(content)
  if type(content) == 'string' then
    return content
  elseif type(content) == 'table' then
    -- Try to extract concatenated text fields from arrays of parts
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

    local parts = flatten_table_parts(content)
    if #parts > 0 then
      return table.concat(parts, '\n')
    end
    return tostring(vim.inspect(content))
  else
    return tostring(content)
  end
end

-- Extract content from message with fallback options
---@param msg table Message object
---@return string content
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

-- Optimize session messages by removing duplicates
---@param session_data table
---@return table optimized_session
local function optimize_session_messages(session_data)
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
  return session_data
end

-- Create CodeCompanion chat instance
---@param session_data table
---@return table? chat, string? error_message
local function create_codecompanion_chat(session_data)
  local function normalize_role(role)
    if role == 'assistant' or role == 'llm' or role == 'model' then
      return 'llm'
    elseif role == 'function' then
      return 'tool'
    end
    return role
  end
  -- Try to access CodeCompanion and its config
  local config_ok, config = pcall(require, 'codecompanion.config')
  if not config_ok then
    return nil, 'CodeCompanion config not available'
  end

  -- Resolve adapter name from session config or use default
  local adapter_name = nil
  if session_data.config and session_data.config.adapter and session_data.config.adapter ~= 'unknown' then
    adapter_name = session_data.config.adapter
  end
  if not adapter_name then
    adapter_name = config.default_adapter
  end

  -- Create chat using CodeCompanion's Chat strategy
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

  -- Preserve the original session ID to maintain continuity
  if session_data.session_id then
    chat.id = session_data.session_id
  end

  -- Set session creation timestamp for duration tracking
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
        local success, err = pcall(function()
          chat.tool_registry:add(tool_name, tool_config, { visible = true })
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

-- Add messages to chat
---@param chat table CodeCompanion chat object
---@param messages table Array of messages
local function restore_chat_messages(chat, messages)
  local config_ok, config = pcall(require, 'codecompanion.config')
  if not config_ok then
    return
  end

  local tool_call_map = {}
  local last_tool_call = nil
  local added_reasoning = {}

  for _, message in ipairs(messages) do
    if message.role then
      -- Skip system messages only
      local is_system_prompt = message.role == 'system'

      if not is_system_prompt then
        -- Normalize roles to match CodeCompanion expectations
        local role = message.role
        if role == 'function' then
          role = 'tool'
          if not message.tool_call_id and message.id then
            message.tool_call_id = message.id
          end
          if not message.tool_name and message.name then
            message.tool_name = message.name
          end
        elseif role == 'assistant' or role == 'llm' or role == 'model' then
          role = 'llm'
        end

        -- Preserve the full message structure for proper CodeCompanion display
        local restored_message = vim.tbl_extend('keep', {
          role = role,
          content = extract_any_content(message),
        }, message)

        -- Handle tool calls
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

        -- Force visibility for normal conversation and tool outputs on restore
        if role == 'user' or role == 'llm' or role == 'tool' then
          restored_message.visible = true
          restored_message.opts = restored_message.opts or {}
          restored_message.opts.visible = true
        end

        -- Handle reasoning messages
        pcall(function()
          if
            restored_message.role == 'llm'
            and restored_message.reasoning
            and type(restored_message.reasoning) == 'table'
          then
            local rtext = normalize_content(restored_message.reasoning.content)
            local key = tostring(restored_message.id or '') .. ':' .. tostring(#rtext)
            if rtext and vim.trim(rtext) ~= '' and not added_reasoning[key] then
              added_reasoning[key] = true
              local mt = chat and chat.MESSAGE_TYPES or nil
              local opts = {}
              if mt and mt.REASONING_MESSAGE then
                opts.type = mt.REASONING_MESSAGE
              end
              chat:add_buf_message({ role = config.constants.LLM_ROLE, content = rtext }, opts)
            end
          end
        end)

        -- Handle special message content cases
        if
          restored_message.role == 'llm'
          and (not restored_message.content or restored_message.content == '')
          and restored_message.tool_calls
        then
          local parts = {}
          for _, call in ipairs(restored_message.tool_calls) do
            local fname = (call['function'] and call['function'].name) or 'tool'
            table.insert(parts, fmt('called %s', fname))
          end
          restored_message.content = table.concat(parts, '; ')
        end

        if restored_message.role == 'tool' and (not restored_message.content or restored_message.content == '') then
          local name = restored_message.tool_name or restored_message.name or 'tool'
          restored_message.content = fmt('[%s output]', name)
        end

        -- If this is a tool output without an id, associate it to the last assistant tool call
        if restored_message.role == 'tool' and not restored_message.tool_call_id and last_tool_call then
          restored_message.tool_call_id = last_tool_call.id
          restored_message.tool_name = restored_message.tool_name or last_tool_call.name
        end

        -- Add message to chat
        pcall(function()
          if restored_message.role == 'tool' then
            local out_text = extract_any_content(restored_message)
            local to_add = vim.tbl_extend('force', restored_message, { content = out_text })
            if restored_message.tool_call_id and chat.add_tool_output then
              -- Prefer strategy-aware rendering to preserve linkage; ensure UI visibility when supported
              local mapping = tool_call_map[restored_message.tool_call_id]
              local tool_name = (restored_message.tool_name or restored_message.name or (mapping and mapping.name))
              local tool_obj =
                { function_call = { id = restored_message.tool_call_id, name = tool_name or 'unknown_tool' } }
              pcall(function()
                chat:add_tool_output(tool_obj, out_text, out_text)
              end)
              -- Some implementations don't push to buffer; add UI assistant message only when types are available
              local mt = chat and chat.MESSAGE_TYPES or nil
              if mt and mt.TOOL_MESSAGE then
                chat:add_buf_message(
                  { role = config.constants.LLM_ROLE, content = out_text },
                  { type = mt.TOOL_MESSAGE }
                )
              end
            else
              -- Generic rendering for plain tool messages
              chat:add_message(to_add, { visible = true })
              local mt = chat and chat.MESSAGE_TYPES or nil
              local opts = {}
              if mt and mt.TOOL_MESSAGE then
                opts.type = mt.TOOL_MESSAGE
              end
              chat:add_buf_message({ role = config.constants.LLM_ROLE, content = out_text }, opts)
            end
          else
            -- Regular chat message
            chat:add_message(restored_message, { visible = true })
            -- Use explicit message type for UI rendering
            local mt = chat and chat.MESSAGE_TYPES or nil
            local ui_type = nil
            if mt then
              if restored_message.role == 'llm' then
                ui_type = mt.LLM_MESSAGE
              elseif restored_message.role == 'tool' then
                ui_type = mt.TOOL_MESSAGE
              end
            end
            chat:add_buf_message(restored_message, ui_type and { type = ui_type } or {})
          end
        end)
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
end

-- Finalize chat for user interaction
---@param chat table CodeCompanion chat object
local function finalize_chat_for_interaction(chat)
  local config_ok, config = pcall(require, 'codecompanion.config')
  if not config_ok then
    return
  end

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
end

-- Restore session by creating a new CodeCompanion chat with history
---@param session_data table Loaded session data
---@param filename string Original session filename
---@return boolean success, string? error_message
function SessionRestorer.restore_session(session_data, filename)
  if not session_data then
    return false, 'Invalid session data'
  end

  -- Optimize session messages
  session_data = optimize_session_messages(session_data)

  -- Create CodeCompanion chat
  local chat, err = create_codecompanion_chat(session_data)
  if not chat then
    return false, err
  end

  -- Preserve original session filename for subsequent saves
  chat._session_filename = filename
  chat.opts = chat.opts or {}
  chat.opts.session_filename = filename

  -- Restore tools
  restore_chat_tools(chat, session_data.tools)

  -- Restore messages
  restore_chat_messages(chat, session_data.messages or {})

  -- Sanitize messages for adapters
  sanitize_chat_messages(chat)

  -- Finalize for user interaction
  finalize_chat_for_interaction(chat)

  vim.notify(fmt('Restored session: %s (%d messages)', filename, #(session_data.messages or {})), vim.log.levels.INFO)
  return true, nil
end

return SessionRestorer
