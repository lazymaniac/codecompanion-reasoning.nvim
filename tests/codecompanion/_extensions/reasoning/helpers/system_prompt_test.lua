-- filepath: tests/codecompanion/_extensions/reasoning/helpers/system_prompt_test.lua
-- Extracted from tests/test_ask_user_enhancements.lua (system prompt part)
local MiniTest = require('mini.test')

local T = MiniTest.new_set()

T['system prompt includes proactive clarification step'] = function()
  local system_prompt = require('codecompanion._extensions.reasoning.helpers.system_prompt')
  local prompt_text = system_prompt.get()
  MiniTest.expect.equality(
    string.find(prompt_text, 'IMPORTANT SECOND STEP: Assess task clarity BEFORE proceeding', 1, true) ~= nil,
    true
  )
  MiniTest.expect.equality(string.find(prompt_text, 'ask_user', 1, true) ~= nil, true)
  MiniTest.expect.equality(string.find(prompt_text, 'Evidence & Discipline', 1, true) ~= nil, true)
  MiniTest.expect.equality(string.find(prompt_text, 'Engineering Practices', 1, true) ~= nil, true)
  MiniTest.expect.equality(string.find(prompt_text, 'project_knowledge', 1, true) ~= nil, true)
end

return T
