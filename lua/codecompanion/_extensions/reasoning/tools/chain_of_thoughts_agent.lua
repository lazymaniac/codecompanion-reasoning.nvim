local ReasoningAgentBase =
  require('codecompanion._extensions.reasoning.reasoning.reasoning_agent_base').ReasoningAgentBase
local ChainOfThoughtEngine = require('codecompanion._extensions.reasoning.reasoning.chain_of_thoughts_engine')

return ReasoningAgentBase.create_tool_definition(ChainOfThoughtEngine.get_config())
