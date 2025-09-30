local h = require('tests.helpers')

local new_set = MiniTest.new_set

local child = MiniTest.new_child_neovim()
local T = new_set({
  hooks = {
    pre_once = function()
      h.child_start(child)
      child.lua([[
        h = require('tests.helpers')
        local tmp = vim.fn.getcwd() .. '/tests/tmp_sessions/manager_tags'
        vim.fn.delete(tmp, 'rf')
        vim.fn.mkdir(tmp, 'p')

        local SessionManager = require('codecompanion._extensions.reasoning.helpers.session_manager')
        SessionManager.setup({
          sessions_dir = tmp,
          continue_chat = 'no',
        })
      ]])
    end,
    post_once = child.stop,
  },
})

T['auto-generate tags on session save'] = function()
  child.lua([[
    local SessionManager = require('codecompanion._extensions.reasoning.helpers.session_manager')

    -- Mock the LLM request to return predictable tags
    local original_make_llm_request = SessionManager._make_llm_request
    local llm_request_called = false
    SessionManager._make_llm_request = function(session_data, prompt, callback)
      llm_request_called = true
      assert(prompt:find('Generate 3-5 relevant tags'), 'Expected tag generation prompt')
      if callback then
        callback('python, web development, flask, backend, api')
      end
    end

    -- Create a mock chat object with enough messages to trigger tag generation
    local mock_chat = {
      id = 'test-chat-123',
      messages = {
        { role = 'user', content = 'How do I build a REST API with Flask in Python?' },
        { role = 'assistant', content = 'To build a REST API with Flask, you need to...' },
        { role = 'user', content = 'What about authentication and database integration?' },
        { role = 'assistant', content = 'For authentication, you can use JWT tokens...' },
      },
      opts = { title = 'Flask API Development' },
    }

    -- Save the session (should trigger tag generation)
    local success, filename = SessionManager.save_session(mock_chat)
    assert(success, 'Expected session save to succeed')
    assert(filename, 'Expected filename to be returned')

    -- Wait a bit for async tag generation
    vim.wait(100)

    -- Verify tag generation was attempted
    assert(llm_request_called, 'Expected LLM request to be called for tag generation')

    -- Load the session and check if tags were added
    local saved_session_data, err = SessionManager.load_session(filename)
    assert(saved_session_data, 'Expected session data to load: ' .. (err or 'unknown error'))

    -- Note: In real implementation, tags might be added asynchronously
    -- For testing purposes, we verify the tag generation logic was called

    -- Restore original function
    SessionManager._make_llm_request = original_make_llm_request
  ]])
end

