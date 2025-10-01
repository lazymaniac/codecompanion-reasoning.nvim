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
        local tmp = vim.fn.getcwd() .. '/tests/tmp_sessions/enhanced_picker'
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

        -- Mock vim.ui.input for testing
        _G.test_input_result = nil
        _G.test_input_prompt = nil
        vim.ui.input = function(opts, on_confirm)
          _G.test_input_prompt = opts.prompt
          if on_confirm then
            on_confirm(_G.test_input_result)
          end
        end

        -- Mock vim.notify
        _G.test_notifications = {}
        vim.notify = function(msg, level)
          table.insert(_G.test_notifications, { msg = msg, level = level })
        end

        -- Mock vim.fn.confirm
        _G.test_confirm_result = 1
        _G.test_confirm_msg = nil
        vim.fn.confirm = function(msg, choices, default, type)
          _G.test_confirm_msg = msg
          return _G.test_confirm_result
        end
      ]])
    end,
    post_once = child.stop,
  },
})

-- Helper function to create test session
local function create_test_session(session_id, title, messages, metadata)
  return {
    version = '2.0',
    messages = messages or {
      { role = 'user', content = 'Test user message for session ' .. session_id },
      { role = 'assistant', content = 'Test assistant response for session ' .. session_id },
    },
    metadata = vim.tbl_extend('force', {
      total_messages = #(messages or {}),
    }, metadata or {}),
    config = { adapter = 'test', model = 'mock-' .. session_id },
    timestamp = os.time() + session_id,
    created_at = os.date('%Y-%m-%d %H:%M:%S', os.time() + session_id),
    title = title or ('Test Session ' .. session_id),
  }
end

