---@class CodeCompanion.ChatHooks
---Hooks for integrating session management with CodeCompanion chat lifecycle
local ChatHooks = {}

local SessionManager = require('codecompanion._extensions.reasoning.helpers.session_manager')

-- Track active chats and their auto-save status
local active_chats = {}
local auto_save_enabled = true

-- Forward declarations
local get_codecompanion_chat
local extract_chat_from_codecompanion_buffer

-- Hook into CodeCompanion's native event system
local function setup_codecompanion_hooks()
  -- Try to hook into CodeCompanion's events if available
  local config_ok, config = pcall(require, 'codecompanion.config')
  if not config_ok then
    return false
  end

  local group = vim.api.nvim_create_augroup('CodeCompanionReasoningHooks', { clear = true })

  -- Hook into chat events for auto-saving
  vim.api.nvim_create_autocmd('User', {
    pattern = { 'CodeCompanionChatDone', 'CodeCompanionChatSubmitted' },
    group = group,
    callback = function(event)
      if not auto_save_enabled then
        return
      end

      local event_data = event.data
      if event_data and event_data.bufnr and event_data.id then
        local chat_id = tostring(event_data.id)
        local buf = event_data.bufnr

        -- Debounce auto-save to avoid excessive writes
        if active_chats[chat_id] then
          vim.fn.timer_stop(active_chats[chat_id].timer)
        end

        active_chats[chat_id] = {
          chat_id = chat_id,
          buf = buf,
          timer = vim.fn.timer_start(2000, function() -- 2 second delay
            -- Wrap in pcall for safety
            local success, err = pcall(function()
              -- Try to get the actual chat object first
              local chat_obj = get_codecompanion_chat(chat_id, buf)
              if chat_obj then
                SessionManager.auto_save_session(chat_obj)
              else
                -- Fallback to buffer parsing
                local chat_data = extract_chat_from_codecompanion_buffer(buf, chat_id)
                if chat_data then
                  SessionManager.auto_save_session(chat_data)
                end
              end
            end)

            if not success then
              -- Silently ignore errors during auto-save to avoid disrupting user experience
              -- vim.notify('[CodeCompanion Reasoning] Auto-save error: ' .. tostring(err), vim.log.levels.DEBUG)
            end
          end),
        }
      end
    end,
  })

  -- Hook into chat close events to do final save
  vim.api.nvim_create_autocmd('User', {
    pattern = 'CodeCompanionChatClosed',
    group = group,
    callback = function(event)
      if not auto_save_enabled then
        return
      end

      local event_data = event.data
      if event_data and event_data.bufnr and event_data.id then
        local chat_id = tostring(event_data.id)
        local buf = event_data.bufnr

        -- Stop any pending timer
        if active_chats[chat_id] then
          vim.fn.timer_stop(active_chats[chat_id].timer)
          active_chats[chat_id] = nil
        end

        -- Do final save before closing (with error handling)
        local success, err = pcall(function()
          local chat_obj = get_codecompanion_chat(chat_id, buf)
          if chat_obj then
            SessionManager.auto_save_session(chat_obj)
          else
            local chat_data = extract_chat_from_codecompanion_buffer(buf, chat_id)
            if chat_data then
              SessionManager.auto_save_session(chat_data)
            end
          end
        end)

        if not success then
          -- Silently ignore errors during final save
          -- vim.notify('[CodeCompanion Reasoning] Final save error: ' .. tostring(err), vim.log.levels.DEBUG)
        end
      end
    end,
  })

  return true
end

-- Try to get the actual CodeCompanion chat object
---@param chat_id string Chat identifier
---@param buf number Buffer handle
---@return table|nil chat_object
get_codecompanion_chat = function(chat_id, buf)
  -- Validate inputs
  if not buf or not vim.api.nvim_buf_is_valid(buf) then
    return nil
  end

  -- Try to access CodeCompanion's internal chat storage
  local ok, codecompanion = pcall(require, 'codecompanion')
  if not ok then
    return nil
  end

  -- Try multiple approaches to get the chat object
  local chat = nil

  -- Method 1: Use buf_get_chat if available (with error handling)
  if codecompanion.buf_get_chat then
    local buf_ok, result = pcall(codecompanion.buf_get_chat, buf)
    if buf_ok and result and tostring(result.id) == tostring(chat_id) then
      return result
    end
  end

  -- Method 2: Try to find chat through buffer variables
  local chat_var_patterns = {
    'codecompanion_chat_' .. chat_id,
    'codecompanion_chat',
    'chat',
  }

  for _, pattern in ipairs(chat_var_patterns) do
    if vim.b[buf][pattern] then
      local potential_chat = vim.b[buf][pattern]
      if potential_chat and (not chat_id or tostring(potential_chat.id) == tostring(chat_id)) then
        return potential_chat
      end
    end
  end

  -- Method 3: Check global CodeCompanion state
  if codecompanion.active_chats and codecompanion.active_chats[buf] then
    return codecompanion.active_chats[buf]
  end

  -- Method 4: Try window-local variables
  local win = vim.fn.bufwinid(buf)
  if win ~= -1 then
    local win_chat = vim.w[win].codecompanion_chat
    if win_chat and (not chat_id or tostring(win_chat.id) == tostring(chat_id)) then
      return win_chat
    end
  end

  return nil
