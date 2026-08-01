local Config = require('codecompanion._extensions.reasoning.config')
local Evidence = require('codecompanion._extensions.reasoning.tools.evidence')
local Frame = require('codecompanion._extensions.reasoning.tools.frame')
local Options = require('codecompanion._extensions.reasoning.tools.options')
local Review = require('codecompanion._extensions.reasoning.tools.review')
local State = require('codecompanion._extensions.reasoning.state')

local T = MiniTest.new_set({
  hooks = {
    pre_case = function()
      Config.setup()
      State._reset()
    end,
  },
})
local eq = MiniTest.expect.equality

local function prepare(temporal)
  local chat = {}
  local second_perspective = temporal and 'temporal' or 'operations'
  local frame = {
    action = 'start',
    objective = 'Choose a durable cache design',
    problem_type = 'design',
    depth = 'deep',
    constraints = { 'No external service' },
    success_criteria = { 'Durable', 'Bounded' },
    unknowns = {},
    perspectives = {
      { name = 'correctness', purpose = 'Find invalidation failures' },
      { name = second_perspective, purpose = 'Find lifecycle failures over time' },
    },
    temporal_required = temporal == true,
    branching_required = true,
    branching_rationale = 'Competing designs exist',
  }
  eq(Frame.cmds[1]({ chat = chat }, frame, {}).status, 'success')
  local evidence = {
    items = {
      {
        kind = 'observation',
        statement = 'The process may restart',
        source = 'user constraint',
        confidence = 'high',
        falsifier = 'The process lifetime is guaranteed',
        perspective = 'correctness',
        addresses_unknowns = {},
        supports = {},
        contradicts = {},
        qualifies = {},
        supersedes_id = '',
      },
      {
        kind = 'claim',
        statement = 'Snapshots reduce write frequency',
        source = 'design derivation',
        confidence = 'medium',
        falsifier = 'Measured snapshot writes exceed journal writes',
        perspective = second_perspective,
        addresses_unknowns = {},
        supports = {},
        contradicts = { 'E1' },
        qualifies = {},
        supersedes_id = '',
      },
    },
  }
  eq(Evidence.cmds[1]({ chat = chat }, evidence, {}).status, 'success')
  local options = {
    question = 'Which design?',
    branch_type = 'solution',
    criteria = { 'Durability', 'Memory' },
    supersedes_branch_id = '',
    options = {
      {
        label = 'journal',
        summary = 'Append mutations',
        evidence_ids = { 'E1' },
        assumptions = { 'Disk works' },
        predictions = { 'Replay restores state' },
        benefits = { 'Durable' },
        costs = { 'Compaction' },
        risks = { 'Torn writes' },
        reversibility = 'moderate',
      },
      {
        label = 'snapshot',
        summary = 'Write snapshots',
        evidence_ids = { 'E2' },
        assumptions = { 'State fits' },
        predictions = { 'Recovery uses last snapshot' },
        benefits = { 'Simple' },
        costs = { 'Full writes' },
        risks = { 'Stale state' },
        reversibility = 'easy',
      },
    },
  }
  eq(Options.cmds[1]({ chat = chat }, options, {}).status, 'success')
  return chat
end

local function full_review()
  return {
    mode = 'full',
    target_ids = { 'O1', 'E1' },
    defense = { summary = 'The journal is supported by restart requirements', evidence_ids = { 'E1' } },
    challenges = {
      {
        kind = 'counterexample',
        summary = 'A torn journal record can prevent recovery',
        target_ids = { 'O1', 'E1' },
        falsifier = 'Recovery succeeds after truncating every possible partial suffix',
      },
      {
        kind = 'hidden_assumption',
        summary = 'Atomic rename behavior is assumed',
        target_ids = { 'O1' },
        falsifier = 'The selected filesystem documents the required atomicity',
      },
    },
    blind_spots = { 'Behavior on disk exhaustion' },
    stress_tests = {},
    verdicts = {
      { target_id = 'O1', status = 'revise', revision_instruction = 'Add torn-write recovery' },
      { target_id = 'E1', status = 'keep', revision_instruction = '' },
    },
    contradiction_resolutions = {},
    structural_tradeoffs = {},
  }
end

T['records a full review and an open revision'] = function()
  local chat = prepare()
  local result = Review.cmds[1]({ chat = chat }, full_review(), {})
  eq(result.status, 'success')
  eq(result.data.artifact.id, 'R1')
  eq(result.data.artifact.data.frame_id, 'F1')
  eq(State.get(chat).open_revisions.O1, 'R1')
  eq(State.find(State.get(chat), 'R1').relations.depends_on, { 'O1', 'E1' })
  eq(State.find(State.get(chat), 'R1').relations.supports, { 'E1' })
