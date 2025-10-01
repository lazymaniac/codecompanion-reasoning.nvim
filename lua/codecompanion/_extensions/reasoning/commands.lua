---@class CodeCompanion.Commands
local Commands = {}

local SessionManager = require('codecompanion._extensions.reasoning.helpers.session_manager')
local SessionManagerUI = require('codecompanion._extensions.reasoning.ui.session_manager_ui')
local ChatHooks = require('codecompanion._extensions.reasoning.helpers.chat_hooks')
local SessionOptimizer = require('codecompanion._extensions.reasoning.helpers.session_optimizer')
local SessionRestorer = require('codecompanion._extensions.reasoning.helpers.session_restorer')

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

  local success, restored_chat_or_err = SessionManager.restore_session(last_session)
  if not success then
    vim.notify(string.format('Failed to restore last session: %s', restored_chat_or_err), vim.log.levels.ERROR)
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

---Initialize project knowledge using custom adapter/model from config
function Commands.init_project_knowledge()
  local ProjectKnowledgeInitializer =
    require('codecompanion._extensions.reasoning.helpers.project_knowledge_initializer')

  -- Check if initialization is needed
  if not ProjectKnowledgeInitializer.needs_initialization() then
    if ProjectKnowledgeInitializer.has_knowledge_file() then
      vim.notify('Project knowledge file already exists', vim.log.levels.INFO)
    else
      vim.notify('Project knowledge initialization already prompted', vim.log.levels.INFO)
    end
    return
  end

  -- Start custom initialization with config-based adapter/model
  ProjectKnowledgeInitializer.prompt_for_initialization(
    require('codecompanion.strategies.chat').bufnr,
    function(accepted, chat)
      if accepted then
        if chat then
          vim.notify('Project knowledge initialization started with custom configuration', vim.log.levels.INFO)
        else
          vim.notify('Project knowledge initialization started', vim.log.levels.INFO)
        end
      else
        vim.notify('Project knowledge initialization cancelled', vim.log.levels.INFO)
      end
    end
  )
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

  -- Preserve existing session filename to update current session instead of creating new one
  local current_session_filename = chat_obj._session_filename or chat_obj.opts and chat_obj.opts.session_filename

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

      -- Update session file directly instead of relying on auto_save_session
      -- which might create a new session entry
      if current_session_filename then
        -- Preserve session filename to update existing session
        chat_obj._session_filename = current_session_filename
        chat_obj.opts = chat_obj.opts or {}
        chat_obj.opts.session_filename = current_session_filename

        -- Save directly to the existing session file
        local save_success, save_err = SessionManager.save_session(chat_obj)
        if not save_success then
          vim.notify('Failed to save optimized session: ' .. (save_err or 'unknown error'), vim.log.levels.WARN)
        end
      else
        -- No existing session filename, create new session
        pcall(function()
          SessionManager.auto_save_session(chat_obj)
        end)
      end

      -- Reload active session with compacted version using session_restorer
      local compacted_session_data = vim.deepcopy(compacted)
      compacted_session_data.config = {
        adapter = chat_obj.adapter,
        model = chat_obj.settings and chat_obj.settings.model or 'unknown',
      }
      compacted_session_data.tools = chat_obj.tool_registry and vim.tbl_keys(chat_obj.tool_registry.in_use) or {}
      compacted_session_data.session_id = chat_obj.id

      -- Use session_restorer to reload the active chat buffer with compacted content
      local success, _ =
        SessionRestorer.restore_session(compacted_session_data, current_session_filename, { chat = chat_obj })

      if success then
        vim.notify(
          string.format(
            'Session optimized and reloaded: %d messages compacted into 1 summary',
            compacted.metadata
                and compacted.metadata.compaction
                and compacted.metadata.compaction.original_message_count
              or 0
          ),
          vim.log.levels.INFO
        )
      else
        vim.notify(
          string.format(
            'Session optimized but failed to reload: %s. Manual refresh may be needed.',
            result or 'unknown error'
          ),
          vim.log.levels.WARN
        )
      end
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

  vim.api.nvim_create_user_command('CodeCompanionOptimizeSession', Commands.optimize_current_session, {
    desc = 'Optimize current chat session by summarizing messages into a message single summary',
  })

  -- Enable auto-save by default
  ChatHooks.setup()
end

return Commands
