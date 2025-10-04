-- filepath: tests/codecompanion/_extensions/reasoning/commands_test.lua
-- Moved from tests/test_session_optimizer_commands.lua
---@diagnostic disable: undefined-global
local MiniTest = require('mini.test')
local new_set = MiniTest.new_set

local T = new_set({
  hooks = {
    pre_case = function()
      vim.notify = function() end
      vim.schedule = function(fn)
        fn()
      end

      package.loaded['codecompanion.strategies.chat'] = {
        buf_get_chat = function(bufnr)
          if bufnr == 1 then
            return {
              messages = {
                { role = 'system', content = 'You are a helpful assistant.' },
                { role = 'user', content = 'Hello, can you help me?' },
                { role = 'assistant', content = "Of course! I'd be happy to help you." },
                { role = 'user', content = 'Thanks, I have a complex question about coding.' },
                { role = 'assistant', content = 'Please go ahead and ask your coding question!' },
              },
              adapter = {
                name = 'test_adapter',
                map_schema_to_params = function(_, params)
                  return params
                end,
                map_roles = function(_, messages)
                  return messages
                end,
                handlers = {
                  chat_output = function()
                    return {
                      status = 'success',
                      output = { content = 'This chat covers a user greeting and a request for coding help.' },
                    }
                  end,
                },
              },
              settings = { model = 'test_model' },
              opts = { title = 'Test Chat' },
              render = function() end,
            }
          else
            error('No chat found')
          end
        end,
      }

      vim.api.nvim_get_current_buf = function()
        return 1
      end
      vim.api.nvim_buf_is_valid = function()
        return true
      end
    end,
    post_case = function()
      vim.notify = function(msg, level)
        print(msg)
      end
    end,
  },
})

local Commands = require('codecompanion._extensions.reasoning.commands')

T['optimize_current_session should get current chat object'] = function()
  local adapters = require('codecompanion.adapters')
  local schema = require('codecompanion.schema')
  local http = require('codecompanion.http')

  local original_resolve = adapters and adapters.resolve
  local original_get_default = schema and schema.get_default
  local original_http_new = http and http.new

  if adapters then
    adapters.resolve = function(name)
      return {
        map_schema_to_params = function(_, params)
          return params
        end,
        map_roles = function(_, messages)
          return messages
        end,
        handlers = {
          chat_output = function()
            return {
              status = 'success',
              output = { content = 'This chat covers a user greeting and a request for coding help.' },
            }
          end,
        },
      }
    end
  end

  if schema then
    schema.get_default = function(_, opts)
      opts = opts or {}
      opts.model = opts.model or 'test_model'
      return opts
    end
  end

  if http then
    http.new = function(opts)
      return {
        request = function(_, _, handlers)
          handlers.callback(
            nil,
            { output = { content = 'This chat covers a user greeting and a request for coding help.' } }
          )
        end,
      }
    end
  end

  require('codecompanion._extensions.reasoning.helpers.session_manager').auto_save_session = function()
    return true
  end

  Commands.optimize_current_session()

  if adapters then
    adapters.resolve = original_resolve
  end
  if schema then
    schema.get_default = original_get_default
  end
  if http then
    http.new = original_http_new
  end
end

T['optimize_current_session should handle no active chat gracefully'] = function()
  vim.api.nvim_get_current_buf = function()
    return 99
  end
  local notified = false
  vim.notify = function(msg, level)
    if msg:find('No active CodeCompanion chat found') then
      notified = true
    end
  end
  Commands.optimize_current_session()
  MiniTest.expect.equality(notified, true)
  vim.api.nvim_get_current_buf = function()
    return 1
  end
end

T['optimize_current_session should handle empty messages'] = function()
  package.loaded['codecompanion.strategies.chat'].buf_get_chat = function(bufnr)
    return { messages = {}, adapter = { name = 'test_adapter' } }
  end
  local notified = false
  vim.notify = function(msg, level)
    if msg:find('No messages to optimize') then
      notified = true
    end
  end
  Commands.optimize_current_session()
  MiniTest.expect.equality(notified, true)
end

return T