end

T['rejects incomplete verdict coverage without mutation'] = function()
  local chat = prepare()
  local args = full_review()
  args.verdicts[2] = nil
  local result = Review.cmds[1]({ chat = chat }, args, {})
  eq(result.data.code, 'review_incomplete')
  eq(State.get(chat).counts_by_kind.review, nil)
  eq(State.find(State.get(chat), 'O1').status, 'active')
end

T['applies retraction immediately'] = function()
  local chat = prepare()
  local args = full_review()
  args.target_ids = { 'B1' }
  args.challenges[1].target_ids = { 'B1' }
  args.challenges[2].target_ids = { 'B1' }
  args.verdicts = { { target_id = 'B1', status = 'retract', revision_instruction = '' } }
  local result = Review.cmds[1]({ chat = chat }, args, {})
  eq(result.status, 'success')
  eq(State.find(State.get(chat), 'B1').status, 'retracted')
  eq(State.find(State.get(chat), 'O1').status, 'retracted')
  eq(State.find(State.get(chat), 'O2').status, 'retracted')
end

T['rejects direct option retraction without mutation'] = function()
  local chat = prepare()
  local args = full_review()
  args.target_ids = { 'O1' }
  args.challenges[1].target_ids = { 'O1' }
  args.challenges[2].target_ids = { 'O1' }
  args.verdicts = { { target_id = 'O1', status = 'retract', revision_instruction = '' } }
  local result = Review.cmds[1]({ chat = chat }, args, {})
  eq(result.data.code, 'review_incomplete')
  eq(result.data.next_action.tool, 'reasoning_options')
  eq(State.find(State.get(chat), 'O1').status, 'active')
  eq(State.get(chat).counts_by_kind.review, nil)
end

T['clears an evidence revision only after typed supersession'] = function()
  local chat = prepare()
  local args = full_review()
  args.target_ids = { 'E1' }
  args.challenges[1].target_ids = { 'E1' }
  args.challenges[2].target_ids = { 'E1' }
  args.verdicts = { { target_id = 'E1', status = 'revise', revision_instruction = 'Measure restart behavior' } }
  eq(Review.cmds[1]({ chat = chat }, args, {}).status, 'success')
  eq(Review.cmds[1]({ chat = chat }, args, {}).data.code, 'review_incomplete')
  eq(State.get(chat).open_revisions.E1, 'R1')
  eq(State.get(chat).counts_by_kind.review, 1)
  local replacement = {
    kind = 'observation',
    statement = 'The process may restart',
    source = 'tests/restart.lua:9',
    confidence = 'high',
    falsifier = 'The process lifetime is guaranteed',
    perspective = 'correctness',
    addresses_unknowns = {},
    supports = {},
    contradicts = {},
    qualifies = {},
    supersedes_id = 'E1',
  }
  eq(Evidence.cmds[1]({ chat = chat }, { items = { replacement } }, {}).status, 'success')
  eq(State.get(chat).open_revisions.E1, nil)
  eq(State.get(chat).resolved_revisions.R1.E1, {
    resolution = 'superseded',
    replacement_id = 'E3',
  })
end

T['requires temporal stress tests'] = function()
  local chat = prepare()
  local args = full_review()
  args.mode = 'temporal'
  eq(Review.cmds[1]({ chat = chat }, args, {}).data.code, 'review_incomplete')
  args.stress_tests = {
    {
      scenario = 'Three compaction cycles',
      prediction = 'Recovery remains complete',
      failure_signal = 'A key disappears',
    },
  }
  local result = Review.cmds[1]({ chat = chat }, args, {})
  eq(result.status, 'success')
  eq(State.find(State.get(chat), result.data.artifact.id).relations.tests, { 'O1', 'E1' })
end

T['accepts every non-temporal review mode'] = function()
  for _, mode in ipairs({ 'falsification', 'assumptions', 'cross_perspective', 'full' }) do
    State._reset()
    local chat = prepare()
    local args = full_review()
    args.mode = mode
    if mode == 'cross_perspective' then
      args.target_ids = { 'E1', 'E2' }
      args.challenges[1].target_ids = { 'E1' }
      args.challenges[2].target_ids = { 'E2' }
      args.verdicts = {
        { target_id = 'E1', status = 'keep', revision_instruction = '' },
        { target_id = 'E2', status = 'keep', revision_instruction = '' },
      }
    end
    eq(Review.cmds[1]({ chat = chat }, args, {}).status, 'success')
  end
end

