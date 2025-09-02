---@diagnostic disable: undefined-global
local MiniTest = require('mini.test')
local new_set = MiniTest.new_set

-- Session Optimizer Commands test suite
local T = new_set({
  hooks = {
    pre_case = function()
      -- Mock vim.notify to avoid test noise
      vim.notify = function() end

      -- Mock vim.schedule to make async operations synchronous for testing
      vim.schedule = function(fn)
        fn()
      end

      -- Mock CodeCompanion strategies
      package.loaded['codecompanion.strategies.chat'] = {
        buf_get_chat = function(bufnr)
          if bufnr == 1 then -- Mock valid buffer
            return {
              messages = {
                { role = 'system', content = 'You are a helpful assistant.' },
                { role = 'user', content = 'Hello, can you help me?' },
                { role = 'assistant', content = "Of course! I'd be happy to help you." },
                { role = 'user', content = 'Thanks, I have a complex question about coding.' },
                { role = 'assistant', content = 'Please go ahead and ask your coding question!' },
              },
              adapter = { name = 'test_adapter' },
              settings = { model = 'test_model' },
              opts = { title = 'Test Chat' },
              render = function() end,
            }
          else
            error('No chat found')
          end
        end,
      }

      -- Mock vim.api functions
      vim.api.nvim_get_current_buf = function()
        return 1
      end
      vim.api.nvim_buf_is_valid = function()
        return true
      end
    end,

    post_case = function()
      -- Restore vim.notify
      vim.notify = function(msg, level)
        print(msg)
      end
    end,
  },
})

local Commands = require('codecompanion._extensions.reasoning.commands')

T['optimize_current_session'] = new_set()

T['optimize_current_session']['should get current chat object'] = function()
  local success = true
  local error_msg = nil

  -- Mock the SessionOptimizer to test chat extraction
  local original_new = require('codecompanion._extensions.reasoning.helpers.session_optimizer').new
  require('codecompanion._extensions.reasoning.helpers.session_optimizer').new = function()
    return {
      compact_session = function(self, session_data, callback)
        -- Verify we got the right data
        MiniTest.expect.equality(#session_data.messages, 5)
        MiniTest.expect.equality(session_data.messages[1].role, 'system')
        MiniTest.expect.equality(session_data.adapter.name, 'test_adapter')

        -- Return a mock optimized session
        callback({
          messages = {
            {
              role = 'assistant',
              content = '**[Session Summary - 5 messages compacted]**\n\nThis chat covers a user greeting and a request for coding help.',
              opts = {
                tag = 'session_summary',
                compacted_at = os.time(),
                original_message_count = 5,
              },
            },
          },
          metadata = {
            compaction = {
              original_message_count = 5,
              compacted_message_count = 1,
            },
          },
        })
      end,
    }
  end

  -- Mock SessionManager
  require('codecompanion._extensions.reasoning.helpers.session_manager').auto_save_session = function()
    return true
  end

  -- Test the function
  Commands.optimize_current_session()

  -- Restore the original
  require('codecompanion._extensions.reasoning.helpers.session_optimizer').new = original_new
end

T['optimize_current_session']['should handle no active chat gracefully'] = function()
  -- Mock current buffer to return invalid chat
  vim.api.nvim_get_current_buf = function()
    return 99
  end -- Invalid buffer

  local notified = false
  vim.notify = function(msg, level)
    if msg:find('No active CodeCompanion chat found') then
      notified = true
    end
  end

  Commands.optimize_current_session()

  MiniTest.expect.equality(notified, true)

  -- Restore
  vim.api.nvim_get_current_buf = function()
    return 1
  end
end

T['optimize_current_session']['should handle empty messages'] = function()
  -- Mock chat with no messages
  package.loaded['codecompanion.strategies.chat'].buf_get_chat = function(bufnr)
    return {
      messages = {},
      adapter = { name = 'test_adapter' },
    }
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
