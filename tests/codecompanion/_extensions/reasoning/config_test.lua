-- filepath: tests/codecompanion/_extensions/reasoning/config_test.lua
local MiniTest = require('mini.test')

local T = MiniTest.new_set()

T['Config.setup and get work'] = function()
  local Config = require('codecompanion._extensions.reasoning.config')
  Config.setup({ session_history = { continue_last_session = false } })
  local cfg = Config.get()
  MiniTest.expect.equality(type(cfg), 'table')
  MiniTest.expect.equality(cfg.session_history.continue_last_session, false)
end

return T
