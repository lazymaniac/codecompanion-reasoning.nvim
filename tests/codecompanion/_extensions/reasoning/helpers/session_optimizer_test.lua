-- filepath: tests/codecompanion/_extensions/reasoning/helpers/session_optimizer_test.lua
-- Combined tests for session_optimizer: adapter/model usage, compaction behavior, and title prefixing

local MiniTest = require('mini.test')
local Config = require('codecompanion._extensions.reasoning.config')

-- =====================
-- From tests/test_session_optimizer.lua
-- =====================
local saved_modules = {}

local function restore_modules()
  package.loaded['codecompanion.http'] = saved_modules.http
  package.loaded['codecompanion.schema'] = saved_modules.schema
  package.loaded['codecompanion.adapters'] = saved_modules.adapters
  package.loaded['codecompanion._extensions.reasoning.helpers.session_optimizer'] = nil
  saved_modules = {}
end

local T = MiniTest.new_set({
  hooks = {
    pre_case = function()
      Config.setup()
      saved_modules = {
        http = package.loaded['codecompanion.http'],
        schema = package.loaded['codecompanion.schema'],
        adapters = package.loaded['codecompanion.adapters'],
      }
      package.loaded['codecompanion._extensions.reasoning.helpers.session_optimizer'] = nil
    end,
    post_case = function()
      restore_modules()
    end,
  },
})

