local MiniTest = require('mini.test')
local Config = require('codecompanion._extensions.reasoning.config')

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
  MiniTest.expect.equality(#compacted.messages, 1)
  MiniTest.expect.equality(resolve_calls[#resolve_calls], 'mock_adapter')
  MiniTest.expect.equality(captured_http_opts.model, 'mock-model')
  MiniTest.expect.equality(compacted.messages[1].opts.tag, 'session_summary')
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

return T
