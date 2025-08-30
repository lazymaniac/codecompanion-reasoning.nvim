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

  for name, tool in pairs(reasoning_tools) do
    config.strategies.chat.tools[name] = {
      id = 'reasoning:' .. name,
      description = tool.schema['function'].description,
      callback = tool,
    }
  end

  return config
end

-- Export the tools for direct access if needed
ReasoningExtension.exports = {
  get_tools = register_tools,
}

return ReasoningExtension
