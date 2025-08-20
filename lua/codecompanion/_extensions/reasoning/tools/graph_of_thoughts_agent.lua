---@class CodeCompanion.GraphOfThoughtAgent

local GoT = require('codecompanion._extensions.reasoning.helpers.graph_of_thoughts')
local ReasoningVisualizer = require('codecompanion._extensions.reasoning.helpers.reasoning_visualizer')
local log_ok, log = pcall(require, 'codecompanion.utils.log')
if not log_ok then
  -- Fallback logging when CodeCompanion log is not available
  log = {
    debug = function(...) end,
    error = function(...)
      vim.notify(string.format(...), vim.log.levels.ERROR)
    end,
  }
end
local fmt = string.format

local Actions = {}

function Actions.add_node(args, agent_state)
  if not agent_state.current_instance then
    return { status = 'error', data = 'Agent not initialized. This should not happen with auto-initialization.' }
  end

  log:debug('[Graph of Thoughts Agent] Adding node: %s (type: %s)', args.content, args.node_type or 'analysis')

  local node_id, error = agent_state.current_instance:add_node(args.content, args.id, args.node_type)

  if not node_id then
    return { status = 'error', data = error }
  end

  local node = agent_state.current_instance:get_node(node_id)
  local suggestions = node:generate_suggestions()

  return {
    status = 'success',
    data = fmt(
      [[# %s: %s

## Suggested Next Steps:

%s
]],
      args.node_type or 'analysis',
      args.content,
      table.concat(suggestions, '\n\n')
    ),
  }
end

function Actions.add_edge(args, agent_state)
  if not agent_state.current_instance then
    return { status = 'error', data = 'Agent not initialized. This should not happen with auto-initialization.' }
  end

  log:debug('[Graph of Thoughts Agent] Adding edge: %s -> %s', args.source_id, args.target_id)

  local success, error = agent_state.current_instance:add_edge(
    args.source_id,
    args.target_id,
    args.weight or 1.0,
    args.relationship_type or 'depends_on'
  )

  if not success then
    return { status = 'error', data = error }
  end

  if agent_state.current_instance:has_cycle() then
    return { status = 'error', data = 'Edge would create a cycle in the graph. Edge not added.' }
  end

  return {
    status = 'success',
    data = fmt(
      [[# Edge Added Successfully
The dependency has been created. The target node will wait for the source node to complete before it can execute.]],
      args.source_id,
      args.target_id,
      args.weight or 1.0,
      args.relationship_type or 'depends_on'
    ),
  }
end

function Actions.merge_nodes(args, agent_state)
  if not agent_state.current_instance then
    return { status = 'error', data = 'Agent not initialized. This should not happen with auto-initialization.' }
  end

  log:debug('[Graph of Thoughts Agent] Merging nodes: %s', table.concat(args.source_nodes, ', '))

  local success, result =
    agent_state.current_instance:merge_nodes(args.source_nodes, args.merged_content, args.merged_id)

  if not success then
    return { status = 'error', data = result }
  end

  return {
    status = 'success',
    data = fmt(
      [[# Nodes Merged Successfully

**Source Nodes:** %s
**New Merged Node ID:** %s
**Content:** %s

The nodes have been combined into a single reasoning unit.]],
      table.concat(args.source_nodes, ', '),
      result,
      args.merged_content
    ),
  }
end

local function initialize(agent_state)
  if agent_state.current_instance then
    return nil
  end

  log:debug('[Graph of Thoughts Agent] Initializing')

  agent_state.session_id = tostring(os.time())
  agent_state.current_instance = GoT.GraphOfThoughts.new()
  agent_state.current_instance.agent_type = 'Graph of Thoughts Agent'

  agent_state.current_instance.get_element = function(self, id)
    return self:get_node(id)
  end

  agent_state.current_instance.update_element_score = function(self, id, boost)
    local node = self:get_node(id)
    if node then
      node.score = node.score + boost
      return true
    end
    return false
  end
