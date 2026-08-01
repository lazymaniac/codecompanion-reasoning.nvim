local Config = require('codecompanion._extensions.reasoning.config')
local Guidance = require('codecompanion._extensions.reasoning.guidance')
local State = require('codecompanion._extensions.reasoning.state')
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

function M.final_gates(workspace, synthesis)
  local gates = {}
  if not workspace or not workspace.frame_id then
    table.insert(gates, 'frame_missing')
  end
  return gates
end

M.failure = failure
M.success = success
M.text_valid = text_valid
M.bounded_array = bounded_array

function M.call(operation, chat, args)
  local tools_by_operation = {
    frame = 'reasoning_frame',
    evidence = 'reasoning_evidence',
    options = 'reasoning_options',
    review = 'reasoning_review',
    synthesis = 'reasoning_synthesis',
  }
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
