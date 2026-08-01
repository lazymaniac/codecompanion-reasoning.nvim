local Config = require('codecompanion._extensions.reasoning.config')
local Evidence = require('codecompanion._extensions.reasoning.tools.evidence')
local Frame = require('codecompanion._extensions.reasoning.tools.frame')
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

local function frame_args()
  return {
    action = 'start',
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

local function framed_chat()
  local chat = {}
  eq(Frame.cmds[1]({ chat = chat }, frame_args(), {}).status, 'success')
  return chat
end

local function evidence_item(perspective)
  return {
    kind = 'observation',
    statement = 'The existing cache is process-local',
    source = 'lua/cache.lua:14',
    confidence = 'high',
    falsifier = 'A persistence adapter loaded by cache.lua',
    perspective = perspective or 'correctness',
    addresses_unknowns = {},
    supports = {},
    contradicts = {},
    qualifies = {},
    supersedes_id = '',
  }
end

local function record_assumption(chat)
  local item = evidence_item('correctness')
  item.kind = 'assumption'
  item.source = 'assumption: inferred from the current module layout'
  local result = Evidence.cmds[1]({ chat = chat }, { items = { item } }, {})
  eq(result.status, 'success')
  return result.data.artifacts[1]
end

T['routes cross-tool corrections to the exact corrective tool'] = function()
  local missing = Evidence.cmds[1]({ chat = {} }, { items = { evidence_item() } }, {})
  eq(missing.data.code, 'workspace_missing')
  eq(missing.data.next_action.tool, 'reasoning_frame')

  local unknown = Evidence.cmds[1]({ chat = framed_chat() }, { items = { evidence_item('missing') } }, {})
  eq(unknown.data.code, 'perspective_unknown')
  eq(unknown.data.next_action.tool, 'reasoning_frame')
end

T['records evidence and typed relations with stable IDs'] = function()
  local chat = framed_chat()
  local first = Evidence.cmds[1]({ chat = chat }, { items = { evidence_item() } }, {})
  local second_item = evidence_item('operations')
  second_item.statement = 'A journal survives process restart'
  second_item.source = 'tests/recovery_spec.lua:28'
  second_item.supports = { 'E1' }
  second_item.contradicts = { 'E1' }
  second_item.qualifies = { 'E1' }
  local second = Evidence.cmds[1]({ chat = chat }, { items = { second_item } }, {})
  eq(first.data.artifacts[1].id, 'E1')
  eq(second.data.artifacts[1].id, 'E2')
  eq(State.find(State.get(chat), 'E2').relations.supports, { 'E1' })
  eq(State.find(State.get(chat), 'E2').relations.contradicts, { 'E1' })
  eq(State.find(State.get(chat), 'E2').relations.qualifies, { 'E1' })
end

T['rejects an unknown perspective without a partial write'] = function()
  local chat = framed_chat()
  local first = evidence_item('missing')
  local second = evidence_item('correctness')
  second.statement = 'A distinct statement'
  local result = Evidence.cmds[1]({ chat = chat }, { items = { first, second } }, {})
  eq(result.status, 'error')
  eq(result.data.code, 'perspective_unknown')
  eq(State.get(chat).counts_by_kind.evidence, nil)
end

T['distinguishes missing and inactive references'] = function()
  local chat = framed_chat()
  local item = evidence_item()
  item.supports = { 'E99' }
  eq(Evidence.cmds[1]({ chat = chat }, { items = { item } }, {}).data.code, 'invalid_reference')

  local accepted = Evidence.cmds[1]({ chat = chat }, { items = { evidence_item() } }, {})
  State.retract(State.get(chat), accepted.data.artifacts[1].id)
  item.statement = 'A second distinct statement'
  item.supports = { 'E1' }
  eq(Evidence.cmds[1]({ chat = chat }, { items = { item } }, {}).data.code, 'inactive_reference')
end

T['rejects duplicate normalized statements'] = function()
  local chat = framed_chat()
  Evidence.cmds[1]({ chat = chat }, { items = { evidence_item() } }, {})
  local duplicate = evidence_item()
  duplicate.statement = '  THE existing   cache is process-local  '
  eq(Evidence.cmds[1]({ chat = chat }, { items = { duplicate } }, {}).data.code, 'duplicate_artifact')
end

T['rejects duplicate statements found in inactive history'] = function()
  local chat = framed_chat()
  Evidence.cmds[1]({ chat = chat }, { items = { evidence_item() } }, {})
  State.retract(State.get(chat), 'E1')
  local result = Evidence.cmds[1]({ chat = chat }, { items = { evidence_item() } }, {})
  eq(result.data.code, 'duplicate_artifact')
  eq(result.data.artifact_ids, { 'E1' })
end

T['rejects duplicate statements and supersession targets inside one batch'] = function()
  local chat = framed_chat()
  local original = Evidence.cmds[1]({ chat = chat }, { items = { evidence_item() } }, {}).data.artifacts[1]
  local first = evidence_item()
  first.supersedes_id = original.id
  local second = evidence_item('operations')
  second.supersedes_id = original.id
  local result = Evidence.cmds[1]({ chat = chat }, { items = { first, second } }, {})
  eq(result.data.code, 'duplicate_artifact')
  eq(result.data.artifact_ids, { 'E1' })
  eq(State.find(State.get(chat), 'E1').status, 'active')
  eq(State.get(chat).counts_by_kind.evidence, 1)
end

T['requires explicit assumption and observation sources'] = function()
  local chat = framed_chat()
  local assumption = evidence_item()
  assumption.kind = 'assumption'
  eq(Evidence.cmds[1]({ chat = chat }, { items = { assumption } }, {}).data.code, 'evidence_invalid')
  local observation = evidence_item()
  observation.source = 'unknown'
  eq(Evidence.cmds[1]({ chat = chat }, { items = { observation } }, {}).data.code, 'evidence_invalid')
end

T['requires a falsifier and validates unknown coverage'] = function()
  local chat = framed_chat()
  local missing_falsifier = evidence_item()
  missing_falsifier.falsifier = '   '
  eq(Evidence.cmds[1]({ chat = chat }, { items = { missing_falsifier } }, {}).data.code, 'evidence_invalid')

  local covered = evidence_item()
  covered.addresses_unknowns = { 'Expected write rate' }
  eq(Evidence.cmds[1]({ chat = chat }, { items = { covered } }, {}).status, 'success')

  local unknown = evidence_item('operations')
  unknown.statement = 'Writes are bursty'
  unknown.addresses_unknowns = { 'Unknown not present in the frame' }
  eq(Evidence.cmds[1]({ chat = chat }, { items = { unknown } }, {}).data.code, 'evidence_invalid')
end

T['enforces max_batch_items atomically'] = function()
  Config.setup({ limits = { max_batch_items = 1 } })
  local chat = framed_chat()
  local second = evidence_item('operations')
  second.statement = 'A second distinct statement'
  local result = Evidence.cmds[1]({ chat = chat }, { items = { evidence_item(), second } }, {})
  eq(result.data.code, 'evidence_invalid')
  eq(State.get(chat).counts_by_kind.evidence, nil)
end

T['supersedes an assumption with an observation'] = function()
  local chat = framed_chat()
  local first = record_assumption(chat)
  local replacement = evidence_item('correctness')
  replacement.statement = first.data.statement
  replacement.supersedes_id = first.id
  local result = Evidence.cmds[1]({ chat = chat }, { items = { replacement } }, {})
  eq(result.status, 'success')
  eq(State.find(State.get(chat), first.id).status, 'superseded')
  eq(result.data.artifacts[1].relations.supersedes, { first.id })
end

T['rejects a batch when total capacity is unavailable'] = function()
  Config.setup({ limits = { max_artifacts = 2 } })
  local chat = framed_chat()
  local first = evidence_item()
  local second = evidence_item('operations')
  second.statement = 'A second distinct statement'
  local result = Evidence.cmds[1]({ chat = chat }, { items = { first, second } }, {})
  eq(result.data.code, 'limit_exceeded')
  eq(State.get(chat).counts_by_kind.evidence, nil)
end

return T
