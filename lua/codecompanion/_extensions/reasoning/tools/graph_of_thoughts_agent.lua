---@class CodeCompanion.GraphOfThoughtAgent

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

  local node = Node.new(content, node_type)
  self.nodes[node.id] = node
  self.edges[node.id] = {}

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

  for _, edges in pairs(self.edges) do
    for _ in pairs(edges) do
      analysis.total_edges = analysis.total_edges + 1
    end
  end

  for _, node in pairs(self.nodes) do
    analysis.type_distribution[node.type] = (analysis.type_distribution[node.type] or 0) + 1
  end

  if analysis.total_nodes > 10 then
    table.insert(
      analysis.insights,
      string.format('Complex reasoning graph with %d interconnected nodes', analysis.total_nodes)
    )
  elseif analysis.total_nodes > 0 then
    table.insert(analysis.insights, string.format('Growing reasoning graph with %d nodes', analysis.total_nodes))
  end

  local type_counts = {}
  for type, count in pairs(analysis.type_distribution) do
    table.insert(type_counts, string.format('%s:%d', type, count))
  end
  if #type_counts > 0 then
    table.insert(analysis.insights, 'Node types: ' .. table.concat(type_counts, ', '))
  end

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
      description = [[
MANDATORY Network-Based Investigation Agent. Model complex problems as interconnected evidence networks requiring deep cross-cutting analysis.

INVESTIGATION REQUIREMENTS (MANDATORY)
- DECOMPOSITION NETWORK: 3-4 analysis nodes exploring different problem dimensions with interconnections
- EVIDENCE MANDATES: Task nodes MUST gather contextual evidence before any reasoning attempts
- CROSS-CONNECTION: Reasoning nodes MUST connect to evidence from multiple analysis branches
- VALIDATION NETWORKS: All reasoning paths require validation nodes with specific verification steps
- SYNTHESIS INTEGRATION: Combine validated insights across multiple investigation branches

MANDATORY NETWORK WORKFLOW
1) PROBLEM SPACE MAPPING: Multiple analysis nodes examining different aspects (technical, business, user impact)
2) EVIDENCE COLLECTION LAYER: Task nodes investigating each dimension (existing code, patterns, constraints, requirements)
3) HYPOTHESIS NETWORK: Reasoning nodes proposing solutions based on cross-dimensional evidence
4) VALIDATION MESH: Validation nodes testing each hypothesis against gathered evidence
5) SYNTHESIS CONVERGENCE: Integration nodes combining validated approaches into cohesive solution

NODE TYPE MANDATES
- `analysis`: ONLY for multi-dimensional problem decomposition; minimum 3 different angles required
- `task`: MANDATORY evidence collection phase; must investigate context before reasoning
- `reasoning`: MUST connect to evidence from multiple task nodes; reference specific findings
- `validation`: MANDATORY for each reasoning path; must verify against evidence and constraints
- `synthesis`: ONLY for integrating multiple validated reasoning paths; show evidence cross-connections

CROSS-CONNECTION REQUIREMENTS
- Reasoning nodes MUST connect to 2+ evidence sources
- Validation nodes MUST connect to their respective reasoning + evidence nodes
- Synthesis nodes MUST integrate insights from 3+ different reasoning paths
- Evidence task nodes should cross-reference related findings

EXAMPLE (use as reference)
- `add_tools(action="list_tools")`
- `add_tools(action="add_tool", tool_name="list_files")` — inventory affected modules
- `list_files(dir="lua", glob="**/*auth*|**/*api*|**/*logging*" )` — scope cross‑cutting areas
- `graph_of_thoughts_agent(action="add_node", node_type="analysis", content="Technical dimension: audit logging integration points across auth/API")`
- `graph_of_thoughts_agent(action="add_node", node_type="analysis", content="Security dimension: PII handling and data sensitivity in audit logs")`
- `graph_of_thoughts_agent(action="add_node", node_type="analysis", content="Performance dimension: logging overhead and async processing needs")`
- `graph_of_thoughts_agent(action="add_node", node_type="task", content="Investigate existing auth flow touchpoints and current logging patterns", connect_to=["<tech_analysis_id>"])`
- `graph_of_thoughts_agent(action="add_node", node_type="task", content="Analyze PII exposure risks in current API payloads and responses", connect_to=["<security_analysis_id>"])`
- `graph_of_thoughts_agent(action="add_node", node_type="reasoning", content="Audit insertion strategy: post-auth hook + pre-response filter based on flow evidence", connect_to=["<tech_task_id>", "<security_task_id>"])`
- `graph_of_thoughts_agent(action="add_node", node_type="validation", content="Test audit strategy: unit tests + integration tests for auth/API flows", connect_to=["<reasoning_id>", "<tech_task_id>"])`
- `graph_of_thoughts_agent(action="add_node", node_type="synthesis", content="Integrated solution: async audit pipeline with PII filtering, validated across all dimensions", connect_to=["<reasoning_id>","<validation_id>","<security_analysis_id>"])`
- `graph_of_thoughts_agent(action="reflect", content="Evidence network complete: technical, security, performance dimensions investigated and integrated")`

FORBIDDEN PATTERNS
- Linear analysis→reasoning→task chains
- Reasoning without evidence connections
- Solutions without validation networks
- Single-source reasoning without cross-dimensional investigation
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
            description = [[
Node type: `analysis`, `reasoning`, `task`, `validation`, `synthesis` (required for `add_node`)

NETWORK-ENFORCED INSTRUCTIONS:
`analysis` - Multi-dimensional problem space mapping ONLY. Must explore different dimensions (technical, business, security, performance). REQUIRED: minimum 3 analysis nodes with different angles. FORBIDDEN: single-dimension analysis.

`reasoning` - Cross-dimensional solution hypothesis. Must connect to evidence from multiple task nodes. REQUIRED: reference findings from 2+ evidence sources. FORBIDDEN: reasoning without cross-dimensional evidence connections.

`task` - MANDATORY evidence collection phase. Must investigate context, patterns, constraints for specific problem dimensions. REQUIRED: gather concrete evidence before any reasoning attempts. FORBIDDEN: implementation tasks without evidence foundation.

`validation` - Network verification of reasoning paths. Must test hypotheses against gathered evidence and constraints. REQUIRED: connect to both reasoning and evidence nodes. FORBIDDEN: validation without evidence cross-reference.

`synthesis` - Multi-path integration ONLY. Must combine validated insights from multiple reasoning branches. REQUIRED: connect to 3+ different reasoning paths with evidence backing. FORBIDDEN: synthesis without cross-validated reasoning network.
]],
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
