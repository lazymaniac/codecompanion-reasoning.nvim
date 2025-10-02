---@diagnostic disable: undefined-field
---Test for compacted title prefix functionality
local SessionOptimizer = require('codecompanion._extensions.reasoning.helpers.session_optimizer')

local T = MiniTest.new_set({
  hooks = {
    pre_once = function()
      -- No global setup needed
    end,
  },
})

T['adds compacted prefix to session title'] = function()
  local optimizer = SessionOptimizer.new()

  local session_data = {
    messages = {
      { role = 'user', content = 'Test question' },
      { role = 'assistant', content = 'Test response' },
    },
    title = 'Original Session Title',
    adapter = 'test',
    settings = {},
  }

  local callback_called = false
  local compacted_result = nil

  -- Mock the _make_summarization_request to simulate successful compaction
  optimizer._make_summarization_request = function(self, session_data, prompt, callback)
    vim.schedule(function()
      callback('This is a test summary of the conversation.')
    end)
  end

  optimizer:compact_session(session_data, function(result, error_msg)
    callback_called = true
    compacted_result = result
  end)

  -- Wait for async callback
  local attempts = 0
  while not callback_called and attempts < 100 do
    vim.wait(10)
    attempts = attempts + 1
  end

  MiniTest.expect.equality(callback_called, true)
  MiniTest.expect.no_equality(compacted_result, nil)
  MiniTest.expect.equality(compacted_result.title, '[compacted] Original Session Title')
end

T['does not duplicate compacted prefix'] = function()
  local optimizer = SessionOptimizer.new()

  local session_data = {
    messages = {
      { role = 'user', content = 'Test question' },
      { role = 'assistant', content = 'Test response' },
    },
    title = '[compacted] Already Compacted Title',
    adapter = 'test',
    settings = {},
  }

  local callback_called = false
  local compacted_result = nil

  -- Mock the _make_summarization_request to simulate successful compaction
  optimizer._make_summarization_request = function(self, session_data, prompt, callback)
    vim.schedule(function()
      callback('This is a test summary of the conversation.')
    end)
  end

  optimizer:compact_session(session_data, function(result, error_msg)
    callback_called = true
    compacted_result = result
  end)

  -- Wait for async callback
  local attempts = 0
  while not callback_called and attempts < 100 do
    vim.wait(10)
    attempts = attempts + 1
  end

  MiniTest.expect.equality(callback_called, true)
  MiniTest.expect.no_equality(compacted_result, nil)
  MiniTest.expect.equality(compacted_result.title, '[compacted] Already Compacted Title')
end

T['handles session with no title'] = function()
  local optimizer = SessionOptimizer.new()

  local session_data = {
    messages = {
      { role = 'user', content = 'Test question' },
      { role = 'assistant', content = 'Test response' },
    },
    -- No title field
    adapter = 'test',
    settings = {},
  }

  local callback_called = false
  local compacted_result = nil

  -- Mock the _make_summarization_request to simulate successful compaction
  optimizer._make_summarization_request = function(self, session_data, prompt, callback)
    vim.schedule(function()
      callback('This is a test summary of the conversation.')
    end)
  end

  optimizer:compact_session(session_data, function(result, error_msg)
    callback_called = true
    compacted_result = result
  end)

  -- Wait for async callback
  local attempts = 0
  while not callback_called and attempts < 100 do
    vim.wait(10)
    attempts = attempts + 1
  end

  MiniTest.expect.equality(callback_called, true)
  MiniTest.expect.no_equality(compacted_result, nil)
  MiniTest.expect.equality(compacted_result.title, '[compacted] Untitled')
end

T['handles session with empty title'] = function()
  local optimizer = SessionOptimizer.new()

  local session_data = {
    messages = {
      { role = 'user', content = 'Test question' },
      { role = 'assistant', content = 'Test response' },
    },
    title = '',
    adapter = 'test',
    settings = {},
  }

  local callback_called = false
  local compacted_result = nil

  -- Mock the _make_summarization_request to simulate successful compaction
  optimizer._make_summarization_request = function(self, session_data, prompt, callback)
    vim.schedule(function()
      callback('This is a test summary of the conversation.')
    end)
  end

  optimizer:compact_session(session_data, function(result, error_msg)
    callback_called = true
    compacted_result = result
  end)

  -- Wait for async callback
  local attempts = 0
  while not callback_called and attempts < 100 do
    vim.wait(10)
    attempts = attempts + 1
  end

  MiniTest.expect.equality(callback_called, true)
  MiniTest.expect.no_equality(compacted_result, nil)
  MiniTest.expect.equality(compacted_result.title, '[compacted] Untitled')
end

return T
