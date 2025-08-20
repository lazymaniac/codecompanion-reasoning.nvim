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

        -- Helper to reset graph state between tests
        function reset_graph_state()
          _G._codecompanion_graph_of_thoughts_state = nil
          local GoT = require('codecompanion._extensions.reasoning.helpers.graph_of_thoughts')
          GoT.reset_test_counter()
        end
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
      has_source_id_param = params.properties.source_id ~= nil,
      has_target_id_param = params.properties.target_id ~= nil,
      has_source_nodes_param = params.properties.source_nodes ~= nil,
      has_merged_content_param = params.properties.merged_content ~= nil,
      action_required = vim.tbl_contains(params.required, 'action')
    }
  ]])

  local schema_info = child.lua_get('schema_info')

  h.eq('graph_of_thoughts_agent', schema_info.func_name)
  h.eq(true, schema_info.has_description)
  h.eq(true, schema_info.has_action_param)
  h.eq(true, schema_info.has_content_param)
  h.eq(true, schema_info.has_node_type_param)
  h.eq(true, schema_info.has_source_id_param)
  h.eq(true, schema_info.has_target_id_param)
  h.eq(true, schema_info.has_source_nodes_param)
  h.eq(true, schema_info.has_merged_content_param)
  h.eq(true, schema_info.action_required)
end

-- System prompt functionality moved to tool schema descriptions for token efficiency
T['tool description contains workflow guidance'] = function()
  child.lua([[
    schema = GraphOfThoughtsAgent.schema
    description = schema['function'].description

    description_info = {
      has_workflow = description and string.find(description, 'WORKFLOW') ~= nil,
      has_guidance = description and string.find(description, 'component') ~= nil,
      is_comprehensive = description and #description > 100
    }
  ]])

  local description_info = child.lua_get('description_info')

  h.eq(true, description_info.has_workflow)
  h.eq(true, description_info.has_guidance)
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
      has_suggestions = result.data and string.find(result.data, 'Suggested Next Steps') ~= nil
    }
  ]])

  local node_info = child.lua_get('node_info')

  h.eq('success', node_info.status)
  h.eq(true, node_info.has_data)
  h.eq(true, node_info.has_content)
  h.eq(true, node_info.has_suggestions)
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

-- Test add_edge action
T['add_edge action works correctly'] = function()
  child.lua([[
    reset_graph_state()

    -- Add source node (will get ID: node_1)
    call_tool(GraphOfThoughtsAgent, {
      action = 'add_node',
      content = 'Authentication service'
    })

    -- Add target node (will get ID: node_2)
    call_tool(GraphOfThoughtsAgent, {
      action = 'add_node',
      content = 'User database'
    })

    -- Add edge between them using predictable IDs
    edge_result = call_tool(GraphOfThoughtsAgent, {
      action = 'add_edge',
      source_id = 'node_1',
      target_id = 'node_2'
    })

    edge_info = {
      status = edge_result.status,
      success_message = edge_result.data and string.find(edge_result.data, 'Edge Added Successfully') ~= nil
    }
  ]])

  local edge_info = child.lua_get('edge_info')

  h.eq('success', edge_info.status)
  h.eq(true, edge_info.success_message)
end

-- Test add_edge with missing parameters
T['add_edge requires source_id and target_id'] = function()
  child.lua([[
    -- Missing source_id
    result1 = call_tool(GraphOfThoughtsAgent, {
      action = 'add_edge',
      target_id = 'node_2'
    })

    -- Missing target_id
    result2 = call_tool(GraphOfThoughtsAgent, {
      action = 'add_edge',
      source_id = 'node_1'
    })

    edge_validation_info = {
      missing_source_error = result1.status == 'error',
      missing_target_error = result2.status == 'error'
    }
  ]])

  local edge_validation_info = child.lua_get('edge_validation_info')

  h.eq(true, edge_validation_info.missing_source_error)
  h.eq(true, edge_validation_info.missing_target_error)
end

