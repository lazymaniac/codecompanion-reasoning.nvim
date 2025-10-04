-- filepath: tests/codecompanion/_extensions/reasoning/tools/graph_of_thoughts_agent_test.lua
-- Moved from tests/reasoning/test_graph_of_thoughts_agent.lua
local h = require('tests.helpers')

local new_set = MiniTest.new_set

local child = MiniTest.new_child_neovim()
local T = new_set({
  hooks = {
    pre_once = function()
      h.child_start(child)
      child.lua([[
        h = require('tests.helpers')
        GraphOfThoughtsAgent = require('codecompanion._extensions.reasoning.tools.graph_of_thoughts_agent')
        function call_tool(tool, args)
          if tool.handlers and tool.handlers.setup then
            tool.handlers.setup(tool, {})
          end
          return tool.cmds[1](tool, args, nil)
        end
        _G._codecompanion_test_mode = true
      ]])
    end,
    post_once = child.stop,
  },
})

T['tool has correct basic configuration'] = function()
  local tool_info = child.lua([[
    return {
      name = GraphOfThoughtsAgent.name,
      has_cmds = GraphOfThoughtsAgent.cmds ~= nil and #GraphOfThoughtsAgent.cmds > 0,
      has_schema = GraphOfThoughtsAgent.schema ~= nil
    }
  ]])
  h.eq('graph_of_thoughts_agent', tool_info.name)
  h.eq(true, tool_info.has_cmds)
  h.eq(true, tool_info.has_schema)
end

T['tool schema has correct structure'] = function()
  local schema_info = child.lua([[
    local schema = GraphOfThoughtsAgent.schema
    local func_schema = schema['function']
    local params = func_schema.parameters
    return {
      func_name = func_schema.name,
      has_description = func_schema.description ~= nil,
      has_content_param = params.properties.content ~= nil,
      has_node_type_param = params.properties.node_type ~= nil,
      has_connect_to_param = params.properties.connect_to ~= nil
    }
  ]])
  h.eq('graph_of_thoughts_agent', schema_info.func_name)
  h.eq(true, schema_info.has_description)
  h.eq(true, schema_info.has_content_param)
  h.eq(true, schema_info.has_node_type_param)
  h.eq(true, schema_info.has_connect_to_param)
end

T['tool description contains workflow guidance'] = function()
  local description_info = child.lua([[
    local schema = GraphOfThoughtsAgent.schema
    local description = schema['function'].description
    return { has_workflow = description and string.find(description, 'WORKFLOW') ~= nil, is_comprehensive = description and #description > 100 }
  ]])
  h.eq(true, description_info.has_workflow)
  h.eq(true, description_info.is_comprehensive)
end

T['add_node action works correctly'] = function()
  local node_info = child.lua([[
    local result = call_tool(GraphOfThoughtsAgent, { action = 'add_node', content = 'User authentication service', node_type = 'analysis' })
    return { status = result.status, has_data = result.data ~= nil, has_content = result.data and string.find(result.data, 'User authentication service') ~= nil }
  ]])
  h.eq('success', node_info.status)
  h.eq(true, node_info.has_data)
  h.eq(true, node_info.has_content)
end

return T
