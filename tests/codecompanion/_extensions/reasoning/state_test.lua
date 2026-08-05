local Config = require('codecompanion._extensions.reasoning.config')
local State = require('codecompanion._extensions.reasoning.state')

local T = MiniTest.new_set({
  hooks = {
    pre_case = function()
      Config.setup({ limits = { max_artifacts = 3 } })
      State._reset()
    end,
  },
})
local eq = MiniTest.expect.equality

T['isolates workspaces by chat'] = function()
  local first_chat, second_chat = {}, {}
  local first = State.begin(first_chat)
  local second = State.begin(second_chat)
  eq(first.id, 'W1')
  eq(second.id, 'W1')
  eq(State.get(first_chat), first)
  eq(State.get(second_chat), second)
end

T['allocates deterministic artifact IDs'] = function()
  local workspace = State.begin({})
  eq(State.add(workspace, 'frame', {}).id, 'F1')
  eq(State.add(workspace, 'evidence', {}).id, 'E1')
  eq(State.add(workspace, 'evidence', {}).id, 'E2')
end

T['tracks supersession and retraction'] = function()
  local workspace = State.begin({})
  local old = State.add(workspace, 'evidence', {})
  local replacement = State.add(workspace, 'evidence', {})
  workspace.open_revisions[old.id] = 'R1'
  State.supersede(workspace, old.id, replacement.id)
  eq(old.status, 'superseded')
  eq(replacement.relations.supersedes[1], old.id)
  eq(workspace.resolved_revisions.R1[old.id], {
    resolution = 'superseded',
    replacement_id = replacement.id,
  })
  workspace.open_revisions[replacement.id] = 'R2'
  State.retract(workspace, replacement.id)
  eq(replacement.status, 'retracted')
  eq(workspace.resolved_revisions.R2[replacement.id], { resolution = 'retracted' })
end

T['retires a replaced aggregate member without a cross-kind relation'] = function()
  local workspace = State.begin({})
  local option = State.add(workspace, 'option', {})
  workspace.open_revisions[option.id] = 'R1'
  State.retire(workspace, option.id)
  eq(option.status, 'superseded')
  eq(option.relations.supersedes, {})
  eq(workspace.open_revisions[option.id], nil)
  eq(workspace.resolved_revisions.R1[option.id], { resolution = 'retired' })
end

T['rejects artifacts beyond the configured limit'] = function()
  local workspace = State.begin({})
  State.add(workspace, 'frame', {})
  State.add(workspace, 'evidence', {})
  State.add(workspace, 'review', {})
  local artifact, code = State.add(workspace, 'synthesis', {})
  eq(artifact, nil)
  eq(code, 'limit_exceeded')
end

T['replaces a workspace without reusing its workspace sequence'] = function()
  local chat = {}
  eq(State.begin(chat).id, 'W1')
  eq(State.begin(chat, true).id, 'W2')
  eq(State.get(chat).artifact_order, {})
end

T['does not keep a released chat alive'] = function()
  local chat = {}
  State.begin(chat)
  eq(State._workspace_count(), 1)
  chat = nil
  collectgarbage('collect')
  collectgarbage('collect')
  eq(State._workspace_count(), 0)
end

T['tracks one revision for every externally visible mutation'] = function()
  local workspace = State.begin({})
  eq(workspace.revision, 0)
  local frame = State.add(workspace, 'frame', {})
  eq(workspace.revision, 1)
  State.set_frame(workspace, frame.id)
  eq(workspace.revision, 2)
  local evidence = State.add(workspace, 'evidence', {})
  eq(workspace.revision, 3)
  State.add_relation(workspace, evidence, 'depends_on', frame.id)
  eq(workspace.revision, 4)
  State.retract(workspace, evidence.id)
  eq(workspace.revision, 5)
  State.retire(workspace, frame.id)
  eq(workspace.revision, 6)
end

T['prepares and commits one revision-bound final'] = function()
  local chat = {}
  local workspace = State.begin(chat)
  local frame = State.add(workspace, 'frame', {})
  State.set_frame(workspace, frame.id)
  local before_revision = workspace.revision
  local stage = State.prepare_final(chat, { mode = 'final', frame_id = frame.id }, {
    depends_on = { frame.id },
  })

  eq(stage.reserved_id, 'S1')
  eq(stage.candidate.id, 'S1')
  eq(workspace.revision, before_revision)
  eq(workspace.next_sequence.synthesis, nil)
  eq(State.find(workspace, 'S1'), nil)

  local committed = State.commit_final(chat, stage)
  eq(committed.id, 'S1')
  eq(State.find(workspace, 'S1'), committed)
  eq(workspace.revision, before_revision + 1)

  local duplicate, code = State.commit_final(chat, stage)
  eq(duplicate, nil)
  eq(code, 'transaction_closed')
end

T['discards or rejects stale finals without consuming an ID'] = function()
  local chat = {}
  local workspace = State.begin(chat)
  local discarded = State.prepare_final(chat, { mode = 'final' }, {})
  eq(State.discard_final(discarded), true)
  eq(workspace.next_sequence.synthesis, nil)

  local stage = State.prepare_final(chat, { mode = 'final' }, {})
  State.add(workspace, 'evidence', {})
  local committed, code = State.commit_final(chat, stage)
  eq(committed, nil)
  eq(code, 'transaction_conflict')
  eq(State.find(workspace, 'S1'), nil)
end

T['rolls back the exact just-committed final after an emission failure'] = function()
  local chat = {}
  local workspace = State.begin(chat)
  local checkpoint = State.add(workspace, 'synthesis', { mode = 'checkpoint' })
  local stage = State.prepare_final(chat, { mode = 'final' }, { supersedes = { checkpoint.id } })
  local before = workspace.revision
  eq(State.commit_final(chat, stage).id, 'S2')

  eq(State.rollback_final(chat, stage), true)
  eq(stage.state, 'rolled_back')
  eq(workspace.revision, before)
  eq(workspace.next_sequence.synthesis, 1)
  eq(workspace.counts_by_kind.synthesis, 1)
  eq(State.find(workspace, 'S2'), nil)
  eq(State.find(workspace, checkpoint.id).status, 'active')
end

T['clears only the requested chat workspace'] = function()
  local first, second = {}, {}
  State.begin(first)
  State.begin(second)
  State.clear(first)
  eq(State.get(first), nil)
  eq(State.get(second).id, 'W1')
  eq(State.begin(first).id, 'W1')
end

return T
