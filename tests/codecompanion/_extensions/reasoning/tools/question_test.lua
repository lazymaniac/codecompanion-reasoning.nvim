local Config = require('codecompanion._extensions.reasoning.config')
local Protocol = require('codecompanion._extensions.reasoning.protocol')
local Question = require('codecompanion._extensions.reasoning.tools.question')
local State = require('codecompanion._extensions.reasoning.state')
local Tree = require('codecompanion._extensions.reasoning.tree')

local T = MiniTest.new_set({
  hooks = {
    pre_case = function()
      Config.setup()
      State._reset()
    end,
  },
})
local eq = MiniTest.expect.equality

local function frame_args()
  return {
    action = 'start',
    objective = 'Choose a durable cache design',
    problem_type = 'analysis',
    depth = 'standard',
    constraints = { 'No external service' },
    success_criteria = { 'Survives process restart' },
    unknowns = {},
    perspectives = { { name = 'correctness', purpose = 'Find invalidation failures' } },
    temporal_required = false,
    branching_required = false,
    branching_rationale = 'One design is under analysis',
  }
end

local function question_args(overrides)
  return vim.tbl_extend('force', {
    action = 'split',
    parent_id = '',
    axis = 'component',
    composition = 'all_of',
    residual = '',
    residual_disposition = 'none',
    residual_covered_by = '',
    child_questions = {},
    question_id = '',
    answer = '',
    justification = '',
    drop_reason = 'none',
    evidence_ids = {},
    acceptance_test = '',
    resolution_kind = 'none',
    confidence = 'none',
  }, overrides or {})
end

local function children(count, tag)
  local suffix = tag and (' ' .. tag) or ''
  local result = {}
  for index = 1, count do
    table.insert(result, {
      text = ('Sub-question%s %d'):format(suffix, index),
      kind = 'sub_problem',
      acceptance_test = ('Observe outcome%s %d'):format(suffix, index),
      resolution_kind = 'observation',
    })
  end
  return result
end

local function started()
  local chat = {}
  eq(Protocol.call('frame', chat, frame_args(), nil).status, 'success')
  return chat, State.get(chat)
end

local function root_split(chat, workspace, overrides)
  return Protocol.call(
    'question',
    chat,
    question_args(vim.tbl_extend('force', {
      parent_id = workspace.frame_id,
      child_questions = children(2),
    }, overrides or {})),
    nil
  )
end

local function evidence(workspace, kind)
  return State.add(workspace, 'evidence', {
    kind = kind or 'observation',
    perspective = 'correctness',
    addresses_unknowns = {},
  })
end

local function snapshot(workspace)
  return {
    revision = workspace.revision,
    artifact_order = vim.deepcopy(workspace.artifact_order),
    next_sequence = vim.deepcopy(workspace.next_sequence),
  }
end

local function assert_unchanged(workspace, before)
  eq(workspace.revision, before.revision)
  eq(workspace.artifact_order, before.artifact_order)
  eq(workspace.next_sequence, before.next_sequence)
end

T['records the root split and its children'] = function()
  local chat, workspace = started()
  local result = root_split(chat, workspace)

  eq(result.status, 'success')
  eq(result.data.artifact.id, 'Q2')
  eq(
    vim.tbl_map(function(artifact)
      return artifact.id
    end, result.data.artifacts),
    { 'Q1', 'Q2' }
  )
  eq(State.find(workspace, 'Q1').data.parent_id, workspace.frame_id)
  eq(State.find(workspace, 'Q1').relations.depends_on, { workspace.frame_id })
  eq(Tree.root_split(workspace).child_ids, { 'Q1', 'Q2' })
  eq(Tree.root_split(workspace).axis, 'component')
end

T['splits a sub-question below the root'] = function()
  local chat, workspace = started()
  root_split(chat, workspace)
  local result = Protocol.call(
    'question',
    chat,
    question_args({ parent_id = 'Q1', axis = 'phase', child_questions = children(2, 'below') }),
    nil
  )
  eq(result.status, 'success')
  eq(State.find(workspace, 'Q3').data.parent_id, 'Q1')
  eq(Tree.depth(workspace, State.find(workspace, 'Q3')), 2)
end