T['requires stress tests for an explicitly temporal frame'] = function()
  local chat = prepare(true)
  local args = full_review()
  eq(Review.cmds[1]({ chat = chat }, args, {}).data.code, 'review_incomplete')
  args.stress_tests = {
    {
      scenario = 'Three lifecycle transitions',
      prediction = 'State remains valid',
      failure_signal = 'Recovery diverges',
    },
  }
  eq(Review.cmds[1]({ chat = chat }, args, {}).status, 'success')
end

T['rejects structural tradeoffs with invalid evidence'] = function()
  local chat = prepare()
  local args = full_review()
  args.structural_tradeoffs = {
    {
      statement = 'Durability increases writes',
      evidence_ids = { 'E99' },
      falsifier = 'A durable zero-write design',
    },
  }
  eq(Review.cmds[1]({ chat = chat }, args, {}).data.code, 'invalid_reference')
end

T['resolves a reviewed contradiction pair'] = function()
  local chat = prepare()
  local args = full_review()
  args.target_ids = { 'E1', 'E2' }
  args.challenges[1].target_ids = { 'E1' }
  args.challenges[2].target_ids = { 'E2' }
  args.verdicts = {
    { target_id = 'E1', status = 'keep', revision_instruction = '' },
    { target_id = 'E2', status = 'keep', revision_instruction = '' },
  }
  args.contradiction_resolutions = {
    {
      left_id = 'E1',
      right_id = 'E2',
      resolution = 'E2 qualifies E1 only for write frequency; it does not refute restart requirements',
      evidence_ids = { 'E1', 'E2' },
    },
  }
  local result = Review.cmds[1]({ chat = chat }, args, {})
  eq(result.status, 'success')
  eq(State.get(chat).resolved_contradictions['E1:E2'], 'R1')
  eq(State.find(State.get(chat), 'R1').relations.qualifies, { 'E1', 'E2' })
end

T['does not resolve a contradiction from unrelated keep verdicts'] = function()
  local chat = prepare()
  local args = full_review()
  args.target_ids = { 'E1', 'E2' }
  args.challenges[1].target_ids = { 'E1' }
  args.challenges[2].target_ids = { 'E2' }
  args.verdicts = {
    { target_id = 'E1', status = 'keep', revision_instruction = '' },
    { target_id = 'E2', status = 'keep', revision_instruction = '' },
  }
  eq(Review.cmds[1]({ chat = chat }, args, {}).status, 'success')
  eq(State.get(chat).resolved_contradictions['E1:E2'], nil)
end

T['rejects reversed duplicate contradiction resolutions atomically'] = function()
  local chat = prepare()
  local args = full_review()
  args.target_ids = { 'E1', 'E2' }
  args.challenges[1].target_ids = { 'E1' }
  args.challenges[2].target_ids = { 'E2' }
  args.verdicts = {
    { target_id = 'E1', status = 'keep', revision_instruction = '' },
    { target_id = 'E2', status = 'keep', revision_instruction = '' },
  }
  local resolution = {
    left_id = 'E1',
    right_id = 'E2',
    resolution = 'The claims apply to different scopes',
    evidence_ids = { 'E1' },
  }
  args.contradiction_resolutions = {
    resolution,
    {
      left_id = 'E2',
      right_id = 'E1',
      resolution = 'The same pair in reverse',
      evidence_ids = { 'E2' },
    },
  }
  eq(Review.cmds[1]({ chat = chat }, args, {}).data.code, 'review_incomplete')
  eq(State.get(chat).counts_by_kind.review, nil)
end

T['requires every target to receive an adversarial challenge'] = function()
  local chat = prepare()
  local args = full_review()
  args.challenges[1].target_ids = { 'O1' }
  local result = Review.cmds[1]({ chat = chat }, args, {})
  eq(result.data.code, 'review_incomplete')
  eq(result.data.artifact_ids, { 'E1' })
  eq(State.get(chat).counts_by_kind.review, nil)
end

T['requires distinct evidence perspectives in cross-perspective mode'] = function()
  local chat = prepare()
  local args = full_review()
  args.mode = 'cross_perspective'
  local result = Review.cmds[1]({ chat = chat }, args, {})
  eq(result.data.code, 'review_incomplete')
  eq(State.get(chat).counts_by_kind.review, nil)
end

T['rejects frame retraction and routes correction to framing'] = function()
  local chat = prepare()
  local args = full_review()
  args.target_ids = { 'F1' }
  args.challenges[1].target_ids = { 'F1' }
  args.challenges[2].target_ids = { 'F1' }
  args.verdicts = { { target_id = 'F1', status = 'retract', revision_instruction = '' } }
  local result = Review.cmds[1]({ chat = chat }, args, {})
  eq(result.data.code, 'review_incomplete')
  eq(result.data.next_action.tool, 'reasoning_frame')
  eq(State.find(State.get(chat), 'F1').status, 'active')
  eq(State.get(chat).counts_by_kind.review, nil)
