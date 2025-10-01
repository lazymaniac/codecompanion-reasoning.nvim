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

        _G.__RESTORE_CHAT_NEW_CALLS = 0

        local in_use = {}

        local function build_chat()
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
            clear = function(self)
              self.messages = {}
              self.added.history = 0
              self.added.buffer = 0
              self.added.tool = 0
            end,
            apply_settings = function(self, settings)
              self.settings = vim.tbl_deep_extend('force', self.settings or {}, settings or {})
            end,
            apply_model = function(self, model)
              self.settings = self.settings or {}
              self.settings.model = model
            end,
            change_adapter = function(self, adapter, model)
              self.settings = self.settings or {}
              self.settings.adapter = adapter
              self.settings.model = model
            end,
            settings = {},
          }
          return chat
        end

        package.loaded['codecompanion.strategies.chat'] = {
          new = function(opts)
            _G.__RESTORE_CHAT_NEW_CALLS = (_G.__RESTORE_CHAT_NEW_CALLS or 0) + 1
            local chat = build_chat()
            _G.__RESTORE_LAST_CHAT = chat
            return chat
          end,
          buf_get_chat = function(bufnr)
            if _G.__RESTORE_LAST_CHAT and _G.__RESTORE_LAST_CHAT.bufnr == bufnr then
              return _G.__RESTORE_LAST_CHAT
            end
            return nil
          end,
        }

        package.loaded['codecompanion.config'] = {
          default_adapter = 'test',
          adapters = { test = {} },
          strategies = { chat = { tools = { groups = {} } } },
        }

        package.loaded['codecompanion.adapters'] = {
          resolve = function(name)
            if name == 'test' then
              return {
                schema = {},
              }
            end
            return nil
          end,
          make_safe = function(adapter)
            return adapter
          end,
        }

        normalize_content = function(content)
          if type(content) == 'table' then
            return normalize_content(vim.inspect(content))
          end
          return vim.trim(tostring(content or ''))
        end

        SessionManager = require('codecompanion._extensions.reasoning.helpers.session_manager')

        -- Use a temp sessions dir in project workspace
        local tmp = vim.fn.getcwd() .. '/tests/tmp_sessions'
        vim.fn.mkdir(tmp, 'p')
        local Config = require('codecompanion._extensions.reasoning.config')
        Config.setup({
          session_history = {
            sessions_dir = tmp,
            continue_last_session = false,
            auto_generate_title = true,
          },
        })
        SessionManager.setup()
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

    local restored, chat_or_err = SessionManager.restore_session(filename)
    assert(restored, chat_or_err)
    assert(chat_or_err.added, 'expected chat counters to be present')
    assert(
      chat_or_err.added.history == 78,
      string.format('expected 78 history messages, got %s', vim.inspect(chat_or_err.added))
    )
    assert(
      chat_or_err.added.buffer == 78,
      string.format('expected 78 buffer messages, got %s', vim.inspect(chat_or_err.added))
    )
  ]])
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

    local restored, chat_or_err = SessionManager.restore_session(filename)
    assert(restored, chat_or_err)
    assert(chat_or_err.added, 'expected chat counters to be present')
    -- Expect 3 regular messages (user, assistant tool_call, assistant follow-up) and 1 tool output
    assert(
      chat_or_err.added.history == 3,
      string.format('expected 3 history messages, got %s', vim.inspect(chat_or_err.added))
    )
    assert(
      chat_or_err.added.buffer == 3,
      string.format('expected 3 buffer messages, got %s', vim.inspect(chat_or_err.added))
    )
    assert(
      chat_or_err.added.tool == 0,
      string.format('expected tool outputs to be rendered inline (0 tracked entries), got %s', vim.inspect(chat_or_err.added))
    )
  ]])
end

T['reuses existing chat when provided'] = function()
  child.lua([[
    _G.__RESTORE_CHAT_NEW_CALLS = 0

    local session_data = {
      version = '2.0',
      messages = {
        { role = 'user', content = 'Hello' },
        { role = 'assistant', content = 'Hi there' },
      },
      metadata = { total_messages = 2 },
      config = { adapter = 'test', model = 'reuse' },
      tools = {},
      timestamp = os.time(),
    }

    local filename = 'session_reuse_existing.lua'
    local ok, err = SessionManager.save_session_data(session_data, filename)
    assert(ok, err)

    local Chat = require('codecompanion.strategies.chat')
    local existing = Chat.new({})
    assert(_G.__RESTORE_CHAT_NEW_CALLS == 1, 'expected fixture chat creation to increment counter')

    local restored, restore_err = SessionManager.restore_session(filename, { chat = existing })
    assert(restored, restore_err)
    assert(_G.__RESTORE_CHAT_NEW_CALLS == 1, 'expected restore to reuse provided chat without creating a new one')
    assert(_G.__RESTORE_LAST_CHAT == existing, 'expected provided chat to be used during restore')
  ]])
end

return T
