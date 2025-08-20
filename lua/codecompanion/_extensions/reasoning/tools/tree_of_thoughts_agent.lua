---@class CodeCompanion.TreeOfThoughtAgent

local ReasoningVisualizer = require('codecompanion._extensions.reasoning.helpers.reasoning_visualizer')
local ToT = require('codecompanion._extensions.reasoning.helpers.tree_of_thoughts')
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
  agent_state.current_instance = ToT.TreeOfThoughts:new('Coding task exploration')
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
      description = 'Explores multiple coding approaches. SUGGESTED WORKFLOW: 1) Use project_context for context 2) Try small approach → Evaluate → Use ask_user for feedback → Compare alternatives → Refine → Next experiment. Call add_thought to explore first approach, then continue exploring multiple paths. Use reflect to analyze progress and get insights. ALWAYS use companion tools: project_context for context, ask_user for validation, add_tools for enhanced capabilities.',
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
