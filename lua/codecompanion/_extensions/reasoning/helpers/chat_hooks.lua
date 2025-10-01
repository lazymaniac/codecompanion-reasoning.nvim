---@class CodeCompanion.ChatHooks
local ChatHooks = {}

local SessionManager = require('codecompanion._extensions.reasoning.helpers.session_manager')
local TitleGenerator = require('codecompanion._extensions.reasoning.helpers.session_title_generator')
local ProjectKnowledgeInitializer = require('codecompanion._extensions.reasoning.helpers.project_knowledge_initializer')
local config = require('codecompanion._extensions.reasoning.config')

local function setup_codecompanion_hooks()
  local group = vim.api.nvim_create_augroup('CodeCompanionReasoningHooks', { clear = true })

  vim.api.nvim_create_autocmd('User', {
    pattern = { 'CodeCompanionChatCreated', 'CodeCompanionChatOpen' },
    group = group,
    callback = function(event)
      if not (event and event.data and event.data.bufnr) then
        return
      end
      local buf = event.data.bufnr
      if ProjectKnowledgeInitializer.needs_initialization() then
        ProjectKnowledgeInitializer.prompt_for_initialization(buf)
      end
    end,
  })

  -- Generate or refresh title on the first message and then every N messages
  vim.api.nvim_create_autocmd('User', {
    pattern = 'CodeCompanionChatSubmitted',
    group = group,
    callback = function(event)
      local chat_obj = nil
      if event and event.data and event.data.bufnr and vim.api.nvim_buf_is_valid(event.data.bufnr) then
        local ok, Chat = pcall(require, 'codecompanion.strategies.chat')
        if ok and Chat.buf_get_chat then
          local chat_ok, result = pcall(Chat.buf_get_chat, event.data.bufnr)
          if chat_ok then
            chat_obj = result
          end
        end
      end

      if not chat_obj then
        return
      end

      local tg = TitleGenerator.new()
      local should = tg:should_generate(chat_obj)
      if not should then
        return
      end

      tg:generate(chat_obj, function(title)
        if not title or title == '' then
          return
        end
        chat_obj.opts = chat_obj.opts or {}
        chat_obj.opts.title = title
        local applied = chat_obj.opts._title_generated_counts or {}
        local count = (tg and tg._count_user_messages and tg:_count_user_messages(chat_obj)) or 0
        applied[count] = true
        chat_obj.opts._title_generated_counts = applied

        if chat_obj.messages and #chat_obj.messages > 0 then
          pcall(function()
            SessionManager.auto_save_session(chat_obj)
          end)
        end
      end)
    end,
  })

  vim.api.nvim_create_autocmd('User', {
    pattern = { 'CodeCompanionChatDone', 'CodeCompanionRequestStreaming' },
    group = group,
    callback = function(event)
      if not event.data then
        return
      end

      local event_data = event.data
      local buf = event_data.bufnr

      local chat_obj = nil
      if buf and vim.api.nvim_buf_is_valid(buf) then
        local ok, Chat = pcall(require, 'codecompanion.strategies.chat')
        if ok and Chat.buf_get_chat then
          local chat_ok, result = pcall(Chat.buf_get_chat, buf)
          if chat_ok then
            chat_obj = result
          end
        end
      end

      if chat_obj then
        local success, err = pcall(function()
          SessionManager.auto_save_session(chat_obj)
        end)
        if not success then
          vim.notify('Failed to save session: ' .. tostring(err), vim.log.levels.WARN)
        end
      end
    end,
  })

  return true
end

-- Setup hooks
function ChatHooks.setup()
  if config.get().session_history.auto_save then
    setup_codecompanion_hooks()
  end
end

return ChatHooks
