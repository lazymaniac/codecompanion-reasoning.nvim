---@class CodeCompanion.SessionOptimizer
---Chat session compaction utility that summarizes conversations into single messages
local SessionOptimizer = {}

local fmt = string.format
local config = require('codecompanion._extensions.reasoning.config')

---Create new session optimizer instance
---@return CodeCompanion.SessionOptimizer
function SessionOptimizer.new()
  local self = setmetatable({}, { __index = SessionOptimizer })
  return self
end

---Compact a session by summarizing all messages into a single message
---@param session_data table Complete session data
---@param callback function Callback to receive compacted session
function SessionOptimizer:compact_session(session_data, callback)
  if not session_data.messages then
    if callback then
      callback(session_data)
    end
    return
  end

  local relevant_messages = vim.tbl_filter(function(msg)
    local normalized_content = msg.content or ''
    -- Handle case where content might be a table
    if type(normalized_content) == 'table' then
      normalized_content = vim.inspect(normalized_content)
    end
    local has_content = vim.trim(normalized_content) ~= ''
    return has_content
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
    local content = message.content or ''
    -- Handle case where content might be a table
    if type(content) == 'table' then
      content = vim.inspect(content)
    end
    content = vim.trim(content)

    -- Pass full content without any truncation
    table.insert(conversation_lines, role_prefix .. ': ' .. content)
  end

  local conversation_context = table.concat(conversation_lines, '\n\n')

  local prompt_parts = {
    'You are an AI conversation summarizer specializing in preserving context for seamless conversation continuation.',
    '',
    'TASK: Create a comprehensive yet concise summary that allows another AI to continue this conversation as if no interruption occurred.',
    '',
    'REQUIRED OUTPUT STRUCTURE:',
    '## Context Overview',
    '- Domain/technology being discussed',
    '- Current project or task scope',
    "- User's apparent skill level and preferences",
    '',
    '## Technical State',
    '- Active files, functions, or components mentioned',
    '- Current implementation approach or architecture',
    '- Tools, libraries, or frameworks in use',
    '- Code patterns or standards established',
    '',
    '## Workflow Progress',
    '- Completed tasks or resolved issues',
    '- Current objective or goal',
    '- Next planned steps or pending actions',
    '- Open questions or unresolved items',
    '',
    '## Key Decisions & Insights',
    '- Important choices made and rationale',
    '- Established constraints or requirements',
    '- Lessons learned or gotchas discovered',
    '- Performance or design considerations',
    '',
    '## Conversation Dynamics',
    "- User's communication style and preferences",
    '- Specific terminology or conventions used',
    '- Level of explanation typically provided',
    '- Any recurring themes or concerns',
    '',
    'INSTRUCTIONS:',
    '- Write in a clear, structured format using the sections above',
    '- Focus on information needed to continue the conversation productively',
    '- Include specific technical details, file names, and code concepts',
    "- Preserve the user's mental model and current understanding",
    '- Keep technical context precise but avoid excessive code reproduction',
  }

  local max_words = config.get().session_optimizer.summary_max_words
  table.insert(
    prompt_parts,
    fmt(
      '- Target %d words, but prioritize completeness over strict limits - use more words if necessary for continuity',
      max_words
    )
  )

  table.insert(prompt_parts, '')
  table.insert(prompt_parts, 'CONVERSATION TO SUMMARIZE:')
  table.insert(prompt_parts, conversation_context)
  table.insert(prompt_parts, '')
  table.insert(prompt_parts, 'STRUCTURED SUMMARY:')

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
        role = 'user',
        content = fmt('**[Session Summary - %d messages compacted]**', original_count),
      },
      {
        role = 'llm',
        content = summary,
        opts = {
          tag = 'session_summary',
          compacted_at = os.time(),
          compacted_date = os.date('%Y-%m-%d %H:%M:%S'),
          original_message_count = original_count,
        },
      },
    }

    compacted.metadata = compacted.metadata or {}
    compacted.metadata.compaction = {
      original_message_count = original_count,
      compacted_message_count = 1,
      compacted_at = os.time(),
      compacted_date = os.date('%Y-%m-%d %H:%M:%S'),
      summary_word_count = #vim.split(summary, '%s+'),
    }

    compacted.metadata.token_estimate = math.floor(#summary / 4)

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

  local settings = session_data.settings
  local adapters_ok, adapters = pcall(require, 'codecompanion.adapters')

  local function resolve_adapter(value)
    if not value or value == 'unknown' then
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

  local adapter
  local adapter_changed = false

  if config.get().session_optimizer.adapter then
    local resolved = resolve_adapter(config.get().session_optimizer.adapter)
    if not resolved then
      if callback then
        callback(
          nil,
          fmt('Failed to resolve adapter "%s" for summarization', tostring(config.get().session_optimizer.adapter))
        )
      end
      return
    end
    adapter = resolved
    adapter_changed = true
    settings = nil
  else
    local candidates = {
      { value = session_data.adapter, source = 'session_data.adapter' },
      { value = session_data.config and session_data.config.adapter, source = 'session_data.config' },
      { value = session_data.opts and session_data.opts.adapter, source = 'session_data.opts' },
    }

    for _, candidate in ipairs(candidates) do
      local resolved = resolve_adapter(candidate.value)
      if resolved then
        adapter = resolved
        adapter_changed = candidate.source ~= 'session_data.adapter'
        break
      end
    end
  end

  if not adapter then
    if callback then
      callback(nil, 'No adapter available for summarization')
    end
    return
  end

  if not settings and session_data.config then
    settings = vim.deepcopy(session_data.config)
  end

  if config.get().session_optimizer.model then
    settings = schema.get_default(adapter, { model = config.get().session_optimizer.model })
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
