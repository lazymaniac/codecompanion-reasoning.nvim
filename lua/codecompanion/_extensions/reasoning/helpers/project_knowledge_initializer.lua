---@class CodeCompanion.ProjectKnowledgeInitializer
---Project knowledge initialization and management for CodeCompanion reasoning extension
local ProjectKnowledgeInitializer = {}

local reasoning_config = require('codecompanion._extensions.reasoning.config')

-- Private utility functions
local function find_project_root()
  return vim.fn.getcwd()
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

local function add_tool_if_available(chat, tool_name)
  local ok_cfg, config = pcall(require, 'codecompanion.config')
  if not ok_cfg or not config or not config.strategies or not config.strategies.chat then
    return false
  end
  local tool_cfg = config.strategies.chat.tools[tool_name]
  if not tool_cfg or not chat or not chat.tool_registry or not chat.tool_registry.add then
    return false
  end
  local prepared = vim.deepcopy(tool_cfg)
  local ok = pcall(function()
    chat.tool_registry:add(tool_name, prepared, { visible = true })
  end)
  return ok and true or false
end

-- Public API methods

---Check if project knowledge file exists
---@return boolean
function ProjectKnowledgeInitializer.has_knowledge_file()
  local root = find_project_root()
  return vim.fn.filereadable(root .. '/.codecompanion/project-knowledge.md') == 1
end

---Check if project has been prompted for initialization before
---@return boolean
function ProjectKnowledgeInitializer.has_been_prompted()
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

---Mark project as having been prompted for initialization
function ProjectKnowledgeInitializer.mark_as_prompted()
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

---Ensure .codecompanion directory exists
---@return string directory_path
function ProjectKnowledgeInitializer.ensure_directory()
  return ensure_codecompanion_dir()
end

---Queue initialization instructions in chat
---@param chat table|CodeCompanion.Chat|nil CodeCompanion chat object
function ProjectKnowledgeInitializer.queue_initialization_instructions(chat)
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
    '- Review AVAILABLE TOOLS in the system prompt and add any read/write helpers you need via `add_tools(tool_name="<name>")` before gathering context.',
  }
  if #present > 0 then
    table.insert(
      lines,
      '- Read these existing AI context files and extract relevant information: ' .. table.concat(present, ', ')
    )
  else
    table.insert(lines, '- Infer details from README, package manifests, config files, and directory structure.')
  end
  table.insert(lines, '- Draft the full content using the following structure:')
  table.insert(lines, '  - Project Overview: what the project does, tech stack, how to run/test')
  table.insert(lines, '  - Directory Structure: key directories and their purposes')
  table.insert(lines, '  - Changelog: start empty')
  table.insert(lines, '')
  table.insert(
    lines,
    'When ready, CALL the tool `initialize_project_knowledge` with parameter `content` set to the full markdown text.'
  )

  local adapter = reasoning_config.get().project_knowledge_initialization.adapter
  local model = reasoning_config.get().project_knowledge_initialization.model

  if chat then
    if adapter and model then
      chat:change_adapter(adapter, model)
    end
    chat:add_message({ role = 'user', content = table.concat(lines, '\n') }, { visible = true })
    vim.schedule(function()
      pcall(function()
        chat:submit()
      end)
    end)
  end
end

---Prompt user and initiate project knowledge initialization if agreed
---@param chat_buffer number Buffer number of the chat
---@param callback? function Optional callback after initialization prompt
function ProjectKnowledgeInitializer.prompt_for_initialization(chat_buffer, callback)
  vim.schedule(function()
    vim.ui.select({ '✓ Yes', '✗ No' }, {
      prompt = 'No project knowledge file found. Initialize now by letting the AI create it? ',
    }, function(choice)
      ProjectKnowledgeInitializer.mark_as_prompted()
      if choice ~= '✓ Yes' then
        if callback then
          callback(false)
        end
        return
      end

      ProjectKnowledgeInitializer.ensure_directory()
      local chat_obj = nil
      local ok, Chat = pcall(require, 'codecompanion.strategies.chat')
      if ok and Chat.buf_get_chat then
        local chat_ok, result = pcall(Chat.buf_get_chat, chat_buffer)
        if chat_ok then
          chat_obj = result
          add_tool_if_available(chat_obj, 'initialize_project_knowledge')
          add_tool_if_available(chat_obj, 'add_tools')
        end
      end
      ProjectKnowledgeInitializer.queue_initialization_instructions(chat_obj)
      if callback then
        callback(true)
      end
    end)
  end)
end

---Check if project needs initialization (no knowledge file and hasn't been prompted)
---@return boolean
function ProjectKnowledgeInitializer.needs_initialization()
  return not ProjectKnowledgeInitializer.has_knowledge_file() and not ProjectKnowledgeInitializer.has_been_prompted()
end

return ProjectKnowledgeInitializer
