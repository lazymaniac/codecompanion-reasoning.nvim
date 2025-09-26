---@class CodeCompanion.Extension.Reasoning
local ReasoningExtension = {}

local function register_tools()
  local tools = {
    'ask_user',
    'chain_of_thoughts_agent',
    'tree_of_thoughts_agent',
    'graph_of_thoughts_agent',
    'meta_agent',
    'add_tools',
    'list_files',
    'project_knowledge',
    'initialize_project_knowledge',
  }

  local registered_tools = {}

  for _, tool_name in ipairs(tools) do
    local ok, tool = pcall(require, string.format('codecompanion._extensions.reasoning.tools.%s', tool_name))
    if ok then
      registered_tools[tool_name] = tool
    else
      vim.notify(string.format('Failed to load reasoning tool: %s', tool_name), vim.log.levels.WARN)
    end
  end

  return registered_tools
end

function ReasoningExtension.setup(opts)
  opts = opts or {}

  local reasoning_tools = register_tools()

  -- Initialize chat hooks for auto-save functionality
  local chat_hooks_ok, chat_hooks = pcall(require, 'codecompanion._extensions.reasoning.helpers.chat_hooks')
  if chat_hooks_ok then
    chat_hooks.setup(opts.chat_history or { auto_save = true })
  end

  -- Initialize session manager with configuration
  local session_manager_ok, session_manager =
    pcall(require, 'codecompanion._extensions.reasoning.helpers.session_manager')
  if session_manager_ok and opts.chat_history then
    session_manager.setup({
      sessions_dir = opts.chat_history.sessions_dir,
      max_sessions = opts.chat_history.max_sessions,
      auto_save = opts.chat_history.auto_save,
      auto_load_last_session = opts.chat_history.auto_load_last_session,
    })
  end

  -- Setup user commands if enabled
  if opts.chat_history and opts.chat_history.enable_commands ~= false then
    local commands_ok, commands = pcall(require, 'codecompanion._extensions.reasoning.commands')
    if commands_ok then
      commands.setup()
    end
  end

  local config_ok, config = pcall(require, 'codecompanion.config')
  if not config_ok then
    return {
      tools = reasoning_tools,
    }
  end

  -- System prompt: provide a function value for CodeCompanion to call.
  -- This keeps the prompt source in one place (helpers/system_prompt.lua)
  -- and appends Project Knowledge if present.
  local sp_ok, SystemPrompt = pcall(require, 'codecompanion._extensions.reasoning.helpers.system_prompt')
  if sp_ok and SystemPrompt and type(SystemPrompt.get) == 'function' then
    local prompt_fn = function()
      local prompt = SystemPrompt.get()
      local root = vim.fn.getcwd()
      local knowledge_path = root .. '/.codecompanion/project-knowledge.md'
      if vim.fn.filereadable(knowledge_path) == 1 then
        local ok, content = pcall(function()
          local f = io.open(knowledge_path, 'r')
          if not f then
            return nil
          end
          local c = f:read('*all')
          f:close()
          return c
        end)
        if ok and content and content ~= '' then
          return prompt .. '\n\n---\n PROJECT CONTEXT\n' .. content
        end
      end
      return prompt
    end
    config.opts = config.opts or {}
    config.opts.system_prompt = prompt_fn
  end

  for name, tool in pairs(reasoning_tools) do
    config.strategies.chat.tools[name] = {
      id = 'reasoning:' .. name,
      description = tool.schema['function'].description,
      callback = tool,
    }
  end

  return {
    tools = reasoning_tools,
    config = config,
  }
end

-- Export the tools for direct access if needed
ReasoningExtension.exports = {
  get_tools = register_tools,
}

return ReasoningExtension
