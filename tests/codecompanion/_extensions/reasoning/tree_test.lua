local Tree = require('codecompanion._extensions.reasoning.tree')

local T = MiniTest.new_set()
local eq = MiniTest.expect.equality

local function artifact(id, kind, data)
  return {
    id = id,
    kind = kind,
    status = 'active',
    data = data,
    relations = {
      supports = {},
      contradicts = {},
      qualifies = {},
      depends_on = {},
      tests = {},
      supersedes = {},
    },
  }
end

local function workspace()
  local ws = {
    frame_id = 'F1',
    frame_lineage = { 'F1' },
    root_split = nil,
    artifact_order = { 'F1' },
    artifacts_by_id = { F1 = artifact('F1', 'frame', { unknowns = {} }) },
    open_revisions = {},
    resolved_revisions = {},
    resolved_contradictions = {},
  }
  return ws
end

local function add(ws, value)
  ws.artifacts_by_id[value.id] = value
  table.insert(ws.artifact_order, value.id)
  return value
end

local function question(ws, id, parent_id, text, overrides)
  local data = vim.tbl_extend('force', {
    parent_id = parent_id,
    text = text,
    kind = 'sub_problem',
    acceptance_test = 'Observe ' .. id,
    resolution_kind = 'observation',
    provisional = false,
    frame_id = 'F1',
  }, overrides or {})
  return add(ws, artifact(id, 'question', data))
end

local function evidence(ws, id, kind)
  return add(ws, artifact(id, 'evidence', { kind = kind or 'observation', perspective = 'correctness' }))
end

local function closure(ws, id, question_id, evidence_ids, overrides)
  local data = vim.tbl_extend('force', {
    question_id = question_id,
    action = 'answer',
    answer = 'Answered ' .. question_id,
    justification = '',
    drop_reason = 'none',
    acceptance_test = '',
    resolution_kind = 'observation',
    confidence = 'medium',
    frame_id = 'F1',
  }, overrides or {})
  local value = add(ws, artifact(id, 'closure', data))
  value.relations.supports = vim.deepcopy(evidence_ids or {})
  return value
end

local function split_workspace()
  local ws = workspace()
  ws.root_split = { axis = 'component', composition = 'all_of', residual = '', child_ids = { 'Q1', 'Q2' } }
  question(ws, 'Q1', 'F1', 'Does the cache survive restart?')
  question(ws, 'Q2', 'F1', 'Is memory bounded?')
  return ws
end

local strict = { require_observation = true, judgment_requires_review = true }

T['reads children and closures for a node'] = function()
  local ws = split_workspace()
  question(ws, 'Q3', 'Q1', 'Does the snapshot load?')
  question(ws, 'Q4', 'Q1', 'Does the journal replay?')
  evidence(ws, 'E1')
  closure(ws, 'C1', 'Q3', { 'E1' })

  eq(
    vim.tbl_map(function(node)
      return node.id
    end, Tree.children(ws, 'Q1')),
    { 'Q3', 'Q4' }
  )
  eq(Tree.children(ws, 'Q2'), {})
  eq(Tree.closure(ws, 'Q3').id, 'C1')
  eq(Tree.closure(ws, 'Q4'), nil)

  ws.artifacts_by_id.Q4.status = 'superseded'
  eq(
    vim.tbl_map(function(node)
      return node.id
    end, Tree.children(ws, 'Q1')),
    { 'Q3' }
  )
end

T['orders roots and leaves in pre-order'] = function()
  local ws = split_workspace()
  question(ws, 'Q3', 'Q1', 'Does the snapshot load?')
  question(ws, 'Q4', 'Q2', 'Is the working set bounded?')
  question(ws, 'Q5', 'Q1', 'Does the journal replay?')

  eq(
    vim.tbl_map(function(node)
      return node.id
    end, Tree.preorder(ws)),
    { 'Q1', 'Q3', 'Q5', 'Q2', 'Q4' }
  )
  eq(
    vim.tbl_map(function(node)
      return node.id
    end, Tree.open_leaves(ws, strict)),
    { 'Q3', 'Q5', 'Q4' }
  )
  eq(Tree.depth(ws, ws.artifacts_by_id.Q1), 1)
  eq(Tree.depth(ws, ws.artifacts_by_id.Q3), 2)
end

T['closes a parent only when every child closes'] = function()
  local ws = split_workspace()
  question(ws, 'Q3', 'Q1', 'Does the snapshot load?')
  question(ws, 'Q4', 'Q1', 'Does the journal replay?')
  evidence(ws, 'E1')
  closure(ws, 'C1', 'Q3', { 'E1' })
  closure(ws, 'C2', 'Q2', { 'E1' })

  eq(Tree.closed(ws, ws.artifacts_by_id.Q1, strict), false)
  eq(Tree.closed(ws, ws.artifacts_by_id.Q2, strict), true)
  closure(ws, 'C3', 'Q4', { 'E1' })
  eq(Tree.closed(ws, ws.artifacts_by_id.Q1, strict), true)
  eq(Tree.open_leaves(ws, strict), {})
