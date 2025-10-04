-- filepath: tests/codecompanion/_extensions/reasoning/helpers/session_manager_test.lua
-- Combined SessionManager tests: save/load/list/preview/restore/search/tags/sorting/token estimate
local MiniTest = require('mini.test')
local helpers = require('tests.helpers')

local T = MiniTest.new_set({
  hooks = {
    pre_once = function()
      local tmp = vim.fn.getcwd() .. '/tests/tmp_sessions/manager_all'
      vim.fn.delete(tmp, 'rf')
      vim.fn.mkdir(tmp, 'p')
      local Config = require('codecompanion._extensions.reasoning.config')
      Config.setup({
        session_history = { sessions_dir = tmp, continue_last_session = false, auto_generate_title = true },
      })
      require('codecompanion._extensions.reasoning.helpers.session_manager').setup()
    end,
  },
})

T['session save and load + listing + preview'] = function()
  local SessionManager = require('codecompanion._extensions.reasoning.helpers.session_manager')
  local ReasoningPlugin = require('codecompanion-reasoning')
  local Config = require('codecompanion._extensions.reasoning.config')

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
  local success, filename = SessionManager.save_session(mock_chat)
  MiniTest.expect.equality(success, true)
  MiniTest.expect.equality(type(filename), 'string')

  local session_data, error_msg = SessionManager.load_session(filename)
  MiniTest.expect.no_equality(session_data, nil)
  MiniTest.expect.equality(error_msg, nil)
  MiniTest.expect.equality(#session_data.messages, 3)
  MiniTest.expect.equality(session_data.config.model, 'unknown')
  MiniTest.expect.equality(session_data.session_id, mock_chat.id)

  local sessions = SessionManager.list_sessions()
  MiniTest.expect.equality(type(sessions), 'table')
  MiniTest.expect.equality(#sessions >= 1, true)

  local preview = SessionManager.get_session_preview(session_data)
  MiniTest.expect.equality(type(preview), 'string')
  MiniTest.expect.equality(preview:find('Hello') ~= nil, true)
end

T['restore visible messages and tool cycles'] = function()
  local SessionManager = require('codecompanion._extensions.reasoning.helpers.session_manager')
  -- Minimal mocks
  package.loaded['codecompanion.utils.context'] = {
    get = function(_)
      return {}
    end,
  }
  package.loaded['codecompanion.utils'] = { fire = function(_) end }
  _G.__RESTORE_CHAT_NEW_CALLS = 0
  local function build_chat()
    local bufnr = vim.api.nvim_create_buf(true, false)
    local chat = {
      bufnr = bufnr,
      id = 'chat-test',
      tool_registry = { in_use = {}, add = function(_, name) end, add_group = function() end },
      added = { history = 0, buffer = 0, tool = 0 },
      add_tool_output = function(self, _, _)
        self.added.tool = self.added.tool + 1
      end,
      add_message = function(self, _, _)
        self.added.history = self.added.history + 1
      end,
      add_buf_message = function(self, _)
        self.added.buffer = self.added.buffer + 1
      end,
      clear = function(self)
        self.messages = {}
        self.added.history = 0
        self.added.buffer = 0
        self.added.tool = 0
      end,
      apply_settings = function(self, settings)
        self.settings = vim.tbl_deep_extend('force', self.settings or {}, settings or {})
      end,
      apply_model = function(self, model)
        self.settings = self.settings or {}
        self.settings.model = model
      end,
      change_adapter = function(self, adapter, model)
        self.settings = self.settings or {}
        self.settings.adapter = adapter
        self.settings.model = model
      end,
      settings = {},
    }
    return chat
  end
  package.loaded['codecompanion.strategies.chat'] = {
    new = function(opts)
      _G.__RESTORE_CHAT_NEW_CALLS = (_G.__RESTORE_CHAT_NEW_CALLS or 0) + 1
      local chat = build_chat()
      _G.__RESTORE_LAST_CHAT = chat
      return chat
    end,
    buf_get_chat = function(bufnr)
      if _G.__RESTORE_LAST_CHAT and _G.__RESTORE_LAST_CHAT.bufnr == bufnr then
        return _G.__RESTORE_LAST_CHAT
      end
      return nil
    end,
  }
  package.loaded['codecompanion.config'] =
    { default_adapter = 'test', adapters = { test = {} }, strategies = { chat = { tools = { groups = {} } } } }
  package.loaded['codecompanion.adapters'] = {
    resolve = function(name)
      if name == 'test' then
        return { schema = {} }
      end
      return nil
    end,
    make_safe = function(adapter)
      return adapter
    end,
  }

  local messages = {}
  for i = 1, 20 do
    local role = (i % 2 == 0) and 'assistant' or 'user'
    table.insert(messages, { role = role, content = 'msg ' .. i })
  end
  local session_data = {
    version = '2.0',
    messages = messages,
    metadata = { total_messages = #messages },
    config = { adapter = 'test', model = 'mock' },
    tools = {},
    timestamp = helpers.timestamp(),
  }
  local filename = 'session_restore_test.lua'
  local ok, err = SessionManager.save_session_data(session_data, filename)
  assert(ok, err)
  local restored, chat_or_err = SessionManager.restore_session(filename)
  assert(restored, chat_or_err)
  assert(chat_or_err.added.history == 20)
  assert(chat_or_err.added.buffer == 20)

  local session_data2 = {
    version = '2.0',
    messages = {
      { role = 'user', content = 'Please ask me a question' },
      {
        role = 'assistant',
        content = '',
        tool_calls = { { ['function'] = { name = 'ask_user', arguments = '{"q":"hi"}' }, id = 'abc' } },
      },
      { role = 'tool', tool_call_id = 'abc', tool_name = 'ask_user', content = 'Answer: hello' },
      { role = 'assistant', content = 'Thanks!' },
    },
    metadata = { total_messages = 4 },
    config = { adapter = 'test', model = 'mock' },
    tools = { 'ask_user' },
    timestamp = helpers.timestamp(),
  }
  local filename2 = 'session_tool_cycle_test.lua'
  ok, err = SessionManager.save_session_data(session_data2, filename2)
  assert(ok, err)
  local restored2, chat2 = SessionManager.restore_session(filename2)
  assert(restored2, chat2)
  assert(chat2.added.history == 3)
  assert(chat2.added.buffer == 3)
end

T['search, tags and sorting'] = function()
  local SessionManager = require('codecompanion._extensions.reasoning.helpers.session_manager')
  -- Clean
  for _, s in ipairs(SessionManager.list_sessions()) do
    SessionManager.delete_session(s.filename)
  end

  -- Create sessions for title search
  local sessions_for_title = {
    { title = 'Python Web Development Tutorial', content = 'Learning Flask framework' },
    { title = 'JavaScript React Components', content = 'Building modern UI components' },
    { title = 'Database Design Patterns', content = 'SQL and NoSQL best practices' },
    { title = 'Machine Learning with Python', content = 'Using scikit-learn and TensorFlow' },
    { title = 'Mobile App Development', content = 'React Native and Flutter comparison' },
  }
  for i, s in ipairs(sessions_for_title) do
    local session_data = {
      version = '2.0',
      messages = { { role = 'user', content = s.content } },
      metadata = { total_messages = 1 },
      config = { adapter = 'test', model = 'mock' },
      timestamp = helpers.timestamp(i),
      created_at = helpers.datetime(i),
      title = s.title,
    }
    local ok, err = SessionManager.save_session_data(session_data, ('search_title_test_%d.lua'):format(i))
    assert(ok, err)
  end
  local all_sessions = SessionManager.list_sessions()
  local function search_sessions(query)
    local filtered = {}
    local nq = query:lower()
    for _, session in ipairs(all_sessions) do
      local matches = false
      if session.title and session.title:lower():find(nq, 1, true) then
        matches = true
      end
      if not matches and session.preview and session.preview:lower():find(nq, 1, true) then
        matches = true
      end
      if matches then
        table.insert(filtered, session)
      end
    end
    return filtered
  end
  assert(#search_sessions('python') == 2)
  assert(#search_sessions('javascript') == 1)
  assert(#search_sessions('development') == 2)

  -- Tag-based search and sorting
  for _, s in ipairs(SessionManager.list_sessions()) do
    SessionManager.delete_session(s.filename)
  end
  local tagged = {
    { title = 'Python Basics', tags = { 'python', 'programming', 'beginners', 'tutorial' } },
    { title = 'React Advanced', tags = { 'react', 'javascript', 'frontend', 'hooks', 'components' } },
    { title = 'Database Design', tags = { 'database', 'sql', 'design', 'normalization' } },
    { title = 'Machine Learning', tags = { 'ml', 'python', 'algorithms', 'data science', 'tensorflow' } },
  }
  for i, s in ipairs(tagged) do
    local session_data = {
      version = '2.0',
      messages = { { role = 'user', content = 'Test message for ' .. s.title } },
      metadata = { total_messages = 1, tags = s.tags },
      config = { adapter = 'test', model = 'mock' },
      timestamp = helpers.timestamp(i),
      created_at = helpers.datetime(i),
      title = s.title,
    }
    local ok, err = SessionManager.save_session_data(session_data, ('search_tags_test_%d.lua'):format(i))
    assert(ok, err)
  end
  local function search_with_tags(query)
    local filtered = {}
    local nq = query:lower()
    local sessions = SessionManager.list_sessions()
    for _, session in ipairs(sessions) do
      local matches = false
      if session.title and session.title:lower():find(nq, 1, true) then
        matches = true
      end
      if not matches and session.preview and session.preview:lower():find(nq, 1, true) then
        matches = true
      end
      if not matches and session.tags then
        for _, tag in ipairs(session.tags) do
          if tag:lower():find(nq, 1, true) then
            matches = true
            break
          end
        end
      end
      if matches then
        table.insert(filtered, session)
      end
    end
    return filtered
  end
  assert(#(search_with_tags('python')) == 2)
  assert(#(search_with_tags('javascript')) == 1)

  -- Favorite sorting
  for _, s in ipairs(SessionManager.list_sessions()) do
    SessionManager.delete_session(s.filename)
  end
  local tests = {
    { title = 'Oldest Non-Favorite', offset = -300, favorite = false },
    { title = 'Old Favorite', offset = -200, favorite = true },
    { title = 'Recent Non-Favorite', offset = -100, favorite = false },
    { title = 'Recent Favorite', offset = -50, favorite = true },
    { title = 'Newest Non-Favorite', offset = 0, favorite = false },
  }
  for i, s in ipairs(tests) do
    local session_data = {
      version = '2.0',
      messages = { { role = 'user', content = 'Test message ' .. i } },
      metadata = { total_messages = 1, favorite = s.favorite },
      config = { adapter = 'test', model = 'mock' },
      timestamp = helpers.timestamp(s.offset),
      created_at = helpers.datetime(s.offset),
      title = s.title,
    }
    local ok, err = SessionManager.save_session_data(session_data, ('sorting_test_%d.lua'):format(i))
    assert(ok, err)
  end
  local sessions = SessionManager.list_sessions()
  assert(sessions[1].is_favorite and sessions[2].is_favorite)
end

return T
