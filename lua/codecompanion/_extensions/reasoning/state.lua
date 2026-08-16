local Config = require('codecompanion._extensions.reasoning.config')

local M = {}
local workspaces_by_chat = setmetatable({}, { __mode = 'k' })
local prefixes = {
  frame = 'F',
  evidence = 'E',
  branch = 'B',
  option = 'O',
  review = 'R',
  synthesis = 'S',
  question = 'Q',
  closure = 'C',
}

local function new_workspace(sequence)
  return {
    id = 'W' .. sequence,
    revision = 0,
    frame_id = nil,
    frame_lineage = {},
    splits = {},
    artifacts_by_id = {},
    artifact_order = {},
    counts_by_kind = {},
    next_sequence = {},
    open_revisions = {},
    resolved_revisions = {},
    resolved_contradictions = {},
  }
end

local function touch(workspace)
  workspace.revision = workspace.revision + 1
end

local function artifact_value(kind, id, data, relations)
  return {
    id = id,
    kind = kind,
    status = 'active',
    data = vim.deepcopy(data),
    relations = vim.tbl_deep_extend('force', {
      supports = {},
      contradicts = {},
      qualifies = {},
      depends_on = {},
      tests = {},
      supersedes = {},
    }, vim.deepcopy(relations or {})),
  }
end

local function insert_artifact(workspace, artifact, sequence)
  workspace.next_sequence[artifact.kind] = sequence
  workspace.artifacts_by_id[artifact.id] = artifact
  table.insert(workspace.artifact_order, artifact.id)
  workspace.counts_by_kind[artifact.kind] = (workspace.counts_by_kind[artifact.kind] or 0) + 1
  touch(workspace)
  return artifact
end

local function resolve_revision(workspace, target_id, resolution, replacement_id)
  local review_id = workspace.open_revisions[target_id]
  if not review_id then
    return
  end
  workspace.resolved_revisions[review_id] = workspace.resolved_revisions[review_id] or {}
  local record = { resolution = resolution }
  if replacement_id then
    record.replacement_id = replacement_id
  end
  workspace.resolved_revisions[review_id][target_id] = record
  workspace.open_revisions[target_id] = nil
end

function M.begin(chat, replace)
  assert(type(chat) == 'table', 'chat must be a table')
  local entry = workspaces_by_chat[chat]
  if entry and entry.active and not replace then
    return nil, 'workspace_exists'
  end
  entry = entry or { next_workspace = 1 }
  local workspace = new_workspace(entry.next_workspace)
  entry.next_workspace = entry.next_workspace + 1
  entry.active = workspace
  workspaces_by_chat[chat] = entry
  return workspace
end

function M.get(chat)
  local entry = workspaces_by_chat[chat]
  return entry and entry.active or nil
end

function M.add(workspace, kind, data)
  local prefix = prefixes[kind]
  assert(prefix, 'unknown artifact kind: ' .. tostring(kind))
  if #workspace.artifact_order >= Config.get().limits.max_artifacts then
    return nil, 'limit_exceeded'
  end
  local sequence = (workspace.next_sequence[kind] or 0) + 1
  return insert_artifact(workspace, artifact_value(kind, prefix .. sequence, data), sequence)
end

function M.find(workspace, id)
  return workspace and workspace.artifacts_by_id[id] or nil
end

function M.add_relation(workspace, artifact, relation, target_id)
  assert(artifact.relations[relation], 'unknown relation: ' .. tostring(relation))
  table.insert(artifact.relations[relation], target_id)
  touch(workspace)
end

function M.supersede(workspace, old_id, replacement_id)
  local old = M.find(workspace, old_id)
  local replacement = M.find(workspace, replacement_id)
  assert(old and replacement, 'supersession artifacts must exist')
  old.status = 'superseded'
  table.insert(replacement.relations.supersedes, old_id)
  resolve_revision(workspace, old_id, 'superseded', replacement_id)
  touch(workspace)
end

function M.retract(workspace, id)
  local artifact = M.find(workspace, id)
  assert(artifact, 'retracted artifact must exist')
  artifact.status = 'retracted'
  resolve_revision(workspace, id, 'retracted')
  touch(workspace)
end

function M.retire(workspace, id)
  local artifact = M.find(workspace, id)
  assert(artifact, 'retired artifact must exist')
  artifact.status = 'superseded'
  resolve_revision(workspace, id, 'retired')
  touch(workspace)
end

function M.set_frame(workspace, frame_id)
  workspace.frame_id = frame_id
  touch(workspace)
end

function M.append_data(workspace, artifact, field, value)
  assert(type(artifact.data[field]) == 'table', 'artifact data field must be an array')
  table.insert(artifact.data[field], value)
  touch(workspace)
end

function M.reset_lineage(workspace, frame_id)
  assert(type(frame_id) == 'string', 'lineage frames must be identified')
  workspace.frame_lineage = { frame_id }
  touch(workspace)
end

function M.extend_lineage(workspace, frame_id)
  assert(type(frame_id) == 'string', 'lineage frames must be identified')
  table.insert(workspace.frame_lineage, frame_id)
  touch(workspace)
end

function M.in_lineage(workspace, frame_id)
  if not workspace or type(frame_id) ~= 'string' then
    return false
  end
  local lineage = workspace.frame_lineage
  if type(lineage) ~= 'table' or #lineage == 0 then
    return workspace.frame_id == frame_id
  end
  return vim.tbl_contains(lineage, frame_id)
