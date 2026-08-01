local Config = require('codecompanion._extensions.reasoning.config')
local Guidance = require('codecompanion._extensions.reasoning.guidance')
local State = require('codecompanion._extensions.reasoning.state')
local Terminal = require('codecompanion._extensions.reasoning.terminal')
local log = require('codecompanion.utils.log')

local M = {}

local function failure(code, message, artifact_ids, next_action)
  return {
    status = 'error',
    data = {
      code = code,
      message = message,
      artifact_ids = artifact_ids or {},
      next_action = next_action,
    },
  }
end

local function success(workspace, artifact)
  return {
    status = 'success',
    data = {
      workspace_id = workspace.id,
      artifact = vim.deepcopy(artifact),
      progress = vim.deepcopy(workspace.counts_by_kind),
      unmet_gates = M.final_gates(workspace, nil),
      next_action = Guidance.next(workspace),
    },
  }
end

local function text_valid(value)
  return type(value) == 'string'
    and vim.trim(value) ~= ''
    and vim.fn.strchars(value) <= Config.get().limits.max_text_chars
end

local function bounded_array(value, minimum, maximum)
  return type(value) == 'table' and #value >= minimum and #value <= maximum
end

local function frame_text_array(value, minimum)
  if not bounded_array(value, minimum or 0, Config.get().limits.max_array_items) then
    return false
  end
  for _, item in ipairs(value) do
    if not text_valid(item) then
      return false
    end
  end
  return true
end

local function unique_frame_texts(values)
  local seen = {}
  for _, value in ipairs(values) do
    local key = vim.trim(value):lower():gsub('%s+', ' ')
    if seen[key] then
      return false
    end
    seen[key] = true
  end
  return true
end

function M.frame(chat, args)
  if
    type(args) ~= 'table'
    or not vim.tbl_contains({ 'start', 'revise', 'replace' }, args.action)
    or not text_valid(args.objective)
    or not frame_text_array(args.constraints)
    or not frame_text_array(args.success_criteria, 1)
    or not frame_text_array(args.unknowns)
    or type(args.temporal_required) ~= 'boolean'
    or type(args.branching_required) ~= 'boolean'
    or not text_valid(args.branching_rationale)
  then
    return failure('frame_incomplete', 'objective must be non-empty and bounded', {}, 'Call reasoning_frame')
  end
  if not unique_frame_texts(args.success_criteria) or not unique_frame_texts(args.unknowns) then
    return failure(
      'frame_incomplete',
      'success criteria and unknowns must be unique',
      {},
      'Remove duplicate frame entries'
    )
  end
  if not vim.tbl_contains({ 'analysis', 'decision', 'diagnosis', 'design', 'planning' }, args.problem_type) then
    return failure('frame_incomplete', 'problem_type is invalid', {}, 'Call reasoning_frame with a valid problem_type')
  end
  if args.depth ~= 'standard' and args.depth ~= 'deep' then
    return failure('frame_incomplete', 'depth must be standard or deep', {}, 'Call reasoning_frame with a valid depth')
  end
  local minimum_perspectives = args.depth == 'deep' and 2 or 1
  if not bounded_array(args.perspectives, minimum_perspectives, math.min(4, Config.get().limits.max_array_items)) then
    return failure(
      'frame_incomplete',
      'perspectives do not satisfy the selected depth',
      {},
      'Add distinct perspectives'
    )
  end
  local perspective_names = {}
  for _, perspective in ipairs(args.perspectives) do
    if type(perspective) ~= 'table' or not text_valid(perspective.name) or not text_valid(perspective.purpose) then
      return failure(
        'frame_incomplete',
        'every perspective needs a bounded name and purpose',
        {},
        'Correct the perspectives'
      )
    end
    local name = vim.trim(perspective.name):lower():gsub('%s+', ' ')
    if perspective_names[name] then
      return failure('frame_incomplete', 'perspective names must be unique', {}, 'Rename the duplicate perspective')
    end
    perspective_names[name] = true
  end
  local requires_branching = vim.tbl_contains({ 'decision', 'diagnosis', 'design', 'planning' }, args.problem_type)
  if requires_branching and not args.branching_required then
    return failure(
      'branching_required',
      'this problem type requires competing branches',
      {},
      'Set branching_required to true'
    )
  end
  local existing = State.get(chat)
  if args.action == 'start' and existing then
    return failure(
      'workspace_exists',
      'an active workspace already exists',
      { existing.frame_id },
      'Use revise or replace'
    )
  end
  if args.action == 'revise' and not existing then
    return failure('workspace_missing', 'there is no frame to revise', {}, 'Start a frame')
  end
  if args.action == 'revise' then
    local unknown_names = {}
    for _, unknown in ipairs(args.unknowns) do
      unknown_names[vim.trim(unknown):lower():gsub('%s+', ' ')] = true
    end
    for _, id in ipairs(existing.artifact_order) do
      local artifact = State.find(existing, id)
      if
        artifact.status == 'active'
        and artifact.kind == 'evidence'
        and not perspective_names[vim.trim(artifact.data.perspective):lower():gsub('%s+', ' ')]
      then
        return failure(
          'frame_incomplete',
          'a revised frame cannot remove a perspective used by active evidence',
          { artifact.id },
          'Retract or replace the evidence before revising the frame'
        )
      end
      if artifact.status == 'active' and artifact.kind == 'evidence' then
        for _, unknown in ipairs(artifact.data.addresses_unknowns or {}) do
          local key = vim.trim(unknown):lower():gsub('%s+', ' ')
          if not unknown_names[key] then
            return failure(
              'frame_incomplete',
              'a revised frame cannot remove an unknown addressed by active evidence',
              { artifact.id },
              'Retract or replace the evidence before revising the frame'
            )
          end
        end
      end
    end
  end
  local workspace = existing
  if args.action == 'start' then
    workspace = State.begin(chat)
  elseif args.action == 'replace' then
    workspace = State.begin(chat, true)
  end
  local frame_data = vim.deepcopy(args)
  frame_data.action = nil
  local frame = State.add(workspace, 'frame', frame_data)
  if not frame then
    return failure('limit_exceeded', 'the workspace artifact limit was reached', {}, 'Replace the workspace')
  end
  if workspace.frame_id then
    State.supersede(workspace, workspace.frame_id, frame.id)
  end
  workspace.frame_id = frame.id
  return success(workspace, frame)
end

local function normalized(value)
  return vim.trim(value):lower():gsub('%s+', ' ')
end

local function text_array_valid(value, minimum)
  if not bounded_array(value, minimum or 0, Config.get().limits.max_array_items) then
    return false
  end
  for _, item in ipairs(value) do
    if not text_valid(item) then
      return false
    end
  end
  return true
end

local function active_reference(workspace, id)
  local artifact = State.find(workspace, id)
  if not artifact then
    return nil, 'invalid_reference'
  end
  if artifact.status ~= 'active' then
    return nil, 'inactive_reference'
  end
  return artifact
end

