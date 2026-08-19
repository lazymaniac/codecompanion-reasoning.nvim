local Shared = require('codecompanion._extensions.reasoning.tools.shared')

return Shared.tool('reasoning_revise', 'revise', {
  name = 'reasoning_revise',
  description = 'Restate the whole frame when its objective, problem type, depth, or wording was wrong. The workspace survives, but every downstream artifact is retired and each unknown is seeded again. WHEN: the frame itself misdescribes the problem, or new user information changes what is being asked. Prefer reasoning_amend when the frame is right and only needs additions. NEXT: the retired work must be rebuilt from evidence onward.',
  parameters = Shared.parameters(Shared.frame_properties()),
})
