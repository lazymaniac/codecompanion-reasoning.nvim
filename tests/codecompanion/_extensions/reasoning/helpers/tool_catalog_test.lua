-- filepath: tests/codecompanion/_extensions/reasoning/helpers/tool_catalog_test.lua
-- Extracted from tests/test_add_tools.lua (tool catalog part)
local h = require('tests.helpers')
local new_set = MiniTest.new_set

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

  package.loaded['codecompanion._extensions.reasoning.helpers.tool_catalog'] = nil
  ToolCatalog = require('codecompanion._extensions.reasoning.helpers.tool_catalog')
end

local T = new_set({ hooks = { pre_once = setup_stubs } })

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

return T
