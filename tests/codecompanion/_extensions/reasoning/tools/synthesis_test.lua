local Config = require('codecompanion._extensions.reasoning.config')
local Evidence = require('codecompanion._extensions.reasoning.tools.evidence')
local Frame = require('codecompanion._extensions.reasoning.tools.frame')
local Options = require('codecompanion._extensions.reasoning.tools.options')
local Protocol = require('codecompanion._extensions.reasoning.protocol')
local Tree = require('codecompanion._extensions.reasoning.tree')
local TreeFixture = require('support.tree_fixture')
local Render = require('codecompanion._extensions.reasoning.render')
local Review = require('codecompanion._extensions.reasoning.tools.review')
local State = require('codecompanion._extensions.reasoning.state')
local Synthesis = require('codecompanion._extensions.reasoning.tools.synthesis')

local original_render = Render.render
local original_prepare_final = State.prepare_final

local T = MiniTest.new_set({
  hooks = {
    pre_case = function()
      Config.setup()
      State._reset()
    end,
    post_case = function()
      Render.render = original_render
      State.prepare_final = original_prepare_final
    end,
  },
})
local eq = MiniTest.expect.equality

local function contains(values, expected)
  eq(vim.tbl_contains(values, expected), true)
end

local function add_frame(chat, depth, branching, unknowns, temporal_required)
  local result = Frame.cmds[1]({ chat = chat }, {
    action = 'start',
    objective = 'Choose a durable cache design',
    problem_type = branching and 'design' or 'analysis',
    depth = depth,
    constraints = { 'No external service' },
    success_criteria = { 'Survives process restart', 'Bounded memory' },
    unknowns = unknowns or {},
    perspectives = depth == 'deep' and {
      { name = 'correctness', purpose = 'Find recovery failures' },
      { name = 'operations', purpose = 'Find lifecycle failures' },
    } or { { name = 'correctness', purpose = 'Find recovery failures' } },
    temporal_required = temporal_required == true,
    branching_required = branching,
    branching_rationale = branching and 'Competing designs exist' or 'This analysis tests one claim',
  }, {})
  if result.status == 'success' then
    eq(TreeFixture.satisfy(chat), true)
  end
  return result
end

local function revise_frame(chat, temporal_required)
  local current = State.find(State.get(chat), State.get(chat).frame_id)
  local args = vim.deepcopy(current.data)
  args.action = 'revise'
  args.objective = current.data.objective .. ' under the revised frame'
  args.temporal_required = temporal_required == true
  return Frame.cmds[1]({ chat = chat }, args, {})
end

local function add_evidence(chat, statement, perspective, contradicts, addresses_unknowns)
  return Evidence.cmds[1]({ chat = chat }, {
    items = {
      {
        kind = 'observation',
        statement = statement,
        source = 'tests/recovery.lua:10',
        confidence = 'high',
        falsifier = 'A controlled test produces the opposite result',
        perspective = perspective,
        addresses_unknowns = addresses_unknowns or {},
        supports = {},
        contradicts = contradicts or {},
        qualifies = {},
        supersedes_id = '',
      },
    },
  }, {})
end

local function add_options(chat, supported, supersedes_branch_id, evidence_ids)
  local ids = supported == false and {} or vim.deepcopy(evidence_ids or { 'E1' })
  local secondary_ids = vim.deepcopy(evidence_ids or { 'E1' })
  return Options.cmds[1]({ chat = chat }, {
    question = 'Which design?',
    branch_type = 'solution',
    criteria = { 'Durability', 'Memory' },
    supersedes_branch_id = supersedes_branch_id or '',
    options = {
      {
        label = 'journal',
        summary = 'Append checksummed mutations',
        evidence_ids = ids,
        assumptions = { 'Disk writes work' },
        predictions = { 'Replay restores state' },
        benefits = { 'Durability' },
        costs = { 'Compaction' },
        risks = { 'Torn writes' },
        reversibility = 'moderate',
      },
      {
        label = 'snapshot',
        summary = 'Write atomic snapshots',
        evidence_ids = secondary_ids,
        assumptions = { 'State fits' },
        predictions = { 'Restart loads a snapshot' },
        benefits = { 'Simplicity' },
        costs = { 'Full writes' },
        risks = { 'Stale state' },
        reversibility = 'easy',
      },
    },
  }, {})
end

local function add_review(chat, revise, target_ids, temporal, defense_evidence_ids)
  target_ids = target_ids or { 'O1', 'E1' }
  local verdicts = {}
  for _, id in ipairs(target_ids) do
    table.insert(verdicts, {
      target_id = id,
      status = revise and id == target_ids[1] and 'revise' or 'keep',
      revision_instruction = revise and id == target_ids[1] and 'Correct the selected artifact' or '',
    })
  end
  return Review.cmds[1]({ chat = chat }, {
    mode = 'full',
    target_ids = target_ids,
    defense = {
      summary = 'Restart evidence supports the journal',
      evidence_ids = vim.deepcopy(defense_evidence_ids or { 'E1' }),
    },
    challenges = {
      {
        kind = 'counterexample',
        summary = 'A torn write can break replay',
        target_ids = vim.deepcopy(target_ids),
        falsifier = 'Truncation recovery succeeds for every partial suffix',
      },
      {
        kind = 'hidden_assumption',
        summary = 'Atomic filesystem behavior is assumed',
        target_ids = { target_ids[1] },
        falsifier = 'Filesystem documentation guarantees the operation',
      },
    },
    blind_spots = { 'Disk exhaustion' },
    stress_tests = temporal and {
      {
        scenario = 'Three restart and compaction cycles',
        prediction = 'Recovery remains complete',
        failure_signal = 'A committed key disappears',
      },
    } or {},
    verdicts = verdicts,
    contradiction_resolutions = {},
    structural_tradeoffs = {},
  }, {})
