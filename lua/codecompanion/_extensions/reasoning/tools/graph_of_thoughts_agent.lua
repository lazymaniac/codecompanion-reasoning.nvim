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
function GraphOfThoughts:add_node(content, node_type, connect_to)
  if node_type and not NODE_TYPES[node_type] then
    local valid_types = {}
    for type_name, _ in pairs(NODE_TYPES) do
      table.insert(valid_types, type_name)
    end
    return nil, 'Invalid node type: ' .. tostring(node_type) .. '. Valid types: ' .. table.concat(valid_types, ', ')
  end

  local node = Node.new(content, nil, node_type) -- Auto-generate ID
  self.nodes[node.id] = node
  self.edges[node.id] = {}
  self.reverse_edges[node.id] = {}

  -- Add edges if connect_to is provided
  if connect_to then
    for _, target_id in ipairs(connect_to) do
      if self.nodes[target_id] then
        self:add_edge(node.id, target_id, 1.0, 'depends_on')
      end
    end
  end

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

-- Reflection analysis for graph state
function GraphOfThoughts:reflect()
  local analysis = {
    total_nodes = self:get_node_count(),
    total_edges = 0,
    type_distribution = {},
    insights = {},
    improvements = {},
    complexity_metrics = {},
  }

  -- Count edges and analyze types
  for _, edges in pairs(self.edges) do
    for _ in pairs(edges) do
      analysis.total_edges = analysis.total_edges + 1
    end
  end

  -- Analyze node types
  for _, node in pairs(self.nodes) do
    analysis.type_distribution[node.type] = (analysis.type_distribution[node.type] or 0) + 1
  end

  -- Generate insights
  if analysis.total_nodes > 5 then
    table.insert(
      analysis.insights,
      string.format('Complex reasoning graph with %d interconnected nodes', analysis.total_nodes)
    )
  elseif analysis.total_nodes > 0 then
    table.insert(analysis.insights, string.format('Growing reasoning graph with %d nodes', analysis.total_nodes))
  end

  if analysis.total_edges > 0 then
    local edge_to_node_ratio = analysis.total_edges / analysis.total_nodes
    if edge_to_node_ratio > 1.5 then
      table.insert(analysis.insights, 'High interconnectivity - thoughts are well-connected')
    elseif edge_to_node_ratio < 0.5 then
      table.insert(analysis.insights, 'Low interconnectivity - consider linking related thoughts')
    else
      table.insert(analysis.insights, 'Moderate interconnectivity between thoughts')
    end
  end

  -- Type distribution insights
  local type_counts = {}
  for type, count in pairs(analysis.type_distribution) do
    table.insert(type_counts, string.format('%s:%d', type, count))
  end
  if #type_counts > 0 then
    table.insert(analysis.insights, 'Node types: ' .. table.concat(type_counts, ', '))
  end

  -- Generate improvement suggestions
  if analysis.total_nodes == 0 then
    table.insert(analysis.improvements, 'Start by adding analysis nodes to explore the problem space')
  end

  if not analysis.type_distribution['validation'] then
    table.insert(analysis.improvements, 'Add validation nodes to test your reasoning')
  end

  if not analysis.type_distribution['synthesis'] then
    table.insert(analysis.improvements, 'Consider synthesis nodes to combine multiple ideas')
  end

  if analysis.total_edges == 0 and analysis.total_nodes > 1 then
    table.insert(analysis.improvements, 'Connect related nodes to show dependencies and relationships')
  end

  if self:has_cycle() then
    table.insert(analysis.improvements, 'Graph contains cycles - review dependencies for logical consistency')
  end

  return analysis
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

  local node_id, error = agent_state.current_instance:add_node(args.content, args.node_type, args.connect_to)

  if not node_id then
    return { status = 'error', data = error }
  end

  -- Format response with node ID for future connections
  local response_data = fmt(
    [[**%s:** %s
**Node ID:** %s (for connecting to this node)
]],
    string.upper((args.node_type or 'analysis'):sub(1, 1)) .. (args.node_type or 'analysis'):sub(2),
    args.content,
    node_id
  )

  if args.connect_to and #args.connect_to > 0 then
    response_data = response_data .. fmt('**Connected to:** %s', table.concat(args.connect_to, ', '))
  end

  return {
    status = 'success',
    data = response_data,
  }
