-- filepath: tests/codecompanion/_extensions/reasoning/helpers/chat_hooks_test.lua
local MiniTest = require('mini.test')

local T = MiniTest.new_set()

T['module loads'] = function()
  local ok, mod = pcall(require, 'codecompanion._extensions.reasoning.helpers.chat_hooks')
  MiniTest.expect.equality(ok, true)
  MiniTest.expect.equality(type(mod), 'table')
end

return T