end

local function resolve_contradiction(chat, evidence_id)
  return Review.cmds[1]({ chat = chat }, {
    mode = 'full',
    target_ids = { 'E1', 'E2' },
    defense = { summary = 'Both observations apply to different scopes', evidence_ids = { evidence_id } },
    challenges = {
      {
        kind = 'counterexample',
        summary = 'The scopes may still overlap',
        target_ids = { 'E1' },
        falsifier = 'A controlled trace shows the scopes never overlap',
      },
      {
        kind = 'hidden_assumption',
        summary = 'Scope separation is assumed',
        target_ids = { 'E2' },
        falsifier = 'The source explicitly defines separate scopes',
      },
    },
    blind_spots = { 'A third runtime mode may exist' },
    stress_tests = {},
    verdicts = {
      { target_id = 'E1', status = 'keep', revision_instruction = '' },
      { target_id = 'E2', status = 'keep', revision_instruction = '' },
    },
    contradiction_resolutions = {
      {
        left_id = 'E1',
        right_id = 'E2',
        resolution = 'The claims are retained as scope-qualified observations',
        evidence_ids = { evidence_id },
      },
    },
    structural_tradeoffs = {},
  }, {})
end

local function final_args()
  return {
    mode = 'final',
    conclusion = 'Use a journal with checksummed records and truncation recovery',
    selected_option_ids = { 'O1' },
    support_ids = { 'E1', 'E2' },
    review_ids = { 'R1' },
    criterion_results = {
      {
        criterion = 'Survives process restart',
        status = 'passed',
        evidence_ids = { 'E1' },
        explanation = 'Recovery test replays committed records',
      },
      {
        criterion = 'Bounded memory',
        status = 'passed',
        evidence_ids = { 'E2' },
        explanation = 'Compaction bounds retained entries',
      },
    },
    tradeoffs = { 'More write amplification for deterministic recovery' },
    uncertainties = { 'Disk-full behavior needs platform testing' },
    blind_spots = { 'Network filesystems were not evaluated' },
    next_actions = { 'Implement the journal behind the cache interface' },
    confidence = 'medium',
  }
end

local function deep_workspace(opts)
  opts = opts or {}
  local chat = {}
  eq(add_frame(chat, 'deep', true).status, 'success')
  eq(add_evidence(chat, 'Restart loses process-local state', 'correctness').status, 'success')
  if not opts.one_perspective then
    eq(
      add_evidence(chat, 'Compaction bounds retained entries', 'operations', opts.contradiction and { 'E1' } or {}).status,
      'success'
    )
  end
  if not opts.no_branches then
    eq(add_options(chat, true).status, 'success')
    if opts.unsupported_option then
      State.find(State.get(chat), 'O1').data.evidence_ids = {}
    end
  end
  if not opts.no_review and not opts.no_branches then
    eq(add_review(chat, opts.open_revision).status, 'success')
  end
  return chat
end

T['checkpoint succeeds and reports the highest-priority gate'] = function()
  local chat = {}
  eq(add_frame(chat, 'deep', true).status, 'success')
  local args = final_args()
  args.mode = 'checkpoint'
  args.selected_option_ids, args.support_ids, args.review_ids, args.criterion_results = {}, {}, {}, {}
  local result = Synthesis.cmds[1]({ chat = chat }, args, {})
  eq(result.status, 'success')
  contains(result.data.unmet_gates, 'evidence_missing')
  eq(result.data.next_action.tool, 'reasoning_evidence')
end

T['deep final requires cited two-perspective evidence'] = function()
  local args = final_args()
  args.support_ids = { 'E1' }
  args.criterion_results[2].evidence_ids = { 'E1' }
  local result = Synthesis.cmds[1]({ chat = deep_workspace() }, args, {})
  eq(result.data.code, 'synthesis_gate_failed')
  contains(result.data.unmet_gates, 'perspective_coverage_missing')
end

T['deep final requires two-perspective evidence to exist'] = function()
  local args = final_args()
  args.support_ids = { 'E1' }
  args.criterion_results[2].evidence_ids = { 'E1' }
  local result = Synthesis.cmds[1]({ chat = deep_workspace({ one_perspective = true }) }, args, {})
  eq(result.data.code, 'synthesis_gate_failed')
  contains(result.data.unmet_gates, 'perspective_coverage_missing')
end

