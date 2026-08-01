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

return T