local function evidence_success(workspace, artifacts)
  return {
    status = 'success',
    data = {
      workspace_id = workspace.id,
      artifact = vim.deepcopy(artifacts[#artifacts]),
      artifacts = vim.deepcopy(artifacts),
      progress = vim.deepcopy(workspace.counts_by_kind),
      unmet_gates = M.final_gates(workspace, nil),
      next_action = Guidance.next(workspace),
    },
  }
end

function M.evidence(chat, args)
  local workspace = State.get(chat)
  if not workspace then
    return failure('workspace_missing', 'start a frame before recording evidence', {}, 'Call reasoning_frame')
  end
  if type(args) ~= 'table' or not bounded_array(args.items, 1, Config.get().limits.max_batch_items) then
    return failure('evidence_invalid', 'items must be a non-empty bounded batch', {}, 'Call reasoning_evidence')
  end

  local frame = State.find(workspace, workspace.frame_id)
  local perspectives = {}
  for _, perspective in ipairs(frame.data.perspectives) do
    perspectives[normalized(perspective.name)] = true
  end
  local frame_unknowns = {}
  for _, unknown in ipairs(frame.data.unknowns) do
    frame_unknowns[normalized(unknown)] = true
  end

  local known_statements = {}
  for _, id in ipairs(workspace.artifact_order) do
    local artifact = State.find(workspace, id)
    if artifact.kind == 'evidence' then
      known_statements[normalized(artifact.data.statement)] = artifact.id
    end
  end

  local prepared = {}
  local pending_statements = {}
  local pending_supersessions = {}
  local pending_ids = {}
  local evidence_sequence = workspace.next_sequence.evidence or 0
  for index = 1, #args.items do
    pending_ids['E' .. (evidence_sequence + index)] = index
  end
  for index, item in ipairs(args.items) do
    if
      type(item) ~= 'table'
      or not vim.tbl_contains({ 'observation', 'claim', 'assumption' }, item.kind)
      or not text_valid(item.statement)
      or not text_valid(item.source)
      or not vim.tbl_contains({ 'low', 'medium', 'high' }, item.confidence)
      or not text_valid(item.falsifier)
      or not text_valid(item.perspective)
      or not text_array_valid(item.addresses_unknowns)
      or not text_array_valid(item.supports)
      or not text_array_valid(item.contradicts)
      or not text_array_valid(item.qualifies)
      or type(item.supersedes_id) ~= 'string'
    then
      return failure(
        'evidence_invalid',
        'evidence item ' .. index .. ' is invalid',
        {},
        'Correct reasoning_evidence fields'
      )
    end
    local source = normalized(item.source)
    if item.kind == 'assumption' and not source:match('^assumption:') then
      return failure(
        'evidence_invalid',
        'assumption sources must begin with assumption:',
        {},
        'Label the assumption source'
      )
    end
    if item.kind == 'observation' and vim.tbl_contains({ 'unknown', 'unspecified', 'none' }, source) then
      return failure('evidence_invalid', 'observations require a concrete source', {}, 'Provide the observation source')
    end
    if not perspectives[normalized(item.perspective)] then
      return failure(
        'perspective_unknown',
        'evidence references an unknown perspective',
        {},
        'Revise the frame or perspective'
      )
    end
    local addressed = {}
    for _, unknown in ipairs(item.addresses_unknowns) do
      local key = normalized(unknown)
      if addressed[key] or not frame_unknowns[key] then
        return failure(
          'evidence_invalid',
          'addresses_unknowns must uniquely match active frame unknowns',
          {},
          'Use exact unknowns from reasoning_frame'
        )
      end
      addressed[key] = true
    end
    for _, field in ipairs({ 'supports', 'contradicts', 'qualifies' }) do
      local seen = {}
      for _, id in ipairs(item[field]) do
        if seen[id] then
          return failure(
            'evidence_invalid',
            field .. ' contains a duplicate ID',
            { id },
            'Remove the duplicate reference'
          )
        end
        seen[id] = true
        local _, code = active_reference(workspace, id)
        if code == 'invalid_reference' and pending_ids[id] and pending_ids[id] < index then
          code = nil
        end
        if code then
          return failure(code, 'evidence relation target is unavailable', { id }, 'Use an active artifact ID')
        end
      end
    end
    if item.supersedes_id ~= '' then
      local target, code = active_reference(workspace, item.supersedes_id)
      if code then
        return failure(code, 'superseded evidence is unavailable', { item.supersedes_id }, 'Use an active evidence ID')
      end
      if target.kind ~= 'evidence' then
        return failure(
          'invalid_reference',
          'supersedes_id must name evidence',
          { item.supersedes_id },
          'Use reasoning_evidence'
        )
      end
      if pending_supersessions[item.supersedes_id] then
        return failure(
          'duplicate_artifact',
          'one evidence artifact cannot have two replacements in the same batch',
          { item.supersedes_id },
          'Submit one replacement for the evidence ID'
        )
      end
      pending_supersessions[item.supersedes_id] = true
    end
    local key = normalized(item.statement)
    local duplicate_id = known_statements[key]
    if pending_statements[key] then
      return failure(
        'duplicate_artifact',
        'the evidence batch contains duplicate normalized statements',
        duplicate_id and { duplicate_id } or {},
        'Keep one statement or submit separate revisions'
      )
    end
    if duplicate_id and item.supersedes_id ~= duplicate_id then
      return failure(
        'duplicate_artifact',
        'an evidence artifact already has the same statement',
        { duplicate_id },
        'Supersede the active evidence or use a distinct statement'
      )
    end
    pending_statements[key] = true
    table.insert(prepared, vim.deepcopy(item))
  end

  for _, item in ipairs(prepared) do
    for _, field in ipairs({ 'supports', 'contradicts', 'qualifies' }) do
      for _, id in ipairs(item[field]) do
        if pending_supersessions[id] then
          return failure(
            'inactive_reference',
            'evidence relation target is superseded by the same batch',
            { id },
            'Reference the replacement evidence artifact'
          )
        end
      end
    end
  end

  if #workspace.artifact_order + #prepared > Config.get().limits.max_artifacts then
    return failure(
      'limit_exceeded',
      'the complete evidence batch exceeds the artifact limit',
      {},
      'Replace the workspace or reduce the batch'
    )
  end

  local artifacts = {}
  for _, item in ipairs(prepared) do
    local artifact = assert(State.add(workspace, 'evidence', item))
    table.insert(artifacts, artifact)
  end
  for index, item in ipairs(prepared) do
    local artifact = artifacts[index]
    for _, field in ipairs({ 'supports', 'contradicts', 'qualifies' }) do
      for _, id in ipairs(item[field]) do
        State.add_relation(artifact, field, id)
      end
    end
    if item.supersedes_id ~= '' then
      State.supersede(workspace, item.supersedes_id, artifact.id)
    end
  end
  return evidence_success(workspace, artifacts)
end

function M.options(chat, args)
  local workspace = State.get(chat)
  if not workspace then
    return failure('workspace_missing', 'start a frame before creating branches', {}, 'Call reasoning_frame')
  end
  if
    type(args) ~= 'table'
    or not text_valid(args.question)
    or not vim.tbl_contains({ 'solution', 'hypothesis', 'scenario' }, args.branch_type)
    or not bounded_array(args.criteria, 1, math.min(8, Config.get().limits.max_array_items))
    or type(args.supersedes_branch_id) ~= 'string'
    or (args.supersedes_branch_id ~= '' and not text_valid(args.supersedes_branch_id))
  then
    return failure('options_invalid', 'branch-set fields are invalid', {}, 'Correct reasoning_options fields')
  end
  local criteria = {}
  for _, criterion in ipairs(args.criteria) do
    if not text_valid(criterion) then
      return failure('options_invalid', 'criteria must contain bounded text', {}, 'Correct reasoning_options criteria')
    end
    local key = normalized(criterion)
    if criteria[key] then
      return failure('options_invalid', 'criteria must be unique', {}, 'Remove the duplicate criterion')
    end
    criteria[key] = true
  end
  if not bounded_array(args.options, 2, math.min(6, Config.get().limits.max_array_items)) then
    return failure(
      'branch_count_insufficient',
      'a branch set requires two to six options',
      {},
      'Provide competing options'
    )
  end

  local active_branch
  for index = #workspace.artifact_order, 1, -1 do
    local artifact = State.find(workspace, workspace.artifact_order[index])
    if artifact.kind == 'branch' and artifact.status == 'active' then
      active_branch = artifact
      break
    end
  end
  if active_branch and args.supersedes_branch_id == '' then
    return failure(
      'options_invalid',
      'an active branch set must be explicitly superseded',
      { active_branch.id },
      'Set supersedes_branch_id to the active branch ID'
    )
  end
  if active_branch and args.supersedes_branch_id ~= active_branch.id then
    return failure(
      'options_invalid',
      'supersedes_branch_id must name the current active branch set',
      { active_branch.id },
      'Set supersedes_branch_id to the active branch ID'
    )
  end

  local replaced
  if args.supersedes_branch_id ~= '' then
    local code
    replaced, code = active_reference(workspace, args.supersedes_branch_id)
    if code then
      return failure(
        code,
        'the replaced branch set is unavailable',
        { args.supersedes_branch_id },
        'Use an active branch ID'
      )
    end
    if replaced.kind ~= 'branch' then
      return failure(
        'invalid_reference',
        'supersedes_branch_id must name a branch set',
        { replaced.id },
        'Use an active B artifact'
      )
    end
  end

  local labels = {}
  local prepared = {}
  for index, option in ipairs(args.options) do
    if
      type(option) ~= 'table'
      or not text_valid(option.label)
      or not text_valid(option.summary)
      or not text_array_valid(option.evidence_ids, 1)
      or not text_array_valid(option.assumptions)
      or not text_array_valid(option.predictions, 1)
      or not text_array_valid(option.benefits)
      or not text_array_valid(option.costs)
      or not text_array_valid(option.risks)
      or not vim.tbl_contains({ 'easy', 'moderate', 'hard' }, option.reversibility)
    then
      return failure('options_invalid', 'option ' .. index .. ' is invalid', {}, 'Correct the option fields')
    end
    local label = normalized(option.label)
    if labels[label] then
      return failure('options_invalid', 'option labels must be unique', {}, 'Rename the duplicate option')
    end
    labels[label] = true
    local seen_evidence = {}
    for _, id in ipairs(option.evidence_ids) do
      if seen_evidence[id] then
        return failure('options_invalid', 'option evidence_ids contains a duplicate', { id }, 'Remove the duplicate ID')
      end
      seen_evidence[id] = true
      local target, code = active_reference(workspace, id)
      if code then
        return failure(code, 'option evidence is unavailable', { id }, 'Use active evidence IDs')
      end
      if target.kind ~= 'evidence' then
        return failure('invalid_reference', 'option evidence_ids must name evidence', { id }, 'Use E artifact IDs')
      end
    end
    table.insert(prepared, vim.deepcopy(option))
  end

  if #workspace.artifact_order + 1 + #prepared > Config.get().limits.max_artifacts then
    return failure(
      'limit_exceeded',
      'the branch set exceeds the artifact limit',
      {},
      'Replace the workspace or reduce branches'
    )
  end

  local branch_data = {
    question = args.question,
    branch_type = args.branch_type,
    criteria = vim.deepcopy(args.criteria),
    option_ids = {},
    frame_id = workspace.frame_id,
    supersedes_branch_id = args.supersedes_branch_id,
  }
  local branch = assert(State.add(workspace, 'branch', branch_data))
  State.add_relation(branch, 'depends_on', workspace.frame_id)
  local options = {}
  for _, option in ipairs(prepared) do
    local artifact = assert(State.add(workspace, 'option', option))
    table.insert(branch.data.option_ids, artifact.id)
    State.add_relation(artifact, 'depends_on', branch.id)
    for _, id in ipairs(option.evidence_ids) do
      State.add_relation(artifact, 'supports', id)
    end
    table.insert(options, artifact)
  end
  if replaced then
    State.supersede(workspace, replaced.id, branch.id)
    for _, id in ipairs(replaced.data.option_ids) do
      if State.find(workspace, id).status == 'active' then
        State.retire(workspace, id)
      end
    end
  end
  return {
    status = 'success',
    data = {
      workspace_id = workspace.id,
      artifact = vim.deepcopy(branch),
      artifacts = vim.deepcopy(options),
      progress = vim.deepcopy(workspace.counts_by_kind),
      unmet_gates = M.final_gates(workspace, nil),
      next_action = Guidance.next(workspace),
    },
  }
end

local function contradiction_key(left, right)
  if left > right then
    left, right = right, left
  end
  return left .. ':' .. right
end

local function validate_evidence_ids(workspace, ids)
  if not text_array_valid(ids) then
    return nil, 'review_incomplete'
  end
  local seen = {}
  for _, id in ipairs(ids) do
    if seen[id] then
      return nil, 'review_incomplete', id
    end
    seen[id] = true
    local target, code = active_reference(workspace, id)
    if code then
      return nil, code, id
    end
    if target.kind ~= 'evidence' then
      return nil, 'invalid_reference', id
    end
  end
  return true
end

local function collect_perspectives(workspace, artifact, perspectives, visited)
  if not artifact or artifact.status ~= 'active' or visited[artifact.id] then
    return
  end
  visited[artifact.id] = true
  if artifact.kind == 'evidence' then
    perspectives[normalized(artifact.data.perspective)] = true
    return
  end
  if artifact.kind == 'frame' then
    return
  end
  local reference_ids = {}
  if artifact.kind == 'option' then
    reference_ids = artifact.data.evidence_ids or {}
  elseif artifact.kind == 'branch' then
    reference_ids = artifact.data.option_ids or {}
  elseif artifact.kind == 'synthesis' then
    vim.list_extend(reference_ids, artifact.data.selected_option_ids or {})
    vim.list_extend(reference_ids, artifact.data.support_ids or {})
    vim.list_extend(reference_ids, artifact.data.review_ids or {})
    for _, result in ipairs(artifact.data.criterion_results or {}) do
      vim.list_extend(reference_ids, result.evidence_ids or {})
    end
  elseif artifact.kind == 'review' then
    reference_ids = artifact.relations.supports or {}
  end
  for _, id in ipairs(reference_ids) do
    collect_perspectives(workspace, State.find(workspace, id), perspectives, visited)
  end
end

local function corrective_tool(kind)
  return ({
    frame = 'reasoning_frame',
    evidence = 'reasoning_evidence',
    branch = 'reasoning_options',
    option = 'reasoning_options',
    synthesis = 'reasoning_synthesis',
  })[kind] or 'reasoning_review'
end

function M.review(chat, args)
  local workspace = State.get(chat)
  if not workspace then
    return failure('workspace_missing', 'start a frame before review', {}, 'Call reasoning_frame')
  end
  local modes = { 'falsification', 'assumptions', 'temporal', 'cross_perspective', 'full' }
  if type(args) ~= 'table' or not vim.tbl_contains(modes, args.mode) or not text_array_valid(args.target_ids, 1) then
    return failure('review_incomplete', 'mode and target_ids are required', {}, 'Correct reasoning_review fields')
  end

  local targets = {}
  for _, id in ipairs(args.target_ids) do
    if targets[id] then
      return failure('review_incomplete', 'target_ids must be unique', { id }, 'Remove the duplicate target')
    end
    local target, code = active_reference(workspace, id)
    if code then
      return failure(code, 'review target is unavailable', { id }, 'Use an active artifact ID')
    end
    if target.kind == 'review' then
      return failure(
        'invalid_reference',
        'reviews cannot revise another review artifact',
        { id },
        'Target a frame, evidence, branch, option, or synthesis'
      )
    end
    targets[id] = target
  end

  if type(args.defense) ~= 'table' or not text_valid(args.defense.summary) then
    return failure(
      'review_incomplete',
      'a bounded defense summary is required',
      {},
      'Add the strongest surviving defense'
    )
  end
  local evidence_ok, evidence_code, evidence_id = validate_evidence_ids(workspace, args.defense.evidence_ids)
  if not evidence_ok then
    return failure(
      evidence_code,
      'defense evidence is invalid',
      evidence_id and { evidence_id } or {},
      'Use active evidence IDs'
    )
  end
  if args.mode == 'full' and #args.defense.evidence_ids == 0 then
    return failure('review_incomplete', 'full review requires defense evidence', {}, 'Add evidence to the defense')
  end
  local required_evidence = {}
  for _, id in ipairs(args.defense.evidence_ids) do
    required_evidence[id] = true
  end

  if not bounded_array(args.challenges, 1, Config.get().limits.max_array_items) then
    return failure('review_incomplete', 'at least one challenge is required', {}, 'Add an adversarial challenge')
  end
  local challenge_kinds = {
    'counterexample',
    'missing_evidence',
    'hidden_assumption',
    'temporal_failure',
    'overclaim',
    'underclaim',
  }
  local has_disconfirmation, has_hidden_assumption = false, false
  local challenged_targets = {}
  for index, challenge in ipairs(args.challenges) do
    if
      type(challenge) ~= 'table'
      or not vim.tbl_contains(challenge_kinds, challenge.kind)
      or not text_valid(challenge.summary)
      or not text_array_valid(challenge.target_ids, 1)
      or not text_valid(challenge.falsifier)
    then
      return failure('review_incomplete', 'challenge ' .. index .. ' is invalid', {}, 'Correct the challenge fields')
    end
    local challenge_targets = {}
    for _, id in ipairs(challenge.target_ids) do
      if challenge_targets[id] then
        return failure(
          'review_incomplete',
          'challenge target_ids must be unique',
          { id },
          'Remove the duplicate challenge target'
        )
      end
      challenge_targets[id] = true
      if not targets[id] then
        return failure(
          'invalid_reference',
          'challenge targets must be in target_ids',
          { id },
          'Add the target to target_ids'
        )
      end
      challenged_targets[id] = true
    end
    has_disconfirmation = has_disconfirmation
      or vim.tbl_contains({ 'counterexample', 'missing_evidence', 'temporal_failure', 'overclaim' }, challenge.kind)
    has_hidden_assumption = has_hidden_assumption or challenge.kind == 'hidden_assumption'
  end
  for _, id in ipairs(args.target_ids) do
    if not challenged_targets[id] then
      return failure(
        'review_incomplete',
        'every review target must receive an adversarial challenge',
        { id },
        'Add a challenge for the uncovered target'
      )
    end
  end
  if not text_array_valid(args.blind_spots, args.mode == 'full' and 1 or 0) then
    return failure('review_incomplete', 'blind_spots is invalid for this mode', {}, 'Record a blind spot')
  end
  if args.mode == 'full' and (not has_disconfirmation or not has_hidden_assumption) then
    return failure(
      'review_incomplete',
      'full review requires disconfirmation and a hidden assumption',
      {},
      'Add both challenge types'
    )
  end
  if args.mode == 'falsification' and not has_disconfirmation then
    return failure(
      'review_incomplete',
      'falsification review requires a disconfirming challenge',
      {},
      'Add a falsifiable attack'
    )
  end
  if args.mode == 'assumptions' and not has_hidden_assumption then
    return failure(
      'review_incomplete',
      'assumptions review requires a hidden-assumption challenge',
      {},
      'Expose a hidden assumption'
    )
  end
  if args.mode == 'cross_perspective' and #args.target_ids < 2 then
    return failure(
      'review_incomplete',
      'cross-perspective review requires at least two targets',
      args.target_ids,
      'Add another perspective target'
    )
  end
  if args.mode == 'cross_perspective' then
    local perspectives = {}
    for _, id in ipairs(args.target_ids) do
      collect_perspectives(workspace, targets[id], perspectives, {})
    end
    local count = 0
    for _ in pairs(perspectives) do
      count = count + 1
    end
    if count < 2 then
      return failure(
        'review_incomplete',
        'cross-perspective review requires evidence from distinct frame perspectives',
        args.target_ids,
        'Target artifacts grounded in at least two perspectives'
      )
    end
  end

  if not bounded_array(args.stress_tests, 0, Config.get().limits.max_array_items) then
    return failure('review_incomplete', 'stress_tests is invalid', {}, 'Correct the stress tests')
  end
  for index, test in ipairs(args.stress_tests) do
    if
      type(test) ~= 'table'
      or not text_valid(test.scenario)
      or not text_valid(test.prediction)
      or not text_valid(test.failure_signal)
    then
      return failure(
        'review_incomplete',
        'stress test ' .. index .. ' is invalid',
        {},
        'Correct the stress-test fields'
      )
    end
  end
  local frame = State.find(workspace, workspace.frame_id)
  if (args.mode == 'temporal' or frame.data.temporal_required) and #args.stress_tests == 0 then
    return failure('review_incomplete', 'temporal reasoning requires a stress test', {}, 'Add a temporal stress test')
  end

  if not bounded_array(args.verdicts, #args.target_ids, #args.target_ids) then
    return failure(
      'review_incomplete',
      'every target requires exactly one verdict',
      args.target_ids,
      'Cover every target'
    )
  end
  local verdicts = {}
  for _, verdict in ipairs(args.verdicts) do
    if
      type(verdict) ~= 'table'
      or not targets[verdict.target_id]
      or verdicts[verdict.target_id]
      or not vim.tbl_contains({ 'keep', 'revise', 'retract' }, verdict.status)
      or type(verdict.revision_instruction) ~= 'string'
      or vim.fn.strchars(verdict.revision_instruction) > Config.get().limits.max_text_chars
      or (verdict.status == 'revise' and not text_valid(verdict.revision_instruction))
      or (verdict.status ~= 'revise' and verdict.revision_instruction ~= '')
    then
      return failure(
        'review_incomplete',
        'verdicts must uniquely cover every target',
        args.target_ids,
        'Correct the verdicts'
      )
    end
    verdicts[verdict.target_id] = verdict.status
    local target = targets[verdict.target_id]
    if target.kind == 'frame' and verdict.status == 'retract' then
      return failure(
        'review_incomplete',
        'the active frame must be revised or replaced rather than retracted',
        { verdict.target_id },
        {
          tool = 'reasoning_frame',
          reason = 'Revise or replace the active problem frame',
        }
      )
    end
    if target.kind == 'option' and verdict.status == 'retract' then
      return failure(
        'review_incomplete',
        'an option cannot be retracted independently of its branch set',
        { verdict.target_id },
        {
          tool = 'reasoning_options',
          reason = 'Revise the option and replace the complete branch set',
        }
      )
    end
    if verdict.status == 'revise' and workspace.open_revisions[verdict.target_id] then
      return failure(
        'review_incomplete',
        'the target already has an unresolved revision requirement',
        { verdict.target_id },
        {
          tool = corrective_tool(target.kind),
          reason = 'Resolve the existing revision before opening another',
        }
      )
    end
  end
  for id, target in pairs(targets) do
    if target.kind == 'branch' and verdicts[id] == 'retract' then
      for _, option_id in ipairs(target.data.option_ids or {}) do
        if targets[option_id] then
          return failure(
            'review_incomplete',
            'a retracted branch set and its child options cannot receive mixed verdicts',
            { id, option_id },
            {
              tool = 'reasoning_options',
              reason = 'Review or replace the branch set as one coherent unit',
            }
          )
        end
      end
    end
  end

  if not bounded_array(args.contradiction_resolutions, 0, Config.get().limits.max_array_items) then
    return failure(
      'review_incomplete',
      'contradiction_resolutions is invalid',
      {},
      'Correct the contradiction resolutions'
    )
  end
  local contradiction_pairs = {}
  for index, resolution in ipairs(args.contradiction_resolutions) do
    if
      type(resolution) ~= 'table'
      or not text_valid(resolution.left_id)
      or not text_valid(resolution.right_id)
      or resolution.left_id == resolution.right_id
      or not text_valid(resolution.resolution)
      or not bounded_array(resolution.evidence_ids, 1, Config.get().limits.max_array_items)
    then
      return failure(
        'review_incomplete',
        'contradiction resolution ' .. index .. ' is invalid',
        {},
        'Correct the contradiction resolution'
      )
    end
    local left, right = targets[resolution.left_id], targets[resolution.right_id]
    if not left or not right then
      return failure(
        'invalid_reference',
        'contradiction endpoints must both be reviewed',
        { resolution.left_id, resolution.right_id },
        'Target both contradictory artifacts'
      )
    end
    if verdicts[left.id] ~= 'keep' or verdicts[right.id] ~= 'keep' then
      return failure(
        'review_incomplete',
        'resolved contradiction endpoints require keep verdicts',
        { left.id, right.id },
        'Keep both qualified endpoints or omit the resolution'
      )
    end
    local actual = vim.tbl_contains(left.relations.contradicts, right.id)
      or vim.tbl_contains(right.relations.contradicts, left.id)
    if not actual then
      return failure(
        'review_incomplete',
        'the resolution does not name an active contradiction',
        { left.id, right.id },
        'Resolve an actual contradiction pair'
      )
    end
    local key = contradiction_key(left.id, right.id)
    if contradiction_pairs[key] then
      return failure(
        'review_incomplete',
        'a contradiction pair may be resolved once per review',
        { left.id, right.id },
        'Remove the duplicate resolution'
      )
    end
    local ok, code, id = validate_evidence_ids(workspace, resolution.evidence_ids)
    if not ok then
      return failure(
        code,
        'contradiction-resolution evidence is invalid',
        id and { id } or {},
        'Use active evidence IDs'
      )
    end
    for _, id in ipairs(resolution.evidence_ids) do
      required_evidence[id] = true
    end
    contradiction_pairs[key] = resolution
  end

  if not bounded_array(args.structural_tradeoffs, 0, Config.get().limits.max_array_items) then
    return failure('review_incomplete', 'structural_tradeoffs is invalid', {}, 'Correct the tradeoffs')
  end
  for index, tradeoff in ipairs(args.structural_tradeoffs) do
    if type(tradeoff) ~= 'table' or not text_valid(tradeoff.statement) or not text_valid(tradeoff.falsifier) then
      return failure('review_incomplete', 'structural tradeoff ' .. index .. ' is invalid', {}, 'Correct the tradeoff')
    end
    local ok, code, id = validate_evidence_ids(workspace, tradeoff.evidence_ids)
    if not ok then
      return failure(code, 'structural tradeoff evidence is invalid', id and { id } or {}, 'Use active evidence IDs')
    end
    for _, id in ipairs(tradeoff.evidence_ids) do
      required_evidence[id] = true
    end
  end
  for id, status in pairs(verdicts) do
    if status == 'retract' and required_evidence[id] then
      return failure(
        'review_incomplete',
        'a review cannot retract evidence required by its own analysis',
        { id },
        'Remove the evidence dependency or revise the verdict'
      )
    end
  end
  if #workspace.artifact_order >= Config.get().limits.max_artifacts then
    return failure('limit_exceeded', 'the review exceeds the artifact limit', {}, 'Replace the workspace')
  end

  local review_data = vim.deepcopy(args)
  review_data.frame_id = workspace.frame_id
  local review = assert(State.add(workspace, 'review', review_data))
  for _, id in ipairs(args.target_ids) do
    State.add_relation(review, 'depends_on', id)
  end
  if #args.stress_tests > 0 then
    for _, id in ipairs(args.target_ids) do
      State.add_relation(review, 'tests', id)
    end
  end
  for _, id in ipairs(args.defense.evidence_ids) do
    State.add_relation(review, 'supports', id)
  end
  for _, resolution in ipairs(args.contradiction_resolutions) do
    State.add_relation(review, 'qualifies', resolution.left_id)
    State.add_relation(review, 'qualifies', resolution.right_id)
    for _, id in ipairs(resolution.evidence_ids) do
      if not vim.tbl_contains(review.relations.supports, id) then
        State.add_relation(review, 'supports', id)
      end
    end
  end
  for _, verdict in ipairs(args.verdicts) do
    if verdict.status == 'retract' then
      State.retract(workspace, verdict.target_id)
      local target = targets[verdict.target_id]
      if target.kind == 'branch' then
        for _, option_id in ipairs(target.data.option_ids) do
          if State.find(workspace, option_id).status == 'active' then
            State.retract(workspace, option_id)
          end
        end
      end
    elseif verdict.status == 'revise' then
      workspace.open_revisions[verdict.target_id] = review.id
    end
  end
  for key in pairs(contradiction_pairs) do
    workspace.resolved_contradictions[key] = review.id
  end
  return success(workspace, review)
end

local gate_order = {
  'frame_missing',
  'evidence_missing',
  'perspective_coverage_missing',
  'unknown_coverage_missing',
  'branches_missing',
  'selected_option_missing',
  'selected_option_unsupported',
  'support_inactive',
  'review_missing',
  'temporal_review_missing',
  'full_review_missing',
  'revision_unresolved',
  'contradiction_unresolved',
  'criterion_coverage_incomplete',
  'criterion_not_verified',
  'criterion_support_missing',
}

local function active_artifacts(workspace, kind)
  local result = {}
  for _, id in ipairs(workspace.artifact_order) do
    local artifact = State.find(workspace, id)
    if artifact.status == 'active' and (not kind or artifact.kind == kind) then
      table.insert(result, artifact)
    end
  end
  return result
end

local function latest_active(workspace, kind, predicate)
  for index = #workspace.artifact_order, 1, -1 do
    local artifact = State.find(workspace, workspace.artifact_order[index])
    if artifact.status == 'active' and artifact.kind == kind and (not predicate or predicate(artifact)) then
      return artifact
    end
  end
end

local function contradiction_pairs(workspace)
  local pairs_by_key = {}
  for _, artifact in ipairs(active_artifacts(workspace)) do
    for _, other_id in ipairs(artifact.relations.contradicts) do
      local other = State.find(workspace, other_id)
      if other and other.status == 'active' then
        local key = contradiction_key(artifact.id, other_id)
        pairs_by_key[key] = { artifact.id, other_id }
      end
    end
  end
  return pairs_by_key
end

local function id_set(values)
  local result = {}
  for _, value in ipairs(values or {}) do
    result[value] = true
  end
  return result
end

local function synthesis_material(workspace, data)
  local result = {}
  for _, id in ipairs(data.selected_option_ids or {}) do
    result[id] = true
    local option = State.find(workspace, id)
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

local function review_support_active(workspace, review)
  for _, id in ipairs(review.relations.supports or {}) do
    local evidence = State.find(workspace, id)
    if not evidence or evidence.status ~= 'active' or evidence.kind ~= 'evidence' then
      return false
    end
  end
  return true
end

function M.final_gates(workspace, synthesis)
  local failed = {}
  local blocker_set = {}
  local function add(name, ids)
    failed[name] = true
    if type(ids) == 'string' then
      blocker_set[ids] = true
    else
      for _, id in ipairs(ids or {}) do
        blocker_set[id] = true
      end
    end
  end

  local frame = workspace and State.find(workspace, workspace.frame_id) or nil
  if not frame or frame.status ~= 'active' then
    add('frame_missing')
  else
    local evidence = active_artifacts(workspace, 'evidence')
    if #evidence == 0 then
      add('evidence_missing')
    end

    local selected_ids = synthesis and synthesis.selected_option_ids or {}
    local support_ids = synthesis and synthesis.support_ids or {}
    local review_ids = synthesis and synthesis.review_ids or {}
    local criterion_results = synthesis and synthesis.criterion_results or {}
    local relevant = id_set(selected_ids)
    local review_eligible = id_set(selected_ids)
    relevant[frame.id] = true
    for _, id in ipairs(support_ids) do
      relevant[id] = true
      review_eligible[id] = true
    end
    for _, result in ipairs(criterion_results) do
      for _, id in ipairs(result.evidence_ids or {}) do
        relevant[id] = true
        review_eligible[id] = true
      end
    end

    local branch = latest_active(workspace, 'branch', function(artifact)
      return artifact.data.frame_id == frame.id
    end)
    if frame.data.branching_required and not branch then
      local stale = latest_active(workspace, 'branch')
      add('branches_missing', stale and { stale.id } or {})
    end
    local branch_options = branch and id_set(branch.data.option_ids) or {}
    if branch and (frame.data.branching_required or #selected_ids > 0) then
      relevant[branch.id] = true
    end
    if frame.data.branching_required and #selected_ids == 0 then
      add('selected_option_missing')
    end
    for _, id in ipairs(selected_ids) do
      local option = State.find(workspace, id)
      if not option or option.status ~= 'active' or option.kind ~= 'option' or not branch_options[id] then
        add('selected_option_missing', { id })
      else
        local evidence_ids = option.data.evidence_ids or {}
        local supported = #evidence_ids > 0
        local option_blockers = { id }
        for _, evidence_id in ipairs(evidence_ids) do
          local artifact = State.find(workspace, evidence_id)
          supported = supported and artifact ~= nil and artifact.status == 'active' and artifact.kind == 'evidence'
          if not artifact or artifact.status ~= 'active' or artifact.kind ~= 'evidence' then
            table.insert(option_blockers, evidence_id)
          end
          relevant[evidence_id] = true
          review_eligible[evidence_id] = true
        end
        if not supported or #option.data.predictions == 0 then
          add('selected_option_unsupported', option_blockers)
        end
      end
    end
    for _, id in ipairs(support_ids) do
      local artifact = State.find(workspace, id)
      if not artifact or artifact.status ~= 'active' or artifact.kind ~= 'evidence' then
        add('support_inactive', { id })
      end
    end
    if not synthesis then
      if branch then
        for _, option_id in ipairs(branch.data.option_ids or {}) do
          local option = State.find(workspace, option_id)
          if option and option.status == 'active' then
            review_eligible[option_id] = true
            for _, evidence_id in ipairs(option.data.evidence_ids or {}) do
              local artifact = State.find(workspace, evidence_id)
              if artifact and artifact.status == 'active' and artifact.kind == 'evidence' then
                review_eligible[evidence_id] = true
              end
            end
          end
        end
      else
        for _, artifact in ipairs(evidence) do
          review_eligible[artifact.id] = true
        end
      end
    end

    if frame.data.depth == 'deep' then
      local covered = {}
      for _, artifact in ipairs(evidence) do
        if not synthesis or relevant[artifact.id] then
          covered[normalized(artifact.data.perspective)] = true
        end
      end
      if vim.tbl_count(covered) < 2 then
        add('perspective_coverage_missing')
      end
    end

    local unknowns = {}
    for _, unknown in ipairs(frame.data.unknowns) do
      unknowns[normalized(unknown)] = true
    end
    for _, artifact in ipairs(evidence) do
      if not synthesis or relevant[artifact.id] then
        for _, unknown in ipairs(artifact.data.addresses_unknowns or {}) do
          unknowns[normalized(unknown)] = nil
        end
      end
    end
    if next(unknowns) ~= nil then
      add('unknown_coverage_missing')
    end

    local pairs_by_key = contradiction_pairs(workspace)
    local relevant_contradiction = false
    for _, pair in pairs(pairs_by_key) do
      relevant_contradiction = relevant_contradiction or not synthesis or relevant[pair[1]] or relevant[pair[2]]
    end
    local reviews = {}
    local available_reviews = {}
    local function review_current_and_sound(review)
      return review.data.frame_id == frame.id and review_support_active(workspace, review)
    end
    for _, review in ipairs(active_artifacts(workspace, 'review')) do
      if review_current_and_sound(review) then
        table.insert(available_reviews, review)
      end
    end
    if synthesis then
      for _, id in ipairs(review_ids) do
        local review = State.find(workspace, id)
        if review and review.status == 'active' and review.kind == 'review' and review_current_and_sound(review) then
          table.insert(reviews, review)
        elseif review then
          blocker_set[review.id] = true
        end
      end
    else
      for _, review in ipairs(available_reviews) do
        table.insert(reviews, review)
      end
    end
    local reviews_by_id = {}
    for _, review in ipairs(reviews) do
      reviews_by_id[review.id] = review
    end
    local checkpoint = latest_active(workspace, 'synthesis', function(artifact)
      return artifact.data.frame_id == frame.id and artifact.data.mode == 'checkpoint'
    end)
    local checkpoint_covers = checkpoint ~= nil
    local checkpoint_material = checkpoint and synthesis_material(workspace, checkpoint.data) or {}
    for id in pairs(review_eligible) do
      if not checkpoint_material[id] then
        checkpoint_covers = false
      end
    end
    if checkpoint_covers then
      review_eligible[checkpoint.id] = true
    end
    local function review_relevant(review)
      for _, id in ipairs(review.data.target_ids or {}) do
        if review_eligible[id] then
          return true
        end
      end
      return false
    end
    local has_relevant_review = false
    for _, review in ipairs(reviews) do
      has_relevant_review = has_relevant_review or review_relevant(review)
    end
    if (branch or relevant_contradiction) and not has_relevant_review then
      add('review_missing')
      for _, review in ipairs(available_reviews) do
        if review_relevant(review) then
          blocker_set[review.id] = true
        end
      end
    end
    if frame.data.temporal_required then
      local stress_tested = false
      for _, review in ipairs(reviews) do
        stress_tested = stress_tested or (#(review.data.stress_tests or {}) > 0 and review_relevant(review))
      end
      if not stress_tested then
        add('temporal_review_missing')
        for _, review in ipairs(available_reviews) do
          if #(review.data.stress_tests or {}) > 0 and review_relevant(review) then
            blocker_set[review.id] = true
          end
        end
      end
    end

    if frame.data.depth == 'deep' then
      if checkpoint_covers then
        relevant[checkpoint.id] = true
      end
      local full_review = false
      for _, review in ipairs(reviews) do
        if review.data.mode == 'full' and review_relevant(review) then
          full_review = true
        end
      end
      if not full_review then
        add('full_review_missing')
        for _, review in ipairs(available_reviews) do
          if review.data.mode == 'full' and review_relevant(review) then
            blocker_set[review.id] = true
          end
        end
      end
    end

    for id in pairs(workspace.open_revisions) do
      if not synthesis or relevant[id] then
        add('revision_unresolved', { id })
      end
    end
    local function contradiction_resolution_valid(key)
      local review = reviews_by_id[workspace.resolved_contradictions[key]]
      if not review then
        return false
      end
      for _, resolution in ipairs(review.data.contradiction_resolutions or {}) do
        if contradiction_key(resolution.left_id, resolution.right_id) == key then
          local evidence_valid = #(resolution.evidence_ids or {}) > 0
          for _, id in ipairs(resolution.evidence_ids or {}) do
            local artifact = State.find(workspace, id)
            evidence_valid = evidence_valid
              and artifact ~= nil
              and artifact.status == 'active'
              and artifact.kind == 'evidence'
          end
          if evidence_valid then
            return true
          end
        end
      end
      return false
    end
    for key, pair in pairs(pairs_by_key) do
      if (not synthesis or relevant[pair[1]] or relevant[pair[2]]) and not contradiction_resolution_valid(key) then
        local ids = { pair[1], pair[2] }
        local review_id = workspace.resolved_contradictions[key]
        if review_id and not reviews_by_id[review_id] then
          table.insert(ids, review_id)
        end
        add('contradiction_unresolved', ids)
      end
    end

    local expected_criteria = {}
    for _, criterion in ipairs(frame.data.success_criteria) do
      expected_criteria[normalized(criterion)] = criterion
    end
    local observed_criteria = {}
    for _, result in ipairs(criterion_results) do
      local key = normalized(result.criterion)
      if not expected_criteria[key] or observed_criteria[key] then
        add('criterion_coverage_incomplete')
      end
      observed_criteria[key] = true
      if result.status == 'failed' or result.status == 'pending' then
        add('criterion_not_verified')
      elseif result.status == 'not_applicable' and not text_valid(result.explanation) then
        add('criterion_not_verified')
      elseif result.status == 'passed' then
        if #result.evidence_ids == 0 then
          add('criterion_support_missing')
        end
        for _, id in ipairs(result.evidence_ids) do
          local artifact = State.find(workspace, id)
          if not artifact or artifact.status ~= 'active' or artifact.kind ~= 'evidence' then
            add('criterion_support_missing', { id })
          end
        end
      end
    end
    for key in pairs(expected_criteria) do
      if not observed_criteria[key] then
        add('criterion_coverage_incomplete')
      end
    end
  end

  local ordered = {}
  for _, name in ipairs(gate_order) do
    if failed[name] then
      table.insert(ordered, name)
    end
  end
  local blocker_ids = {}
  for _, id in ipairs((workspace and workspace.artifact_order) or {}) do
    if blocker_set[id] then
      table.insert(blocker_ids, id)
    end
  end
  return ordered, blocker_ids
end

local function synthesis_references_valid(workspace, ids, kind)
  for _, id in ipairs(ids) do
    local artifact, code = active_reference(workspace, id)
    if code then
      return nil, code, id
    end
    if artifact.kind ~= kind then
      return nil, 'invalid_reference', id
    end
  end
  return true
end

local function unique_strings(values, normalize_values)
  local seen = {}
  for _, value in ipairs(values) do
    local key = normalize_values and normalized(value) or value
    if seen[key] then
      return false
    end
    seen[key] = true
  end
  return true
end

function M.synthesis(chat, args)
  local workspace = State.get(chat)
  if not workspace then
    return failure('workspace_missing', 'start a frame before synthesis', {}, 'Call reasoning_frame')
  end
  if
    type(args) ~= 'table'
    or not vim.tbl_contains({ 'checkpoint', 'final' }, args.mode)
    or not text_valid(args.conclusion)
    or not text_array_valid(args.selected_option_ids)
    or not text_array_valid(args.support_ids)
    or not text_array_valid(args.review_ids)
    or not unique_strings(args.selected_option_ids)
    or not unique_strings(args.support_ids)
    or not unique_strings(args.review_ids)
    or not bounded_array(args.criterion_results, 0, Config.get().limits.max_array_items)
    or not text_array_valid(args.tradeoffs)
    or not unique_strings(args.tradeoffs, true)
    or not text_array_valid(args.uncertainties)
    or not unique_strings(args.uncertainties, true)
    or not text_array_valid(args.blind_spots)
    or not unique_strings(args.blind_spots, true)
    or not text_array_valid(args.next_actions)
    or not unique_strings(args.next_actions, true)
    or not vim.tbl_contains({ 'low', 'medium', 'high' }, args.confidence)
  then
    return failure('synthesis_invalid', 'synthesis fields are invalid', {}, 'Correct reasoning_synthesis fields')
  end
  for index, result in ipairs(args.criterion_results) do
    if
      type(result) ~= 'table'
      or not text_valid(result.criterion)
      or not vim.tbl_contains({ 'passed', 'failed', 'pending', 'not_applicable' }, result.status)
      or not text_array_valid(result.evidence_ids)
      or not unique_strings(result.evidence_ids)
      or not text_valid(result.explanation)
    then
      return failure(
        'synthesis_invalid',
        'criterion result ' .. index .. ' is invalid',
        {},
        'Correct criterion_results'
      )
    end
  end
  for _, reference in ipairs({
    { args.selected_option_ids, 'option' },
    { args.support_ids, 'evidence' },
    { args.review_ids, 'review' },
  }) do
    local ok, code, id = synthesis_references_valid(workspace, reference[1], reference[2])
    if not ok then
      return failure(code, 'synthesis reference is unavailable', { id }, 'Use active typed artifact IDs')
    end
  end
  for _, result in ipairs(args.criterion_results) do
    local ok, code, id = synthesis_references_valid(workspace, result.evidence_ids, 'evidence')
    if not ok then
      return failure(code, 'criterion evidence is unavailable', { id }, 'Use active evidence IDs')
    end
  end

  local gates, blocker_ids = M.final_gates(workspace, args)
  if args.mode == 'final' and #gates > 0 then
    local rejected = failure(
      'synthesis_gate_failed',
      'final synthesis is blocked by: ' .. table.concat(gates, ', '),
      blocker_ids,
      Guidance.next(workspace, args)
    )
    rejected.data.unmet_gates = gates
    return rejected
  end
  if #workspace.artifact_order >= Config.get().limits.max_artifacts then
    return failure('limit_exceeded', 'the synthesis exceeds the artifact limit', {}, 'Replace the workspace')
  end

  local synthesis_data = vim.deepcopy(args)
  synthesis_data.frame_id = workspace.frame_id
  local synthesis_artifact = assert(State.add(workspace, 'synthesis', synthesis_data))
  State.add_relation(synthesis_artifact, 'depends_on', workspace.frame_id)
  local recorded_support = {}
  for _, id in ipairs(args.support_ids) do
    if not recorded_support[id] then
      State.add_relation(synthesis_artifact, 'supports', id)
      recorded_support[id] = true
    end
  end
  for _, result in ipairs(args.criterion_results) do
    for _, id in ipairs(result.evidence_ids) do
      if not recorded_support[id] then
        State.add_relation(synthesis_artifact, 'supports', id)
        recorded_support[id] = true
      end
    end
  end
  for _, id in ipairs(args.selected_option_ids) do
    State.add_relation(synthesis_artifact, 'depends_on', id)
  end
  for _, id in ipairs(args.review_ids) do
    State.add_relation(synthesis_artifact, 'depends_on', id)
  end
  local revised = {}
  for _, target_id in ipairs(workspace.artifact_order) do
    local target = State.find(workspace, target_id)
    if workspace.open_revisions[target_id] and target and target.status == 'active' and target.kind == 'synthesis' then
      table.insert(revised, target_id)
    end
  end
  for _, target_id in ipairs(revised) do
    State.supersede(workspace, target_id, synthesis_artifact.id)
  end
  return {
    status = 'success',
    data = {
      workspace_id = workspace.id,
      artifact = vim.deepcopy(synthesis_artifact),
      progress = vim.deepcopy(workspace.counts_by_kind),
      unmet_gates = args.mode == 'final' and {} or M.final_gates(workspace, args),
      next_action = Guidance.next(workspace, args),
    },
  }
end

M.failure = failure
M.success = success
M.text_valid = text_valid
M.bounded_array = bounded_array

local function accepted_final(workspace)
  if not workspace then
    return nil
  end
  local latest_id = workspace.artifact_order[#workspace.artifact_order]
  local latest = latest_id and State.find(workspace, latest_id) or nil
  if
    not latest
    or latest.status ~= 'active'
    or latest.kind ~= 'synthesis'
    or latest.data.mode ~= 'final'
    or latest.data.frame_id ~= workspace.frame_id
  then
    return nil
  end
  local gates = M.final_gates(workspace, latest.data)
  return #gates == 0 and latest or nil
end

function M.call(operation, chat, args)
  local tools_by_operation = {
    frame = 'reasoning_frame',
    evidence = 'reasoning_evidence',
    options = 'reasoning_options',
    review = 'reasoning_review',
    synthesis = 'reasoning_synthesis',
  }
  local explicit_reframe = operation == 'frame'
    and type(args) == 'table'
    and vim.tbl_contains({ 'revise', 'replace' }, args.action)
  if not explicit_reframe then
    local final = accepted_final(State.get(chat))
    if final then
      return failure(
        'workspace_finalized',
        'the accepted final synthesis is terminal until the frame is explicitly revised or replaced',
        { final.id },
        {
          tool = 'none',
          reason = 'Return the accepted conclusion; revise or replace the frame only for new user information',
        }
      )
    end
  end
  local handler = M[operation]
  if type(handler) ~= 'function' then
    log:error('[reasoning] unknown protocol operation: %s', tostring(operation))
    return failure('internal_error', 'the reasoning operation is unavailable', {}, {
      tool = tools_by_operation[operation] or 'reasoning_frame',
      reason = 'Retry with a registered reasoning tool',
    })
  end
  local ok, result = xpcall(function()
    return handler(chat, args)
  end, debug.traceback)
  if not ok then
    log:error('[reasoning] %s failed: %s', operation, result)
    return failure('internal_error', 'the reasoning operation failed internally', {}, {
      tool = tools_by_operation[operation],
      reason = 'Correct the call or report the plugin error',
    })
  end
  if explicit_reframe and result.status == 'success' then
    Terminal.clear(chat)
  end
  if result.status == 'error' and type(result.data.next_action) == 'string' then
    local tools_by_code = {
      workspace_missing = 'reasoning_frame',
      perspective_unknown = 'reasoning_frame',
      limit_exceeded = 'reasoning_frame',
    }
    result.data.next_action = {
      tool = tools_by_code[result.data.code] or tools_by_operation[operation] or 'reasoning_frame',
      reason = result.data.next_action,
    }
  end
  return result
end

return M
