---@class CodeCompanion.ChatHooks
---Simplified hooks using CodeCompanion event data directly
local ChatHooks = {}

local SessionManager = require('codecompanion._extensions.reasoning.helpers.session_manager')
local TitleGenerator = require('codecompanion._extensions.reasoning.helpers.title_generator')

local auto_save_enabled = true

-- Utilities for project knowledge initialization
local function find_project_root()
  return vim.fn.getcwd()
end

local function knowledge_file_exists()
  local root = find_project_root()
  return vim.fn.filereadable(root .. '/.codecompanion/project-knowledge.md') == 1
end

local function ensure_codecompanion_dir()
  local root = find_project_root()
  local dir = root .. '/.codecompanion'
  if vim.fn.isdirectory(dir) == 0 then
    vim.fn.mkdir(dir, 'p')
  end
  return dir
end

local function project_prompt_sentinel()
  local dir = ensure_codecompanion_dir()
  return dir .. '/.project-knowledge-prompted'
end

local function has_prompted_project_once()
  _G.__CC_REASONING_PROMPTED = _G.__CC_REASONING_PROMPTED or {}
  local root = find_project_root()
  if _G.__CC_REASONING_PROMPTED[root] then
    return true
  end
  local sentinel = project_prompt_sentinel()
  if vim.fn.filereadable(sentinel) == 1 then
    _G.__CC_REASONING_PROMPTED[root] = true
    return true
  end
  return false
end

local function mark_project_prompted()
  _G.__CC_REASONING_PROMPTED = _G.__CC_REASONING_PROMPTED or {}
  local root = find_project_root()
  _G.__CC_REASONING_PROMPTED[root] = true
  local sentinel = project_prompt_sentinel()
  local f = io.open(sentinel, 'w')
  if f then
    f:write('prompted=true\n')
    f:close()
  end
end

local function add_tool_if_available(chat, tool_name)
  local ok_cfg, config = pcall(require, 'codecompanion.config')
  if not ok_cfg or not config or not config.strategies or not config.strategies.chat then
    return false
  end
  local tool_cfg = config.strategies.chat.tools[tool_name]
  if not tool_cfg or not chat or not chat.tool_registry or not chat.tool_registry.add then
    return false
  end
  local ok = pcall(function()
    chat.tool_registry:add(tool_name, tool_cfg, { visible = true })
  end)
  return ok and true or false
end

local function queue_initialization_instructions(chat)
  local root = find_project_root()
  local knowledge_path = root .. '/.codecompanion/project-knowledge.md'
  local ai_files = {
    'CLAUDE.md',
    '.claude.md',
    'AGENTS.md',
    'agents.md',
    '.agents.md',
    '.cursorrules',
    'cursor.md',
    '.github/copilot-instructions.md',
    'copilot-instructions.md',
    'AI_CONTEXT.md',
    'ai-context.md',
    'INSTRUCTIONS.md',
  }
  local present = {}
  for _, f in ipairs(ai_files) do
    if vim.fn.filereadable(root .. '/' .. f) == 1 then
      table.insert(present, f)
    end
  end

  local lines = {
    'Initialize Project Knowledge',
    '',
    ('Goal: Create a CONCISE project knowledge file at `%s` under 1,500 tokens.'):format(knowledge_path),
    '',
    'Instructions:',
    '- Use `add_tools` to list available tools and add any read/write file tools needed to gather context.',
  }
  if #present > 0 then
    table.insert(
      lines,
      '- Read these existing AI context files and extract relevant information: ' .. table.concat(present, ', ')
    )
  else
    table.insert(
      lines,
      '- If no AI context files exist, infer details from README, package manifests, config files, and directory structure.'
    )
  end
  table.insert(lines, '- Draft the full content using the following structure:')
  table.insert(lines, '  - Project Overview: what the project does, tech stack, how to run/test')
  table.insert(lines, '  - Directory Structure: key directories and their purposes')
  table.insert(lines, '  - Changelog: start empty')
  table.insert(lines, '  - Current Features in Development: start empty')
  table.insert(lines, '')
  table.insert(
    lines,
    'When ready, CALL the tool `initialize_project_knowledge` with parameter `content` set to the full markdown text. That tool will save it to the path above.'
  )
  table.insert(lines, 'Important: After creation, future context is loaded only from this file.')

  if chat and chat.add_message then
    pcall(function()
      chat:add_message({ role = 'user', content = table.concat(lines, '\n') }, { visible = true })
    end)
    if chat and type(chat.submit) == 'function' then
      vim.schedule(function()
        pcall(function()
          chat:submit()
        end)
      end)
    end
  end
