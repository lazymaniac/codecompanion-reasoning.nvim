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
  analysis = true,
  reasoning = true,
  task = true,
  validation = true,
  synthesis = true,
}

local node_counter = 0

local function generate_id()
  node_counter = node_counter + 1
  return 'node_' .. node_counter
end

-- ThoughtNode Class
local Node = {}
Node.__index = Node

function Node.new(content, node_type)
  local self = setmetatable({}, Node)
  self.id = generate_id()
  self.content = content or ''
  self.type = node_type or 'analysis'
  return self
end

-- Edge Class
local Edge = {}
Edge.__index = Edge

function Edge.new(source_id, target_id)
  local self = setmetatable({}, Edge)
  self.source = source_id
  self.target = target_id
  return self
end

-- GraphOfThoughts Class
local GraphOfThoughts = {}
GraphOfThoughts.__index = GraphOfThoughts

function GraphOfThoughts.new()
  local self = setmetatable({}, GraphOfThoughts)
  self.nodes = {} -- id -> ThoughtNode
  self.edges = {} -- source_id -> {target_id -> Edge}
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

  local node = Node.new(content, node_type) -- Auto-generate ID
  self.nodes[node.id] = node
  self.edges[node.id] = {}

  -- Add edges if connect_to is provided
  if connect_to then
    for _, target_id in ipairs(connect_to) do
      if self.nodes[target_id] then
        self:add_edge(node.id, target_id)
      end
    end
  end

  return node.id
end

-- Edge Management
function GraphOfThoughts:add_edge(source_id, target_id)
  if not self.nodes[source_id] or not self.nodes[target_id] then
    return false, 'Source or target node does not exist'
  end

  if source_id == target_id then
    return false, 'Self-loops are not allowed'
  end

  local edge = Edge.new(source_id, target_id)

  self.edges[source_id][target_id] = edge

  return true
end

-- Utility Functions
function GraphOfThoughts:get_node_count()
  local count = 0
  for _ in pairs(self.nodes) do
    count = count + 1
  end
  return count
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
  if analysis.total_nodes > 10 then
    table.insert(
      analysis.insights,
      string.format('Complex reasoning graph with %d interconnected nodes', analysis.total_nodes)
    )
  elseif analysis.total_nodes > 0 then
    table.insert(analysis.insights, string.format('Growing reasoning graph with %d nodes', analysis.total_nodes))
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
    table.insert(analysis.improvements, 'Consider synthesis nodes to create new ideas or knowledge')
  end

  if analysis.total_edges == 0 and analysis.total_nodes > 1 then
    table.insert(analysis.improvements, 'Connect related nodes to show dependencies and relationships')
  end

  return analysis
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
    '%s: %s\nNode ID: %s (connect using connect_to)',
    string.upper((args.node_type or 'analysis'):sub(1, 1)) .. (args.node_type or 'analysis'):sub(2),
    args.content,
    node_id
  )

  if args.connect_to and #args.connect_to > 0 then
    response_data = response_data .. fmt('Connected to: %s', table.concat(args.connect_to, ', '))
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

local function initialize(agent_state)
  if agent_state.current_instance then
    return nil
  end

  log:debug('[Graph of Thoughts Agent] Initializing')

  agent_state.session_id = tostring(os.time())
  agent_state.current_instance = GraphOfThoughts.new()
  agent_state.current_instance.agent_type = 'Graph of Thoughts Agent'
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
      description = [[Model the problem as a graph of thoughts with typed nodes and explicit connections. Explore relationships, merge insights, and reflect to steer towards the best solution.

USE WHEN
- You need to analyze cross-cutting concerns, dependencies, or multi-aspect trade-offs.

WORKFLOW
1) Use the auto-injected project knowledge for conventions. Discover and add needed tools via `add_tools` (list first, then add).
2) Add nodes with `action="add_node"` and `node_type` in {analysis, reasoning, task, validation, synthesis}. Connect new nodes to relevant prior nodes via `connect_to`.
3) Use `synthesis` nodes to combine insights across branches.
4) Reflect with `action="reflect"` to summarize structure, gaps, and next edges to add.
5) Use `ask_user` before destructive changes or when multiple viable paths exist.

RULES
- Precision: One idea/change per node; content ≤ 280 chars.
- Validation: After any code edit, add a validation node (tests, lint, or verifiable check) and connect it to the implementation node.
- Tooling: First `add_tools(action="list_tools")`, then `add_tools(action="add_tool", tool_name="<from list>")`. Do not assume tool names.
- Safety: Use `ask_user` before deletions, large rewrites, or API changes.
- Evidence: Ground your actions in observed facts (file paths, test output, diffs, line refs). Include this in your reasoning.
- Output: Do not dump raw chain-of-thought; write concise reasoning and the next concrete move.

IF TESTS ARE ABSENT
- Create minimal tests or `ask_user` to confirm an alternative verification strategy.

COMPLETION
- After successful implementation, call `project_knowledge` with a concise description and affected files.

STOP WHEN
- Success criteria met; waiting on user input; destructive action requires confirmation; repeated failures demand strategy change.
]],
      parameters = {
        type = 'object',
        properties = {
          action = {
            type = 'string',
            description = 'The graph action to perform: `add_node`, `reflect`',
            enum = { 'add_node', 'reflect' },
          },
          content = {
            type = 'string',
            description = 'The node content to add (required for `add_node`) or reflection content (required for `reflect`). Make it concise, focused and thoughtful.',
          },
          node_type = {
            type = 'string',
            enum = { 'analysis', 'reasoning', 'task', 'validation', 'synthesis' },
            description = [[Node type: `analysis`, `reasoning`, `task`, `validation`, `synthesis` (required for `add_node`)

Instructions:
`analysis` - Analysis and exploration of the chunk of the problem.
`reasoning` - Logical deduction and inference based on evidence.
`task` - Small actionable step towards the final goal.
'validation' - MANDATORY step that verifies current progress, especially REQUIRED after any code changes. This includes: running test suite, creating new tests, updating existing tests, executing code to verify functionality, checking for errors/failures.
`synthesis` - Combining multiple nodes to create new ideas or knowledge.\n]],
          },
          connect_to = {
            type = 'array',
            items = { type = 'string' },
            description = "Array of node IDs to connect this new node to (for 'add_node'). Creates relationships between nodes.",
          },
        },
        required = { 'action' },
        additionalProperties = false,
      },
      strict = true,
    },
  },
}
