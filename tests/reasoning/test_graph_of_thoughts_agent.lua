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

        -- Mock functions no longer needed since unified_reasoning_prompt was removed

        -- Helper function to call the tool
        function call_tool(tool, args)
          -- Initialize the agent if it has a setup handler
          if tool.handlers and tool.handlers.setup then
            tool.handlers.setup(tool, {})
          end
          return tool.cmds[1](tool, args, nil)
        end

        -- Enable test mode for predictable node IDs
        _G._codecompanion_test_mode = true
      ]])
    end,
    post_once = child.stop,
  },
})

-- Test tool basic configuration
T['tool has correct basic configuration'] = function()
  child.lua([[
    tool_info = {
      name = GraphOfThoughtsAgent.name,
      has_cmds = GraphOfThoughtsAgent.cmds ~= nil and #GraphOfThoughtsAgent.cmds > 0,
      has_schema = GraphOfThoughtsAgent.schema ~= nil
    }
  ]])

  local tool_info = child.lua_get('tool_info')

  h.eq('graph_of_thoughts_agent', tool_info.name)
  h.eq(true, tool_info.has_cmds)
  h.eq(true, tool_info.has_schema)
  -- System prompt removed for token efficiency
end

-- Test schema structure
T['tool schema has correct structure'] = function()
  child.lua([[
    schema = GraphOfThoughtsAgent.schema
    func_schema = schema['function']
    params = func_schema.parameters

    schema_info = {
      func_name = func_schema.name,
      has_description = func_schema.description ~= nil,
      has_action_param = params.properties.action ~= nil,
      has_content_param = params.properties.content ~= nil,
      has_node_type_param = params.properties.node_type ~= nil,
      has_connect_to_param = params.properties.connect_to ~= nil,
      action_required = vim.tbl_contains(params.required, 'action')
    }
  ]])

  local schema_info = child.lua_get('schema_info')

  h.eq('graph_of_thoughts_agent', schema_info.func_name)
  h.eq(true, schema_info.has_description)
  h.eq(true, schema_info.has_action_param)
  h.eq(true, schema_info.has_content_param)
  h.eq(true, schema_info.has_node_type_param)
  h.eq(true, schema_info.has_connect_to_param)
  h.eq(true, schema_info.action_required)
end

-- System prompt functionality moved to tool schema descriptions for token efficiency
T['tool description contains workflow guidance'] = function()
  child.lua([[
    schema = GraphOfThoughtsAgent.schema
    description = schema['function'].description

    description_info = {
      has_workflow = description and string.find(description, 'WORKFLOW') ~= nil,
      is_comprehensive = description and #description > 100
    }
  ]])

  local description_info = child.lua_get('description_info')

  h.eq(true, description_info.has_workflow)
  h.eq(true, description_info.is_comprehensive)
end

-- Test successful add_node action
T['add_node action works correctly'] = function()
  child.lua([[
    result = call_tool(GraphOfThoughtsAgent, {
      action = 'add_node',
      content = 'User authentication service',
      node_type = 'analysis'
    })

    node_info = {
      status = result.status,
      has_data = result.data ~= nil,
      has_content = result.data and string.find(result.data, 'User authentication service') ~= nil,
    }
  ]])

  local node_info = child.lua_get('node_info')

  h.eq('success', node_info.status)
  h.eq(true, node_info.has_data)
  h.eq(true, node_info.has_content)
end

-- Test add_node with missing content
T['add_node requires content'] = function()
  child.lua([[
    result = call_tool(GraphOfThoughtsAgent, {
      action = 'add_node'
    })

    missing_content_info = {
      status = result.status,
      mentions_content = result.data and string.find(result.data, 'content') ~= nil
    }
  ]])

  local missing_content_info = child.lua_get('missing_content_info')

  h.eq('error', missing_content_info.status)
  h.eq(true, missing_content_info.mentions_content)
end

-- Test add_node with connect_to parameter
T['add_node with connect_to works correctly'] = function()
  child.lua([[
    -- Add first node (will get ID: node_1)
    result1 = call_tool(GraphOfThoughtsAgent, {
      action = 'add_node',
      content = 'Authentication service',
      node_type = 'analysis'
    })

    -- Add second node connected to first (will get ID: node_2)
    result2 = call_tool(GraphOfThoughtsAgent, {
      action = 'add_node',
      content = 'User database',
      node_type = 'task',
      connect_to = {'node_1'}
    })

    connection_info = {
      first_status = result1.status,
      second_status = result2.status,
      has_node_id = result2.data and string.find(result2.data, 'node_') ~= nil
    }
  ]])

  local connection_info = child.lua_get('connection_info')

  h.eq('success', connection_info.first_status)
  h.eq('success', connection_info.second_status)
  h.eq(true, connection_info.has_node_id)
