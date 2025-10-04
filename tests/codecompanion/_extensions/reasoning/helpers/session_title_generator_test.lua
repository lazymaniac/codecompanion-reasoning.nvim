-- filepath: tests/codecompanion/_extensions/reasoning/helpers/session_title_generator_test.lua
-- Combined from tests/reasoning/test_title_generator.lua and functionality adapter title test
local MiniTest = require('mini.test')
local h = require('tests.helpers')
local expect = MiniTest.expect

local child = MiniTest.new_child_neovim()

local T = MiniTest.new_set({
  hooks = {
    pre_once = function()
      h.child_start(child)
    end,
    post_once = function()
      pcall(function()
        if child and child.is_running and child:is_running() then
          child:stop()
        end
      end)
    end,
  },
})

T['should_generate every 3 messages starting at first'] = function()
  child.lua([[
    package.loaded['codecompanion._extensions.reasoning.helpers.session_title_generator'] = nil
    local Config = require('codecompanion._extensions.reasoning.config')
    Config.setup()
    local TitleGenerator = require('codecompanion._extensions.reasoning.helpers.session_title_generator')
    local tg = TitleGenerator.new()

    local function new_chat(count)
      local msgs = {}
      for i = 1, count do
        table.insert(msgs, { role = 'user', content = 'message ' .. i })
      end
      return { messages = msgs, opts = {} }
    end

    local chat = { messages = { { role = 'user', content = 'hello' } }, opts = {} }
    local should1, refresh1 = tg:should_generate(chat)
    assert(should1 == true and refresh1 == false)

    chat = new_chat(1)
    chat.opts.title = 'Title'
    chat.opts._title_generated_counts = { [1] = true }

    chat.messages = new_chat(2).messages
    local should2 = tg:should_generate(chat)
    assert(should2 == false)

    chat.messages = new_chat(3).messages
    local should3 = tg:should_generate(chat)
    assert(should3 == false)

    chat.messages = new_chat(4).messages
    local should4, refresh4 = tg:should_generate(chat)
    assert(should4 == true and refresh4 == true)
  ]])
end

T['interval param works with custom N'] = function()
  child.lua([[
    package.loaded['codecompanion._extensions.reasoning.helpers.session_title_generator'] = nil
    local Config = require('codecompanion._extensions.reasoning.config')
    Config.setup({ session_title_generator = { refresh_every_n_prompts = 2 } })
    local TitleGenerator = require('codecompanion._extensions.reasoning.helpers.session_title_generator')
    local tg = TitleGenerator.new()

    local function new_chat(count)
      local msgs = {}
      for i = 1, count do
        table.insert(msgs, { role = 'user', content = 'message ' .. i })
      end
      return { messages = msgs, opts = {} }
    end

    local chat = { messages = { { role = 'user', content = 'hello' } }, opts = {} }
    local should1, refresh1 = tg:should_generate(chat)
    assert(should1 == true and refresh1 == false)

    chat = new_chat(3)
    chat.opts.title = 'Title'
    chat.opts._title_generated_counts = { [1] = true }
    local should2, refresh2 = tg:should_generate(chat)
    assert(should2 == true and refresh2 == true)
  ]])
end

T['Title generator uses configured adapter'] = function()
  child.lua([[
    local Config = require('codecompanion._extensions.reasoning.config')
    Config.setup({ session_title_generator = { adapter = 'stub-adapter', model = 'stub-model' } })

    local function build_mock_adapter(opts)
      opts = opts or {}
      return {
        name = opts.name or 'mock_adapter',
        map_schema_to_params = function(_, params) return params end,
        map_roles = function(_, messages) return messages end,
        handlers = { chat_output = function(_, _adapter_data) return { status = 'success', output = { content = opts.output or 'Generated Title' } } end },
      }
    end

    local resolve_calls = {}
    local stub_adapter = build_mock_adapter({ output = 'Generated Title' })

    package.loaded['codecompanion.adapters'] = {
      resolve = function(name) table.insert(resolve_calls, name); return stub_adapter end,
    }
    package.loaded['codecompanion.schema'] = {
      get_default = function(_, opts) opts = opts or {}; opts.model = opts.model or 'default-title-model'; return opts end,
    }
    package.loaded['codecompanion.http'] = {
      new = function() return { request = function(_, _, handlers) handlers.callback(nil, { output = { content = 'Generated Title' } }, stub_adapter) end } end,
    }

    package.loaded['codecompanion._extensions.reasoning.helpers.session_title_generator'] = nil
    local TitleGenerator = require('codecompanion._extensions.reasoning.helpers.session_title_generator')
    local generator = TitleGenerator.new()
    local chat = { adapter = 'unused', messages = { { role = 'user', content = 'Plan feature work' } }, opts = {} }
    local titles = {}
    generator:generate(chat, function(title) table.insert(titles, title) end)
    assert(resolve_calls[#resolve_calls] == 'stub-adapter')
    assert(titles[#titles] == 'Generated Title')
  ]])
end

return T
