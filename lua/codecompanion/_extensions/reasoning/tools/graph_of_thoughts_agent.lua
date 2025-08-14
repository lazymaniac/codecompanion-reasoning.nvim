local ReasoningAgentBase =
  require("codecompanion._extensions.reasoning.reasoning.reasoning_agent_base").ReasoningAgentBase
local GraphOfThoughtEngine = require("codecompanion._extensions.reasoning.reasoning.graph_of_thought_engine")

return ReasoningAgentBase.create_tool_definition(GraphOfThoughtEngine.get_config())