end

-- Auto-inject project context into new chats
local function inject_project_context(chat)
  local knowledge_path = find_project_root() .. '/.codecompanion/project-knowledge.md'
  if vim.fn.filereadable(knowledge_path) == 0 then
    return
  end

  local content
  local ok = pcall(function()
    local f = io.open(knowledge_path, 'r')
    if f then
      content = f:read('*all')
      f:close()
    end
  end)
  if not ok or not content or content == '' then
    return
  end

  if chat and chat.messages then
    for _, msg in ipairs(chat.messages) do
      if
        (msg.opts and msg.opts.tag == 'project_knowledge')
        or (type(msg.content) == 'string' and msg.content:find('^PROJECT CONTEXT:'))
      then
        return
      end
    end
  end

  if chat and chat.add_message then
    pcall(function()
      chat:add_message({ role = 'system', content = content }, { tag = 'project_knowledge', visible = false })
    end)
  end
end

-- Simplified hook setup using CodeCompanion event data - saves only when session ends
local function setup_codecompanion_hooks()
  local group = vim.api.nvim_create_augroup('CodeCompanionReasoningHooks', { clear = true })

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
          if (not knowledge_file_exists()) and (not has_prompted_project_once()) then
            vim.schedule(function()
              vim.ui.select({ '✓ Yes', '✗ No' }, {
                prompt = 'No project knowledge file found. Initialize now by letting the AI create it? ',
              }, function(choice)
                mark_project_prompted()

                if choice ~= '✓ Yes' then
                  return
                end

                ensure_codecompanion_dir()

                add_tool_if_available(chat_obj, 'initialize_project_knowledge')
                add_tool_if_available(chat_obj, 'add_tools')

                queue_initialization_instructions(chat_obj)
              end)
            end)
          end
        end
      end
    end,
  })

  -- Generate or refresh title on the first message and then every N messages
  vim.api.nvim_create_autocmd('User', {
    pattern = 'CodeCompanionChatSubmitted',
    group = group,
    callback = function(event)
      -- Try to get the full chat object
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

      -- Decide if we should generate or refresh a title based on interval cadence (1, 1+N, 1+2N, ...)
      local tg = TitleGenerator.new({ auto_generate_title = true })
      local should, is_refresh = tg:should_generate(chat_obj)
      if not should then
        return
      end

      -- Run async generation; persist on chat object and let normal save persist it later
      tg:generate(chat_obj, function(title)
        if not title or title == '' then
          return
        end
        -- Persist on chat object for subsequent saves and UI usage
        chat_obj.opts = chat_obj.opts or {}
        chat_obj.opts.title = title
        -- Mark the current user count as applied to avoid re-running at same threshold
        local applied = chat_obj.opts._title_generated_counts or {}
        local count = (tg and tg._count_user_messages and tg:_count_user_messages(chat_obj)) or 0
        applied[count] = true
        chat_obj.opts._title_generated_counts = applied

        -- Optionally trigger a lightweight autosave only once to persist title early
        -- Do not spam saves: only auto-save if there is at least one message
        if chat_obj.messages and #chat_obj.messages > 0 then
          pcall(function()
            SessionManager.auto_save_session(chat_obj)
          end)
        end
      end, is_refresh)
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
