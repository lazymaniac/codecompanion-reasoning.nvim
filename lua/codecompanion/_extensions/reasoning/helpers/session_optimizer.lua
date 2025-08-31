---@class CodeCompanion.SessionOptimizer
---Session compaction and optimization utilities for chat history management
local SessionOptimizer = {}

local fmt = string.format

---Configuration for session optimization
local DEFAULT_CONFIG = {
  max_message_length = 2000,
  remove_duplicate_messages = true,
  remove_empty_messages = true,
  compact_tool_outputs = true,
  preserve_important_messages = true,
  max_consecutive_duplicates = 2,
}

---Create new session optimizer instance
---@param opts? table Configuration options
---@return CodeCompanion.SessionOptimizer
function SessionOptimizer.new(opts)
  local self = setmetatable({}, { __index = SessionOptimizer })
  self.config = vim.tbl_deep_extend('force', DEFAULT_CONFIG, opts or {})
  return self
end

---Check if two messages are considered duplicates
---@param msg1 table First message
---@param msg2 table Second message
---@return boolean is_duplicate
local function messages_are_duplicate(msg1, msg2)
  if not msg1 or not msg2 then
    return false
  end

  -- Same role and same content (ignoring timestamps and IDs)
  if msg1.role == msg2.role then
    local content1 = (msg1.content or ''):gsub('%s+', ' '):lower()
    local content2 = (msg2.content or ''):gsub('%s+', ' '):lower()
    return content1 == content2
  end

  return false
end

---Check if message is empty or meaningless
---@param message table Message to check
---@return boolean is_empty
local function is_empty_message(message)
  if not message or not message.content then
    return true
  end

  local content = vim.trim(message.content)
  if content == '' then
    return true
  end

  -- Check for very short or meaningless content
  if #content < 3 then
    return true
  end

  -- Common meaningless patterns
  local meaningless_patterns = {
    '^ok$',
    '^yes$',
    '^no$',
    '^%.$',
    '^%?$',
    '^thanks?$',
    '^thank you$',
    '^thx$',
  }

  local content_lower = content:lower()
  for _, pattern in ipairs(meaningless_patterns) do
    if content_lower:match(pattern) then
      return true
    end
  end

  return false
end

---Check if message is important and should be preserved
---@param message table Message to check
---@return boolean is_important
local function is_important_message(message)
  if not message or not message.content then
    return false
  end

  -- Tool calls and responses are usually important
  if message.tool_calls or message.tool_call_id then
    return true
  end

  -- Messages with specific metadata
  if message.opts and (message.opts.tag or message.opts.reference) then
    return true
  end

  -- Long messages are typically more important
  local content = message.content or ''
  if #content > 200 then
    return true
  end

  -- Messages containing code blocks
  if content:match('```') then
    return true
  end

  -- Messages with structured content (lists, etc.)
  if content:match('\n%s*[%-%*%+]%s') or content:match('\n%s*%d+%.%s') then
    return true
  end

  return false
end

---Truncate a message if it's too long while preserving important parts
---@param message table Message to truncate
---@param max_length number Maximum length
---@return table truncated_message
local function truncate_message(message, max_length)
  if not message.content or #message.content <= max_length then
    return message
  end

  local content = message.content

  -- Try to preserve code blocks
  local code_blocks = {}
  local code_pattern = '```[^`]*```'
  for block in content:gmatch(code_pattern) do
    table.insert(code_blocks, block)
  end

  -- If we have code blocks, try to keep them
  if #code_blocks > 0 then
    local total_code_length = 0
    for _, block in ipairs(code_blocks) do
      total_code_length = total_code_length + #block
    end

    -- If code blocks fit within limit, keep them and truncate around them
    if total_code_length <= max_length * 0.8 then
      local remaining = max_length - total_code_length - 50 -- buffer for truncation markers
      local non_code = content:gsub(code_pattern, '')
      if #non_code > remaining then
        non_code = non_code:sub(1, remaining) .. '\n[truncated]'
      end

      -- Reconstruct with code blocks (simplified)
      content = non_code .. '\n\n' .. table.concat(code_blocks, '\n\n')
    else
      -- Just truncate normally if code blocks are too large
      content = content:sub(1, max_length - 15) .. '\n[truncated]'
    end
  else
    -- No code blocks, just truncate
    content = content:sub(1, max_length - 15) .. '\n[truncated]'
  end

  local truncated = vim.deepcopy(message)
  truncated.content = content
  return truncated
end

---Remove duplicate consecutive messages
---@param messages table[] List of messages
---@param config table Configuration options
---@return table[] deduplicated_messages
function SessionOptimizer:remove_duplicate_messages(messages, config)
  if not config.remove_duplicate_messages or #messages <= 1 then
    return messages
  end

  local result = {}
  local consecutive_count = 0
  local last_message = nil

  for _, message in ipairs(messages) do
    local is_duplicate = messages_are_duplicate(message, last_message)

    if is_duplicate then
      consecutive_count = consecutive_count + 1
      -- Only keep up to max_consecutive_duplicates
      if consecutive_count <= config.max_consecutive_duplicates then
        table.insert(result, message)
      end
    else
      consecutive_count = 0
      table.insert(result, message)
    end

    last_message = message
  end

  return result
