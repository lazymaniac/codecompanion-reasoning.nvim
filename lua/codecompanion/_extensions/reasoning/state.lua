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
}

local function new_workspace(sequence)
  return {
    id = 'W' .. sequence,
    frame_id = nil,
    artifacts_by_id = {},
    artifact_order = {},
    counts_by_kind = {},
    next_sequence = {},
    open_revisions = {},
    resolved_revisions = {},
    resolved_contradictions = {},
  }
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
  workspace.next_sequence[kind] = sequence
  local artifact = {
    id = prefix .. sequence,
    kind = kind,
    status = 'active',
    data = vim.deepcopy(data),
    relations = {
      supports = {},
      contradicts = {},
      qualifies = {},
      depends_on = {},
      tests = {},
      supersedes = {},
    },
  }
  workspace.artifacts_by_id[artifact.id] = artifact
  table.insert(workspace.artifact_order, artifact.id)
  workspace.counts_by_kind[kind] = (workspace.counts_by_kind[kind] or 0) + 1
  return artifact
end

function M.find(workspace, id)
  return workspace and workspace.artifacts_by_id[id] or nil
end

function M.add_relation(artifact, relation, target_id)
  assert(artifact.relations[relation], 'unknown relation: ' .. tostring(relation))
  table.insert(artifact.relations[relation], target_id)
end

function M.supersede(workspace, old_id, replacement_id)
  local old = M.find(workspace, old_id)
  local replacement = M.find(workspace, replacement_id)
  assert(old and replacement, 'supersession artifacts must exist')
  old.status = 'superseded'
  M.add_relation(replacement, 'supersedes', old_id)
  resolve_revision(workspace, old_id, 'superseded', replacement_id)
end

function M.retract(workspace, id)
  local artifact = M.find(workspace, id)
  assert(artifact, 'retracted artifact must exist')
  artifact.status = 'retracted'
  resolve_revision(workspace, id, 'retracted')
end

function M.retire(workspace, id)
  local artifact = M.find(workspace, id)
  assert(artifact, 'retired artifact must exist')
  artifact.status = 'superseded'
  resolve_revision(workspace, id, 'retired')
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
