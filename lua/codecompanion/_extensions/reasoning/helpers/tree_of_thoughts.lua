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

  -- Generate insights
  if analysis.total_nodes > 1 then
    table.insert(
      analysis.insights,
      string.format(
        'Explored %d different thoughts across %d depth levels',
        analysis.total_nodes - 1,
        analysis.max_depth
      )
    ) -- -1 to exclude root
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
  if analysis.max_depth < 2 then
    table.insert(analysis.improvements, 'Consider deeper exploration of promising ideas')
  end

  if analysis.leaf_nodes < 2 then
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

return {
  TreeNode = TreeNode,
  TreeOfThoughts = TreeOfThoughts,
}
