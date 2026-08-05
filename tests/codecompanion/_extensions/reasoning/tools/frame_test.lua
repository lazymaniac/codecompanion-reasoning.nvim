local Config = require('codecompanion._extensions.reasoning.config')
local Protocol = require('codecompanion._extensions.reasoning.protocol')
local State = require('codecompanion._extensions.reasoning.state')
local Frame = require('codecompanion._extensions.reasoning.tools.frame')

local T = MiniTest.new_set({
  hooks = {
    pre_case = function()
      Config.setup()
      State._reset()
    end,
  },
})
local eq = MiniTest.expect.equality

local function valid_args(action)
  return {
    action = action or 'start',
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
  local result = Frame.cmds[1]({ chat = chat }, valid_args(), {})
  eq(result.status, 'success')
  eq(result.data.artifact.id, 'F1')
  eq(result.data.next_action.tool, 'reasoning_evidence')
end

T['accepts a deep frame with more than four perspectives'] = function()
  local args = resize_perspectives(valid_args(), 5)
  local result = Frame.cmds[1]({ chat = {} }, args, {})

  eq(result.status, 'success')
end

T['explains the deep perspective lower bound'] = function()
  local args = resize_perspectives(valid_args(), 1)
  local result = Frame.cmds[1]({ chat = {} }, args, {})

  eq(result.status, 'error')
  eq(result.data.code, 'frame_incomplete')
  eq(result.data.message, 'deep frames require at least 2 perspectives; received 1')
  eq(result.data.next_action.tool, 'reasoning_frame')
  eq(result.data.next_action.reason, 'Add perspectives and retry with action=start')
end

T['explains the configured perspective safety bound'] = function()
  Config.setup({ limits = { max_array_items = 4 } })
  local args = resize_perspectives(valid_args(), 5)
  local result = Frame.cmds[1]({ chat = {} }, args, {})

  eq(result.status, 'error')
  eq(result.data.code, 'frame_incomplete')
  eq(result.data.message, 'perspectives exceed max_array_items=4; received 5')
  eq(result.data.next_action.tool, 'reasoning_frame')
  eq(result.data.next_action.reason, 'Reduce perspectives to 4 or fewer and retry with action=start')
end

T['explains the standard perspective lower bound'] = function()
  local args = resize_perspectives(valid_args(), 0)
  args.depth = 'standard'
  local result = Frame.cmds[1]({ chat = {} }, args, {})

  eq(result.status, 'error')
  eq(result.data.code, 'frame_incomplete')
  eq(result.data.message, 'standard frames require at least 1 perspective; received 0')
  eq(result.data.next_action.tool, 'reasoning_frame')
  eq(result.data.next_action.reason, 'Add a perspective and retry with action=start')
end

T['reports perspective cardinality before later frame fields'] = function()
  local args = resize_perspectives(valid_args(), 0)
  args.temporal_required = nil
  local result = Frame.cmds[1]({ chat = {} }, args, {})

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
  local result = Frame.cmds[1]({ chat = {} }, args, {})
  eq(result.status, 'error')
  eq(result.data.code, 'branching_required')
end

T['requires branching for every decision-shaped problem type'] = function()
  for _, problem_type in ipairs({ 'decision', 'diagnosis', 'design', 'planning' }) do
    State._reset()
    local args = valid_args()
    args.problem_type = problem_type
    args.branching_required = false
    eq(Frame.cmds[1]({ chat = {} }, args, {}).data.code, 'branching_required')
  end
  local analysis = valid_args()
  analysis.problem_type = 'analysis'
  analysis.branching_required = false
  eq(Frame.cmds[1]({ chat = {} }, analysis, {}).status, 'success')
end

T['requires explicit replace for an active workspace'] = function()
  local chat = {}
  Frame.cmds[1]({ chat = chat }, valid_args(), {})
  local result = Frame.cmds[1]({ chat = chat }, valid_args(), {})
  eq(result.status, 'error')
  eq(result.data.code, 'workspace_exists')
end

T['rejects duplicate perspective names'] = function()
  local args = valid_args()
  args.perspectives[1].name = 'correctness review'
  args.perspectives[2].name = ' CORRECTNESS   REVIEW '
  local result = Frame.cmds[1]({ chat = {} }, args, {})
  eq(result.data.code, 'frame_incomplete')
end

T['rejects duplicate criteria and unknowns after normalization'] = function()
  local criteria = valid_args()
  criteria.success_criteria[2] = '  SURVIVES   process restart '
  eq(Frame.cmds[1]({ chat = {} }, criteria, {}).data.code, 'frame_incomplete')
  local unknowns = valid_args()
  unknowns.unknowns = { 'Expected write rate', ' expected   WRITE rate ' }
  eq(Frame.cmds[1]({ chat = {} }, unknowns, {}).data.code, 'frame_incomplete')
end

T['rejects whitespace-only required text'] = function()
  local args = valid_args()
  args.objective = '   '
  local result = Frame.cmds[1]({ chat = {} }, args, {})
  eq(result.data.code, 'frame_incomplete')
  eq(result.data.next_action.tool, 'reasoning_frame')
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
  eq(Frame.cmds[1]({ chat = chat }, args, {}).data.code, 'frame_incomplete')
  resize_perspectives(args, 2)
  eq(Frame.cmds[1]({ chat = chat }, args, {}).status, 'success')
end

T['retires evidence when revision removes its perspective'] = function()
  local chat = {}
  Frame.cmds[1]({ chat = chat }, valid_args(), {})
  local workspace = State.get(chat)
  local evidence = State.add(workspace, 'evidence', { perspective = 'operations' })
  local revised = valid_args('revise')
  revised.perspectives = { revised.perspectives[1], { name = 'security', purpose = 'Find trust failures' } }
  local result = Frame.cmds[1]({ chat = chat }, revised, {})
  eq(result.status, 'success')
  eq(State.find(workspace, evidence.id).status, 'superseded')
end

T['retires evidence when revision removes its addressed unknown'] = function()
  local chat = {}
  Frame.cmds[1]({ chat = chat }, valid_args(), {})
  local workspace = State.get(chat)
  local evidence = State.add(workspace, 'evidence', {
    perspective = 'correctness',
    addresses_unknowns = { 'Expected write rate' },
  })
  local revised = valid_args('revise')
  revised.unknowns = {}
  eq(Frame.cmds[1]({ chat = chat }, revised, {}).status, 'success')
  eq(State.find(workspace, evidence.id).status, 'superseded')
end

T['replace starts a fresh sequenced workspace'] = function()
  local chat = {}
  Frame.cmds[1]({ chat = chat }, valid_args(), {})
  local replaced = valid_args('replace')
  local result = Frame.cmds[1]({ chat = chat }, replaced, {})
  eq(result.status, 'success')
  eq(result.data.workspace_id, 'W2')
  eq(result.data.artifact.id, 'F1')
end

T['advertises perspective lower bounds without caching the configured maximum'] = function()
  local properties = Frame.schema['function'].parameters.properties
  eq(properties.depth.description, 'Explicit protocol depth; the reasoning group prompt states the configured default.')
  eq(properties.perspectives.minItems, 1)
  eq(properties.perspectives.maxItems, nil)
  eq(
    properties.perspectives.description,
    'At least one perspective is required; deep frames require at least two. The configured max_array_items safety bound applies at runtime.'
  )
end

T['revision retires every downstream artifact before rebuilding'] = function()
  local chat = {}
  local started = Frame.cmds[1]({ chat = chat }, valid_args(), {})
  local workspace = State.get(chat)
  local old_frame = workspace.frame_id
  local downstream = {}
  for _, kind in ipairs({ 'evidence', 'branch', 'option', 'review', 'synthesis' }) do
    local artifact = State.add(workspace, kind, { frame_id = old_frame })
    table.insert(downstream, artifact.id)
  end

  local revised = valid_args()
  revised.action = 'revise'
  revised.objective = 'Explain the corrected failure'
  revised.depth = 'standard'
  revised.perspectives = { { name = 'operations', purpose = 'Check the corrected lifecycle' } }
  local result = Protocol.call('frame', chat, revised, 'active')

  eq(started.status, 'success')
  eq(result.status, 'success')
  eq(State.find(workspace, old_frame).status, 'superseded')
  for _, id in ipairs(downstream) do
    eq(State.find(workspace, id).status, 'superseded')
  end
  eq(State.find(workspace, workspace.frame_id).status, 'active')
end

T['reports ordered armed and reframing diagnostics without consuming frame IDs'] = function()
  local armed_chat = {}
  local malformed_start = valid_args()
  malformed_start.objective = '   '
  local armed = Protocol.call('frame', armed_chat, malformed_start, 'armed')
  eq(armed.data.committed, false)
  eq(armed.data.diagnostic, {
    path = 'objective',
    constraint = 'min_chars',
    expected = 1,
    actual = 3,
  })
  eq(armed.data.next_action, Protocol.transition(nil, 'armed'))
  eq(State.get(armed_chat), nil)
  eq(Protocol.call('frame', armed_chat, valid_args(), 'armed').data.artifact.id, 'F1')

  local workspace = State.get(armed_chat)
  local before = {
    revision = workspace.revision,
    artifact_order = vim.deepcopy(workspace.artifact_order),
    next_sequence = vim.deepcopy(workspace.next_sequence),
  }
  local malformed_revision = valid_args('revise')
  malformed_revision.objective = nil
  local reframing = Protocol.call('frame', armed_chat, malformed_revision, 'reframing')
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
  eq(Protocol.call('frame', armed_chat, valid_args('revise'), 'reframing').data.artifact.id, 'F2')
end

return T