end

---Remove empty or meaningless messages
---@param messages table[] List of messages
---@param config table Configuration options
---@return table[] filtered_messages
function SessionOptimizer:remove_empty_messages(messages, config)
  if not config.remove_empty_messages then
    return messages
  end

  return vim.tbl_filter(function(message)
    -- Always preserve important messages
    if config.preserve_important_messages and is_important_message(message) then
      return true
    end

    return not is_empty_message(message)
  end, messages)
end

---Truncate overly long messages
---@param messages table[] List of messages
---@param config table Configuration options
---@return table[] truncated_messages
function SessionOptimizer:truncate_long_messages(messages, config)
  local result = {}

  for _, message in ipairs(messages) do
    if message.content and #message.content > config.max_message_length then
      table.insert(result, truncate_message(message, config.max_message_length))
    else
      table.insert(result, message)
    end
  end

  return result
end

---Compact tool output messages
---@param messages table[] List of messages
---@param config table Configuration options
---@return table[] compacted_messages
function SessionOptimizer:compact_tool_outputs(messages, config)
  if not config.compact_tool_outputs then
    return messages
  end

  local result = {}

  for _, message in ipairs(messages) do
    if message.role == 'tool' and message.content then
      local content = message.content

      -- Truncate very long tool outputs
      if #content > 1000 then
        -- Try to preserve important parts (errors, results)
        local lines = vim.split(content, '\n')
        local important_lines = {}
        local total_length = 0

        for _, line in ipairs(lines) do
          local line_lower = line:lower()
          -- Keep error messages, results, and short lines
          if line_lower:match('error') or line_lower:match('result') or line_lower:match('warning') or #line < 100 then
            table.insert(important_lines, line)
            total_length = total_length + #line
            if total_length > 800 then
              break
            end
          end
        end

        if #important_lines > 0 then
          content = table.concat(important_lines, '\n') .. '\n[tool output truncated]'
        else
          content = content:sub(1, 500) .. '\n[tool output truncated]'
        end

        local compacted = vim.deepcopy(message)
        compacted.content = content
        table.insert(result, compacted)
      else
        table.insert(result, message)
      end
    else
      table.insert(result, message)
    end
  end

  return result
end

---Optimize a complete session by applying all enabled optimizations
---@param session_data table Complete session data
---@return table optimized_session_data
function SessionOptimizer:optimize_session(session_data)
  if not session_data.messages or #session_data.messages == 0 then
    return session_data
  end

  local optimized = vim.deepcopy(session_data)
  local messages = optimized.messages
  local original_count = #messages

  -- Apply optimizations in order
  messages = self:remove_duplicate_messages(messages, self.config)
  messages = self:remove_empty_messages(messages, self.config)
  messages = self:truncate_long_messages(messages, self.config)
  messages = self:compact_tool_outputs(messages, self.config)

  -- Update session data
  optimized.messages = messages
  optimized.metadata = optimized.metadata or {}
  optimized.metadata.total_messages = #messages
  optimized.metadata.optimization = {
    original_message_count = original_count,
    optimized_message_count = #messages,
    messages_removed = original_count - #messages,
    optimized_at = os.time(),
    optimized_date = os.date('%Y-%m-%d %H:%M:%S'),
  }

  -- Recalculate token estimate
  local total_chars = 0
  for _, message in ipairs(messages) do
    if message.content then
      total_chars = total_chars + #tostring(message.content)
    end
  end
  optimized.metadata.token_estimate = math.floor(total_chars / 4)

  return optimized
end

---Get optimization statistics for a session
---@param session_data table Session data to analyze
---@return table stats Optimization statistics
function SessionOptimizer:analyze_session(session_data)
  if not session_data.messages then
    return {
      total_messages = 0,
      empty_messages = 0,
      duplicate_messages = 0,
      long_messages = 0,
      tool_messages = 0,
      optimization_potential = 'none',
    }
  end

  local messages = session_data.messages
  local stats = {
    total_messages = #messages,
    empty_messages = 0,
    duplicate_messages = 0,
    long_messages = 0,
    tool_messages = 0,
    very_long_messages = 0,
  }

  local last_message = nil
  for _, message in ipairs(messages) do
    if is_empty_message(message) then
      stats.empty_messages = stats.empty_messages + 1
    end

    if messages_are_duplicate(message, last_message) then
      stats.duplicate_messages = stats.duplicate_messages + 1
    end

    if message.content and #message.content > self.config.max_message_length then
      stats.long_messages = stats.long_messages + 1
    end

    if message.content and #message.content > self.config.max_message_length * 2 then
      stats.very_long_messages = stats.very_long_messages + 1
    end

    if message.role == 'tool' then
      stats.tool_messages = stats.tool_messages + 1
    end

    last_message = message
  end

  -- Determine optimization potential
  local removable = stats.empty_messages + stats.duplicate_messages
  local compactable = stats.long_messages + stats.tool_messages

  if removable > stats.total_messages * 0.2 or compactable > stats.total_messages * 0.3 then
    stats.optimization_potential = 'high'
  elseif removable > 0 or compactable > 0 then
    stats.optimization_potential = 'medium'
  else
    stats.optimization_potential = 'low'
  end

  return stats
end

return SessionOptimizer