T['requires an active frame or sub-question parent'] = function()
  local chat, workspace = started()
  local before = snapshot(workspace)
  local result = root_split(chat, workspace, { parent_id = 'Q7' })
  eq(result.data.code, 'invalid_reference')
  eq(result.data.committed, false)
  eq(result.data.diagnostic.path, 'parent_id')
  assert_unchanged(workspace, before)
end

T['refuses to split a parent twice'] = function()
  local chat, workspace = started()
  root_split(chat, workspace)
  local before = snapshot(workspace)

  local repeated = root_split(chat, workspace)
  eq(repeated.data.code, 'split_exists')
  eq(repeated.data.diagnostic, {
    path = 'parent_id',
    constraint = 'workspace_state',
    expected = 'unsplit',
    actual = 'already_split',
  })
  assert_unchanged(workspace, before)
end

T['refuses to split a closed leaf'] = function()
  local chat, workspace = started()
  root_split(chat, workspace)
  local item = evidence(workspace)
  eq(
    Protocol.call(
      'question',
      chat,
      question_args({ action = 'answer', question_id = 'Q1', answer = 'It survives', evidence_ids = { item.id } }),
      nil
    ).status,
    'success'
  )
  local before = snapshot(workspace)

  local result =
    Protocol.call('question', chat, question_args({ parent_id = 'Q1', child_questions = children(2, 'closed') }), nil)
  eq(result.data.code, 'question_closed')
  assert_unchanged(workspace, before)
end

T['rejects degenerate and duplicated child sets'] = function()
  local chat, workspace = started()
  local before = snapshot(workspace)
  local cases = {
    {
      children = children(1),
      diagnostic = { path = 'child_questions', constraint = 'min_items', expected = 2, actual = 1 },
    },
    {
      children = children(7),
      diagnostic = { path = 'child_questions', constraint = 'max_items', expected = 6, actual = 7 },
    },
    {
      children = {
        { text = 'Same', kind = 'sub_problem', acceptance_test = 'Observe one', resolution_kind = 'observation' },
        { text = 'Same', kind = 'sub_problem', acceptance_test = 'Observe two', resolution_kind = 'observation' },
      },
      diagnostic = {
        path = 'child_questions[2].text',
        constraint = 'unique_items',
        expected = true,
        actual = 'duplicate_value',
      },
    },
    {
      children = {
        { text = 'First', kind = 'sub_problem', acceptance_test = 'Observe one', resolution_kind = 'observation' },
        { text = 'Second', kind = 'sub_problem', acceptance_test = 'Observe one', resolution_kind = 'observation' },
      },
      diagnostic = {
        path = 'child_questions[2].acceptance_test',
        constraint = 'unique_items',
        expected = true,
        actual = 'duplicate_value',
      },
    },
  }
  for _, case in ipairs(cases) do
    local result = root_split(chat, workspace, { child_questions = case.children })
    eq(result.data.code, 'question_invalid')
    eq(result.data.diagnostic, case.diagnostic)
    assert_unchanged(workspace, before)
  end
end

T['rejects a conjunctive acceptance test unless atomicity is relaxed'] = function()
  local chat, workspace = started()
  local before = snapshot(workspace)
  local conjunctive = children(2)
  conjunctive[2].acceptance_test = 'Observe the restart and the replay'

  local result = root_split(chat, workspace, { child_questions = conjunctive })
  eq(result.data.code, 'question_not_atomic')
  eq(result.data.diagnostic, {
    path = 'child_questions[2].acceptance_test',
    constraint = 'single_observable',
    expected = 1,
    actual = 'multiple_observables',
  })
  assert_unchanged(workspace, before)

  Config.setup({ strict_atomicity = false })
  eq(root_split(chat, workspace, { child_questions = conjunctive }).status, 'success')
end

T['bounds tree depth and question count'] = function()
  Config.setup({ limits = { max_tree_depth = 1 } })
  local chat, workspace = started()
  root_split(chat, workspace)
  local before = snapshot(workspace)
  local deep =
    Protocol.call('question', chat, question_args({ parent_id = 'Q1', child_questions = children(2, 'deep') }), nil)
  eq(deep.data.code, 'tree_depth_exceeded')
  eq(deep.data.diagnostic, {
    path = 'child_questions',
    constraint = 'max_depth',
    expected = 1,
    actual = 2,
  })
  assert_unchanged(workspace, before)

  Config.setup({ limits = { max_questions = 3 } })
  local wide_chat, wide_workspace = started()
  local wide = root_split(wide_chat, wide_workspace, { child_questions = children(4) })
  eq(wide.data.code, 'limit_exceeded')
  eq(wide.data.diagnostic.constraint, 'max_items')
