local Config = require('codecompanion._extensions.reasoning.config')
local Constants = require('codecompanion._extensions.reasoning.constants')
local Guidance = require('codecompanion._extensions.reasoning.guidance')
local Render = require('codecompanion._extensions.reasoning.render')
local State = require('codecompanion._extensions.reasoning.state')
local Terminal = require('codecompanion._extensions.reasoning.terminal')
local Tree = require('codecompanion._extensions.reasoning.tree')
local Transition = require('codecompanion._extensions.reasoning.transition')
local Validation = require('codecompanion._extensions.reasoning.validation')
local log = require('codecompanion.utils.log')

local M = {}

local function failure(code, message, artifact_ids, next_action, diagnostic)
  local data = {
    code = code,
    message = message,
    artifact_ids = Validation.artifact_ids(artifact_ids),
    committed = false,
    next_action = next_action,
  }
  if diagnostic then
    data.diagnostic = diagnostic
  end
  return { status = 'error', data = data }
end

local function success_payload(workspace, artifact, unmet_gates, next_action)
  return {
    status = 'success',
    data = {
      workspace_id = workspace.id,
      artifact = vim.deepcopy(artifact),
      progress = vim.deepcopy(workspace.counts_by_kind),
      unmet_gates = unmet_gates or M.final_gates(workspace, nil),
      next_action = next_action or Guidance.next(workspace),
    },
  }
end

local function success(workspace, artifact)
  return success_payload(workspace, artifact)
end

local function text_valid(value)
  return type(value) == 'string'
    and vim.trim(value) ~= ''
    and vim.fn.strchars(value) <= Config.get().limits.max_text_chars
end

local function bounded_array(value, minimum, maximum)
  return type(value) == 'table' and #value >= minimum and #value <= maximum
end

local function normalized(value)
  return vim.trim(value):lower():gsub('%s+', ' ')
end

local function text_array_diagnostic(value, path, minimum, maximum, normalize_values)
  local diagnostic = Validation.array(value, path, minimum or 0, maximum or Config.get().limits.max_array_items)
  if diagnostic then
    return diagnostic
  end
  for index, item in ipairs(value) do
    diagnostic = Validation.text(item, ('%s[%d]'):format(path, index), Config.get().limits.max_text_chars)
    if diagnostic then
      return diagnostic
    end
  end
  if normalize_values == nil then
    return
  end
  return Validation.unique(value, path, normalize_values and normalized or nil)
end

local function optional_text_diagnostic(value, path)
  local diagnostic = Validation.required(value, path, 'string')
  if diagnostic then
    return diagnostic
  end
  local count = vim.fn.strchars(value)
  if count > Config.get().limits.max_text_chars then
    return Validation.diagnostic(path, 'max_chars', Config.get().limits.max_text_chars, count)
  end
end

local function any_reference_diagnostic(workspace, id, path)
  local artifact = type(id) == 'string' and workspace.artifacts_by_id[id] or nil
  return Validation.reference(workspace, id, path, artifact and artifact.kind or 'artifact')
end

local function normalized_set(values)
  local set = {}
  for _, value in ipairs(type(values) == 'table' and values or {}) do
    if type(value) == 'string' then
      set[normalized(value)] = true
    end
  end
  return set
end

local function amend_diagnostic_for(workspace, args)
  local frame = workspace and State.find(workspace, workspace.frame_id) or nil
  if not frame or frame.status ~= 'active' then
    return Validation.diagnostic('action', 'workspace_exists', true, false)
  end
  local data = frame.data
  if normalized(args.objective) ~= normalized(data.objective or '') then
    return Validation.diagnostic('objective', 'immutable_under_amend', 'unchanged', 'changed')
  end
  for _, field in ipairs({ 'problem_type', 'depth' }) do
    if args[field] ~= data[field] then
      return Validation.diagnostic(field, 'immutable_under_amend', 'unchanged', 'changed')
    end
  end
  for _, field in ipairs({ 'constraints', 'success_criteria', 'unknowns' }) do
    local proposed = normalized_set(args[field])
    for value in pairs(normalized_set(data[field])) do
      if not proposed[value] then
        return Validation.diagnostic(field, 'append_only', 'superset', 'removed_item')
      end
    end
  end
  local proposed_perspectives = {}
  for _, perspective in ipairs(args.perspectives) do
    proposed_perspectives[normalized(perspective.name)] = true
  end
  for _, perspective in ipairs(data.perspectives or {}) do
    if not proposed_perspectives[normalized(perspective.name)] then
      return Validation.diagnostic('perspectives', 'append_only', 'superset', 'removed_item')
    end
  end
  for _, field in ipairs({ 'temporal_required', 'branching_required' }) do
    if data[field] == true and args[field] ~= true then
      return Validation.diagnostic(field, 'append_only', true, false)
    end
  end
end

local function seed_unknowns(workspace, frame, existing_unknowns)
  local seeded = {}
  local known = normalized_set(existing_unknowns)
  for _, unknown in ipairs(frame.data.unknowns or {}) do
    if not known[normalized(unknown)] then
      local artifact = State.add(workspace, 'question', {
        parent_id = frame.id,
        text = unknown,
        kind = 'unknown',
        acceptance_test = '',
        resolution_kind = 'none',
        provisional = true,
        frame_id = frame.id,
      })
      if not artifact then
        return nil
      end
      State.add_relation(workspace, artifact, 'depends_on', frame.id)
      table.insert(seeded, artifact)
    end
  end
  if #seeded == 0 then
    return seeded
  end
  local record = Tree.root_split(workspace)
  local key = frame.id
  for _, frame_id in ipairs(workspace.frame_lineage or {}) do
    if workspace.splits[frame_id] then
      key = frame_id
    end
  end
  local child_ids = record and vim.deepcopy(record.child_ids) or {}
  for _, artifact in ipairs(seeded) do
    table.insert(child_ids, artifact.id)
  end
  State.set_split(workspace, key, {
    axis = record and record.axis or 'none',
    composition = record and record.composition or 'all_of',
    residual = record and record.residual or '',
    residual_disposition = record and record.residual_disposition or 'none',
    residual_covered_by = record and record.residual_covered_by or '',
    seeded = true,
    child_ids = child_ids,
  })
  return seeded
end

