-- filepath: tests/codecompanion/_extensions/reasoning/ui/pickers/init_test.lua
local MiniTest = require('mini.test')

local T = MiniTest.new_set()

T['pickers init module loads'] = function()
  local ok, mod = pcall(require, 'codecompanion._extensions.reasoning.ui.pickers')
  MiniTest.expect.equality(ok, true)
  MiniTest.expect.equality(type(mod), 'table')
end

return T
