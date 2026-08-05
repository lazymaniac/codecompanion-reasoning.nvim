local Guidance = require('codecompanion._extensions.reasoning.guidance')
local Protocol = require('codecompanion._extensions.reasoning.protocol')

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
  local frame = artifact('F1', 'frame', {
    depth = 'deep',
    problem_type = 'design',
    branching_required = true,
    success_criteria = { 'Durable' },
    unknowns = {},
    temporal_required = false,
    perspectives = {
      { name = 'correctness', purpose = 'Find failures' },
      { name = 'operations', purpose = 'Find lifecycle failures' },
    },
  })
  return {
    frame_id = 'F1',
    artifact_order = { 'F1' },
    artifacts_by_id = { F1 = frame },
    open_revisions = {},
    resolved_revisions = {},
    resolved_contradictions = {},
  }
end

local function add(ws, value)
  ws.artifacts_by_id[value.id] = value
  table.insert(ws.artifact_order, value.id)
  return value
end

local function evidence(id, perspective)
  return artifact(id, 'evidence', { perspective = perspective, addresses_unknowns = {} })
end

local function complete_workspace()
  local ws = workspace()
  add(ws, evidence('E1', 'correctness'))
  add(ws, evidence('E2', 'operations'))
  local option1 = artifact('O1', 'option', { evidence_ids = { 'E1' }, predictions = { 'Replay succeeds' } })
  local option2 = artifact('O2', 'option', { evidence_ids = { 'E2' }, predictions = { 'Snapshot loads' } })
  add(ws, artifact('B1', 'branch', { frame_id = 'F1', option_ids = { 'O1', 'O2' } }))
  add(ws, option1)
  add(ws, option2)
  local review = add(
    ws,
    artifact('R1', 'review', {
      frame_id = 'F1',
      mode = 'full',
      target_ids = { 'O1', 'E1' },
      stress_tests = {},
      contradiction_resolutions = {},
      verdicts = {},
    })
  )
  review.relations.supports = { 'E1' }
  return ws
end

local function verified_synthesis(mode)
  return {
    mode = mode,
    selected_option_ids = { 'O1' },
    support_ids = { 'E1', 'E2' },
    review_ids = { 'R1' },
    criterion_results = { { criterion = 'Durable', status = 'passed', evidence_ids = { 'E1' } } },
  }
end

T['uses deterministic priority order'] = function()
  eq(Guidance.next(nil), { tool = 'reasoning_frame', reason = 'Create the active problem frame' })

  local malformed = workspace()
  malformed.artifacts_by_id.F1.data.perspectives[2] = nil
  eq(Guidance.next(malformed), { tool = 'reasoning_frame', reason = 'Correct uncovered frame requirements' })

  local ws = workspace()
  eq(Guidance.next(ws).tool, 'reasoning_evidence')
  add(ws, evidence('E1', 'correctness'))
  eq(Guidance.next(ws).tool, 'reasoning_evidence')
  add(ws, evidence('E2', 'operations'))
  eq(Guidance.next(ws).tool, 'reasoning_options')

  local unsupported = artifact('O1', 'option', { evidence_ids = {}, predictions = { 'A result' } })
  add(ws, artifact('B1', 'branch', { frame_id = 'F1', option_ids = { 'O1' } }))
  add(ws, unsupported)
  eq(Guidance.next(ws).tool, 'reasoning_options')

  unsupported.data.evidence_ids = { 'E1' }
  ws.artifacts_by_id.E2.relations.contradicts = { 'E1' }
  eq(Guidance.next(ws).tool, 'reasoning_review')
  ws.artifacts_by_id.E2.relations.contradicts = {}
  ws.open_revisions.E1 = 'R1'
  eq(Guidance.next(ws).tool, 'reasoning_evidence')

  local complete = complete_workspace()
  eq(Guidance.next(complete).reason, 'Record verification for every success criterion')
  eq(Guidance.next(complete, verified_synthesis()), {
    tool = 'reasoning_synthesis',
    reason = 'All structural gates are ready for final synthesis',
  })
end

T['routes immutable option repair through branch replacement'] = function()
  local ws = complete_workspace()
  ws.artifacts_by_id.O1.data.evidence_ids = {}
  eq(Guidance.next(ws), {
    tool = 'reasoning_options',
    reason = 'Replace the branch set so every option cites active evidence and states testable predictions',
  })

  ws.artifacts_by_id.O1.data.evidence_ids = { 'E1' }
  ws.artifacts_by_id.O1.data.predictions = {}
  eq(Guidance.next(ws).tool, 'reasoning_options')
