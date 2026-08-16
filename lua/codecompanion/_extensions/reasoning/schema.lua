local Config = require('codecompanion._extensions.reasoning.config')

local M = {}

local unique_arrays = {
  ['reasoning_frame.success_criteria'] = true,
  ['reasoning_frame.unknowns'] = true,
  ['reasoning_evidence.items.addresses_unknowns'] = true,
  ['reasoning_evidence.items.supports'] = true,
  ['reasoning_evidence.items.contradicts'] = true,
  ['reasoning_evidence.items.qualifies'] = true,
  ['reasoning_options.criteria'] = true,
  ['reasoning_options.options.evidence_ids'] = true,
  ['reasoning_review.target_ids'] = true,
  ['reasoning_review.defense.evidence_ids'] = true,
  ['reasoning_review.challenges.target_ids'] = true,
  ['reasoning_review.contradiction_resolutions.evidence_ids'] = true,
  ['reasoning_review.structural_tradeoffs.evidence_ids'] = true,
  ['reasoning_synthesis.selected_option_ids'] = true,
  ['reasoning_synthesis.support_ids'] = true,
  ['reasoning_synthesis.review_ids'] = true,
  ['reasoning_synthesis.criterion_results.evidence_ids'] = true,
  ['reasoning_synthesis.tradeoffs'] = true,
  ['reasoning_synthesis.uncertainties'] = true,
  ['reasoning_synthesis.blind_spots'] = true,
  ['reasoning_synthesis.next_actions'] = true,
  ['reasoning_question.evidence_ids'] = true,
  ['reasoning_evidence.items.addresses_questions'] = true,
}

local empty_text_allowed = {
  ['reasoning_review.verdicts.revision_instruction'] = true,
  ['reasoning_question.residual'] = true,
  ['reasoning_question.answer'] = true,
  ['reasoning_question.justification'] = true,
  ['reasoning_question.acceptance_test'] = true,
}

local artifact_id_paths = {
  ['reasoning_evidence.items.supports'] = true,
  ['reasoning_evidence.items.contradicts'] = true,
  ['reasoning_evidence.items.qualifies'] = true,
  ['reasoning_evidence.items.supersedes_id'] = true,
  ['reasoning_options.supersedes_branch_id'] = true,
  ['reasoning_options.options.evidence_ids'] = true,
  ['reasoning_review.target_ids'] = true,
  ['reasoning_review.defense.evidence_ids'] = true,
  ['reasoning_review.challenges.target_ids'] = true,
  ['reasoning_review.verdicts.target_id'] = true,
  ['reasoning_review.contradiction_resolutions.left_id'] = true,
  ['reasoning_review.contradiction_resolutions.right_id'] = true,
  ['reasoning_review.contradiction_resolutions.evidence_ids'] = true,
  ['reasoning_review.structural_tradeoffs.evidence_ids'] = true,
  ['reasoning_synthesis.selected_option_ids'] = true,
  ['reasoning_synthesis.support_ids'] = true,
  ['reasoning_synthesis.review_ids'] = true,
  ['reasoning_synthesis.criterion_results.evidence_ids'] = true,
  ['reasoning_question.parent_id'] = true,
  ['reasoning_question.question_id'] = true,
  ['reasoning_question.residual_covered_by'] = true,
  ['reasoning_question.evidence_ids'] = true,
  ['reasoning_evidence.items.addresses_questions'] = true,
}

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
  if name == 'reasoning_question' then
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
