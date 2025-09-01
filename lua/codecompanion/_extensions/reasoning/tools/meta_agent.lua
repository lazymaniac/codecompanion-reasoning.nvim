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
      description = [[Start every coding session with this tool.

PURPOSE
- Pick the reasoning agent that fits the task and attach essential companion tools (ask_user, add_tools, project_knowledge).

WHY FIRST
- Do not request specifics or act before tools are attached. Select an agent, then manage optional tools via add_tools.

CHOICES
- chain_of_thoughts_agent: sequential steps with reflection and evidence for actions.
- tree_of_thoughts_agent: branching alternatives with evidence and periodic comparison.
- graph_of_thoughts_agent: relationships + synthesis across aspects with evidence.

COMPANION TOOLS (auto‑attached)
- ask_user: interactive confirmation/decision tool for ambiguous choices or any potentially destructive change. Presents options and returns the user’s selection.
- add_tools: manage optional capabilities. First list available tools, then add exact tool names needed (e.g., read/edit/test helpers).
- project_knowledge: log a concise changelog entry (description + files) after successful work. Updates the knowledge file; it does not load context.

PROTOCOL
1) Call meta_agent to select an agent. Selecting an agent automatically attaches companion tools (ask_user, add_tools, project_knowledge) to this chat — you do not need to add them manually.
2) Immediately call `add_tools(action="list_tools")`, then `add_tools(action="add_tool", tool_name="<from list>")` to add any optional read/edit/test tools before proceeding.
3) Proceed with the chosen agent (small steps, reflect regularly, validate after edits, require evidence for actions).]],
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
        }

        local human_agent = agent_labels[selected_agent] or selected_agent
        local human_tools = {}
        for _, t in ipairs(added_companions) do
          table.insert(human_tools, tool_labels[t] or t)
        end

        local success_message = fmt('✅ %s agent is ready.', human_agent)
        local tools_message = fmt('Attached companion tools: %s', table.concat(human_tools, ', '))
        local next_message = 'Next: Use Add Tools to list optional tools, then add what you need before proceeding.'

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
