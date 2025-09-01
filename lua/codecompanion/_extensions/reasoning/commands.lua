---@class CodeCompanion.Commands
---User commands for chat history and session management
local Commands = {}

local SessionManager = require('codecompanion._extensions.reasoning.helpers.session_manager')
local SessionManagerUI = require('codecompanion._extensions.reasoning.ui.session_manager_ui')
local ChatHooks = require('codecompanion._extensions.reasoning.helpers.chat_hooks')

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

  -- Enable auto-save by default
  ChatHooks.setup({ auto_save = true })
end

return Commands
