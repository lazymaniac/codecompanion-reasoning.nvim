local Config = require('codecompanion._extensions.reasoning.config')
local Protocol = require('codecompanion._extensions.reasoning.protocol')
local State = require('codecompanion._extensions.reasoning.state')
local Transition = require('codecompanion._extensions.reasoning.transition')

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
    objective = 'Explain the failure',
    problem_type = 'analysis',
    depth = 'standard',
    constraints = {},
    success_criteria = { 'Cite active evidence' },
    unknowns = {},
    perspectives = { { name = 'correctness', purpose = 'Check the explanation' } },
    temporal_required = false,
    branching_required = false,
    branching_rationale = 'One claim is under analysis',
  }
end

local function active_workspace_fixture()
  local chat = {}
  eq(Protocol.call('start', chat, frame_args(), 'armed').status, 'success')
  return chat
end

local function final_workspace_fixture()
  local chat = active_workspace_fixture()
  local evidence = Protocol.call('evidence', chat, {
    items = {
      {
        kind = 'observation',
        statement = 'The trace identifies the failing boundary',
        source = 'tests/trace.lua:10',
        confidence = 'high',
        falsifier = 'A controlled trace identifies a different boundary',
        perspective = 'correctness',
        addresses_unknowns = {},
        supports = {},
        contradicts = {},
        qualifies = {},
        supersedes_id = '',
      },
    },
  }, 'active')
  eq(evidence.status, 'success')
  local final = Protocol.call('final', chat, {
    conclusion = 'The trace identifies the failing boundary',
    selected_option_ids = {},
    support_ids = { 'E1' },
    review_ids = {},
    criterion_results = {
      {
        criterion = 'Cite active evidence',
        status = 'passed',
        evidence_ids = { 'E1' },
        explanation = 'The conclusion cites the trace observation',
      },
    },
    tradeoffs = {},
    uncertainties = {},
    blind_spots = {},
    next_actions = {},
    confidence = 'high',
  }, nil)
  eq(final.status, 'success')
  return chat
end

T['defines lifecycle transitions without mutating workspace'] = function()
  eq(Transition.next(nil, 'dormant'), nil)
  eq(Transition.next(nil, 'blocked').tool, 'none')
  eq(Transition.next(nil, 'armed').tool, 'reasoning_start')
  eq(Transition.next(nil, 'reframing').tool, 'reasoning_revise')
  eq(Transition.next(nil, 'finalizing').tool, 'none')
  eq(Transition.next(nil, 'halted').tool, 'none')
  eq(Transition.next(nil, 'finalized').tool, 'none')
end

T['accepts any tool that shares the authoritative role'] = function()
  local chat = active_workspace_fixture()
  local workspace = State.get(chat)
  eq(Transition.next(workspace, 'active').tool, 'reasoning_evidence')
  eq(Transition.allowed(workspace, 'active', 'evidence'), true)
  eq(Transition.allowed(workspace, 'active', 'answer'), false)
  eq(Transition.allowed(workspace, 'active', 'amend'), true)
  eq(Transition.allowed(workspace, 'active', 'start'), false)
end

T['blocks every protocol mutation through the effective unavailable sentinel'] = function()
  local chat = {}
  local rejected = Protocol.call('start', chat, frame_args(), 'blocked')
  eq(rejected.status, 'error')
  eq(rejected.data.code, 'transition_invalid')
  eq(rejected.data.next_action.tool, 'none')
  eq(State.get(chat), nil)
end

T['rejects an out-of-order reasoning operation before mutation'] = function()
  local chat = {}
  local started = Protocol.call('start', chat, frame_args(), 'armed')
  eq(started.status, 'success')
  local before = vim.deepcopy(State.get(chat))

  local rejected = Protocol.call('checkpoint', chat, {
    conclusion = 'Too early',
    selected_option_ids = {},
    support_ids = {},
    review_ids = {},
    criterion_results = {},
    confidence = 'low',
  }, 'active')

  eq(rejected.status, 'error')
  eq(rejected.data.code, 'transition_invalid')
  eq(rejected.data.committed, false)
  eq(rejected.data.next_action.tool, 'reasoning_evidence')
  eq(State.get(chat), before)
end

T['rejects options and review while evidence is authoritative'] = function()
  for _, operation in ipairs({ 'options', 'options_replace', 'review', 'resolve_contradiction' }) do
    local chat = {}
    Protocol.call('start', chat, frame_args(), 'armed')
    local workspace = State.get(chat)
    local before = vim.deepcopy(workspace)
    local rejected = Protocol.call(operation, chat, {}, 'active')
    eq(rejected.data.code, 'transition_invalid')
    eq(rejected.data.next_action.tool, 'reasoning_evidence')
    eq(workspace, before)
  end
end

T['keeps external callers unpoliced when no controller phase is supplied'] = function()
  local chat = {}
  local result = Protocol.call('start', chat, frame_args(), nil)
  eq(result.status, 'success')
end

T['permits only explicit revise or replace while reframing'] = function()
  local chat = {}
  Protocol.call('start', chat, frame_args(), 'armed')
  eq(Protocol.call('revise', chat, frame_args(), 'reframing').status, 'success')

  local rejected = Protocol.call('evidence', chat, { items = {} }, 'reframing')
  eq(rejected.data.code, 'transition_invalid')
  eq(rejected.data.next_action.tool, 'reasoning_revise')

  rejected = Protocol.call('amend', chat, {
    add_constraints = { 'New constraint' },
    add_success_criteria = {},
    add_unknowns = {},
    add_perspectives = {},
    require_temporal = false,
    require_branching = false,
    branching_rationale = '',
  }, 'reframing')
  eq(rejected.data.code, 'transition_invalid')
end

T['enforces reframing before the accepted-final shortcut'] = function()
  local chat = final_workspace_fixture()
  local workspace = State.get(chat)
  local before = vim.deepcopy(workspace)

  local rejected = Protocol.call('evidence', chat, { items = {} }, 'reframing')

  eq(rejected.data.code, 'transition_invalid')
  eq(rejected.data.next_action.tool, 'reasoning_revise')
  eq(State.get(chat), workspace)
  eq(workspace, before)
end

T['never treats replace as the first frame operation'] = function()
  local controlled = {}
  local rejected = Protocol.call('replace', controlled, frame_args(), 'armed')
  eq(rejected.data.code, 'transition_invalid')
  eq(State.get(controlled), nil)

  local standalone = {}
  rejected = Protocol.call('replace', standalone, frame_args(), nil)
  eq(rejected.data.code, 'transition_invalid')
  eq(State.get(standalone), nil)
end

T['returns workspace_finalized before a generic transition rejection'] = function()
  local chat = final_workspace_fixture()
  local rejected = Protocol.call('evidence', chat, { items = {} }, 'finalized')
  eq(rejected.data.code, 'workspace_finalized')
  eq(rejected.data.next_action.tool, 'none')
end

T['permits explicit revise and replace from active and finalized workspaces'] = function()
  for _, phase in ipairs({ 'active', 'finalized' }) do
    for _, operation in ipairs({ 'revise', 'replace' }) do
      local chat = phase == 'finalized' and final_workspace_fixture() or active_workspace_fixture()
      local old = State.get(chat)
      local result = Protocol.call(operation, chat, frame_args(), phase)
      eq(result.status, 'success')
      if operation == 'replace' then
        local replacement = State.get(chat)
        eq(replacement == old, false)
        eq(replacement.counts_by_kind, { frame = 1 })
        eq(#replacement.artifact_order, 1)
      end
    end
  end
end

return T
