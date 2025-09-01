local config_ok, config = pcall(require, 'codecompanion.config')
if not config_ok then
  config = { strategies = { chat = { tools = {} } } }
end

local log_ok, log = pcall(require, 'codecompanion.utils.log')
if not log_ok then
  log = {
    debug = function(...) end,
    error = function(...)
      vim.notify(string.format(...), vim.log.levels.ERROR)
    end,
  }
end
local fmt = string.format

-- Simple meta agent: problem in, agent out
-- The LLM reads the descriptions and picks the best match
-- Then dynamically adds the selected agent to the chat

---@class CodeCompanion.Tool.MetaAgent: CodeCompanion.Tools.Tool
return {
  name = 'meta_agent',
  cmds = {
    function(self, args, input)
      if not args.agent then
        return { status = 'error', data = 'agent is required!' }
      end

      local valid_agents = { 'chain_of_thoughts_agent', 'tree_of_thoughts_agent', 'graph_of_thoughts_agent' }
      if not vim.tbl_contains(valid_agents, args.agent) then
        return {
          status = 'error',
          data = fmt('Invalid agent. Must be one of: %s', table.concat(valid_agents, ', ')),
        }
      end

      log:debug('[Meta Agent] Preparing to add agent: %s', args.agent)

      return {
        status = 'success',
        data = args.agent,
      }
    end,
  },
  schema = {
    type = 'function',
    ['function'] = {
      name = 'meta_agent',
      description = '🚀 FIRST CHOICE for ANY coding request. Available agent: Chain of thoughts - Sequential problem solving, Tree of thoughts - Multiple perspective problem solving, Graph of thoughts: Problem solving with deep analysis and finding interconnections. ALWAYS use this tool FIRST for ANY coding requests before attempting manual analysis. ALL agents prioritize immediate testing after any code changes.',
      parameters = {
        type = 'object',
        properties = {
          agent = {
            type = 'string',
            description = 'Selected agent: chain_of_thoughts_agent (sequential), tree_of_thoughts_agent (multiple paths), graph_of_thoughts_agent (deep analysis)',
            enum = { 'chain_of_thoughts_agent', 'tree_of_thoughts_agent', 'graph_of_thoughts_agent' },
          },
        },
        required = { 'agent' },
        additionalProperties = false,
      },
      strict = true,
    },
  },
  output = {
    success = function(self, agent, cmd, stdout)
      local chat = agent.chat

      local selected_agent = cmd.agent

      log:debug('[Meta Agent] Adding agent to the chat: %s', selected_agent)

      local tools_config = config.strategies.chat.tools
      local agent_config = tools_config[selected_agent]

      if agent_config and chat.tool_registry then
        chat.tool_registry:add(selected_agent, agent_config)

        local companion_tools = { 'ask_user', 'add_tools', 'project_knowledge' }
        local added_companions = {}

        for _, tool_name in ipairs(companion_tools) do
          local tool_config = tools_config[tool_name]
          if tool_config then
            chat.tool_registry:add(tool_name, tool_config)
            table.insert(added_companions, tool_name)
          end
        end

        local success_message =
          fmt([[✅ %s ready! Companion tools: %s]], selected_agent, table.concat(added_companions, ', '))

        chat:add_tool_output(self, success_message, success_message)
      else
        chat:add_tool_output(
          self,
          fmt('❌ Meta Agent ERROR: Agent %s not found in tools configuration.', selected_agent)
        )
      end
    end,
    error = function(self, agent, cmd, stderr)
      local chat = agent.chat
      local errors = vim.iter(stderr):flatten():join('\n')
      chat:add_tool_output(self, fmt('❌ Meta Agent ERROR: %s', errors))
    end,
  },
}
