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
      [[# Node Added Successfully

**Node ID:** %s
**Content:** %s
**Type:** %s

The node has been added to the graph and is ready for dependency connections.

## Suggested Next Steps:

%s

Use 'add_edge' to create dependencies with other nodes.]],
      node_id,
      args.content,
      args.node_type or 'analysis',
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

**Source:** %s
**Target:** %s
**Weight:** %.2f
**Type:** %s

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

-- Auto-initialize agent on first use
local function auto_initialize(agent_state, goal)
  if agent_state.current_instance then
    return nil -- Already initialized
  end

  log:debug('[Graph of Thoughts Agent] Auto-initializing with goal: %s', goal)

  agent_state.session_id = tostring(os.time())
  agent_state.current_instance = GoT.GraphOfThoughts.new()
  agent_state.current_instance.agent_type = 'Graph of Thoughts Agent'

  -- Load project context
  local MemoryEngine = require('codecompanion._extensions.reasoning.helpers.memory_engine')
  local context_summary, context_files = MemoryEngine.load_project_context()
  agent_state.project_context = context_files

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

  local goal_id = agent_state.current_instance:add_node(goal, 'goal')

  local init_message = fmt(
    [[🕸️ Graph of Thoughts Agent activated for: %s

AUTO-INITIALIZED: Ready for system building! (Root: %s)

START: Call add_node to add first component:
- action: "add_node"
- content: "[identify first component/file/module]"
- node_type: "task"|"analysis"|"reasoning"|"validation"|"synthesis"

THEN: Call add_edge to connect components:
- action: "add_edge"
- source_id: "[node1_id]"
- target_id: "[node2_id]"

REMEMBER: Build system incrementally - add component → connect dependencies → evolve architecture]],
    goal,
    goal_id
  )

  -- Add context if found
  if #context_files > 0 then
    init_message = init_message .. '\n\n' .. context_summary
  end

  return init_message
end

-- Create the tool definition with auto-initialization
local function handle_action(args)
  local agent_state = _G._codecompanion_graph_of_thoughts_state or {}
  _G._codecompanion_graph_of_thoughts_state = agent_state

  -- Auto-initialize if needed
  if not agent_state.current_instance then
    local goal = args.content or 'System building task requested'
    local init_message = auto_initialize(agent_state, goal)

    if init_message then
      -- If this was an action call that triggered initialization, continue with the action
      if args.action == 'add_node' then
        local node_result = Actions.add_node(args, agent_state)
        return {
          status = 'success',
          data = init_message .. '\n\n---\n\n' .. node_result.data,
        }
      elseif args.action == 'add_edge' then
        local edge_result = Actions.add_edge(args, agent_state)
        return {
          status = 'success',
          data = init_message .. '\n\n---\n\n' .. edge_result.data,
        }
      elseif args.action == 'merge_nodes' then
        local merge_result = Actions.merge_nodes(args, agent_state)
        return {
          status = 'success',
          data = init_message .. '\n\n---\n\n' .. merge_result.data,
        }
      else
        return { status = 'success', data = init_message }
      end
    end
  end

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
  schema = {
    type = 'function',
    ['function'] = {
      name = 'graph_of_thoughts_agent',
      description = 'Manages complex coding systems: auto-initializes on first use. Use for microservices, dependencies, integrations, architectures. WORKFLOW: Add one component → Test connections → Validate dependencies → Evolve gradually. Call add_node for components, add_edge for dependencies. Build system incrementally through connected components.',
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
