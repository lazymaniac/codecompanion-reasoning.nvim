-- filepath: tests/codecompanion/_extensions/reasoning/tools/chain_of_thoughts_agent_test.lua
-- Moved from tests/reasoning/test_chain_of_thoughts_agent.lua
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
      name = ChainOfThoughtsAgent.name,
      has_cmds = ChainOfThoughtsAgent.cmds ~= nil and #ChainOfThoughtsAgent.cmds > 0,
      has_schema = ChainOfThoughtsAgent.schema ~= nil
    }
  ]])

  h.eq('chain_of_thoughts_agent', tool_info.name)
  h.eq(true, tool_info.has_cmds)
  h.eq(true, tool_info.has_schema)
end

T['tool schema has correct structure'] = function()
  local schema_info = child.lua([[
    local schema = ChainOfThoughtsAgent.schema
    local func_schema = schema['function']
    local params = func_schema.parameters

    return {
      func_name = func_schema.name,
      has_description = func_schema.description ~= nil,
      has_content_param = params.properties.content ~= nil,
      has_step_type_param = params.properties.step_type ~= nil
    }
  ]])

  h.eq('chain_of_thoughts_agent', schema_info.func_name)
  h.eq(true, schema_info.has_description)
  h.eq(true, schema_info.has_content_param)
  h.eq(true, schema_info.has_step_type_param)
end

T['tool description contains workflow guidance'] = function()
  local description_info = child.lua([[
    local schema = ChainOfThoughtsAgent.schema
    local description = schema['function'].description

    return {
      has_workflow = description and string.find(description, 'WORKFLOW') ~= nil,
      is_comprehensive = description and #description > 100
    }
  ]])

  h.eq(true, description_info.has_workflow)
  h.eq(true, description_info.is_comprehensive)
end

T['add_step action works correctly'] = function()
  local step_info = child.lua([[
    local result = call_tool(ChainOfThoughtsAgent, {
      action = 'add_step',
      content = 'Analyze the authentication flow',
      step_type = 'analysis'
    })

    return {
      status = result.status,
      has_data = result.data ~= nil,
      contains_step_type = result.data and string.find(result.data, 'analysis:') ~= nil,
      contains_content = result.data and string.find(result.data, 'Analyze the authentication flow') ~= nil
    }
  ]])

  h.eq('success', step_info.status)
  h.eq(true, step_info.has_data)
  h.eq(true, step_info.contains_step_type)
  h.eq(true, step_info.contains_content)
end

T['add_step requires content and step_type'] = function()
  local validation_info = child.lua([[
    local result_missing_content = call_tool(ChainOfThoughtsAgent, {
      action = 'add_step',
      step_type = 'analysis'
    })

    local result_missing_type = call_tool(ChainOfThoughtsAgent, {
      action = 'add_step',
      content = 'Test content'
    })

    return {
      missing_content_error = result_missing_content.status == 'error',
      missing_step_type_error = result_missing_type.status == 'error'
    }
  ]])

  h.eq(true, validation_info.missing_content_error)
  h.eq(true, validation_info.missing_step_type_error)
end

T['invalid action returns validation error (uses add_step validation)'] = function()
  local invalid_info = child.lua([[
    local result = call_tool(ChainOfThoughtsAgent, {
      action = 'invalid_action'
    })

    return {
      status = result.status,
    }
  ]])

  h.eq('error', invalid_info.status)
end

T['complete workflow: add multiple steps'] = function()
  local workflow_info = child.lua([[
    local step1 = call_tool(ChainOfThoughtsAgent, { action = 'add_step', content = 'Identify the problem', step_type = 'analysis' })
    local step2 = call_tool(ChainOfThoughtsAgent, { action = 'add_step', content = 'Design the solution', step_type = 'reasoning' })
    local step3 = call_tool(ChainOfThoughtsAgent, { action = 'add_step', content = 'Implement the fix', step_type = 'task' })

    return { step1_success = step1.status == 'success', step2_success = step2.status == 'success', step3_success = step3.status == 'success' }
  ]])
  h.eq(true, workflow_info.step1_success)
  h.eq(true, workflow_info.step2_success)
  h.eq(true, workflow_info.step3_success)
end

return T
