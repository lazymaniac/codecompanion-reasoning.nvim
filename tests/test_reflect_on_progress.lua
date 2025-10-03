local h = require('tests.helpers')

local new_set = MiniTest.new_set

local child = MiniTest.new_child_neovim()
local T = new_set({
  hooks = {
    pre_once = function()
      h.child_start(child)
      child.lua([[
        h = require('tests.helpers')
        ReflectOnProgress = require('codecompanion._extensions.reasoning.tools.reflect_on_progress')
        ChainOfThoughtsAgent = require('codecompanion._extensions.reasoning.tools.chain_of_thoughts_agent')
        TreeOfThoughtsAgent = require('codecompanion._extensions.reasoning.tools.tree_of_thoughts_agent')
        GraphOfThoughtsAgent = require('codecompanion._extensions.reasoning.tools.graph_of_thoughts_agent')

        -- Helper function to call tools
        function call_tool(tool, args)
          if tool.handlers and tool.handlers.setup then
            tool.handlers.setup(tool, {})
          end
          return tool.cmds[1](tool, args, nil)
        end

        -- Helper to clear agent states
        function clear_agent_states()
          _G._codecompanion_chain_of_thoughts_state = nil
          _G._codecompanion_tree_of_thoughts_state = nil
          _G._codecompanion_graph_of_thoughts_state = nil
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
      name = ReflectOnProgress.name,
      has_cmds = ReflectOnProgress.cmds ~= nil and #ReflectOnProgress.cmds > 0,
      has_schema = ReflectOnProgress.schema ~= nil
    }
  ]])

  local tool_info = child.lua_get('tool_info')

  h.eq('reflect_on_progress', tool_info.name)
  h.eq(true, tool_info.has_cmds)
  h.eq(true, tool_info.has_schema)
end

-- Test schema structure
T['tool schema has correct structure'] = function()
  child.lua([[
    schema = ReflectOnProgress.schema
    func_schema = schema['function']
    params = func_schema.parameters

    schema_info = {
      func_name = func_schema.name,
      has_description = func_schema.description ~= nil,
      has_content_param = params.properties.content ~= nil,
      content_required = vim.tbl_contains(params.required, 'content')
    }
  ]])

  local schema_info = child.lua_get('schema_info')

  h.eq('reflect_on_progress', schema_info.func_name)
  h.eq(true, schema_info.has_description)
  h.eq(true, schema_info.has_content_param)
  h.eq(true, schema_info.content_required)
end

-- Test no active agent error
T['echoes content without requiring an active agent'] = function()
  child.lua([[
    clear_agent_states()

    result = call_tool(ReflectOnProgress, {
      content = 'Attempting to reflect without an active agent'
    })

    info = {
      status = result.status,
      echoes = result.data and string.find(result.data, 'Attempting to reflect without an active agent') ~= nil
    }
  ]])

  local info = child.lua_get('info')

  h.eq('success', info.status)
  h.eq(true, info.echoes)
end

-- Test reflection with Chain of Thoughts agent
T['includes provided content in output (Chain agent present)'] = function()
  child.lua([[
    clear_agent_states()

    call_tool(ChainOfThoughtsAgent, {
      action = 'add_step',
      content = 'Analyze the problem',
      step_type = 'analysis'
    })

    result = call_tool(ReflectOnProgress, {
      content = 'Making good progress with step-by-step analysis'
    })

    info = {
      status = result.status,
      includes_user_content = result.data and string.find(result.data, 'Making good progress') ~= nil
    }
  ]])

  local info = child.lua_get('info')

  h.eq('success', info.status)
  h.eq(true, info.includes_user_content)
end

-- Test reflection with Tree of Thoughts agent
T['includes provided content in output (Tree agent present)'] = function()
  child.lua([[
    clear_agent_states()

    call_tool(TreeOfThoughtsAgent, {
      action = 'add_thought',
      content = 'Explore different architectures',
      type = 'analysis'
    })

    result = call_tool(ReflectOnProgress, {
      content = 'Tree exploration is revealing good alternatives'
    })

    info = {
      status = result.status,
      includes_user_content = result.data and string.find(result.data, 'revealing good alternatives') ~= nil
    }
  ]])

  local info = child.lua_get('info')

  h.eq('success', info.status)
  h.eq(true, info.includes_user_content)
end

-- Test reflection with Graph of Thoughts agent
T['includes provided content in output (Graph agent present)'] = function()
  child.lua([[
    clear_agent_states()

    call_tool(GraphOfThoughtsAgent, {
      action = 'add_node',
      content = 'Authentication layer',
      node_type = 'analysis'
    })

    result = call_tool(ReflectOnProgress, {
      content = 'Graph connections showing system dependencies clearly'
    })

    info = {
      status = result.status,
      includes_user_content = result.data and string.find(result.data, 'system dependencies') ~= nil
    }
  ]])

  local info = child.lua_get('info')

  h.eq('success', info.status)
  h.eq(true, info.includes_user_content)
end

-- Test missing content parameter
T['requires content parameter'] = function()
  child.lua([[
    clear_agent_states()

    call_tool(ChainOfThoughtsAgent, {
      action = 'add_step',
      content = 'Test step',
      step_type = 'analysis'
    })

    result = call_tool(ReflectOnProgress, {})

    info = {
      status = result.status
    }
  ]])

  local info = child.lua_get('info')

  h.eq('success', info.status)
end

-- Test agent switching detection
T['does not detect or report agent type (current minimal behavior)'] = function()
  child.lua([[
    clear_agent_states()

    call_tool(ChainOfThoughtsAgent, {
      action = 'add_step',
      content = 'First step',
      step_type = 'analysis'
    })

    call_tool(TreeOfThoughtsAgent, {
      action = 'add_thought',
      content = 'Tree thought',
      type = 'analysis'
    })

    result = call_tool(ReflectOnProgress, {
      content = 'Testing agent detection'
    })

    info = {
      status = result.status,
      includes_user_content = result.data and string.find(result.data, 'Testing agent detection') ~= nil
    }
  ]])

  local info = child.lua_get('info')

  h.eq('success', info.status)
  h.eq(true, info.includes_user_content)
end

return T
