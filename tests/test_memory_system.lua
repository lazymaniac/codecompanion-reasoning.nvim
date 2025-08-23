local h = require('tests.helpers')

local new_set = MiniTest.new_set

local child = MiniTest.new_child_neovim()
local T = new_set({
  hooks = {
    pre_once = function()
      h.child_start(child)
      child.lua([[
        h = require('tests.helpers')
        MemoryEngine = require('codecompanion._extensions.reasoning.helpers.memory_engine')
        ProjectContext = require('codecompanion._extensions.reasoning.tools.project_context')
      ]])
    end,
    post_once = child.stop,
  },
})

-- Test memory system basic functionality
T['memory system stores and retrieves file knowledge'] = function()
  child.lua([[
    -- Store file knowledge
    MemoryEngine.store_file_knowledge('test.lua', {
      purpose = 'Test file',
      key_functions = {'test_function'},
      patterns = {'testing_pattern'}
    })

    -- Retrieve file knowledge
    knowledge = MemoryEngine.get_file_knowledge('test.lua')

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
    MemoryEngine.store_user_preference('coding_style', 'incremental')

    -- Retrieve user preference
    preference = MemoryEngine.get_user_preference('coding_style')

    pref_test_info = {
      has_preference = preference ~= nil,
      correct_value = preference == 'incremental'
    }
  ]])

  local pref_test_info = child.lua_get('pref_test_info')

  h.eq(true, pref_test_info.has_preference)
  h.eq(true, pref_test_info.correct_value)
end

T['project_context tool handles discover_context action'] = function()
  child.lua([[
    -- Test context discovery
    result = ProjectContext.cmds[1](ProjectContext, {
      action = 'discover_context'
    }, nil)

    discover_test_info = {
      status = result.status,
      has_discover_data = string.find(result.data, 'DISCOVERED') ~= nil
    }
  ]])

  local discover_test_info = child.lua_get('discover_test_info')

  h.eq('success', discover_test_info.status)
  h.eq(true, discover_test_info.has_discover_data)
end

T['project_context tool handles get_enhanced_context action'] = function()
  child.lua([[
    -- Test enhanced context
    result = ProjectContext.cmds[1](ProjectContext, {
      action = 'get_enhanced_context'
    }, nil)

    enhanced_test_info = {
      status = result.status,
      has_data = result.data ~= nil and result.data ~= ''
    }
  ]])

  local enhanced_test_info = child.lua_get('enhanced_test_info')

  h.eq('success', enhanced_test_info.status)
  h.eq(true, enhanced_test_info.has_data)
end

T['project_context tool handles store_file_knowledge action'] = function()
  child.lua([[
    result = ProjectContext.cmds[1](ProjectContext, {
      action = 'store_file_knowledge',
      file_path = 'example.lua',
      knowledge = {
        purpose = 'Example file for testing',
        key_functions = {'example_function'}
      }
    }, nil)

    tool_test_info = {
      status = result.status,
      has_success_message = string.find(result.data, 'STORED') ~= nil
    }
  ]])

  local tool_test_info = child.lua_get('tool_test_info')

  h.eq('success', tool_test_info.status)
  h.eq(true, tool_test_info.has_success_message)
end

T['project_context tool handles get_file_knowledge action'] = function()
  child.lua([[
    -- First store some knowledge
    ProjectContext.cmds[1](ProjectContext, {
      action = 'store_file_knowledge',
      file_path = 'retrieve_test.lua',
      knowledge = {
        purpose = 'Retrieval test file'
      }
    }, nil)

    -- Then retrieve it
    result = ProjectContext.cmds[1](ProjectContext, {
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