T['compact_session uses configured adapter and produces summary message'] = function()
  Config.setup({
    session_optimizer = {
      adapter = 'mock_adapter',
      model = 'mock-model',
      summary_max_words = 50,
    },
  })

  local resolve_calls = {}
  local captured_http_opts

  local mock_adapter = {
    map_schema_to_params = function(_, params)
      return params
    end,
    map_roles = function(_, messages)
      return messages
    end,
    handlers = {
      chat_output = function(_, _data)
        return {
          status = 'success',
          output = { content = 'Condensed conversation summary' },
        }
      end,
    },
  }

  package.loaded['codecompanion.adapters'] = {
    resolve = function(name)
      table.insert(resolve_calls, name)
      return mock_adapter
    end,
  }

  package.loaded['codecompanion.schema'] = {
    get_default = function(_, opts)
      opts = opts or {}
      if not opts.model then
        opts.model = 'schema-model'
      end
      return opts
    end,
  }

  package.loaded['codecompanion.http'] = {
    new = function(opts)
      captured_http_opts = opts.adapter
      return {
        request = function(_, _, handlers)
          handlers.callback(nil, { output = { content = 'Condensed conversation summary' } }, mock_adapter)
        end,
      }
    end,
  }

  local SessionOptimizer = require('codecompanion._extensions.reasoning.helpers.session_optimizer')
  local optimizer = SessionOptimizer.new()

  local session_data = {
    messages = {
      { role = 'user', content = 'Please summarize our deployment checklist.' },
      { role = 'assistant', content = 'Checklist includes migrations, API restart, cache warmup.' },
      { role = 'user', content = 'Add verification steps.' },
    },
    config = { adapter = 'unused', model = 'unused' },
  }

  local compacted
  optimizer:compact_session(session_data, function(result, err)
    MiniTest.expect.equality(err, nil)
    compacted = result
  end)

  MiniTest.expect.no_equality(compacted, nil)
  MiniTest.expect.equality(#compacted.messages, 2)
  MiniTest.expect.equality(resolve_calls[#resolve_calls], 'mock_adapter')
  MiniTest.expect.equality(captured_http_opts.model, 'mock-model')
  MiniTest.expect.equality(compacted.messages[2].opts.tag, 'session_summary')
end

T['compact_session returns original data when messages missing'] = function()
  local SessionOptimizer = require('codecompanion._extensions.reasoning.helpers.session_optimizer')
  local optimizer = SessionOptimizer.new()

  local input = { metadata = { example = true } }
  local output
  optimizer:compact_session(input, function(result)
    output = result
  end)

  MiniTest.expect.equality(output, input)
end

-- =====================
-- From tests/test_compacted_title_prefix.lua
-- =====================
T['adds compacted prefix to session title'] = function()
  local SessionOptimizer = require('codecompanion._extensions.reasoning.helpers.session_optimizer')
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

  optimizer._make_summarization_request = function(self, session_data, prompt, callback)
    vim.schedule(function()
      callback('This is a test summary of the conversation.')
    end)
  end

  optimizer:compact_session(session_data, function(result, _)
    callback_called = true
    compacted_result = result
  end)

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
  local SessionOptimizer = require('codecompanion._extensions.reasoning.helpers.session_optimizer')
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

  optimizer._make_summarization_request = function(self, session_data, prompt, callback)
    vim.schedule(function()
      callback('This is a test summary of the conversation.')
    end)
  end

  optimizer:compact_session(session_data, function(result, _)
    callback_called = true
    compacted_result = result
  end)

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
  local SessionOptimizer = require('codecompanion._extensions.reasoning.helpers.session_optimizer')
  local optimizer = SessionOptimizer.new()

  local session_data = {
    messages = {
      { role = 'user', content = 'Test question' },
      { role = 'assistant', content = 'Test response' },
    },
    adapter = 'test',
    settings = {},
  }

  local callback_called = false
  local compacted_result = nil

  optimizer._make_summarization_request = function(self, session_data, prompt, callback)
    vim.schedule(function()
      callback('This is a test summary of the conversation.')
    end)
  end

  optimizer:compact_session(session_data, function(result, _)
    callback_called = true
    compacted_result = result
  end)

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
  local SessionOptimizer = require('codecompanion._extensions.reasoning.helpers.session_optimizer')
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

  optimizer._make_summarization_request = function(self, session_data, prompt, callback)
    vim.schedule(function()
      callback('This is a test summary of the conversation.')
    end)
  end

  optimizer:compact_session(session_data, function(result, _)
    callback_called = true
    compacted_result = result
  end)

  local attempts = 0
  while not callback_called and attempts < 100 do
    vim.wait(10)
    attempts = attempts + 1
  end

  MiniTest.expect.equality(callback_called, true)
  MiniTest.expect.no_equality(compacted_result, nil)
  MiniTest.expect.equality(compacted_result.title, '[compacted] Untitled')
end

-- =====================
-- From tests/test_functionality_adapters.lua (optimizer specific)
-- =====================
local expect = MiniTest.expect

local function build_mock_adapter(opts)
  opts = opts or {}
  return {
    name = opts.name or 'mock_adapter',
    map_schema_to_params = function(_, params)
      return params
    end,
    map_roles = function(_, messages)
      return messages
    end,
    handlers = opts.handlers or {
      chat_output = function(_, _adapter_data)
        return {
          status = 'success',
          output = { content = opts.output or 'Mock output' },
        }
      end,
    },
  }
end

local function with_stubbed_modules(stubs, fn)
  local saved = {}
  for name, value in pairs(stubs) do
    saved[name] = package.loaded[name]
    package.loaded[name] = value
  end

  local ok, result = pcall(fn)

  for name, value in pairs(saved) do
    package.loaded[name] = value
  end

  if not ok then
    error(result)
  end

  return result
end

T['Session optimizer uses configured adapter and model (from functionality adapters)'] = function()
  Config.setup({
    session_optimizer = {
      adapter = 'mock_adapter',
      model = 'stored-model',
      summary_max_words = 123,
    },
  })

  local resolve_calls = {}
  local captured_http_settings

  local stub_adapter = build_mock_adapter({ output = 'Summarized content' })

  with_stubbed_modules({
    ['codecompanion.adapters'] = {
      resolve = function(name)
        table.insert(resolve_calls, name)
        if name == 'mock_adapter' then
          return stub_adapter
        end
        return nil
      end,
    },
    ['codecompanion.schema'] = {
      get_default = function(_, opts)
        opts = opts or {}
        if not opts.model then
          opts.model = 'schema-default'
        end
        return opts
      end,
    },
    ['codecompanion.http'] = {
      new = function(http_opts)
        captured_http_settings = http_opts.adapter
        return {
          request = function(_, _, handlers)
            handlers.callback(nil, { output = { content = 'Summarized content' } }, stub_adapter)
          end,
        }
      end,
    },
  }, function()
    package.loaded['codecompanion._extensions.reasoning.helpers.session_optimizer'] = nil
    local SessionOptimizer = require('codecompanion._extensions.reasoning.helpers.session_optimizer')
    local optimizer = SessionOptimizer.new()

    local session_data = {
      messages = {
        { role = 'user', content = 'Hello' },
        { role = 'assistant', content = 'Hi' },
        { role = 'user', content = 'Summarize please' },
      },
      config = {
        adapter = 'ignored-adapter',
        model = 'ignored-model',
      },
    }

    local summary
    optimizer:compact_session(session_data, function(compacted, err)
      expect.equality(err, nil)
      summary = compacted
    end)

    expect.no_equality(summary, nil)
    expect.equality(#resolve_calls >= 1, true)
    expect.equality(resolve_calls[#resolve_calls], 'mock_adapter')
    expect.equality(captured_http_settings.model, 'stored-model')
  end)
end

T['Session optimizer reflects updated configuration'] = function()
  local resolve_calls = {}

  local stub_adapter = build_mock_adapter({ output = 'Summary A' })

  local function run_compaction()
    with_stubbed_modules({
      ['codecompanion.adapters'] = {
        resolve = function(name)
          table.insert(resolve_calls, name)
          return stub_adapter
        end,
      },
      ['codecompanion.schema'] = {
        get_default = function(_, opts)
          opts = opts or {}
          opts.model = opts.model or 'default-model'
          return opts
        end,
      },
      ['codecompanion.http'] = {
        new = function()
          return {
            request = function(_, _, handlers)
              handlers.callback(nil, { output = { content = 'Summary A' } }, stub_adapter)
            end,
          }
        end,
      },
    }, function()
      package.loaded['codecompanion._extensions.reasoning.helpers.session_optimizer'] = nil
      local SessionOptimizer = require('codecompanion._extensions.reasoning.helpers.session_optimizer')
      local optimizer = SessionOptimizer.new()
      optimizer:compact_session({
        messages = {
          { role = 'user', content = 'one' },
          { role = 'assistant', content = 'two' },
        },
      }, function() end)
    end)
  end

  Config.setup({ session_optimizer = { adapter = 'adapter-one' } })
  run_compaction()

  Config.setup({ session_optimizer = { adapter = 'adapter-two' } })
  run_compaction()

  expect.equality(resolve_calls[1], 'adapter-one')
  expect.equality(resolve_calls[2], 'adapter-two')
end

return T
