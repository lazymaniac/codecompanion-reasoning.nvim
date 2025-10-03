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

  local validation_rules = {
    add_node = { 'content', 'node_type' },
  }

  local required_fields = validation_rules[args.action] or {}
  for _, field in ipairs(required_fields) do
    if not args[field] or args[field] == '' then
      return { status = 'error', data = fmt('%s is required for %s action', field, args.action) }
    end
  end

  return Actions.add_node(args, agent_state)
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
Deep Network-Based (Graph of Thoughts pattern) Reasoning Agent. Model complex problems as interconnected evidence networks requiring deep cross-cutting analysis. This tool is designed to help you guide you through problem solving process and sort your thoughts in a Graph of Thought pattern. Use it often - it's your best friend.

INVESTIGATION REQUIREMENTS (MANDATORY)
- DECOMPOSITION NETWORK: 3 or more analysis nodes exploring different problem dimensions with interconnections
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

CROSS-CONNECTION REQUIREMENTS
- Reasoning nodes MUST connect to 2+ evidence sources
- Validation nodes MUST connect to their respective reasoning + evidence nodes
- Synthesis nodes MUST integrate insights from 3+ different reasoning paths
- Evidence task nodes should cross-reference related findings

EXAMPLE (use as reference)
- Review AVAILABLE TOOLS section to identify optional helpers
- `add_tools(tool_name="list_files")` — inventory affected modules
- `list_files(dir="lua", glob="**/*auth*|**/*api*|**/*logging*" )` — scope cross‑cutting areas
- `graph_of_thoughts_agent(node_type="analysis", content="Technical dimension: audit logging integration points across auth/API")`
- `graph_of_thoughts_agent(node_type="analysis", content="Security dimension: PII handling and data sensitivity in audit logs")`
- `graph_of_thoughts_agent(node_type="analysis", content="Performance dimension: logging overhead and async processing needs")`
- `graph_of_thoughts_agent(node_type="task", content="Investigate existing auth flow touchpoints and current logging patterns", connect_to=["<tech_analysis_id>"])`
- `graph_of_thoughts_agent(node_type="task", content="Analyze PII exposure risks in current API payloads and responses", connect_to=["<security_analysis_id>"])`
- `graph_of_thoughts_agent(node_type="reasoning", content="Audit insertion strategy: post-auth hook + pre-response filter based on flow evidence", connect_to=["<tech_task_id>", "<security_task_id>"])`
- `graph_of_thoughts_agent(node_type="validation", content="Test audit strategy: unit tests + integration tests for auth/API flows", connect_to=["<reasoning_id>", "<tech_task_id>"])`
- `graph_of_thoughts_agent(node_type="synthesis", content="Integrated solution: async audit pipeline with PII filtering, validated across all dimensions", connect_to=["<reasoning_id>","<validation_id>","<security_analysis_id>"])`

FORBIDDEN PATTERNS
- Linear analysis→reasoning→task chains
- Reasoning without evidence connections
- Solutions without validation networks
- Single-source reasoning without cross-dimensional investigation
]],
      parameters = {
        type = 'object',
        properties = {
          content = {
            type = 'string',
            description = 'The node content to add. Make it concise, focused and thoughtful.',
          },
          node_type = {
            type = 'string',
            enum = { 'analysis', 'reasoning', 'task', 'validation', 'synthesis' },
            description = [[
Node types:

`analysis` - Multi-dimensional problem space mapping ONLY. MUST explore different dimensions (technical, business, security, performance). REQUIRED: minimum 3 analysis nodes with different angles. FORBIDDEN: single-dimension analysis.

`task` - MANDATORY evidence collection phase or implementation. MUST investigate context, patterns, constraints for specific problem dimensions. REQUIRED: gather concrete evidence before any reasoning attempts. FORBIDDEN: implementation tasks without evidence foundation.

`reasoning` - Cross-dimensional solution hypothesis. MUST connect to evidence from multiple task nodes. REQUIRED: reference findings from 2+ evidence sources. FORBIDDEN: reasoning without cross-dimensional evidence connections.

`validation` - Network verification of reasoning paths. MUST test hypotheses against gathered evidence and constraints. REQUIRED: connect to both reasoning and evidence nodes. FORBIDDEN: validation without evidence cross-reference.

`synthesis` - Multi-path integration ONLY. MUST combine validated insights from multiple reasoning branches. REQUIRED: connect to 3+ different reasoning paths with evidence backing. FORBIDDEN: synthesis without cross-validated reasoning network.
]],
          },
          connect_to = {
            type = 'array',
            items = { type = 'string' },
            description = 'Array of node IDs to connect this new node to. Creates relationships between nodes.',
          },
        },
        required = { 'content', 'node_type', 'connect_to' },
        additionalProperties = false,
      },
      strict = true,
    },
  },
}