function M.frame(chat, args)
  if type(args) ~= 'table' then
    return failure(
      'frame_incomplete',
      'objective must be non-empty and bounded',
      {},
      'Call reasoning_frame',
      Validation.required(nil, 'action', 'string')
    )
  end
  local diagnostic = Validation.required(args.action, 'action', 'string')
    or Validation.enum(args.action, 'action', { start = true, revise = true, replace = true, amend = true })
  if diagnostic then
    return failure(
      'frame_incomplete',
      'objective must be non-empty and bounded',
      {},
      'Call reasoning_frame',
      diagnostic
    )
  end
  diagnostic = Validation.text(args.objective, 'objective', Config.get().limits.max_text_chars)
  if diagnostic then
    return failure(
      'frame_incomplete',
      'objective must be non-empty and bounded',
      {},
      'Call reasoning_frame',
      diagnostic
    )
  end
  diagnostic = Validation.required(args.problem_type, 'problem_type', 'string')
    or Validation.enum(args.problem_type, 'problem_type', {
      analysis = true,
      decision = true,
      diagnosis = true,
      design = true,
      planning = true,
    })
  if diagnostic then
    return failure(
      'frame_incomplete',
      'problem_type is invalid',
      {},
      'Call reasoning_frame with a valid problem_type',
      diagnostic
    )
  end
  diagnostic = Validation.required(args.depth, 'depth', 'string')
    or Validation.enum(args.depth, 'depth', { standard = true, deep = true })
  if diagnostic then
    return failure(
      'frame_incomplete',
      'depth must be standard or deep',
      {},
      'Call reasoning_frame with a valid depth',
      diagnostic
    )
  end
  diagnostic = text_array_diagnostic(args.constraints, 'constraints')
  if diagnostic then
    return failure(
      'frame_incomplete',
      'objective must be non-empty and bounded',
      {},
      'Call reasoning_frame',
      diagnostic
    )
  end
  diagnostic = text_array_diagnostic(args.success_criteria, 'success_criteria', 1, nil, true)
  if diagnostic then
    return failure(
      'frame_incomplete',
      'success criteria and unknowns must be unique',
      {},
      'Remove duplicate frame entries',
      diagnostic
    )
  end
  diagnostic = text_array_diagnostic(args.unknowns, 'unknowns', 0, nil, true)
  if diagnostic then
    return failure(
      'frame_incomplete',
      'success criteria and unknowns must be unique',
      {},
      'Remove duplicate frame entries',
      diagnostic
    )
  end
  diagnostic = Validation.required(args.perspectives, 'perspectives', 'array')
  if diagnostic then
    return failure(
      'frame_incomplete',
      'perspectives must be an array',
      {},
      string.format('Provide perspectives and retry with action=%s', args.action),
      diagnostic
    )
  end
  local minimum_perspectives = args.depth == 'deep' and 2 or 1
  local maximum_perspectives = Config.get().limits.max_array_items
  if maximum_perspectives < minimum_perspectives then
    return failure(
      'limit_exceeded',
      string.format(
        'max_array_items=%d cannot satisfy the %s perspective minimum=%d',
        maximum_perspectives,
        args.depth,
        minimum_perspectives
      ),
      {},
      string.format('Use standard depth or configure max_array_items to at least %d', minimum_perspectives),
      Validation.diagnostic('perspectives', 'configured_capacity', minimum_perspectives, maximum_perspectives)
    )
  end
  local perspective_count = #args.perspectives
  if perspective_count < minimum_perspectives then
    local perspective_noun = minimum_perspectives == 1 and 'perspective' or 'perspectives'
    local addition = minimum_perspectives == 1 and 'a perspective' or 'perspectives'
    return failure(
      'frame_incomplete',
      string.format(
        '%s frames require at least %d %s; received %d',
        args.depth,
        minimum_perspectives,
        perspective_noun,
        perspective_count
      ),
      {},
      string.format('Add %s and retry with action=%s', addition, args.action),
      Validation.diagnostic('perspectives', 'min_items', minimum_perspectives, perspective_count)
    )
  end
  if perspective_count > maximum_perspectives then
    return failure(
      'frame_incomplete',
      string.format('perspectives exceed max_array_items=%d; received %d', maximum_perspectives, perspective_count),
      {},
      string.format('Reduce perspectives to %d or fewer and retry with action=%s', maximum_perspectives, args.action),
      Validation.diagnostic('perspectives', 'max_items', maximum_perspectives, perspective_count)
    )
  end
  local perspective_names = {}
  for index, perspective in ipairs(args.perspectives) do
    local path = ('perspectives[%d]'):format(index)
    diagnostic = Validation.required(perspective, path, 'object')
    if diagnostic then
      return failure(
        'frame_incomplete',
        'every perspective needs a bounded name and purpose',
        {},
        'Correct the perspectives',
        diagnostic
      )
    end
    diagnostic = Validation.text(perspective.name, path .. '.name', Config.get().limits.max_text_chars)
      or Validation.text(perspective.purpose, path .. '.purpose', Config.get().limits.max_text_chars)
    if diagnostic then
      return failure(
        'frame_incomplete',
        'every perspective needs a bounded name and purpose',
        {},
        'Correct the perspectives',
        diagnostic
      )
    end
    local name = normalized(perspective.name)
    if perspective_names[name] then
      return failure(
        'frame_incomplete',
        'perspective names must be unique',
        {},
        'Rename the duplicate perspective',
        Validation.diagnostic(path .. '.name', 'unique_items', true, 'duplicate_value')
      )
    end
    perspective_names[name] = true
  end
  diagnostic = Validation.required(args.temporal_required, 'temporal_required', 'boolean')
  if diagnostic then
    return failure(
      'frame_incomplete',
      'objective must be non-empty and bounded',
      {},
      'Call reasoning_frame',
      diagnostic
    )
  end
  diagnostic = Validation.required(args.branching_required, 'branching_required', 'boolean')
  if diagnostic then
    return failure(
      'frame_incomplete',
      'objective must be non-empty and bounded',
      {},
      'Call reasoning_frame',
      diagnostic
    )
  end
  diagnostic = Validation.text(args.branching_rationale, 'branching_rationale', Config.get().limits.max_text_chars)
  if diagnostic then
    return failure(
      'frame_incomplete',
      'objective must be non-empty and bounded',
      {},
      'Call reasoning_frame',
      diagnostic
    )
  end

  local requires_branching = vim.tbl_contains({ 'decision', 'diagnosis', 'design', 'planning' }, args.problem_type)
  if requires_branching and not args.branching_required then
    return failure(
      'branching_required',
      'this problem type requires competing branches',
      {},
      'Set branching_required to true',
      Validation.diagnostic('branching_required', 'problem_type_requires_branching', true, false)
    )
  end
  local existing = State.get(chat)
  if args.action == 'start' and existing then
    return failure(
      'workspace_exists',
      'an active workspace already exists',
      { existing.frame_id },
      'Use revise or replace',
      Validation.diagnostic('action', 'workspace_state', { 'revise', 'replace' }, 'start')
    )
  end
  if (args.action == 'revise' or args.action == 'amend') and not existing then
    return failure(
      'workspace_missing',
      ('there is no frame to %s'):format(args.action),
      {},
      'Start a frame',
      Validation.diagnostic('action', 'workspace_exists', true, false)
    )
  end
  if args.action == 'amend' then
    local amend_diagnostic = amend_diagnostic_for(existing, args)
    if amend_diagnostic then
      return failure(
        'amend_invalid',
        'amend may only add to the active frame',
        {},
        { tool = 'reasoning_frame', reason = 'Add to the frame with amend, or revise it to change its identity' },
        amend_diagnostic
      )
    end
  end
  if args.action == 'replace' and not existing then
    return failure(
      'transition_invalid',
      'replace requires an existing reasoning workspace',
      {},
      { tool = 'reasoning_frame', reason = 'Start the workspace with action=start' },
      {
        path = 'action',
        constraint = 'authoritative_transition',
        expected = 'start',
        actual = 'replace',
      }
    )
  end
  local downstream = {}
  if args.action == 'revise' then
    for _, id in ipairs(existing.artifact_order) do
      local artifact = State.find(existing, id)
      if artifact and artifact.status == 'active' and artifact.kind ~= 'frame' then
        table.insert(downstream, id)
      end
    end
  end
  local previous_frame = existing and State.find(existing, existing.frame_id) or nil
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
    return failure(
      'limit_exceeded',
      'the workspace artifact limit was reached',
      {},
      'Replace the workspace',
      Validation.diagnostic(
        'workspace.artifacts',
        'max_items',
        Config.get().limits.max_artifacts,
        #workspace.artifact_order
      )
    )
  end
  if workspace.frame_id then
    State.supersede(workspace, workspace.frame_id, frame.id)
  end
  State.set_frame(workspace, frame.id)
  if args.action == 'amend' then
    State.extend_lineage(workspace, frame.id)
  else
    State.reset_lineage(workspace, frame.id)
  end
  for _, id in ipairs(downstream) do
    State.retire(workspace, id)
  end
  local previous_unknowns = args.action == 'amend' and previous_frame and previous_frame.data.unknowns or {}
  local seeded = seed_unknowns(workspace, frame, previous_unknowns)
  if not seeded then
    return failure(
      'limit_exceeded',
      'the workspace artifact limit was reached while seeding framed unknowns',
      {},
      { tool = 'reasoning_frame', reason = 'Replace the workspace' },
      Validation.diagnostic(
        'workspace.artifacts',
        'max_items',
        Config.get().limits.max_artifacts,
        #workspace.artifact_order
      )
    )
  end
  local result = success(workspace, frame)
  if #seeded > 0 then
    result.data.artifacts = vim.deepcopy(seeded)
  end
  return result
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
  if type(args) ~= 'table' then
    return failure(
      'evidence_invalid',
      'items must be a non-empty bounded batch',
      {},
      'Call reasoning_evidence',
      Validation.required(nil, 'items', 'array')
    )
  end
  local diagnostic = Validation.array(args.items, 'items', 1, Config.get().limits.max_batch_items)
  if diagnostic then
    return failure(
      'evidence_invalid',
      'items must be a non-empty bounded batch',
      {},
      'Call reasoning_evidence',
      diagnostic
    )
  end

  local frame = State.find(workspace, workspace.frame_id)
  local perspectives = {}
  local perspective_values = {}
  for _, perspective in ipairs(frame.data.perspectives) do
    local name = normalized(perspective.name)
    perspectives[name] = true
    table.insert(perspective_values, name)
  end
  table.sort(perspective_values)
  local frame_unknowns = {}
  local frame_unknown_values = {}
  for _, unknown in ipairs(frame.data.unknowns) do
    local name = normalized(unknown)
    frame_unknowns[name] = true
    table.insert(frame_unknown_values, unknown)
  end
  table.sort(frame_unknown_values)

  local known_statements = {}
  local current_frame_seen = false
  for _, id in ipairs(workspace.artifact_order) do
    local artifact = State.find(workspace, id)
    if id == workspace.frame_id then
      current_frame_seen = true
    end
    if artifact.kind == 'evidence' and (artifact.status == 'active' or current_frame_seen) then
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
    local path = ('items[%d]'):format(index)
    diagnostic = Validation.required(item, path, 'object')
    if diagnostic then
      return failure(
        'evidence_invalid',
        'evidence item ' .. index .. ' is invalid',
        {},
        'Correct reasoning_evidence fields',
        diagnostic
      )
    end
    diagnostic = Validation.required(item.kind, path .. '.kind', 'string')
      or Validation.enum(item.kind, path .. '.kind', { observation = true, claim = true, assumption = true })
      or Validation.text(item.statement, path .. '.statement', Config.get().limits.max_text_chars)
      or Validation.text(item.source, path .. '.source', Config.get().limits.max_text_chars)
      or Validation.required(item.confidence, path .. '.confidence', 'string')
      or Validation.enum(item.confidence, path .. '.confidence', { low = true, medium = true, high = true })
      or Validation.text(item.falsifier, path .. '.falsifier', Config.get().limits.max_text_chars)
      or Validation.text(item.perspective, path .. '.perspective', Config.get().limits.max_text_chars)
      or text_array_diagnostic(item.addresses_unknowns, path .. '.addresses_unknowns')
      or text_array_diagnostic(item.supports, path .. '.supports')
      or text_array_diagnostic(item.contradicts, path .. '.contradicts')
      or text_array_diagnostic(item.qualifies, path .. '.qualifies')
      or optional_text_diagnostic(item.supersedes_id, path .. '.supersedes_id')
    if diagnostic then
      return failure(
        'evidence_invalid',
        'evidence item ' .. index .. ' is invalid',
        {},
        'Correct reasoning_evidence fields',
        diagnostic
      )
    end
  end
  for index, item in ipairs(args.items) do
    local path = ('items[%d]'):format(index)
    local source = normalized(item.source)
    if item.kind == 'assumption' and not source:match('^assumption:') then
      return failure(
        'evidence_invalid',
        'assumption sources must begin with assumption:',
        {},
        'Label the assumption source',
        Validation.diagnostic(path .. '.source', 'assumption_prefix', 'assumption:', 'invalid_source')
      )
    end
    if item.kind == 'observation' and vim.tbl_contains({ 'unknown', 'unspecified', 'none' }, source) then
      return failure(
        'evidence_invalid',
        'observations require a concrete source',
        {},
        'Provide the observation source',
        Validation.diagnostic(path .. '.source', 'concrete_source', true, 'placeholder_source')
      )
    end
    if not perspectives[normalized(item.perspective)] then
      return failure(
        'perspective_unknown',
        'evidence references an unknown perspective',
        {},
        'Revise the frame or perspective',
        Validation.diagnostic(path .. '.perspective', 'active_frame_perspective', perspective_values, 'unknown_value')
      )
    end
    local addressed = {}
    for unknown_index, unknown in ipairs(item.addresses_unknowns) do
      local key = normalized(unknown)
      if addressed[key] or not frame_unknowns[key] then
        return failure(
          'evidence_invalid',
          'addresses_unknowns must uniquely match active frame unknowns',
          {},
          'Use exact unknowns from reasoning_frame',
          Validation.diagnostic(
            ('%s.addresses_unknowns[%d]'):format(path, unknown_index),
            addressed[key] and 'unique_items' or 'active_frame_unknown',
            addressed[key] and true or frame_unknown_values,
            addressed[key] and 'duplicate_value' or 'unknown_value'
          )
        )
      end
      addressed[key] = true
    end
    local key = normalized(item.statement)
    local duplicate_id = known_statements[key]
    if pending_statements[key] then
      return failure(
        'duplicate_artifact',
        'the evidence batch contains duplicate normalized statements',
        duplicate_id and { duplicate_id } or {},
        'Keep one statement or submit separate revisions',
        Validation.diagnostic(path .. '.statement', 'unique_items', true, 'duplicate_value')
      )
    end
    if duplicate_id and item.supersedes_id ~= duplicate_id then
      return failure(
        'duplicate_artifact',
        'an evidence artifact already has the same statement',
        { duplicate_id },
        'Supersede the active evidence or use a distinct statement',
        Validation.diagnostic(path .. '.statement', 'unique_items', true, 'duplicate_value')
      )
    end
    pending_statements[key] = true
    table.insert(prepared, vim.deepcopy(item))
  end

  for index, item in ipairs(prepared) do
    local path = ('items[%d]'):format(index)
    for _, field in ipairs({ 'supports', 'contradicts', 'qualifies' }) do
      local seen = {}
      for reference_index, id in ipairs(item[field]) do
        local reference_path = ('%s.%s[%d]'):format(path, field, reference_index)
        if seen[id] then
          return failure(
            'evidence_invalid',
            field .. ' contains a duplicate ID',
            { id },
            'Remove the duplicate reference',
            Validation.diagnostic(reference_path, 'unique_items', true, Validation.artifact_ids({ id })[1])
          )
        end
        seen[id] = true
        local _, code = active_reference(workspace, id)
        if code == 'invalid_reference' and pending_ids[id] and pending_ids[id] < index then
          code = nil
        end
        if code then
          return failure(
            code,
            'evidence relation target is unavailable',
            { id },
            'Use an active artifact ID',
            any_reference_diagnostic(workspace, id, reference_path)
          )
        end
      end
    end
    if item.supersedes_id ~= '' then
      local target, code = active_reference(workspace, item.supersedes_id)
      if code then
        return failure(
          code,
          'superseded evidence is unavailable',
          { item.supersedes_id },
          'Use an active evidence ID',
          Validation.reference(workspace, item.supersedes_id, path .. '.supersedes_id', 'evidence')
        )
      end
      if target.kind ~= 'evidence' then
        return failure(
          'invalid_reference',
          'supersedes_id must name evidence',
          { item.supersedes_id },
          'Use reasoning_evidence',
          Validation.reference(workspace, item.supersedes_id, path .. '.supersedes_id', 'evidence')
        )
      end
      if pending_supersessions[item.supersedes_id] then
        return failure(
          'duplicate_artifact',
          'one evidence artifact cannot have two replacements in the same batch',
          { item.supersedes_id },
          'Submit one replacement for the evidence ID',
          Validation.diagnostic(
            path .. '.supersedes_id',
            'unique_supersession_target',
            true,
            Validation.artifact_ids({ item.supersedes_id })[1]
          )
        )
      end
      pending_supersessions[item.supersedes_id] = true
    end
  end

  for item_index, item in ipairs(prepared) do
    for _, field in ipairs({ 'supports', 'contradicts', 'qualifies' }) do
      for reference_index, id in ipairs(item[field]) do
        if pending_supersessions[id] then
          return failure(
            'inactive_reference',
            'evidence relation target is superseded by the same batch',
            { id },
            'Reference the replacement evidence artifact',
            Validation.diagnostic(
              ('items[%d].%s[%d]'):format(item_index, field, reference_index),
              'batch_reference_status',
              'survives_batch',
              Validation.artifact_ids({ id })[1]
            )
          )
        end
      end
    end
  end

  local seeded_by_text = {}
  for _, node in ipairs(Tree.preorder(workspace)) do
    if node.data.kind == 'unknown' and node.data.provisional then
      seeded_by_text[normalized(node.data.text)] = node.id
    end
  end
  for index, item in ipairs(prepared) do
    local path = ('items[%d]'):format(index)
    local addressed_questions = {}
    local ordered_questions = {}
    for reference_index, id in ipairs(item.addresses_questions or {}) do
      local reference_path = ('%s.addresses_questions[%d]'):format(path, reference_index)
      local artifact = State.find(workspace, id)
      if
        not artifact
        or artifact.status ~= 'active'
        or artifact.kind ~= 'question'
        or not State.in_lineage(workspace, artifact.data.frame_id)
      then
        return failure(
          'invalid_reference',
          'addresses_questions must name active sub-questions',
          { id },
          'Use active sub-question IDs',
          Validation.reference(workspace, id, reference_path, 'question')
        )
      end
      if addressed_questions[id] then
        return failure(
          'evidence_invalid',
          'addresses_questions contains a duplicate ID',
          { id },
          'Remove the duplicate reference',
          Validation.diagnostic(reference_path, 'unique_items', true, Validation.artifact_ids({ id })[1])
        )
      end
      addressed_questions[id] = true
      table.insert(ordered_questions, id)
    end
    for _, unknown in ipairs(item.addresses_unknowns or {}) do
      local seeded_id = seeded_by_text[normalized(unknown)]
      if seeded_id and not addressed_questions[seeded_id] then
        addressed_questions[seeded_id] = true
        table.insert(ordered_questions, seeded_id)
      end
    end
    item.addresses_questions = ordered_questions
  end

  if #workspace.artifact_order + #prepared > Config.get().limits.max_artifacts then
    return failure(
      'limit_exceeded',
      'the complete evidence batch exceeds the artifact limit',
      {},
      'Replace the workspace or reduce the batch',
      Validation.diagnostic(
        'items',
        'workspace_capacity',
        Config.get().limits.max_artifacts - #workspace.artifact_order,
        #prepared
      )
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
        State.add_relation(workspace, artifact, field, id)
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
  if type(args) ~= 'table' then
    return failure(
      'options_invalid',
      'branch-set fields are invalid',
      {},
      'Correct reasoning_options fields',
      Validation.required(nil, 'question', 'string')
    )
  end
  local diagnostic = Validation.text(args.question, 'question', Config.get().limits.max_text_chars)
  if diagnostic then
    return failure(
      'options_invalid',
      'branch-set fields are invalid',
      {},
      'Correct reasoning_options fields',
      diagnostic
    )
  end
  diagnostic = Validation.required(args.branch_type, 'branch_type', 'string')
    or Validation.enum(args.branch_type, 'branch_type', { solution = true, hypothesis = true, scenario = true })
  if diagnostic then
    return failure(
      'options_invalid',
      'branch-set fields are invalid',
      {},
      'Correct reasoning_options fields',
      diagnostic
    )
  end
  diagnostic =
    text_array_diagnostic(args.criteria, 'criteria', 1, math.min(8, Config.get().limits.max_array_items), true)
  if diagnostic then
    return failure(
      'options_invalid',
      'criteria must contain bounded text',
      {},
      'Correct reasoning_options criteria',
      diagnostic
    )
  end
  diagnostic = optional_text_diagnostic(args.supersedes_branch_id, 'supersedes_branch_id')
  if diagnostic then
    return failure(
      'options_invalid',
      'branch-set fields are invalid',
      {},
      'Correct reasoning_options fields',
      diagnostic
    )
  end
  diagnostic = Validation.array(args.options, 'options', 2, math.min(6, Config.get().limits.max_array_items))
  if diagnostic then
    return failure(
      'branch_count_insufficient',
      'a branch set requires two to six options',
      {},
      'Provide competing options',
      diagnostic
    )
  end

  local labels = {}
  local prepared = {}
  for index, option in ipairs(args.options) do
    local path = ('options[%d]'):format(index)
    diagnostic = Validation.required(option, path, 'object')
    if diagnostic then
      return failure(
        'options_invalid',
        'option ' .. index .. ' is invalid',
        {},
        'Correct the option fields',
        diagnostic
      )
    end
    diagnostic = Validation.text(option.label, path .. '.label', Config.get().limits.max_text_chars)
      or Validation.text(option.summary, path .. '.summary', Config.get().limits.max_text_chars)
      or text_array_diagnostic(option.evidence_ids, path .. '.evidence_ids', 1, nil, false)
      or text_array_diagnostic(option.assumptions, path .. '.assumptions')
      or text_array_diagnostic(option.predictions, path .. '.predictions', 1)
      or text_array_diagnostic(option.benefits, path .. '.benefits')
      or text_array_diagnostic(option.costs, path .. '.costs')
      or text_array_diagnostic(option.risks, path .. '.risks')
      or Validation.required(option.reversibility, path .. '.reversibility', 'string')
      or Validation.enum(option.reversibility, path .. '.reversibility', { easy = true, moderate = true, hard = true })
    if diagnostic then
      return failure(
        'options_invalid',
        'option ' .. index .. ' is invalid',
        {},
        'Correct the option fields',
        diagnostic
      )
    end
    local label = normalized(option.label)
    if labels[label] then
      return failure(
        'options_invalid',
        'option labels must be unique',
        {},
        'Rename the duplicate option',
        Validation.diagnostic(path .. '.label', 'unique_items', true, 'duplicate_value')
      )
    end
    labels[label] = true
    table.insert(prepared, vim.deepcopy(option))
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
      'Set supersedes_branch_id to the active branch ID',
      Validation.diagnostic('supersedes_branch_id', 'active_branch_supersession', active_branch.id, 'missing')
    )
  end
  if active_branch and args.supersedes_branch_id ~= active_branch.id then
    return failure(
      'options_invalid',
      'supersedes_branch_id must name the current active branch set',
      { active_branch.id },
      'Set supersedes_branch_id to the active branch ID',
      Validation.diagnostic(
        'supersedes_branch_id',
        'active_branch_supersession',
        active_branch.id,
        Validation.artifact_ids({ args.supersedes_branch_id })[1]
      )
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
        'Use an active branch ID',
        Validation.reference(workspace, args.supersedes_branch_id, 'supersedes_branch_id', 'branch')
      )
    end
    if replaced.kind ~= 'branch' then
      return failure(
        'invalid_reference',
        'supersedes_branch_id must name a branch set',
        { replaced.id },
        'Use an active B artifact',
        Validation.reference(workspace, args.supersedes_branch_id, 'supersedes_branch_id', 'branch')
      )
    end
  end

  for index, option in ipairs(args.options) do
    for reference_index, id in ipairs(option.evidence_ids) do
      local path = ('options[%d].evidence_ids[%d]'):format(index, reference_index)
      local target, code = active_reference(workspace, id)
      if code then
        return failure(
          code,
          'option evidence is unavailable',
          { id },
          'Use active evidence IDs',
          Validation.reference(workspace, id, path, 'evidence')
        )
      end
      if target.kind ~= 'evidence' then
        return failure(
          'invalid_reference',
          'option evidence_ids must name evidence',
          { id },
          'Use E artifact IDs',
          Validation.reference(workspace, id, path, 'evidence')
        )
      end
    end
  end

  if #workspace.artifact_order + 1 + #prepared > Config.get().limits.max_artifacts then
    return failure(
      'limit_exceeded',
      'the branch set exceeds the artifact limit',
      {},
      'Replace the workspace or reduce branches',
      Validation.diagnostic(
        'options',
        'workspace_capacity',
        Config.get().limits.max_artifacts - #workspace.artifact_order - 1,
        #prepared
      )
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
  State.add_relation(workspace, branch, 'depends_on', workspace.frame_id)
  local options = {}
  for _, option in ipairs(prepared) do
    local artifact = assert(State.add(workspace, 'option', option))
    State.append_data(workspace, branch, 'option_ids', artifact.id)
    State.add_relation(workspace, artifact, 'depends_on', branch.id)
    for _, id in ipairs(option.evidence_ids) do
      State.add_relation(workspace, artifact, 'supports', id)
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

local function validate_evidence_ids(workspace, ids, path)
  local seen = {}
  for index, id in ipairs(ids) do
    local item_path = ('%s[%d]'):format(path, index)
    if seen[id] then
      return nil,
        'review_incomplete',
        id,
        Validation.diagnostic(item_path, 'unique_items', true, Validation.artifact_ids({ id })[1])
    end
    seen[id] = true
    local target, code = active_reference(workspace, id)
    if code then
      return nil, code, id, Validation.reference(workspace, id, item_path, 'evidence')
    end
    if target.kind ~= 'evidence' then
      return nil, 'invalid_reference', id, Validation.reference(workspace, id, item_path, 'evidence')
    end
  end
  return true
end

local function review_shape_diagnostic(args)
  if type(args) ~= 'table' then
    return Validation.required(nil, 'mode', 'string')
  end
  local diagnostic = Validation.required(args.mode, 'mode', 'string')
    or Validation.enum(args.mode, 'mode', {
      falsification = true,
      assumptions = true,
      temporal = true,
      cross_perspective = true,
      full = true,
    })
    or text_array_diagnostic(args.target_ids, 'target_ids', 1, nil, false)
  if diagnostic then
    return diagnostic
  end
  diagnostic = Validation.required(args.defense, 'defense', 'object')
  if diagnostic then
    return diagnostic
  end
  diagnostic = Validation.text(args.defense.summary, 'defense.summary', Config.get().limits.max_text_chars)
    or text_array_diagnostic(args.defense.evidence_ids, 'defense.evidence_ids', 0, nil, false)
    or Validation.array(args.challenges, 'challenges', 1, Config.get().limits.max_array_items)
  if diagnostic then
    return diagnostic
  end
  local challenge_kinds = {
    counterexample = true,
    missing_evidence = true,
    hidden_assumption = true,
    temporal_failure = true,
    overclaim = true,
    underclaim = true,
  }
  for index, challenge in ipairs(args.challenges) do
    local path = ('challenges[%d]'):format(index)
    diagnostic = Validation.required(challenge, path, 'object')
    if diagnostic then
      return diagnostic
    end
    diagnostic = Validation.required(challenge.kind, path .. '.kind', 'string')
      or Validation.enum(challenge.kind, path .. '.kind', challenge_kinds)
      or Validation.text(challenge.summary, path .. '.summary', Config.get().limits.max_text_chars)
      or text_array_diagnostic(challenge.target_ids, path .. '.target_ids', 1, nil, false)
      or Validation.text(challenge.falsifier, path .. '.falsifier', Config.get().limits.max_text_chars)
    if diagnostic then
      return diagnostic
    end
  end
  diagnostic = text_array_diagnostic(
    args.blind_spots,
    'blind_spots',
    args.mode == 'full' and 1 or 0,
    Config.get().limits.max_array_items
  ) or Validation.array(args.stress_tests, 'stress_tests', 0, Config.get().limits.max_array_items)
  if diagnostic then
    return diagnostic
  end
  for index, test in ipairs(args.stress_tests) do
    local path = ('stress_tests[%d]'):format(index)
    diagnostic = Validation.required(test, path, 'object')
    if diagnostic then
      return diagnostic
    end
    diagnostic = Validation.text(test.scenario, path .. '.scenario', Config.get().limits.max_text_chars)
      or Validation.text(test.prediction, path .. '.prediction', Config.get().limits.max_text_chars)
      or Validation.text(test.failure_signal, path .. '.failure_signal', Config.get().limits.max_text_chars)
    if diagnostic then
      return diagnostic
    end
  end
  diagnostic = Validation.array(args.verdicts, 'verdicts', #args.target_ids, #args.target_ids)
  if diagnostic then
    return diagnostic
  end
  for index, verdict in ipairs(args.verdicts) do
    local path = ('verdicts[%d]'):format(index)
    diagnostic = Validation.required(verdict, path, 'object')
    if diagnostic then
      return diagnostic
    end
    diagnostic = Validation.text(verdict.target_id, path .. '.target_id', Config.get().limits.max_text_chars)
      or Validation.required(verdict.status, path .. '.status', 'string')
      or Validation.enum(verdict.status, path .. '.status', { keep = true, revise = true, retract = true })
      or optional_text_diagnostic(verdict.revision_instruction, path .. '.revision_instruction')
    if diagnostic then
      return diagnostic
    end
  end
  diagnostic = Validation.array(
    args.contradiction_resolutions,
    'contradiction_resolutions',
    0,
    Config.get().limits.max_array_items
  )
  if diagnostic then
    return diagnostic
  end
  for index, resolution in ipairs(args.contradiction_resolutions) do
    local path = ('contradiction_resolutions[%d]'):format(index)
    diagnostic = Validation.required(resolution, path, 'object')
    if diagnostic then
      return diagnostic
    end
    diagnostic = Validation.text(resolution.left_id, path .. '.left_id', Config.get().limits.max_text_chars)
      or Validation.text(resolution.right_id, path .. '.right_id', Config.get().limits.max_text_chars)
      or Validation.text(resolution.resolution, path .. '.resolution', Config.get().limits.max_text_chars)
      or text_array_diagnostic(resolution.evidence_ids, path .. '.evidence_ids', 1, nil, false)
    if diagnostic then
      return diagnostic
    end
  end
  diagnostic =
    Validation.array(args.structural_tradeoffs, 'structural_tradeoffs', 0, Config.get().limits.max_array_items)
  if diagnostic then
    return diagnostic
  end
  for index, tradeoff in ipairs(args.structural_tradeoffs) do
    local path = ('structural_tradeoffs[%d]'):format(index)
    diagnostic = Validation.required(tradeoff, path, 'object')
    if diagnostic then
      return diagnostic
    end
    diagnostic = Validation.text(tradeoff.statement, path .. '.statement', Config.get().limits.max_text_chars)
      or text_array_diagnostic(tradeoff.evidence_ids, path .. '.evidence_ids', 0, nil, false)
      or Validation.text(tradeoff.falsifier, path .. '.falsifier', Config.get().limits.max_text_chars)
    if diagnostic then
      return diagnostic
    end
  end
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
  local diagnostic = review_shape_diagnostic(args)
  if diagnostic then
    return failure(
      'review_incomplete',
      'mode and target_ids are required',
      {},
      'Correct reasoning_review fields',
      diagnostic
    )
  end

  local targets = {}
  for index, id in ipairs(args.target_ids) do
    local path = ('target_ids[%d]'):format(index)
    if targets[id] then
      return failure(
        'review_incomplete',
        'target_ids must be unique',
        { id },
        'Remove the duplicate target',
        Validation.diagnostic(path, 'unique_items', true, Validation.artifact_ids({ id })[1])
      )
    end
    local target, code = active_reference(workspace, id)
    if code then
      return failure(
        code,
        'review target is unavailable',
        { id },
        'Use an active artifact ID',
        any_reference_diagnostic(workspace, id, path)
      )
    end
    if target.kind == 'review' then
      return failure(
        'invalid_reference',
        'reviews cannot revise another review artifact',
        { id },
        'Target a frame, evidence, branch, option, or synthesis',
        Validation.diagnostic(path, 'artifact_kind', 'non_review', Validation.artifact_ids({ id })[1])
      )
    end
    targets[id] = target
  end

  local evidence_ok, evidence_code, evidence_id, evidence_diagnostic =
    validate_evidence_ids(workspace, args.defense.evidence_ids, 'defense.evidence_ids')
  if not evidence_ok then
    return failure(
      evidence_code,
      'defense evidence is invalid',
      evidence_id and { evidence_id } or {},
      'Use active evidence IDs',
      evidence_diagnostic
    )
  end
  if args.mode == 'full' and #args.defense.evidence_ids == 0 then
    return failure(
      'review_incomplete',
      'full review requires defense evidence',
      {},
      'Add evidence to the defense',
      Validation.diagnostic('defense.evidence_ids', 'min_items', 1, 0)
    )
  end
  local required_evidence = {}
  for _, id in ipairs(args.defense.evidence_ids) do
    required_evidence[id] = true
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
    local challenge_targets = {}
    for target_index, id in ipairs(challenge.target_ids) do
      local path = ('challenges[%d].target_ids[%d]'):format(index, target_index)
      if challenge_targets[id] then
        return failure(
          'review_incomplete',
          'challenge target_ids must be unique',
          { id },
          'Remove the duplicate challenge target',
          Validation.diagnostic(path, 'unique_items', true, Validation.artifact_ids({ id })[1])
        )
      end
      challenge_targets[id] = true
      if not targets[id] then
        return failure(
          'invalid_reference',
          'challenge targets must be in target_ids',
          { id },
          'Add the target to target_ids',
          Validation.diagnostic(path, 'review_target_membership', true, Validation.artifact_ids({ id })[1])
        )
      end
      challenged_targets[id] = true
    end
    has_disconfirmation = has_disconfirmation
      or vim.tbl_contains({ 'counterexample', 'missing_evidence', 'temporal_failure', 'overclaim' }, challenge.kind)
    has_hidden_assumption = has_hidden_assumption or challenge.kind == 'hidden_assumption'
  end
  for index, id in ipairs(args.target_ids) do
    if not challenged_targets[id] then
      return failure(
        'review_incomplete',
        'every review target must receive an adversarial challenge',
        { id },
        'Add a challenge for the uncovered target',
        Validation.diagnostic(
          ('target_ids[%d]'):format(index),
          'challenge_coverage',
          true,
          Validation.artifact_ids({ id })[1]
        )
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
      'Add both challenge types',
      Validation.diagnostic(
        'challenges',
        'required_challenge_kinds',
        { 'counterexample', 'hidden_assumption' },
        'missing_kind'
      )
    )
  end
  if args.mode == 'falsification' and not has_disconfirmation then
    return failure(
      'review_incomplete',
      'falsification review requires a disconfirming challenge',
      {},
      'Add a falsifiable attack',
      Validation.diagnostic('challenges', 'disconfirming_challenge', true, false)
    )
  end
  if args.mode == 'assumptions' and not has_hidden_assumption then
    return failure(
      'review_incomplete',
      'assumptions review requires a hidden-assumption challenge',
      {},
      'Expose a hidden assumption',
      Validation.diagnostic('challenges', 'hidden_assumption_challenge', true, false)
    )
  end
  if args.mode == 'cross_perspective' and #args.target_ids < 2 then
    return failure(
      'review_incomplete',
      'cross-perspective review requires at least two targets',
      args.target_ids,
      'Add another perspective target',
      Validation.diagnostic('target_ids', 'min_items', 2, #args.target_ids)
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
        'Target artifacts grounded in at least two perspectives',
        Validation.diagnostic('target_ids', 'evidence_perspective_count', 2, count)
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
    return failure(
      'review_incomplete',
      'temporal reasoning requires a stress test',
      {},
      'Add a temporal stress test',
      Validation.diagnostic('stress_tests', 'min_items', 1, 0)
    )
  end

  local verdicts = {}
  for index, verdict in ipairs(args.verdicts) do
    local path = ('verdicts[%d]'):format(index)
    if not targets[verdict.target_id] then
      return failure(
        'review_incomplete',
        'verdicts must uniquely cover every target',
        { verdict.target_id },
        'Correct the verdicts',
        Validation.diagnostic(
          path .. '.target_id',
          'review_target_membership',
          true,
          Validation.artifact_ids({ verdict.target_id })[1]
        )
      )
    end
    if verdicts[verdict.target_id] then
      return failure(
        'review_incomplete',
        'verdicts must uniquely cover every target',
        { verdict.target_id },
        'Correct the verdicts',
        Validation.diagnostic(
          path .. '.target_id',
          'unique_items',
          true,
          Validation.artifact_ids({ verdict.target_id })[1]
        )
      )
    end
    if verdict.status == 'revise' then
      diagnostic = Validation.text(
        verdict.revision_instruction,
        path .. '.revision_instruction',
        Config.get().limits.max_text_chars
      )
      if diagnostic then
        return failure(
          'review_incomplete',
          'verdicts must uniquely cover every target',
          { verdict.target_id },
          'Correct the verdicts',
          diagnostic
        )
      end
    elseif verdict.revision_instruction ~= '' then
      return failure(
        'review_incomplete',
        'verdicts must uniquely cover every target',
        { verdict.target_id },
        'Correct the verdicts',
        Validation.diagnostic(path .. '.revision_instruction', 'allowed_when_status', 'revise', verdict.status)
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
        },
        Validation.diagnostic(
          ('verdicts[%d].status'):format(index),
          'frame_status_transition',
          { 'keep', 'revise' },
          'retract'
        )
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
        },
        Validation.diagnostic(
          ('verdicts[%d].status'):format(index),
          'option_status_transition',
          { 'keep', 'revise' },
          'retract'
        )
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
        },
        Validation.diagnostic(
          ('verdicts[%d].target_id'):format(index),
          'open_revision',
          false,
          Validation.artifact_ids({ verdict.target_id })[1]
        )
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
            },
            Validation.diagnostic('verdicts', 'coherent_branch_verdict', true, 'mixed_branch_and_option')
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
        'Correct the contradiction resolution',
        Validation.diagnostic(
          ('contradiction_resolutions[%d].right_id'):format(index),
          'distinct_from_left_id',
          true,
          'duplicate_value'
        )
      )
    end
    local left, right = targets[resolution.left_id], targets[resolution.right_id]
    if not left or not right then
      return failure(
        'invalid_reference',
        'contradiction endpoints must both be reviewed',
        { resolution.left_id, resolution.right_id },
        'Target both contradictory artifacts',
        Validation.diagnostic(
          ('contradiction_resolutions[%d]'):format(index),
          'review_target_membership',
          true,
          'unreviewed_endpoint'
        )
      )
    end
    if verdicts[left.id] ~= 'keep' or verdicts[right.id] ~= 'keep' then
      return failure(
        'review_incomplete',
        'resolved contradiction endpoints require keep verdicts',
        { left.id, right.id },
        'Keep both qualified endpoints or omit the resolution',
        Validation.diagnostic(('contradiction_resolutions[%d]'):format(index), 'endpoint_verdicts', 'keep', 'non_keep')
      )
    end
    local actual = vim.tbl_contains(left.relations.contradicts, right.id)
      or vim.tbl_contains(right.relations.contradicts, left.id)
    if not actual then
      return failure(
        'review_incomplete',
        'the resolution does not name an active contradiction',
        { left.id, right.id },
        'Resolve an actual contradiction pair',
        Validation.diagnostic(('contradiction_resolutions[%d]'):format(index), 'active_contradiction', true, false)
      )
    end
    local key = contradiction_key(left.id, right.id)
    if contradiction_pairs[key] then
      return failure(
        'review_incomplete',
        'a contradiction pair may be resolved once per review',
        { left.id, right.id },
        'Remove the duplicate resolution',
        Validation.diagnostic(('contradiction_resolutions[%d]'):format(index), 'unique_items', true, 'duplicate_pair')
      )
    end
    local ok, code, id, reference_diagnostic = validate_evidence_ids(
      workspace,
      resolution.evidence_ids,
      ('contradiction_resolutions[%d].evidence_ids'):format(index)
    )
    if not ok then
      return failure(
        code,
        'contradiction-resolution evidence is invalid',
        id and { id } or {},
        'Use active evidence IDs',
        reference_diagnostic
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
    local ok, code, id, reference_diagnostic =
      validate_evidence_ids(workspace, tradeoff.evidence_ids, ('structural_tradeoffs[%d].evidence_ids'):format(index))
    if not ok then
      return failure(
        code,
        'structural tradeoff evidence is invalid',
        id and { id } or {},
        'Use active evidence IDs',
        reference_diagnostic
      )
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
        'Remove the evidence dependency or revise the verdict',
        Validation.diagnostic('verdicts', 'required_evidence_status', 'keep', Validation.artifact_ids({ id })[1])
      )
    end
  end
  if #workspace.artifact_order >= Config.get().limits.max_artifacts then
    return failure(
      'limit_exceeded',
      'the review exceeds the artifact limit',
      {},
      'Replace the workspace',
      Validation.diagnostic(
        'workspace.artifacts',
        'max_items',
        Config.get().limits.max_artifacts,
        #workspace.artifact_order
      )
    )
  end

  local review_data = vim.deepcopy(args)
  review_data.frame_id = workspace.frame_id
  local review = assert(State.add(workspace, 'review', review_data))
  for _, id in ipairs(args.target_ids) do
    State.add_relation(workspace, review, 'depends_on', id)
  end
  if #args.stress_tests > 0 then
    for _, id in ipairs(args.target_ids) do
      State.add_relation(workspace, review, 'tests', id)
    end
  end
  for _, id in ipairs(args.defense.evidence_ids) do
    State.add_relation(workspace, review, 'supports', id)
  end
  for _, resolution in ipairs(args.contradiction_resolutions) do
    State.add_relation(workspace, review, 'qualifies', resolution.left_id)
    State.add_relation(workspace, review, 'qualifies', resolution.right_id)
    for _, id in ipairs(resolution.evidence_ids) do
      if not vim.tbl_contains(review.relations.supports, id) then
        State.add_relation(workspace, review, 'supports', id)
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
      State.open_revision(workspace, verdict.target_id, review.id)
    end
  end
  for key in pairs(contradiction_pairs) do
    State.resolve_contradiction(workspace, key, review.id)
  end
  return success(workspace, review)
