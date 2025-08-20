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

        -- Mock functions no longer needed since unified_reasoning_prompt was removed

        -- Helper function to call the tool
        function call_tool(tool, args)
          -- Initialize the agent if it has a setup handler
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

-- Test tool basic configuration
T['tool has correct basic configuration'] = function()
  child.lua([[
    tool_info = {
      name = TreeOfThoughtsAgent.name,
      has_cmds = TreeOfThoughtsAgent.cmds ~= nil and #TreeOfThoughtsAgent.cmds > 0,
      has_schema = TreeOfThoughtsAgent.schema ~= nil
    }
  ]])

  local tool_info = child.lua_get('tool_info')

  h.eq('tree_of_thoughts_agent', tool_info.name)
  h.eq(true, tool_info.has_cmds)
  h.eq(true, tool_info.has_schema)
  -- System prompt removed for token efficiency
end

-- Test schema structure
T['tool schema has correct structure'] = function()
  child.lua([[
    schema = TreeOfThoughtsAgent.schema
    func_schema = schema['function']
    params = func_schema.parameters

    schema_info = {
      func_name = func_schema.name,
      has_description = func_schema.description ~= nil,
      has_action_param = params.properties.action ~= nil,
      has_content_param = params.properties.content ~= nil,
      has_type_param = params.properties.type ~= nil,
      has_parent_id_param = params.properties.parent_id ~= nil,
      action_required = vim.tbl_contains(params.required, 'action')
    }
  ]])

  local schema_info = child.lua_get('schema_info')

  h.eq('tree_of_thoughts_agent', schema_info.func_name)
  h.eq(true, schema_info.has_description)
  h.eq(true, schema_info.has_action_param)
  h.eq(true, schema_info.has_content_param)
  h.eq(true, schema_info.has_type_param)
  h.eq(true, schema_info.has_parent_id_param)
  h.eq(true, schema_info.action_required)
end

-- System prompt functionality moved to tool schema descriptions for token efficiency
T['tool description contains workflow guidance'] = function()
  child.lua([[
    schema = TreeOfThoughtsAgent.schema
    description = schema['function'].description

    description_info = {
      has_workflow = description and string.find(description, 'WORKFLOW') ~= nil,
      has_guidance = description and string.find(description, 'approach') ~= nil,
      is_comprehensive = description and #description > 100
    }
  ]])

  local description_info = child.lua_get('description_info')

  h.eq(true, description_info.has_workflow)
  h.eq(true, description_info.has_guidance)
  h.eq(true, description_info.is_comprehensive)
end

-- Test successful add_thought action
T['add_thought action works correctly'] = function()
  child.lua([[
    result = call_tool(TreeOfThoughtsAgent, {
      action = 'add_thought',
      content = 'Consider using microservices architecture'
    })

    thought_info = {
      status = result.status,
      has_data = result.data ~= nil,
      success_message = result.data and string.find(result.data, '.*:') ~= nil,
    }
  ]])

  local thought_info = child.lua_get('thought_info')

  h.eq('success', thought_info.status)
  h.eq(true, thought_info.has_data)
  h.eq(true, thought_info.success_message)
end

-- Test add_thought with specific type and parent
T['add_thought works with type and parent_id'] = function()
  child.lua([[
    -- Add root thought first
    root_result = call_tool(TreeOfThoughtsAgent, {
      action = 'add_thought',
      content = 'Root analysis: API design options'
    })

    -- Add child thought with specific type
    child_result = call_tool(TreeOfThoughtsAgent, {
      action = 'add_thought',
      content = 'Option 1: REST API with JSON',
      type = 'reasoning',
      parent_id = 'root'
    })

    parent_child_info = {
      root_success = root_result.status == 'success',
      child_success = child_result.status == 'success',
      child_has_node_id = child_result.data and string.find(child_result.data, 'Node ID:') ~= nil
    }
  ]])

  local parent_child_info = child.lua_get('parent_child_info')

  h.eq(true, parent_child_info.root_success)
  h.eq(true, parent_child_info.child_success)
  h.eq(true, parent_child_info.child_has_node_id)
