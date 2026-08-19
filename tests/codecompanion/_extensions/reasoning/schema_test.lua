local Config = require('codecompanion._extensions.reasoning.config')
local Constants = require('codecompanion._extensions.reasoning.constants')
local Schema = require('codecompanion._extensions.reasoning.schema')

local T = MiniTest.new_set({ hooks = {
  pre_case = function()
    Config.setup()
  end,
} })
local eq = MiniTest.expect.equality

T['exposes default evidence batch bounds'] = function()
  local tool = Schema.resolve('reasoning_evidence', require('codecompanion._extensions.reasoning.tools.evidence'))
  local items = tool.schema['function'].parameters.properties.items
  eq(items.minItems, 1)
  eq(items.maxItems, 8)
end

T['applies current evidence batch, array, and text limits'] = function()
  Config.setup({ limits = { max_batch_items = 3, max_array_items = 5, max_text_chars = 111 } })
  local tool = Schema.resolve('reasoning_evidence', require('codecompanion._extensions.reasoning.tools.evidence'))
  local items = tool.schema['function'].parameters.properties.items
  eq(items.minItems, 1)
  eq(items.maxItems, 3)
  eq(items.items.properties.statement.maxLength, 111)
  eq(items.items.properties.supports.maxItems, 5)
  eq(items.items.properties.supports.uniqueItems, true)
  eq(items.items.properties.supports.items.maxLength, nil)
  eq(items.items.properties.supersedes_id.minLength, nil)
end

T['returns a fresh schema after configuration changes'] = function()
  local template = require('codecompanion._extensions.reasoning.tools.evidence')
  Config.setup({ limits = { max_batch_items = 4 } })
  local first = Schema.resolve('reasoning_evidence', template)
  Config.setup({ limits = { max_batch_items = 2 } })
  local second = Schema.resolve('reasoning_evidence', template)
  eq(first.schema['function'].parameters.properties.items.maxItems, 4)
  eq(second.schema['function'].parameters.properties.items.maxItems, 2)
end

T['dealiases shared review arrays before path-specific constraints'] = function()
  Config.setup({ limits = { max_array_items = 5, max_text_chars = 111 } })
  local tool = Schema.resolve('reasoning_review', require('codecompanion._extensions.reasoning.tools.review'))
  local properties = tool.schema['function'].parameters.properties
  eq(properties.defense.properties.evidence_ids.uniqueItems, true)
  eq(properties.defense.properties.evidence_ids.items.maxLength, nil)
  eq(properties.blind_spots.uniqueItems, nil)
  eq(properties.blind_spots.items.maxLength, 111)
  eq(properties.challenges.items.properties.target_ids.items.maxLength, nil)
end

T['leaves permitted-empty IDs unconstrained as prose'] = function()
  Config.setup({ limits = { max_text_chars = 111 } })
  local evidence = Schema.resolve('reasoning_evidence', require('codecompanion._extensions.reasoning.tools.evidence'))
  local options =
    Schema.resolve('reasoning_options_replace', require('codecompanion._extensions.reasoning.tools.options_replace'))
  local evidence_id = evidence.schema['function'].parameters.properties.items.items.properties.supersedes_id
  local branch_id = options.schema['function'].parameters.properties.supersedes_branch_id

  eq({ evidence_id.minLength, evidence_id.maxLength }, {})
  eq({ branch_id.minLength, branch_id.maxLength }, {})
end

local function resolved(name)
  return Schema.resolve(name, require('codecompanion._extensions.reasoning.tools.' .. name:gsub('^reasoning_', '')))
end

local function property_names(name)
  local names = vim.tbl_keys(resolved(name).schema['function'].parameters.properties)
  table.sort(names)
  return names
end

T['each tool takes exactly the fields its own action needs'] = function()
  eq(property_names('reasoning_start'), {
    'branching_rationale',
    'branching_required',
    'constraints',
    'depth',
    'objective',
    'perspectives',
    'problem_type',
    'success_criteria',
    'temporal_required',
    'unknowns',
  })
  eq(property_names('reasoning_amend'), {
    'add_constraints',
    'add_perspectives',
    'add_success_criteria',
    'add_unknowns',
    'branching_rationale',
    'require_branching',
    'require_temporal',
  })
  eq(property_names('reasoning_split'), {
    'axis',
    'child_questions',
    'composition',
    'parent_id',
    'residual',
    'residual_covered_by',
    'residual_disposition',
  })
  eq(property_names('reasoning_answer'), {
    'acceptance_test',
    'answer',
    'confidence',
    'evidence_ids',
    'question_id',
    'resolution_kind',
  })
  eq(property_names('reasoning_drop'), { 'drop_reason', 'evidence_ids', 'justification', 'question_id' })
  eq(property_names('reasoning_resolve_contradiction'), {
    'contradiction',
    'evidence_ids',
    'falsifier',
    'left_id',
    'resolution',
    'right_id',
  })
  eq(property_names('reasoning_checkpoint'), {
    'conclusion',
    'confidence',
    'criterion_results',
    'review_ids',
    'selected_option_ids',
    'support_ids',
  })
end

T['keeps every tool strict with no optional or placeholder field'] = function()
  for _, name in ipairs(Constants.tool_names) do
    local schema = resolved(name).schema['function']
    eq(schema.name, name)
    eq(schema.strict, true)
    eq(schema.parameters.additionalProperties, false)
    local required = vim.deepcopy(schema.parameters.required)
    table.sort(required)
    eq(required, property_names(name))
    for field, node in pairs(schema.parameters.properties) do
      -- 'none' survives only where it describes this action's own state: a
      -- split that leaves no residual behind.
      if node.enum and field ~= 'residual_disposition' then
        eq({ name, field, vim.tbl_contains(node.enum, 'none') }, { name, field, false })
      end
    end
  end
end

T['names one action per tool and one tool per action'] = function()
  eq(#Constants.tool_names, 14)
  for _, name in ipairs(Constants.tool_names) do
    local operation = Constants.operation_by_tool[name]
    eq(Constants.tool_by_operation[operation], name)
    eq(type(Constants.family_by_tool[name]), 'string')
    local properties = resolved(name).schema['function'].parameters.properties
    eq(properties.action, nil)
    eq(properties.mode ~= nil, name == 'reasoning_review')
  end
end

return T
