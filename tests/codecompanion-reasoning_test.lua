-- filepath: tests/codecompanion-reasoning_test.lua
-- Covers top-level main module
local MiniTest = require('mini.test')
local expect = MiniTest.expect

local T = MiniTest.new_set()

T['Main module loads'] = function()
  local ok, main = pcall(require, 'codecompanion-reasoning')
  expect.equality(ok, true)
  expect.equality(type(main.setup), 'function')
  expect.equality(type(main.get_tools), 'function')
end

T['Direct API functions work'] = function()
  local SessionManager = require('codecompanion._extensions.reasoning.helpers.session_manager')
  local ReasoningPlugin = require('codecompanion-reasoning')
  local Config = require('codecompanion._extensions.reasoning.config')
  local helpers = require('tests.helpers')

  local tmp_dir = vim.fn.tempname() .. '_chat_sessions'
  vim.fn.delete(tmp_dir, 'rf')
  vim.fn.mkdir(tmp_dir, 'p')

  Config.setup({
    session_history = {
      sessions_dir = tmp_dir,
      continue_last_session = false,
      auto_save = true,
      auto_generate_title = true,
    },
  })
  SessionManager.setup()

  local function create_mock_chat()
    return {
      id = 'test_chat_' .. tostring(math.random(1000, 9999)),
      adapter = { name = 'openai' },
      model = 'gpt-4',
      messages = {
        { role = 'user', content = 'Hello, can you help me with some code?', timestamp = helpers.timestamp(-100) },
        {
          role = 'assistant',
          content = "Of course! I'd be happy to help you with your code. What do you need assistance with?",
          timestamp = helpers.timestamp(-50),
        },
        { role = 'user', content = 'I need to implement a binary search function.', timestamp = helpers.timestamp() },
      },
      tools = { 'add_tools', 'project_context' },
    }
  end

  local mock_chat = create_mock_chat()
  local save_success = ReasoningPlugin.save_session(mock_chat)
  expect.equality(save_success, true)

  local sessions = ReasoningPlugin.list_sessions()
  expect.equality(type(sessions), 'table')
  if #sessions < 1 then
    error('Expected at least 1 session from direct API')
  end
  local session = sessions[1]

  local loaded_data, load_error = ReasoningPlugin.load_session(session.filename)
  expect.no_equality(loaded_data, nil)
  expect.equality(load_error, nil)
  expect.equality(#loaded_data.messages, 3)

  local delete_success = ReasoningPlugin.delete_session(session.filename)
  expect.equality(delete_success, true)
  local session_path = Config.get().session_history.sessions_dir .. '/' .. session.filename
  expect.equality(vim.fn.filereadable(session_path), 0)
end

return T
