local h = require('tests.helpers')

local new_set = MiniTest.new_set

local child = MiniTest.new_child_neovim()
local T = new_set({
  hooks = {
    pre_once = function()
      h.child_start(child)
      child.lua([[
        h = require('tests.helpers')
        ContextDiscovery = require('codecompanion._extensions.reasoning.helpers.context_discovery')
        MemoryInsight = require('codecompanion._extensions.reasoning.tools.memory_insight')
      ]])
    end,
    post_once = child.stop,
  },
})

-- Test memory system basic functionality
T['memory system stores and retrieves file knowledge'] = function()
  child.lua([[
    -- Store file knowledge
    ContextDiscovery.store_file_knowledge('test.lua', {
      purpose = 'Test file',
      key_functions = {'test_function'},
      patterns = {'testing_pattern'}
    })

    -- Retrieve file knowledge
    knowledge = ContextDiscovery.get_file_knowledge('test.lua')

    memory_test_info = {
      has_knowledge = knowledge ~= nil,
      has_purpose = knowledge and knowledge.purpose == 'Test file',
      has_functions = knowledge and knowledge.key_functions and knowledge.key_functions[1] == 'test_function',
      has_patterns = knowledge and knowledge.patterns and knowledge.patterns[1] == 'testing_pattern'
    }
  ]])

  local memory_test_info = child.lua_get('memory_test_info')

  h.eq(true, memory_test_info.has_knowledge)
  h.eq(true, memory_test_info.has_purpose)
  h.eq(true, memory_test_info.has_functions)
  h.eq(true, memory_test_info.has_patterns)
end

T['memory system stores and retrieves user preferences'] = function()
  child.lua([[
    -- Store user preference
    ContextDiscovery.store_user_preference('coding_style', 'incremental')

    -- Retrieve user preference
    preference = ContextDiscovery.get_user_preference('coding_style')

    pref_test_info = {
      has_preference = preference ~= nil,
      correct_value = preference == 'incremental'
    }
  ]])

  local pref_test_info = child.lua_get('pref_test_info')

  h.eq(true, pref_test_info.has_preference)
  h.eq(true, pref_test_info.correct_value)
end

T['memory system stores reasoning patterns'] = function()
  child.lua([[
    -- Store reasoning pattern
    ContextDiscovery.store_reasoning_pattern('test_problem',
      {'step1', 'step2', 'step3'},
      'Successfully solved test problem')

    -- Retrieve reasoning patterns
    patterns = ContextDiscovery.get_reasoning_patterns('test_problem')

    pattern_test_info = {
      has_patterns = patterns ~= nil and #patterns > 0,
      correct_steps = patterns and patterns[1] and patterns[1].steps and #patterns[1].steps == 3,
      correct_outcome = patterns and patterns[1] and patterns[1].outcome == 'Successfully solved test problem'
    }
  ]])

  local pattern_test_info = child.lua_get('pattern_test_info')

  h.eq(true, pattern_test_info.has_patterns)
  h.eq(true, pattern_test_info.correct_steps)
  h.eq(true, pattern_test_info.correct_outcome)
end

T['memory system searches similar problems'] = function()
  child.lua([[
    -- Store problem-solution
    ContextDiscovery.store_problem_solution(
      'Authentication token expires too quickly',
      'Increased token expiry time in config',
      {'config/auth.lua', 'utils/jwt.lua'}
    )

    -- Search for similar problems
    matches = ContextDiscovery.search_similar_problems({'authentication', 'token'})

    search_test_info = {
      has_matches = matches ~= nil and #matches > 0,
      correct_match = matches and matches[1] and
                     string.find(matches[1].problem, 'Authentication') ~= nil
    }
  ]])

  local search_test_info = child.lua_get('search_test_info')

  h.eq(true, search_test_info.has_matches)
  h.eq(true, search_test_info.correct_match)
end

T['memory insight tool handles store_file_knowledge action'] = function()
  child.lua([[
    result = MemoryInsight.cmds[1](MemoryInsight, {
      action = 'store_file_knowledge',
      file_path = 'example.lua',
      knowledge = {
        purpose = 'Example file for testing',
        key_functions = {'example_function'}
      }
    }, nil)

    tool_test_info = {
      status = result.status,
      has_success_message = string.find(result.data, 'Stored knowledge') ~= nil
    }
  ]])

  local tool_test_info = child.lua_get('tool_test_info')

  h.eq('success', tool_test_info.status)
  h.eq(true, tool_test_info.has_success_message)
end

T['memory insight tool handles get_file_knowledge action'] = function()
  child.lua([[
    -- First store some knowledge
    MemoryInsight.cmds[1](MemoryInsight, {
      action = 'store_file_knowledge',
      file_path = 'retrieve_test.lua',
      knowledge = {
        purpose = 'Retrieval test file'
      }
    }, nil)

    -- Then retrieve it
    result = MemoryInsight.cmds[1](MemoryInsight, {
      action = 'get_file_knowledge',
      file_path = 'retrieve_test.lua'
    }, nil)

    retrieve_test_info = {
      status = result.status,
      has_knowledge_data = string.find(result.data, 'Knowledge for') ~= nil,
      contains_purpose = string.find(result.data, 'Retrieval test file') ~= nil
    }
  ]])

  local retrieve_test_info = child.lua_get('retrieve_test_info')

  h.eq('success', retrieve_test_info.status)
  h.eq(true, retrieve_test_info.has_knowledge_data)
  h.eq(true, retrieve_test_info.contains_purpose)
end

return T

