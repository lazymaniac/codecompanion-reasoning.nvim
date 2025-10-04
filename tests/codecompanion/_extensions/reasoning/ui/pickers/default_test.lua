-- filepath: tests/codecompanion/_extensions/reasoning/ui/pickers/default_test.lua
local MiniTest = require('mini.test')

local T = MiniTest.new_set()

T['default picker module loads'] = function()
  local ok, mod = pcall(require, 'codecompanion._extensions.reasoning.ui.pickers.default')
  MiniTest.expect.equality(ok, true)
  MiniTest.expect.equality(type(mod), 'table')
end

return T
