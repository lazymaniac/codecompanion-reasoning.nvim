-- filepath: tests/codecompanion/_extensions/reasoning/ui/popup_test.lua
local MiniTest = require('mini.test')

local T = MiniTest.new_set()

T['popup ui module loads'] = function()
  local ok, mod = pcall(require, 'codecompanion._extensions.reasoning.ui.popup')
  MiniTest.expect.equality(ok, true)
  MiniTest.expect.equality(type(mod), 'table')
end

return T
