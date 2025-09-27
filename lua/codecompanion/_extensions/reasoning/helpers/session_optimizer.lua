---@class CodeCompanion.SessionOptimizer
---Chat session compaction utility that summarizes conversations into single messages
local SessionOptimizer = {}

local fmt = string.format

local config_ok, ReasoningConfig = pcall(require, 'codecompanion._extensions.reasoning.config')
if not config_ok then
  ReasoningConfig = {
    merge_with_functionality = function(_, _, overrides)
      return vim.deepcopy(overrides or {})
    end,
    get_functionality_adapter = function()
      return nil
    end,
  }
end

---Configuration for session compaction
local DEFAULT_CONFIG = {
  adapter = nil, -- defaults to current chat adapter
  model = nil, -- defaults to current chat model
  min_messages_for_compaction = 5, -- minimum messages before compaction
  summary_max_words = 300, -- maximum words in generated summary
  include_code_snippets = true, -- preserve important code examples
  preserve_metadata = true, -- keep original session metadata
}

---Create new session optimizer instance
---@param opts? table Configuration options
---@return CodeCompanion.SessionOptimizer
function SessionOptimizer.new(opts)
  local self = setmetatable({}, { __index = SessionOptimizer })
  local merged_opts = ReasoningConfig.merge_with_functionality('session_optimizer', opts or {})
  local config = vim.tbl_deep_extend('force', {}, DEFAULT_CONFIG)
  if merged_opts and next(merged_opts) then
    config = vim.tbl_deep_extend('force', config, merged_opts)
  end
  self.config = config
  return self
end

---Compact a session by summarizing all messages into a single message
---@param session_data table Complete session data
---@param callback function Callback to receive compacted session
function SessionOptimizer:compact_session(session_data, callback)
  if not session_data.messages or #session_data.messages < self.config.min_messages_for_compaction then
    if callback then
      callback(session_data)
    end
    return
  end

  local relevant_messages = vim.tbl_filter(function(msg)
    local has_content = msg.content and vim.trim(msg.content) ~= ''
    local is_conversational = msg.role == 'user' or msg.role == 'assistant'
    local no_tool_calls = not msg.tool_calls and not msg.tool_call_id
    return has_content and is_conversational and no_tool_calls
  end, session_data.messages)

  if #relevant_messages == 0 then
    if callback then
      callback(session_data)
    end
    return
  end

  local conversation_lines = {}
  for _, message in ipairs(relevant_messages) do
    local role_prefix = message.role == 'user' and 'User' or 'Assistant'
    local content = vim.trim(message.content)

    if #content > 2000 then
      content = content:sub(1, 2000) .. ' [message truncated]'
    end

    table.insert(conversation_lines, role_prefix .. ': ' .. content)
  end

  local conversation_context = table.concat(conversation_lines, '\n\n')

  if #conversation_context > 20000 then
    conversation_context = conversation_context:sub(1, 20000) .. '\n\n[conversation truncated]'
  end

  local prompt_parts = {
    'Summarize this chat conversation into a concise overview that captures:',
    '• Main topics and themes discussed',
    '• Key decisions, conclusions, or agreements reached',
    '• Important facts, findings, or insights established',
    '• Current tasks, open questions, or next steps',
  }

  if self.config.include_code_snippets then
    table.insert(prompt_parts, '• Essential code examples, patterns, or technical details')
  end

  table.insert(prompt_parts, '')
  table.insert(
    prompt_parts,
    fmt(
      'Keep the summary under %d words and focus on information needed to continue this conversation productively.',
      self.config.summary_max_words
    )
  )
  table.insert(prompt_parts, '')
  table.insert(prompt_parts, 'Conversation:')
  table.insert(prompt_parts, conversation_context)
  table.insert(prompt_parts, '')
  table.insert(prompt_parts, 'Summary:')

  local prompt = table.concat(prompt_parts, '\n')

  self:_make_summarization_request(session_data, prompt, function(summary, error_msg)
    if not summary then
      if callback then
        callback(session_data, error_msg)
      end
      return
    end

    local compacted = vim.deepcopy(session_data)
    local original_count = #compacted.messages

    compacted.messages = {
      {
        role = 'assistant',
        content = fmt('**[Session Summary - %d messages compacted]**\n\n%s', original_count, summary),
        opts = {
          tag = 'session_summary',
          compacted_at = os.time(),
          compacted_date = os.date('%Y-%m-%d %H:%M:%S'),
          original_message_count = original_count,
        },
      },
    }

    if self.config.preserve_metadata then
      compacted.metadata = compacted.metadata or {}
      compacted.metadata.compaction = {
        original_message_count = original_count,
        compacted_message_count = 1,
        compacted_at = os.time(),
        compacted_date = os.date('%Y-%m-%d %H:%M:%S'),
        summary_word_count = #vim.split(summary, '%s+'),
      }

      compacted.metadata.token_estimate = math.floor(#tostring(summary) / 4)
    end

    if callback then
      callback(compacted)
    end
  end)
end

---Make adapter request for chat summarization
---@param session_data table Session data for adapter context
---@param prompt string Summarization prompt
---@param callback function Callback to receive summary
function SessionOptimizer:_make_summarization_request(session_data, prompt, callback)
  local client_ok, client = pcall(require, 'codecompanion.http')
  local schema_ok, schema = pcall(require, 'codecompanion.schema')

  if not client_ok or not schema_ok then
    if callback then
      callback(nil, 'CodeCompanion HTTP client not available')
    end
    return
  end

  local adapter = session_data.adapter
  local settings = session_data.settings
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

  adapter = resolve_adapter(adapter)
  local adapter_changed = false

  if self.config.adapter then
    local resolved = resolve_adapter(self.config.adapter)
    if not resolved then
      if callback then
        callback(nil, fmt('Failed to resolve adapter "%s" for summarization', tostring(self.config.adapter)))
      end
      return
    end
    adapter = resolved
    adapter_changed = true
    settings = nil
  elseif not adapter and session_data.opts and session_data.opts.adapter then
    local resolved = resolve_adapter(session_data.opts.adapter)
    if resolved then
      adapter = resolved
      adapter_changed = true
    end
  end

  if not adapter then
    if callback then
      callback(nil, 'No adapter available for summarization')
    end
    return
  end

  if self.config.model then
    settings = schema.get_default(adapter, { model = self.config.model })
  elseif adapter_changed or not settings then
    settings = schema.get_default(adapter, settings or {})
  end

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
        if callback then
          callback(nil, 'Error while generating summary: ' .. tostring(err.stderr))
        end
        return
      end

      if data and _adapter and _adapter.handlers and _adapter.handlers.chat_output then
        local result = _adapter.handlers.chat_output(_adapter, data)
        if result and result.status then
          if result.status == 'success' then
            local summary = vim.trim(result.output.content or '')
            if callback then
              callback(summary)
            end
            return
          elseif result.status == 'error' then
            if callback then
              callback(nil, 'Error while generating summary: ' .. tostring(result.output))
            end
            return
          end
        end
      end

      if callback then
        callback(nil, 'Failed to generate summary')
      end
    end,
  }, {
    silent = true,
  })
end

return SessionOptimizer
