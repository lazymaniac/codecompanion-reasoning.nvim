---@class CodeCompanion.GraphOfThoughtAgent

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

-- Node types for categorizing thoughts
local NODE_TYPES = {
  analysis = 'Analysis and exploration of the problem',
  reasoning = 'Logical deduction and inference',
  task = 'Actionable implementation step',
  validation = 'Verification and testing',
  synthesis = 'Combining multiple thoughts or ideas',
}

local node_counter = 0

local function generate_id()
  node_counter = node_counter + 1
  return 'node_' .. node_counter
end

-- ThoughtNode Class
local Node = {}
Node.__index = Node

function Node.new(content, id, node_type)
  local self = setmetatable({}, Node)
  self.id = id or generate_id()
  self.content = content or ''
  self.type = node_type or 'analysis'
  self.score = 0.0
  self.confidence = 0.0
  self.created_at = os.time()
  self.updated_at = os.time()
  return self
end

function Node:set_score(score, confidence)
  self.score = score or self.score
  self.confidence = confidence or self.confidence
  self.updated_at = os.time()
end

function Node:generate_suggestions()
  local generators = {
    analysis = function(content)
      return {
        '🤔 **Assumptions**: What assumptions are being made about this analysis?',
        '📊 **Data needed**: What information or data would help validate this analysis?',
        '❓ **Sub-questions**: What specific questions need to be answered?',
        '🔗 **Related cases**: Are there similar situations or precedents to consider?',
      }
    end,

    reasoning = function(content)
      return {
        '➡️ **Implications**: If this reasoning is correct, what are the logical consequences?',
        '🛡️ **Supporting evidence**: What facts or data support this line of reasoning?',
        '⚡ **Counter-arguments**: What are potential weaknesses or alternative viewpoints?',
        '🎯 **Next steps**: How can this reasoning lead to actionable conclusions?',
      }
    end,

    task = function(content)
      return {
        '📋 **Implementation steps**: Break this task into specific, actionable sub-steps',
        '🔄 **Alternative approaches**: Consider different ways to accomplish this task',
        '🛠️ **Resources needed**: What tools, skills, or materials are required?',
        '✅ **Success criteria**: How will you know when this task is completed successfully?',
      }
    end,

    validation = function(content)
      return {
        '🎯 **Test cases**: What specific scenarios should be tested?',
        '📏 **Success metrics**: What measurable criteria define success?',
        '⚠️ **Edge cases**: What unusual or boundary conditions might cause issues?',
        '🔧 **Failure recovery**: What should happen if validation fails?',
      }
    end,

    synthesis = function(content)
      return {
        '🧩 **Integration**: How do the component ideas fit together in this synthesis?',
        '⚖️ **Trade-offs**: What are the pros and cons of combining these concepts?',
        '🔄 **Refinement**: How can this synthesis be improved or optimized?',
        '🎯 **Applications**: Where and how can this synthesized idea be applied?',
      }
    end,
  }

  local generator = generators[self.type]
  if generator then
    return generator(self.content)
  end

  return { '💡 **Next steps**: Consider what logical follow-ups make sense for this thought' }
end

-- Edge Class
local Edge = {}
Edge.__index = Edge

function Edge.new(source_id, target_id, weight, relationship_type)
  local self = setmetatable({}, Edge)
  self.source = source_id
  self.target = target_id
  self.weight = weight or 1.0
  self.type = relationship_type or 'depends_on'
  self.created_at = os.time()
  return self
end

-- GraphOfThoughts Class
local GraphOfThoughts = {}
GraphOfThoughts.__index = GraphOfThoughts

function GraphOfThoughts.new()
  local self = setmetatable({}, GraphOfThoughts)
  self.nodes = {} -- id -> ThoughtNode
  self.edges = {} -- source_id -> {target_id -> Edge}
  self.reverse_edges = {} -- target_id -> {source_id -> Edge}
  return self
end

-- Node Management
function GraphOfThoughts:add_node(content, id, node_type)
  if node_type and not NODE_TYPES[node_type] then
    local valid_types = {}
    for type_name, _ in pairs(NODE_TYPES) do
      table.insert(valid_types, type_name)
    end
    return nil, 'Invalid node type: ' .. tostring(node_type) .. '. Valid types: ' .. table.concat(valid_types, ', ')
  end

  local node = Node.new(content, id, node_type)
  self.nodes[node.id] = node
  self.edges[node.id] = {}
  self.reverse_edges[node.id] = {}
  return node.id
end

function GraphOfThoughts:get_node(node_id)
  return self.nodes[node_id]
end

-- Edge Management
function GraphOfThoughts:add_edge(source_id, target_id, weight, relationship_type)
  if not self.nodes[source_id] or not self.nodes[target_id] then
    return false, 'Source or target node does not exist'
  end

  if source_id == target_id then
    return false, 'Self-loops are not allowed'
  end

  local edge = Edge.new(source_id, target_id, weight, relationship_type)

  self.edges[source_id][target_id] = edge
  self.reverse_edges[target_id][source_id] = edge

  return true
end

