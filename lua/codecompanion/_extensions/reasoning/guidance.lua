local State = require('codecompanion._extensions.reasoning.state')

local M = {}

local function normalized(value)
  return vim.trim(value):lower():gsub('%s+', ' ')
end

local function active(workspace, kind)
  local result = {}
  for _, id in ipairs(workspace.artifact_order or {}) do
    local artifact = workspace.artifacts_by_id[id]
    if artifact and artifact.status == 'active' and (not kind or artifact.kind == kind) then
      table.insert(result, artifact)
    end
  end
  return result
end

local function latest(workspace, kind, predicate)
  for index = #(workspace.artifact_order or {}), 1, -1 do
    local artifact = workspace.artifacts_by_id[workspace.artifact_order[index]]
    if
      artifact
      and artifact.status == 'active'
      and artifact.kind == kind
      and (not predicate or predicate(artifact))
    then
      return artifact
    end
  end
end

local function active_evidence(workspace, id)
  local artifact = workspace.artifacts_by_id[id]
  return artifact and artifact.status == 'active' and artifact.kind == 'evidence'
end

local function review_sound(workspace, review)
  if
    not review
    or review.status ~= 'active'
    or review.kind ~= 'review'
    or not State.in_lineage(workspace, review.data.frame_id)
  then
    return false
  end
  for _, id in ipairs(review.relations.supports or {}) do
    if not active_evidence(workspace, id) then
      return false
    end
  end
  return true
end

local function resolution_review(workspace, key)
  local review = workspace.artifacts_by_id[workspace.resolved_contradictions[key]]
  if not review_sound(workspace, review) then
    return nil
  end
  for _, resolution in ipairs(review.data.contradiction_resolutions or {}) do
    local left, right = resolution.left_id, resolution.right_id
    if left > right then
      left, right = right, left
    end
    if left .. ':' .. right == key then
      local valid = #(resolution.evidence_ids or {}) > 0
      for _, id in ipairs(resolution.evidence_ids or {}) do
        valid = valid and active_evidence(workspace, id)
      end
      if valid then
        return review
      end
    end
  end
end

local function contradiction_state(workspace, relevant, cited_reviews)
  local seen = {}
  local has_relevant = false
  local has_uncited = false
  for _, artifact in ipairs(active(workspace)) do
    for _, other_id in ipairs(artifact.relations.contradicts or {}) do
      local other = workspace.artifacts_by_id[other_id]
      if other and other.status == 'active' then
        local left, right = artifact.id, other_id
        if left > right then
          left, right = right, left
        end
        local key = left .. ':' .. right
        if not seen[key] and (relevant == nil or relevant[left] or relevant[right]) then
          seen[key] = true
          has_relevant = true
          local review = resolution_review(workspace, key)
          if not review then
            return 'unresolved', true
          end
          if cited_reviews and not cited_reviews[review.id] then
            has_uncited = true
          end
        end
      end
    end
  end
  return has_uncited and 'uncited' or 'resolved', has_relevant
end

local function revision_tool(workspace, relevant)
  local tool_by_kind = {
    frame = 'reasoning_frame',
    evidence = 'reasoning_evidence',
    branch = 'reasoning_options',
    option = 'reasoning_options',
    synthesis = 'reasoning_synthesis',
  }
  for index = #(workspace.artifact_order or {}), 1, -1 do
    local review = workspace.artifacts_by_id[workspace.artifact_order[index]]
    if review and review.kind == 'review' then
      for _, verdict in ipairs(review.data.verdicts or {}) do
        if
          workspace.open_revisions[verdict.target_id] == review.id
          and (relevant == nil or relevant[verdict.target_id])
        then
          local target = workspace.artifacts_by_id[verdict.target_id]
          return target and tool_by_kind[target.kind]
        end
      end
    end
  end
  local target_ids = vim.tbl_keys(workspace.open_revisions or {})
  table.sort(target_ids)
  for _, target_id in ipairs(target_ids) do
    local target = workspace.artifacts_by_id[target_id]
    if target and (relevant == nil or relevant[target_id]) then
      return tool_by_kind[target.kind]
    end
  end
end

local function count_keys(values)
  local count = 0
  for _ in pairs(values) do
    count = count + 1
  end
  return count
end

