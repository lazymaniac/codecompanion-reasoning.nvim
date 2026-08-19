local Shared = require('codecompanion._extensions.reasoning.tools.shared')

return Shared.tool('reasoning_answer', 'answer', {
  name = 'reasoning_answer',
  description = "Close one open leaf sub-question by stating what cited active evidence establishes. WHEN: the recorded evidence satisfies that leaf's acceptance test; next_action names the leaf. NEXT: the remaining open leaves, in the order the frontier lists them. The closure holds only while its evidence stays active: retracting that evidence reopens the leaf and blocks the final again. FAILS IF: the target is not an active leaf, it is already closed, no active evidence is cited, an observation closure cites no observation item, or a judgment closure has no adversarial review behind it.",
  parameters = Shared.parameters({
    question_id = { type = 'string', description = 'The active leaf Q being closed.' },
    answer = { type = 'string', description = 'What the cited evidence establishes about this sub-question.' },
    evidence_ids = Shared.strings('Active E artifacts that establish the answer.', { minItems = 1 }),
    acceptance_test = {
      type = 'string',
      description = 'The single observable this answer satisfies; a seeded unknown states its test here for the first time.',
    },
    resolution_kind = {
      type = 'string',
      enum = { 'observation', 'computation', 'judgment' },
      description = 'How this leaf was resolved. Observation closures need an observation item; judgment closures need a review.',
    },
    confidence = {
      type = 'string',
      enum = { 'low', 'medium', 'high' },
      description = 'Confidence that the cited evidence closes this sub-question.',
    },
  }),
})