end

T['requires a new selection after branch replacement retires the checkpoint selection'] = function()
  local ws = complete_workspace()
  ws.artifacts_by_id.B1.status = 'superseded'
  ws.artifacts_by_id.O1.status = 'superseded'
  ws.artifacts_by_id.O2.status = 'superseded'
  add(ws, artifact('B2', 'branch', { frame_id = 'F1', option_ids = { 'O3', 'O4' } }))
  add(ws, artifact('O3', 'option', { evidence_ids = { 'E1' }, predictions = { 'Replay succeeds' } }))
  add(ws, artifact('O4', 'option', { evidence_ids = { 'E2' }, predictions = { 'Snapshot loads' } }))
  add(
    ws,
    artifact('S1', 'synthesis', {
      frame_id = 'F1',
      mode = 'checkpoint',
      selected_option_ids = { 'O1' },
      support_ids = { 'E1' },
      review_ids = { 'R1' },
      criterion_results = {},
    })
  )
  eq(Guidance.next(ws), {
    tool = 'reasoning_synthesis',
    reason = 'Select active options from the current branch set in the next synthesis',
  })
end

T['normalizes criterion whitespace exactly like final gates'] = function()
  local ws = complete_workspace()
  ws.artifacts_by_id.F1.data.success_criteria = { 'Durable   recovery' }
  local synthesis = verified_synthesis()
  synthesis.criterion_results = {
    { criterion = ' durable recovery ', status = 'passed', evidence_ids = { 'E1' } },
  }
  eq(Guidance.next(ws, synthesis).reason, 'All structural gates are ready for final synthesis')
end

T['accepts a cited non-full review for a standard branch'] = function()
  local ws = complete_workspace()
  ws.artifacts_by_id.F1.data.depth = 'standard'
  ws.artifacts_by_id.R1.data.mode = 'falsification'
  eq(Guidance.next(ws, verified_synthesis()).reason, 'All structural gates are ready for final synthesis')
end

T['requires a relevant cited full review in deep mode'] = function()
  local ws = complete_workspace()
  ws.artifacts_by_id.R1.data.target_ids = { 'O2' }
  eq(Guidance.next(ws, verified_synthesis()), {
    tool = 'reasoning_review',
    reason = 'Run a full review of selected or supporting artifacts',
  })
end

T['asks synthesis to select an option when a branch result omits selection'] = function()
  local ws = complete_workspace()
  local synthesis = verified_synthesis()
  synthesis.selected_option_ids = {}
  eq(Guidance.next(ws, synthesis), {
    tool = 'reasoning_synthesis',
    reason = 'Select a supported option in the next synthesis',
  })
end

T['does not count unsupported passed criteria as verified'] = function()
  local ws = complete_workspace()
  local synthesis = verified_synthesis()
  synthesis.criterion_results[1].evidence_ids = {}
  eq(Guidance.next(ws, synthesis).reason, 'Record verification for every success criterion')
end

T['prioritizes evidence for an uncovered framed unknown'] = function()
  local ws = workspace()
  ws.artifacts_by_id.F1.data.unknowns = { 'Expected write rate' }
  add(ws, evidence('E1', 'correctness'))
  add(ws, evidence('E2', 'operations'))
  eq(Guidance.next(ws), {
    tool = 'reasoning_evidence',
    reason = 'Gather evidence for unresolved framed unknowns',
  })
end

T['returns a terminal action after an accepted final synthesis'] = function()
  local ws = complete_workspace()
  add(ws, artifact('S1', 'synthesis', vim.tbl_extend('force', verified_synthesis('final'), { frame_id = 'F1' })))
  eq(Guidance.next(ws), {
    tool = 'none',
    reason = 'Final synthesis accepted; no further model action is permitted',
  })

  add(ws, evidence('E3', 'correctness'))
  eq(Guidance.next(ws), {
    tool = 'reasoning_synthesis',
    reason = 'All structural gates are ready for final synthesis',
  })
end

T['asks synthesis to cite an existing relevant review'] = function()
  local ws = complete_workspace()
  local synthesis = verified_synthesis()
  synthesis.review_ids = {}
  eq(Guidance.next(ws, synthesis), {
    tool = 'reasoning_synthesis',
    reason = 'Cite the existing relevant review in the next synthesis',
  })
