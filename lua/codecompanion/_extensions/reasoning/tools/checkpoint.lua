local Shared = require('codecompanion._extensions.reasoning.tools.shared')

return Shared.tool('reasoning_checkpoint', 'checkpoint', {
  name = 'reasoning_checkpoint',
  description = 'Record the progress established so far without claiming completion, and read back which gates a final would still fail. WHEN: optional, on a long run, to consolidate what is settled or to preview the remaining gates before attempting a final. It publishes nothing and starts no answer. NEXT: the tool that next_action names, and eventually reasoning_final.',
  parameters = Shared.parameters(Shared.synthesis_properties()),
})
