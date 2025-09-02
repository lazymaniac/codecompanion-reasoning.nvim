---@class CodeCompanion.Commands
local Commands = {}

local SessionManager = require('codecompanion._extensions.reasoning.helpers.session_manager')
local SessionManagerUI = require('codecompanion._extensions.reasoning.ui.session_manager_ui')
local ChatHooks = require('codecompanion._extensions.reasoning.helpers.chat_hooks')
local SessionOptimizer = require('codecompanion._extensions.reasoning.helpers.session_optimizer')

-- Command implementations

---Show interactive chat history picker
function Commands.show_chat_history()
  local session_ui = SessionManagerUI.new()
  session_ui:browse_sessions()
end

---Load the most recent chat session
function Commands.load_last_session()
  local last_session, err = SessionManager.get_last_session()
  if not last_session then
    vim.notify(err or 'No sessions found', vim.log.levels.WARN)
    return
  end

  local success, restore_err = SessionManager.restore_session(last_session)
  if not success then
    vim.notify(string.format('Failed to restore last session: %s', restore_err), vim.log.levels.ERROR)
  else
    vim.notify(string.format('Restored last session: %s', last_session), vim.log.levels.INFO)
  end
end

---View project knowledge file
function Commands.view_project_knowledge()
  local function find_project_root()
    return vim.fn.getcwd()
  end

  local project_root = find_project_root()
  local knowledge_file = project_root .. '/.codecompanion/project-knowledge.md'

  if vim.fn.filereadable(knowledge_file) == 1 then
    vim.cmd('edit ' .. knowledge_file)
  else
    vim.notify('No project knowledge file found. Use initialize_project_knowledge to create one.', vim.log.levels.INFO)
  end
end

---Initialize project knowledge via the tool and notify
function Commands.init_project_knowledge()
  local ok, tool = pcall(require, 'codecompanion._extensions.reasoning.tools.initialize_project_knowledge')
  if not ok or not tool or not tool.cmds or not tool.cmds[1] then
    vim.notify('Failed to load initialize_project_knowledge tool', vim.log.levels.ERROR)
    return
  end

  tool.cmds[1](tool, {}, nil, function(res)
    local msg = (res and res.data) or 'Initialization attempted'
    vim.schedule(function()
      vim.notify(msg, vim.log.levels.INFO)
    end)
  end)
end

---Show project-specific chat history
function Commands.show_project_history()
  local session_ui = SessionManagerUI.new()
  session_ui:browse_project_sessions()
end

---Optimize current chat session by summarizing messages
function Commands.optimize_current_session()
  -- Get current buffer and try to extract chat object
  local current_buf = vim.api.nvim_get_current_buf()
  local chat_obj = nil

  local ok, Chat = pcall(require, 'codecompanion.strategies.chat')
  if not ok or not Chat.buf_get_chat then
    vim.notify('CodeCompanion chat strategy not available', vim.log.levels.ERROR)
    return
  end

  local chat_ok, result = pcall(Chat.buf_get_chat, current_buf)
  if not chat_ok or not result then
    vim.notify('No active CodeCompanion chat found in current buffer', vim.log.levels.WARN)
    return
  end
  chat_obj = result

  if not chat_obj.messages or #chat_obj.messages == 0 then
    vim.notify('No messages to optimize', vim.log.levels.INFO)
    return
  end

  vim.notify('Optimizing session, please wait...', vim.log.levels.INFO)

  -- Create session optimizer and compact session
  local optimizer = SessionOptimizer.new()
  local session_data = {
    messages = chat_obj.messages,
    adapter = chat_obj.adapter,
    settings = chat_obj.settings,
    opts = chat_obj.opts,
  }

  optimizer:compact_session(session_data, function(compacted, error_msg)
    if error_msg then
      vim.schedule(function()
        vim.notify('Failed to optimize session: ' .. error_msg, vim.log.levels.ERROR)
      end)
      return
    end

    if not compacted or not compacted.messages then
      vim.schedule(function()
        vim.notify('Session optimization produced no result', vim.log.levels.WARN)
      end)
      return
    end

    vim.schedule(function()
      -- Find system message (usually first message with role='system')
      local system_msg_index = nil
      for i, msg in ipairs(chat_obj.messages) do
        if msg.role == 'system' then
          system_msg_index = i
          break
        end
      end

      -- Replace chat messages with optimized content
      -- Keep system message if present, add summary as user message, then continue from there
      local new_messages = {}

      if system_msg_index then
        table.insert(new_messages, chat_obj.messages[system_msg_index])
      end

      -- Add optimized summary as user message right after system prompt
      local summary_message = compacted.messages[1]
      summary_message.role = 'user' -- Change from assistant to user as requested
      table.insert(new_messages, summary_message)

      -- Replace current chat messages
      chat_obj.messages = new_messages

      -- Save the optimized session
      pcall(function()
        SessionManager.auto_save_session(chat_obj)
      end)

      -- Refresh the chat buffer display
      if chat_obj.render then
        pcall(function()
          chat_obj:render()
        end)
      end

      vim.notify(
        string.format(
          'Session optimized: %d messages compacted into 1 summary',
          compacted.metadata and compacted.metadata.compaction and compacted.metadata.compaction.original_message_count
            or 0
        ),
        vim.log.levels.INFO
      )
    end)
  end)
end

function Commands.setup()
  vim.api.nvim_create_user_command('CodeCompanionChatHistory', Commands.show_chat_history, {
    desc = 'Show interactive chat session picker',
  })

  vim.api.nvim_create_user_command('CodeCompanionChatLast', Commands.load_last_session, {
    desc = 'Load the most recent chat session',
  })

  vim.api.nvim_create_user_command('CodeCompanionProjectHistory', Commands.show_project_history, {
    desc = 'Show chat history for current project',
  })

  vim.api.nvim_create_user_command('CodeCompanionProjectKnowledge', Commands.view_project_knowledge, {
    desc = 'View project knowledge file',
  })

  vim.api.nvim_create_user_command('CodeCompanionInitProjectKnowledge', Commands.init_project_knowledge, {
    desc = 'Initialize project knowledge: prompt, add tools, and queue LLM instructions',
  })

  vim.api.nvim_create_user_command('CodeCompanionRefreshSessionTitles', function()
    local ok, SM = pcall(require, 'codecompanion._extensions.reasoning.helpers.session_manager')
    if not ok then
      return vim.notify('Failed to load session manager', vim.log.levels.ERROR)
    end
    SM.refresh_session_titles()
    vim.notify('Refreshing session titles in background…', vim.log.levels.INFO)
  end, {
    desc = 'Regenerate and persist session titles using the LLM',
  })

  vim.api.nvim_create_user_command('CodeCompanionOptimizeSession', Commands.optimize_current_session, {
    desc = 'Optimize current chat session by summarizing messages into a single summary',
  })

  -- Enable auto-save by default
  ChatHooks.setup({ auto_save = true })
end

return Commands
