-- Covers the frame family: reasoning_start, reasoning_amend, reasoning_revise,
-- and reasoning_replace.
local Config = require('codecompanion._extensions.reasoning.config')
local Protocol = require('codecompanion._extensions.reasoning.protocol')
local Start = require('codecompanion._extensions.reasoning.tools.start')
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

local function valid_args()
  return {
    objective = 'Choose a durable cache design',
    problem_type = 'design',
    depth = 'deep',
    constraints = { 'No external service' },
    success_criteria = { 'Survives process restart', 'Bounded memory' },
    unknowns = { 'Expected write rate' },
    perspectives = {
      { name = 'correctness', purpose = 'Find invalidation failures' },
      { name = 'operations', purpose = 'Find lifecycle failures' },
    },
    temporal_required = false,
    branching_required = true,
    branching_rationale = 'Several storage strategies are viable',
  }
end

local function amend_args(overrides)
  return vim.tbl_extend('force', {
    add_constraints = {},
    add_success_criteria = {},
    add_unknowns = {},
    add_perspectives = {},
    require_temporal = false,
    require_branching = false,
    branching_rationale = '',
  }, overrides or {})
end

local function resize_perspectives(args, count)
  while #args.perspectives > count do
    table.remove(args.perspectives)
  end
  for index = #args.perspectives + 1, count do
    table.insert(args.perspectives, {
      name = 'perspective-' .. index,
      purpose = 'Inspect concern ' .. index,
    })
  end
  return args
end

T['starts a deep frame and recommends evidence'] = function()
  local chat = {}
  local result = Start.cmds[1]({ chat = chat }, valid_args(), {})
  eq(result.status, 'success')
  eq(result.data.artifact.id, 'F1')
  eq(result.data.next_action.tool, 'reasoning_evidence')
end

T['accepts a deep frame with more than four perspectives'] = function()
  local args = resize_perspectives(valid_args(), 5)
  local result = Start.cmds[1]({ chat = {} }, args, {})

  eq(result.status, 'success')
end

T['explains the deep perspective lower bound'] = function()
  local args = resize_perspectives(valid_args(), 1)
  local result = Start.cmds[1]({ chat = {} }, args, {})

  eq(result.status, 'error')
  eq(result.data.code, 'frame_incomplete')
  eq(result.data.message, 'deep frames require at least 2 perspectives; received 1')
  eq(result.data.next_action.tool, 'reasoning_start')
  eq(result.data.next_action.reason, 'Add perspectives and retry')
end

T['explains the configured perspective safety bound'] = function()
  Config.setup({ limits = { max_array_items = 4 } })
  local args = resize_perspectives(valid_args(), 5)
  local result = Start.cmds[1]({ chat = {} }, args, {})

  eq(result.status, 'error')
  eq(result.data.code, 'frame_incomplete')
  eq(result.data.message, 'perspectives exceed max_array_items=4; received 5')
  eq(result.data.next_action.tool, 'reasoning_start')
  eq(result.data.next_action.reason, 'Reduce perspectives to 4 or fewer and retry')
end

T['explains the standard perspective lower bound'] = function()
  local args = resize_perspectives(valid_args(), 0)
  args.depth = 'standard'
  local result = Start.cmds[1]({ chat = {} }, args, {})

  eq(result.status, 'error')
  eq(result.data.code, 'frame_incomplete')
  eq(result.data.message, 'standard frames require at least 1 perspective; received 0')
  eq(result.data.next_action.tool, 'reasoning_start')
  eq(result.data.next_action.reason, 'Add a perspective and retry')
end

T['reports perspective cardinality before later frame fields'] = function()
  local args = resize_perspectives(valid_args(), 0)
  args.temporal_required = nil
  local result = Start.cmds[1]({ chat = {} }, args, {})

  eq(result.data.diagnostic, {
    path = 'perspectives',
    constraint = 'min_items',
    expected = 2,
    actual = 0,
  })
end

T['requires branching for design problems'] = function()
  local args = valid_args()
  args.branching_required = false
  local result = Start.cmds[1]({ chat = {} }, args, {})
  eq(result.status, 'error')
  eq(result.data.code, 'branching_required')
end