end

local function question_next_action()
  return { tool = 'reasoning_question', reason = 'Correct the sub-question and retry' }
end

local function question_failure(code, message, artifact_ids, diagnostic)
  return failure(code, message, artifact_ids, question_next_action(), diagnostic)
end

local function conjunctive(value)
  local padded = ' ' .. normalized(value) .. ' '
  if padded:find(' and ', 1, true) or padded:find(' also ', 1, true) or value:find(';', 1, true) then
    return true
  end
  local _, marks = value:gsub('%?', '')
  return marks > 1
end

local function tree_options()
  local options = Config.get()
  return {
    require_observation = options.require_observation_for_closure,
    judgment_requires_review = options.judgment_requires_review,
  }
end

local function active_question(workspace, id)
  local artifact = State.find(workspace, id)
  if not artifact or artifact.status ~= 'active' or artifact.kind ~= 'question' then
    return nil
  end
  return artifact
end

local function split_diagnostic(workspace, args, parent, limits, strict_atomicity)
  local texts, tests = {}, {}
  local parent_text = parent and parent.kind == 'question' and normalized(parent.data.text) or nil
  local diagnostic = Validation.array(args.child_questions, 'child_questions', 2, limits.max_children)
  if diagnostic then
    return 'question_invalid', diagnostic
  end
  for index, child in ipairs(args.child_questions) do
    local path = ('child_questions[%d]'):format(index)
    diagnostic = Validation.required(child, path, 'object')
      or Validation.text(child.text, path .. '.text', limits.max_text_chars)
      or Validation.enum(child.kind, path .. '.kind', {
        unknown = true,
        sub_problem = true,
        option_test = true,
        assumption_check = true,
      })
      or Validation.text(child.acceptance_test, path .. '.acceptance_test', limits.max_text_chars)
      or Validation.enum(child.resolution_kind, path .. '.resolution_kind', {
        observation = true,
        computation = true,
        judgment = true,
      })
    if diagnostic then
      return 'question_invalid', diagnostic
    end
    local text = normalized(child.text)
    if parent_text and text == parent_text then
      return 'question_invalid',
        Validation.diagnostic(path .. '.text', 'distinct_from_parent', 'different_value', 'duplicate_value')
    end
    if texts[text] then
      return 'question_invalid', Validation.diagnostic(path .. '.text', 'unique_items', true, 'duplicate_value')
    end
    texts[text] = true
    local test = normalized(child.acceptance_test)
    if tests[test] then
      return 'question_invalid',
        Validation.diagnostic(path .. '.acceptance_test', 'unique_items', true, 'duplicate_value')
    end
    tests[test] = true
    if strict_atomicity and conjunctive(child.acceptance_test) then
      return 'question_not_atomic',
        Validation.diagnostic(path .. '.acceptance_test', 'single_observable', 1, 'multiple_observables')
    end
  end
