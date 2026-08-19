local Shared = require('codecompanion._extensions.reasoning.tools.shared')

return Shared.tool('reasoning_start', 'start', {
  name = 'reasoning_start',
  description = 'Open the reasoning workspace by framing the problem: the objective, the constraints, what would count as success, what is still unknown, and the perspectives the evidence must cover. WHEN: the first reasoning call of the run, exactly once. NEXT: a deep frame, or any frame that declares unknowns, must be split into sub-questions before evidence is gathered; each unknown is seeded as a provisional sub-question. FAILS IF: a workspace is already open (reframe with reasoning_revise or reasoning_replace), a deep frame declares fewer than two perspectives, or a decision, diagnosis, design, or planning frame does not require branching.',
  parameters = Shared.parameters(Shared.frame_properties()),
})
