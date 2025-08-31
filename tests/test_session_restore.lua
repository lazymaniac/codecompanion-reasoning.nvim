local h = require('tests.helpers')

local new_set = MiniTest.new_set

local child = MiniTest.new_child_neovim()
local T = new_set({
  hooks = {
    pre_once = function()
      h.child_start(child)
      child.lua([[
        h = require('tests.helpers')

        -- Minimal mocks for CodeCompanion
        package.loaded['codecompanion.utils.context'] = {
          get = function(_) return {} end,
        }
        package.loaded['codecompanion.utils'] = {
          fire = function(_) end,
        }

        local in_use = {}
        package.loaded['codecompanion.strategies.chat'] = {
          new = function(opts)
            local bufnr = vim.api.nvim_create_buf(true, false)
            local chat = {
              bufnr = bufnr,
              id = 'chat-test',
              tool_registry = {
                in_use = in_use,
                add = function(_, name) in_use[name] = true end,
                add_group = function() end,
              },
              added = { history = 0, buffer = 0, tool = 0 },
              add_tool_output = function(self, _, _)
                self.added.tool = self.added.tool + 1
              end,
              add_message = function(self, _, _)
                self.added.history = self.added.history + 1
              end,
              add_buf_message = function(self, _)
                self.added.buffer = self.added.buffer + 1
              end,
            }
            _G.__RESTORE_LAST_CHAT = chat
            return chat
          end,
        }

        package.loaded['codecompanion.config'] = {
          default_adapter = 'test',
          adapters = { test = {} },
          strategies = { chat = { tools = { groups = {} } } },
        }

        SessionManager = require('codecompanion._extensions.reasoning.helpers.session_manager')

        -- Use a temp sessions dir in project workspace
        local tmp = vim.fn.getcwd() .. '/tests/tmp_sessions'
        vim.fn.mkdir(tmp, 'p')
        SessionManager.setup({ sessions_dir = tmp })
      ]])
    end,
    post_once = child.stop,
  },
})

T['restores all visible messages'] = function()
  child.lua([[
    local messages = {}
    for i = 1, 78 do
      local role = (i % 2 == 0) and 'assistant' or 'user'
      table.insert(messages, { role = role, content = 'msg ' .. i })
    end

    local session_data = {
      version = '2.0',
      messages = messages,
      metadata = { total_messages = #messages },
      config = { adapter = 'test', model = 'mock' },
      tools = {},
      timestamp = os.time(),
    }

    local filename = 'session_restore_test.lua'
    local ok, err = SessionManager.save_session_data(session_data, filename)
    assert(ok, err)

    local restored, restore_err = SessionManager.restore_session(filename)
    assert(restored, restore_err)
  ]])
  -- Validate added messages went to buffer
  child.lua(
    [[ chat_counts = _G.__RESTORE_LAST_CHAT and _G.__RESTORE_LAST_CHAT.added or { history = -1, buffer = -1 } ]]
  )
  local counts = child.lua_get('chat_counts')
  h.eq(78, counts.history)
  h.eq(78, counts.buffer)
end

T['restores tool call cycles visibly'] = function()
  child.lua([[
    local session_data = {
      version = '2.0',
      messages = {
        { role = 'user', content = 'Please ask me a question' },
        { role = 'assistant', content = '', tool_calls = { { ["function"] = { name = 'ask_user', arguments = '{"q":"hi"}' }, id = 'abc' } } },
        { role = 'tool', tool_call_id = 'abc', tool_name = 'ask_user', content = 'Answer: hello' },
        { role = 'assistant', content = 'Thanks!' },
      },
      metadata = { total_messages = 4 },
      config = { adapter = 'test', model = 'mock' },
      tools = { 'ask_user' },
      timestamp = os.time(),
    }

    local filename = 'session_tool_cycle_test.lua'
    local ok, err = SessionManager.save_session_data(session_data, filename)
    assert(ok, err)

    local restored, restore_err = SessionManager.restore_session(filename)
    assert(restored, restore_err)
  ]])

  child.lua(
    [[ chat_counts = _G.__RESTORE_LAST_CHAT and _G.__RESTORE_LAST_CHAT.added or { history = -1, buffer = -1, tool = -1 } ]]
  )
  local counts = child.lua_get('chat_counts')
  -- Expect 3 regular messages (user, assistant tool_call, assistant follow-up) and 1 tool output
  h.eq(3, counts.history)
  h.eq(3, counts.buffer)
  h.eq(1, counts.tool)
end

return T
