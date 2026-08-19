local Config = require('codecompanion._extensions.reasoning.config')
local Evidence = require('codecompanion._extensions.reasoning.tools.evidence')
local Start = require('codecompanion._extensions.reasoning.tools.start')
local Options = require('codecompanion._extensions.reasoning.tools.options')
local OptionsReplace = require('codecompanion._extensions.reasoning.tools.options_replace')
local Protocol = require('codecompanion._extensions.reasoning.protocol')
local State = require('codecompanion._extensions.reasoning.state')
local TreeFixture = require('support.tree_fixture')

local T = MiniTest.new_set({
  hooks = {
    pre_case = function()
      Config.setup()
      State._reset()
    end,
  },
})
local eq = MiniTest.expect.equality

local function evidence_args()
  return {
    items = {
      {
        kind = 'observation',
        statement = 'The cache is process-local',
        source = 'lua/cache.lua:14',
        confidence = 'high',
        falsifier = 'A persistence adapter loaded by cache.lua',
        perspective = 'correctness',
        addresses_unknowns = {},
        supports = {},
        contradicts = {},
        qualifies = {},
        supersedes_id = '',
      },
    },
  }
end

local function prepared_chat()
  local chat = {}
  local frame = {
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
  eq(Start.cmds[1]({ chat = chat }, frame, {}).status, 'success')
  eq(TreeFixture.satisfy(chat), true)
  eq(Evidence.cmds[1]({ chat = chat }, evidence_args(), {}).status, 'success')
  return chat
end

local function valid_args()
  return {
    question = 'Which cache architecture satisfies the frame?',
    branch_type = 'solution',
    criteria = { 'Durability', 'Bounded memory' },
    options = {
      {
        label = 'journal',
        summary = 'Append mutations to a local journal',
        evidence_ids = { 'E1' },
        assumptions = { 'Disk writes are acceptable' },
        predictions = { 'Restart restores the latest committed entry' },
        benefits = { 'Durable without a service' },
        costs = { 'Compaction is required' },
        risks = { 'Partial writes' },
        reversibility = 'moderate',
      },
      {
        label = 'snapshot',
        summary = 'Write periodic complete snapshots',
        evidence_ids = { 'E1' },
        assumptions = { 'State fits in one file' },
        predictions = { 'Recovery loses changes after the last snapshot' },
        benefits = { 'Simple recovery' },
        costs = { 'Repeated full writes' },
        risks = { 'Stale recovery point' },
        reversibility = 'easy',
      },
    },
  }
end

T['creates a branch set and two options'] = function()
  local chat = prepared_chat()
  local result = Options.cmds[1]({ chat = chat }, valid_args(), {})
  eq(result.status, 'success')
  eq(result.data.artifact.id, 'B1')
  eq({ result.data.artifacts[1].id, result.data.artifacts[2].id }, { 'O1', 'O2' })
  eq(result.data.artifact.data.option_ids, { 'O1', 'O2' })
  eq(result.data.artifact.data.frame_id, 'F1')
  eq(State.find(State.get(chat), 'B1').relations.depends_on, { 'F1' })
  eq(State.find(State.get(chat), 'O1').relations.depends_on, { 'B1' })
  eq(State.find(State.get(chat), 'O1').relations.supports, { 'E1' })
end

T['rejects duplicate labels and insufficient branches atomically'] = function()
  local chat = prepared_chat()
  local duplicate = valid_args()
  duplicate.options[2].label = ' JOURNAL '
  eq(Options.cmds[1]({ chat = chat }, duplicate, {}).data.code, 'options_invalid')
  local insufficient = valid_args()
  insufficient.options = { insufficient.options[1] }
  eq(Options.cmds[1]({ chat = chat }, insufficient, {}).data.code, 'branch_count_insufficient')
  eq(State.get(chat).counts_by_kind.branch, nil)
end

T['rejects invalid and inactive evidence'] = function()
  local chat = prepared_chat()
  local missing = valid_args()
  missing.options[1].evidence_ids = { 'E99' }
  eq(Options.cmds[1]({ chat = chat }, missing, {}).data.code, 'invalid_reference')
  State.retract(State.get(chat), 'E1')
  eq(Options.cmds[1]({ chat = chat }, valid_args(), {}).data.code, 'inactive_reference')
end

T['reports typed option references without consuming branch IDs'] = function()
  local chat = prepared_chat()
  local additional = evidence_args()
  additional.items[1].statement = 'The cache needs bounded lifecycle recovery'
  additional.items[1].source = 'tests/cache_spec.lua:28'
  additional.items[1].perspective = 'operations'
  additional.items[1].addresses_unknowns = { 'Expected write rate' }
  eq(Evidence.cmds[1]({ chat = chat }, additional, {}).status, 'success')
  local workspace = State.get(chat)
  local before = {
    revision = workspace.revision,
    artifact_order = vim.deepcopy(workspace.artifact_order),
    next_sequence = vim.deepcopy(workspace.next_sequence),
  }
  local args = valid_args()
  args.options[1].evidence_ids = { 'F1' }
  local result = Protocol.call('options', chat, args, 'active')

  eq(result.data.committed, false)
  eq(result.data.diagnostic, {
    path = 'options[1].evidence_ids[1]',
    constraint = 'artifact_kind',
    expected = 'evidence',
    actual = 'F1',
  })
  eq(result.data.next_action, Protocol.transition(workspace, 'active'))
  eq({
    revision = workspace.revision,
    artifact_order = workspace.artifact_order,
    next_sequence = workspace.next_sequence,
  }, before)
  eq(Protocol.call('options', chat, valid_args(), 'active').data.artifact.id, 'B1')
end

T['replaces a complete branch set'] = function()
  local chat = prepared_chat()
  eq(Options.cmds[1]({ chat = chat }, valid_args(), {}).status, 'success')
  local replacement = valid_args()
  replacement.supersedes_branch_id = 'B1'
  replacement.options[1].label = 'checksummed journal'
  replacement.options[2].label = 'atomic snapshot'
  local result = OptionsReplace.cmds[1]({ chat = chat }, replacement, {})
  eq(result.data.artifact.id, 'B2')
  eq({ result.data.artifacts[1].id, result.data.artifacts[2].id }, { 'O3', 'O4' })
  eq(State.find(State.get(chat), 'B1').status, 'superseded')
  eq(State.find(State.get(chat), 'O1').status, 'superseded')
  eq(State.find(State.get(chat), 'O2').status, 'superseded')
  eq(State.find(State.get(chat), 'B2').relations.supersedes, { 'B1' })
  eq(State.find(State.get(chat), 'O1').relations.supersedes, {})
  eq(State.find(State.get(chat), 'O2').relations.supersedes, {})
end

T['requires explicit supersession when a branch set is active'] = function()
  local chat = prepared_chat()
  eq(Options.cmds[1]({ chat = chat }, valid_args(), {}).status, 'success')
  local result = Options.cmds[1]({ chat = chat }, valid_args(), {})
  eq(result.data.code, 'options_invalid')
  eq(result.data.artifact_ids, { 'B1' })
  eq(State.get(chat).counts_by_kind.branch, 1)
end

T['allows optional analysis arrays but requires evidence and predictions'] = function()
  local chat = prepared_chat()
  local args = valid_args()
  for _, option in ipairs(args.options) do
    option.assumptions = {}
    option.benefits = {}
    option.costs = {}
    option.risks = {}
  end
  eq(Options.cmds[1]({ chat = chat }, args, {}).status, 'success')

  local no_evidence = valid_args()
  no_evidence.options[1].evidence_ids = {}
  local evidence_chat = prepared_chat()
  local missing_evidence = Options.cmds[1]({ chat = evidence_chat }, no_evidence, {})
  eq(missing_evidence.data.code, 'options_invalid')
  eq(State.get(evidence_chat).counts_by_kind.branch, nil)

  local no_prediction = valid_args()
  no_prediction.options[1].predictions = {}
  local prediction_chat = prepared_chat()
  local missing_prediction = Options.cmds[1]({ chat = prediction_chat }, no_prediction, {})
  eq(missing_prediction.data.code, 'options_invalid')
  eq(State.get(prediction_chat).counts_by_kind.branch, nil)
end

T['rejects invalid criteria and reversibility atomically'] = function()
  local chat = prepared_chat()
  local invalid_criterion = valid_args()
  invalid_criterion.criteria = { '   ' }
  eq(Options.cmds[1]({ chat = chat }, invalid_criterion, {}).data.code, 'options_invalid')
  local invalid_reversibility = valid_args()
  invalid_reversibility.options[1].reversibility = 'impossible'
  eq(Options.cmds[1]({ chat = chat }, invalid_reversibility, {}).data.code, 'options_invalid')
  eq(State.get(chat).counts_by_kind.branch, nil)
  local duplicate_criteria = valid_args()
  duplicate_criteria.criteria[2] = ' durability '
  eq(Options.cmds[1]({ chat = chat }, duplicate_criteria, {}).data.code, 'options_invalid')
end

T['applies max_array_items to the option count'] = function()
  Config.setup({ limits = { max_array_items = 2 } })
  local chat = prepared_chat()
  local args = valid_args()
  local third = vim.deepcopy(args.options[1])
  third.label = 'write-through file'
  table.insert(args.options, third)
  eq(Options.cmds[1]({ chat = chat }, args, {}).data.code, 'branch_count_insufficient')
  eq(State.get(chat).counts_by_kind.branch, nil)
end

T['requires the exact active branch as the replacement target'] = function()
  local chat = prepared_chat()
  eq(Options.cmds[1]({ chat = chat }, valid_args(), {}).status, 'success')
  local workspace = State.get(chat)
  local second_active = State.add(workspace, 'branch', { option_ids = {}, frame_id = workspace.frame_id })
  local replacement = valid_args()
  replacement.supersedes_branch_id = 'B1'
  local result = OptionsReplace.cmds[1]({ chat = chat }, replacement, {})
  eq(result.data.code, 'options_invalid')
  eq(result.data.artifact_ids, { second_active.id })
  eq(workspace.counts_by_kind.branch, 2)
  eq(State.find(workspace, 'B1').status, 'active')
  eq(State.find(workspace, second_active.id).status, 'active')
end

T['validates branch replacement references atomically'] = function()
  local chat = prepared_chat()
  local missing = valid_args()
  missing.supersedes_branch_id = 'B99'
  eq(OptionsReplace.cmds[1]({ chat = chat }, missing, {}).data.code, 'invalid_reference')

  local wrong_kind = valid_args()
  wrong_kind.supersedes_branch_id = 'E1'
  eq(OptionsReplace.cmds[1]({ chat = chat }, wrong_kind, {}).data.code, 'invalid_reference')

  eq(Options.cmds[1]({ chat = chat }, valid_args(), {}).status, 'success')
  State.retract(State.get(chat), 'B1')
  local inactive = valid_args()
  inactive.supersedes_branch_id = 'B1'
  eq(OptionsReplace.cmds[1]({ chat = chat }, inactive, {}).data.code, 'inactive_reference')
  eq(State.get(chat).counts_by_kind.branch, 1)
end

T['rejects an unbounded branch replacement ID before echoing it'] = function()
  local chat = prepared_chat()
  local args = valid_args()
  args.supersedes_branch_id = string.rep('B', Config.get().limits.max_text_chars + 1)
  local result = OptionsReplace.cmds[1]({ chat = chat }, args, {})
  eq(result.data.code, 'options_invalid')
  eq(result.data.artifact_ids, {})
  eq(State.get(chat).counts_by_kind.branch, nil)
end

T['rejects a replacement atomically when total capacity is unavailable'] = function()
  local chat = prepared_chat()
  eq(Options.cmds[1]({ chat = chat }, valid_args(), {}).status, 'success')
  Config.setup({ limits = { max_artifacts = 7 } })
  local replacement = valid_args()
  replacement.supersedes_branch_id = 'B1'
  local result = OptionsReplace.cmds[1]({ chat = chat }, replacement, {})
  eq(result.data.code, 'limit_exceeded')
  eq(State.get(chat).counts_by_kind.branch, 1)
  eq(State.get(chat).counts_by_kind.option, 2)
  eq(State.find(State.get(chat), 'B1').status, 'active')
  eq(State.find(State.get(chat), 'O1').status, 'active')
  eq(State.find(State.get(chat), 'O2').status, 'active')
end

T['binds rebuilt branches to the active frame revision'] = function()
  local chat = prepared_chat()
  eq(Options.cmds[1]({ chat = chat }, valid_args(), {}).status, 'success')
  local revised = vim.deepcopy(State.find(State.get(chat), 'F1').data)
  revised.objective = 'Choose and validate a durable cache design'
  eq(Protocol.call('revise', chat, revised, nil).status, 'success')
  eq(State.find(State.get(chat), 'E1').status, 'superseded')
  eq(State.find(State.get(chat), 'B1').status, 'superseded')
  eq(Evidence.cmds[1]({ chat = chat }, evidence_args(), {}).status, 'success')

  local replacement = valid_args()
  for _, option in ipairs(replacement.options) do
    option.evidence_ids = { 'E2' }
  end
  local result = Options.cmds[1]({ chat = chat }, replacement, {})
  eq(result.status, 'success')
  eq(result.data.artifact.id, 'B2')
  eq(result.data.artifact.data.frame_id, 'F2')
  eq(State.find(State.get(chat), 'B2').relations.depends_on, { 'F2' })
end

T['exposes branch cardinality in the strict schema'] = function()
  local properties = Options.schema['function'].parameters.properties
  eq({ properties.criteria.minItems, properties.criteria.maxItems }, { 1, 8 })
  eq({ properties.options.minItems, properties.options.maxItems }, { 2, 6 })
  local option = properties.options.items.properties
  eq(option.evidence_ids.minItems, 1)
  eq(option.predictions.minItems, 1)
end

return T