end

-- Test invalid action
T['invalid action returns error'] = function()
  child.lua([[
    result = call_tool(GraphOfThoughtsAgent, {
      action = 'nonexistent_action',
      content = 'Test content'
    })

    invalid_action_info = {
      status = result.status,
      mentions_invalid = result.data and string.find(result.data, 'Invalid action') ~= nil
    }
  ]])

  local invalid_action_info = child.lua_get('invalid_action_info')

  h.eq('error', invalid_action_info.status)
  h.eq(true, invalid_action_info.mentions_invalid)
end

-- Test reflect action
T['reflect action works correctly'] = function()
  child.lua([[
    -- Add some nodes first
    call_tool(GraphOfThoughtsAgent, {
      action = 'add_node',
      content = 'Auth validation',
      node_type = 'analysis'
    })

    call_tool(GraphOfThoughtsAgent, {
      action = 'add_node',
      content = 'Token generation',
      node_type = 'task'
    })

    -- Test reflect
    reflect_result = call_tool(GraphOfThoughtsAgent, {
      action = 'reflect',
      content = 'Analyzing progress so far'
    })

    reflect_info = {
      status = reflect_result.status,
      has_reflection = reflect_result.data and string.find(reflect_result.data, 'Graph of Thoughts') ~= nil
    }
  ]])

  local reflect_info = child.lua_get('reflect_info')

  h.eq('success', reflect_info.status)
  h.eq(true, reflect_info.has_reflection)
end

-- Test reflect with empty content
T['reflect requires content'] = function()
  child.lua([[
    -- Add a node first
    call_tool(GraphOfThoughtsAgent, {
      action = 'add_node',
      content = 'Test node'
    })

    -- Test reflect without content
    result = call_tool(GraphOfThoughtsAgent, {
      action = 'reflect'
    })

    reflect_validation_info = {
      status = result.status,
      mentions_content = result.data and string.find(result.data, 'content') ~= nil
    }
  ]])

  local reflect_validation_info = child.lua_get('reflect_validation_info')

  h.eq('error', reflect_validation_info.status)
  h.eq(true, reflect_validation_info.mentions_content)
end

-- Test invalid action
T['invalid action returns error'] = function()
  child.lua([[
    result = call_tool(GraphOfThoughtsAgent, {
      action = 'invalid_action'
    })

    invalid_info = {
      status = result.status,
      mentions_invalid = result.data and string.find(result.data, 'Invalid action') ~= nil
    }
  ]])

  local invalid_info = child.lua_get('invalid_info')

  h.eq('error', invalid_info.status)
  h.eq(true, invalid_info.mentions_invalid)
end

-- Test auto-initialization behavior
T['agent auto-initializes on first use'] = function()
  child.lua([[
    -- First call should auto-initialize and work
    result = call_tool(GraphOfThoughtsAgent, {
      action = 'add_node',
      content = 'Auto-initialization test'
    })

    auto_init_info = {
      status = result.status,
      has_content = result.data and string.find(result.data, 'Auto%-initialization test') ~= nil,
    }
  ]])

  local auto_init_info = child.lua_get('auto_init_info')

  h.eq('success', auto_init_info.status)
  h.eq(true, auto_init_info.has_content)
end

-- Test different node types
T['different node types are handled correctly'] = function()
  child.lua([[

    -- Test each node type
    analysis = call_tool(GraphOfThoughtsAgent, {
      action = 'add_node',
      content = 'Analyze system requirements',
      node_type = 'analysis'
    })

    reasoning = call_tool(GraphOfThoughtsAgent, {
      action = 'add_node',
      content = 'Design system architecture',
      node_type = 'reasoning'
    })

    task = call_tool(GraphOfThoughtsAgent, {
      action = 'add_node',
      content = 'Implement API endpoints',
      node_type = 'task'
    })

    validation = call_tool(GraphOfThoughtsAgent, {
      action = 'add_node',
      content = 'Test system integration',
      node_type = 'validation'
    })

    synthesis = call_tool(GraphOfThoughtsAgent, {
      action = 'add_node',
      content = 'Combine components into complete system',
      node_type = 'synthesis'
    })

    node_types_info = {
      analysis_success = analysis.status == 'success',
      reasoning_success = reasoning.status == 'success',
      task_success = task.status == 'success',
      validation_success = validation.status == 'success',
      synthesis_success = synthesis.status == 'success'
    }
  ]])

  local node_types_info = child.lua_get('node_types_info')

  h.eq(true, node_types_info.analysis_success)
  h.eq(true, node_types_info.reasoning_success)
  h.eq(true, node_types_info.task_success)
  h.eq(true, node_types_info.validation_success)
  h.eq(true, node_types_info.synthesis_success)
end

return T
