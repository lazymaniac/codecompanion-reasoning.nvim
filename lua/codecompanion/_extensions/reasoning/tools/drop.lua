local Shared = require('codecompanion._extensions.reasoning.tools.shared')

return Shared.tool('reasoning_drop', 'drop', {
  name = 'reasoning_drop',
  description = "Close one open leaf sub-question that does not need an answer, with a classified justification. WHEN: the question is outside the frame's constraints, already answered by another leaf, or immaterial to the objective. Use it rather than leaving a leaf open, because open leaves block the final. FAILS IF: the target is not an active leaf, an out_of_scope drop does not quote an active frame constraint exactly, or an answered_elsewhere or not_material drop cites no active evidence.",
  parameters = Shared.parameters({
    question_id = { type = 'string', description = 'The active leaf Q being dropped.' },
    drop_reason = {
      type = 'string',
      enum = { 'out_of_scope', 'answered_elsewhere', 'not_material' },
      description = 'Why no answer is needed. Out_of_scope quotes a frame constraint; the other two cite evidence.',
    },
    justification = {
      type = 'string',
      description = 'Why the leaf needs no answer. For out_of_scope this must quote an active frame constraint exactly.',
    },
    evidence_ids = Shared.strings(
      'Active E artifacts supporting the drop; required unless the reason is out_of_scope.'
    ),
  }),
})