T['rename session functionality'] = function()
  child.lua([[
    local SessionManager = require('codecompanion._extensions.reasoning.helpers.session_manager')
    local SessionPicker = require('codecompanion._extensions.reasoning.ui.session_picker')

    -- Clean any existing sessions first
    local existing_sessions = SessionManager.list_sessions()
    for _, session in ipairs(existing_sessions) do
      SessionManager.delete_session(session.filename)
    end

    -- Create test session
    local session_data = {
      version = '2.0',
      messages = { { role = 'user', content = 'Test message' } },
      metadata = { total_messages = 1 },
      config = { adapter = 'test', model = 'mock' },
      timestamp = os.time(),
      created_at = os.date('%Y-%m-%d %H:%M:%S'),
      title = 'Original Title',
    }

    local ok, err = SessionManager.save_session_data(session_data, 'rename_test.lua')
    assert(ok, err)

    -- Mock user input for rename
    _G.test_input_result = 'New Renamed Title'

    -- Test the rename handler
    local sessions = SessionManager.list_sessions()
    assert(#sessions == 1, 'Expected exactly one session')

    local test_session = sessions[1]
    SessionPicker._handle_rename(test_session, function() end)

    -- Verify the prompt was shown
    assert(_G.test_input_prompt == 'New title: ', 'Expected rename prompt')

    -- Verify the session was updated
    local updated_sessions = SessionManager.list_sessions()
    assert(#updated_sessions == 1, 'Expected exactly one session after rename')
    assert(updated_sessions[1].title == 'New Renamed Title', 'Expected title to be updated')

    -- Verify notification
    local found_success = false
    for _, notif in ipairs(_G.test_notifications) do
      if notif.msg:find('Renamed to "New Renamed Title"') then
        found_success = true
        break
      end
    end
    assert(found_success, 'Expected success notification for rename')
  ]])
end

T['regenerate title functionality'] = function()
  child.lua([[
    local SessionManager = require('codecompanion._extensions.reasoning.helpers.session_manager')
    local SessionPicker = require('codecompanion._extensions.reasoning.ui.session_picker')

    -- Clean any existing sessions first
    local existing_sessions = SessionManager.list_sessions()
    for _, session in ipairs(existing_sessions) do
      SessionManager.delete_session(session.filename)
    end

    -- Create test session with meaningful content
    local session_data = {
      version = '2.0',
      messages = {
        { role = 'user', content = 'How do I implement a binary search algorithm in Python?' },
        { role = 'assistant', content = 'Here is a binary search implementation...' },
      },
      metadata = { total_messages = 2 },
      config = { adapter = 'test', model = 'mock' },
      timestamp = os.time(),
      created_at = os.date('%Y-%m-%d %H:%M:%S'),
      title = 'Original Title',
    }

    local ok, err = SessionManager.save_session_data(session_data, 'regenerate_title_test.lua')
    assert(ok, err)

    -- Mock adapters.resolve to return a proper adapter
    local adapters_ok, adapters = pcall(require, 'codecompanion.adapters')
    local original_resolve = nil
    if adapters_ok and adapters then
      original_resolve = adapters.resolve
      adapters.resolve = function(adapter_name)
        if adapter_name == 'test' then
          return {
            map_roles = function(messages)
              return messages
            end,
            map_schema_to_params = function(settings)
              return settings
            end,
            handlers = {
              chat_output = function(adapter, data)
                return {
                  status = 'success',
                  output = { content = 'Binary Search Algorithm' }
                }
              end
            }
          }
        end
        return nil
      end
    end

    -- Mock schema module
    local schema_ok, schema = pcall(require, 'codecompanion.schema')
    local original_get_default = nil
    if schema_ok and schema then
      original_get_default = schema.get_default
      schema.get_default = function(adapter, settings)
        return {
          model = 'mock',
          opts = { stream = false }
        }
      end
    end

    -- Mock HTTP client
    local client_ok, client = pcall(require, 'codecompanion.http')
    local original_new = nil
    if client_ok and client then
      original_new = client.new
      client.new = function(opts)
        return {
          request = function(self, payload, callbacks, options)
            vim.schedule(function()
              if callbacks and callbacks.callback then
                callbacks.callback(nil, { content = 'Binary Search Algorithm' }, {
                  handlers = {
                    chat_output = function(adapter, data)
                      return {
                        status = 'success',
                        output = { content = 'Binary Search Algorithm' }
                      }
                    end
                  }
                })
              end
            end)
          end
        }
      end
    end

    local sessions = SessionManager.list_sessions()
    assert(#sessions == 1, 'Expected exactly one session after creation')
    local test_session = sessions[1]

    -- Test regenerate title
    SessionPicker._handle_regenerate_title(test_session, function() end)

    -- Wait for async operations to complete
    vim.wait(100)

    -- Verify the session was updated
    local updated_sessions = SessionManager.list_sessions()
    assert(updated_sessions[1].title == 'Binary Search Algorithm', 'Expected title to be regenerated')

    -- Restore original functions
    if adapters_ok and adapters and original_resolve then
      adapters.resolve = original_resolve
    end
    if schema_ok and schema and original_get_default then
      schema.get_default = original_get_default
    end
    if client_ok and client and original_new then
      client.new = original_new
    end
  ]])
end

T['delete all sessions functionality'] = function()
  child.lua([[
    local SessionManager = require('codecompanion._extensions.reasoning.helpers.session_manager')
    local SessionPicker = require('codecompanion._extensions.reasoning.ui.session_picker')

    -- Clean any existing sessions first
    local existing_sessions = SessionManager.list_sessions()
    for _, session in ipairs(existing_sessions) do
      SessionManager.delete_session(session.filename)
    end

    -- Create multiple test sessions
    for i = 1, 3 do
      local session_data = {
        version = '2.0',
        messages = { { role = 'user', content = 'Test message ' .. i } },
        metadata = { total_messages = 1 },
        config = { adapter = 'test', model = 'mock' },
        timestamp = os.time() + i,
        created_at = os.date('%Y-%m-%d %H:%M:%S'),
        title = 'Test Session ' .. i,
      }

      local ok, err = SessionManager.save_session_data(session_data, 'delete_all_test_' .. i .. '.lua')
      assert(ok, err)
    end

    -- Verify sessions were created
    local sessions = SessionManager.list_sessions()
    assert(#sessions == 3, 'Expected 3 sessions before delete all')

    -- Mock confirmation dialog to accept deletion
    _G.test_confirm_result = 1 -- Accept deletion

    -- Test delete all
    SessionPicker._handle_delete_all(function() end)

    -- Verify confirmation was shown
    assert(_G.test_confirm_msg:find('Delete all 3 sessions'), 'Expected delete all confirmation')

    -- Verify all sessions were deleted
    local remaining_sessions = SessionManager.list_sessions()
    assert(#remaining_sessions == 0, 'Expected no sessions after delete all')

    -- Verify notification
    local found_success = false
    for _, notif in ipairs(_G.test_notifications) do
      if notif.msg:find('Deleted 3 sessions') then
        found_success = true
        break
      end
    end
    assert(found_success, 'Expected success notification for delete all')
  ]])
end

T['toggle favorite functionality'] = function()
  child.lua([[
    local SessionManager = require('codecompanion._extensions.reasoning.helpers.session_manager')
    local SessionPicker = require('codecompanion._extensions.reasoning.ui.session_picker')

    -- Clean any existing sessions first
    local existing_sessions = SessionManager.list_sessions()
    for _, session in ipairs(existing_sessions) do
      SessionManager.delete_session(session.filename)
    end

    -- Create test session
    local session_data = {
      version = '2.0',
      messages = { { role = 'user', content = 'Test message' } },
      metadata = { total_messages = 1, favorite = false },
      config = { adapter = 'test', model = 'mock' },
      timestamp = os.time(),
      created_at = os.date('%Y-%m-%d %H:%M:%S'),
      title = 'Test Session',
    }

    local ok, err = SessionManager.save_session_data(session_data, 'favorite_test.lua')
    assert(ok, err)

    local sessions = SessionManager.list_sessions()
    local test_session = sessions[1]

    -- Initially not favorite
    assert(not test_session.is_favorite, 'Expected session to not be favorite initially')

    -- Toggle to favorite
    SessionPicker._handle_toggle_favorite(test_session, function() end)

    -- Verify favorite was toggled
    local updated_sessions = SessionManager.list_sessions()
    assert(updated_sessions[1].is_favorite, 'Expected session to be favorite after toggle')

    -- Toggle back to not favorite
    test_session = updated_sessions[1]
    SessionPicker._handle_toggle_favorite(test_session, function() end)

    -- Verify favorite was toggled back
    updated_sessions = SessionManager.list_sessions()
    assert(not updated_sessions[1].is_favorite, 'Expected session to not be favorite after second toggle')
  ]])
end

T['search sessions functionality'] = function()
  child.lua([[
    local SessionManager = require('codecompanion._extensions.reasoning.helpers.session_manager')
    local SessionPicker = require('codecompanion._extensions.reasoning.ui.session_picker')

    -- Clean any existing sessions first
    local existing_sessions = SessionManager.list_sessions()
    for _, session in ipairs(existing_sessions) do
      SessionManager.delete_session(session.filename)
    end

    -- Create test sessions with different content
    local sessions_data = {
      {
        title = 'Python Tutorial',
        messages = {{ role = 'user', content = 'Teach me Python basics' }},
        tags = {'python', 'programming', 'tutorial'}
      },
      {
        title = 'JavaScript Help',
        messages = {{ role = 'user', content = 'Help with JavaScript promises' }},
        tags = {'javascript', 'promises', 'async'}
      },
      {
        title = 'Database Design',
        messages = {{ role = 'user', content = 'How to design a database schema' }},
        tags = {'database', 'sql', 'design'}
      },
    }

    for i, data in ipairs(sessions_data) do
      local session_data = {
        version = '2.0',
        messages = data.messages,
        metadata = {
          total_messages = #data.messages,
          tags = data.tags
        },
        config = { adapter = 'test', model = 'mock' },
        timestamp = os.time() + i,
        created_at = os.date('%Y-%m-%d %H:%M:%S'),
        title = data.title,
      }

      local ok, err = SessionManager.save_session_data(session_data, 'search_test_' .. i .. '.lua')
      assert(ok, err)
    end

    -- Test search by title
    local all_sessions = SessionManager.list_sessions()
    assert(#all_sessions == 3, 'Expected 3 sessions for search test')

    -- Mock search functionality (this would normally open filtered picker)
    local function test_search(query, expected_count, expected_titles)
      local filtered_sessions = {}
      local normalized_query = query:lower()

      for _, session in ipairs(all_sessions) do
        local matches = false

        -- Search in title
        if session.title and session.title:lower():find(normalized_query, 1, true) then
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

      assert(#filtered_sessions == expected_count,
        string.format('Expected %d results for query "%s", got %d', expected_count, query, #filtered_sessions))

      if expected_titles then
        for _, expected_title in ipairs(expected_titles) do
          local found = false
          for _, session in ipairs(filtered_sessions) do
            if session.title == expected_title then
              found = true
              break
            end
          end
          assert(found, string.format('Expected to find session with title "%s"', expected_title))
        end
      end
    end

    -- Test different search queries
    test_search('python', 1, {'Python Tutorial'})
    test_search('javascript', 1, {'JavaScript Help'})
    test_search('programming', 1, {'Python Tutorial'}) -- by tag
    test_search('help', 1, {'JavaScript Help'})
    test_search('design', 1, {'Database Design'})
    test_search('nonexistent', 0)
  ]])
end

T['session tags generation'] = function()
  child.lua([[
    local SessionManager = require('codecompanion._extensions.reasoning.helpers.session_manager')

    -- Clean any existing sessions first
    local existing_sessions = SessionManager.list_sessions()
    for _, session in ipairs(existing_sessions) do
      SessionManager.delete_session(session.filename)
    end

    -- Create test session with content suitable for tag generation
    local session_data = {
      version = '2.0',
      messages = {
        { role = 'user', content = 'I need help with Python web development using Flask' },
        { role = 'assistant', content = 'Flask is a great framework for building web applications in Python...' },
        { role = 'user', content = 'How do I handle database connections?' },
        { role = 'assistant', content = 'You can use SQLAlchemy with Flask for database operations...' },
      },
      metadata = { total_messages = 4 },
      config = { adapter = 'test', model = 'mock' },
      timestamp = os.time(),
      created_at = os.date('%Y-%m-%d %H:%M:%S'),
      title = 'Flask Web Development',
    }

    -- Mock LLM request to return tags
    local original_make_llm_request = SessionManager._make_llm_request
    SessionManager._make_llm_request = function(session_data, prompt, callback)
      -- Verify the prompt is for tag generation
      assert(prompt:find('Generate 3%-5 relevant tags for this chat conversation'), 'Expected tag generation prompt')
      if callback then
        callback('python, flask, web development, database, sqlalchemy')
      end
    end

    -- Test tag generation
    local generated_tags = nil
    SessionManager._generate_session_tags(session_data, function(tags)
      generated_tags = tags
    end)

    -- Verify tags were generated
    assert(generated_tags, 'Expected tags to be generated')
    assert(#generated_tags == 5, 'Expected 5 tags to be generated')

    local expected_tags = {'python', 'flask', 'web development', 'database', 'sqlalchemy'}
    for i, expected_tag in ipairs(expected_tags) do
      assert(generated_tags[i] == expected_tag,
        string.format('Expected tag "%s" at position %d, got "%s"', expected_tag, i, generated_tags[i]))
    end

    -- Restore original function
    SessionManager._make_llm_request = original_make_llm_request
  ]])
end

T['regenerate tags functionality'] = function()
  child.lua([[
    local SessionManager = require('codecompanion._extensions.reasoning.helpers.session_manager')
    local SessionPicker = require('codecompanion._extensions.reasoning.ui.session_picker')

    -- Clean any existing sessions first
    local existing_sessions = SessionManager.list_sessions()
    for _, session in ipairs(existing_sessions) do
      SessionManager.delete_session(session.filename)
    end

    -- Create test session with existing tags
    local session_data = {
      version = '2.0',
      messages = {
        { role = 'user', content = 'Help me with React hooks' },
        { role = 'assistant', content = 'React hooks allow you to use state and other React features...' },
      },
      metadata = {
        total_messages = 2,
        tags = {'old', 'tags', 'to', 'replace'}
      },
      config = { adapter = 'test', model = 'mock' },
      timestamp = os.time(),
      created_at = os.date('%Y-%m-%d %H:%M:%S'),
      title = 'React Hooks Tutorial',
    }

    local ok, err = SessionManager.save_session_data(session_data, 'regenerate_tags_test.lua')
    assert(ok, err)

    -- Mock LLM request to return new tags
    local original_make_llm_request = SessionPicker._make_llm_request
    SessionPicker._make_llm_request = function(session_data, prompt, callback)
      if callback then
        callback('react, hooks, javascript, frontend, components')
      end
    end

    local sessions = SessionManager.list_sessions()
    local test_session = sessions[1]

    -- Verify old tags
    assert(#test_session.tags == 4, 'Expected 4 old tags')
    assert(test_session.tags[1] == 'old', 'Expected old tag')

    -- Test regenerate tags
    SessionPicker._handle_regenerate_tags(test_session, function() end)

    -- Verify tags were regenerated
    local updated_sessions = SessionManager.list_sessions()
    local updated_session = updated_sessions[1]

    assert(#updated_session.tags == 5, 'Expected 5 new tags')
    assert(updated_session.tags[1] == 'react', 'Expected new tag "react"')
    assert(updated_session.tags[2] == 'hooks', 'Expected new tag "hooks"')

    -- Restore original function
    SessionPicker._make_llm_request = original_make_llm_request
  ]])
end

T['favorite sessions sorting'] = function()
  child.lua([[
    local SessionManager = require('codecompanion._extensions.reasoning.helpers.session_manager')

    -- Clean any existing sessions first
    local existing_sessions = SessionManager.list_sessions()
    for _, session in ipairs(existing_sessions) do
      SessionManager.delete_session(session.filename)
    end

    -- Create sessions with different timestamps and favorite status
    local sessions_data = {
      {
        title = 'Oldest Session',
        timestamp = os.time() - 100,
        is_favorite = false
      },
      {
        title = 'Newest Non-Favorite',
        timestamp = os.time(),
        is_favorite = false
      },
      {
        title = 'Middle Favorite',
        timestamp = os.time() - 50,
        is_favorite = true
      },
      {
        title = 'Older Favorite',
        timestamp = os.time() - 75,
        is_favorite = true
      },
    }

    for i, data in ipairs(sessions_data) do
      local session_data = {
        version = '2.0',
        messages = {{ role = 'user', content = 'Test message ' .. i }},
        metadata = {
          total_messages = 1,
          favorite = data.is_favorite
        },
        config = { adapter = 'test', model = 'mock' },
        timestamp = data.timestamp,
        created_at = os.date('%Y-%m-%d %H:%M:%S', data.timestamp),
        title = data.title,
      }

      local ok, err = SessionManager.save_session_data(session_data, 'sorting_test_' .. i .. '.lua')
      assert(ok, err)
    end

    local sessions = SessionManager.list_sessions()
    assert(#sessions == 4, 'Expected 4 sessions for sorting test')

    -- Verify favorites come first
    assert(sessions[1].is_favorite, 'Expected first session to be favorite')
    assert(sessions[2].is_favorite, 'Expected second session to be favorite')
    assert(not sessions[3].is_favorite, 'Expected third session to not be favorite')
    assert(not sessions[4].is_favorite, 'Expected fourth session to not be favorite')

    -- Verify favorites are sorted by timestamp (newest first)
    assert(sessions[1].title == 'Middle Favorite', 'Expected newest favorite first')
    assert(sessions[2].title == 'Older Favorite', 'Expected older favorite second')

    -- Verify non-favorites are sorted by timestamp (newest first)
    assert(sessions[3].title == 'Newest Non-Favorite', 'Expected newest non-favorite third')
    assert(sessions[4].title == 'Oldest Session', 'Expected oldest session last')
  ]])
end

T['token estimation in sessions'] = function()
  child.lua([[
    local SessionManager = require('codecompanion._extensions.reasoning.helpers.session_manager')

    -- Clean any existing sessions first
    local existing_sessions = SessionManager.list_sessions()
    for _, session in ipairs(existing_sessions) do
      SessionManager.delete_session(session.filename)
    end

    -- Create session with known content size
    local large_content = string.rep('This is a test message with some content. ', 100) -- ~4000 characters
    local session_data = {
      version = '2.0',
      messages = {
        { role = 'user', content = large_content },
        { role = 'assistant', content = 'Short response' },
      },
      metadata = { total_messages = 2 },
      config = { adapter = 'test', model = 'mock' },
      timestamp = os.time(),
      created_at = os.date('%Y-%m-%d %H:%M:%S'),
      title = 'Token Estimation Test',
    }

    local ok, err = SessionManager.save_session_data(session_data, 'token_test.lua')
    assert(ok, err)

    local sessions = SessionManager.list_sessions()
    local test_session = sessions[1]

    -- Verify token estimation is present and reasonable
    assert(test_session.token_estimate, 'Expected token estimation to be present')
    assert(test_session.token_estimate > 0, 'Expected positive token estimate')

    -- Rough estimation should be around file_size / 4
    local expected_tokens = math.floor(test_session.file_size / 4)
    local tolerance = math.floor(expected_tokens * 0.2) -- 20% tolerance

    assert(math.abs(test_session.token_estimate - expected_tokens) <= tolerance,
      string.format('Expected token estimate around %d, got %d', expected_tokens, test_session.token_estimate))
  ]])
end

T['summarize session functionality'] = function()
  child.lua([[
    local SessionManager = require('codecompanion._extensions.reasoning.helpers.session_manager')
    local SessionPicker = require('codecompanion._extensions.reasoning.ui.session_picker')
    local SessionOptimizer = require('codecompanion._extensions.reasoning.helpers.session_optimizer')

    -- Clean any existing sessions first
    local existing_sessions = SessionManager.list_sessions()
    for _, session in ipairs(existing_sessions) do
      SessionManager.delete_session(session.filename)
    end

    -- Create session with multiple messages for summarization
    local session_data = {
      version = '2.0',
      messages = {
        { role = 'user', content = 'Can you help me understand React components?' },
        { role = 'assistant', content = 'React components are reusable pieces of UI...' },
        { role = 'user', content = 'What about functional components vs class components?' },
        { role = 'assistant', content = 'Functional components are simpler and use hooks...' },
        { role = 'user', content = 'How do I manage state in functional components?' },
        { role = 'assistant', content = 'You can use useState and useEffect hooks...' },
      },
      metadata = { total_messages = 6 },
      config = { adapter = 'test', model = 'mock' },
      timestamp = os.time(),
      created_at = os.date('%Y-%m-%d %H:%M:%S'),
      title = 'React Components Tutorial',
    }

    local ok, err = SessionManager.save_session_data(session_data, 'summarize_test.lua')
    assert(ok, err)

    -- Mock session optimizer to return a summary
    local original_new = SessionOptimizer.new
    SessionOptimizer.new = function()
      return {
        compact_session = function(self, session_data, callback)
          local compacted = vim.deepcopy(session_data)
          compacted.messages = {
            {
              role = 'assistant',
              content = '**[Session Summary - 6 messages compacted]**\n\nDiscussion about React components, including functional vs class components and state management with hooks.',
              opts = {
                tag = 'session_summary',
                compacted_at = os.time(),
                original_message_count = 6,
              },
            },
          }

          -- Immediately save the compacted data to make the test synchronous
          local success, save_err = SessionManager.save_session_data(compacted, 'summarize_test.lua')
          
          if callback then
            if success then
              callback(compacted, nil)  -- Pass nil as error
            else
              callback(nil, save_err)  -- Pass save error
            end
          end
        end
      }
    end

    local sessions = SessionManager.list_sessions()
    local test_session = sessions[1]

    -- Verify original message count
    local original_session_data = SessionManager.load_session(test_session.filename)
    assert(#original_session_data.messages == 6, 'Expected 6 original messages')

    -- Test summarize
    SessionPicker._handle_summarize(test_session, function() end)

    -- Small wait to ensure async operation completes
    vim.wait(100, function() return false end)

    -- Verify session was summarized
    local updated_session_data = SessionManager.load_session(test_session.filename)
    assert(#updated_session_data.messages == 1, 'Expected 1 message after summarization')
    assert(updated_session_data.messages[1].content:find('Session Summary'), 'Expected summary content')
    assert(updated_session_data.messages[1].opts.tag == 'session_summary', 'Expected summary tag')

    -- Restore original function
    SessionOptimizer.new = original_new
  ]])
end

T['session list display with favorites and tags'] = function()
  child.lua([[
    local SessionManager = require('codecompanion._extensions.reasoning.helpers.session_manager')

    -- Clean any existing sessions first
    local existing_sessions = SessionManager.list_sessions()
    for _, session in ipairs(existing_sessions) do
      SessionManager.delete_session(session.filename)
    end

    -- Create test session with favorite status and tags
    local session_data = {
      version = '2.0',
      messages = {{ role = 'user', content = 'Test message' }},
      metadata = {
        total_messages = 1,
        favorite = true,
        tags = {'python', 'testing', 'automation'}
      },
      config = { adapter = 'test', model = 'mock' },
      timestamp = os.time(),
      created_at = os.date('%Y-%m-%d %H:%M:%S'),
      title = 'Favorite Test Session',
    }

    local ok, err = SessionManager.save_session_data(session_data, 'display_test.lua')
    assert(ok, err)

    local sessions = SessionManager.list_sessions()
    local test_session = sessions[1]

    -- Verify session has favorite status and tags
    assert(test_session.is_favorite, 'Expected session to be favorite')
    assert(test_session.tags, 'Expected session to have tags')
    assert(#test_session.tags == 3, 'Expected 3 tags')
    assert(test_session.tags[1] == 'python', 'Expected first tag to be "python"')
    assert(test_session.tags[2] == 'testing', 'Expected second tag to be "testing"')
    assert(test_session.tags[3] == 'automation', 'Expected third tag to be "automation"')

    -- Verify token estimation is present
    assert(test_session.token_estimate, 'Expected token estimation to be present')
    assert(type(test_session.token_estimate) == 'number', 'Expected token estimation to be a number')
  ]])
end

return T
