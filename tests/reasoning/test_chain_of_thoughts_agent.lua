local h = require('tests.helpers')

local new_set = MiniTest.new_set

local child = MiniTest.new_child_neovim()
local T = new_set({
  hooks = {
    pre_once = function()
      h.child_start(child)
      child.lua([[
        h = require('tests.helpers')
        ChainOfThoughtsAgent = require('codecompanion._extensions.reasoning.tools.chain_of_thoughts_agent')

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
      name = ChainOfThoughtsAgent.name,
      has_cmds = ChainOfThoughtsAgent.cmds ~= nil and #ChainOfThoughtsAgent.cmds > 0,
      has_schema = ChainOfThoughtsAgent.schema ~= nil
    }
  ]])

  local tool_info = child.lua_get('tool_info')

  h.eq('chain_of_thoughts_agent', tool_info.name)
  h.eq(true, tool_info.has_cmds)
  h.eq(true, tool_info.has_schema)
  -- System prompt removed for token efficiency
end

-- Test schema structure
T['tool schema has correct structure'] = function()
  child.lua([[
    schema = ChainOfThoughtsAgent.schema
    func_schema = schema['function']
    params = func_schema.parameters

    schema_info = {
      func_name = func_schema.name,
      has_description = func_schema.description ~= nil,
      has_action_param = params.properties.action ~= nil,
      has_content_param = params.properties.content ~= nil,
      has_step_type_param = params.properties.step_type ~= nil,
      action_required = vim.tbl_contains(params.required, 'action')
    }
  ]])

  local schema_info = child.lua_get('schema_info')

  h.eq('chain_of_thoughts_agent', schema_info.func_name)
  h.eq(true, schema_info.has_description)
  h.eq(true, schema_info.has_action_param)
  h.eq(true, schema_info.has_content_param)
  h.eq(true, schema_info.has_step_type_param)
  h.eq(true, schema_info.action_required)
end

T['tool description contains workflow guidance'] = function()
  child.lua([[
    schema = ChainOfThoughtsAgent.schema
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

-- Test successful add_step action
T['add_step action works correctly'] = function()
  child.lua([[
    result = call_tool(ChainOfThoughtsAgent, {
      action = 'add_step',
      content = 'Analyze the authentication flow',
      step_type = 'analysis'
    })

    step_info = {
      status = result.status,
      has_data = result.data ~= nil,
      contains_step_type = result.data and string.find(result.data, 'analysis:') ~= nil,
      contains_content = result.data and string.find(result.data, 'Analyze the authentication flow') ~= nil
    }
  ]])

  local step_info = child.lua_get('step_info')

  h.eq('success', step_info.status)
  h.eq(true, step_info.has_data)
  h.eq(true, step_info.contains_step_type)
  h.eq(true, step_info.contains_content)
end

-- Test add_step with missing required parameters
T['add_step requires content and step_type'] = function()
  child.lua([[
    -- Missing content
    result_missing_content = call_tool(ChainOfThoughtsAgent, {
      action = 'add_step',
      step_type = 'analysis'
    })

    -- Missing step_type
    result_missing_type = call_tool(ChainOfThoughtsAgent, {
      action = 'add_step',
      content = 'Test content'
    })

    validation_info = {
      missing_content_error = result_missing_content.status == 'error',
      missing_step_type_error = result_missing_type.status == 'error'
    }
  ]])

  local validation_info = child.lua_get('validation_info')

  h.eq(true, validation_info.missing_content_error)
  h.eq(true, validation_info.missing_step_type_error)
end

-- Test reflect action
T['reflect action works with existing steps'] = function()
  child.lua([[
    -- Add a step first
    call_tool(ChainOfThoughtsAgent, {
      action = 'add_step',
      content = 'Test step for reflection',
      step_type = 'analysis'
    })

    -- Then reflect
    result = call_tool(ChainOfThoughtsAgent, {
      action = 'reflect',
      content = 'This approach seems to be working well'
    })

    reflect_info = {
      status = result.status,
      has_analysis = result.data and string.find(result.data, 'Reflection Analysis') ~= nil,
      has_total_steps = result.data and string.find(result.data, 'Total steps:') ~= nil,
      has_user_reflection = result.data and string.find(result.data, 'Reflection:') ~= nil
    }
  ]])

  local reflect_info = child.lua_get('reflect_info')

  h.eq('success', reflect_info.status)
  h.eq(true, reflect_info.has_analysis)
  h.eq(true, reflect_info.has_total_steps)
  h.eq(true, reflect_info.has_user_reflection)
end

-- Test reflect action requires content parameter
T['reflect action requires content parameter'] = function()
  child.lua([[
    result = call_tool(ChainOfThoughtsAgent, {
      action = 'reflect'
    })

    reflect_info = {
      status = result.status,
      has_error_message = result.data and string.find(result.data, 'content is required') ~= nil
    }
  ]])

  local reflect_info = child.lua_get('reflect_info')

  h.eq('error', reflect_info.status)
  h.eq(true, reflect_info.has_error_message)
end

-- Test invalid action
T['invalid action returns error'] = function()
  child.lua([[
    result = call_tool(ChainOfThoughtsAgent, {
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

-- Test complete workflow
T['complete workflow: add steps and reflect'] = function()
  child.lua([[
    -- Add multiple steps
    step1 = call_tool(ChainOfThoughtsAgent, {
      action = 'add_step',
      content = 'Identify the problem',
      step_type = 'analysis'
    })

    step2 = call_tool(ChainOfThoughtsAgent, {
      action = 'add_step',
      content = 'Design the solution',
      step_type = 'reasoning'
    })

    step3 = call_tool(ChainOfThoughtsAgent, {
      action = 'add_step',
      content = 'Implement the fix',
      step_type = 'task'
    })

    -- Reflect on the process
    reflection = call_tool(ChainOfThoughtsAgent, {
      action = 'reflect',
      content = 'The step-by-step approach worked well'
    })

    workflow_info = {
      step1_success = step1.status == 'success',
      step2_success = step2.status == 'success',
      step3_success = step3.status == 'success',
      reflection_success = reflection.status == 'success',
      reflection_shows_steps = reflection.data and string.find(reflection.data, 'Total steps:') ~= nil
    }
  ]])

  local workflow_info = child.lua_get('workflow_info')

  h.eq(true, workflow_info.step1_success)
  h.eq(true, workflow_info.step2_success)
  h.eq(true, workflow_info.step3_success)
  h.eq(true, workflow_info.reflection_success)
  h.eq(true, workflow_info.reflection_shows_steps)
end

return T