local function synthesis_material(workspace, data)
  local result = {}
  for _, id in ipairs(data.selected_option_ids or {}) do
    result[id] = true
    local option = workspace.artifacts_by_id[id]
    for _, evidence_id in ipairs((option and option.data.evidence_ids) or {}) do
      result[evidence_id] = true
    end
  end
  for _, id in ipairs(data.support_ids or {}) do
    result[id] = true
  end
  for _, criterion in ipairs(data.criterion_results or {}) do
    for _, id in ipairs(criterion.evidence_ids or {}) do
      result[id] = true
    end
  end
  return result
end

function M.next(workspace, synthesis)
  if not workspace then
    return { tool = 'reasoning_frame', reason = 'Create the active problem frame' }
  end
  local frame = workspace.artifacts_by_id[workspace.frame_id]
  if not frame or frame.status ~= 'active' then
    return { tool = 'reasoning_frame', reason = 'Create the active problem frame' }
  end
  local branching_by_type = {
    decision = true,
    diagnosis = true,
    design = true,
    planning = true,
  }
  local perspective_count = #(frame.data.perspectives or {})
  if
    (frame.data.depth == 'deep' and perspective_count < 2)
    or perspective_count == 0
    or (branching_by_type[frame.data.problem_type] and not frame.data.branching_required)
  then
    return { tool = 'reasoning_frame', reason = 'Correct uncovered frame requirements' }
  end

  local current_synthesis = synthesis
  if not current_synthesis then
    local latest_synthesis = latest(workspace, 'synthesis', function(artifact)
      return State.in_lineage(workspace, artifact.data.frame_id)
    end)
    current_synthesis = latest_synthesis and latest_synthesis.data or nil
  end
  local checkpoint = latest(workspace, 'synthesis', function(artifact)
    return State.in_lineage(workspace, artifact.data.frame_id) and artifact.data.mode == 'checkpoint'
  end)
  local relevant
  local review_eligible
  if current_synthesis then
    relevant = { [frame.id] = true }
    review_eligible = {}
    for _, id in ipairs(current_synthesis.selected_option_ids or {}) do
      relevant[id] = true
      review_eligible[id] = true
      local option = workspace.artifacts_by_id[id]
      for _, evidence_id in ipairs((option and option.data.evidence_ids) or {}) do
        relevant[evidence_id] = true
        review_eligible[evidence_id] = true
      end
    end
    for _, id in ipairs(current_synthesis.support_ids or {}) do
      relevant[id] = true
      review_eligible[id] = true
    end
    for _, result in ipairs(current_synthesis.criterion_results or {}) do
      for _, id in ipairs(result.evidence_ids or {}) do
        relevant[id] = true
        review_eligible[id] = true
      end
    end
    local checkpoint_covers = checkpoint ~= nil
    local checkpoint_material = checkpoint and synthesis_material(workspace, checkpoint.data) or {}
    for id in pairs(review_eligible) do
      if not checkpoint_material[id] then
        checkpoint_covers = false
      end
    end
    if checkpoint_covers then
      review_eligible[checkpoint.id] = true
      relevant[checkpoint.id] = true
    end
  end
  local cited_reviews
  if current_synthesis then
    cited_reviews = {}
    for _, id in ipairs(current_synthesis.review_ids or {}) do
      cited_reviews[id] = true
    end
  end

  local required_perspectives = frame.data.depth == 'deep' and 2 or 1
  local all_evidence = active(workspace, 'evidence')
  local available = {}
  for _, artifact in ipairs(all_evidence) do
    available[normalized(artifact.data.perspective)] = true
  end
  if count_keys(available) < required_perspectives then
    return { tool = 'reasoning_evidence', reason = 'Gather evidence for uncovered perspectives' }
  end
  local globally_uncovered = {}
  for _, unknown in ipairs(frame.data.unknowns or {}) do
    globally_uncovered[normalized(unknown)] = true
  end
  for _, artifact in ipairs(all_evidence) do
    for _, unknown in ipairs(artifact.data.addresses_unknowns or {}) do
      globally_uncovered[normalized(unknown)] = nil
    end
  end
  if next(globally_uncovered) ~= nil then
    return { tool = 'reasoning_evidence', reason = 'Gather evidence for unresolved framed unknowns' }
  end

  local branch = latest(workspace, 'branch', function(artifact)
    return State.in_lineage(workspace, artifact.data.frame_id)
  end)
  if relevant and branch and (frame.data.branching_required or #(current_synthesis.selected_option_ids or {}) > 0) then
    relevant[branch.id] = true
  end
  if branch then
    local option_ids = branch.data.option_ids
    if current_synthesis and #(current_synthesis.selected_option_ids or {}) > 0 then
      local current_options = {}
      for _, id in ipairs(branch.data.option_ids) do
        current_options[id] = true
      end
      for _, id in ipairs(current_synthesis.selected_option_ids) do
        local selected = workspace.artifacts_by_id[id]
        if not current_options[id] or not selected or selected.status ~= 'active' or selected.kind ~= 'option' then
          return {
            tool = 'reasoning_synthesis',
            reason = 'Select active options from the current branch set in the next synthesis',
          }
        end
      end
      option_ids = current_synthesis.selected_option_ids
    end
    for _, option_id in ipairs(option_ids) do
      local option = workspace.artifacts_by_id[option_id]
      if option and option.status == 'active' then
        local evidence_ids = option.data.evidence_ids or {}
        local supported = #evidence_ids > 0
        for _, evidence_id in ipairs(evidence_ids) do
          supported = supported and active_evidence(workspace, evidence_id)
        end
        if not supported or #(option.data.predictions or {}) == 0 then
          return {
            tool = 'reasoning_options',
            reason = 'Replace the branch set so every option cites active evidence and states testable predictions',
          }
        end
      end
    end
  end
  if not current_synthesis then
    review_eligible = {}
    if branch then
      for _, option_id in ipairs(branch.data.option_ids or {}) do
        local option = workspace.artifacts_by_id[option_id]
        if option and option.status == 'active' then
          review_eligible[option_id] = true
          for _, evidence_id in ipairs(option.data.evidence_ids or {}) do
            if active_evidence(workspace, evidence_id) then
              review_eligible[evidence_id] = true
            end
          end
        end
      end
    else
      for _, artifact in ipairs(active(workspace, 'evidence')) do
        review_eligible[artifact.id] = true
      end
    end
  end

  local covered = {}
  for _, artifact in ipairs(all_evidence) do
    if relevant == nil or relevant[artifact.id] then
      covered[normalized(artifact.data.perspective)] = true
    end
  end
  if count_keys(covered) < required_perspectives then
    return {
      tool = 'reasoning_synthesis',
      reason = 'Cite active evidence from every required perspective in the next synthesis',
    }
  end

  local uncovered = {}
  for _, unknown in ipairs(frame.data.unknowns or {}) do
    local key = normalized(unknown)
    uncovered[key] = true
  end
  for _, artifact in ipairs(all_evidence) do
    for _, unknown in ipairs(artifact.data.addresses_unknowns or {}) do
      local key = normalized(unknown)
      if relevant == nil or relevant[artifact.id] then
        uncovered[key] = nil
      end
    end
  end
  if next(uncovered) ~= nil then
    return {
      tool = 'reasoning_synthesis',
      reason = 'Cite the evidence that resolves every framed unknown in the next synthesis',
    }
  end
  if frame.data.branching_required and not branch then
    return { tool = 'reasoning_options', reason = 'Create the required competing branches' }
  end
  if
    branch
    and frame.data.branching_required
    and current_synthesis
    and #(current_synthesis.selected_option_ids or {}) == 0
  then
    return { tool = 'reasoning_synthesis', reason = 'Select a supported option in the next synthesis' }
  end

  if current_synthesis then
    for _, id in ipairs(current_synthesis.support_ids or {}) do
      if not active_evidence(workspace, id) then
        return { tool = 'reasoning_synthesis', reason = 'Replace inactive support citations in the next synthesis' }
      end
    end
    for _, result in ipairs(current_synthesis.criterion_results or {}) do
      for _, id in ipairs(result.evidence_ids or {}) do
        if not active_evidence(workspace, id) then
          return { tool = 'reasoning_synthesis', reason = 'Replace inactive criterion evidence in the next synthesis' }
        end
      end
    end
    for _, id in ipairs(current_synthesis.review_ids or {}) do
      if not review_sound(workspace, workspace.artifacts_by_id[id]) then
        return { tool = 'reasoning_synthesis', reason = 'Replace stale review citations in the next synthesis' }
      end
    end
  end

  local contradiction, has_relevant_contradiction = contradiction_state(workspace, relevant, cited_reviews)
  if contradiction == 'unresolved' then
    return { tool = 'reasoning_review', reason = 'Review an unresolved contradiction' }
  end
  if contradiction == 'uncited' then
    return {
      tool = 'reasoning_synthesis',
      reason = 'Cite the existing contradiction resolution in the next synthesis',
    }
  end

  local correction_tool = revision_tool(workspace, relevant)
  if correction_tool then
    return { tool = correction_tool, reason = 'Apply the latest required revision' }
  end

  local all_reviews, cited = {}, {}
  for _, review in ipairs(active(workspace, 'review')) do
    if review_sound(workspace, review) then
      table.insert(all_reviews, review)
      if cited_reviews == nil or cited_reviews[review.id] then
        table.insert(cited, review)
      end
    end
  end
  local function review_relevant(review)
    if review_eligible == nil then
      return true
    end
    for _, id in ipairs(review.data.target_ids or {}) do
      if review_eligible[id] then
        return true
      end
    end
    return false
  end
  local function any_review(reviews, mode, require_stress)
    for _, review in ipairs(reviews) do
      if
        (not mode or review.data.mode == mode)
        and (not require_stress or #(review.data.stress_tests or {}) > 0)
        and review_relevant(review)
      then
        return true
      end
    end
    return false
  end

  if frame.data.temporal_required and not any_review(cited, nil, true) then
    if current_synthesis and any_review(all_reviews, nil, true) then
      return {
        tool = 'reasoning_synthesis',
        reason = 'Cite the existing temporal review in the next synthesis',
      }
    end
    return { tool = 'reasoning_review', reason = 'Adversarially review the strongest current case' }
  end
  if frame.data.depth == 'deep' and not any_review(cited, 'full') then
    if current_synthesis and any_review(all_reviews, 'full') then
      return {
        tool = 'reasoning_synthesis',
        reason = 'Cite the existing relevant review in the next synthesis',
      }
    end
    return { tool = 'reasoning_review', reason = 'Run a full review of selected or supporting artifacts' }
  end
  if (branch or has_relevant_contradiction) and not any_review(cited) then
    if current_synthesis and any_review(all_reviews) then
      return {
        tool = 'reasoning_synthesis',
        reason = 'Cite the existing relevant review in the next synthesis',
      }
    end
    return { tool = 'reasoning_review', reason = 'Adversarially review the strongest current case' }
  end

  local covered_criteria = {}
  local expected_criteria = {}
  for _, criterion in ipairs(frame.data.success_criteria) do
    expected_criteria[normalized(criterion)] = true
  end
  local criterion_invalid = false
  local observed_criteria = {}
  for _, result in ipairs((current_synthesis and current_synthesis.criterion_results) or {}) do
    local key = normalized(result.criterion)
    criterion_invalid = criterion_invalid or not expected_criteria[key] or observed_criteria[key] == true
    observed_criteria[key] = true
    local covered_result = result.status == 'not_applicable'
      and type(result.explanation) == 'string'
      and vim.trim(result.explanation) ~= ''
    if result.status == 'passed' and #(result.evidence_ids or {}) > 0 then
      covered_result = true
      for _, id in ipairs(result.evidence_ids) do
        covered_result = covered_result and active_evidence(workspace, id)
      end
    end
    if covered_result then
      covered_criteria[key] = true
    end
  end
  for _, criterion in ipairs(frame.data.success_criteria) do
    if criterion_invalid or not covered_criteria[normalized(criterion)] then
      return { tool = 'reasoning_synthesis', reason = 'Record verification for every success criterion' }
    end
  end
  local latest_id = workspace.artifact_order[#workspace.artifact_order]
  local latest_artifact = latest_id and workspace.artifacts_by_id[latest_id] or nil
  if
    current_synthesis
    and current_synthesis.mode == 'final'
    and latest_artifact
    and latest_artifact.status == 'active'
    and latest_artifact.kind == 'synthesis'
    and latest_artifact.data.mode == 'final'
    and State.in_lineage(workspace, latest_artifact.data.frame_id)
  then
    return { tool = 'none', reason = 'Final synthesis accepted; no further model action is permitted' }
  end
  return { tool = 'reasoning_synthesis', reason = 'All structural gates are ready for final synthesis' }
end

return M