end

T['requires a declared axis and a compatible composition'] = function()
  local chat, workspace = started()
  local before = snapshot(workspace)

  local axis = root_split(chat, workspace, { axis = 'none' })
  eq(axis.data.code, 'question_invalid')
  eq(axis.data.diagnostic.path, 'axis')
  assert_unchanged(workspace, before)

  eq(root_split(chat, workspace, { child_questions = children(2) }).status, 'success')
  local unknown_children = children(2)
  unknown_children[1].kind = 'unknown'
  eq(
    Protocol.call(
      'question',
      chat,
      question_args({ parent_id = 'Q1', composition = 'one_of', child_questions = unknown_children }),
      nil
    ).data.code,
    'question_invalid'
  )
end

T['requires every residual to be dispositioned'] = function()
  local chat, workspace = started()
  local before = snapshot(workspace)

  local undeclared = root_split(chat, workspace, { residual = 'Cluster failover' })
  eq(undeclared.data.code, 'residual_unresolved')
  eq(undeclared.data.diagnostic.path, 'residual_disposition')
  assert_unchanged(workspace, before)

  local missing_target = root_split(chat, workspace, {
    residual = 'Cluster failover',
    residual_disposition = 'covered_elsewhere',
    residual_covered_by = 'Q9',
  })
  eq(missing_target.data.code, 'residual_unresolved')
  assert_unchanged(workspace, before)

  local unquoted = root_split(chat, workspace, {
    residual = 'Cluster failover',
    residual_disposition = 'out_of_scope',
  })
  eq(unquoted.data.code, 'residual_unresolved')
  eq(unquoted.data.diagnostic, {
    path = 'residual',
    constraint = 'frame_constraint',
    expected = 'active_constraint',
    actual = 'unknown_value',
  })
  assert_unchanged(workspace, before)

  local scoped = root_split(chat, workspace, {
    residual = 'No external service',
    residual_disposition = 'out_of_scope',
  })
  eq(scoped.status, 'success')
  eq(Tree.root_split(workspace).residual, 'No external service')

  local spurious = Protocol.call(
    'question',
    chat,
    question_args({
      parent_id = 'Q1',
      child_questions = children(2, 'residual'),
      residual_disposition = 'covered_elsewhere',
      residual_covered_by = 'Q2',
    }),
    nil
  )
  eq(spurious.data.code, 'residual_unresolved')
  eq(spurious.data.diagnostic.path, 'residual_disposition')
end

T['closes a leaf with an answer and records the closure'] = function()
  local chat, workspace = started()
  root_split(chat, workspace)
  local item = evidence(workspace)

  local result = Protocol.call(
    'question',
    chat,
    question_args({
      action = 'answer',
      question_id = 'Q1',
      answer = 'The journal replays on restart',
      evidence_ids = { item.id },
      confidence = 'high',
    }),
    nil
  )
  eq(result.status, 'success')
  local artifact = State.find(workspace, result.data.artifact.id)
  eq(artifact.kind, 'closure')
  eq(artifact.data.question_id, 'Q1')
  eq(artifact.data.confidence, 'high')
  eq(artifact.relations.supports, { item.id })
  eq(artifact.relations.depends_on, { 'Q1' })
  eq(Tree.closed(workspace, State.find(workspace, 'Q1'), {}), true)
end