end

-- Extract chat data from a CodeCompanion buffer using improved parsing
---@param buf number Buffer handle
---@param chat_id string Chat identifier
---@return table|nil chat_data
extract_chat_from_codecompanion_buffer = function(buf, chat_id)
  -- Validate buffer
  if not buf or not vim.api.nvim_buf_is_valid(buf) then
    return nil
  end

  -- Safely get buffer content
  local ok, lines = pcall(vim.api.nvim_buf_get_lines, buf, 0, -1, false)
  if not ok or not lines then
    return nil
  end

  local content = table.concat(lines, '\n')
  if content == '' then
    return nil
  end

  -- Parse messages from buffer content
  local messages = {}
  local current_role = nil
  local current_content = {}

  for i, line in ipairs(lines) do
    -- Detect CodeCompanion role markers with comprehensive patterns
    local role = line:match('^## (User|Assistant)$')
      or line:match('^# (user|assistant)$')
      or line:match('^# (User|Assistant)$')
      or line:match('^%s*%*%*User:%*%*') -- **User:**
      or line:match('^%s*%*%*Assistant:%*%*') -- **Assistant:**
      or line:match('^User:') -- User:
      or line:match('^Assistant:') -- Assistant:
      or line:match('^> User') -- > User
      or line:match('^> Assistant') -- > Assistant
      -- Flexible pattern matching
      or (line:match('^%s*[#>%*]*%s*[Uu]set%s*[:>%*]*%s*$') and 'User')
      or (line:match('^%s*[#>%*]*%s*[Aa]ssistant%s*[:>%*]*%s*$') and 'Assistant')

    if role then
      -- Save previous message
      if current_role and #current_content > 0 then
        local content_text = table.concat(current_content, '\n')
        content_text = content_text:gsub('^%s+', ''):gsub('%s+$', '')
        if content_text ~= '' then
          table.insert(messages, {
            role = current_role:lower(),
            content = content_text,
            timestamp = os.time(),
          })
        end
      end

      -- Determine role from the marker
      if role:lower():find('user') then
        current_role = 'user'
      elseif role:lower():find('assistant') then
        current_role = 'assistant'
      else
        current_role = role:lower()
      end
      current_content = {}
    elseif current_role then
      -- Skip empty lines at the start of a message
      if #current_content > 0 or line:match('%S') then
        table.insert(current_content, line)
      end
    end
  end

  -- Save final message
  if current_role and #current_content > 0 then
    table.insert(messages, {
      role = current_role:lower(),
      content = table.concat(current_content, '\n'):gsub('^%s+', ''):gsub('%s+$', ''),
      timestamp = os.time(),
    })
  end

  if #messages == 0 then
    return nil
  end

  return {
    id = chat_id,
    model = 'unknown', -- Would need to detect from CodeCompanion
    adapter = { name = 'unknown' },
    messages = messages,
    tools = {},
  }
end

-- Enable auto-save functionality
function ChatHooks.enable_auto_save()
  auto_save_enabled = true
  SessionManager.setup({ auto_save = true })
  return setup_codecompanion_hooks()
end

-- Disable auto-save functionality
function ChatHooks.disable_auto_save()
  auto_save_enabled = false
  SessionManager.setup({ auto_save = false })

  -- Stop all active timers
  for chat_id, chat_data in pairs(active_chats) do
    if chat_data.timer then
      vim.fn.timer_stop(chat_data.timer)
    end
  end
  active_chats = {}
end

-- Manual hook for when a chat gets a new message
---@param chat table CodeCompanion chat instance
function ChatHooks.on_chat_message(chat)
  if auto_save_enabled and chat then
    local ok, err = pcall(SessionManager.auto_save_session, chat)
    if not ok then
      -- Silently handle errors to avoid disrupting chat flow
      -- vim.notify('[CodeCompanion Reasoning] Manual save error: ' .. tostring(err), vim.log.levels.DEBUG)
    end
  end
end

-- Hook for when a chat is closed
---@param chat table CodeCompanion chat instance
function ChatHooks.on_chat_close(chat)
  if chat and chat.id and active_chats[chat.id] then
    -- Stop the timer
    if active_chats[chat.id].timer then
      vim.fn.timer_stop(active_chats[chat.id].timer)
    end
    active_chats[chat.id] = nil

    -- Do a final save
    if auto_save_enabled then
      local ok, err = pcall(SessionManager.auto_save_session, chat)
      if not ok then
        -- Silently handle errors to avoid disrupting chat close
        -- vim.notify('[CodeCompanion Reasoning] Close save error: ' .. tostring(err), vim.log.levels.DEBUG)
      end
    end
  end
end

-- Initialize hooks
function ChatHooks.setup(opts)
  opts = opts or {}
  auto_save_enabled = opts.auto_save ~= false -- Default to true

  if auto_save_enabled then
    setup_codecompanion_hooks()
  end
end

-- Check if auto-save is enabled
function ChatHooks.is_auto_save_enabled()
  return auto_save_enabled
end

return ChatHooks
