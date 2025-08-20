---@class CodeCompanion.TreeOfThoughtAgent

-- Tree of Thoughts classes (merged from helpers/tree_of_thoughts.lua)

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

local TreeNode = {}
TreeNode.__index = TreeNode

-- Node types matching Chain of Thought
local NODE_TYPES = {
  analysis = 'Analysis and exploration of the problem',
  reasoning = 'Logical deduction and inference',
  task = 'Actionable implementation step',
  validation = 'Verification and testing',
}

function TreeNode:new(content, node_type, parent, depth)
  local node = {
    id = string.format('node_%d_%d', os.time(), math.random(1000, 9999)),
    content = content or '',
    type = node_type or 'analysis', -- Use 'type' field like Chain of Thought
    parent = parent,
    children = {},
    depth = depth or 0,
    score = 0,
    created_at = os.time(),
  }
  setmetatable(node, TreeNode)
  return node
end

function TreeNode:add_child(content, node_type)
  -- Validate node type
  if node_type and not NODE_TYPES[node_type] then
    return nil,
      'Invalid node type: ' .. tostring(node_type) .. '. Valid types: ' .. table.concat(vim.tbl_keys(NODE_TYPES), ', ')
  end

  local child = TreeNode:new(content, node_type, self, self.depth + 1)
  table.insert(self.children, child)
  return child
end

-- Generate suggestions based on node type
function TreeNode:generate_suggestions()
  local generators = {
    analysis = function(content)
      return {
        '🤔 **Assumptions**: What assumptions are being made about this analysis?',
        '📊 **Data needed**: What information or data would help validate this analysis?',
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
        '🔄 **Alternative approaches**: Consider different ways to accomplish this task',
        '✅ **Success criteria**: How will you know when this task is completed successfully?',
      }
    end,

    validation = function(content)
      return {
        '🎯 **Test cases**: What specific scenarios should be tested?',
        '⚠️ **Edge cases**: What unusual or boundary conditions might cause issues?',
      }
    end,
  }

  local generator = generators[self.type]
  if generator then
    return generator(self.content)
  end

  return { '💡 **Next steps**: Consider what logical follow-ups make sense for this thought' }
end

function TreeNode:get_path()
  local path = {}
  local current = self
  while current do
    table.insert(path, 1, current)
    current = current.parent
  end
  return path
end

function TreeNode:is_leaf()
  return #self.children == 0
end

function TreeNode:get_siblings()
  if not self.parent then
    return {}
  end
  local siblings = {}
  for _, child in ipairs(self.parent.children) do
    if child.id ~= self.id then
      table.insert(siblings, child)
    end
  end
  return siblings
end

-- TreeOfThoughts: Main reasoning system manager
local TreeOfThoughts = {}
TreeOfThoughts.__index = TreeOfThoughts

function TreeOfThoughts:new(initial_problem)
  local tot = {
    root = TreeNode:new(initial_problem or 'Initial Problem', 'analysis'),
  }
  setmetatable(tot, TreeOfThoughts)
  return tot
end

-- Add thought with type and return suggestions
function TreeOfThoughts:add_thought(parent_id, content, node_type)
  local parent_node = self.root

  -- Find parent node if specified
  if parent_id and parent_id ~= 'root' then
    parent_node = self:find_node_by_id(parent_id)
    if not parent_node then
      return nil, 'Parent node not found: ' .. parent_id
    end
  end

  -- Add the new node
  local new_node, error_msg = parent_node:add_child(content, node_type)
  if not new_node then
    return nil, error_msg
  end

  -- Generate suggestions based on type
  local suggestions = new_node:generate_suggestions()

  return new_node, nil, suggestions
end

-- Find node by ID (helper method)
function TreeOfThoughts:find_node_by_id(id)
  local function search(node)
    if node.id == id then
      return node
    end
    for _, child in ipairs(node.children) do
      local found = search(child)
      if found then
        return found
      end
    end
    return nil
  end
  return search(self.root)
end