T['tag generation with different conversation types'] = function()
  child.lua([[
    local SessionManager = require('codecompanion._extensions.reasoning.helpers.session_manager')

    local test_cases = {
      {
        name = 'Python Programming',
        messages = {
          { role = 'user', content = 'Help me debug this Python script with list comprehensions' },
          { role = 'assistant', content = 'List comprehensions are powerful Python features...' },
        },
        expected_tags = 'python, debugging, list comprehensions, programming'
      },
      {
        name = 'Database Design',
        messages = {
          { role = 'user', content = 'How should I design a relational database for an e-commerce platform?' },
          { role = 'assistant', content = 'For e-commerce databases, you need tables for users, products, orders...' },
        },
        expected_tags = 'database design, sql, ecommerce, relational database'
      },
      {
        name = 'Machine Learning',
        messages = {
          { role = 'user', content = 'Explain neural networks and deep learning concepts' },
          { role = 'assistant', content = 'Neural networks are inspired by biological neurons...' },
        },
        expected_tags = 'machine learning, neural networks, deep learning, ai'
      }
    }

    for _, test_case in ipairs(test_cases) do
      local generated_tags = nil

      -- Mock LLM request for this test case
      local original_make_llm_request = SessionManager._make_llm_request
      SessionManager._make_llm_request = function(session_data, prompt, callback)
        -- Verify the conversation content is included in the prompt
        assert(prompt:find(test_case.messages[1].content:sub(1, 20)),
          'Expected user message content in prompt for ' .. test_case.name)

        if callback then
          callback(test_case.expected_tags)
        end
      end

      local session_data = {
        messages = test_case.messages,
        config = { adapter = 'test', model = 'mock' },
      }

      SessionManager._generate_session_tags(session_data, function(tags)
        generated_tags = tags
      end)

      -- Verify tags were generated
      assert(generated_tags, 'Expected tags to be generated for ' .. test_case.name)
      assert(type(generated_tags) == 'table', 'Expected tags to be a table for ' .. test_case.name)
      assert(#generated_tags > 0, 'Expected non-empty tags for ' .. test_case.name)

      -- Verify tags are properly parsed and cleaned
      local expected_tags_list = vim.split(test_case.expected_tags, ', ')
      for i, expected_tag in ipairs(expected_tags_list) do
        assert(generated_tags[i] == expected_tag,
          string.format('Expected tag "%s" at position %d for %s, got "%s"',
            expected_tag, i, test_case.name, generated_tags[i] or 'nil'))
      end

      SessionManager._make_llm_request = original_make_llm_request
    end
  ]])
end

T['tag parsing and validation'] = function()
  child.lua([[
    local SessionManager = require('codecompanion/_extensions.reasoning.helpers.session_manager')

    local test_responses = {
      {
        name = 'Normal comma-separated tags',
        response = 'python, web development, flask, api, backend',
        expected = {'python', 'web development', 'flask', 'api', 'backend'}
      },
      {
        name = 'Tags with extra whitespace',
        response = 'python,   web development ,flask,  api  , backend ',
        expected = {'python', 'web development', 'flask', 'api', 'backend'}
      },
      {
        name = 'Too many tags (should limit to 5)',
        response = 'python, javascript, react, node, express, mongodb, sql, redis',
        expected = {'python', 'javascript', 'react', 'node', 'express'}
      },
      {
        name = 'Tags with mixed case (should normalize to lowercase)',
        response = 'Python, WEB Development, Flask, API, BackEnd',
        expected = {'python', 'web development', 'flask', 'api', 'backend'}
      },
      {
        name = 'Empty tags and very long tags (should filter out)',
        response = 'python, , web development, this-is-a-very-long-tag-that-exceeds-the-limit, flask',
        expected = {'python', 'web development', 'flask'}
      }
    }

    for _, test_case in ipairs(test_responses) do
      local generated_tags = nil

      -- Mock LLM request to return test response
      local original_make_llm_request = SessionManager._make_llm_request
      SessionManager._make_llm_request = function(session_data, prompt, callback)
        if callback then
          callback(test_case.response)
        end
      end

      local session_data = {
        messages = {{ role = 'user', content = 'Test message' }},
        config = { adapter = 'test', model = 'mock' },
      }

      SessionManager._generate_session_tags(session_data, function(tags)
        generated_tags = tags
      end)

      -- Verify tags were parsed correctly
      assert(generated_tags, 'Expected tags to be generated for ' .. test_case.name)
      assert(#generated_tags == #test_case.expected,
        string.format('Expected %d tags for %s, got %d', #test_case.expected, test_case.name, #generated_tags))

      for i, expected_tag in ipairs(test_case.expected) do
        assert(generated_tags[i] == expected_tag,
          string.format('Expected tag "%s" at position %d for %s, got "%s"',
            expected_tag, i, test_case.name, generated_tags[i] or 'nil'))
      end

      SessionManager._make_llm_request = original_make_llm_request
    end
  ]])
end

T['session list includes tags and favorites metadata'] = function()
  child.lua([[
    local SessionManager = require('codecompanion._extensions.reasoning.helpers.session_manager')

    -- Clean any existing sessions first
    local existing_sessions = SessionManager.list_sessions()
    for _, session in ipairs(existing_sessions) do
      SessionManager.delete_session(session.filename)
    end

    -- Create test sessions with various metadata combinations
    local test_sessions = {
      {
        filename = 'session_with_tags.lua',
        title = 'Python Tutorial',
        metadata = {
          total_messages = 3,
          tags = {'python', 'programming', 'tutorial'},
          favorite = false
        }
      },
      {
        filename = 'favorite_session.lua',
        title = 'Important Discussion',
        metadata = {
          total_messages = 2,
          favorite = true
        }
      },
      {
        filename = 'session_with_both.lua',
        title = 'Advanced React',
        metadata = {
          total_messages = 5,
          tags = {'react', 'javascript', 'hooks'},
          favorite = true
        }
      }
    }

    for _, session_info in ipairs(test_sessions) do
      local session_data = {
        version = '2.0',
        messages = {
          { role = 'user', content = 'Test message for ' .. session_info.title }
        },
        metadata = session_info.metadata,
        config = { adapter = 'test', model = 'mock' },
        timestamp = os.time(),
        created_at = os.date('%Y-%m-%d %H:%M:%S'),
        title = session_info.title,
      }

      local ok, err = SessionManager.save_session_data(session_data, session_info.filename)
      assert(ok, 'Expected session save to succeed: ' .. (err or 'unknown error'))
    end

    -- List sessions and verify metadata is included
    local sessions = SessionManager.list_sessions()
    assert(#sessions == 3, 'Expected 3 sessions in list')

    -- Find each session and verify its metadata
    local function find_session_by_title(title)
      for _, session in ipairs(sessions) do
        if session.title == title then
          return session
        end
      end
      return nil
    end

    -- Verify Python Tutorial session
    local python_session = find_session_by_title('Python Tutorial')
    assert(python_session, 'Expected to find Python Tutorial session')
    assert(not python_session.is_favorite, 'Expected Python session to not be favorite')
    assert(python_session.tags, 'Expected Python session to have tags')
    assert(#python_session.tags == 3, 'Expected Python session to have 3 tags')
    assert(python_session.tags[1] == 'python', 'Expected first tag to be "python"')

    -- Verify Important Discussion session
    local important_session = find_session_by_title('Important Discussion')
    assert(important_session, 'Expected to find Important Discussion session')
    assert(important_session.is_favorite, 'Expected Important session to be favorite')
    assert(#important_session.tags == 0, 'Expected Important session to have no tags')

    -- Verify Advanced React session
    local react_session = find_session_by_title('Advanced React')
    assert(react_session, 'Expected to find Advanced React session')
    assert(react_session.is_favorite, 'Expected React session to be favorite')
    assert(react_session.tags, 'Expected React session to have tags')
    assert(#react_session.tags == 3, 'Expected React session to have 3 tags')

    -- Verify token estimation is present for all sessions
    for _, session in ipairs(sessions) do
      assert(session.token_estimate, 'Expected token estimation for session: ' .. session.title)
      assert(type(session.token_estimate) == 'number', 'Expected token estimation to be number for: ' .. session.title)
      assert(session.token_estimate > 0, 'Expected positive token estimation for: ' .. session.title)
    end
  ]])
end

T['favorite sessions sorting priority'] = function()
  child.lua([[
    local SessionManager = require('codecompanion._extensions.reasoning.helpers.session_manager')

    -- Clean any existing sessions first
    local existing_sessions = SessionManager.list_sessions()
    for _, session in ipairs(existing_sessions) do
      SessionManager.delete_session(session.filename)
    end

    local base_time = os.time()

    -- Create sessions with mixed favorite status and timestamps
    local test_sessions = {
      { title = 'Oldest Non-Favorite', timestamp = base_time - 300, favorite = false },
      { title = 'Old Favorite', timestamp = base_time - 200, favorite = true },
      { title = 'Recent Non-Favorite', timestamp = base_time - 100, favorite = false },
      { title = 'Recent Favorite', timestamp = base_time - 50, favorite = true },
      { title = 'Newest Non-Favorite', timestamp = base_time, favorite = false },
    }

    for i, session_info in ipairs(test_sessions) do
      local session_data = {
        version = '2.0',
        messages = {{ role = 'user', content = 'Test message ' .. i }},
        metadata = {
          total_messages = 1,
          favorite = session_info.favorite
        },
        config = { adapter = 'test', model = 'mock' },
        timestamp = session_info.timestamp,
        created_at = os.date('%Y-%m-%d %H:%M:%S', session_info.timestamp),
        title = session_info.title,
      }

      local filename = 'sorting_test_' .. i .. '.lua'
      local ok, err = SessionManager.save_session_data(session_data, filename)
      assert(ok, 'Expected session save to succeed: ' .. (err or 'unknown error'))
    end

    -- Get sorted session list
    local sessions = SessionManager.list_sessions()
    assert(#sessions == 5, 'Expected 5 sessions in list')

    -- Verify favorites come first
    assert(sessions[1].is_favorite, 'Expected first session to be favorite: ' .. sessions[1].title)
    assert(sessions[2].is_favorite, 'Expected second session to be favorite: ' .. sessions[2].title)

    -- Verify favorites are sorted by timestamp (newest first)
    assert(sessions[1].title == 'Recent Favorite', 'Expected newest favorite first')
    assert(sessions[2].title == 'Old Favorite', 'Expected older favorite second')

    -- Verify non-favorites come after favorites
    assert(not sessions[3].is_favorite, 'Expected third session to not be favorite: ' .. sessions[3].title)
    assert(not sessions[4].is_favorite, 'Expected fourth session to not be favorite: ' .. sessions[4].title)
    assert(not sessions[5].is_favorite, 'Expected fifth session to not be favorite: ' .. sessions[5].title)

    -- Verify non-favorites are sorted by timestamp (newest first)
    assert(sessions[3].title == 'Newest Non-Favorite', 'Expected newest non-favorite third')
    assert(sessions[4].title == 'Recent Non-Favorite', 'Expected recent non-favorite fourth')
    assert(sessions[5].title == 'Oldest Non-Favorite', 'Expected oldest non-favorite last')
  ]])
end

return T
