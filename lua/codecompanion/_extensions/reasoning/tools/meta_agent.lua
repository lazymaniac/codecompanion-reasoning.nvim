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
      description = [[Start every coding session with this tool.

PURPOSE
- Pick the reasoning agent that fits the task and attach essential companion tools (ask_user, add_tools, project_knowledge).

WHY FIRST
- Do not request specifics or act before tools are attached. Select an agent, then manage optional tools via `add_tools`.

CHOICES
- chain_of_thoughts_agent: sequential steps with reflection. Best for simple, linear tasks with a single obvious path.
- tree_of_thoughts_agent: branching alternatives with periodic comparison. Best when exploring multiple viable approaches or comparing trade-offs.
- graph_of_thoughts_agent: relationships + synthesis across aspects. Best for cross-cutting work or complex task requiring deep thinking.

SELECTION GUIDELINES
- Prefer tree_of_thoughts_agent or graph_of_thoughts_agent for complex software engineering tasks. Use chain_of_thoughts_agent only for straitforward tasks.
- Choose tree_of_thoughts_agent when you need to generate and compare alternative designs, refactoring strategies, debugging hypotheses etc.
- Choose graph_of_thoughts_agent when the task is complex, requires vast analysis or synthesizing new knowledge based on fidings to produce final solution.
]],
      parameters = {
        type = 'object',
        properties = {
          agent = {
            type = 'string',
            description = 'Selected agent. Prefer tree/graph for complex tasks: chain_of_thoughts_agent (simple, linear), tree_of_thoughts_agent (explore alternatives), graph_of_thoughts_agent (complex interconnections and design)',
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
        chat.tool_registry:add(selected_agent, vim.deepcopy(agent_config))

        local companion_tools = { 'ask_user', 'add_tools', 'project_knowledge', 'reflect_on_progress' }
        local added_companions = {}

        for _, tool_name in ipairs(companion_tools) do
          local tool_config = tools_config[tool_name]
          if tool_config then
            chat.tool_registry:add(tool_name, vim.deepcopy(tool_config))
            table.insert(added_companions, tool_name)
          end
        end

        -- Human-friendly labels
        local agent_labels = {
          chain_of_thoughts_agent = 'Chain of Thoughts',
          tree_of_thoughts_agent = 'Tree of Thoughts',
          graph_of_thoughts_agent = 'Graph of Thoughts',
        }
        local tool_labels = {
          ask_user = 'Ask User',
          add_tools = 'Add Tools',
          project_knowledge = 'Project Knowledge',
          reflect_on_progress = 'Reflect on Progress',
        }

        local human_agent = agent_labels[selected_agent] or selected_agent
        local human_tools = {}
        for _, t in ipairs(added_companions) do
          table.insert(human_tools, tool_labels[t] or t)
        end

        local success_message = fmt('✅ %s agent is ready.', human_agent)
        local tools_message = fmt('Attached companion tools: %s', table.concat(human_tools, ', '))
        local next_message =
          'Next: Review the AVAILABLE TOOLS section in the system prompt, then add what you need with add_tools before proceeding.'

        local combined = table.concat({ success_message, tools_message, next_message }, '\n')
        chat:add_tool_output(self, combined, combined)
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