-- Reflection analysis for tree state
function TreeOfThoughts:reflect()
  local analysis = {
    total_nodes = 0,
    max_depth = 0,
    leaf_nodes = 0,
    type_distribution = {},
    insights = {},
    improvements = {},
    branches = {},
  }

  -- Traverse tree and collect statistics
  local function traverse(node, depth)
    analysis.total_nodes = analysis.total_nodes + 1
    analysis.max_depth = math.max(analysis.max_depth, depth)

    -- Track type distribution
    analysis.type_distribution[node.type] = (analysis.type_distribution[node.type] or 0) + 1

    -- Track leaf nodes and branches
    if node:is_leaf() then
      analysis.leaf_nodes = analysis.leaf_nodes + 1
      if depth > 0 then -- Don't count root as branch
        table.insert(analysis.branches, {
          depth = depth,
          type = node.type,
          content_length = #node.content,
        })
      end
    end

    for _, child in ipairs(node.children) do
      traverse(child, depth + 1)
    end
  end

  traverse(self.root, 0)

  if analysis.total_nodes > 1 then
    table.insert(
      analysis.insights,
      string.format(
        'Explored %d different thoughts across %d depth levels',
        analysis.total_nodes - 1,
        analysis.max_depth
      )
    )
  end

  if analysis.leaf_nodes > 1 then
    table.insert(analysis.insights, string.format('%d exploration branches created', analysis.leaf_nodes))
  end

  -- Type distribution insights
  local type_counts = {}
  for type, count in pairs(analysis.type_distribution) do
    if type ~= 'analysis' or count > 1 then -- Don't report single analysis (root)
      table.insert(type_counts, string.format('%s:%d', type, count))
    end
  end
  if #type_counts > 0 then
    table.insert(analysis.insights, 'Node types: ' .. table.concat(type_counts, ', '))
  end

  -- Generate improvement suggestions
  if analysis.max_depth < 3 then
    table.insert(analysis.improvements, 'Consider deeper exploration of promising ideas')
  end

  if analysis.leaf_nodes < 3 then
    table.insert(analysis.improvements, 'Try exploring alternative approaches or solutions')
  end

  if not analysis.type_distribution['validation'] then
    table.insert(analysis.improvements, 'Add validation thoughts to test your reasoning')
  end

  if not analysis.type_distribution['task'] then
    table.insert(analysis.improvements, 'Include concrete task nodes for implementation steps')
  end

  return analysis
end

local Actions = {}

function Actions.add_thought(args, agent_state)
  local content = args.content
  local node_type = args.type or 'analysis'
  local parent_id = args.parent_id or 'root'

  log:debug('[Tree of Thoughts Agent] Adding typed thought: %s (%s)', content, node_type)

  -- Validate type
  local valid_types = { 'analysis', 'reasoning', 'task', 'validation' }
  if not vim.tbl_contains(valid_types, node_type) then
    return {
      status = 'error',
      data = "Invalid type '" .. node_type .. "'. Valid types: " .. table.concat(valid_types, ', '),
    }
  end

  local new_node, error_msg, suggestions = agent_state.current_instance:add_thought(parent_id, content, node_type)

  if not new_node then
    return { status = 'error', data = error_msg }
  end

  -- Format the response with suggestions
  local response_data = fmt(
    [[**%s:** %s

**💡 Suggestions:**
%s

**Node ID:** %s (for adding child thoughts)
]],
    string.upper(node_type:sub(1, 1)) .. node_type:sub(2),
    content,
    table.concat(suggestions, '\n'),
    new_node.id
  )

  return {
    status = 'success',
    data = response_data,
  }
end