end

function M.set_split(workspace, parent_id, record)
  assert(type(parent_id) == 'string', 'splits must name a parent')
  workspace.splits[parent_id] = vim.deepcopy(record)
  touch(workspace)
end

function M.open_revision(workspace, target_id, review_id)
  workspace.open_revisions[target_id] = review_id
  touch(workspace)
end

function M.resolve_contradiction(workspace, key, review_id)
  workspace.resolved_contradictions[key] = review_id
  touch(workspace)
end

function M.prepare_final(chat, data, relations)
  local workspace = M.get(chat)
  if not workspace then
    return nil, 'workspace_missing'
  end
  if #workspace.artifact_order >= Config.get().limits.max_artifacts then
    return nil, 'limit_exceeded'
  end
  local sequence = (workspace.next_sequence.synthesis or 0) + 1
  return {
    workspace = workspace,
    workspace_id = workspace.id,
    revision = workspace.revision,
    reserved_id = 'S' .. sequence,
    candidate = artifact_value('synthesis', 'S' .. sequence, data, relations),
    state = 'prepared',
  }
end

function M.commit_final(chat, stage)
  if type(stage) ~= 'table' or stage.state ~= 'prepared' then
    return nil, 'transaction_closed'
  end
  local workspace = M.get(chat)
  if
    not workspace
    or workspace ~= stage.workspace
    or workspace.id ~= stage.workspace_id
    or workspace.revision ~= stage.revision
    or type(stage.candidate) ~= 'table'
    or stage.candidate.kind ~= 'synthesis'
    or stage.candidate.status ~= 'active'
    or stage.candidate.id ~= stage.reserved_id
    or stage.reserved_id ~= 'S' .. ((workspace.next_sequence.synthesis or 0) + 1)
    or workspace.artifacts_by_id[stage.reserved_id]
  then
    stage.state = 'conflicted'
    return nil, 'transaction_conflict'
  end
  if #workspace.artifact_order >= Config.get().limits.max_artifacts then
    stage.state = 'conflicted'
    return nil, 'limit_exceeded'
  end
  for _, id in ipairs(stage.candidate.relations.supersedes) do
    local artifact = M.find(workspace, id)
    if not artifact or artifact.status ~= 'active' or artifact.kind ~= 'synthesis' then
      stage.state = 'conflicted'
      return nil, 'transaction_conflict'
    end
  end

  stage.rollback = {
    next_sequence = workspace.next_sequence.synthesis,
    count = workspace.counts_by_kind.synthesis,
    open_revisions = vim.deepcopy(workspace.open_revisions),
    resolved_revisions = vim.deepcopy(workspace.resolved_revisions),
    statuses = {},
  }
  for _, id in ipairs(stage.candidate.relations.supersedes) do
    stage.rollback.statuses[id] = M.find(workspace, id).status
  end

  local committed =
    insert_artifact(workspace, vim.deepcopy(stage.candidate), (workspace.next_sequence.synthesis or 0) + 1)
  for _, id in ipairs(stage.candidate.relations.supersedes) do
    local old = M.find(workspace, id)
    old.status = 'superseded'
    resolve_revision(workspace, id, 'superseded', committed.id)
  end
  stage.state = 'committed'
  stage.committed_artifact = committed
  return committed
end

function M.rollback_final(chat, stage)
  local workspace = M.get(chat)
  if
    type(stage) ~= 'table'
    or stage.state ~= 'committed'
    or workspace ~= stage.workspace
    or workspace.revision ~= stage.revision + 1
    or workspace.artifact_order[#workspace.artifact_order] ~= stage.reserved_id
    or workspace.artifacts_by_id[stage.reserved_id] ~= stage.committed_artifact
  then
    return false
  end
  table.remove(workspace.artifact_order)
  workspace.artifacts_by_id[stage.reserved_id] = nil
  workspace.next_sequence.synthesis = stage.rollback.next_sequence
  workspace.counts_by_kind.synthesis = stage.rollback.count
  workspace.open_revisions = stage.rollback.open_revisions
  workspace.resolved_revisions = stage.rollback.resolved_revisions
  for id, status in pairs(stage.rollback.statuses) do
    M.find(workspace, id).status = status
  end
  workspace.revision = stage.revision
  stage.committed_artifact = nil
  stage.state = 'rolled_back'
  return true
end

function M.finalize_final(chat, stage)
  local workspace = M.get(chat)
  if
    type(stage) ~= 'table'
    or stage.state ~= 'committed'
    or workspace ~= stage.workspace
    or workspace.revision ~= stage.revision + 1
    or workspace.artifact_order[#workspace.artifact_order] ~= stage.reserved_id
    or workspace.artifacts_by_id[stage.reserved_id] ~= stage.committed_artifact
  then
    return false
  end
  stage.rollback = nil
  stage.state = 'finalized'
  return true
end

function M.discard_final(stage)
  if type(stage) ~= 'table' or stage.state ~= 'prepared' then
    return false
  end
  stage.state = 'discarded'
  return true
end

function M.clear(chat)
  workspaces_by_chat[chat] = nil
end

function M._reset()
  workspaces_by_chat = setmetatable({}, { __mode = 'k' })
end

function M._workspace_count()
  local count = 0
  for _ in pairs(workspaces_by_chat) do
    count = count + 1
  end
  return count
end

return M
