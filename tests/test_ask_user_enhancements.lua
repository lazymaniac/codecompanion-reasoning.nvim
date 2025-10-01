local MiniTest = require('mini.test')
local h = require('tests.helpers')

-- Mock dependencies
package.loaded['codecompanion._extensions.reasoning.ui.popup'] = {
  ask_question = function(question, options, callback)
    -- Simulate user response for testing
    callback('Test response', false, nil)
  end,
}

local ask_user_tool = require('codecompanion._extensions.reasoning.tools.ask_user')

local T = MiniTest.new_set()

T['ask_user tool has enhanced schema'] = function()
  local schema = ask_user_tool.schema

  -- Verify schema structure
  h.eq('function', schema.type)
  h.eq('ask_user', schema['function'].name)

  local description = schema['function'].description

  -- Check for proactive use guidance
  h.eq(true, string.find(description, 'PROACTIVE USE (at task start)', 1, true) ~= nil)
  h.eq(true, string.find(description, 'Request is vague or lacks specifics', 1, true) ~= nil)
  h.eq(true, string.find(description, 'Missing key details', 1, true) ~= nil)

  -- Check for ongoing use guidance
  h.eq(true, string.find(description, 'ONGOING USE (during work)', 1, true) ~= nil)
  h.eq(true, string.find(description, 'Architecture decisions affecting maintainability', 1, true) ~= nil)

  -- Check for updated don't use guidance
  h.eq(true, string.find(description, 'Established coding standards or obvious technical choices', 1, true) ~= nil)
  h.eq(true, string.find(description, 'Simple implementation details with one obvious approach', 1, true) ~= nil)
end

T['ask_user question parameter has enhanced examples'] = function()
  local schema = ask_user_tool.schema
  local question_desc = schema['function'].parameters.properties.question.description

  -- Check for structure guidance
  h.eq(true, string.find(question_desc, 'STRUCTURE: Context + Options + Reasoning', 1, true) ~= nil)

  -- Check for proactive example
  h.eq(true, string.find(question_desc, 'PROACTIVE:', 1, true) ~= nil)
  h.eq(true, string.find(question_desc, 'improve the validation code', 1, true) ~= nil)

  -- Check for ongoing example
  h.eq(true, string.find(question_desc, 'ONGOING:', 1, true) ~= nil)
  h.eq(true, string.find(question_desc, 'Found failing tests', 1, true) ~= nil)

  -- Check bad example is still there
  h.eq(true, string.find(question_desc, 'BAD: "What should I do?" (too vague)', 1, true) ~= nil)
end

T['system prompt includes proactive clarification step'] = function()
  local system_prompt = require('codecompanion._extensions.reasoning.helpers.system_prompt')
  local prompt_text = system_prompt.get()

  -- Check for important second step (matches actual implementation)
  h.eq(true, string.find(prompt_text, 'IMPORTANT SECOND STEP: Assess task clarity BEFORE proceeding', 1, true) ~= nil)

  -- Check for actual workflow content that exists in the system prompt
  h.eq(true, string.find(prompt_text, 'ask_user', 1, true) ~= nil)
  h.eq(true, string.find(prompt_text, 'Evidence & Discipline', 1, true) ~= nil)
  h.eq(true, string.find(prompt_text, 'Engineering Practices', 1, true) ~= nil)
  h.eq(true, string.find(prompt_text, 'project_knowledge', 1, true) ~= nil)
end

return T
