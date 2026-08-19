local Shared = require('codecompanion._extensions.reasoning.tools.shared')

return Shared.tool('reasoning_resolve_contradiction', 'resolve_contradiction', {
  name = 'reasoning_resolve_contradiction',
  description = 'Reconcile two active artifacts that contradict each other by recording the qualification under which both stand, with the evidence that supports it. WHEN: evidence declared a contradiction and next_action names this tool; the final stays blocked until the pair is resolved. Both artifacts are kept, so use reasoning_review with a retract verdict instead when one of them is simply wrong. NOTE: a resolution carries no stress test, so a temporal frame still needs a stress-tested review before the final. FAILS IF: the two IDs are the same, the pair has no active contradiction between them, or no active evidence supports the resolution.',
  parameters = Shared.parameters({
    left_id = { type = 'string', description = 'One active artifact in the contradicting pair.' },
    right_id = { type = 'string', description = 'The other active artifact; it must differ from left_id.' },
    contradiction = { type = 'string', description = 'What the two artifacts actually disagree about.' },
    resolution = {
      type = 'string',
      description = 'The qualification that lets both stand, such as the condition under which each holds.',
    },
    evidence_ids = Shared.strings('Active E artifacts supporting the resolution.', { minItems = 1 }),
    falsifier = { type = 'string', description = 'The observation that would show the resolution is wrong.' },
  }),
})
