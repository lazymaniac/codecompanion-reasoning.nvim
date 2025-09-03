---@class CodeCompanion.SessionDataTransformer
---Data preparation and normalization for session management
local SessionDataTransformer = {}

local fmt = string.format

-- Generate unique save ID
---@return string save_id
function SessionDataTransformer.generate_save_id()
  return tostring(os.time() * 1000 + math.random(1000))
end

-- Extract tools that were used in the chat from tool_registry
---@param chat table CodeCompanion chat object
---@return table tools_used Array of tool names
function SessionDataTransformer.extract_used_tools(chat)
  local tools_used = {}

  if chat.tool_registry and chat.tool_registry.in_use then
    for tool_name, _ in pairs(chat.tool_registry.in_use) do
      tools_used[tool_name] = true
    end
  end

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

  local tools_array = {}
  for tool_name, _ in pairs(tools_used) do
    table.insert(tools_array, tool_name)
  end
  table.sort(tools_array)

  return tools_array
end

-- Get adapter model information
---@param chat table CodeCompanion chat object
---@return string model
function SessionDataTransformer.extract_model_info(chat)
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
end

-- Generate simple title from first user message
---@param messages table Array of messages
---@return string title
function SessionDataTransformer.generate_simple_title(messages)
  if not messages or #messages == 0 then
    return 'Empty Session'
  end

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

  local first_line = first_user_msg:match('^[^\n\r]*') or first_user_msg
  if #first_line > 50 then
    return first_line:sub(1, 47) .. '...'
  end

  return first_line
end

-- Prepare chat messages for storage (clean and serialize)
---@param chat table CodeCompanion chat object
---@return table cleaned_messages
function SessionDataTransformer.prepare_messages(chat)
  local cleaned_messages = {}

  if not chat.messages or #chat.messages == 0 then
    return cleaned_messages
  end

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
      table.insert(cleaned_messages, clean_message)
    end
  end

  return cleaned_messages
end

-- Calculate rough token estimate (4 chars = 1 token approximation)
---@param messages table Array of messages
---@return number token_estimate
function SessionDataTransformer.calculate_token_estimate(messages)
  local total_chars = 0
  for _, message in ipairs(messages) do
    if message.content then
      total_chars = total_chars + #tostring(message.content)
    end
  end
  return math.floor(total_chars / 4)
end

-- Prepare complete chat data for storage
---@param chat table CodeCompanion chat object
---@return table session_data
function SessionDataTransformer.prepare_chat_data(chat)
  local current_time = os.time()
  local created_time = chat._session_created_at or current_time
  local session_duration = current_time - created_time
  local cwd = vim.fn.getcwd()

  local cleaned_messages = SessionDataTransformer.prepare_messages(chat)
  local tools_used = SessionDataTransformer.extract_used_tools(chat)
  local model_info = SessionDataTransformer.extract_model_info(chat)
  local token_estimate = SessionDataTransformer.calculate_token_estimate(cleaned_messages)

  local session_data = {
    version = '2.0',
    save_id = chat.opts and chat.opts.save_id or SessionDataTransformer.generate_save_id(),
    title = chat.opts and chat.opts.title or nil,
    timestamp = current_time,
    created_at = os.date('%Y-%m-%d %H:%M:%S', created_time),
    updated_at = current_time,

    chat_id = chat.id or 'unknown',
    cwd = cwd,
    project_root = cwd,

    config = {
      adapter = (chat.adapter and (chat.adapter.name or chat.adapter.formatted_name)) or 'unknown',
      model = model_info,
    },

    -- Enhanced tracking
    tools = tools_used,
    cycle = chat.cycle or 1,
    messages = cleaned_messages,

    metadata = {
      total_messages = #cleaned_messages,
      last_activity = os.date('%Y-%m-%d %H:%M:%S'),
      session_duration = session_duration,
      created_timestamp = created_time,
      title_refresh_count = (chat.opts and chat.opts.title_refresh_count) or 0,
      token_estimate = token_estimate,
    },
  }

  return session_data
end

-- Get a brief preview of session content
---@param session_data table
---@return string preview
function SessionDataTransformer.get_session_preview(session_data)
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
    local first_line = first_user_message:match('^[^\n\r]*')
    if #first_line > 60 then
      return first_line:sub(1, 57) .. '...'
    end
    return first_line
  end

  return fmt('%d messages', #session_data.messages)
end

return SessionDataTransformer
