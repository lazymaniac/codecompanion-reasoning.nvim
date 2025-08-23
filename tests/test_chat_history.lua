-- Test for chat history functionality
local MiniTest = require('mini.test')

local SessionManager = require('codecompanion._extensions.reasoning.helpers.session_manager')
local ReasoningPlugin = require('codecompanion-reasoning')

-- Test suite for chat history
local T = MiniTest.new_set({
  hooks = {
    -- Setup test environment
    pre_once = function()
      -- Use a temporary directory for testing
      SessionManager.setup({
        sessions_dir = vim.fn.tempname() .. '_chat_sessions',
      })
    end,
  },
})

-- Mock chat object for testing
local function create_mock_chat()
  return {
    id = 'test_chat_' .. tostring(math.random(1000, 9999)),
    adapter = { name = 'openai' },
    model = 'gpt-4',
    messages = {
      {
        role = 'user',
        content = 'Hello, can you help me with some code?',
        timestamp = os.time() - 100,
      },
      {
        role = 'assistant',
        content = "Of course! I'd be happy to help you with your code. What do you need assistance with?",
        timestamp = os.time() - 50,
      },
      {
        role = 'user',
        content = 'I need to implement a binary search function.',
        timestamp = os.time(),
      },
    },
    tools = { 'add_tools', 'project_context' },
  }
end

T['session save and load'] = function()
  local mock_chat = create_mock_chat()

  -- Test saving
  local success, filename = SessionManager.save_session(mock_chat)
  MiniTest.expect.equality(type(success), 'boolean')
  MiniTest.expect.equality(success, true)
  MiniTest.expect.equality(type(filename), 'string')

  -- Test loading
  local session_data, error_msg = SessionManager.load_session(filename)
  MiniTest.expect.no_equality(session_data, nil)
  MiniTest.expect.equality(error_msg, nil)
  MiniTest.expect.equality(#session_data.messages, 3)
  MiniTest.expect.equality(session_data.config.model, 'gpt-4')
  MiniTest.expect.equality(session_data.session_id, mock_chat.id)
end

T['session listing'] = function()
  -- Create and save multiple sessions with unique filenames
  local chat1 = create_mock_chat()
  local chat2 = create_mock_chat()

  local success1, filename1 = SessionManager.save_session(chat1, 'test_session_1.lua')
  local success2, filename2 = SessionManager.save_session(chat2, 'test_session_2.lua')

  MiniTest.expect.equality(success1, true)
  MiniTest.expect.equality(success2, true)

  local sessions = SessionManager.list_sessions()
  MiniTest.expect.equality(type(sessions), 'table')
  -- Should have at least the sessions we just created
  if #sessions < 2 then
    error(string.format('Expected at least 2 sessions, got %d', #sessions))
  end

  -- Check session structure
  if #sessions > 0 then
    local session = sessions[1]
    MiniTest.expect.equality(type(session.filename), 'string')
    MiniTest.expect.equality(type(session.created_at), 'string')
    MiniTest.expect.equality(type(session.total_messages), 'number')
    MiniTest.expect.equality(type(session.preview), 'string')
  end
end

T['session preview generation'] = function()
  local mock_chat = create_mock_chat()

  local success, filename = SessionManager.save_session(mock_chat)
  MiniTest.expect.equality(success, true)

  local session_data = SessionManager.load_session(filename)
  local preview = SessionManager.get_session_preview(session_data)

  MiniTest.expect.equality(type(preview), 'string')
  if #preview == 0 then
    error('Expected non-empty preview string')
  end
  if not preview:find('Hello') then
    error('Expected preview to contain "Hello" from first message')
  end
end

T['session deletion'] = function()
  local mock_chat = create_mock_chat()

  local success, filename = SessionManager.save_session(mock_chat)
  MiniTest.expect.equality(success, true)

  -- Verify it exists
  local session_data = SessionManager.load_session(filename)
  MiniTest.expect.no_equality(session_data, nil)

  -- Delete it
  local delete_success, delete_error = SessionManager.delete_session(filename)
  MiniTest.expect.equality(delete_success, true)
  MiniTest.expect.equality(delete_error, nil)

  -- Verify it's gone
  local deleted_session, error_msg = SessionManager.load_session(filename)
  MiniTest.expect.equality(deleted_session, nil)
  MiniTest.expect.no_equality(error_msg, nil) -- Should have an error message
end

T['direct API functions work'] = function()
  local mock_chat = create_mock_chat()

  -- Test direct save function
  local save_success = ReasoningPlugin.save_session(mock_chat)
  MiniTest.expect.equality(save_success, true)

  -- Test list sessions function
  local sessions = ReasoningPlugin.list_sessions()
  MiniTest.expect.equality(type(sessions), 'table')
  if #sessions < 1 then
    error('Expected at least 1 session from direct API')
  end

  local session = sessions[1]

  -- Test load session function
  local loaded_data, load_error = ReasoningPlugin.load_session(session.filename)
  MiniTest.expect.no_equality(loaded_data, nil)
  MiniTest.expect.equality(load_error, nil)
  MiniTest.expect.equality(#loaded_data.messages, 3)

  -- Test delete session function
  local delete_success = ReasoningPlugin.delete_session(session.filename)
  MiniTest.expect.equality(delete_success, true)
end

return T
