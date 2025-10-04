-- filepath: tests/codecompanion/_extensions/reasoning/tools/list_files_test.lua
-- Moved from tests/test_list_files.lua
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
  local res = child.lua([[
    local Tool = require('codecompanion._extensions.reasoning.tools.list_files')
    local dir = 'lua/codecompanion/_extensions/reasoning/tools'
    local result = Tool.cmds[1](Tool, { dir = dir }, nil)
    return { status = result.status, data = result.data }
  ]])
  h.eq('success', res.status)
  h.expect_contains('meta_agent.lua', res.data)
  h.expect_contains('list_files.lua', res.data)
end

T['list_files with glob filter'] = function()
  local res = child.lua([[
    local Tool = require('codecompanion._extensions.reasoning.tools.list_files')
    local dir = 'lua/codecompanion/_extensions/reasoning/tools'
    local result = Tool.cmds[1](Tool, { dir = dir, glob = '*agent*.lua' }, nil)
    return { status = result.status, data = result.data }
  ]])
  h.eq('success', res.status)
  h.expect_contains('meta_agent.lua', res.data)
  h.expect_no_match('edit_file.lua', res.data)
end

T['list_files refuses outside root'] = function()
  local res = child.lua([[
    local Tool = require('codecompanion._extensions.reasoning.tools.list_files')
    local result = Tool.cmds[1](Tool, { dir = '../../' }, nil)
    return { status = result.status, data = result.data }
  ]])
  h.eq('error', res.status)
  h.expect_contains('Refusing to list outside project root', res.data)
end

T['list_files no-args uses gitignore'] = function()
  local res = child.lua([[
    local Tool = require('codecompanion._extensions.reasoning.tools.list_files')
    local result = Tool.cmds[1](Tool, nil, nil)
    return { status = result.status, data = result.data }
  ]])

  h.eq('success', res.status)
  h.expect_contains('Project root:', res.data)
  h.expect_contains('\nBase:', res.data)
end

T['list_files args also respect gitignore'] = function()
  local res = child.lua([[
    local Tool = require('codecompanion._extensions.reasoning.tools.list_files')
    local result = Tool.cmds[1](Tool, { dir = '.', glob = 'prompts/*' }, nil)
    return { status = result.status, data = result.data }
  ]])

  h.eq('success', res.status)
  h.expect_contains('Results: 0', res.data)
end

return T
