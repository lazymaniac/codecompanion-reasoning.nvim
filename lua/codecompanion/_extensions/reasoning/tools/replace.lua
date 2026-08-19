local Shared = require('codecompanion._extensions.reasoning.tools.shared')

return Shared.tool('reasoning_replace', 'replace', {
  name = 'reasoning_replace',
  description = 'Discard the entire workspace and reason again from a new frame. Every artifact, sub-question, and closure is dropped and IDs restart. WHEN: the work so far is unusable, not merely incomplete. Prefer reasoning_revise, which keeps the workspace, unless the existing evidence and branches are actually worthless.',
  parameters = Shared.parameters(Shared.frame_properties()),
})
