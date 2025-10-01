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

local new_chat = function(count)
  local msgs = {}
  for i = 1, count do
    table.insert(msgs, { role = 'user', content = 'message ' .. i })
  end
  return { messages = msgs, opts = {} }
end

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
    assert(should1 == true, 'expected generation for first user message')
    assert(refresh1 == false, 'expected initial generation, not refresh')

    chat = new_chat(1)
    chat.opts.title = 'Title'
    chat.opts._title_generated_counts = { [1] = true }

    chat.messages = new_chat(2).messages
    local should2 = tg:should_generate(chat)
    assert(should2 == false, 'expected no generation at second prompt')

    chat.messages = new_chat(3).messages
    local should3 = tg:should_generate(chat)
    assert(should3 == false, 'expected no generation at third prompt')

    chat.messages = new_chat(4).messages
    local should4, refresh4 = tg:should_generate(chat)
    assert(should4 == true and refresh4 == true, 'expected refresh on fourth prompt')
  ]])
end

T['interval param works with custom N'] = function()
  child.lua([[
    package.loaded['codecompanion._extensions.reasoning.helpers.session_title_generator'] = nil
    local Config = require('codecompanion._extensions.reasoning.config')
    Config.setup({
      session_title_generator = {
        refresh_every_n_prompts = 2,
      },
    })
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
    assert(should1 == true and refresh1 == false, 'expected initial generation')

    chat = new_chat(3)
    chat.opts.title = 'Title'
    chat.opts._title_generated_counts = { [1] = true }
    local should2, refresh2 = tg:should_generate(chat)
    assert(should2 == true and refresh2 == true, 'expected refresh when threshold met')
  ]])
end

return T
