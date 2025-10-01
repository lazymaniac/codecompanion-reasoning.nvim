local h = require('tests.helpers')

local new_set = MiniTest.new_set

local child = MiniTest.new_child_neovim()
local T = new_set({
  hooks = {
    pre_once = function()
      h.child_start(child)
      child.lua([[
        h = require('tests.helpers')
        normalize_content = function(content)
          if type(content) == 'table' then
            return normalize_content(vim.inspect(content))
          end
          return vim.trim(tostring(content or ''))
        end

        local Config = require('codecompanion._extensions.reasoning.config')
        local tmp = vim.fn.getcwd() .. '/tests/tmp_sessions/search'
        vim.fn.delete(tmp, 'rf')
        vim.fn.mkdir(tmp, 'p')

        Config.setup({
          session_history = {
            sessions_dir = tmp,
            continue_last_session = false,
            auto_generate_title = true,
          },
        })

        local SessionManager = require('codecompanion._extensions.reasoning.helpers.session_manager')
        SessionManager.setup()
      ]])
    end,
    post_once = child.stop,
  },
})

T['search sessions by title'] = function()
  child.lua([[
    local helpers = require('tests.helpers')
    local SessionManager = require('codecompanion._extensions.reasoning.helpers.session_manager')

    -- Clean any existing sessions first
    local existing_sessions = SessionManager.list_sessions()
    for _, session in ipairs(existing_sessions) do
      SessionManager.delete_session(session.filename)
    end

    -- Create test sessions with different titles
    local test_sessions = {
      { title = 'Python Web Development Tutorial', content = 'Learning Flask framework' },
      { title = 'JavaScript React Components', content = 'Building modern UI components' },
      { title = 'Database Design Patterns', content = 'SQL and NoSQL best practices' },
      { title = 'Machine Learning with Python', content = 'Using scikit-learn and TensorFlow' },
      { title = 'Mobile App Development', content = 'React Native and Flutter comparison' },
    }

    for i, session_info in ipairs(test_sessions) do
      local session_data = {
        version = '2.0',
        messages = {
          { role = 'user', content = session_info.content }
        },
        metadata = { total_messages = 1 },
        config = { adapter = 'test', model = 'mock' },
        timestamp = helpers.timestamp(i),
        created_at = helpers.datetime(i),
        title = session_info.title,
      }

      local filename = 'search_title_test_' .. i .. '.lua'
      local ok, err = SessionManager.save_session_data(session_data, filename)
      assert(ok, 'Expected session save to succeed: ' .. (err or 'unknown error'))
    end

    local all_sessions = SessionManager.list_sessions()
    assert(#all_sessions == 5, 'Expected 5 sessions for title search test')

    -- Test search function (simulating the search logic from session_picker.lua)
    local function search_sessions(query)
      local filtered_sessions = {}
      local normalized_query = query:lower()

      for _, session in ipairs(all_sessions) do
        local matches = false

        -- Search in title
        if session.title and session.title:lower():find(normalized_query, 1, true) then
          matches = true
        end

        -- Search in preview/content
        if not matches and session.preview and session.preview:lower():find(normalized_query, 1, true) then
          matches = true
        end

        if matches then
          table.insert(filtered_sessions, session)
        end
      end

      return filtered_sessions
    end

    -- Test various search queries
    local search_tests = {
      { query = 'python', expected_count = 2, expected_titles = {'Python Web Development Tutorial', 'Machine Learning with Python'} },
      { query = 'javascript', expected_count = 1, expected_titles = {'JavaScript React Components'} },
      { query = 'development', expected_count = 2, expected_titles = {'Python Web Development Tutorial', 'Mobile App Development'} }, -- Note: "development" appears in 2 titles, not 3
      { query = 'database', expected_count = 1, expected_titles = {'Database Design Patterns'} },
      { query = 'react', expected_count = 2, expected_titles = {'JavaScript React Components', 'Mobile App Development'} }, -- React appears in title and content
      { query = 'nonexistent', expected_count = 0, expected_titles = {} },
      { query = 'tutorial', expected_count = 1, expected_titles = {'Python Web Development Tutorial'} },
    }

    for _, test in ipairs(search_tests) do
      local results = search_sessions(test.query)

      assert(#results == test.expected_count,
        string.format('Expected %d results for query "%s", got %d', test.expected_count, test.query, #results))

      -- Verify expected titles are found
      for _, expected_title in ipairs(test.expected_titles) do
        local found = false
        for _, result in ipairs(results) do
          if result.title == expected_title then
            found = true
            break
          end
        end
        assert(found, string.format('Expected to find session with title "%s" for query "%s"', expected_title, test.query))
      end
    end
  ]])
end

T['search sessions by content'] = function()
  child.lua([[
    local helpers = require('tests.helpers')
    local SessionManager = require('codecompanion._extensions.reasoning.helpers.session_manager')

    -- Clean any existing sessions first
    local existing_sessions = SessionManager.list_sessions()
    for _, session in ipairs(existing_sessions) do
      SessionManager.delete_session(session.filename)
    end

    -- Create test sessions with specific content for searching
    local test_sessions = {
      {
        title = 'Web Development Help',
        messages = {
          { role = 'user', content = 'How do I implement authentication in Express.js?' },
          { role = 'assistant', content = 'You can use passport.js for authentication middleware' },
        }
      },
      {
        title = 'Algorithm Discussion',
        messages = {
          { role = 'user', content = 'Explain binary search algorithm implementation' },
          { role = 'assistant', content = 'Binary search works by dividing the search space in half' },
        }
      },
      {
        title = 'Database Query Help',
        messages = {
          { role = 'user', content = 'How to optimize SQL queries with indexes?' },
          { role = 'assistant', content = 'Indexes can significantly improve query performance' },
        }
      },
    }

    for i, session_info in ipairs(test_sessions) do
      local session_data = {
        version = '2.0',
        messages = session_info.messages,
        metadata = { total_messages = #session_info.messages },
        config = { adapter = 'test', model = 'mock' },
        timestamp = helpers.timestamp(i),
        created_at = helpers.datetime(i),
        title = session_info.title,
      }

      local filename = 'search_content_test_' .. i .. '.lua'
      local ok, err = SessionManager.save_session_data(session_data, filename)
      assert(ok, 'Expected session save to succeed: ' .. (err or 'unknown error'))
    end

    local all_sessions = SessionManager.list_sessions()
    assert(#all_sessions == 3, 'Expected 3 sessions for content search test')

    -- Search function that includes content/preview search
    local function search_sessions(query)
      local filtered_sessions = {}
      local normalized_query = query:lower()

      for _, session in ipairs(all_sessions) do
        local matches = false

        -- Search in title
        if session.title and session.title:lower():find(normalized_query, 1, true) then
          matches = true
        end

        -- Search in preview/content (preview is generated from messages)
        if not matches and session.preview and session.preview:lower():find(normalized_query, 1, true) then
          matches = true
        end

        if matches then
          table.insert(filtered_sessions, session)
        end
      end

      return filtered_sessions
    end

    -- Test content-based searches (note: search uses preview which is first user message only)
    local content_tests = {
      { query = 'authentication', expected_count = 1, note = 'should find session about Express.js auth' },
      { query = 'express', expected_count = 1, note = 'should find session mentioning Express.js in user message' },
      { query = 'binary', expected_count = 1, note = 'should find algorithm discussion' },
      { query = 'explain', expected_count = 1, note = 'should find session starting with "Explain"' },
      { query = 'sql', expected_count = 1, note = 'should find database query session' },
      { query = 'optimize', expected_count = 1, note = 'should find session about query optimization' },
      { query = 'authentication', expected_count = 1, note = 'should find session asking about authentication' },
    }

    for _, test in ipairs(content_tests) do
      local results = search_sessions(test.query)

      assert(#results == test.expected_count,
        string.format('Expected %d results for query "%s" (%s), got %d',
          test.expected_count, test.query, test.note, #results))
    end
  ]])
end

T['search sessions by tags'] = function()
  child.lua([[
    local helpers = require('tests.helpers')
    local SessionManager = require('codecompanion._extensions.reasoning.helpers.session_manager')

    -- Clean any existing sessions first
    local existing_sessions = SessionManager.list_sessions()
    for _, session in ipairs(existing_sessions) do
      SessionManager.delete_session(session.filename)
    end

    -- Create test sessions with different tags
    local test_sessions = {
      {
        title = 'Python Basics',
        tags = {'python', 'programming', 'beginners', 'tutorial'}
      },
      {
        title = 'React Advanced',
        tags = {'react', 'javascript', 'frontend', 'hooks', 'components'}
      },
      {
        title = 'Database Design',
        tags = {'database', 'sql', 'design', 'normalization'}
      },
      {
        title = 'Machine Learning',
        tags = {'ml', 'python', 'algorithms', 'data science', 'tensorflow'}
      },
    }

    for i, session_info in ipairs(test_sessions) do
      local session_data = {
        version = '2.0',
        messages = {
          { role = 'user', content = 'Test message for ' .. session_info.title }
        },
        metadata = {
          total_messages = 1,
          tags = session_info.tags
        },
        config = { adapter = 'test', model = 'mock' },
        timestamp = helpers.timestamp(i),
        created_at = helpers.datetime(i),
        title = session_info.title,
      }

      local filename = 'search_tags_test_' .. i .. '.lua'
      local ok, err = SessionManager.save_session_data(session_data, filename)
      assert(ok, 'Expected session save to succeed: ' .. (err or 'unknown error'))
    end

    local all_sessions = SessionManager.list_sessions()
    assert(#all_sessions == 4, 'Expected 4 sessions for tag search test')

    -- Search function that includes tags
    local function search_sessions_with_tags(query)
      local filtered_sessions = {}
      local normalized_query = query:lower()

      for _, session in ipairs(all_sessions) do
        local matches = false

        -- Search in title
        if session.title and session.title:lower():find(normalized_query, 1, true) then
          matches = true
        end

        -- Search in preview/content
        if not matches and session.preview and session.preview:lower():find(normalized_query, 1, true) then
          matches = true
        end

        -- Search in tags
        if not matches and session.tags then
          for _, tag in ipairs(session.tags) do
            if tag:lower():find(normalized_query, 1, true) then
              matches = true
              break
            end
          end
        end

        if matches then
          table.insert(filtered_sessions, session)
        end
      end

      return filtered_sessions
    end

    -- Test tag-based searches
    local tag_tests = {
      { query = 'python', expected_count = 2, note = 'should find Python Basics and Machine Learning' },
      { query = 'javascript', expected_count = 1, note = 'should find React Advanced' },
      { query = 'frontend', expected_count = 1, note = 'should find React session by tag' },
      { query = 'sql', expected_count = 1, note = 'should find Database Design by tag' },
      { query = 'algorithms', expected_count = 1, note = 'should find Machine Learning by tag' },
      { query = 'tutorial', expected_count = 1, note = 'should find Python Basics by tag' },
      { query = 'hooks', expected_count = 1, note = 'should find React session by specific tag' },
      { query = 'design', expected_count = 1, note = 'should find Database Design by tag and title' },
    }

    for _, test in ipairs(tag_tests) do
      local results = search_sessions_with_tags(test.query)

      assert(#results == test.expected_count,
        string.format('Expected %d results for tag query "%s" (%s), got %d',
          test.expected_count, test.query, test.note, #results))
    end
  ]])
end

T['case insensitive search'] = function()
  child.lua([[
    local helpers = require('tests.helpers')
    local SessionManager = require('codecompanion._extensions.reasoning.helpers.session_manager')

    -- Clean any existing sessions first
    local existing_sessions = SessionManager.list_sessions()
    for _, session in ipairs(existing_sessions) do
      SessionManager.delete_session(session.filename)
    end

    -- Create test session with mixed case content
    local session_data = {
      version = '2.0',
      messages = {
        { role = 'user', content = 'Help me with JavaScript and React Development' }
      },
      metadata = {
        total_messages = 1,
        tags = {'JavaScript', 'React', 'Frontend'}
      },
      config = { adapter = 'test', model = 'mock' },
      timestamp = helpers.timestamp(),
      created_at = helpers.datetime(),
      title = 'JavaScript React Tutorial',
    }

    local ok, err = SessionManager.save_session_data(session_data, 'case_test.lua')
    assert(ok, 'Expected session save to succeed: ' .. (err or 'unknown error'))

    local all_sessions = SessionManager.list_sessions()
    assert(#all_sessions == 1, 'Expected 1 session for case sensitivity test')

    -- Search function with case insensitive matching
    local function search_sessions(query)
      local filtered_sessions = {}
      local normalized_query = query:lower()

      for _, session in ipairs(all_sessions) do
        local matches = false

        -- Search in title (case insensitive)
        if session.title and session.title:lower():find(normalized_query, 1, true) then
          matches = true
        end

        -- Search in tags (case insensitive)
        if not matches and session.tags then
          for _, tag in ipairs(session.tags) do
            if tag:lower():find(normalized_query, 1, true) then
              matches = true
              break
            end
          end
        end

        if matches then
          table.insert(filtered_sessions, session)
        end
      end

      return filtered_sessions
    end

    -- Test case insensitive searches
    local case_tests = {
      'javascript',  -- lowercase
      'JAVASCRIPT',  -- uppercase
      'JavaScript',  -- mixed case
      'react',       -- lowercase
      'REACT',       -- uppercase
      'React',       -- mixed case
      'frontend',    -- lowercase (tag is 'Frontend')
      'FRONTEND',    -- uppercase
      'tutorial',    -- lowercase (title contains 'Tutorial')
      'TUTORIAL',    -- uppercase
    }

    for _, query in ipairs(case_tests) do
      local results = search_sessions(query)
      assert(#results == 1,
        string.format('Expected 1 result for case-insensitive query "%s", got %d', query, #results))
      assert(results[1].title == 'JavaScript React Tutorial',
        'Expected to find the test session for query: ' .. query)
    end
  ]])
end

T['search with empty results'] = function()
  child.lua([[
    local helpers = require('tests.helpers')
    local SessionManager = require('codecompanion._extensions.reasoning.helpers.session_manager')

    -- Clean any existing sessions first
    local existing_sessions = SessionManager.list_sessions()
    for _, session in ipairs(existing_sessions) do
      SessionManager.delete_session(session.filename)
    end

    -- Create test session
    local session_data = {
      version = '2.0',
      messages = {
        { role = 'user', content = 'Simple test message' }
      },
      metadata = {
        total_messages = 1,
        tags = {'test', 'simple'}
      },
      config = { adapter = 'test', model = 'mock' },
      timestamp = helpers.timestamp(),
      created_at = helpers.datetime(),
      title = 'Test Session',
    }

    local ok, err = SessionManager.save_session_data(session_data, 'empty_results_test.lua')
    assert(ok, 'Expected session save to succeed: ' .. (err or 'unknown error'))

    local all_sessions = SessionManager.list_sessions()
    assert(#all_sessions == 1, 'Expected 1 session for empty results test')

    -- Search function
    local function search_sessions(query)
      local filtered_sessions = {}
      local normalized_query = query:lower()

      for _, session in ipairs(all_sessions) do
        local matches = false

        if session.title and session.title:lower():find(normalized_query, 1, true) then
          matches = true
        end

        if not matches and session.tags then
          for _, tag in ipairs(session.tags) do
            if tag:lower():find(normalized_query, 1, true) then
              matches = true
              break
            end
          end
        end

        if matches then
          table.insert(filtered_sessions, session)
        end
      end

      return filtered_sessions
    end

    -- Test queries that should return no results
    local empty_queries = {
      'nonexistent',
      'python',      -- not in our test session
      'javascript',  -- not in our test session
      'database',    -- not in our test session
      'xyz123',      -- definitely not there
      'advanced',    -- not in our simple test session
    }

    for _, query in ipairs(empty_queries) do
      local results = search_sessions(query)
      assert(#results == 0,
        string.format('Expected 0 results for query "%s", got %d', query, #results))
    end

    -- Test queries that should return the session
    local matching_queries = {
      'test',
      'simple',
      'session',
      'Test',  -- case insensitive
      'SIMPLE', -- case insensitive
    }

    for _, query in ipairs(matching_queries) do
      local results = search_sessions(query)
      assert(#results == 1,
        string.format('Expected 1 result for query "%s", got %d', query, #results))
    end
  ]])
end

return T
