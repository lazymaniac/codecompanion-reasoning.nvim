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
        ReasoningAgentBase = require('codecompanion._extensions.reasoning.helpers.reasoning_agent_base')

        -- Mock the unified reasoning prompt for testing
        package.loaded['codecompanion._extensions.reasoning.helpers.unified_reasoning_prompt'] = {
          generate_for_reasoning = function(type)
            return string.format("Test system prompt for %s reasoning", type)
          end
        }

        -- Helper function to call the tool
        function call_tool(tool, args)
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
      has_schema = ChainOfThoughtsAgent.schema ~= nil,
      has_system_prompt = ChainOfThoughtsAgent.system_prompt ~= nil
    }
  ]])

  local tool_info = child.lua_get('tool_info')

  h.eq('chain_of_thoughts_agent', tool_info.name)
  h.eq(true, tool_info.has_cmds)
  h.eq(true, tool_info.has_schema)
  h.eq(true, tool_info.has_system_prompt)
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
      has_step_id_param = params.properties.step_id ~= nil,
      has_content_param = params.properties.content ~= nil,
      has_step_type_param = params.properties.step_type ~= nil,
      action_required = vim.tbl_contains(params.required, 'action')
    }
  ]])

  local schema_info = child.lua_get('schema_info')

  h.eq('chain_of_thoughts_agent', schema_info.func_name)
  h.eq(true, schema_info.has_description)
  h.eq(true, schema_info.has_action_param)
  h.eq(true, schema_info.has_step_id_param)
  h.eq(true, schema_info.has_content_param)
  h.eq(true, schema_info.has_step_type_param)
  h.eq(true, schema_info.action_required)
end

-- Test system prompt function
T['system prompt function works'] = function()
  child.lua([[
    prompt_result = ChainOfThoughtsAgent.system_prompt()

    prompt_info = {
      is_string = type(prompt_result) == 'string',
      has_content = prompt_result and #prompt_result > 0,
      contains_chain = prompt_result and string.find(prompt_result, 'chain') ~= nil
    }
  ]])

  local prompt_info = child.lua_get('prompt_info')

  h.eq(true, prompt_info.is_string)
  h.eq(true, prompt_info.has_content)
  h.eq(true, prompt_info.contains_chain)
end

-- Test successful add_step action
T['add_step action works correctly'] = function()
  child.lua([[
    result = call_tool(ChainOfThoughtsAgent, {
      action = 'add_step',
      step_id = 'step1',
      content = 'Analyze the authentication flow',
      step_type = 'analysis',
      reasoning = 'Need to understand current auth before making changes'
    })

    step_info = {
      status = result.status,
      has_data = result.data ~= nil,
      success_message = result.data and string.find(result.data, 'Added step') ~= nil,
      next_instruction = result.data and string.find(result.data, 'NEXT:') ~= nil
    }
  ]])

  local step_info = child.lua_get('step_info')

  h.eq('success', step_info.status)
  h.eq(true, step_info.has_data)
  h.eq(true, step_info.success_message)
  h.eq(true, step_info.next_instruction)
end

-- Test add_step with missing required parameters
T['add_step requires step_id, content, and step_type'] = function()
  child.lua([[
    -- Missing step_id
    result1 = call_tool(ChainOfThoughtsAgent, {
      action = 'add_step',
      content = 'Test content',
      step_type = 'analysis'
    })

    -- Missing content
    result2 = call_tool(ChainOfThoughtsAgent, {
      action = 'add_step',
      step_id = 'step1',
      step_type = 'analysis'
    })

    -- Missing step_type
    result3 = call_tool(ChainOfThoughtsAgent, {
      action = 'add_step',
      step_id = 'step1',
      content = 'Test content'
    })

    validation_info = {
      missing_step_id_error = result1.status == 'error',
      missing_content_error = result2.status == 'error',
      missing_step_type_error = result3.status == 'error'
    }
  ]])

  local validation_info = child.lua_get('validation_info')

  h.eq(true, validation_info.missing_step_id_error)
  h.eq(true, validation_info.missing_content_error)
  h.eq(true, validation_info.missing_step_type_error)
end

-- Test duplicate step_id handling
T['add_step prevents duplicate step IDs'] = function()
  child.lua([[
    -- Add first step
    result1 = call_tool(ChainOfThoughtsAgent, {
      action = 'add_step',
      step_id = 'duplicate_test',
      content = 'First step',
      step_type = 'analysis'
    })

    -- Try to add step with same ID
    result2 = call_tool(ChainOfThoughtsAgent, {
      action = 'add_step',
      step_id = 'duplicate_test',
      content = 'Second step',
      step_type = 'reasoning'
    })

    duplicate_info = {
      first_success = result1.status == 'success',
      second_error = result2.status == 'error',
      error_mentions_duplicate = result2.data and string.find(result2.data, 'already exists') ~= nil
    }
  ]])

  local duplicate_info = child.lua_get('duplicate_info')

  h.eq(true, duplicate_info.first_success)
  h.eq(true, duplicate_info.second_error)
  h.eq(true, duplicate_info.error_mentions_duplicate)
end

-- Test reflect action
T['reflect action works with existing steps'] = function()
  child.lua([[
    -- Add a step first
    call_tool(ChainOfThoughtsAgent, {
      action = 'add_step',
      step_id = 'reflect_test',
      content = 'Test step for reflection',
      step_type = 'analysis'
    })

    -- Then reflect
    result = call_tool(ChainOfThoughtsAgent, {
      action = 'reflect',
      reflection = 'This approach seems to be working well'
    })

    reflect_info = {
      status = result.status,
      has_analysis = result.data and string.find(result.data, 'Reflection Analysis') ~= nil,
      has_total_steps = result.data and string.find(result.data, 'Total steps:') ~= nil,
      has_user_reflection = result.data and string.find(result.data, 'User Reflection:') ~= nil
    }
  ]])

  local reflect_info = child.lua_get('reflect_info')

  h.eq('success', reflect_info.status)
  h.eq(true, reflect_info.has_analysis)
  h.eq(true, reflect_info.has_total_steps)
  h.eq(true, reflect_info.has_user_reflection)
end

-- Test reflect action behaves correctly
T['reflect action behaves correctly'] = function()
  child.lua([[
    result = call_tool(ChainOfThoughtsAgent, {
      action = 'reflect'
    })

    reflect_info = {
      status = result.status,
      has_data = result.data ~= nil,
      mentions_no_steps = result.data and string.find(result.data, 'No steps') ~= nil,
      has_reflection = result.data and string.find(result.data, 'Reflection Analysis') ~= nil
    }
  ]])

  local reflect_info = child.lua_get('reflect_info')

  -- Either it succeeds with reflection analysis OR fails with "no steps" message
  h.eq(true, reflect_info.has_data)
  if reflect_info.status == 'error' then
    h.eq(true, reflect_info.mentions_no_steps)
  else
    h.eq('success', reflect_info.status)
    h.eq(true, reflect_info.has_reflection)
  end
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
      step_id = 'workflow_step1',
      content = 'Identify the problem',
      step_type = 'analysis'
    })

    step2 = call_tool(ChainOfThoughtsAgent, {
      action = 'add_step',
      step_id = 'workflow_step2',
      content = 'Design the solution',
      step_type = 'reasoning'
    })

    step3 = call_tool(ChainOfThoughtsAgent, {
      action = 'add_step',
      step_id = 'workflow_step3',
      content = 'Implement the fix',
      step_type = 'task'
    })

    -- Reflect on the process
    reflection = call_tool(ChainOfThoughtsAgent, {
      action = 'reflect',
      reflection = 'The step-by-step approach worked well'
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