end

local function handle_action(args)
  local agent_state = _G._codecompanion_graph_of_thoughts_state or {}
  _G._codecompanion_graph_of_thoughts_state = agent_state

  local action = Actions[args.action]
  if not action then
    return { status = 'error', data = 'Invalid action: ' .. (args.action or 'nil') }
  end

  -- Validate required parameters (removed 'initialize' from validation)
  local validation_rules = {
    add_node = { 'content' },
    add_edge = { 'source_id', 'target_id' },
    merge_nodes = { 'source_nodes', 'merged_content' },
  }

  local required_fields = validation_rules[args.action] or {}
  for _, field in ipairs(required_fields) do
    if not args[field] or args[field] == '' then
      return { status = 'error', data = fmt('%s is required for %s action', field, args.action) }
    end
  end

  return action(args, agent_state)
end

---@class CodeCompanion.Tool.GraphOfThoughtsAgent: CodeCompanion.Tools.Tool
return {
  name = 'graph_of_thoughts_agent',
  cmds = {
    function(self, args, input)
      return handle_action(args)
    end,
  },
  handlers = {
    setup = function(self, tools)
      local agent_state = _G._codecompanion_graph_of_thoughts_state or {}
      _G._codecompanion_graph_of_thoughts_state = agent_state
      initialize(agent_state)
    end,
    on_exit = function(agent)
      local agent_state = _G._codecompanion_graph_of_thoughts_state
      if agent_state and agent_state.current_instance then
        local node_count = 0
        local edge_count = 0
        if agent_state.current_instance.nodes then
          node_count = #agent_state.current_instance.nodes
        end
        if agent_state.current_instance.edges then
          edge_count = #agent_state.current_instance.edges
        end
        log:debug('[Graph of Thoughts Agent] Session ended with %d nodes and %d edges', node_count, edge_count)
      end
    end,
  },
  output = {
    success = function(self, tools, cmd, stdout)
      local chat = tools.chat
      return chat:add_tool_output(self, tostring(stdout[1]))
    end,
    error = function(self, tools, cmd, stderr)
      local chat = tools.chat
      return chat:add_tool_output(self, tostring(stderr[1]))
    end,
  },
  schema = {
    type = 'function',
    ['function'] = {
      name = 'graph_of_thoughts_agent',
      description = 'Manages complex coding systems: auto-initializes on first use. Use for microservices, dependencies, integrations, architectures. WORKFLOW: 1) Use project_context for context 2) Add one component → Test connections → Use ask_user for validation → Map dependencies → Evolve gradually. Call add_node for components, add_edge for dependencies. ALWAYS use companion tools: project_context for context, ask_user for decisions, add_tools for system capabilities.',
      parameters = {
        type = 'object',
        properties = {
          action = {
            type = 'string',
            description = "The graph action to perform: 'add_node', 'add_edge', 'merge_nodes'",
          },
          content = {
            type = 'string',
            description = "Content for the new node (required for 'add_node')",
          },
          node_type = {
            type = 'string',
            enum = { 'analysis', 'reasoning', 'task', 'validation', 'synthesis' },
            description = 'Type of the node: analysis, reasoning, task, validation, or synthesis',
          },
          source_id = {
            type = 'string',
            description = "Source node ID for edge creation (required for 'add_edge')",
          },
          target_id = {
            type = 'string',
            description = "Target node ID for edge creation (required for 'add_edge')",
          },
          source_nodes = {
            type = 'array',
            items = { type = 'string' },
            description = "Array of source node IDs to merge (required for 'merge_nodes')",
          },
          merged_content = {
            type = 'string',
            description = "Content for the new merged node (required for 'merge_nodes')",
          },
          merged_id = {
            type = 'string',
            description = "Optional ID for the merged node (for 'merge_nodes')",
          },
        },
        required = { 'action' },
        additionalProperties = false,
      },
      strict = true,
    },
  },
}
