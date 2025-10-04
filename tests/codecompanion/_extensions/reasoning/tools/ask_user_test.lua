-- filepath: tests/codecompanion/_extensions/reasoning/tools/ask_user_test.lua
-- Extracted from tests/test_ask_user_enhancements.lua (ask_user parts)
local MiniTest = require('mini.test')
local h = require('tests.helpers')

package.loaded['codecompanion._extensions.reasoning.ui.popup'] = {
  ask_question = function(question, options, callback)
    callback('Test response', false, nil)
  end,
}

local ask_user_tool = require('codecompanion._extensions.reasoning.tools.ask_user')

local T = MiniTest.new_set()

T['ask_user tool has enhanced schema'] = function()
  local schema = ask_user_tool.schema
  h.eq('function', schema.type)
  h.eq('ask_user', schema['function'].name)

  local description = schema['function'].description
  h.eq(true, string.find(description, 'PROACTIVE USE (at task start)', 1, true) ~= nil)
  h.eq(true, string.find(description, 'Request is vague or lacks specifics', 1, true) ~= nil)
  h.eq(true, string.find(description, 'Missing key details', 1, true) ~= nil)
  h.eq(true, string.find(description, 'ONGOING USE (during work)', 1, true) ~= nil)
  h.eq(true, string.find(description, 'Architecture decisions affecting maintainability', 1, true) ~= nil)
  h.eq(true, string.find(description, 'Established coding standards or obvious technical choices', 1, true) ~= nil)
  h.eq(true, string.find(description, 'Simple implementation details with one obvious approach', 1, true) ~= nil)
end

T['ask_user question parameter has enhanced examples'] = function()
  local schema = ask_user_tool.schema
  local question_desc = schema['function'].parameters.properties.question.description
  h.eq(true, string.find(question_desc, 'STRUCTURE: Context + Reasoning', 1, true) ~= nil)
  h.eq(true, string.find(question_desc, 'PROACTIVE:', 1, true) ~= nil)
  h.eq(true, string.find(question_desc, 'improve the validation code', 1, true) ~= nil)
  h.eq(true, string.find(question_desc, 'ONGOING:', 1, true) ~= nil)
  h.eq(true, string.find(question_desc, 'Found failing tests', 1, true) ~= nil)
  h.eq(true, string.find(question_desc, 'BAD: "What should I do?" (too vague)', 1, true) ~= nil)
end

return T
