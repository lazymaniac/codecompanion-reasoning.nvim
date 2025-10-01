---@diagnostic disable: undefined-global
local MiniTest = require('mini.test')
local expect = MiniTest.expect

local Config = require('codecompanion._extensions.reasoning.config')

local function reset_config()
  Config.setup()
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

local T = MiniTest.new_set({
  hooks = {
    pre_case = reset_config,
    post_case = reset_config,
  },
})

T['Session optimizer uses configured adapter and model'] = function()
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

T['Title generator uses configured adapter'] = function()
  Config.setup({
    session_title_generator = {
      adapter = 'stub-adapter',
      model = 'stub-model',
    },
  })

  local resolve_calls = {}

  local stub_adapter = build_mock_adapter({ output = 'Generated Title' })

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
        opts.model = opts.model or 'default-title-model'
        return opts
      end,
    },
    ['codecompanion.http'] = {
      new = function()
        return {
          request = function(_, _, handlers)
            handlers.callback(nil, { output = { content = 'Generated Title' } }, stub_adapter)
          end,
        }
      end,
    },
  }, function()
    package.loaded['codecompanion._extensions.reasoning.helpers.session_title_generator'] = nil
    local TitleGenerator = require('codecompanion._extensions.reasoning.helpers.session_title_generator')
    local generator = TitleGenerator.new()

    local chat = {
      adapter = 'unused',
      messages = {
        { role = 'user', content = 'Plan feature work' },
      },
      opts = {},
    }

    local titles = {}
    generator:generate(chat, function(title)
      table.insert(titles, title)
    end)

    expect.equality(resolve_calls[#resolve_calls], 'stub-adapter')
    expect.equality(titles[#titles], 'Generated Title')
  end)
end

T['Reasoning extension registers tools into CodeCompanion config'] = function()
  local original_config = package.loaded['codecompanion.config']

  local mock_config = {
    strategies = {
      chat = {
        tools = {},
      },
    },
    opts = {},
  }

  package.loaded['codecompanion.config'] = mock_config

  Config.setup()

  local ok, extension = pcall(require, 'codecompanion._extensions.reasoning')
  expect.equality(ok, true)

  local result = extension.setup()
  expect.no_equality(result, nil)

  local tools = mock_config.strategies.chat.tools
  expect.no_equality(tools.meta_agent, nil)
  expect.no_equality(tools.add_tools, nil)
  expect.no_equality(tools.project_knowledge, nil)

  package.loaded['codecompanion.config'] = original_config
end

return T