-- Test merge_nodes action
T['merge_nodes action works correctly'] = function()
  child.lua([[
    reset_graph_state()

    -- Add multiple nodes (will get IDs: node_1, node_2, node_3)
    call_tool(GraphOfThoughtsAgent, {
      action = 'add_node',
      content = 'Auth validation'
    })

    call_tool(GraphOfThoughtsAgent, {
      action = 'add_node',
      content = 'Token generation'
    })

    call_tool(GraphOfThoughtsAgent, {
      action = 'add_node',
      content = 'Session management'
    })

    -- Merge nodes using predictable IDs
    merge_result = call_tool(GraphOfThoughtsAgent, {
      action = 'merge_nodes',
      source_nodes = {'node_1', 'node_2', 'node_3'},
      merged_content = 'Complete authentication system'
    })

    merge_info = {
      status = merge_result.status,
      success_message = merge_result.data and string.find(merge_result.data, 'Nodes Merged Successfully') ~= nil
    }
  ]])

  local merge_info = child.lua_get('merge_info')

  h.eq('success', merge_info.status)
  h.eq(true, merge_info.success_message)
end

-- Test merge_nodes with missing parameters
T['merge_nodes requires source_nodes and merged_content'] = function()
  child.lua([[
    -- Missing source_nodes
    result1 = call_tool(GraphOfThoughtsAgent, {
      action = 'merge_nodes',
      merged_content = 'Test content'
    })

    -- Missing merged_content
    result2 = call_tool(GraphOfThoughtsAgent, {
      action = 'merge_nodes',
      source_nodes = {'node_1', 'node_2'}
    })

    merge_validation_info = {
      missing_source_nodes_error = result1.status == 'error',
      missing_merged_content_error = result2.status == 'error'
    }
  ]])

  local merge_validation_info = child.lua_get('merge_validation_info')

  h.eq(true, merge_validation_info.missing_source_nodes_error)
  h.eq(true, merge_validation_info.missing_merged_content_error)
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
    reset_graph_state()

    -- First call should auto-initialize and work
    result = call_tool(GraphOfThoughtsAgent, {
      action = 'add_node',
      content = 'Auto-initialization test'
    })

    auto_init_info = {
      status = result.status,
      has_content = result.data and string.find(result.data, 'Auto%-initialization test') ~= nil,
      has_suggestions = result.data and string.find(result.data, 'Suggested Next Steps') ~= nil
    }
  ]])

  local auto_init_info = child.lua_get('auto_init_info')

  h.eq('success', auto_init_info.status)
  h.eq(true, auto_init_info.has_content)
  h.eq(true, auto_init_info.has_suggestions)
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

-- Test complete workflow: nodes -> edges -> merge
T['complete workflow: add nodes, edges, and merge'] = function()
  child.lua([[
    reset_graph_state()

    -- Add multiple nodes (will get IDs: node_1, node_2, node_3)
    node1 = call_tool(GraphOfThoughtsAgent, {
      action = 'add_node',
      content = 'Database layer'
    })

    node2 = call_tool(GraphOfThoughtsAgent, {
      action = 'add_node',
      content = 'API layer'
    })

    node3 = call_tool(GraphOfThoughtsAgent, {
      action = 'add_node',
      content = 'Frontend layer'
    })

    -- Add edges between nodes using predictable IDs
    edge1 = call_tool(GraphOfThoughtsAgent, {
      action = 'add_edge',
      source_id = 'node_1',
      target_id = 'node_2'
    })

    edge2 = call_tool(GraphOfThoughtsAgent, {
      action = 'add_edge',
      source_id = 'node_2',
      target_id = 'node_3'
    })

    -- Merge some nodes
    merge = call_tool(GraphOfThoughtsAgent, {
      action = 'merge_nodes',
      source_nodes = {'node_1', 'node_2'},
      merged_content = 'Backend system (DB + API)'
    })

    workflow_info = {
      node1_success = node1.status == 'success',
      node2_success = node2.status == 'success',
      node3_success = node3.status == 'success',
      edge1_success = edge1.status == 'success',
      edge2_success = edge2.status == 'success',
      merge_success = merge.status == 'success'
    }
  ]])

  local workflow_info = child.lua_get('workflow_info')

  h.eq(true, workflow_info.node1_success)
  h.eq(true, workflow_info.node2_success)
  h.eq(true, workflow_info.node3_success)
  h.eq(true, workflow_info.edge1_success)
  h.eq(true, workflow_info.edge2_success)
  h.eq(true, workflow_info.merge_success)
end

return T