end

local function split(chat, workspace, args)
  local options = Config.get()
  local limits = options.limits
  local parent_is_frame = State.in_lineage(workspace, args.parent_id)
  local parent = parent_is_frame and State.find(workspace, args.parent_id) or active_question(workspace, args.parent_id)
  if not parent or parent.status ~= 'active' then
    return question_failure(
      'invalid_reference',
      'the split parent must be the active frame or an active sub-question',
      { args.parent_id },
      Validation.reference(workspace, args.parent_id, 'parent_id', parent_is_frame and 'frame' or 'question')
    )
  end
  if Tree.split(workspace, parent.id) or #Tree.children(workspace, parent.id) > 0 then
    return question_failure(
      'split_exists',
      'this parent is already split',
      { parent.id },
      Validation.diagnostic('parent_id', 'workspace_state', 'unsplit', 'already_split')
    )
  end
  if parent_is_frame and Tree.root_split(workspace) then
    return question_failure(
      'split_exists',
      'the root split already exists for this frame lineage',
      {},
      Validation.diagnostic('parent_id', 'workspace_state', 'unsplit', 'already_split')
    )
  end
  if not parent_is_frame then
    local closure = Tree.closure(workspace, parent.id)
    if closure and Tree.closure_valid(workspace, closure, tree_options()) then
      return question_failure(
        'question_closed',
        'a closed sub-question cannot be split',
        { parent.id, closure.id },
        Validation.diagnostic('parent_id', 'workspace_state', 'open', 'closed')
      )
    end
  end

  local diagnostic
  local code
  code, diagnostic = split_diagnostic(workspace, args, parent, limits, options.strict_atomicity)
  if diagnostic then
    return question_failure(code, 'the sub-question split is invalid', {}, diagnostic)
  end

  local child_depth = parent_is_frame and 1 or Tree.depth(workspace, parent) + 1
  if child_depth > limits.max_tree_depth then
    return question_failure(
      'tree_depth_exceeded',
      'the split exceeds the configured tree depth',
      { parent.id },
      Validation.diagnostic('child_questions', 'max_depth', limits.max_tree_depth, child_depth)
    )
  end
  local existing_questions = #Tree.preorder(workspace)
  if existing_questions + #args.child_questions > limits.max_questions then
    return question_failure(
      'limit_exceeded',
      'the split exceeds the configured sub-question limit',
      {},
      Validation.diagnostic(
        'child_questions',
        'max_items',
        limits.max_questions,
        existing_questions + #args.child_questions
      )
    )
  end

  diagnostic = Validation.enum(args.axis, 'axis', {
    component = true,
    phase = true,
    failure_mode = true,
    actor = true,
    constraint = true,
    data_flow = true,
  }) or Validation.enum(args.composition, 'composition', { all_of = true, one_of = true, ordered = true })
  if diagnostic then
    return question_failure('question_invalid', 'the split axis and composition are invalid', {}, diagnostic)
  end
  if args.composition == 'one_of' and not parent_is_frame and parent.data.kind == 'unknown' then
    return question_failure(
      'question_invalid',
      'an unknown resolves through every child, not one of them',
      { parent.id },
      Validation.diagnostic('composition', 'composition_kind', { 'all_of', 'ordered' }, 'one_of')
    )
  end

  local residual = type(args.residual) == 'string' and vim.trim(args.residual) or ''
  if residual == '' then
    if args.residual_disposition ~= 'none' then
      return question_failure(
        'residual_unresolved',
        'an empty residual needs no disposition',
        {},
        Validation.diagnostic('residual_disposition', 'residual_disposition', 'none', 'unknown_enum')
      )
    end
  else
    if args.residual_disposition == 'covered_elsewhere' then
      if not active_question(workspace, args.residual_covered_by) then
        return question_failure(
          'residual_unresolved',
          'the residual must name an active sub-question that covers it',
          { args.residual_covered_by },
          Validation.reference(workspace, args.residual_covered_by, 'residual_covered_by', 'question')
        )
      end
    elseif args.residual_disposition == 'out_of_scope' then
      local frame = State.find(workspace, workspace.frame_id)
      local constraints = normalized_set(frame and frame.data.constraints or {})
      if not constraints[normalized(residual)] then
        return question_failure(
          'residual_unresolved',
          'an out-of-scope residual must quote an active frame constraint',
          {},
          Validation.diagnostic('residual', 'frame_constraint', 'active_constraint', 'unknown_value')
        )
      end
    else
      return question_failure(
        'residual_unresolved',
        'a non-empty residual must be covered elsewhere or declared out of scope',
        {},
        Validation.diagnostic(
          'residual_disposition',
          'residual_disposition',
          { 'covered_elsewhere', 'out_of_scope' },
          'none'
        )
      )
    end
  end

  local children = {}
  for _, child in ipairs(args.child_questions) do
    local artifact = State.add(workspace, 'question', {
      parent_id = parent.id,
      text = child.text,
      kind = child.kind,
      acceptance_test = child.acceptance_test,
      resolution_kind = child.resolution_kind,
      provisional = false,
      frame_id = workspace.frame_id,
    })
    if not artifact then
      return question_failure(
        'limit_exceeded',
        'the workspace artifact limit was reached',
        {},
        Validation.diagnostic('workspace.artifacts', 'max_items', limits.max_artifacts, #workspace.artifact_order)
      )
    end
    State.add_relation(workspace, artifact, 'depends_on', parent.id)
    table.insert(children, artifact)
  end
  local child_ids = {}
  for _, artifact in ipairs(children) do
    table.insert(child_ids, artifact.id)
  end
  State.set_split(workspace, parent.id, {
    axis = args.axis,
    composition = args.composition,
    residual = residual,
    residual_disposition = args.residual_disposition,
    residual_covered_by = args.residual_disposition == 'covered_elsewhere' and args.residual_covered_by or '',
    child_ids = child_ids,
  })

  local result = success(workspace, children[#children])
  result.data.artifacts = vim.deepcopy(children)
  return result
end

local function closure(chat, workspace, args)
  local options = Config.get()
  local limits = options.limits
  local question = active_question(workspace, args.question_id)
  if not question or not State.in_lineage(workspace, question.data.frame_id) then
    return question_failure(
      'invalid_reference',
      'the closed sub-question must be active in the current frame lineage',
      { args.question_id },
      Validation.reference(workspace, args.question_id, 'question_id', 'question')
    )
  end
  if #Tree.children(workspace, question.id) > 0 then
    return question_failure(
      'question_not_leaf',
      'only a leaf sub-question can be closed',
      { question.id },
      Validation.diagnostic('question_id', 'workspace_state', 'leaf', 'parent')
    )
  end
  local existing = Tree.closure(workspace, question.id)
  if existing and Tree.closure_valid(workspace, existing, tree_options()) then
    return question_failure(
      'question_closed',
      'this sub-question is already closed',
      { question.id, existing.id },
      Validation.diagnostic('question_id', 'workspace_state', 'open', 'closed')
    )
  end

  local diagnostic = Validation.required(args.evidence_ids, 'evidence_ids', 'array')
  if diagnostic then
    return question_failure('question_invalid', 'evidence_ids must be an array', {}, diagnostic)
  end
  local evidence = {}
  for index, id in ipairs(args.evidence_ids) do
    local path = ('evidence_ids[%d]'):format(index)
    local artifact = State.find(workspace, id)
    if not artifact or artifact.status ~= 'active' or artifact.kind ~= 'evidence' then
      return question_failure(
        'invalid_reference',
        'closure evidence must be active evidence',
        { id },
        Validation.reference(workspace, id, path, 'evidence')
      )
    end
    table.insert(evidence, artifact)
  end

  if args.action == 'answer' then
    diagnostic = Validation.text(args.answer, 'answer', limits.max_text_chars)
    if diagnostic then
      return question_failure('closure_invalid', 'an answer must state what the evidence establishes', {}, diagnostic)
    end
    if #evidence == 0 then
      return question_failure(
        'closure_invalid',
        'an answer must cite at least one active evidence item',
        {},
        Validation.diagnostic('evidence_ids', 'min_items', 1, 0)
      )
    end
  else
    diagnostic = Validation.text(args.justification, 'justification', limits.max_text_chars)
      or Validation.enum(args.drop_reason, 'drop_reason', {
        out_of_scope = true,
        answered_elsewhere = true,
        not_material = true,
      })
    if diagnostic then
      return question_failure('closure_invalid', 'a drop must be justified and classified', {}, diagnostic)
    end
    if args.drop_reason == 'out_of_scope' then
      local frame = State.find(workspace, workspace.frame_id)
      local constraints = normalized_set(frame and frame.data.constraints or {})
      if not constraints[normalized(args.justification)] then
        return question_failure(
          'closure_invalid',
          'an out-of-scope drop must quote an active frame constraint',
          {},
          Validation.diagnostic('justification', 'frame_constraint', 'active_constraint', 'unknown_value')
        )
      end
    elseif #evidence == 0 then
      return question_failure(
        'closure_invalid',
        'this drop reason must cite active evidence',
        {},
        Validation.diagnostic('evidence_ids', 'min_items', 1, 0)
      )
    end
  end

  local resolution = args.resolution_kind
  if resolution == 'none' or resolution == nil then
    resolution = question.data.resolution_kind
  end
  if question.data.provisional then
    diagnostic = Validation.text(args.acceptance_test, 'acceptance_test', limits.max_text_chars)
      or Validation.enum(resolution or 'none', 'resolution_kind', {
        observation = true,
        computation = true,
        judgment = true,
      })
    if diagnostic then
      return question_failure(
        'closure_invalid',
        'a seeded sub-question needs its acceptance test before it closes',
        { question.id },
        diagnostic
      )
    end
  end

  local acceptance_test = type(args.acceptance_test) == 'string' and vim.trim(args.acceptance_test) or ''
  if acceptance_test == '' then
    acceptance_test = question.data.acceptance_test or ''
  end
  local candidate = {
    id = 'candidate',
    kind = 'closure',
    status = 'active',
    data = {
      question_id = question.id,
      action = args.action,
      answer = args.action == 'answer' and args.answer or '',
      justification = args.action == 'drop' and args.justification or '',
      drop_reason = args.action == 'drop' and args.drop_reason or 'none',
      acceptance_test = acceptance_test,
      resolution_kind = resolution or 'none',
      confidence = args.confidence ~= 'none' and args.confidence or 'medium',
      frame_id = workspace.frame_id,
    },
    relations = { supports = vim.deepcopy(args.evidence_ids) },
  }
  if not Tree.closure_valid(workspace, candidate, tree_options()) then
    local code = candidate.data.resolution_kind == 'judgment' and 'closure_unreviewed' or 'closure_unsupported'
    local constraint = code == 'closure_unreviewed' and 'reviewed_judgment' or 'observation_backed'
    return question_failure(
      code,
      'the closure does not meet the configured evidence bar',
      vim.deepcopy(args.evidence_ids),
      Validation.diagnostic('evidence_ids', constraint, true, false)
    )
  end

  local artifact = State.add(workspace, 'closure', candidate.data)
  if not artifact then
    return question_failure(
      'limit_exceeded',
      'the workspace artifact limit was reached',
      {},
      Validation.diagnostic('workspace.artifacts', 'max_items', limits.max_artifacts, #workspace.artifact_order)
    )
  end
  State.add_relation(workspace, artifact, 'depends_on', question.id)
  for _, item in ipairs(evidence) do
    State.add_relation(workspace, artifact, 'supports', item.id)
  end
  return success(workspace, artifact)
end

function M.question(chat, args)
  local workspace = State.get(chat)
  if not workspace then
    return failure(
      'workspace_missing',
      'start a frame before decomposing the problem',
      {},
      { tool = 'reasoning_frame', reason = 'Create the active problem frame' },
      Validation.diagnostic('action', 'workspace_exists', true, false)
    )
  end
  if type(args) ~= 'table' then
    return question_failure(
      'question_invalid',
      'the sub-question call is malformed',
      {},
      Validation.required(nil, 'action', 'string')
    )
  end
  local diagnostic = Validation.required(args.action, 'action', 'string')
    or Validation.enum(args.action, 'action', { split = true, answer = true, drop = true })
  if diagnostic then
    return question_failure('question_invalid', 'the sub-question action is invalid', {}, diagnostic)
  end
  if args.action == 'split' then
    return split(chat, workspace, args)
  end
  return closure(chat, workspace, args)
end

local gate_order = {
  'frame_missing',
  'evidence_missing',
  'perspective_coverage_missing',
  'unknown_coverage_missing',
  'decomposition_missing',
  'open_questions',
  'closure_unsupported',
  'residual_unresolved',
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
      return State.in_lineage(workspace, artifact.data.frame_id)
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

    local closure_options = tree_options()
    if (frame.data.depth == 'deep' or #(frame.data.unknowns or {}) > 0) and not Tree.root_split(workspace) then
      add('decomposition_missing')
    end
    for _, leaf in ipairs(Tree.open_leaves(workspace, closure_options)) do
      add('open_questions', { leaf.id })
    end
    for _, id in ipairs(Tree.unsupported_closures(workspace, closure_options)) do
      add('closure_unsupported', { id })
    end
    for parent_id, record in pairs(workspace.splits or {}) do
      if record.residual_disposition == 'covered_elsewhere' then
        local target = State.find(workspace, record.residual_covered_by)
        if not target or target.status ~= 'active' or target.kind ~= 'question' then
          add('residual_unresolved', { parent_id, record.residual_covered_by })
        end
      end
    end

    local pairs_by_key = contradiction_pairs(workspace)
    local relevant_contradiction = false
    for _, pair in pairs(pairs_by_key) do
      relevant_contradiction = relevant_contradiction or not synthesis or relevant[pair[1]] or relevant[pair[2]]
    end
    local reviews = {}
    local available_reviews = {}
    local function review_current_and_sound(review)
      return State.in_lineage(workspace, review.data.frame_id) and review_support_active(workspace, review)
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
      return State.in_lineage(workspace, artifact.data.frame_id) and artifact.data.mode == 'checkpoint'
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

local function synthesis_references_valid(workspace, ids, kind, path)
  for index, id in ipairs(ids) do
    local artifact, code = active_reference(workspace, id)
    local item_path = ('%s[%d]'):format(path, index)
    if code then
      return nil, code, id, Validation.reference(workspace, id, item_path, kind)
    end
    if artifact.kind ~= kind then
      return nil, 'invalid_reference', id, Validation.reference(workspace, id, item_path, kind)
    end
  end
  return true
end

local function synthesis_shape_diagnostic(args)
  if type(args) ~= 'table' then
    return Validation.required(nil, 'mode', 'string')
  end
  local diagnostic = Validation.required(args.mode, 'mode', 'string')
    or Validation.enum(args.mode, 'mode', { checkpoint = true, final = true })
    or Validation.text(args.conclusion, 'conclusion', Config.get().limits.max_text_chars)
    or text_array_diagnostic(args.selected_option_ids, 'selected_option_ids', 0, nil, false)
    or text_array_diagnostic(args.support_ids, 'support_ids', 0, nil, false)
    or text_array_diagnostic(args.review_ids, 'review_ids', 0, nil, false)
    or Validation.array(args.criterion_results, 'criterion_results', 0, Config.get().limits.max_array_items)
  if diagnostic then
    return diagnostic
  end
  for index, result in ipairs(args.criterion_results) do
    local path = ('criterion_results[%d]'):format(index)
    diagnostic = Validation.required(result, path, 'object')
    if diagnostic then
      return diagnostic
    end
    diagnostic = Validation.text(result.criterion, path .. '.criterion', Config.get().limits.max_text_chars)
      or Validation.required(result.status, path .. '.status', 'string')
      or Validation.enum(result.status, path .. '.status', {
        passed = true,
        failed = true,
        pending = true,
        not_applicable = true,
      })
      or text_array_diagnostic(result.evidence_ids, path .. '.evidence_ids', 0, nil, false)
      or Validation.text(result.explanation, path .. '.explanation', Config.get().limits.max_text_chars)
    if diagnostic then
      return diagnostic
    end
  end
  return text_array_diagnostic(args.tradeoffs, 'tradeoffs', 0, nil, true)
    or text_array_diagnostic(args.uncertainties, 'uncertainties', 0, nil, true)
    or text_array_diagnostic(args.blind_spots, 'blind_spots', 0, nil, true)
    or text_array_diagnostic(args.next_actions, 'next_actions', 0, nil, true)
    or Validation.required(args.confidence, 'confidence', 'string')
    or Validation.enum(args.confidence, 'confidence', { low = true, medium = true, high = true })
end

function M.synthesis(chat, args, lifecycle_phase)
  local workspace = State.get(chat)
  if not workspace then
    return failure('workspace_missing', 'start a frame before synthesis', {}, 'Call reasoning_frame')
  end
  local diagnostic = synthesis_shape_diagnostic(args)
  if diagnostic then
    return failure(
      'synthesis_invalid',
      'synthesis fields are invalid',
      {},
      'Correct reasoning_synthesis fields',
      diagnostic
    )
  end
  for _, reference in ipairs({
    { args.selected_option_ids, 'option', 'selected_option_ids' },
    { args.support_ids, 'evidence', 'support_ids' },
    { args.review_ids, 'review', 'review_ids' },
  }) do
    local ok, code, id, reference_diagnostic =
      synthesis_references_valid(workspace, reference[1], reference[2], reference[3])
    if not ok then
      return failure(
        code,
        'synthesis reference is unavailable',
        { id },
        'Use active typed artifact IDs',
        reference_diagnostic
      )
    end
  end
  for index, result in ipairs(args.criterion_results) do
    local ok, code, id, reference_diagnostic = synthesis_references_valid(
      workspace,
      result.evidence_ids,
      'evidence',
      ('criterion_results[%d].evidence_ids'):format(index)
    )
    if not ok then
      return failure(code, 'criterion evidence is unavailable', { id }, 'Use active evidence IDs', reference_diagnostic)
    end
  end

  local gates, blocker_ids = M.final_gates(workspace, args)
  if args.mode == 'final' and #gates > 0 then
    local rejected = failure(
      'synthesis_gate_failed',
      'final synthesis is blocked by: ' .. table.concat(gates, ', '),
      blocker_ids,
      Guidance.next(workspace, args),
      Validation.diagnostic('final_gates', 'satisfied', true, gates)
    )
    rejected.data.unmet_gates = gates
    return rejected
  end
  if #workspace.artifact_order >= Config.get().limits.max_artifacts then
    return failure(
      'limit_exceeded',
      'the synthesis exceeds the artifact limit',
      {},
      'Replace the workspace',
      Validation.diagnostic(
        'workspace.artifacts',
        'max_items',
        Config.get().limits.max_artifacts,
        #workspace.artifact_order
      )
    )
  end

  local relations = {
    supports = {},
    contradicts = {},
    qualifies = {},
    depends_on = { workspace.frame_id },
    tests = {},
    supersedes = {},
  }
  local recorded_support = {}
  for _, id in ipairs(args.support_ids) do
    if not recorded_support[id] then
      table.insert(relations.supports, id)
      recorded_support[id] = true
    end
  end
  for _, result in ipairs(args.criterion_results) do
    for _, id in ipairs(result.evidence_ids) do
      if not recorded_support[id] then
        table.insert(relations.supports, id)
        recorded_support[id] = true
      end
    end
  end
  for _, id in ipairs(args.selected_option_ids) do
    table.insert(relations.depends_on, id)
  end
  for _, id in ipairs(args.review_ids) do
    table.insert(relations.depends_on, id)
  end
  for _, target_id in ipairs(workspace.artifact_order) do
    local target = State.find(workspace, target_id)
    if workspace.open_revisions[target_id] and target and target.status == 'active' and target.kind == 'synthesis' then
      table.insert(relations.supersedes, target_id)
    end
  end

  local synthesis_data = vim.deepcopy(args)
  synthesis_data.frame_id = workspace.frame_id
  if args.mode == 'checkpoint' then
    local synthesis_artifact = assert(State.add(workspace, 'synthesis', synthesis_data))
    for _, relation in ipairs({ 'supports', 'contradicts', 'qualifies', 'depends_on', 'tests' }) do
      for _, target_id in ipairs(relations[relation]) do
        State.add_relation(workspace, synthesis_artifact, relation, target_id)
      end
    end
    for _, target_id in ipairs(relations.supersedes) do
      State.supersede(workspace, target_id, synthesis_artifact.id)
    end
    return success_payload(
      workspace,
      synthesis_artifact,
      M.final_gates(workspace, args),
      Guidance.next(workspace, args)
    )
  end

  local stage, prepare_code = State.prepare_final(chat, synthesis_data, relations)
  if not stage then
    return failure(prepare_code, 'the final synthesis could not be prepared', {}, Guidance.next(workspace, args))
  end
  local rendered, markdown = xpcall(function()
    return Render.render(workspace, stage.candidate.data)
  end, debug.traceback)
  if not rendered or type(markdown) ~= 'string' or vim.trim(markdown) == '' then
    if not rendered then
      log:error('[reasoning] final rendering failed: %s', markdown)
    end
    State.discard_final(stage)
    return failure(
      'render_internal',
      'the deterministic final could not be rendered',
      {},
      { tool = 'reasoning_synthesis', reason = 'Resume after inspecting the plugin failure' }
    )
  end

  local terminal = {
    tool = 'none',
    reason = 'Final synthesis accepted; no further model action is permitted',
  }
  if lifecycle_phase == nil then
    local committed, commit_code = State.commit_final(chat, stage)
    if not committed then
      return failure(commit_code, 'the final synthesis transaction conflicted', {}, Guidance.next(workspace, args))
    end
    return success_payload(workspace, committed, {}, terminal)
  end

  local projected_progress = vim.deepcopy(workspace.counts_by_kind)
  projected_progress.synthesis = (projected_progress.synthesis or 0) + 1
  return {
    status = 'success',
    data = {
      workspace_id = workspace.id,
      artifact = vim.deepcopy(stage.candidate),
      progress = projected_progress,
      unmet_gates = {},
      next_action = terminal,
      _reasoning_final = { stage = stage, markdown = markdown },
    },
  }
end

M.failure = failure
M.success = success
M.text_valid = text_valid
M.bounded_array = bounded_array
M.transition = Transition.next

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

local function normalize_next_action(operation, result)
  if result.status ~= 'error' or type(result.data.next_action) ~= 'string' then
    return result
  end
  local tools_by_code = {
    workspace_missing = 'reasoning_frame',
    perspective_unknown = 'reasoning_frame',
    limit_exceeded = 'reasoning_frame',
  }
  result.data.next_action = {
    tool = tools_by_code[result.data.code] or Constants.tool_by_operation[operation] or 'reasoning_frame',
    reason = result.data.next_action,
  }
  return result
end

function M.call(operation, chat, args, lifecycle_phase)
  local tools_by_operation = Constants.tool_by_operation
  local workspace = State.get(chat)
  local transition_allowed = not lifecycle_phase or Transition.allowed(workspace, lifecycle_phase, operation, args)
  local function reject_transition()
    local expected = Transition.next(workspace, lifecycle_phase)
    return failure(
      'transition_invalid',
      'the reasoning operation does not match the authoritative transition',
      {},
      expected,
      {
        path = 'tool',
        constraint = 'authoritative_transition',
        expected = expected and expected.tool or 'none',
        actual = tools_by_operation[operation] or 'unknown_operation',
      }
    )
  end

  if lifecycle_phase == 'reframing' and not transition_allowed then
    return reject_transition()
  end

  local explicit_reframe = operation == 'frame'
    and type(args) == 'table'
    and vim.tbl_contains({ 'revise', 'replace' }, args.action)
  if not explicit_reframe then
    local final = accepted_final(workspace)
    if final then
      return failure(
        'workspace_finalized',
        'the accepted final synthesis is terminal until the frame is explicitly revised or replaced',
        { final.id },
        { tool = 'none', reason = 'Use explicit user resume before reframing' }
      )
    end
  end

  if not transition_allowed then
    return reject_transition()
  end

  local handler = M[operation]
  if type(handler) ~= 'function' then
    return failure(
      'internal_error',
      'the reasoning operation is unavailable',
      {},
      { tool = tools_by_operation[operation] or 'reasoning_frame', reason = 'Report the plugin error' }
    )
  end
  local ok, result = xpcall(function()
    return handler(chat, args, lifecycle_phase)
  end, debug.traceback)
  if not ok then
    log:error('[reasoning] %s failed: %s', operation, result)
    return failure(
      'internal_error',
      'the reasoning operation failed internally',
      {},
      { tool = tools_by_operation[operation], reason = 'Report the plugin error' }
    )
  end
  if lifecycle_phase == nil and explicit_reframe and result.status == 'success' then
    Terminal.clear(chat)
  end
  result = normalize_next_action(operation, result)
  if lifecycle_phase and result.status == 'error' then
    result.data.next_action = Transition.next(State.get(chat), lifecycle_phase)
  end
  return result
end

return M
