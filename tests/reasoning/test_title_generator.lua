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
    package.loaded['codecompanion._extensions.reasoning.helpers.title_generator'] = nil
    TitleGenerator = require('codecompanion._extensions.reasoning.helpers.title_generator')
    tg = TitleGenerator.new({
      auto_generate_title = true,
      title_generation_opts = { refresh_every_n_prompts = 3 },
    })
    
    function new_chat(count)
      local msgs = {}
      for i = 1, count do
        table.insert(msgs, { role = 'user', content = 'message ' .. i })
      end
      return { messages = msgs, opts = {} }
    end
  ]])

  -- 1st user message -> generate (initial)
  child.lua([[
    chat = { messages = { { role='user', content='hello' } }, opts = {} }
    should1, refresh1 = tg:should_generate(chat)
  ]])
  local should1 = child.lua_get('should1')
  local refresh1 = child.lua_get('refresh1')
  expect.equality(should1, true)
  expect.equality(refresh1, false)

  -- Mark applied for count=1 and set a title
  child.lua([[
    chat = new_chat(1)
    chat.opts.title = 'Title'
    chat.opts._title_generated_counts = { [1] = true }
  ]])

  -- 2nd and 3rd user messages -> do not generate
  child.lua([[
    chat.messages = new_chat(2).messages
    should2, refresh2 = tg:should_generate(chat)
  ]])
  local should2 = child.lua_get('should2')
  expect.equality(should2, false)

  child.lua([[
    chat.messages = new_chat(3).messages
    should3, refresh3 = tg:should_generate(chat)
  ]])
  local should3 = child.lua_get('should3')
  expect.equality(should3, false)

  -- 4th user message -> refresh
  child.lua([[
    chat.messages = new_chat(4).messages
    should4, refresh4 = tg:should_generate(chat)
  ]])
  local should4 = child.lua_get('should4')
  local refresh4 = child.lua_get('refresh4')
  expect.equality(should4, true)
  expect.equality(refresh4, true)
end

T['interval param works with custom N'] = function()
  child.lua([[
    package.loaded['codecompanion._extensions.reasoning.helpers.title_generator'] = nil
    TitleGenerator = require('codecompanion._extensions.reasoning.helpers.title_generator')
    tg2 = TitleGenerator.new({
      auto_generate_title = true,
      title_generation_opts = { refresh_every_n_prompts = 2 },
    })
  ]])

  -- 1st -> generate
  child.lua([[
    chat = { messages = { { role='user', content='hello' } }, opts = {} }
    should1, refresh1 = tg2:should_generate(chat)
  ]])
  local should1 = child.lua_get('should1')
  local refresh1 = child.lua_get('refresh1')
  expect.equality(should1, true)
  expect.equality(refresh1, false)

  -- 3rd -> refresh
  child.lua([[
    chat = new_chat(3)
    chat.opts.title = 'Title'
    chat.opts._title_generated_counts = { [1] = true }
    should2, refresh2 = tg2:should_generate(chat)
  ]])
  local should2 = child.lua_get('should2')
  local refresh2 = child.lua_get('refresh2')
  expect.equality(should2, true)
  expect.equality(refresh2, true)
end

return T
