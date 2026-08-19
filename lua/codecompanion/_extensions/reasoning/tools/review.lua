local Shared = require('codecompanion._extensions.reasoning.tools.shared')

return Shared.tool('reasoning_review', 'review', {
  name = 'reasoning_review',
  description = 'Attack the strongest current case: defend it, challenge it with falsifiable objections, name what it may still miss, and give every target exactly one keep, revise, or retract verdict. WHEN: competing alternatives exist, before a final on a deep frame, and whenever a claim needs adversarial pressure. A revise verdict opens a correction the owning tool must satisfy; a retract verdict deactivates the target. NEXT: apply the corrections, then the final. MODES: falsification needs a disconfirming challenge; assumptions needs a hidden-assumption challenge; cross_perspective needs two targets grounded in two perspectives; temporal needs a stress test; full needs defense evidence, a blind spot, and both challenge kinds, and a deep frame needs a full review before its final. To reconcile two contradictory artifacts, use reasoning_resolve_contradiction instead. FAILS IF: a target receives no challenge or not exactly one verdict, the frame requires temporal reasoning and no stress test is given, a frame is retracted, or an option is retracted outside its branch set.',
  parameters = Shared.parameters({
    mode = {
      type = 'string',
      enum = { 'falsification', 'assumptions', 'temporal', 'cross_perspective', 'full' },
      description = 'The adversarial lens. Deep frames need a full review before the final.',
    },
    target_ids = Shared.strings(
      'Distinct active artifacts under review; every one needs a challenge and exactly one verdict.',
      { minItems = 1 }
    ),
    defense = {
      type = 'object',
      description = 'The strongest case for the targets before they are attacked.',
      properties = {
        summary = { type = 'string', description = 'Why the current case holds.' },
        evidence_ids = Shared.strings('Active E artifacts behind the defense; a full review requires at least one.'),
      },
      required = { 'summary', 'evidence_ids' },
      additionalProperties = false,
    },
    challenges = {
      type = 'array',
      minItems = 1,
      description = 'Attacks on the targets; together they must cover every target ID.',
      items = {
        type = 'object',
        properties = {
          kind = {
            type = 'string',
            enum = {
              'counterexample',
              'missing_evidence',
              'hidden_assumption',
              'temporal_failure',
              'overclaim',
              'underclaim',
            },
            description = 'What kind of weakness this attack exposes.',
          },
          summary = { type = 'string', description = 'The attack itself.' },
          target_ids = Shared.strings('Which of the reviewed targets this attack hits.', { minItems = 1 }),
          falsifier = { type = 'string', description = 'The observation that would defeat this attack.' },
        },
        required = { 'kind', 'summary', 'target_ids', 'falsifier' },
        additionalProperties = false,
      },
    },
    blind_spots = Shared.strings('What this reasoning may still be missing; a full review requires at least one.'),
    stress_tests = {
      type = 'array',
      description = 'Behaviour over time. Required for a temporal review and for every review of a temporal frame.',
      items = {
        type = 'object',
        properties = {
          scenario = { type = 'string', description = 'The situation being pushed through time.' },
          prediction = { type = 'string', description = 'What the current case predicts happens.' },
          failure_signal = { type = 'string', description = 'What would show the prediction wrong.' },
        },
        required = { 'scenario', 'prediction', 'failure_signal' },
        additionalProperties = false,
      },
    },
    verdicts = {
      type = 'array',
      description = 'Exactly one verdict per target ID.',
      items = {
        type = 'object',
        properties = {
          target_id = { type = 'string', description = 'The reviewed artifact.' },
          status = {
            type = 'string',
            enum = { 'keep', 'revise', 'retract' },
            description = 'Keep leaves it active, revise opens a correction the owning tool must satisfy, retract deactivates it. A frame is revised rather than retracted, and an option only through its branch set.',
          },
          revision_instruction = {
            type = 'string',
            description = 'The required correction for a revise verdict; an empty string for keep or retract.',
          },
        },
        required = { 'target_id', 'status', 'revision_instruction' },
        additionalProperties = false,
      },
    },
    structural_tradeoffs = {
      type = 'array',
      description = 'Trade-offs inherent to the problem rather than to one alternative.',
      items = {
        type = 'object',
        properties = {
          statement = { type = 'string', description = 'The trade-off that cannot be designed away.' },
          evidence_ids = Shared.strings('Active E artifacts behind the trade-off.'),
          falsifier = { type = 'string', description = 'What would show the trade-off is avoidable.' },
        },
        required = { 'statement', 'evidence_ids', 'falsifier' },
        additionalProperties = false,
      },
    },
  }),
})