end

T['asks synthesis to cite an existing contradiction resolution'] = function()
  local ws = complete_workspace()
  ws.artifacts_by_id.E2.relations.contradicts = { 'E1' }
  local resolution = add(
    ws,
    artifact('R2', 'review', {
      frame_id = 'F1',
      mode = 'full',
      target_ids = { 'E1', 'E2' },
      stress_tests = {},
      verdicts = {},
      contradiction_resolutions = {
        { left_id = 'E1', right_id = 'E2', resolution = 'Different scopes', evidence_ids = { 'E1' } },
      },
    })
  )
  resolution.relations.supports = { 'E1' }
  ws.resolved_contradictions['E1:E2'] = 'R2'
  eq(Guidance.next(ws, verified_synthesis()), {
    tool = 'reasoning_synthesis',
    reason = 'Cite the existing contradiction resolution in the next synthesis',
  })
end

T['does not count a frame-only full review as deep selected-support review'] = function()
  local ws = complete_workspace()
  ws.artifacts_by_id.R1.data.target_ids = { 'F1', 'B1' }
  eq(Guidance.next(ws, verified_synthesis()), {
    tool = 'reasoning_review',
    reason = 'Run a full review of selected or supporting artifacts',
  })
end

T['ignores branches and reviews from a superseded frame'] = function()
  local ws = complete_workspace()
  ws.artifacts_by_id.F1.status = 'superseded'
  local frame = vim.deepcopy(ws.artifacts_by_id.F1)
  frame.id = 'F2'
  frame.status = 'active'
  add(ws, frame)
  ws.frame_id = 'F2'
  eq(Guidance.next(ws), {
    tool = 'reasoning_options',
    reason = 'Create the required competing branches',
  })
end

T['does not return terminal guidance for a rejected final attempt'] = function()
  local synthesis = verified_synthesis('final')
  synthesis.selected_option_ids, synthesis.support_ids, synthesis.review_ids, synthesis.criterion_results =
    {}, {}, {}, {}
  eq(Guidance.next(workspace(), synthesis), {
    tool = 'reasoning_evidence',
    reason = 'Gather evidence for uncovered perspectives',
  })
end

T['asks synthesis to cite an available missing perspective'] = function()
  local ws = complete_workspace()
  local synthesis = verified_synthesis()
  synthesis.support_ids = { 'E1' }
  eq(Guidance.next(ws, synthesis), {
    tool = 'reasoning_synthesis',
    reason = 'Cite active evidence from every required perspective in the next synthesis',
  })
end

T['repairs stale support citations before declaring readiness'] = function()
  local ws = complete_workspace()
  ws.artifacts_by_id.F1.data.depth = 'standard'
  local synthesis = verified_synthesis()
  synthesis.selected_option_ids = { 'O2' }
  synthesis.support_ids = { 'E1' }
  synthesis.criterion_results[1].evidence_ids = { 'E2' }
  ws.artifacts_by_id.E1.status = 'superseded'
  eq(Guidance.next(ws, synthesis), {
    tool = 'reasoning_synthesis',
    reason = 'Replace inactive support citations in the next synthesis',
  })
end

T['does not reuse an old option review after same-frame branch replacement'] = function()
  local ws = complete_workspace()
  ws.artifacts_by_id.R1.data.target_ids = { 'O1' }
  ws.artifacts_by_id.B1.status = 'superseded'
  ws.artifacts_by_id.O1.status = 'superseded'
  ws.artifacts_by_id.O2.status = 'superseded'
  add(ws, artifact('B2', 'branch', { frame_id = 'F1', option_ids = { 'O3', 'O4' } }))
  add(ws, artifact('O3', 'option', { evidence_ids = { 'E1' }, predictions = { 'Replay succeeds' } }))
  add(ws, artifact('O4', 'option', { evidence_ids = { 'E2' }, predictions = { 'Snapshot loads' } }))
  eq(Guidance.next(ws), {
    tool = 'reasoning_review',
    reason = 'Run a full review of selected or supporting artifacts',
  })
end

T['ready guidance implies that final gates are empty'] = function()
  local ws = complete_workspace()
  local synthesis = verified_synthesis()
  eq(Guidance.next(ws, synthesis), {
    tool = 'reasoning_synthesis',
    reason = 'All structural gates are ready for final synthesis',
  })
  eq(Protocol.final_gates(ws, synthesis), {})
end

return T
