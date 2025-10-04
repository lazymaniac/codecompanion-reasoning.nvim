-- filepath: tests/codecompanion/_extensions/reasoning/tools/meta_agent_test.lua
local MiniTest = require('mini.test')

local T = MiniTest.new_set()

T['meta_agent loads and exposes schema'] = function()
  local ok, mod = pcall(require, 'codecompanion._extensions.reasoning.tools.meta_agent')
  MiniTest.expect.equality(ok, true)
  MiniTest.expect.equality(type(mod), 'table')
  MiniTest.expect.equality(type(mod.schema), 'table')
end

return T
