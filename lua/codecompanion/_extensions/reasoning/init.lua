---@class CodeCompanion.Extension.Reasoning
local ReasoningExtension = {}

local function register_tools()
  local tools = {
    "ask_user",
    "chain_of_thoughts_agent",
    "tree_of_thoughts_agent",
    "graph_of_thoughts_agent",
    "meta_reasoning_governor",
    "tool_discovery",
  }

  local registered_tools = {}

  for _, tool_name in ipairs(tools) do
    local ok, tool = pcall(require, string.format("codecompanion._extensions.reasoning.tools.%s", tool_name))
    if ok then
      registered_tools[tool_name] = tool
    else
      vim.notify(string.format("Failed to load reasoning tool: %s", tool_name), vim.log.levels.WARN)
    end
  end

  return registered_tools
end

function ReasoningExtension.setup(opts)
  opts = opts or {}

  -- Register the reasoning tools
  local tools = register_tools()

  -- Return the extension configuration
  return {
    tools = tools,
    enabled = opts.enabled ~= false,
  }
end

-- Export the tools for direct access if needed
ReasoningExtension.exports = {
  get_tools = register_tools,
}

return ReasoningExtension
