---@class CodeCompanion.SessionTitleGenerator
---Advanced title generation for chat sessions using LLM adapters
local SessionTitleGenerator = {}

local fmt = string.format
local config = require('codecompanion._extensions.reasoning.config')

---Create new title generator instance
---@return CodeCompanion.SessionTitleGenerator
function SessionTitleGenerator.new()
  local self = setmetatable({}, { __index = SessionTitleGenerator })
  return self
end

---Count user messages in chat (excluding tagged/reference messages)
---@param chat table CodeCompanion chat object
---@return number count Number of actual user messages
function SessionTitleGenerator:_count_user_messages(chat)
  if not chat.messages or #chat.messages == 0 then
    return 0
  end

  local user_messages = vim.tbl_filter(function(msg)
    return msg.role == 'user'
  end, chat.messages)

  local actual_user_messages = vim.tbl_filter(function(msg)
    local has_content = msg.content and type(msg.content) == 'string' and vim.trim(msg.content) ~= ''
    return has_content
      and not (msg.opts and msg.opts.tag)
      and not (msg.opts and (msg.opts.reference or msg.opts.context_id))
  end, user_messages)

  return #actual_user_messages
end

---Check if title should be generated or refreshed
---@param chat table CodeCompanion chat object
---@return boolean should_generate
---@return boolean is_refresh
function SessionTitleGenerator:should_generate(chat)
  if not config.get().session_history.auto_generate_title then
    return false, false
  end

  local user_message_count = self:_count_user_messages(chat)
  local applied = (chat.opts and chat.opts._title_generated_counts) or {}

  local refresh_opts = config.get().session_title_generator or {}
  local n = refresh_opts.refresh_every_n_prompts or 3
  if type(n) ~= 'number' or n <= 0 then
    n = 3
  end

  if user_message_count >= 1 then
    local should_at_this_count = ((user_message_count - 1) % n) == 0
    if should_at_this_count and not applied[user_message_count] then
      local is_refresh = chat.opts and chat.opts.title and true or false
      return true, is_refresh
    end
  end

  return false, false
end

---Generate title for chat session
---@param chat table CodeCompanion chat object
---@param callback function Callback function to receive generated title
function SessionTitleGenerator:generate(chat, callback)
  if not config.get().session_history.auto_generate_title then
    if callback then
      callback(nil)
    end
    return
  end

  if not chat.messages or #chat.messages == 0 then
    if callback then
      callback(nil)
    end
    return
  end

  local relevant_messages = vim.tbl_filter(function(msg)
    local has_content = msg.content and vim.trim(vim.inspect(msg.content)) ~= ''
    local not_system_role = msg.role ~= 'system'
    return has_content and not_system_role
  end, chat.messages)

  if #relevant_messages == 0 then
    vim.notify('No relevant messages')
    if callback then
      callback(nil)
    end
    return
  end

  local conversation_context = ''

  local first_msg = relevant_messages[1]

  if not first_msg then
    if callback then
      callback(nil)
    end
    return
  end

  local content = type(first_msg.content) == 'string' and vim.trim(first_msg.content)
    or vim.trim(vim.inspect(first_msg.content))

  if #content > 1000 then
    content = content:sub(1, 1000) .. ' [truncated]'
  end

  conversation_context = 'Content: ' .. content

  if #conversation_context > 10000 then
    conversation_context = conversation_context:sub(1, 10000) .. '\n[conversation truncated]'
  end

  local prompt = fmt(
    [[Generate a very short and concise title (max 5 words) for this chat based on the following conversation:
Do not include any special characters or quotes. Your response shouldn't contain any other text, just the title.

===
Examples:
1. User: What is the capital of France?
   Title: Capital of France
2. User: How do I create a new file in Vim?
   Title: Vim File Creation
===

Conversation:
%s
Title:]],
    conversation_context
  )

  self:_make_adapter_request(chat, prompt, callback)
end

---Make adapter request for title generation
---@param chat table CodeCompanion chat object
---@param prompt string Title generation prompt
---@param callback function Callback to receive title
function SessionTitleGenerator:_make_adapter_request(chat, prompt, callback)
  local client_ok, client = pcall(require, 'codecompanion.http')
  local schema_ok, schema = pcall(require, 'codecompanion.schema')

  if not client_ok or not schema_ok then
    local fallback_title = self:_generate_fallback_title(chat)
    if callback then
      callback(fallback_title)
    end
    return
  end

  local generator_opts = config.get().session_title_generator or {}

  local adapters_ok, adapters = pcall(require, 'codecompanion.adapters')

  local function resolve_adapter(value)
    if not value then
      return nil
    end
    if type(value) == 'table' then
      return value
    end
    if adapters_ok and adapters.resolve then
      return adapters.resolve(value)
    end
    return nil
  end

  local adapter = resolve_adapter(config.get().session_title_generator.adapter)
    or resolve_adapter(chat.adapter)
    or (chat.opts and resolve_adapter(chat.opts.adapter))

  if not adapter then
    local fallback_title = self:_generate_fallback_title(chat)
    if callback then
      callback(fallback_title)
    end
    return
  end

  local settings = chat.settings and vim.deepcopy(chat.settings) or {}
  local chosen_model = config.get().session_title_generator.model or settings.model
  local desired = {}
  if chosen_model then
    desired.model = chosen_model
  end
  settings = schema.get_default(adapter, desired)
  settings = settings or {}
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
        vim.notify('Error while generating title: ' .. tostring(err.stderr), vim.log.levels.WARN)
        local fallback_title = self:_generate_fallback_title(chat)
        if callback then
          callback(fallback_title)
        end
        return
      end

      if data and _adapter and _adapter.handlers and _adapter.handlers.chat_output then
        local result = _adapter.handlers.chat_output(_adapter, data)
        if result and result.status then
          if result.status == 'success' then
            local title = vim.trim(result.output.content or '')
            -- Apply format_title function if provided
            if generator_opts.format_title then
              title = generator_opts.format_title(title)
            end
            if callback then
              callback(title)
            end
            return
          elseif result.status == 'error' then
            vim.notify('Error while generating title: ' .. tostring(result.output), vim.log.levels.WARN)
          end
        end
      end

      local fallback_title = self:_generate_fallback_title(chat)
      if callback then
        callback(fallback_title)
      end
    end,
  }, {
    silent = true,
  })
end

---Generate fallback title when API calls fail
---@param chat table CodeCompanion chat object
---@return string title Fallback title
function SessionTitleGenerator:_generate_fallback_title(chat)
  if not chat.messages or #chat.messages == 0 then
    return 'Empty Session'
  end

  local first_user_msg = nil
  for _, message in ipairs(chat.messages) do
    if message.role == 'user' and message.content then
      first_user_msg = message.content
      break
    end
  end

  if not first_user_msg then
    return 'No User Input'
  end

  local first_line = first_user_msg:match('^[^\n\r]*') or first_user_msg
  if #first_line > 45 then
    return first_line:sub(1, 42) .. '...'
  end

  return first_line
end

---Update configuration
function SessionTitleGenerator:setup() end

return SessionTitleGenerator