T['rejects closures that miss the configured evidence bar'] = function()
  local chat, workspace = started()
  root_split(chat, workspace)
  local assumption = evidence(workspace, 'assumption')
  local before = snapshot(workspace)

  local unsupported = Protocol.call(
    'question',
    chat,
    question_args({
      action = 'answer',
      question_id = 'Q1',
      answer = 'It probably survives',
      evidence_ids = { assumption.id },
    }),
    nil
  )
  eq(unsupported.data.code, 'closure_unsupported')
  eq(unsupported.data.diagnostic.constraint, 'observation_backed')
  assert_unchanged(workspace, before)

  local unreviewed = Protocol.call(
    'question',
    chat,
    question_args({
      action = 'answer',
      question_id = 'Q1',
      answer = 'The design is acceptable',
      evidence_ids = { assumption.id },
      resolution_kind = 'judgment',
    }),
    nil
  )
  eq(unreviewed.data.code, 'closure_unreviewed')
  assert_unchanged(workspace, before)

  local empty =
    Protocol.call('question', chat, question_args({ action = 'answer', question_id = 'Q1', answer = 'No basis' }), nil)
  eq(empty.data.code, 'closure_invalid')
  eq(empty.data.diagnostic, { path = 'evidence_ids', constraint = 'min_items', expected = 1, actual = 0 })
  assert_unchanged(workspace, before)
end

T['drops a leaf only with a classified justification'] = function()
  local chat, workspace = started()
  root_split(chat, workspace)
  local before = snapshot(workspace)

  local unclassified = Protocol.call(
    'question',
    chat,
    question_args({ action = 'drop', question_id = 'Q1', justification = 'Not needed' }),
    nil
  )
  eq(unclassified.data.code, 'closure_invalid')
  eq(unclassified.data.diagnostic.path, 'drop_reason')
  assert_unchanged(workspace, before)

  local unquoted = Protocol.call(
    'question',
    chat,
    question_args({
      action = 'drop',
      question_id = 'Q1',
      justification = 'Not needed',
      drop_reason = 'out_of_scope',
    }),
    nil
  )
  eq(unquoted.data.code, 'closure_invalid')
  eq(unquoted.data.diagnostic.constraint, 'frame_constraint')
  assert_unchanged(workspace, before)

  local scoped = Protocol.call(
    'question',
    chat,
    question_args({
      action = 'drop',
      question_id = 'Q1',
      justification = 'No external service',
      drop_reason = 'out_of_scope',
    }),
    nil
  )
  eq(scoped.status, 'success')
  eq(State.find(workspace, scoped.data.artifact.id).data.drop_reason, 'out_of_scope')
end

T['rejects closing a parent, a closed leaf, or a foreign reference'] = function()
  local chat, workspace = started()
  root_split(chat, workspace)
  Protocol.call('question', chat, question_args({ parent_id = 'Q1', child_questions = children(2, 'leaf') }), nil)
  local item = evidence(workspace)

  local parent = Protocol.call(
    'question',
    chat,
    question_args({ action = 'answer', question_id = 'Q1', answer = 'Answered', evidence_ids = { item.id } }),
    nil
  )
  eq(parent.data.code, 'question_not_leaf')

  local missing = Protocol.call(
    'question',
    chat,
    question_args({ action = 'answer', question_id = 'Q9', answer = 'Answered', evidence_ids = { item.id } }),
    nil
  )
  eq(missing.data.code, 'invalid_reference')

  local closed_args = question_args({
    action = 'answer',
    question_id = 'Q3',
    answer = 'Answered',
    evidence_ids = { item.id },
  })
  eq(Protocol.call('question', chat, closed_args, nil).status, 'success')
  eq(Protocol.call('question', chat, closed_args, nil).data.code, 'question_closed')
end

T['requires a workspace and a known action'] = function()
  local chat = {}
  local missing = Protocol.call('question', chat, question_args(), nil)
  eq(missing.data.code, 'workspace_missing')
  eq(missing.data.next_action.tool, 'reasoning_frame')

  local started_chat, workspace = started()
  local before = snapshot(workspace)
  local unknown = Protocol.call('question', started_chat, question_args({ action = 'merge' }), nil)
  eq(unknown.data.code, 'question_invalid')
  eq(unknown.data.diagnostic.path, 'action')
  assert_unchanged(workspace, before)
end

T['exposes the configured child bound through the resolved schema'] = function()
  Config.setup({ limits = { max_children = 3 } })
  local resolved = require('codecompanion._extensions.reasoning.schema').resolve('reasoning_question', Question)
  local properties = resolved.schema['function'].parameters.properties
  eq(properties.child_questions.maxItems, 3)
  eq(properties.parent_id.minLength, nil)
  eq(properties.residual.minLength, nil)
  eq(properties.evidence_ids.uniqueItems, true)
end

return T
