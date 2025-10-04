-- filepath: tests/codecompanion/_extensions/reasoning/tools/reflect_on_progress_test.lua
-- Moved from tests/test_reflect_on_progress.lua
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
        function call_tool(tool, args)
          if tool.handlers and tool.handlers.setup then
            tool.handlers.setup(tool, {})
          end
          return tool.cmds[1](tool, args, nil)
        end
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

T['tool has correct basic configuration'] = function()
  local tool_info = child.lua([[
    return { name = ReflectOnProgress.name, has_cmds = ReflectOnProgress.cmds ~= nil and #ReflectOnProgress.cmds > 0, has_schema = ReflectOnProgress.schema ~= nil }
  ]])
  h.eq('reflect_on_progress', tool_info.name)
  h.eq(true, tool_info.has_cmds)
  h.eq(true, tool_info.has_schema)
end

T['tool schema has correct structure'] = function()
  local schema_info = child.lua([[
    local schema = ReflectOnProgress.schema
    local func_schema = schema['function']
    local params = func_schema.parameters
    return { func_name = func_schema.name, has_description = func_schema.description ~= nil, has_content_param = params.properties.content ~= nil, content_required = vim.tbl_contains(params.required, 'content') }
  ]])
  h.eq('reflect_on_progress', schema_info.func_name)
  h.eq(true, schema_info.has_description)
  h.eq(true, schema_info.has_content_param)
  h.eq(true, schema_info.content_required)
end

T['echoes content without an active agent'] = function()
  local info = child.lua([[
    clear_agent_states()
    local result = call_tool(ReflectOnProgress, { content = 'Attempting to reflect without an active agent' })
    return { status = result.status, echoes = result.data and string.find(result.data, 'Attempting to reflect without an active agent') ~= nil }
  ]])
  h.eq('success', info.status)
  h.eq(true, info.echoes)
end

return T