T['requires branching for every decision-shaped problem type'] = function()
  for _, problem_type in ipairs({ 'decision', 'diagnosis', 'design', 'planning' }) do
    State._reset()
    local args = valid_args()
    args.problem_type = problem_type
    args.branching_required = false
    eq(Start.cmds[1]({ chat = {} }, args, {}).data.code, 'branching_required')
  end
  local analysis = valid_args()
  analysis.problem_type = 'analysis'
  analysis.branching_required = false
  eq(Start.cmds[1]({ chat = {} }, analysis, {}).status, 'success')
end

T['requires explicit revise or replace for an active workspace'] = function()
  local chat = {}
  Start.cmds[1]({ chat = chat }, valid_args(), {})
  local result = Start.cmds[1]({ chat = chat }, valid_args(), {})
  eq(result.status, 'error')
  eq(result.data.code, 'workspace_exists')
  eq(result.data.next_action.tool, 'reasoning_revise')
  eq(result.data.diagnostic, {
    path = 'tool',
    constraint = 'workspace_state',
    expected = { 'reasoning_revise', 'reasoning_replace' },
    actual = 'reasoning_start',
  })
end

T['rejects duplicate perspective names'] = function()
  local args = valid_args()
  args.perspectives[1].name = 'correctness review'
  args.perspectives[2].name = ' CORRECTNESS   REVIEW '
  local result = Start.cmds[1]({ chat = {} }, args, {})
  eq(result.data.code, 'frame_incomplete')
end

T['rejects duplicate criteria and unknowns after normalization'] = function()
  local criteria = valid_args()
  criteria.success_criteria[2] = '  SURVIVES   process restart '
  eq(Start.cmds[1]({ chat = {} }, criteria, {}).data.code, 'frame_incomplete')
  local unknowns = valid_args()
  unknowns.unknowns = { 'Expected write rate', ' expected   WRITE rate ' }
  eq(Start.cmds[1]({ chat = {} }, unknowns, {}).data.code, 'frame_incomplete')
end

T['rejects whitespace-only required text'] = function()
  local args = valid_args()
  args.objective = '   '
  local result = Start.cmds[1]({ chat = {} }, args, {})
  eq(result.data.code, 'frame_incomplete')
  eq(result.data.next_action.tool, 'reasoning_start')
end

T['counts configured text limits in characters, not bytes'] = function()
  Config.setup({ limits = { max_text_chars = 3 } })
  eq(Protocol.text_valid('żół'), true)
  eq(Protocol.text_valid('żółć'), false)
end

T['applies the configured array cap to perspectives'] = function()
  Config.setup({ limits = { max_array_items = 2 } })
  local args = valid_args()
  args.problem_type = 'analysis'
  args.depth = 'standard'
  args.branching_required = false
  args.branching_rationale = 'One bounded claim is being analyzed'
  resize_perspectives(args, 3)
  local chat = {}
  eq(Start.cmds[1]({ chat = chat }, args, {}).data.code, 'frame_incomplete')
  resize_perspectives(args, 2)
  eq(Start.cmds[1]({ chat = chat }, args, {}).status, 'success')
end

T['retires evidence when revision removes its perspective'] = function()
  local chat = {}
  Start.cmds[1]({ chat = chat }, valid_args(), {})
  local workspace = State.get(chat)
  local evidence = State.add(workspace, 'evidence', { perspective = 'operations' })
  local revised = valid_args()
  revised.perspectives = { revised.perspectives[1], { name = 'security', purpose = 'Find trust failures' } }
  local result = Protocol.call('revise', chat, revised, nil)
  eq(result.status, 'success')
  eq(State.find(workspace, evidence.id).status, 'superseded')
end

T['retires evidence when revision removes its addressed unknown'] = function()
  local chat = {}
  Start.cmds[1]({ chat = chat }, valid_args(), {})
  local workspace = State.get(chat)
  local evidence = State.add(workspace, 'evidence', {
    perspective = 'correctness',
    addresses_unknowns = { 'Expected write rate' },
  })
  local revised = valid_args()
  revised.unknowns = {}
  eq(Protocol.call('revise', chat, revised, nil).status, 'success')
  eq(State.find(workspace, evidence.id).status, 'superseded')
end