-- Cycle Detection
function GraphOfThoughts:has_cycle()
  local visited = {}
  local rec_stack = {}

  for node_id, _ in pairs(self.nodes) do
    visited[node_id] = false
    rec_stack[node_id] = false
  end

  local function dfs_cycle_check(node_id)
    visited[node_id] = true
    rec_stack[node_id] = true

    for target_id, _ in pairs(self.edges[node_id]) do
      if not visited[target_id] then
        if dfs_cycle_check(target_id) then
          return true
        end
      elseif rec_stack[target_id] then
        return true
      end
    end

    rec_stack[node_id] = false
    return false
  end

  for node_id, _ in pairs(self.nodes) do
    if not visited[node_id] then
      if dfs_cycle_check(node_id) then
        return true
      end
    end
  end

  return false
end

-- Topological Sort using Kahn's algorithm
function GraphOfThoughts:topological_sort()
  if self:has_cycle() then
    return nil, 'Graph contains cycles, topological sort not possible'
  end

  local in_degree = {}
  local result = {}
  local queue = {}

  -- Initialize in-degree for all nodes
  for node_id, _ in pairs(self.nodes) do
    in_degree[node_id] = 0
  end

  -- Calculate in-degree for each node
  for source_id, targets in pairs(self.edges) do
    for target_id, _ in pairs(targets) do
      in_degree[target_id] = in_degree[target_id] + 1
    end
  end

  -- Find all nodes with in-degree 0
  for node_id, degree in pairs(in_degree) do
    if degree == 0 then
      table.insert(queue, node_id)
    end
  end

  -- Process nodes
  while #queue > 0 do
    local current = table.remove(queue, 1)
    table.insert(result, current)

    -- For each neighbor of current node
    for neighbor_id, _ in pairs(self.edges[current] or {}) do
      in_degree[neighbor_id] = in_degree[neighbor_id] - 1
      if in_degree[neighbor_id] == 0 then
        table.insert(queue, neighbor_id)
      end
    end
  end

  -- Check if all nodes were processed (no cycles)
  if #result ~= self:get_node_count() then
    return nil, 'Unexpected error in topological sort'
  end

  return result, nil
end

-- Evaluation System

function GraphOfThoughts:propagate_scores(node_id)
  local node = self.nodes[node_id]
  if not node then
    return
  end

  -- Simple score propagation: weighted average of dependency scores
  for dependent_id, _ in pairs(self.edges[node_id] or {}) do
    local dependent = self.nodes[dependent_id]
    if dependent then
      -- Update dependent's score based on this node's completion
      local influence = 0.3 -- configurable influence factor
      dependent.score = dependent.score + (node.score * influence)
    end
  end
end

-- Utility Functions
function GraphOfThoughts:get_node_count()
  local count = 0
  for _ in pairs(self.nodes) do
    count = count + 1
  end
  return count
end

function GraphOfThoughts:get_stats()
  local stats = {
    total_nodes = self:get_node_count(),
    total_edges = 0,
  }

  for _, edges in pairs(self.edges) do
    for _ in pairs(edges) do
      stats.total_edges = stats.total_edges + 1
    end
  end

  return stats
end

-- Serialization
function GraphOfThoughts:serialize()
  local data = {
    nodes = {},
    edges = {},
  }

  for node_id, node in pairs(self.nodes) do
    data.nodes[node_id] = {
      id = node.id,
      content = node.content,
      score = node.score,
      confidence = node.confidence,
      created_at = node.created_at,
      updated_at = node.updated_at,
    }
  end

  for _, targets in pairs(self.edges) do
    for _, edge in pairs(targets) do
      table.insert(data.edges, {
        source = edge.source,
        target = edge.target,
        weight = edge.weight,
        type = edge.type,
        created_at = edge.created_at,
      })
    end
  end

  return data
end

function GraphOfThoughts:deserialize(data)
  self.nodes = {}
  self.edges = {}
  self.reverse_edges = {}

  -- Recreate nodes
  for node_id, node_data in pairs(data.nodes) do
    local node = Node.new(node_data.content, node_data.id)
    node.score = node_data.score
    node.confidence = node_data.confidence
    node.created_at = node_data.created_at
    node.updated_at = node_data.updated_at

    self.nodes[node_id] = node
    self.edges[node_id] = {}
    self.reverse_edges[node_id] = {}
  end

  -- Recreate edges
  for _, edge_data in ipairs(data.edges) do
    self:add_edge(edge_data.source, edge_data.target, edge_data.weight, edge_data.type)
  end
end

-- Node Merging System
function GraphOfThoughts:merge_nodes(source_node_ids, merged_content, merged_id)
  -- Validate all source nodes exist
  for _, node_id in ipairs(source_node_ids) do
    if not self.nodes[node_id] then
      return false, string.format("Source node '%s' does not exist", node_id)
    end
  end

  -- Create the merged node
  local merged_node = Node.new(merged_content, merged_id)

  -- Calculate merged score based on source nodes
  local total_score = 0
  local total_confidence = 0
  for _, node_id in ipairs(source_node_ids) do
    local source_node = self.nodes[node_id]
    total_score = total_score + source_node.score
    total_confidence = total_confidence + source_node.confidence
  end

  merged_node:set_score(total_score / #source_node_ids, total_confidence / #source_node_ids)

  -- Add merged node to graph
  self.nodes[merged_node.id] = merged_node
  self.edges[merged_node.id] = {}
  self.reverse_edges[merged_node.id] = {}

  -- Create edges from all source nodes to the merged node
  for _, source_id in ipairs(source_node_ids) do
    self:add_edge(source_id, merged_node.id, 1.0, 'contributes_to')
  end

  return true, merged_node.id
end

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
  agent_state.current_instance = GraphOfThoughts.new()
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