end

-- Test add_thought with missing content
T['add_thought requires content'] = function()
  child.lua([[
    result = call_tool(TreeOfThoughtsAgent, {
      action = 'add_thought'
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

-- Test add_thought with empty content
T['add_thought fails with empty content'] = function()
  child.lua([[
    result = call_tool(TreeOfThoughtsAgent, {
      action = 'add_thought',
      content = ''
    })

    empty_content_info = {
      status = result.status,
      mentions_content = result.data and string.find(result.data, 'content') ~= nil
    }
  ]])

  local empty_content_info = child.lua_get('empty_content_info')

  h.eq('error', empty_content_info.status)
  h.eq(true, empty_content_info.mentions_content)
end

-- Test invalid action
T['invalid action returns error'] = function()
  child.lua([[
    result = call_tool(TreeOfThoughtsAgent, {
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

-- Test multiple thoughts building a tree
T['multiple thoughts create tree structure'] = function()
  child.lua([[

    -- Add root thought
    root = call_tool(TreeOfThoughtsAgent, {
      action = 'add_thought',
      content = 'Database design decisions'
    })

    -- Add first branch
    branch1 = call_tool(TreeOfThoughtsAgent, {
      action = 'add_thought',
      content = 'SQL database approach',
      type = 'reasoning',
      parent_id = 'root'
    })

    -- Add second branch
    branch2 = call_tool(TreeOfThoughtsAgent, {
      action = 'add_thought',
      content = 'NoSQL database approach',
      type = 'reasoning',
      parent_id = 'root'
    })

    -- Add sub-thought to first branch
    subbranch = call_tool(TreeOfThoughtsAgent, {
      action = 'add_thought',
      content = 'PostgreSQL with JSONB columns',
      type = 'task'
    })

    tree_info = {
      root_success = root.status == 'success',
      branch1_success = branch1.status == 'success',
      branch2_success = branch2.status == 'success',
      subbranch_success = subbranch.status == 'success'
    }
  ]])

  local tree_info = child.lua_get('tree_info')

  h.eq(true, tree_info.root_success)
  h.eq(true, tree_info.branch1_success)
  h.eq(true, tree_info.branch2_success)
  h.eq(true, tree_info.subbranch_success)
end

-- Test auto-initialization behavior
T['agent auto-initializes on first use'] = function()
  child.lua([[

    -- First call should auto-initialize and work
    result = call_tool(TreeOfThoughtsAgent, {
      action = 'add_thought',
      content = 'Auto-initialization test'
    })

    auto_init_info = {
      status = result.status,
      has_substantial_data = result.data ~= nil and #result.data > 50
    }
  ]])

  local auto_init_info = child.lua_get('auto_init_info')

  -- If auto-initialization worked, we should get success status and substantial response
  h.eq('success', auto_init_info.status)
  h.eq(true, auto_init_info.has_substantial_data)
end

-- Test node type handling
T['different node types are handled correctly'] = function()
  child.lua([[

    -- Test each node type
    analysis = call_tool(TreeOfThoughtsAgent, {
      action = 'add_thought',
      content = 'Analyze requirements',
      type = 'analysis'
    })

    reasoning = call_tool(TreeOfThoughtsAgent, {
      action = 'add_thought',
      content = 'Reason about approach',
      type = 'reasoning'
    })

    task = call_tool(TreeOfThoughtsAgent, {
      action = 'add_thought',
      content = 'Implement feature',
      type = 'task'
    })

    validation = call_tool(TreeOfThoughtsAgent, {
      action = 'add_thought',
      content = 'Validate implementation',
      type = 'validation'
    })

    node_types_info = {
      analysis_success = analysis.status == 'success',
      reasoning_success = reasoning.status == 'success',
      task_success = task.status == 'success',
      validation_success = validation.status == 'success'
    }
  ]])

  local node_types_info = child.lua_get('node_types_info')

  h.eq(true, node_types_info.analysis_success)
  h.eq(true, node_types_info.reasoning_success)
  h.eq(true, node_types_info.task_success)
  h.eq(true, node_types_info.validation_success)
end

return T