end

T['rejects mixed branch and child verdicts atomically in either order'] = function()
  for _, reverse in ipairs({ false, true }) do
    State._reset()
    local chat = prepare()
    local args = full_review()
    args.target_ids = { 'B1', 'O1' }
    args.challenges[1].target_ids = { 'B1', 'O1' }
    args.challenges[2].target_ids = { 'B1' }
    local branch_verdict = { target_id = 'B1', status = 'retract', revision_instruction = '' }
    local option_verdict = { target_id = 'O1', status = 'keep', revision_instruction = '' }
    args.verdicts = reverse and { option_verdict, branch_verdict } or { branch_verdict, option_verdict }
    local result = Review.cmds[1]({ chat = chat }, args, {})
    eq(result.data.code, 'review_incomplete')
    eq(State.find(State.get(chat), 'B1').status, 'active')
    eq(State.find(State.get(chat), 'O1').status, 'active')
    eq(State.get(chat).counts_by_kind.review, nil)
  end
end

T['rejects reviews that retract their own supporting evidence'] = function()
  local chat = prepare()
  local args = full_review()
  args.target_ids = { 'E1' }
  args.challenges[1].target_ids = { 'E1' }
  args.challenges[2].target_ids = { 'E1' }
  args.verdicts = { { target_id = 'E1', status = 'retract', revision_instruction = '' } }
  local result = Review.cmds[1]({ chat = chat }, args, {})
  eq(result.data.code, 'review_incomplete')
  eq(State.find(State.get(chat), 'E1').status, 'active')
  eq(State.get(chat).counts_by_kind.review, nil)

  args.defense.evidence_ids = { 'E2' }
  args.structural_tradeoffs = {
    { statement = 'Restarts require durable state', evidence_ids = { 'E1' }, falsifier = 'Restarts never occur' },
  }
  result = Review.cmds[1]({ chat = chat }, args, {})
  eq(result.data.code, 'review_incomplete')
  eq(State.find(State.get(chat), 'E1').status, 'active')
  eq(State.get(chat).counts_by_kind.review, nil)
end

T['rejects duplicate nested references atomically'] = function()
  local chat = prepare()
  local args = full_review()
  args.defense.evidence_ids = { 'E1', 'E1' }
  eq(Review.cmds[1]({ chat = chat }, args, {}).data.code, 'review_incomplete')

  args = full_review()
  args.challenges[1].target_ids = { 'O1', 'O1', 'E1' }
  eq(Review.cmds[1]({ chat = chat }, args, {}).data.code, 'review_incomplete')

  args = full_review()
  args.structural_tradeoffs = {
    { statement = 'Writes buy durability', evidence_ids = { 'E1', 'E1' }, falsifier = 'A zero-write durable design' },
  }
  eq(Review.cmds[1]({ chat = chat }, args, {}).data.code, 'review_incomplete')
  eq(State.get(chat).counts_by_kind.review, nil)
end

T['distinguishes missing and inactive review targets'] = function()
  local chat = prepare()
  local args = full_review()
  args.target_ids = { 'E99' }
  eq(Review.cmds[1]({ chat = chat }, args, {}).data.code, 'invalid_reference')

  State.retract(State.get(chat), 'E2')
  args.target_ids = { 'E2' }
  eq(Review.cmds[1]({ chat = chat }, args, {}).data.code, 'inactive_reference')
  eq(State.get(chat).counts_by_kind.review, nil)
end

T['rejects a review atomically when total capacity is unavailable'] = function()
  local chat = prepare()
  Config.setup({ limits = { max_artifacts = #State.get(chat).artifact_order } })
  local result = Review.cmds[1]({ chat = chat }, full_review(), {})
  eq(result.data.code, 'limit_exceeded')
  eq(State.get(chat).counts_by_kind.review, nil)
  eq(State.get(chat).open_revisions.O1, nil)
  eq(State.find(State.get(chat), 'O1').status, 'active')
end

T['exposes minimum review cardinality in the strict schema'] = function()
  local properties = Review.schema['function'].parameters.properties
  eq(properties.target_ids.minItems, 1)
  eq(properties.challenges.minItems, 1)
  eq(
    properties.target_ids.description,
    'Distinct active artifacts; challenges must collectively cover them and verdicts must cover each exactly once.'
  )
end

return T
