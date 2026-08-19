local Shared = require('codecompanion._extensions.reasoning.tools.shared')

return Shared.tool('reasoning_amend', 'amend', {
  name = 'reasoning_amend',
  description = "Add work the investigation uncovered to the active frame while keeping every artifact, including the inquiry tree, evidence, branches, and reviews. Send only the additions: the objective, problem type, and depth stay as framed. WHEN: a new unknown, success criterion, constraint, or perspective appears mid-run, or the problem turns out to need branching or temporal stress tests. Each added unknown becomes a new provisional sub-question to close. FAILS IF: nothing is added, or an addition is malformed. Nothing can be removed here; changing the frame's identity needs reasoning_revise.",
  parameters = Shared.parameters({
    add_constraints = Shared.strings('Constraints discovered after framing; existing constraints stay.'),
    add_success_criteria = Shared.strings('Success criteria discovered after framing; existing criteria stay.'),
    add_unknowns = Shared.strings('Unknowns discovered after framing; each is seeded as a provisional sub-question.'),
    add_perspectives = {
      type = 'array',
      description = 'Perspectives discovered after framing. A name that already exists is kept as framed.',
      items = {
        type = 'object',
        properties = {
          name = { type = 'string', description = 'Short label evidence cites verbatim.' },
          purpose = { type = 'string', description = 'The failure class this viewpoint looks for.' },
        },
        required = { 'name', 'purpose' },
        additionalProperties = false,
      },
    },
    require_temporal = {
      type = 'boolean',
      description = 'Set true to start requiring temporal stress tests. False keeps the framed setting.',
    },
    require_branching = {
      type = 'boolean',
      description = 'Set true to start requiring competing branches. False keeps the framed setting.',
    },
    branching_rationale = {
      type = 'string',
      description = 'New rationale when branching starts being required; empty keeps the framed rationale.',
    },
  }),
})
