local h = require('tests.helpers')

local new_set = MiniTest.new_set

local child = MiniTest.new_child_neovim()
local T = new_set({
  hooks = {
    pre_once = function()
      h.child_start(child)
      child.lua([[
        h = require('tests.helpers')

        -- Mock CodeCompanion config with reasoning tools
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
                groups = { some_group = {} }
              }
            }
          }
        }

        -- Mock ToolFilter
        package.loaded['codecompanion.strategies.chat.tools.tool_filter'] = {
          filter_enabled_tools = function(tools)
            local enabled = {}
            for name, _ in pairs(tools) do
              if name ~= 'opts' and name ~= 'groups' then
                enabled[name] = true
              end
            end
            return enabled
          end
        }

        -- Mock Tools
        package.loaded['codecompanion.strategies.chat.tools.init'] = {
          get_tools = function() return {} end,
          resolve = function(config) return nil end
        }
      ]])
    end,
    post_once = child.stop,
  },
})

-- Test add_tools filtering
T['add_tools excludes reasoning agents and companion tools'] = function()
  child.lua([[
    AddTools = require('codecompanion._extensions.reasoning.tools.add_tools')

    -- Test list_tools action
    result = AddTools.cmds[1](AddTools, {action = 'list_tools'}, nil)

    tool_list_info = {
      status = result.status,
      contains_ask_user = string.find(result.data, 'ask_user') ~= nil,
      contains_add_tools = string.find(result.data, '✓ %*%*add_tools%*%*:') ~= nil,
      contains_chain_agent = string.find(result.data, 'chain_of_thoughts_agent') ~= nil,
      contains_tree_agent = string.find(result.data, 'tree_of_thoughts_agent') ~= nil,
      contains_graph_agent = string.find(result.data, 'graph_of_thoughts_agent') ~= nil,
      contains_meta_governor = string.find(result.data, 'meta_agent') ~= nil,
      contains_other_tool = string.find(result.data, 'some_other_tool') ~= nil
    }
  ]])

  local tool_list_info = child.lua_get('tool_list_info')

  h.eq('success', tool_list_info.status)
  h.eq(false, tool_list_info.contains_ask_user)
  h.eq(false, tool_list_info.contains_add_tools)
  h.eq(false, tool_list_info.contains_chain_agent)
  h.eq(false, tool_list_info.contains_tree_agent)
  h.eq(false, tool_list_info.contains_graph_agent)
  h.eq(false, tool_list_info.contains_meta_governor)
  h.eq(true, tool_list_info.contains_other_tool)
end

-- Test add_tool rejection for excluded tools
T['add_tool rejects reasoning agents'] = function()
  child.lua([[
    AddTools = require('codecompanion._extensions.reasoning.tools.add_tools')

    chain_result = AddTools.cmds[1](AddTools, {action = 'add_tool', tool_name = 'chain_of_thoughts_agent'}, nil)
    tree_result = AddTools.cmds[1](AddTools, {action = 'add_tool', tool_name = 'tree_of_thoughts_agent'}, nil)
    graph_result = AddTools.cmds[1](AddTools, {action = 'add_tool', tool_name = 'graph_of_thoughts_agent'}, nil)
    meta_result = AddTools.cmds[1](AddTools, {action = 'add_tool', tool_name = 'meta_agent'}, nil)

    rejection_info = {
      chain_status = chain_result.status,
      tree_status = tree_result.status,
      graph_status = graph_result.status,
      meta_status = meta_result.status,
      chain_message = chain_result.data,
      tree_message = tree_result.data,
      graph_message = graph_result.data,
      meta_message = meta_result.data
    }
  ]])

  local rejection_info = child.lua_get('rejection_info')

  h.eq('error', rejection_info.chain_status)
  h.eq('error', rejection_info.tree_status)
  h.eq('error', rejection_info.graph_status)
  h.eq('error', rejection_info.meta_status)

  h.expect_contains('reasoning agent', rejection_info.chain_message)
  h.expect_contains('reasoning agent', rejection_info.tree_message)
  h.expect_contains('reasoning agent', rejection_info.graph_message)
  h.expect_contains('reasoning agent', rejection_info.meta_message)
end

T['add_tool rejects companion tools'] = function()
  child.lua([[
    AddTools = require('codecompanion._extensions.reasoning.tools.add_tools')

    ask_user_result = AddTools.cmds[1](AddTools, {action = 'add_tool', tool_name = 'ask_user'}, nil)
    add_tools_result = AddTools.cmds[1](AddTools, {action = 'add_tool', tool_name = 'add_tools'}, nil)

    companion_rejection_info = {
      ask_user_status = ask_user_result.status,
      add_tools_status = add_tools_result.status,
      ask_user_message = ask_user_result.data,
      add_tools_message = add_tools_result.data
    }
  ]])

  local companion_rejection_info = child.lua_get('companion_rejection_info')

  h.eq('error', companion_rejection_info.ask_user_status)
  h.eq('error', companion_rejection_info.add_tools_status)

  h.expect_contains('automatically added', companion_rejection_info.ask_user_message)
  h.expect_contains('automatically added', companion_rejection_info.add_tools_message)
end

return T
