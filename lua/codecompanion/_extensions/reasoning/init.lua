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
    'project_context',
  }

  local registered_tools = {}

  for _, tool_name in ipairs(tools) do
    local ok, tool = pcall(require, string.format('codecompanion._extensions.reasoning.tools.%s', tool_name))
    if ok then
      local actual_name = tool.schema and tool.schema['function'] and tool.schema['function'].name
        or tool.name
        or tool_name
      registered_tools[actual_name] = tool
    else
      vim.notify(string.format('Failed to load reasoning tool: %s', tool_name), vim.log.levels.WARN)
    end
  end

  return registered_tools
end

function ReasoningExtension.setup(opts)
  opts = opts or {}

  local reasoning_tools = register_tools()

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
