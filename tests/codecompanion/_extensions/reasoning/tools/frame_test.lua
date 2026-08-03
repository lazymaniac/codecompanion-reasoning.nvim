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
  Config.setup({ limits = { max_array_items = 1 } })
  local args = valid_args()
  args.problem_type = 'analysis'
  args.depth = 'standard'
  args.success_criteria = { 'Durable' }
  args.branching_required = false
  args.branching_rationale = 'One bounded claim is being analyzed'
  local chat = {}
  eq(Frame.cmds[1]({ chat = chat }, args, {}).data.code, 'frame_incomplete')
  args.perspectives = { args.perspectives[1] }
  eq(Frame.cmds[1]({ chat = chat }, args, {}).status, 'success')
end

T['does not remove a perspective used by active evidence'] = function()
  local chat = {}
  Frame.cmds[1]({ chat = chat }, valid_args(), {})
  local State = require('codecompanion._extensions.reasoning.state')
  State.add(State.get(chat), 'evidence', { perspective = 'operations' })
  local revised = valid_args('revise')
  revised.perspectives = { revised.perspectives[1], { name = 'security', purpose = 'Find trust failures' } }
  local result = Frame.cmds[1]({ chat = chat }, revised, {})
  eq(result.data.code, 'frame_incomplete')
end

T['does not remove an unknown addressed by active evidence'] = function()
  local chat = {}
  Frame.cmds[1]({ chat = chat }, valid_args(), {})
  State.add(State.get(chat), 'evidence', {
    perspective = 'correctness',
    addresses_unknowns = { 'Expected write rate' },
  })
  local revised = valid_args('revise')
  revised.unknowns = {}
  eq(Frame.cmds[1]({ chat = chat }, revised, {}).data.code, 'frame_incomplete')
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

return T
