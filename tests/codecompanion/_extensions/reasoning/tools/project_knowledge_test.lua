-- filepath: tests/codecompanion/_extensions/reasoning/tools/project_knowledge_test.lua
-- Moved from tests/test_project_knowledge_enhanced.lua
local MiniTest = require('mini.test')

local T = MiniTest.new_set()

T['Enhanced project knowledge schema'] = function()
  local project_knowledge = require('codecompanion._extensions.reasoning.tools.project_knowledge')
  local schema = project_knowledge.schema['function']
  local category_enum = schema.parameters.properties.category.enum

  MiniTest.expect.equality(#category_enum, 4)
  MiniTest.expect.equality(vim.tbl_contains(category_enum, 'architecture'), true)
  MiniTest.expect.equality(vim.tbl_contains(category_enum, 'workflow'), true)
  MiniTest.expect.equality(vim.tbl_contains(category_enum, 'business_logic'), true)
  MiniTest.expect.equality(vim.tbl_contains(category_enum, 'constraints'), true)

  local required_fields = schema.parameters.required
  MiniTest.expect.equality(vim.tbl_contains(required_fields, 'category'), true)
  MiniTest.expect.equality(vim.tbl_contains(required_fields, 'description'), true)

  local description = schema.description
  MiniTest.expect.equality(string.find(description, 'EXAMPLES') ~= nil, true)
  MiniTest.expect.equality(string.find(description, 'Authentication logic') ~= nil, true)
  MiniTest.expect.equality(string.find(description, 'CAPTURE:') ~= nil, true)
  MiniTest.expect.equality(string.find(description, 'AVOID:') ~= nil, true)
end

T['Fact validation'] = function()
  local project_knowledge = require('codecompanion._extensions.reasoning.tools.project_knowledge')

  local test_callback_called = false
  local test_callback_result = nil

  local function test_callback(result)
    test_callback_called = true
    test_callback_result = result
  end

  project_knowledge.cmds[1](project_knowledge, { description = 'Test fact' }, nil, test_callback)
  MiniTest.expect.equality(test_callback_called, true)
  MiniTest.expect.equality(test_callback_result.status, 'error')
  MiniTest.expect.equality(string.find(test_callback_result.data, 'Category is required') ~= nil, true)

  test_callback_called = false
  test_callback_result = nil

  project_knowledge.cmds[1](project_knowledge, { category = 'architecture' }, nil, test_callback)
  MiniTest.expect.equality(test_callback_called, true)
  MiniTest.expect.equality(test_callback_result.status, 'error')
  MiniTest.expect.equality(string.find(test_callback_result.data, 'Description is required') ~= nil, true)
end

T['Load project knowledge'] = function()
  local tmpdir = vim.fn.tempname()
  vim.fn.mkdir(tmpdir .. '/.codecompanion', 'p')
  local knowledge_file = tmpdir .. '/.codecompanion/project-knowledge.md'

  local test_content = [[# PROJECT KNOWLEDGE

## Architecture Facts
- Authentication is in src/auth/ (JWT middleware)
- Database models in app/models/ (Sequelize ORM)

## Workflow Facts  
- Testing: Run `npm test` (requires Docker)
- Build: Uses Webpack with hot reload
]]

  local file = io.open(knowledge_file, 'w')
  file:write(test_content)
  file:close()

  local original_getcwd = vim.fn.getcwd
  vim.fn.getcwd = function()
    return tmpdir
  end

  local content = _G.CodeCompanionProjectKnowledge.load_project_knowledge()
  MiniTest.expect.equality(content, test_content)

  vim.fn.getcwd = original_getcwd
  vim.fn.delete(tmpdir, 'rf')
end

return T
