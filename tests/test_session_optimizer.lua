---@diagnostic disable: undefined-global
local MiniTest = require('mini.test')
local helpers = require('tests.helpers')

local new_set = MiniTest.new_set

local T = new_set({
  hooks = {
    pre_case = function()
      T._saved_modules = {
        http = package.loaded['codecompanion.http'],
        schema = package.loaded['codecompanion.schema'],
        adapters = package.loaded['codecompanion.adapters'],
        optimizer = package.loaded['codecompanion._extensions.reasoning.helpers.session_optimizer'],
      }
      package.loaded['codecompanion._extensions.reasoning.helpers.session_optimizer'] = nil
    end,
    post_case = function()
      package.loaded['codecompanion.http'] = T._saved_modules.http
      package.loaded['codecompanion.schema'] = T._saved_modules.schema
      package.loaded['codecompanion.adapters'] = T._saved_modules.adapters
      package.loaded['codecompanion._extensions.reasoning.helpers.session_optimizer'] = T._saved_modules.optimizer
      T._saved_modules = nil
    end,
  },
})

T['compact_session uses stored config adapter'] = function()
  local resolve_calls = {}
  local captured_settings

  local mock_adapter = {
    name = 'mock_adapter',
  }
  function mock_adapter:map_schema_to_params(settings)
    return settings
  end
  function mock_adapter:map_roles(messages)
    return messages
  end
  mock_adapter.handlers = {
    chat_output = function(_, _adapter_data)
      return {
        status = 'success',
        output = { content = 'Mock summary from adapter' },
      }
    end,
  }

  package.loaded['codecompanion.adapters'] = {
    resolve = function(name)
      table.insert(resolve_calls, name)
      if name == 'mock_adapter' then
        return mock_adapter
      end
      return nil
    end,
  }

  package.loaded['codecompanion.schema'] = {
    get_default = function(_, opts)
      opts = opts or {}
      if not opts.model then
        opts.model = 'schema-default-model'
      end
      return opts
    end,
  }

  package.loaded['codecompanion.http'] = {
    new = function(opts)
      captured_settings = opts.adapter
      return {
        request = function(_, _, options)
          options.callback(nil, { output = { content = 'Mock summary from adapter' } }, mock_adapter)
        end,
      }
    end,
  }

  local SessionOptimizer = require('codecompanion._extensions.reasoning.helpers.session_optimizer')
  local optimizer = SessionOptimizer.new()

  local session_data = {
    messages = {
      { role = 'user', content = 'Hello' },
      { role = 'assistant', content = 'Hi' },
      { role = 'user', content = 'How are you?' },
      { role = 'assistant', content = 'Doing well!' },
      { role = 'user', content = 'Thanks' },
    },
    config = {
      adapter = 'mock_adapter',
      model = 'stored-model',
    },
  }

  local result, err
  optimizer:compact_session(session_data, function(compacted, error_msg)
    result = compacted
    err = error_msg
  end)

  helpers.eq(nil, err)
  helpers.expect_truthy(result)
  helpers.eq(1, #result.messages)
  helpers.expect_contains('Mock summary from adapter', result.messages[1].content)
  helpers.expect_truthy(vim.tbl_contains(resolve_calls, 'mock_adapter'))
  helpers.eq('stored-model', captured_settings.model)
end

return T