end

function Actions.reflect(args, agent_state)
  if not agent_state.current_instance or agent_state.current_instance:get_node_count() == 0 then
    return { status = 'error', data = 'No nodes to reflect on. Add some nodes first.' }
  end

  local reflection_analysis = agent_state.current_instance:reflect()

  local output_parts = {}

  -- Add visual representation first
  local visualization = ReasoningVisualizer.visualize_graph(agent_state.current_instance)
  table.insert(output_parts, visualization)
  table.insert(output_parts, '')

  table.insert(output_parts, 'Graph of Thoughts Reflection')
  table.insert(output_parts, fmt('Total nodes: %d', reflection_analysis.total_nodes))
  table.insert(output_parts, fmt('Total connections: %d', reflection_analysis.total_edges))

  if #reflection_analysis.insights > 0 then
    table.insert(output_parts, '\nInsights:')
    for _, insight in ipairs(reflection_analysis.insights) do
      table.insert(output_parts, fmt('• %s', insight))
    end
  end

  if #reflection_analysis.improvements > 0 then
    table.insert(output_parts, '\nSuggested Improvements:')
    for _, improvement in ipairs(reflection_analysis.improvements) do
      table.insert(output_parts, fmt('• %s', improvement))
    end
  end

  if args.content and args.content ~= '' then
    table.insert(output_parts, fmt('\nUser Reflection:\n%s', args.content))
  end

  return {
    status = 'success',
    data = table.concat(output_parts, '\n'),
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

  -- Validate required parameters
  local validation_rules = {
    add_node = { 'content' },
    reflect = { 'content' },
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
      description = 'Software engineering problem solving in graph like structure with deep analysis and finding interconnections.\nSUGGESTED WORKFLOW:\n1. Use `project_context` to understand more about the project you will work on\n2. Call `add_node` to add your first analysis node\n3. Use `ask_user` for decisions/validation during reasoning if needed\n4. Continue adding connected nodes with `connect_to` parameter\n5. Call `reflect` to analyze progress and get some insights.\nTake small focused steps and build interconnected reasoning.\nALWAYS use companion tools: project_context for context, ask_user for decisions, add_tools for enhanced capabilities (like searching for files, editing code, getting context of code symbols, executing bash commands...). ALWAYS take small but thoughtful and precise steps. ALWAYS try to keep your token usage as low as possible, but without sacrificing quality. ALWAYS try to squize as much of this tool as possible, it is designed to help you with reasoning and thinking about the problem, not just executing commands.\n\nNOTE: This tool is designed to be used in a graph of thoughts workflow. It is not a general-purpose tool and should not be used for other purposes.',
      parameters = {
        type = 'object',
        properties = {
          action = {
            type = 'string',
            description = "The graph action to perform: 'add_node', 'reflect', 'merge_nodes'",
            enum = { 'add_node', 'reflect', 'merge_nodes' },
          },
          content = {
            type = 'string',
            description = "The node content to add (required for 'add_node') or reflection content (required for 'reflect'). Make it concise and focused.",
          },
          node_type = {
            type = 'string',
            enum = { 'analysis', 'reasoning', 'task', 'validation', 'synthesis' },
            description = "Node type: 'analysis', 'reasoning', 'task', 'validation', 'synthesis'.\n'analysis' - Analysis and exploration of the chunk of the problem.\n'reasoning' - Logical deduction and inference base on evidences.\n'task' - Actionable step towards the final goal.\n'validation' - Actionable step that validates current progress (like running test suite, adding new test cases, updating docs if necessary...).\n'synthesis' - Combining multiple thoughts or ideas to create new ideas or knowledge.\n(required for 'add_node')",
          },
          connect_to = {
            type = 'array',
            items = { type = 'string' },
            description = "Array of node IDs to connect this new node to (for 'add_node'). Creates dependencies/relationships between nodes.",
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
