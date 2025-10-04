-- filepath: tests/codecompanion/_extensions/reasoning/init_test.lua
-- Covers extension init and registration
local MiniTest = require('mini.test')
local expect = MiniTest.expect

local T = MiniTest.new_set()

T['Extension loads'] = function()
  local ok, extension = pcall(require, 'codecompanion._extensions.reasoning')
  expect.equality(ok, true)
  expect.equality(type(extension.setup), 'function')
  expect.equality(type(extension.exports), 'table')
end

T['Extension setup returns tools and registers into CodeCompanion config'] = function()
  local original_config = package.loaded['codecompanion.config']
  local mock_config = { strategies = { chat = { tools = {} } }, opts = {} }
  package.loaded['codecompanion.config'] = mock_config

  local extension = require('codecompanion._extensions.reasoning')
  local result = extension.setup()
  expect.equality(type(result.tools), 'table')
  expect.equality(result.tools ~= nil and next(result.tools) ~= nil, true)

  local tools = mock_config.strategies.chat.tools
  expect.no_equality(tools.meta_agent, nil)
  expect.no_equality(tools.add_tools, nil)
  expect.no_equality(tools.project_knowledge, nil)

  package.loaded['codecompanion.config'] = original_config
end

return T
