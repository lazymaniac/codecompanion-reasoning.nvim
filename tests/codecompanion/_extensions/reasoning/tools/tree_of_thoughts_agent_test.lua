-- filepath: tests/codecompanion/_extensions/reasoning/tools/tree_of_thoughts_agent_test.lua
-- Moved from tests/reasoning/test_tree_of_thoughts_agent.lua
local h = require('tests.helpers')

local new_set = MiniTest.new_set

local child = MiniTest.new_child_neovim()
local T = new_set({
  hooks = {
    pre_once = function()
      h.child_start(child)
      child.lua([[
        h = require('tests.helpers')
        TreeOfThoughtsAgent = require('codecompanion._extensions.reasoning.tools.tree_of_thoughts_agent')
        function call_tool(tool, args)
          if tool.handlers and tool.handlers.setup then
            tool.handlers.setup(tool, {})
          end
          return tool.cmds[1](tool, args, nil)
        end
      ]])
    end,
    post_once = child.stop,
  },
})

T['tool has correct basic configuration'] = function()
  local tool_info = child.lua([[
    return {
      name = TreeOfThoughtsAgent.name,
      has_cmds = TreeOfThoughtsAgent.cmds ~= nil and #TreeOfThoughtsAgent.cmds > 0,
      has_schema = TreeOfThoughtsAgent.schema ~= nil
    }
  ]])
  h.eq('tree_of_thoughts_agent', tool_info.name)
  h.eq(true, tool_info.has_cmds)
  h.eq(true, tool_info.has_schema)
end

T['tool schema has correct structure'] = function()
  local schema_info = child.lua([[
    local schema = TreeOfThoughtsAgent.schema
    local func_schema = schema['function']
    local params = func_schema.parameters
    return {
      func_name = func_schema.name,
      has_description = func_schema.description ~= nil,
      has_content_param = params.properties.content ~= nil,
      has_type_param = params.properties.type ~= nil,
      has_parent_id_param = params.properties.parent_id ~= nil
    }
  ]])
  h.eq('tree_of_thoughts_agent', schema_info.func_name)
  h.eq(true, schema_info.has_description)
  h.eq(true, schema_info.has_content_param)
  h.eq(true, schema_info.has_type_param)
  h.eq(true, schema_info.has_parent_id_param)
end

T['tool description contains workflow guidance'] = function()
  local description_info = child.lua([[
    local schema = TreeOfThoughtsAgent.schema
    local description = schema['function'].description
    return { has_workflow = description and string.find(description, 'WORKFLOW') ~= nil, has_guidance = description and string.find(description, 'approach') ~= nil, is_comprehensive = description and #description > 100 }
  ]])
  h.eq(true, description_info.has_workflow)
  h.eq(true, description_info.has_guidance)
  h.eq(true, description_info.is_comprehensive)
end

T['add_thought action works correctly'] = function()
  local thought_info = child.lua([[
    local result = call_tool(TreeOfThoughtsAgent, { action = 'add_thought', content = 'Consider using microservices architecture', type = 'analysis' })
    return { status = result.status, has_data = result.data ~= nil, success_message = result.data and string.find(result.data, '.*:') ~= nil }
  ]])
  h.eq('success', thought_info.status)
  h.eq(true, thought_info.has_data)
  h.eq(true, thought_info.success_message)
end

return T