T['replace starts a fresh sequenced workspace'] = function()
  local chat = {}
  Start.cmds[1]({ chat = chat }, valid_args(), {})
  local result = Protocol.call('replace', chat, valid_args(), nil)
  eq(result.status, 'success')
  eq(result.data.workspace_id, 'W2')
  eq(result.data.artifact.id, 'F1')
end

T['replace requires an existing workspace'] = function()
  local chat = {}
  local result = Protocol.call('replace', chat, valid_args(), nil)
  eq(result.data.code, 'transition_invalid')
  eq(result.data.next_action.tool, 'reasoning_start')
  eq(result.data.diagnostic, {
    path = 'tool',
    constraint = 'authoritative_transition',
    expected = 'reasoning_start',
    actual = 'reasoning_replace',
  })
end

T['advertises perspective lower bounds without caching the configured maximum'] = function()
  local properties = Start.schema['function'].parameters.properties
  eq(
    properties.depth.description,
    'Protocol depth. Deep requires a root decomposition, two perspectives, and a full review.'
  )
  eq(properties.perspectives.minItems, 1)
  eq(properties.perspectives.maxItems, nil)
  eq(
    properties.perspectives.description,
    'Analytical viewpoints evidence must cover. Deep frames require at least two.'
  )
end

T['revision retires every downstream artifact before rebuilding'] = function()
  local chat = {}
  local started = Start.cmds[1]({ chat = chat }, valid_args(), {})
  local workspace = State.get(chat)
  local old_frame = workspace.frame_id
  local downstream = {}
  for _, kind in ipairs({ 'evidence', 'branch', 'option', 'review', 'synthesis' }) do
    local artifact = State.add(workspace, kind, { frame_id = old_frame })
    table.insert(downstream, artifact.id)
  end

  local revised = valid_args()
  revised.objective = 'Explain the corrected failure'
  revised.depth = 'standard'
  revised.perspectives = { { name = 'operations', purpose = 'Check the corrected lifecycle' } }
  local result = Protocol.call('revise', chat, revised, 'active')

  eq(started.status, 'success')
  eq(result.status, 'success')
  eq(State.find(workspace, old_frame).status, 'superseded')
  for _, id in ipairs(downstream) do
    eq(State.find(workspace, id).status, 'superseded')
  end
  eq(State.find(workspace, workspace.frame_id).status, 'active')
end

