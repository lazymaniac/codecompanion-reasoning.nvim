-- Basic test to verify the extension loads correctly

local MiniTest = require('mini.test')
local expect = MiniTest.expect

local T = MiniTest.new_set({
  hooks = {
    pre_case = function()
      -- Reset any global state
    end,
  },
})

T['Extension loads'] = function()
  local ok, extension = pcall(require, 'codecompanion._extensions.reasoning')
  expect.equality(ok, true)
  expect.equality(type(extension.setup), 'function')
  expect.equality(type(extension.exports), 'table')
end

T['Main module loads'] = function()
  local ok, main = pcall(require, 'codecompanion-reasoning')
  expect.equality(ok, true)
  expect.equality(type(main.setup), 'function')
  expect.equality(type(main.get_tools), 'function')
end

T['Extension setup returns tools'] = function()
  local extension = require('codecompanion._extensions.reasoning')
  local result = extension.setup()
  expect.equality(type(result.tools), 'table')
  expect.equality(result.enabled, true)
end

return T
