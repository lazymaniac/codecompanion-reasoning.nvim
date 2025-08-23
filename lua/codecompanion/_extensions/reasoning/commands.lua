---@class CodeCompanion.Commands
---User commands for chat history functionality
local Commands = {}

local ReasoningPlugin = require('codecompanion-reasoning')

-- Create user commands for chat history
function Commands.setup()
  -- Show chat history picker
  vim.api.nvim_create_user_command('CodeCompanionChatHistory', function()
    ReasoningPlugin.show_chat_history()
  end, {
    desc = 'Show CodeCompanion chat history picker',
  })

  -- List chat sessions
  vim.api.nvim_create_user_command('CodeCompanionChatList', function()
    local sessions = ReasoningPlugin.list_sessions()
    if #sessions == 0 then
      vim.notify('No chat sessions found', vim.log.levels.INFO)
      return
    end

    local lines = { 'CodeCompanion Chat Sessions:', '' }
    for i, session in ipairs(sessions) do
      table.insert(lines, string.format('[%d] %s - %d messages', i, session.created_at, session.total_messages))
      table.insert(lines, string.format('    Preview: %s', session.preview))
      table.insert(lines, '')
    end

    -- Show in a scratch buffer
    local buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
    vim.bo[buf].filetype = 'markdown'
    vim.bo[buf].modifiable = false

    local width = math.floor(vim.o.columns * 0.8)
    local height = math.floor(vim.o.lines * 0.8)
    local win = vim.api.nvim_open_win(buf, true, {
      relative = 'editor',
      width = width,
      height = height,
      col = math.floor((vim.o.columns - width) / 2),
      row = math.floor((vim.o.lines - height) / 2),
      style = 'minimal',
      border = 'rounded',
      title = ' Chat Sessions ',
      title_pos = 'center',
    })

    -- Close on escape
    vim.api.nvim_buf_set_keymap(buf, 'n', '<Esc>', '<cmd>close<cr>', { noremap = true, silent = true })
    vim.api.nvim_buf_set_keymap(buf, 'n', 'q', '<cmd>close<cr>', { noremap = true, silent = true })
  end, {
    desc = 'List all CodeCompanion chat sessions',
  })

  -- Save current buffer as chat session
  vim.api.nvim_create_user_command('CodeCompanionChatSave', function()
    local buf = vim.api.nvim_get_current_buf()
    local filetype = vim.bo[buf].filetype

    if filetype ~= 'codecompanion' then
      vim.notify('Current buffer is not a CodeCompanion chat', vim.log.levels.WARN)
      return
    end

    -- Extract chat data from current buffer
    local chat_hooks = require('codecompanion._extensions.reasoning.helpers.chat_hooks')
    local bufname = vim.api.nvim_buf_get_name(buf)
    local chat_id = bufname:match('codecompanion%-(%w+)') or 'manual_save_' .. os.time()

    -- Get buffer content and parse it
    local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
    local content = table.concat(lines, '\n')

    if content == '' then
      vim.notify('Buffer is empty, nothing to save', vim.log.levels.WARN)
      return
    end

    -- Parse messages from buffer content
    local messages = {}
    local current_role = nil
    local current_content = {}

    for _, line in ipairs(lines) do
      local role = line:match('^## (User|Assistant)$') or line:match('^# (user|assistant)$')
      if role then
        if current_role and #current_content > 0 then
          table.insert(messages, {
            role = current_role:lower(),
            content = table.concat(current_content, '\n'):gsub('^%s+', ''):gsub('%s+$', ''),
            timestamp = os.time(),
          })
        end
        current_role = role:lower()
        current_content = {}
      elseif current_role then
        table.insert(current_content, line)
      end
    end

    if current_role and #current_content > 0 then
      table.insert(messages, {
        role = current_role:lower(),
        content = table.concat(current_content, '\n'):gsub('^%s+', ''):gsub('%s+$', ''),
        timestamp = os.time(),
      })
    end

    if #messages == 0 then
      vim.notify('No messages found in buffer', vim.log.levels.WARN)
      return
    end

    local chat_data = {
      id = chat_id,
      model = 'manual',
      adapter = { name = 'manual' },
      messages = messages,
      tools = {},
    }

    local success = ReasoningPlugin.save_session(chat_data)
    if success then
      vim.notify(string.format('Chat session saved (%d messages)', #messages), vim.log.levels.INFO)
    end
  end, {
    desc = 'Save current CodeCompanion chat as session',
  })

  -- Clean up old sessions
  vim.api.nvim_create_user_command('CodeCompanionChatCleanup', function()
    local SessionManager = require('codecompanion._extensions.reasoning.helpers.session_manager')
    SessionManager.cleanup_old_sessions()
    vim.notify('Old chat sessions cleaned up', vim.log.levels.INFO)
  end, {
    desc = 'Clean up old CodeCompanion chat sessions',
  })
end

return Commands
