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
  if not agent_state.current_instance then
    return { status = 'error', data = 'Agent not initialized. This should not happen with auto-initialization.' }
  end

  local content = args.content
  local node_type = args.type or 'analysis' -- Default to analysis
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

  local new_node, error_msg, suggestions = agent_state.current_instance:add_typed_thought(parent_id, content, node_type)

  if not new_node then
    return { status = 'error', data = error_msg }
  end

  -- Format the response with suggestions
  local response_data = fmt(
    [[**Added %s node:** %s

**💡 Suggested next steps:**
%s

**Node ID:** %s (for adding child thoughts)

**NEXT: Continue exploring! Call add_thought again to add more thoughts and build the solution tree!**]],
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

-- Auto-initialize agent on first use
local function auto_initialize(agent_state, problem)
  if agent_state.current_instance then
    return nil -- Already initialized
  end

  log:debug('[Tree of Thoughts Agent] Auto-initializing with problem: %s', problem)

  agent_state.session_id = tostring(os.time())
  agent_state.current_instance = ToT.TreeOfThoughts:new(problem)
  agent_state.current_instance.agent_type = 'Tree of Thoughts Agent'

  -- Load project context
  local ContextDiscovery = require('codecompanion._extensions.reasoning.helpers.context_discovery')
  local context_summary, context_files = ContextDiscovery.load_project_context()
  agent_state.project_context = context_files

  -- Add interface methods for base class compatibility
  agent_state.current_instance.get_element = function(self, id)
    if self.nodes then
      for _, node in ipairs(self.nodes) do
        if node.id == id then
          return node
        end
      end
    end
    return nil
  end

  agent_state.current_instance.update_element_score = function(self, id, boost)
    local node = self:get_element(id)
    if node then
      node.value = (node.value or 0) + boost
      return true
    end
    return false
  end

  local init_message = fmt(
    [[🌳 Tree of Thoughts Agent activated for: %s

AUTO-INITIALIZED: Ready for multi-path exploration!

START: Call add_thought to explore first approach:
- action: "add_thought"
- content: "[your first small exploration]"
- type: "task"|"analysis"|"reasoning"|"validation"
- parent_id: "root" (optional)

REMEMBER: Explore multiple small approaches - try approach A → try approach B → compare → refine]],
    problem
  )

  -- Add context if found
  if #context_files > 0 then
    init_message = init_message .. '\n\n' .. context_summary
  end

  return init_message
end

-- Create the tool definition with auto-initialization
local function handle_action(args)
  local agent_state = _G._codecompanion_tree_of_thoughts_state or {}
  _G._codecompanion_tree_of_thoughts_state = agent_state

  -- Auto-initialize if needed
  if not agent_state.current_instance then
    local problem = args.content or 'Coding task exploration requested'
    local init_message = auto_initialize(agent_state, problem)

    if init_message then
      -- If this was an add_thought call that triggered initialization, continue with the thought
      if args.action == 'add_thought' then
        local thought_result = Actions.add_thought(args, agent_state)
        return {
          status = 'success',
          data = init_message .. '\n\n---\n\n' .. thought_result.data,
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
  schema = {
    type = 'function',
    ['function'] = {
      name = 'tree_of_thoughts_agent',
      description = 'Explores multiple coding approaches: auto-initializes on first use, ideal for architecture decisions, API design, comparing solutions.',
      parameters = {
        type = 'object',
        properties = {
          action = {
            type = 'string',
            description = "The tree action to perform: 'add_thought'",
          },
          content = {
            type = 'string',
            description = "The thought content to add (required for 'add_thought')",
          },
          type = {
            type = 'string',
            description = "Node type: 'analysis', 'reasoning', 'task', 'validation' (default: 'analysis', for 'add_thought')",
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
  system_prompt = function()
    local UnifiedReasoningPrompt = require('codecompanion._extensions.reasoning.helpers.unified_reasoning_prompt')
    return UnifiedReasoningPrompt.generate_for_reasoning('tree')
  end,
}
