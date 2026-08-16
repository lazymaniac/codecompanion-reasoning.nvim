local State = require('codecompanion._extensions.reasoning.state')

local M = {}

local text_width = 160

local function active(workspace, id)
  local artifact = workspace and type(id) == 'string' and workspace.artifacts_by_id[id] or nil
  if artifact and artifact.status == 'active' then
    return artifact
  end
end

local function summary(value)
  if type(value) ~= 'string' then
    return ''
  end
  local trimmed = vim.trim(value):gsub('%s+', ' ')
  if vim.fn.strchars(trimmed) <= text_width then
    return trimmed
  end
  return vim.fn.strcharpart(trimmed, 0, text_width)
end

function M.children(workspace, id)
  local result = {}
  for _, artifact_id in ipairs((workspace and workspace.artifact_order) or {}) do
    local artifact = active(workspace, artifact_id)
    if artifact and artifact.kind == 'question' and artifact.data.parent_id == id then
      table.insert(result, artifact)
    end
  end
  return result
end

function M.split(workspace, parent_id)
  return ((workspace and workspace.splits) or {})[parent_id]
end

function M.root_split(workspace)
  for _, frame_id in ipairs((workspace and workspace.frame_lineage) or {}) do
    local record = M.split(workspace, frame_id)
    if record then
      return record
    end
  end
  return workspace and workspace.frame_id and M.split(workspace, workspace.frame_id) or nil
end

function M.roots(workspace)
  local result = {}
  for _, artifact_id in ipairs((workspace and workspace.artifact_order) or {}) do
    local artifact = active(workspace, artifact_id)
    if artifact and artifact.kind == 'question' and State.in_lineage(workspace, artifact.data.parent_id) then
      table.insert(result, artifact)
    end
  end
  return result
end

function M.closure(workspace, id)
  local order = (workspace and workspace.artifact_order) or {}
  for index = #order, 1, -1 do
    local artifact = active(workspace, order[index])
    if artifact and artifact.kind == 'closure' and artifact.data.question_id == id then
      return artifact
    end
  end
end

function M.preorder(workspace)
  local result = {}
  local visited = {}
  local function walk(node)
    if visited[node.id] then
      return
    end
    visited[node.id] = true
    table.insert(result, node)
    for _, child in ipairs(M.children(workspace, node.id)) do
      walk(child)
    end
  end
  for _, root in ipairs(M.roots(workspace)) do
    walk(root)
  end
  return result
end

function M.depth(workspace, question)
  local depth = 1
  local visited = { [question.id] = true }
  local parent = active(workspace, question.data.parent_id)
  while parent and parent.kind == 'question' and not visited[parent.id] do
    visited[parent.id] = true
    depth = depth + 1
    parent = active(workspace, parent.data.parent_id)
  end
  return depth
end

local function reviewed(workspace, question, evidence)
  local supported = { [question.id] = true }
  for _, artifact in ipairs(evidence) do
    supported[artifact.id] = true
  end
  for _, artifact_id in ipairs((workspace and workspace.artifact_order) or {}) do
    local artifact = active(workspace, artifact_id)
    if artifact and artifact.kind == 'review' and State.in_lineage(workspace, artifact.data.frame_id) then
      for _, target_id in ipairs(artifact.data.target_ids or {}) do
        if supported[target_id] then
          return true
        end
      end
    end
  end
  return false
end

function M.closure_valid(workspace, closure, options)
  options = options or {}
  if type(closure) ~= 'table' or closure.status ~= 'active' or closure.kind ~= 'closure' then
    return false
  end
  local question = active(workspace, closure.data.question_id)
  if not question or question.kind ~= 'question' then
    return false
  end
  local evidence = {}
  for _, id in ipairs(closure.relations.supports or {}) do
    local artifact = active(workspace, id)
    if not artifact or artifact.kind ~= 'evidence' then
      return false
    end
    table.insert(evidence, artifact)
  end
  if closure.data.action == 'drop' then
    return closure.data.drop_reason == 'out_of_scope' or #evidence > 0
  end
  if #evidence == 0 then
    return false
  end
  local resolution = closure.data.resolution_kind
  if options.require_observation and resolution == 'observation' then
    local observed = false
    for _, artifact in ipairs(evidence) do
      observed = observed or artifact.data.kind == 'observation'
    end
    if not observed then
      return false
    end
  end
  if options.judgment_requires_review and resolution == 'judgment' then
    return reviewed(workspace, question, evidence)
  end
  return true
end

function M.closed(workspace, question, options)
  local children = M.children(workspace, question.id)
  if #children > 0 then
    for _, child in ipairs(children) do
      if not M.closed(workspace, child, options) then
        return false
      end
    end
    return true
  end
  local closure = M.closure(workspace, question.id)
  return closure ~= nil and M.closure_valid(workspace, closure, options)
end

function M.open_leaves(workspace, options)
  local result = {}
  for _, node in ipairs(M.preorder(workspace)) do
    if #M.children(workspace, node.id) == 0 and not M.closed(workspace, node, options) then
      table.insert(result, node)
    end
  end
  return result
end

function M.unsupported_closures(workspace, options)
  local result = {}
  for _, artifact_id in ipairs((workspace and workspace.artifact_order) or {}) do
    local artifact = active(workspace, artifact_id)
    if artifact and artifact.kind == 'closure' and not M.closure_valid(workspace, artifact, options) then
      table.insert(result, artifact.id)
    end
  end
  return result
end

local function bounded(values, limit, transform)
  local kept = {}
  for index, value in ipairs(values) do
    if index > limit then
      break
    end
    table.insert(kept, transform and transform(value) or value)
  end
  return kept, math.max(#values - limit, 0)
end

function M.frontier(workspace, limits, options)
  options = options or {}
  local limit = (limits and limits.frontier_items) or 12
  local leaves = M.open_leaves(workspace, options)
  local questions, dropped_questions = bounded(leaves, limit, function(node)
    return {
      id = node.id,
      parent_id = node.data.parent_id,
      depth = M.depth(workspace, node),
      provisional = node.data.provisional == true,
      text = summary(node.data.text),
    }
  end)
  local closures, dropped_closures = bounded(M.unsupported_closures(workspace, options), limit)

  local open_revisions = {}
  for _, artifact_id in ipairs((workspace and workspace.artifact_order) or {}) do
    if workspace.open_revisions[artifact_id] then
      table.insert(open_revisions, artifact_id)
    end
  end

  local total, closed, max_depth = 0, 0, 0
  for _, node in ipairs(M.preorder(workspace)) do
    total = total + 1
    max_depth = math.max(max_depth, M.depth(workspace, node))
    if M.closed(workspace, node, options) then
      closed = closed + 1
    end
  end

  return {
    questions = questions,
    unsupported_closures = closures,
    open_revisions = open_revisions,
    unresolved_contradictions = vim.deepcopy(options.unresolved_contradictions or {}),
    tree = {
      total = total,
      closed = closed,
      open = total - closed,
      max_depth = max_depth,
      root_split = M.root_split(workspace) ~= nil,
    },
    truncated = { questions = dropped_questions, unsupported_closures = dropped_closures },
  }
end

return M
