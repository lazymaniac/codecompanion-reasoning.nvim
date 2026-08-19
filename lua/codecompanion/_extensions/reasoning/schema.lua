local Config = require('codecompanion._extensions.reasoning.config')

local M = {}

local frame_tools = { 'reasoning_start', 'reasoning_revise', 'reasoning_replace' }
local branch_tools = { 'reasoning_options', 'reasoning_options_replace' }
local synthesis_tools = { 'reasoning_checkpoint', 'reasoning_final' }

local function mark(map, tools, fields)
  for _, tool in ipairs(tools) do
    for _, field in ipairs(fields) do
      map[tool .. '.' .. field] = true
    end
  end
end

local unique_arrays = {}
mark(unique_arrays, frame_tools, { 'success_criteria', 'unknowns' })
mark(unique_arrays, { 'reasoning_amend' }, { 'add_constraints', 'add_success_criteria', 'add_unknowns' })
mark(unique_arrays, { 'reasoning_evidence' }, {
  'items.addresses_unknowns',
  'items.addresses_questions',
  'items.supports',
  'items.contradicts',
  'items.qualifies',
})
mark(unique_arrays, branch_tools, { 'criteria', 'options.evidence_ids' })
mark(unique_arrays, { 'reasoning_review' }, {
  'target_ids',
  'defense.evidence_ids',
  'challenges.target_ids',
  'structural_tradeoffs.evidence_ids',
})
mark(unique_arrays, { 'reasoning_resolve_contradiction' }, { 'evidence_ids' })
mark(unique_arrays, synthesis_tools, {
  'selected_option_ids',
  'support_ids',
  'review_ids',
  'criterion_results.evidence_ids',
})
mark(unique_arrays, { 'reasoning_final' }, { 'tradeoffs', 'uncertainties', 'blind_spots', 'next_actions' })
mark(unique_arrays, { 'reasoning_answer', 'reasoning_drop' }, { 'evidence_ids' })

local empty_text_allowed = {
  ['reasoning_review.verdicts.revision_instruction'] = true,
  ['reasoning_split.residual'] = true,
  ['reasoning_amend.branching_rationale'] = true,
}

local artifact_id_paths = {}
mark(artifact_id_paths, { 'reasoning_evidence' }, {
  'items.supports',
  'items.contradicts',
  'items.qualifies',
  'items.supersedes_id',
  'items.addresses_questions',
})
mark(artifact_id_paths, branch_tools, { 'options.evidence_ids' })
mark(artifact_id_paths, { 'reasoning_options_replace' }, { 'supersedes_branch_id' })
mark(artifact_id_paths, { 'reasoning_review' }, {
  'target_ids',
  'defense.evidence_ids',
  'challenges.target_ids',
  'verdicts.target_id',
  'structural_tradeoffs.evidence_ids',
})
mark(artifact_id_paths, { 'reasoning_resolve_contradiction' }, { 'left_id', 'right_id', 'evidence_ids' })
mark(artifact_id_paths, synthesis_tools, {
  'selected_option_ids',
  'support_ids',
  'review_ids',
  'criterion_results.evidence_ids',
})
mark(artifact_id_paths, { 'reasoning_split' }, { 'parent_id', 'residual_covered_by' })
mark(artifact_id_paths, { 'reasoning_answer', 'reasoning_drop' }, { 'question_id', 'evidence_ids' })

local function minimum(left, right)
  return left and math.min(left, right) or right
end

local function clone_schema(value)
  if type(value) ~= 'table' then
    return value
  end
  local copy = {}
  for key, child in pairs(value) do
    copy[clone_schema(key)] = clone_schema(child)
  end
  return copy
end

local function visit(node, path, limits)
  if type(node) ~= 'table' then
    return
  end
  if node.type == 'string' and node.enum == nil and not artifact_id_paths[path] then
    if not empty_text_allowed[path] then
      node.minLength = 1
    end
    node.maxLength = limits.max_text_chars
  elseif node.type == 'array' then
    node.maxItems = minimum(node.maxItems, limits.max_array_items)
    if unique_arrays[path] then
      node.uniqueItems = true
    end
  end
  if type(node.properties) == 'table' then
    for name, child in pairs(node.properties) do
      visit(child, path .. '.' .. name, limits)
    end
  end
  if node.items then
    visit(node.items, path, limits)
  end
end

function M.resolve(name, template)
  local resolved = vim.deepcopy(template)
  resolved.schema = clone_schema(template.schema)
  local limits = Config.get().limits
  local parameters = resolved.schema['function'].parameters
  for field, node in pairs(parameters.properties) do
    visit(node, name .. '.' .. field, limits)
  end
  if name == 'reasoning_split' then
    parameters.properties.child_questions.maxItems = limits.max_children
  end
  if name == 'reasoning_evidence' then
    local items = parameters.properties.items
    items.minItems = 1
    items.maxItems = limits.max_batch_items
  end
  return resolved
end

return M
