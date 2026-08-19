local Shared = require('codecompanion._extensions.reasoning.tools.shared')

return Shared.tool('reasoning_split', 'split', {
  name = 'reasoning_split',
  description = 'Break the frame, or one open sub-question, into two or more atomic sub-questions along a single dimension. A sub-question is atomic when exactly one stated observation closes it. WHEN: right after framing, before gathering evidence, and again whenever a leaf turns out to hide several independent questions. NEXT: gather evidence for the open leaves, then close each one with reasoning_answer or reasoning_drop. FAILS IF: fewer than two children, duplicated text or acceptance tests, an already split parent, a closed leaf, an acceptance test naming more than one observable, a residual that is neither empty nor dispositioned, or a tree past its configured depth or size.',
  parameters = Shared.parameters({
    parent_id = {
      type = 'string',
      description = 'The active frame ID for the root split, or the active Q being split further.',
    },
    axis = {
      type = 'string',
      enum = { 'component', 'phase', 'failure_mode', 'actor', 'constraint', 'data_flow' },
      description = 'The single dimension every child follows.',
    },
    composition = {
      type = 'string',
      enum = { 'all_of', 'one_of', 'ordered' },
      description = 'How the children combine into the parent answer: all together, exactly one, or in sequence.',
    },
    residual = {
      type = 'string',
      description = 'The part of the parent these children do not cover; empty when they cover it completely.',
    },
    residual_disposition = {
      type = 'string',
      enum = { 'none', 'covered_elsewhere', 'out_of_scope' },
      description = 'Use none only with an empty residual; covered_elsewhere needs residual_covered_by; out_of_scope needs a frame constraint.',
    },
    residual_covered_by = {
      type = 'string',
      description = 'The active Q that covers the residual; empty unless the disposition is covered_elsewhere.',
    },
    child_questions = {
      type = 'array',
      minItems = 2,
      description = 'Two or more children with distinct text and distinct acceptance tests.',
      items = {
        type = 'object',
        properties = {
          text = { type = 'string', description = 'The sub-question.' },
          kind = {
            type = 'string',
            enum = { 'unknown', 'sub_problem', 'option_test', 'assumption_check' },
            description = 'What this sub-question resolves.',
          },
          acceptance_test = {
            type = 'string',
            description = 'The single observable that closes it. Naming two observables is rejected as non-atomic.',
          },
          resolution_kind = {
            type = 'string',
            enum = { 'observation', 'computation', 'judgment' },
            description = 'How it will be closed. Judgment closures need an adversarial review first.',
          },
        },
        required = { 'text', 'kind', 'acceptance_test', 'resolution_kind' },
        additionalProperties = false,
      },
    },
  }),
})
