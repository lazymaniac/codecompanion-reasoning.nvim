---@class CodeCompanion.TitleGenerator
---Advanced title generation for chat sessions using LLM adapters
local TitleGenerator = {}

local fmt = string.format

-- Configuration for title generation
local DEFAULT_CONFIG = {
  auto_generate_title = true,
  title_generation_opts = {
    adapter = nil, -- defaults to current chat adapter
    model = nil,   -- defaults to current chat model
    refresh_every_n_prompts = 0, -- 0 to disable
    max_refreshes = 3,
    format_title = nil, -- optional function to format generated titles
  }
}

---Create new title generator instance
---@param opts table Configuration options
---@return CodeCompanion.TitleGenerator
function TitleGenerator.new(opts)
  local self = setmetatable({}, { __index = TitleGenerator })
  self.opts = vim.tbl_deep_extend('force', DEFAULT_CONFIG, opts or {})
  return self
end

---Count user messages in chat (excluding tagged/reference messages)
---@param chat table CodeCompanion chat object
---@return number count Number of actual user messages
function TitleGenerator:_count_user_messages(chat)
  if not chat.messages or #chat.messages == 0 then
    return 0
  end

  local user_messages = vim.tbl_filter(function(msg)
    return msg.role == 'user'
  end, chat.messages)

  local actual_user_messages = vim.tbl_filter(function(msg)
    local has_content = msg.content and vim.trim(msg.content) ~= ''
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
function TitleGenerator:should_generate(chat)
  if not self.opts.auto_generate_title then
    return false, false
  end

  if not chat.opts or not chat.opts.title then
    return true, false
  end

  local refresh_opts = self.opts.title_generation_opts or {}
  if refresh_opts.refresh_every_n_prompts and refresh_opts.refresh_every_n_prompts > 0 then
    local user_message_count = self:_count_user_messages(chat)
    local refresh_count = (chat.opts.title_refresh_count) or 0
    local max_refreshes = refresh_opts.max_refreshes or 3

    if
      user_message_count > 0
      and user_message_count % refresh_opts.refresh_every_n_prompts == 0
      and refresh_count < max_refreshes
    then
      return true, true
    end
  end

  return false, false
end

---Generate title for chat session
---@param chat table CodeCompanion chat object
---@param callback function Callback function to receive generated title
---@param is_refresh? boolean Whether this is a title refresh
function TitleGenerator:generate(chat, callback, is_refresh)
  if not self.opts.auto_generate_title then
    if callback then callback(nil) end
    return
  end

  is_refresh = is_refresh or false

  -- Early return for disabled auto-generation, but allow refresh if explicitly requested
  if not is_refresh and chat.opts and chat.opts.title then
    if callback then callback(chat.opts.title) end
    return
  end

  -- Return early if no messages or messages is nil
  if not chat.messages or #chat.messages == 0 then
    if callback then callback(nil) end
    return
  end

  -- Filter relevant messages (both user and assistant, excluding tagged/reference messages)
  local relevant_messages = vim.tbl_filter(function(msg)
    -- Include user and assistant messages with actual content
    local has_content = msg.content and vim.trim(msg.content) ~= ''
    local is_relevant_role = msg.role == 'user' or msg.role == 'assistant'
    local not_tagged = not (msg.opts and (msg.opts.tag or msg.opts.reference or msg.opts.context_id))
    return has_content and is_relevant_role and not_tagged
  end, chat.messages)

  if #relevant_messages == 0 then
    if callback then callback(nil) end
    return
  end

  -- Show appropriate feedback only after validation
  if callback then
    if is_refresh then
      callback('Refreshing title...')
    else
      callback('Generating title...')
    end
  end

  -- Extract conversation content based on whether this is a refresh or initial generation
  local conversation_context = ''

  if is_refresh then
    -- For refreshes, use recent conversation (last 6 messages or all if fewer)
    local recent_count = math.min(6, #relevant_messages)
    local start_index = math.max(1, #relevant_messages - recent_count + 1)
    local recent_messages = {}

    for i = start_index, #relevant_messages do
      local msg = relevant_messages[i]
      local role_prefix = msg.role == 'user' and 'User' or 'Assistant'
      local content = vim.trim(msg.content)

      -- Truncate individual message if too long
      if #content > 1000 then
        content = content:sub(1, 1000) .. ' [truncated]'
      end

      table.insert(recent_messages, role_prefix .. ': ' .. content)
    end

    conversation_context = table.concat(recent_messages, '\n')
  else
    -- For initial generation, use the first user message
    local first_user_msg = nil
    for _, msg in ipairs(relevant_messages) do
      if msg.role == 'user' then
        first_user_msg = msg
        break
      end
    end

    if not first_user_msg then
      if callback then callback(nil) end
      return
    end

    local content = vim.trim(first_user_msg.content)

    -- Truncate individual message if too long
    if #content > 1000 then
      content = content:sub(1, 1000) .. ' [truncated]'
    end

    conversation_context = 'User: ' .. content
  end

  -- Truncate total content if too long
  if #conversation_context > 10000 then
    conversation_context = conversation_context:sub(1, 10000) .. '\n[conversation truncated]'
  end

  -- Create prompt for title generation
  local prompt
  if is_refresh then
    local original_title = (chat.opts and chat.opts.title) or 'Unknown'
    prompt = fmt([[The conversation has evolved since the original title was generated. Based on the recent conversation below, generate a new concise title (max 5 words) that better reflects the current topic.

Original title: "%s"

Recent conversation:
%s

Generate a new title that captures the main topic of the recent conversation. Do not include any special characters or quotes. Your response should contain only the new title.

New Title:]], original_title, conversation_context)
  else
    prompt = fmt([[Generate a very short and concise title (max 5 words) for this chat based on the following conversation:
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
Title:]], conversation_context)
  end

  self:_make_adapter_request(chat, prompt, callback)
end

---Make adapter request for title generation
---@param chat table CodeCompanion chat object
---@param prompt string Title generation prompt
---@param callback function Callback to receive title
function TitleGenerator:_make_adapter_request(chat, prompt, callback)
  -- Try to use CodeCompanion's http client for consistency
  local client_ok, client = pcall(require, 'codecompanion.http')
  local schema_ok, schema = pcall(require, 'codecompanion.schema')
  
  if not client_ok or not schema_ok then
    -- Fallback: use simple title generation if CodeCompanion internals not available
    local fallback_title = self:_generate_fallback_title(chat)
    if callback then callback(fallback_title) end
    return
  end

  local opts = self.opts.title_generation_opts or {}
  local adapter = vim.deepcopy(chat.adapter)
  local settings = vim.deepcopy(chat.settings)
  
  if opts.adapter then
    local adapters_ok, adapters = pcall(require, 'codecompanion.adapters')
    if adapters_ok and adapters.resolve then
      adapter = adapters.resolve(opts.adapter)
    end
  end
  
  if opts.model then
    settings = schema.get_default(adapter, { model = opts.model })
  end
  
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
        if callback then callback(fallback_title) end
        return
      end
      
      if data and _adapter and _adapter.handlers and _adapter.handlers.chat_output then
        local result = _adapter.handlers.chat_output(_adapter, data)
        if result and result.status then
          if result.status == 'success' then
            local title = vim.trim(result.output.content or '')
            -- Apply format_title function if provided
            if self.opts.title_generation_opts.format_title then
              title = self.opts.title_generation_opts.format_title(title)
            end
            if callback then callback(title) end
            return
          elseif result.status == 'error' then
            vim.notify('Error while generating title: ' .. tostring(result.output), vim.log.levels.WARN)
          end
        end
      end
      
      -- Fallback on any error
      local fallback_title = self:_generate_fallback_title(chat)
      if callback then callback(fallback_title) end
    end,
  }, {
    silent = true,
  })
end

---Generate fallback title when API calls fail
---@param chat table CodeCompanion chat object
---@return string title Fallback title
function TitleGenerator:_generate_fallback_title(chat)
  if not chat.messages or #chat.messages == 0 then
    return 'Empty Session'
  end
  
  -- Find first user message
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
  
  -- Extract first line and truncate
  local first_line = first_user_msg:match('^[^\n\r]*') or first_user_msg
  if #first_line > 45 then
    return first_line:sub(1, 42) .. '...'
  end
  
  return first_line
end

---Update configuration
---@param new_config table New configuration options
function TitleGenerator:setup(new_config)
  if new_config then
    self.opts = vim.tbl_deep_extend('force', self.opts, new_config)
  end
end

return TitleGenerator