-- filepath: tests/codecompanion/_extensions/reasoning/ui/session_manager_ui_test.lua
local MiniTest = require('mini.test')

local T = MiniTest.new_set()

T['session_manager_ui module loads'] = function()
  local ok, mod = pcall(require, 'codecompanion._extensions.reasoning.ui.session_manager_ui')
  MiniTest.expect.equality(ok, true)
  MiniTest.expect.equality(type(mod), 'table')
end

return T