end

T['invalidates a closure whose evidence stops supporting it'] = function()
  local ws = split_workspace()
  evidence(ws, 'E1')
  evidence(ws, 'E2', 'assumption')
  local retracted = closure(ws, 'C1', 'Q1', { 'E1' })
  local assumed = closure(ws, 'C2', 'Q2', { 'E2' })

  eq(Tree.closure_valid(ws, retracted, strict), true)
  ws.artifacts_by_id.E1.status = 'retracted'
  eq(Tree.closure_valid(ws, retracted, strict), false)
  eq(
    vim.tbl_map(function(node)
      return node.id
    end, Tree.open_leaves(ws, strict)),
    { 'Q1', 'Q2' }
  )

  eq(Tree.closure_valid(ws, assumed, strict), false)
  eq(Tree.closure_valid(ws, assumed, { require_observation = false }), true)
end

T['requires a review before a judgment closure counts'] = function()
  local ws = split_workspace()
  evidence(ws, 'E1')
  local judged = closure(ws, 'C1', 'Q1', { 'E1' }, { resolution_kind = 'judgment' })
  eq(Tree.closure_valid(ws, judged, strict), false)
  eq(Tree.closure_valid(ws, judged, { judgment_requires_review = false }), true)

  local review = add(ws, artifact('R1', 'review', { frame_id = 'F1', target_ids = { 'Q1' } }))
  eq(Tree.closure_valid(ws, judged, strict), true)
  review.data.frame_id = 'F9'
  eq(Tree.closure_valid(ws, judged, strict), false)
end

T['drops a leaf without evidence only when it is out of scope'] = function()
  local ws = split_workspace()
  local dropped = closure(ws, 'C1', 'Q1', {}, {
    action = 'drop',
    answer = '',
    justification = 'The constraint forbids it',
    drop_reason = 'out_of_scope',
    resolution_kind = 'none',
  })
  eq(Tree.closure_valid(ws, dropped, strict), true)
  dropped.data.drop_reason = 'not_material'
  eq(Tree.closure_valid(ws, dropped, strict), false)
end

T['reports a deterministic bounded frontier'] = function()
  local ws = split_workspace()
  question(ws, 'Q3', 'Q1', 'Does the snapshot load?', { provisional = true })
  evidence(ws, 'E1')
  closure(ws, 'C1', 'Q2', { 'E1' })
  ws.open_revisions = { E1 = 'R1' }

  local frontier = Tree.frontier(ws, { frontier_items = 12 }, strict)
  eq(frontier.questions, {
    { id = 'Q3', parent_id = 'Q1', depth = 2, provisional = true, text = 'Does the snapshot load?' },
  })
  eq(frontier.unsupported_closures, {})
  eq(frontier.open_revisions, { 'E1' })
  eq(frontier.unresolved_contradictions, {})
  eq(frontier.tree, { total = 3, closed = 1, open = 2, max_depth = 2, root_split = true })
  eq(frontier.truncated, { questions = 0, unsupported_closures = 0 })

  ws.artifacts_by_id.E1.status = 'retracted'
  local reopened = Tree.frontier(ws, { frontier_items = 12 }, strict)
  eq(
    vim.tbl_map(function(entry)
      return entry.id
    end, reopened.questions),
    { 'Q3', 'Q2' }
  )
  eq(reopened.unsupported_closures, { 'C1' })
end

T['truncates long frontiers and counts the remainder'] = function()
  local ws = split_workspace()
  for index = 3, 8 do
    question(ws, 'Q' .. index, 'Q1', 'Sub-question ' .. index)
  end
  local frontier = Tree.frontier(ws, { frontier_items = 3 }, strict)
  eq(#frontier.questions, 3)
  eq(
    vim.tbl_map(function(entry)
      return entry.id
    end, frontier.questions),
    { 'Q3', 'Q4', 'Q5' }
  )
  eq(frontier.truncated.questions, 4)
end

T['trims frontier question text to a bounded width'] = function()
  local ws = split_workspace()
  question(ws, 'Q3', 'Q1', '  ' .. string.rep('a', 200) .. '\n tail  ')
  local frontier = Tree.frontier(ws, { frontier_items = 12 }, strict)
  eq(#frontier.questions[1].text, 160)
  eq(frontier.questions[1].text:find('\n'), nil)
end

T['reports unresolved contradictions supplied by the caller'] = function()
  local ws = split_workspace()
  local frontier = Tree.frontier(
    ws,
    { frontier_items = 12 },
    vim.tbl_extend('force', strict, { unresolved_contradictions = { { 'E2', 'E1' } } })
  )
  eq(frontier.unresolved_contradictions, { { 'E2', 'E1' } })
end

return T