T['final reports every decomposition gate with its blockers'] = function()
  local chat = {}
  eq(
    Frame.cmds[1]({ chat = chat }, {
      action = 'start',
      objective = 'Choose a durable cache design',
      problem_type = 'analysis',
      depth = 'deep',
      constraints = { 'No external service' },
      success_criteria = { 'Survives process restart', 'Bounded memory' },
      unknowns = {},
      perspectives = {
        { name = 'correctness', purpose = 'Find recovery failures' },
        { name = 'operations', purpose = 'Find lifecycle failures' },
      },
      temporal_required = false,
      branching_required = false,
      branching_rationale = 'This analysis tests one claim',
    }, {}).status,
    'success'
  )
  local args = final_args()
  args.mode = 'checkpoint'
  args.selected_option_ids, args.support_ids, args.review_ids, args.criterion_results = {}, {}, {}, {}
  local blocked = Synthesis.cmds[1]({ chat = chat }, args, {})
  contains(blocked.data.unmet_gates, 'decomposition_missing')

  local workspace = State.get(chat)
  eq(
    Protocol.call(
      'question',
      chat,
      TreeFixture.args({
        parent_id = workspace.frame_id,
        child_questions = {
          {
            text = 'Does compaction bound the journal?',
            kind = 'sub_problem',
            acceptance_test = 'Observe compaction output',
            resolution_kind = 'observation',
          },
          {
            text = 'Does replay restore the last commit?',
            kind = 'sub_problem',
            acceptance_test = 'Observe the restored commit',
            resolution_kind = 'observation',
          },
        },
      }),
      nil
    ).status,
    'success'
  )
  eq(#Tree.open_leaves(workspace, {}), 2)
  local open_gate = Synthesis.cmds[1]({ chat = chat }, args, {})
  contains(open_gate.data.unmet_gates, 'open_questions')
  eq(vim.tbl_contains(open_gate.data.unmet_gates, 'decomposition_missing'), false)
  local gates, blockers = Protocol.final_gates(workspace, nil)
  contains(gates, 'open_questions')
  contains(blockers, 'Q1')
  contains(blockers, 'Q2')
end

T['final reopens a leaf whose closure evidence is retracted'] = function()
  local chat = {}
  eq(
    Frame.cmds[1]({ chat = chat }, {
      action = 'start',
      objective = 'Choose a durable cache design',
      problem_type = 'analysis',
      depth = 'standard',
      constraints = { 'No external service' },
      success_criteria = { 'Survives process restart', 'Bounded memory' },
      unknowns = {},
      perspectives = { { name = 'correctness', purpose = 'Find recovery failures' } },
      temporal_required = false,
      branching_required = false,
      branching_rationale = 'This analysis tests one claim',
    }, {}).status,
    'success'
  )
  eq(add_evidence(chat, 'Restart loses process-local state', 'correctness').status, 'success')
  local workspace = State.get(chat)
  eq(
    Protocol.call(
      'question',
      chat,
      TreeFixture.args({
        parent_id = workspace.frame_id,
        child_questions = {
          {
            text = 'Does the journal replay?',
            kind = 'sub_problem',
            acceptance_test = 'Observe a replay',
            resolution_kind = 'observation',
          },
          {
            text = 'Does the snapshot load?',
            kind = 'sub_problem',
            acceptance_test = 'Observe a load',
            resolution_kind = 'observation',
          },
        },
      }),
      nil
    ).status,
    'success'
  )
  for _, id in ipairs({ 'Q1', 'Q2' }) do
    eq(
      Protocol.call(
        'question',
        chat,
        TreeFixture.args({
          action = 'answer',
          question_id = id,
          answer = 'Closed by the recorded observation',
          evidence_ids = { 'E1' },
        }),
        nil
      ).status,
      'success'
    )
  end
  local args = final_args()
  args.selected_option_ids, args.review_ids = {}, {}
  args.support_ids = { 'E1' }
  args.criterion_results[1].evidence_ids = { 'E1' }
  args.criterion_results[2].evidence_ids = { 'E1' }
  eq(Synthesis.cmds[1]({ chat = chat }, args, {}).status, 'success')

  State.retract(workspace, 'E1')
  local gates = Protocol.final_gates(workspace, nil)
  contains(gates, 'closure_unsupported')
  contains(gates, 'open_questions')
end

T['final requires evidence coverage for framed unknowns'] = function()
  local chat = {}
  eq(add_frame(chat, 'standard', false, { 'Expected write rate' }).status, 'success')
  eq(add_evidence(chat, 'Restart loses process-local state', 'correctness').status, 'success')
  local args = final_args()
  args.selected_option_ids, args.review_ids = {}, {}
  args.support_ids = { 'E1' }
  args.criterion_results[2].evidence_ids = { 'E1' }
  contains(Synthesis.cmds[1]({ chat = chat }, args, {}).data.unmet_gates, 'unknown_coverage_missing')

  eq(add_evidence(chat, 'Write rate is bounded', 'correctness', {}, { 'Expected write rate' }).status, 'success')
  args.support_ids = { 'E1', 'E2' }
  args.criterion_results[2].evidence_ids = { 'E2' }
  eq(Synthesis.cmds[1]({ chat = chat }, args, {}).status, 'success')

  State.retract(State.get(chat), 'E2')
  args.support_ids = { 'E1' }
  args.criterion_results[2].evidence_ids = { 'E1' }
  contains(Synthesis.cmds[1]({ chat = chat }, args, {}).data.unmet_gates, 'unknown_coverage_missing')
end

T['final requires branches when the frame requires them'] = function()
  local args = final_args()
  args.selected_option_ids = {}
  args.review_ids = {}
  local result = Synthesis.cmds[1]({ chat = deep_workspace({ no_branches = true, no_review = true }) }, args, {})
  contains(result.data.unmet_gates, 'branches_missing')
end

T['deep final requires a full review of selected support'] = function()
  local args = final_args()
  args.review_ids = {}
  local result = Synthesis.cmds[1]({ chat = deep_workspace({ no_review = true }) }, args, {})
  contains(result.data.unmet_gates, 'full_review_missing')

  local existing = Synthesis.cmds[1]({ chat = deep_workspace() }, args, {})
  contains(existing.data.unmet_gates, 'full_review_missing')
  eq(existing.data.artifact_ids, { 'R1' })
  eq(existing.data.next_action.tool, 'reasoning_synthesis')
end

T['final blocks open revisions and unresolved contradictions'] = function()
  local revised = Synthesis.cmds[1]({ chat = deep_workspace({ open_revision = true }) }, final_args(), {})
  contains(revised.data.unmet_gates, 'revision_unresolved')
  eq(revised.data.artifact_ids, { 'O1' })
  local contradicted = Synthesis.cmds[1]({ chat = deep_workspace({ contradiction = true }) }, final_args(), {})
  contains(contradicted.data.unmet_gates, 'contradiction_unresolved')
  eq(contradicted.data.artifact_ids, { 'E1', 'E2' })
end

T['frame and selected branch revisions cannot be bypassed by option selection'] = function()
  for _, case in ipairs({
    { target_id = 'F1', tool = 'reasoning_frame' },
    { target_id = 'B1', tool = 'reasoning_options' },
  }) do
    State._reset()
    local chat = deep_workspace()
    eq(add_review(chat, true, { case.target_id }).status, 'success')
    local result = Synthesis.cmds[1]({ chat = chat }, final_args(), {})
    contains(result.data.unmet_gates, 'revision_unresolved')
    eq(result.data.artifact_ids, { case.target_id })
    eq(result.data.next_action.tool, case.tool)
  end
end

T['final revalidates cited contradiction resolutions and their evidence'] = function()
  local chat = deep_workspace({ contradiction = true })
  eq(add_evidence(chat, 'The claims refer to distinct runtime scopes', 'correctness').status, 'success')
  eq(resolve_contradiction(chat, 'E3').status, 'success')
  local args = final_args()
  local omitted = Synthesis.cmds[1]({ chat = chat }, args, {})
  contains(omitted.data.unmet_gates, 'contradiction_unresolved')
  eq(omitted.data.artifact_ids, { 'E1', 'E2', 'R2' })
  eq(omitted.data.next_action.tool, 'reasoning_synthesis')

  args.review_ids = { 'R1', 'R2' }
  eq(Synthesis.cmds[1]({ chat = chat }, args, {}).status, 'success')

  State.retract(State.get(chat), 'E3')
  contains(Synthesis.cmds[1]({ chat = chat }, args, {}).data.unmet_gates, 'contradiction_unresolved')
end

T['deep final ignores revisions unrelated to selected support'] = function()
  local chat = deep_workspace()
  eq(add_review(chat, true, { 'O2' }).status, 'success')
  local result = Synthesis.cmds[1]({ chat = chat }, final_args(), {})
  eq(result.status, 'success')
end

T['final requires exact passing criterion coverage'] = function()
  local missing = final_args()
  missing.criterion_results[2] = nil
  contains(
    Synthesis.cmds[1]({ chat = deep_workspace() }, missing, {}).data.unmet_gates,
    'criterion_coverage_incomplete'
  )
  local duplicate = final_args()
  duplicate.criterion_results[2].criterion = duplicate.criterion_results[1].criterion
  contains(
    Synthesis.cmds[1]({ chat = deep_workspace() }, duplicate, {}).data.unmet_gates,
    'criterion_coverage_incomplete'
  )
  local failed = final_args()
  failed.criterion_results[2].status = 'failed'
  contains(Synthesis.cmds[1]({ chat = deep_workspace() }, failed, {}).data.unmet_gates, 'criterion_not_verified')
  local pending = final_args()
  pending.criterion_results[2].status = 'pending'
  contains(Synthesis.cmds[1]({ chat = deep_workspace() }, pending, {}).data.unmet_gates, 'criterion_not_verified')
end

T['accepts explained not-applicable criteria and rejects empty explanations'] = function()
  local args = final_args()
  args.criterion_results[2].status = 'not_applicable'
  args.criterion_results[2].evidence_ids = {}
  args.criterion_results[2].explanation = 'The bounded-memory criterion is external to this conceptual comparison'
  eq(Synthesis.cmds[1]({ chat = deep_workspace() }, args, {}).status, 'success')

  local invalid = final_args()
  invalid.criterion_results[2].status = 'not_applicable'
  invalid.criterion_results[2].evidence_ids = {}
  invalid.criterion_results[2].explanation = '   '
  eq(Synthesis.cmds[1]({ chat = deep_workspace() }, invalid, {}).data.code, 'synthesis_invalid')
end

T['rejects well-formed references of the wrong artifact kind'] = function()
  local selected = final_args()
  selected.selected_option_ids = { 'E1' }
  eq(Synthesis.cmds[1]({ chat = deep_workspace() }, selected, {}).data.code, 'invalid_reference')
  local support = final_args()
  support.support_ids = { 'O1' }
  eq(Synthesis.cmds[1]({ chat = deep_workspace() }, support, {}).data.code, 'invalid_reference')
  local reviews = final_args()
  reviews.review_ids = { 'O1' }
  eq(Synthesis.cmds[1]({ chat = deep_workspace() }, reviews, {}).data.code, 'invalid_reference')
end

T['reports typed synthesis references without consuming synthesis IDs'] = function()
  local chat = deep_workspace()
  local workspace = State.get(chat)
  local before = {
    revision = workspace.revision,
    artifact_order = vim.deepcopy(workspace.artifact_order),
    next_sequence = vim.deepcopy(workspace.next_sequence),
  }
  local args = final_args()
  args.support_ids = { 'O1' }
  local result = Protocol.call('synthesis', chat, args, 'active')

  eq(result.data.committed, false)
  eq(result.data.diagnostic, {
    path = 'support_ids[1]',
    constraint = 'artifact_kind',
    expected = 'evidence',
    actual = 'O1',
  })
  eq(result.data.next_action, Protocol.transition(workspace, 'active'))
  eq({
    revision = workspace.revision,
    artifact_order = workspace.artifact_order,
    next_sequence = workspace.next_sequence,
  }, before)
  eq(Protocol.call('synthesis', chat, final_args(), 'active').data.artifact.id, 'S1')
end

T['final rejects a selected option without active evidence'] = function()
  local result = Synthesis.cmds[1]({ chat = deep_workspace({ unsupported_option = true }) }, final_args(), {})
  contains(result.data.unmet_gates, 'selected_option_unsupported')
end

T['deep final succeeds after every gate is met'] = function()
  local result = Synthesis.cmds[1]({ chat = deep_workspace() }, final_args(), {})
  eq(result.status, 'success')
  eq(result.data.artifact.id, 'S1')
  eq(result.data.artifact.data.frame_id, 'F1')
  eq(result.data.unmet_gates, {})
  eq(result.data.next_action, {
    tool = 'none',
    reason = 'Final synthesis accepted; no further model action is permitted',
  })
  eq(result.data.artifact.relations.supports, { 'E1', 'E2' })
  eq(result.data.artifact.relations.depends_on, { 'F1', 'O1', 'R1' })
end

T['controlled final prepares rendered synthesis without allocating state'] = function()
  local chat = deep_workspace()
  local workspace = State.get(chat)
  local before = {
    revision = workspace.revision,
    sequence = workspace.next_sequence.synthesis,
    count = workspace.counts_by_kind.synthesis,
    order = vim.deepcopy(workspace.artifact_order),
  }

  local result = Protocol.call('synthesis', chat, final_args(), 'active')

  eq(result.status, 'success')
  eq(result.data.artifact.id, 'S1')
  eq(result.data._reasoning_final.stage.candidate.id, 'S1')
  eq(result.data._reasoning_final.stage.candidate.relations.supports, { 'E1', 'E2' })
  eq(result.data._reasoning_final.stage.candidate.relations.depends_on, { 'F1', 'O1', 'R1' })
  eq(result.data._reasoning_final.stage.candidate.relations.supersedes, {})
  eq(type(result.data._reasoning_final.markdown), 'string')
  eq(result.data.progress.synthesis, (before.count or 0) + 1)
  eq(workspace.revision, before.revision)
  eq(workspace.next_sequence.synthesis, before.sequence)
  eq(workspace.counts_by_kind.synthesis, before.count)
  eq(workspace.artifact_order, before.order)
  eq(State.find(workspace, 'S1'), nil)

  eq(State.discard_final(result.data._reasoning_final.stage), true)
  eq(workspace.revision, before.revision)
  eq(workspace.next_sequence.synthesis, before.sequence)
  eq(State.find(workspace, 'S1'), nil)
end

T['prepared final conflicts after workspace mutation and consumes no reserved ID'] = function()
  local chat = deep_workspace()
  local workspace = State.get(chat)
  local result = Protocol.call('synthesis', chat, final_args(), 'active')
  local stage = result.data._reasoning_final.stage
  State.retract(workspace, 'E2')

  local committed, code = State.commit_final(chat, stage)
  eq(committed, nil)
  eq(code, 'transaction_conflict')
  eq(stage.state, 'conflicted')
  eq(workspace.next_sequence.synthesis, nil)
  eq(State.find(workspace, 'S1'), nil)
end

T['standalone final reports a transaction conflict when rendering mutates workspace'] = function()
  local chat = deep_workspace()
  local workspace = State.get(chat)
  local captured_stage
  State.prepare_final = function(...)
    local stage, code = original_prepare_final(...)
    captured_stage = stage
    return stage, code
  end
  Render.render = function(render_workspace, candidate)
    local markdown = original_render(render_workspace, candidate)
    State.retract(render_workspace, 'E2')
    return markdown
  end

  local result = Protocol.call('synthesis', chat, final_args(), nil)

  eq(result.status, 'error')
  eq(result.data.code, 'transaction_conflict')
  eq(result.data.committed, false)
  eq(captured_stage.state, 'conflicted')
  eq(workspace.next_sequence.synthesis, nil)
  eq(State.find(workspace, 'S1'), nil)
end

T['renderer failures are stable and allocate no controlled or standalone final'] = function()
  for _, replacement in ipairs({
    function()
      error('fixture renderer failure')
    end,
    function()
      return nil
    end,
    function()
      return '   '
    end,
  }) do
    State._reset()
    Render.render = replacement
    for _, phase in ipairs({ 'active', false }) do
      local chat = deep_workspace()
      local workspace = State.get(chat)
      local before_revision = workspace.revision
      local captured_stage
      State.prepare_final = function(...)
        local stage, code = original_prepare_final(...)
        captured_stage = stage
        return stage, code
      end
      local result = Protocol.call('synthesis', chat, final_args(), phase == false and nil or phase)
      eq(result.status, 'error')
      eq(result.data.code, 'render_internal')
      eq(result.data.message, 'the deterministic final could not be rendered')
      eq(result.data.committed, false)
      eq(result.data._reasoning_final, nil)
      eq(captured_stage.state, 'discarded')
      eq(workspace.revision, before_revision)
      eq(workspace.next_sequence.synthesis, nil)
      eq(State.find(workspace, 'S1'), nil)
    end
  end
end

T['controlled checkpoint still commits immediately without a final stage'] = function()
  local chat = deep_workspace()
  local args = final_args()
  args.mode = 'checkpoint'
  local result = Protocol.call('synthesis', chat, args, 'active')

  eq(result.status, 'success')
  eq(result.data.artifact.id, 'S1')
  eq(result.data._reasoning_final, nil)
  eq(State.find(State.get(chat), 'S1').data.mode, 'checkpoint')
  eq(State.get(chat).counts_by_kind.synthesis, 1)
end

T['standalone final renders and commits without exposing its internal stage'] = function()
  local chat = deep_workspace()
  local result = Protocol.call('synthesis', chat, final_args(), nil)

  eq(result.status, 'success')
  eq(result.data.artifact.id, 'S1')
  eq(result.data._reasoning_final, nil)
  eq(State.find(State.get(chat), 'S1').data.conclusion, final_args().conclusion)
  eq(State.get(chat).counts_by_kind.synthesis, 1)
end

T['standard analysis succeeds with one perspective and no branch'] = function()
  local chat = {}
  eq(add_frame(chat, 'standard', false).status, 'success')
  eq(add_evidence(chat, 'Restart loses process-local state', 'correctness').status, 'success')
  local args = final_args()
  args.selected_option_ids, args.review_ids = {}, {}
  args.support_ids = { 'E1' }
  args.criterion_results[2].evidence_ids = { 'E1' }
  local result = Synthesis.cmds[1]({ chat = chat }, args, {})
  eq(result.status, 'success')
end

T['temporal final requires a cited stress-tested review'] = function()
  local chat = {}
  eq(add_frame(chat, 'standard', false, {}, true).status, 'success')
  eq(add_evidence(chat, 'Restart loses process-local state', 'correctness').status, 'success')
  local args = final_args()
  args.selected_option_ids, args.review_ids = {}, {}
  args.support_ids = { 'E1' }
  args.criterion_results[1].evidence_ids = { 'E1' }
  args.criterion_results[2].evidence_ids = { 'E1' }
  contains(Synthesis.cmds[1]({ chat = chat }, args, {}).data.unmet_gates, 'temporal_review_missing')

  eq(add_review(chat, false, { 'E1' }, true).status, 'success')
  args.review_ids = { 'R1' }
  eq(Synthesis.cmds[1]({ chat = chat }, args, {}).status, 'success')
end

T['a review without stress tests does not survive a temporal frame revision'] = function()
  local chat = {}
  eq(add_frame(chat, 'standard', false).status, 'success')
  eq(add_evidence(chat, 'Restart loses process-local state', 'correctness').status, 'success')
  eq(add_review(chat, false, { 'E1' }).status, 'success')
  eq(revise_frame(chat, true).status, 'success')
  eq(State.find(State.get(chat), 'E1').status, 'superseded')
  eq(State.find(State.get(chat), 'R1').status, 'superseded')
  eq(add_evidence(chat, 'Restart loses process-local state', 'correctness').status, 'success')
  local args = final_args()
  args.selected_option_ids = {}
  args.support_ids = { 'E2' }
  args.review_ids = {}
  args.criterion_results[1].evidence_ids = { 'E2' }
  args.criterion_results[2].evidence_ids = { 'E2' }
  contains(Synthesis.cmds[1]({ chat = chat }, args, {}).data.unmet_gates, 'temporal_review_missing')
end

T['standard final blocks a revision affecting cited support'] = function()
  local chat = {}
  eq(add_frame(chat, 'standard', false).status, 'success')
  eq(add_evidence(chat, 'Restart loses process-local state', 'correctness').status, 'success')
  eq(add_review(chat, true, { 'E1' }).status, 'success')
  local args = final_args()
  args.selected_option_ids = {}
  args.support_ids = { 'E1' }
  args.review_ids = { 'R1' }
  args.criterion_results[2].evidence_ids = { 'E1' }
  contains(Synthesis.cmds[1]({ chat = chat }, args, {}).data.unmet_gates, 'revision_unresolved')
end

T['standard final ignores a revision unrelated to cited support'] = function()
  local chat = {}
  eq(add_frame(chat, 'standard', false).status, 'success')
  eq(add_evidence(chat, 'Restart loses process-local state', 'correctness').status, 'success')
  eq(add_evidence(chat, 'Write rate is uncertain', 'correctness').status, 'success')
  eq(add_review(chat, true, { 'E2' }).status, 'success')
  local args = final_args()
  args.selected_option_ids = {}
  args.support_ids = { 'E1' }
  args.review_ids = { 'R1' }
  args.criterion_results[1].evidence_ids = { 'E1' }
  args.criterion_results[2].evidence_ids = { 'E1' }
  eq(Synthesis.cmds[1]({ chat = chat }, args, {}).status, 'success')
end

T['stale branches and reviews cannot satisfy a revised frame'] = function()
  local chat = deep_workspace()
  local revised = revise_frame(chat)
  eq(revised.status, 'success')
  eq(revised.data.next_action.tool, 'reasoning_question')
  eq(TreeFixture.satisfy(chat), true)
  local stale = Synthesis.cmds[1]({ chat = chat }, final_args(), {})
  eq(stale.data.code, 'inactive_reference')
  eq(State.find(State.get(chat), 'B1').status, 'superseded')
  eq(State.find(State.get(chat), 'R1').status, 'superseded')

  eq(add_evidence(chat, 'Restart loses process-local state', 'correctness').status, 'success')
  eq(add_evidence(chat, 'Compaction bounds retained entries', 'operations').status, 'success')
  eq(add_options(chat, true, nil, { 'E3' }).status, 'success')
  local args = final_args()
  args.selected_option_ids = { 'O3' }
  args.support_ids = { 'E3', 'E4' }
  args.review_ids = {}
  args.criterion_results[1].evidence_ids = { 'E3' }
  args.criterion_results[2].evidence_ids = { 'E4' }
  local old_review = Synthesis.cmds[1]({ chat = chat }, args, {})
  contains(old_review.data.unmet_gates, 'full_review_missing')

  eq(add_review(chat, false, { 'O3', 'E3' }, false, { 'E3' }).status, 'success')
  args.review_ids = { 'R2' }
  eq(Synthesis.cmds[1]({ chat = chat }, args, {}).status, 'success')
end

T['a review becomes stale when its supporting evidence is superseded'] = function()
  local chat = deep_workspace()
  eq(add_review(chat, false, { 'O2', 'E2' }).status, 'success')
  local replacement = {
    kind = 'observation',
    statement = 'Restart loses process-local state',
    source = 'tests/recovery_v2.lua:12',
    confidence = 'high',
    falsifier = 'A controlled restart retains process-local state',
    perspective = 'correctness',
    addresses_unknowns = {},
    supports = {},
    contradicts = {},
    qualifies = {},
    supersedes_id = 'E1',
  }
  eq(Evidence.cmds[1]({ chat = chat }, { items = { replacement } }, {}).status, 'success')
  local args = final_args()
  args.selected_option_ids = { 'O2' }
  args.support_ids = { 'E2', 'E3' }
  args.review_ids = { 'R2' }
  args.criterion_results[1].evidence_ids = { 'E3' }
  args.criterion_results[2].evidence_ids = { 'E2' }
  contains(Synthesis.cmds[1]({ chat = chat }, args, {}).data.unmet_gates, 'full_review_missing')
end

T['standard branch review must be relevant to the selected result'] = function()
  local chat = {}
  eq(add_frame(chat, 'standard', true).status, 'success')
  eq(add_evidence(chat, 'Restart loses process-local state', 'correctness').status, 'success')
  eq(add_options(chat, true).status, 'success')
  eq(add_review(chat, false, { 'O2' }).status, 'success')
  local args = final_args()
  args.support_ids = { 'E1' }
  args.review_ids = { 'R1' }
  args.criterion_results[1].evidence_ids = { 'E1' }
  args.criterion_results[2].evidence_ids = { 'E1' }
  contains(Synthesis.cmds[1]({ chat = chat }, args, {}).data.unmet_gates, 'review_missing')
end

T['final synthesis accepts intentional empty reflection arrays'] = function()
  for _, field in ipairs({ 'tradeoffs', 'uncertainties', 'blind_spots', 'next_actions' }) do
    local args = final_args()
    args[field] = {}
    eq(Synthesis.cmds[1]({ chat = deep_workspace() }, args, {}).status, 'success')
  end

  local checkpoint = final_args()
  checkpoint.mode = 'checkpoint'
  checkpoint.tradeoffs, checkpoint.uncertainties, checkpoint.blind_spots, checkpoint.next_actions = {}, {}, {}, {}
  eq(Synthesis.cmds[1]({ chat = deep_workspace() }, checkpoint, {}).status, 'success')
end

T['selected options require every cited evidence artifact to remain active'] = function()
  local chat = deep_workspace()
  eq(add_evidence(chat, 'Periodic compaction is observable', 'operations').status, 'success')
  local option = State.find(State.get(chat), 'O1')
  option.data.evidence_ids = { 'E1', 'E2' }
  State.retract(State.get(chat), 'E2')
  local args = final_args()
  args.support_ids = { 'E1', 'E3' }
  args.criterion_results[2].evidence_ids = { 'E3' }
  local result = Synthesis.cmds[1]({ chat = chat }, args, {})
  contains(result.data.unmet_gates, 'selected_option_unsupported')
  eq(result.data.next_action.tool, 'reasoning_options')
end

T['deep full review must target selected or supporting material'] = function()
  for _, target_id in ipairs({ 'F1', 'B1' }) do
    State._reset()
    local chat = deep_workspace({ no_review = true })
    eq(add_review(chat, false, { target_id }).status, 'success')
    local result = Synthesis.cmds[1]({ chat = chat }, final_args(), {})
    contains(result.data.unmet_gates, 'full_review_missing')
    eq(result.data.next_action.tool, 'reasoning_review')
  end
end

T['checkpoint review counts only when the checkpoint covers the final material'] = function()
  local early_chat = deep_workspace({ no_review = true })
  local early = final_args()
  early.mode = 'checkpoint'
  early.selected_option_ids, early.support_ids, early.review_ids, early.criterion_results = {}, {}, {}, {}
  eq(Synthesis.cmds[1]({ chat = early_chat }, early, {}).status, 'success')
  eq(add_review(early_chat, false, { 'S1' }).status, 'success')
  local early_final = final_args()
  early_final.review_ids = { 'R1' }
  local rejected = Synthesis.cmds[1]({ chat = early_chat }, early_final, {})
  contains(rejected.data.unmet_gates, 'full_review_missing')

  local matching_chat = deep_workspace({ no_review = true })
  local matching = final_args()
  matching.mode = 'checkpoint'
  matching.review_ids = {}
  eq(Synthesis.cmds[1]({ chat = matching_chat }, matching, {}).status, 'success')
  eq(add_review(matching_chat, false, { 'S1' }).status, 'success')
  local matching_final = final_args()
  matching_final.review_ids = { 'R1' }
  eq(Synthesis.cmds[1]({ chat = matching_chat }, matching_final, {}).status, 'success')
end

T['checkpoint revisions block only a final result covered by that checkpoint'] = function()
  local matching_chat = deep_workspace({ no_review = true })
  local matching = final_args()
  matching.mode = 'checkpoint'
  matching.review_ids = {}
  eq(Synthesis.cmds[1]({ chat = matching_chat }, matching, {}).status, 'success')
  eq(add_review(matching_chat, true, { 'S1' }).status, 'success')
  local matching_final = final_args()
  matching_final.review_ids = { 'R1' }
  contains(Synthesis.cmds[1]({ chat = matching_chat }, matching_final, {}).data.unmet_gates, 'revision_unresolved')

  local early_chat = deep_workspace({ no_review = true })
  local early = final_args()
  early.mode = 'checkpoint'
  early.selected_option_ids, early.support_ids, early.review_ids, early.criterion_results = {}, {}, {}, {}
  eq(Synthesis.cmds[1]({ chat = early_chat }, early, {}).status, 'success')
  eq(add_review(early_chat, true, { 'S1' }).status, 'success')
  eq(add_review(early_chat, false).status, 'success')
  local early_final = final_args()
  early_final.review_ids = { 'R2' }
  eq(Synthesis.cmds[1]({ chat = early_chat }, early_final, {}).status, 'success')
end

T['branch replacement invalidates an old option-only review immediately'] = function()
  local chat = deep_workspace({ no_review = true })
  eq(add_review(chat, false, { 'O1' }).status, 'success')
  local replacement = add_options(chat, true, 'B1')
  eq(replacement.status, 'success')
  contains(replacement.data.unmet_gates, 'full_review_missing')
  eq(replacement.data.next_action.tool, 'reasoning_review')
end

T['checkpoint replacement resolves multiple synthesis revisions deterministically'] = function()
  local chat = {}
  eq(add_frame(chat, 'standard', false).status, 'success')
  eq(add_evidence(chat, 'Restart loses process-local state', 'correctness').status, 'success')
  local checkpoint = final_args()
  checkpoint.mode = 'checkpoint'
  checkpoint.selected_option_ids, checkpoint.review_ids = {}, {}
  checkpoint.support_ids = { 'E1' }
  checkpoint.criterion_results[1].evidence_ids = { 'E1' }
  checkpoint.criterion_results[2].evidence_ids = { 'E1' }
  eq(Synthesis.cmds[1]({ chat = chat }, checkpoint, {}).status, 'success')
  eq(Synthesis.cmds[1]({ chat = chat }, checkpoint, {}).status, 'success')
  eq(add_review(chat, true, { 'S1' }).status, 'success')
  eq(add_review(chat, true, { 'S2' }).status, 'success')

  local result = Synthesis.cmds[1]({ chat = chat }, checkpoint, {})
  eq(result.status, 'success')
  eq(result.data.artifact.id, 'S3')
  eq(result.data.artifact.relations.supersedes, { 'S1', 'S2' })
  eq(State.find(State.get(chat), 'S1').status, 'superseded')
  eq(State.find(State.get(chat), 'S2').status, 'superseded')
end

T['rejects duplicate synthesis after an unchanged accepted final'] = function()
  local chat = deep_workspace()
  local accepted = Synthesis.cmds[1]({ chat = chat }, final_args(), {})
  eq(accepted.status, 'success')
  eq(accepted.data.next_action.tool, 'none')

  local duplicate = Synthesis.cmds[1]({ chat = chat }, final_args(), {})
  eq(duplicate.status, 'error')
  eq(duplicate.data.code, 'workspace_finalized')
  eq(duplicate.data.artifact_ids, { 'S1' })
  eq(duplicate.data.next_action.tool, 'none')
  eq(State.get(chat).counts_by_kind.synthesis, 1)
end

T['blocks every non-reframing tool after an accepted final'] = function()
  local chat = deep_workspace()
  eq(Synthesis.cmds[1]({ chat = chat }, final_args(), {}).status, 'success')

  for _, case in ipairs({
    { tool = Frame, args = { action = 'start' } },
    { tool = Evidence, args = {} },
    { tool = Options, args = {} },
    { tool = Review, args = {} },
    { tool = Synthesis, args = final_args() },
  }) do
    local result = case.tool.cmds[1]({ chat = chat }, case.args, {})
    eq(result.status, 'error')
    eq(result.data.code, 'workspace_finalized')
    eq(result.data.artifact_ids, { 'S1' })
    eq(result.data.next_action.tool, 'none')
  end
  eq(State.get(chat).counts_by_kind.synthesis, 1)
end

T['requires explicit frame revision or replacement to reopen a final'] = function()
  for _, action in ipairs({ 'revise', 'replace' }) do
    local chat = deep_workspace()
    eq(Synthesis.cmds[1]({ chat = chat }, final_args(), {}).status, 'success')
    local result = Frame.cmds[1]({ chat = chat }, {
      action = action,
      objective = 'Reconsider the durable cache after new user evidence',
      problem_type = 'design',
      depth = 'deep',
      constraints = { 'No external service' },
      success_criteria = { 'Survives process restart', 'Bounded memory' },
      unknowns = { 'Whether the new evidence changes recovery behavior' },
      perspectives = {
        { name = 'correctness', purpose = 'Re-evaluate recovery failures' },
        { name = 'operations', purpose = 'Re-evaluate lifecycle failures' },
      },
      temporal_required = false,
      branching_required = true,
      branching_rationale = 'New evidence may change the competing designs',
    }, {})
    eq(result.status, 'success')
    eq(result.data.artifact.kind, 'frame')

    local evidence = add_evidence(chat, 'New recovery evidence is available', 'correctness')
    eq(evidence.status, 'success')
  end
end

T['describes exact final references in the strict schema'] = function()
  local properties = Synthesis.schema['function'].parameters.properties
  eq(type(properties.selected_option_ids.description), 'string')
  eq(type(properties.support_ids.description), 'string')
  eq(type(properties.review_ids.description), 'string')
  eq(type(properties.criterion_results.description), 'string')
  eq(type(properties.criterion_results.items.properties.evidence_ids.description), 'string')
end

return T