function Actions.reflect(args, agent_state)
  if not agent_state.current_instance or #agent_state.current_instance.root.children == 0 then
    return { status = 'error', data = 'No thoughts to reflect on. Add some thoughts first.' }
  end

  local reflection_analysis = agent_state.current_instance:reflect()

  local output_parts = {}

  table.insert(output_parts, '# Tree of Thoughts Reflection')
  table.insert(output_parts, fmt('**Total nodes explored:** %d', reflection_analysis.total_nodes))
  table.insert(output_parts, fmt('**Maximum depth:** %d levels', reflection_analysis.max_depth))
  table.insert(output_parts, fmt('**Active branches:** %d', reflection_analysis.leaf_nodes))

  if #reflection_analysis.insights > 0 then
    table.insert(output_parts, '\n## Insights:')
    for _, insight in ipairs(reflection_analysis.insights) do
      table.insert(output_parts, fmt('• %s', insight))
    end
  end

  if #reflection_analysis.improvements > 0 then
    table.insert(output_parts, '\n## Suggested Next Steps:')
    for _, improvement in ipairs(reflection_analysis.improvements) do
      table.insert(output_parts, fmt('• %s', improvement))
    end
  end

  if args.content and args.content ~= '' then
    table.insert(output_parts, fmt('\n## Your Reflection:\n%s', args.content))
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

  log:debug('[Tree of Thoughts Agent] Initializing')

  agent_state.session_id = tostring(os.time())
  agent_state.current_instance = TreeOfThoughts:new()
  agent_state.current_instance.agent_type = 'Tree of Thoughts Agent'
end

local function handle_action(args)
  local agent_state = _G._codecompanion_tree_of_thoughts_state or {}
  _G._codecompanion_tree_of_thoughts_state = agent_state

  local action = Actions[args.action]
  if not action then
    return { status = 'error', data = 'Invalid action: ' .. (args.action or 'nil') }
  end

  -- Validate required parameters (removed 'initialize' from validation)
  local validation_rules = {
    add_thought = { 'content' },
  }

  local required_fields = validation_rules[args.action] or {}
  for _, field in ipairs(required_fields) do
    if not args[field] or args[field] == '' then
      return { status = 'error', data = fmt('%s is required for %s action', field, args.action) }
    end
  end

  return action(args, agent_state)
end

---@class CodeCompanion.Tool.TreeOfThoughtsAgent: CodeCompanion.Tools.Tool
return {
  name = 'tree_of_thoughts_agent',
  cmds = {
    function(self, args, input)
      return handle_action(args)
    end,
  },
  handlers = {
    setup = function(self, tools)
      local agent_state = _G._codecompanion_tree_of_thoughts_state or {}
      _G._codecompanion_tree_of_thoughts_state = agent_state
      initialize(agent_state)
    end,
    on_exit = function(agent)
      local agent_state = _G._codecompanion_tree_of_thoughts_state
      if agent_state and agent_state.current_instance then
        local reflection = agent_state.current_instance:reflect()
        log:debug(
          '[Tree of Thoughts Agent] Session ended with %d thoughts explored across %d branches',
          reflection.total_nodes,
          reflection.leaf_nodes
        )
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
      name = 'tree_of_thoughts_agent',
      description = 'Explores multiple coding approaches in tree like thinking process. SUGGESTED WORKFLOW: 1) Use project_context for context 2) Try small approach → Evaluate → Use ask_user for feedback → Compare alternatives → Refine → Next experiment → Reflect. Call add_thought to explore first approach, then continue exploring multiple paths. Use reflect to analyze progress and get insights. ALWAYS use companion tools: project_context for context, ask_user for validation, add_tools for enhanced capabilities.',
      parameters = {
        type = 'object',
        properties = {
          action = {
            type = 'string',
            description = "The tree action to perform: 'add_thought', 'reflect'",
            enum = { 'add_thought', 'reflect' },
          },
          content = {
            type = 'string',
            description = "The thought content to add (required for 'add_thought') or reflection content (optional for 'reflect')",
          },
          type = {
            type = 'string',
            description = "Node type: 'analysis', 'reasoning', 'task', 'validation'",
          },
          parent_id = {
            type = 'string',
            description = "ID of parent node to add thought to (default: 'root', for 'add_thought')",
          },
        },
        required = { 'action' },
        additionalProperties = false,
      },
      strict = true,
    },
  },
}
