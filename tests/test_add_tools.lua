local h = require('tests.helpers')

local new_set = MiniTest.new_set

local AddTools
local ToolCatalog

local function setup_stubs()
  package.loaded['codecompanion.config'] = {
    strategies = {
      chat = {
        tools = {
          ask_user = { description = 'Ask user for input' },
          add_tools = { description = 'Add tools to chat' },
          chain_of_thoughts_agent = { description = 'Chain reasoning agent' },
          tree_of_thoughts_agent = { description = 'Tree reasoning agent' },
          graph_of_thoughts_agent = { description = 'Graph reasoning agent' },
          meta_agent = { description = 'Meta reasoning' },
          some_other_tool = { description = 'Some other useful tool' },
          opts = { some_option = true },
          groups = { some_group = {} },
        },
      },
    },
  }

  package.loaded['codecompanion.strategies.chat.tools.tool_filter'] = {
    filter_enabled_tools = function(tools)
      local enabled = {}
      for name, _ in pairs(tools) do
        if name ~= 'opts' and name ~= 'groups' then
          enabled[name] = true
        end
      end
      return enabled
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

  package.loaded['codecompanion._extensions.reasoning.helpers.tool_catalog'] = nil
  package.loaded['codecompanion._extensions.reasoning.tools.add_tools'] = nil

  ToolCatalog = require('codecompanion._extensions.reasoning.helpers.tool_catalog')
  AddTools = require('codecompanion._extensions.reasoning.tools.add_tools')
end

local T = new_set({
  hooks = {
    pre_once = setup_stubs,
  },
})

T['available tools helper excludes reasoning agents and companion tools'] = function()
  local markdown = ToolCatalog.build_available_tools_markdown()

  h.eq(true, type(markdown) == 'string')
  h.eq(false, string.find(markdown, 'ask_user', 1, true) ~= nil)
  h.eq(false, string.find(markdown, 'add_tools', 1, true) ~= nil)
  h.eq(false, string.find(markdown, 'chain_of_thoughts_agent', 1, true) ~= nil)
  h.eq(false, string.find(markdown, 'tree_of_thoughts_agent', 1, true) ~= nil)
  h.eq(false, string.find(markdown, 'graph_of_thoughts_agent', 1, true) ~= nil)
  h.eq(false, string.find(markdown, 'meta_agent', 1, true) ~= nil)
  h.eq(true, string.find(markdown, 'some_other_tool', 1, true) ~= nil)
end

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
