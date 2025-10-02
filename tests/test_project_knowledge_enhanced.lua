local MiniTest = require('mini.test')
local helpers = require('tests.helpers')

-- Test the enhanced project knowledge tool with categorization
local function test_project_knowledge_enhanced()
  local project_knowledge = require('codecompanion._extensions.reasoning.tools.project_knowledge')

  -- Test that schema includes all required category options
  local schema = project_knowledge.schema['function']
  local category_enum = schema.parameters.properties.category.enum

  MiniTest.expect.equality(#category_enum, 4)
  MiniTest.expect.equality(vim.tbl_contains(category_enum, 'architecture'), true)
  MiniTest.expect.equality(vim.tbl_contains(category_enum, 'workflow'), true)
  MiniTest.expect.equality(vim.tbl_contains(category_enum, 'business_logic'), true)
  MiniTest.expect.equality(vim.tbl_contains(category_enum, 'constraints'), true)

  -- Test that category is required
  local required_fields = schema.parameters.required
  MiniTest.expect.equality(vim.tbl_contains(required_fields, 'category'), true)
  MiniTest.expect.equality(vim.tbl_contains(required_fields, 'description'), true)

  -- Test enhanced description includes examples
  local description = schema.description
  MiniTest.expect.equality(string.find(description, 'EXAMPLES') ~= nil, true)
  MiniTest.expect.equality(string.find(description, 'Authentication logic') ~= nil, true)
  MiniTest.expect.equality(string.find(description, 'CAPTURE:') ~= nil, true)
  MiniTest.expect.equality(string.find(description, 'AVOID:') ~= nil, true)
end

-- Test categorized fact storage
local function test_categorized_fact_storage()
  local tmpdir = vim.fn.tempname()
  vim.fn.mkdir(tmpdir, 'p')
  local knowledge_file = tmpdir .. '/project-knowledge.md'

  -- Create initial file with new structure
  local initial_content = [[# PROJECT KNOWLEDGE

## Project Overview
Test project

## Directory Structure
Test structure

## Architecture Facts
*Code locations and architectural patterns*

## Workflow Facts
*Development commands and processes*

## Business Logic Facts
*Feature behavior and business rules*

## Constraints Facts
*Technical limitations and requirements*
]]

  local file = io.open(knowledge_file, 'w')
  file:write(initial_content)
  file:close()

  -- Test storing facts in different categories
  local project_knowledge = require('codecompanion._extensions.reasoning.tools.project_knowledge')

  -- Mock the ensure_knowledge_file function to use our test file
  local original_ensure = project_knowledge._ensure_knowledge_file
  project_knowledge._ensure_knowledge_file = function()
    return knowledge_file
  end

  -- We can't easily test the UI dialog, but we can test the core storage logic
  -- by accessing internal functions (this would need to be exposed for testing)

  -- Cleanup
  vim.fn.delete(tmpdir, 'rf')
end

-- Test validation of fact categories
local function test_fact_validation()
  local project_knowledge = require('codecompanion._extensions.reasoning.tools.project_knowledge')

  -- Test command validation
  local test_callback_called = false
  local test_callback_result = nil

  local function test_callback(result)
    test_callback_called = true
    test_callback_result = result
  end

  -- Test missing category
  project_knowledge.cmds[1](project_knowledge, {
    description = 'Test fact',
  }, nil, test_callback)

  MiniTest.expect.equality(test_callback_called, true)
  MiniTest.expect.equality(test_callback_result.status, 'error')
  MiniTest.expect.equality(string.find(test_callback_result.data, 'Category is required') ~= nil, true)

  -- Reset for next test
  test_callback_called = false
  test_callback_result = nil

  -- Test missing description
  project_knowledge.cmds[1](project_knowledge, {
    category = 'architecture',
  }, nil, test_callback)

  MiniTest.expect.equality(test_callback_called, true)
  MiniTest.expect.equality(test_callback_result.status, 'error')
  MiniTest.expect.equality(string.find(test_callback_result.data, 'Description is required') ~= nil, true)
end

-- Test that load_project_knowledge still works
local function test_load_project_knowledge()
  local tmpdir = vim.fn.tempname()
  vim.fn.mkdir(tmpdir .. '/.codecompanion', 'p')
  local knowledge_file = tmpdir .. '/.codecompanion/project-knowledge.md'

  -- Create test content
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

  -- Mock getcwd to return our test directory
  local original_getcwd = vim.fn.getcwd
  vim.fn.getcwd = function()
    return tmpdir
  end

  -- Test loading
  local content = _G.CodeCompanionProjectKnowledge.load_project_knowledge()
  MiniTest.expect.equality(content, test_content)

  -- Cleanup
  vim.fn.getcwd = original_getcwd
  vim.fn.delete(tmpdir, 'rf')
end

-- Run tests
local test_suite = MiniTest.new_set({
  hooks = {
    pre_case = function()
      -- Setup before each test
    end,
    post_case = function()
      -- Cleanup after each test
    end,
  },
})

test_suite['Enhanced project knowledge schema'] = test_project_knowledge_enhanced
test_suite['Fact validation'] = test_fact_validation
test_suite['Load project knowledge'] = test_load_project_knowledge
test_suite['Categorized fact storage'] = test_categorized_fact_storage

return test_suite
