-- filepath: tests/codecompanion/_extensions/reasoning/tools/add_tools_test.lua
-- Extracted from tests/test_add_tools.lua (add_tools part)
local h = require('tests.helpers')
local new_set = MiniTest.new_set

local AddTools

local function setup_stubs()
  package.loaded['codecompanion.config'] = {
    strategies = { chat = { tools = {} } },
  }

  package.loaded['codecompanion.strategies.chat.tools.tool_filter'] = {
    filter_enabled_tools = function(tools)
      return {}
    end,
  }

  package.loaded['codecompanion.strategies.chat.tools.init'] = {
    get_tools = function()
      return {}
    end,
    resolve = function()
      return nil
    end,
  }

  package.loaded['codecompanion._extensions.reasoning.tools.add_tools'] = nil
  AddTools = require('codecompanion._extensions.reasoning.tools.add_tools')
end

local T = new_set({ hooks = { pre_once = setup_stubs } })

T['add_tool rejects reasoning agents'] = function()
  local chain_result = AddTools.cmds[1](AddTools, { tool_name = 'chain_of_thoughts_agent' }, nil)
  local tree_result = AddTools.cmds[1](AddTools, { tool_name = 'tree_of_thoughts_agent' }, nil)
  local graph_result = AddTools.cmds[1](AddTools, { tool_name = 'graph_of_thoughts_agent' }, nil)
  local meta_result = AddTools.cmds[1](AddTools, { tool_name = 'meta_agent' }, nil)

  h.eq('error', chain_result.status)
  h.eq('error', tree_result.status)
  h.eq('error', graph_result.status)
  h.eq('error', meta_result.status)

  h.expect_contains('reasoning agent', chain_result.data)
  h.expect_contains('reasoning agent', tree_result.data)
  h.expect_contains('reasoning agent', graph_result.data)
  h.expect_contains('reasoning agent', meta_result.data)
end

T['add_tool rejects companion tools'] = function()
  local ask_user_result = AddTools.cmds[1](AddTools, { tool_name = 'ask_user' }, nil)
  local add_tools_result = AddTools.cmds[1](AddTools, { tool_name = 'add_tools' }, nil)

  h.eq('error', ask_user_result.status)
  h.eq('error', add_tools_result.status)

  h.expect_contains('automatically added', ask_user_result.data)
  h.expect_contains('automatically added', add_tools_result.data)
end

return T
