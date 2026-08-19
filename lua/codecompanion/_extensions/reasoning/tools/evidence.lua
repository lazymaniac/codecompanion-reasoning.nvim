local Shared = require('codecompanion._extensions.reasoning.tools.shared')

return Shared.tool('reasoning_evidence', 'evidence', {
  name = 'reasoning_evidence',
  description = "Record what the investigation found: observations with a concrete source, claims derived from them, and explicitly labelled assumptions. Record several items in one call. WHEN: after the problem is split, to close the open leaf that next_action names, to cover a framed perspective, or to resolve a framed unknown. Link each item to the sub-questions it helps close and the unknowns it addresses, and declare contradictions with contradicts, which blocks the final until reasoning_resolve_contradiction settles them. NEXT: close the leaf with reasoning_answer. FAILS IF: an item lacks a concrete source, an assumption source does not begin with 'assumption:', the perspective is not one the frame declares, a falsifier is missing, or a referenced artifact is not active.",
  parameters = Shared.parameters({
    items = {
      type = 'array',
      description = 'One batch of evidence items for the active frame.',
      items = {
        type = 'object',
        properties = {
          kind = {
            type = 'string',
            enum = { 'observation', 'claim', 'assumption' },
            description = 'Observation is directly sourced, claim is derived from other items, assumption is provisional.',
          },
          statement = { type = 'string', description = 'What is the case, stated so it can be checked.' },
          source = {
            type = 'string',
            description = 'Concrete basis such as file:line, a command, or a test name. An assumption source must begin with "assumption:", and an observation may not use unknown, unspecified, or none.',
          },
          confidence = {
            type = 'string',
            enum = { 'low', 'medium', 'high' },
            description = 'Confidence in this item given its source.',
          },
          falsifier = {
            type = 'string',
            description = 'The observation that would overturn or materially revise this item.',
          },
          perspective = {
            type = 'string',
            description = 'Exact perspective name from the active frame.',
          },
          addresses_unknowns = Shared.strings(
            'Exact active-frame unknowns this item resolves; empty when it resolves none.'
          ),
          addresses_questions = Shared.strings(
            'Active Q sub-questions this item helps close; empty when it helps close none.'
          ),
          supports = Shared.strings('Active artifacts this item strengthens.'),
          contradicts = Shared.strings(
            'Active artifacts this item conflicts with; a contradiction blocks the final until resolved.'
          ),
          qualifies = Shared.strings('Active artifacts this item narrows or conditions.'),
          supersedes_id = {
            type = 'string',
            description = 'Active E artifact this item replaces, or an empty string for new evidence.',
          },
        },
        required = {
          'kind',
          'statement',
          'source',
          'confidence',
          'falsifier',
          'perspective',
          'addresses_unknowns',
          'addresses_questions',
          'supports',
          'contradicts',
          'qualifies',
          'supersedes_id',
        },
        additionalProperties = false,
      },
    },
  }),
})
