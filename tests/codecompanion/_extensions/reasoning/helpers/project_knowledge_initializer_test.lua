-- filepath: tests/codecompanion/_extensions/reasoning/helpers/project_knowledge_initializer_test.lua
local MiniTest = require('mini.test')

local T = MiniTest.new_set()

T['module loads'] = function()
  local ok = pcall(require, 'codecompanion._extensions.reasoning.helpers.project_knowledge_initializer')
  MiniTest.expect.equality(ok, true)
end

return T
