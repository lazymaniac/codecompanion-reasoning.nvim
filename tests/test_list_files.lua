local h = require('tests.helpers')

local new_set = MiniTest.new_set
local child = MiniTest.new_child_neovim()

local T = new_set({
  hooks = {
    pre_once = function()
      h.child_start(child)
      child.lua([[ h = require('tests.helpers') ]])
    end,
    post_once = child.stop,
  },
})

T['list_files basic listing'] = function()
  child.lua([[
    local Tool = require('codecompanion._extensions.reasoning.tools.list_files')
    local dir = 'lua/codecompanion/_extensions/reasoning/tools'
    local res = Tool.cmds[1](Tool, { dir = dir }, nil)
    result = { status = res.status, data = res.data }
  ]])

  local res = child.lua_get('result')
  h.eq('success', res.status)
  h.expect_contains('meta_agent.lua', res.data)
  h.expect_contains('edit_file.lua', res.data)
end

T['list_files with glob filter'] = function()
  child.lua([[
    local Tool = require('codecompanion._extensions.reasoning.tools.list_files')
    local dir = 'lua/codecompanion/_extensions/reasoning/tools'
    local res = Tool.cmds[1](Tool, { dir = dir, glob = '*agent*.lua' }, nil)
    result_glob = { status = res.status, data = res.data }
  ]])

  local res = child.lua_get('result_glob')
  h.eq('success', res.status)
  h.expect_contains('meta_agent.lua', res.data)
  h.expect_no_match('edit_file.lua', res.data)
end

T['list_files max_results limit'] = function()
  -- removed: tool no longer exposes max_results parameter
end

T['list_files refuses outside root'] = function()
  child.lua([[
    local Tool = require('codecompanion._extensions.reasoning.tools.list_files')
    local res = Tool.cmds[1](Tool, { dir = '../../' }, nil)
    result_outside = { status = res.status, data = res.data }
  ]])

  local res = child.lua_get('result_outside')
  h.eq('error', res.status)
  h.expect_contains('Refusing to list outside project root', res.data)
end

return T