T['amend adds work without retiring anything'] = function()
  local chat = {}
  Start.cmds[1]({ chat = chat }, valid_args(), {})
  local workspace = State.get(chat)
  local old_frame = workspace.frame_id
  local downstream = {}
  for _, entry in ipairs({
    { 'evidence', { perspective = 'correctness', addresses_unknowns = {} } },
    { 'branch', { option_ids = {} } },
    { 'option', { evidence_ids = {}, predictions = {} } },
    { 'review', { mode = 'full', target_ids = {}, verdicts = {}, stress_tests = {}, contradiction_resolutions = {} } },
    {
      'synthesis',
      {
        mode = 'checkpoint',
        selected_option_ids = {},
        support_ids = {},
        review_ids = {},
        criterion_results = {},
      },
    },
  }) do
    local data = vim.tbl_extend('force', { frame_id = old_frame }, entry[2])
    table.insert(downstream, State.add(workspace, entry[1], data).id)
  end

  local result = Protocol.call(
    'amend',
    chat,
    amend_args({
      add_unknowns = { 'Peak restart frequency' },
      add_success_criteria = { 'Recovers within one minute' },
      add_constraints = { 'Single node only' },
      add_perspectives = { { name = 'performance', purpose = 'Find latency failures' } },
      require_temporal = true,
      branching_rationale = 'Several storage strategies remain viable',
    }),
    'active'
  )

  eq(result.status, 'success')
  local amended = State.find(workspace, workspace.frame_id)
  eq(amended.data.objective, 'Choose a durable cache design')
  eq(amended.data.constraints, { 'No external service', 'Single node only' })
  eq(amended.data.success_criteria, { 'Survives process restart', 'Bounded memory', 'Recovers within one minute' })
  eq(amended.data.unknowns, { 'Expected write rate', 'Peak restart frequency' })
  eq(#amended.data.perspectives, 3)
  eq(amended.data.temporal_required, true)
  eq(amended.data.branching_rationale, 'Several storage strategies remain viable')
  eq(State.find(workspace, old_frame).status, 'superseded')
  eq(workspace.frame_lineage, { old_frame, workspace.frame_id })
  eq(State.in_lineage(workspace, old_frame), true)
  for _, id in ipairs(downstream) do
    eq(State.find(workspace, id).status, 'active')
  end
end

T['amend keeps framed requirements that its arguments cannot lower'] = function()
  local chat = {}
  local args = valid_args()
  args.temporal_required = true
  Start.cmds[1]({ chat = chat }, args, {})
  local workspace = State.get(chat)

  eq(Protocol.call('amend', chat, amend_args({ add_constraints = { 'Single node only' } }), 'active').status, 'success')

  local amended = State.find(workspace, workspace.frame_id)
  eq(amended.data.temporal_required, true)
  eq(amended.data.branching_required, true)
  eq(amended.data.branching_rationale, 'Several storage strategies are viable')
end

T['amend ignores a perspective name the frame already declares'] = function()
  local chat = {}
  Start.cmds[1]({ chat = chat }, valid_args(), {})
  local workspace = State.get(chat)

  local result = Protocol.call(
    'amend',
    chat,
    amend_args({
      add_unknowns = { 'Peak restart frequency' },
      add_perspectives = { { name = ' CORRECTNESS ', purpose = 'A different purpose' } },
    }),
    'active'
  )

  eq(result.status, 'success')
  local perspectives = State.find(workspace, workspace.frame_id).data.perspectives
  eq(#perspectives, 2)
  eq(perspectives[1].purpose, 'Find invalidation failures')
end

T['amend rejects an amendment that adds nothing'] = function()
  local chat = {}
  Start.cmds[1]({ chat = chat }, valid_args(), {})
  local workspace = State.get(chat)
  local before = {
    revision = workspace.revision,
    frame_id = workspace.frame_id,
    artifact_order = vim.deepcopy(workspace.artifact_order),
    next_sequence = vim.deepcopy(workspace.next_sequence),
  }

  local result = Protocol.call('amend', chat, amend_args(), 'active')

  eq(result.status, 'error')
  eq(result.data.code, 'amend_invalid')
  eq(result.data.committed, false)
  eq(result.data.diagnostic, {
    path = 'add_unknowns',
    constraint = 'amend_adds_something',
    expected = true,
    actual = false,
  })
  eq(result.data.next_action.tool, 'reasoning_amend')
  eq(workspace.revision, before.revision)
  eq(workspace.frame_id, before.frame_id)
  eq(workspace.artifact_order, before.artifact_order)
  eq(workspace.next_sequence, before.next_sequence)
end

T['amend rejects malformed additions before touching the workspace'] = function()
  local chat = {}
  Start.cmds[1]({ chat = chat }, valid_args(), {})
  local workspace = State.get(chat)
  local before = vim.deepcopy(workspace.artifact_order)

  local duplicate = Protocol.call(
    'amend',
    chat,
    amend_args({ add_unknowns = { 'Peak restart frequency', ' peak   RESTART frequency ' } }),
    'active'
  )
  eq(duplicate.data.code, 'amend_invalid')
  eq(duplicate.data.diagnostic.path, 'add_unknowns[2]')

  local malformed =
    Protocol.call('amend', chat, amend_args({ add_perspectives = { { name = 'performance' } } }), 'active')
  eq(malformed.data.code, 'amend_invalid')
  eq(malformed.data.diagnostic, {
    path = 'add_perspectives[1].purpose',
    constraint = 'required',
    expected = 'string',
    actual = 'missing',
  })
  eq(workspace.artifact_order, before)
end

T['seeds one provisional sub-question per newly framed unknown'] = function()
  local chat = {}
  Start.cmds[1]({ chat = chat }, valid_args(), {})
  local workspace = State.get(chat)
  eq(State.find(workspace, 'Q1').data.text, 'Expected write rate')
  eq(State.find(workspace, 'Q1').data.provisional, true)
  eq(State.find(workspace, 'Q1').data.parent_id, workspace.frame_id)
  eq(Tree.root_split(workspace).child_ids, { 'Q1' })

  local amended = amend_args({ add_unknowns = { 'Peak restart frequency' } })
  eq(Protocol.call('amend', chat, amended, 'active').status, 'success')
  eq(State.find(workspace, 'Q2').data.text, 'Peak restart frequency')
  eq(Tree.root_split(workspace).child_ids, { 'Q1', 'Q2' })
  eq(State.find(workspace, 'Q1').status, 'active')

  eq(Protocol.call('amend', chat, amended, 'active').data.code, 'amend_invalid')
  eq(State.find(workspace, 'Q3'), nil)
end

T['reseeds unknowns when a revision retires the old tree'] = function()
  local chat = {}
  Start.cmds[1]({ chat = chat }, valid_args(), {})
  local workspace = State.get(chat)
  local revised = valid_args()
  revised.objective = 'Explain the corrected failure'
  eq(Protocol.call('revise', chat, revised, 'active').status, 'success')
  eq(State.find(workspace, 'Q1').status, 'superseded')
  eq(State.find(workspace, 'Q2').data.text, 'Expected write rate')
  eq(Tree.root_split(workspace).child_ids, { 'Q2' })
end

T['amend requires an existing workspace and yields to armed and reframing phases'] = function()
  local chat = {}
  local missing = Protocol.call('amend', chat, amend_args({ add_constraints = { 'Single node only' } }), nil)
  eq(missing.data.code, 'workspace_missing')
  eq(missing.data.next_action.tool, 'reasoning_start')
  eq(missing.data.diagnostic, {
    path = 'workspace',
    constraint = 'workspace_exists',
    expected = true,
    actual = false,
  })
  eq(State.get(chat), nil)

  local armed = Protocol.call('amend', chat, amend_args({ add_constraints = { 'Single node only' } }), 'armed')
  eq(armed.data.code, 'transition_invalid')
  eq(State.get(chat), nil)

  Start.cmds[1]({ chat = chat }, valid_args(), {})
  local blocked = Protocol.call('amend', chat, amend_args({ add_constraints = { 'Single node only' } }), 'reframing')
  eq(blocked.data.code, 'transition_invalid')
  eq(blocked.data.next_action.tool, 'reasoning_revise')
end

T['revision resets the frame lineage'] = function()
  local chat = {}
  Start.cmds[1]({ chat = chat }, valid_args(), {})
  local workspace = State.get(chat)
  Protocol.call('amend', chat, amend_args({ add_constraints = { 'Single node only' } }), 'active')
  local amended = workspace.frame_id

  local revised = valid_args()
  revised.objective = 'Explain the corrected failure'
  eq(Protocol.call('revise', chat, revised, 'active').status, 'success')
  eq(workspace.frame_lineage, { workspace.frame_id })
  eq(State.in_lineage(workspace, amended), false)
end

T['reports ordered armed and reframing diagnostics without consuming frame IDs'] = function()
  local armed_chat = {}
  local malformed_start = valid_args()
  malformed_start.objective = '   '
  local armed = Protocol.call('start', armed_chat, malformed_start, 'armed')
  eq(armed.data.committed, false)
  eq(armed.data.diagnostic, {
    path = 'objective',
    constraint = 'min_chars',
    expected = 1,
    actual = 3,
  })
  eq(armed.data.next_action, Protocol.transition(nil, 'armed'))
  eq(State.get(armed_chat), nil)
  eq(Protocol.call('start', armed_chat, valid_args(), 'armed').data.artifact.id, 'F1')

  local workspace = State.get(armed_chat)
  local before = {
    revision = workspace.revision,
    artifact_order = vim.deepcopy(workspace.artifact_order),
    next_sequence = vim.deepcopy(workspace.next_sequence),
  }
  local malformed_revision = valid_args()
  malformed_revision.objective = nil
  local reframing = Protocol.call('revise', armed_chat, malformed_revision, 'reframing')
  eq(reframing.data.committed, false)
  eq(reframing.data.diagnostic, {
    path = 'objective',
    constraint = 'required',
    expected = 'string',
    actual = 'missing',
  })
  eq(reframing.data.next_action, Protocol.transition(workspace, 'reframing'))
  eq({
    revision = workspace.revision,
    artifact_order = workspace.artifact_order,
    next_sequence = workspace.next_sequence,
  }, before)
  eq(Protocol.call('revise', armed_chat, valid_args(), 'reframing').data.artifact.id, 'F2')
end

return T
