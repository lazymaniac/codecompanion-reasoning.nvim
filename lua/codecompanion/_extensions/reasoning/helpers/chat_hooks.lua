---@class CodeCompanion.ChatHooks
---Simplified hooks using CodeCompanion event data directly
local ChatHooks = {}

local SessionManager = require('codecompanion._extensions.reasoning.helpers.session_manager')

local auto_save_enabled = true

-- Auto-inject project context into new chats
local function inject_project_context(chat)
  if not _G.CodeCompanionProjectKnowledge then
    -- Load the project knowledge module
    pcall(require, 'codecompanion._extensions.reasoning.tools.project_knowledge')
  end

  if _G.CodeCompanionProjectKnowledge and _G.CodeCompanionProjectKnowledge.auto_load_project_context then
    local project_context = _G.CodeCompanionProjectKnowledge.auto_load_project_context()

    if project_context then
      -- Insert project context at the beginning of chat context/system prompt
      if chat and chat.context and chat.context.bufnr then
        vim.schedule(function()
          local bufnr = chat.context.bufnr
          if vim.api.nvim_buf_is_valid(bufnr) then
            -- Get current buffer content
            local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)

            -- Add project context at the top (after any existing system messages)
            local context_lines = vim.split(project_context, '\n')
            local insert_pos = 0

            -- Find insertion point after existing system context
            for i, line in ipairs(lines) do
              if line:match('^# ') or line:match('^## ') then
                insert_pos = i
                break
              end
            end

            -- Insert context with separator
            local separator = { '', '---', '' }
            local all_context = {}
            vim.list_extend(all_context, context_lines)
            vim.list_extend(all_context, separator)

            vim.api.nvim_buf_set_lines(bufnr, insert_pos, insert_pos, false, all_context)
          end
        end)
      end
    end
  end
end

-- Simplified hook setup using CodeCompanion event data - saves only when session ends
local function setup_codecompanion_hooks()
  local group = vim.api.nvim_create_augroup('CodeCompanionReasoningHooks', { clear = true })

  -- Auto-inject project context when chat is created
  vim.api.nvim_create_autocmd('User', {
    pattern = { 'CodeCompanionChatCreated', 'CodeCompanionChatOpen' },
    group = group,
    callback = function(event)
      if event.data and event.data.bufnr then
        local buf = event.data.bufnr

        -- Try to get the chat object
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
          inject_project_context(chat_obj)
        end
      end
    end,
  })

  vim.api.nvim_create_autocmd('User', {
    pattern = 'CodeCompanionChatDone',
    group = group,
    callback = function(event)
      if not auto_save_enabled then
        return
      end

      if not event.data then
        return
      end

      local event_data = event.data
      local buf = event_data.bufnr

      -- Try to get the full chat object using Chat.buf_get_chat
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

      -- Save session only when we have a complete chat object
      if chat_obj then
        -- Hide tool output before saving (as mentioned in the PR)
        local success, err = pcall(function()
          -- Save the session with tool outputs hidden from display
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
function ChatHooks.setup(opts)
  opts = opts or {}
  auto_save_enabled = opts.auto_save ~= false
  if auto_save_enabled then
    setup_codecompanion_hooks()
  end
end

return ChatHooks
