local Protocol = require('codecompanion._extensions.reasoning.protocol')

local string_array = { type = 'array', items = { type = 'string' } }

return {
  name = 'reasoning_review',
  cmds = {
    function(tools, args, opts)
      return Protocol.call('review', tools.chat, args)
    end,
  },
  schema = {
    type = 'function',
    ['function'] = {
      name = 'reasoning_review',
      description = 'Adversarially review active artifacts, expose assumptions and blind spots, and record keep, revise, or retract verdicts.',
      parameters = {
        type = 'object',
        properties = {
          mode = {
            type = 'string',
            enum = { 'falsification', 'assumptions', 'temporal', 'cross_perspective', 'full' },
            description = 'Select the adversarial lens; full combines defense, disconfirmation, hidden assumptions, and blind spots.',
          },
          target_ids = vim.tbl_extend('force', vim.deepcopy(string_array), {
            minItems = 1,
            description = 'Distinct active artifact IDs that every challenge and verdict must cover.',
          }),
          defense = {
            type = 'object',
            properties = { summary = { type = 'string' }, evidence_ids = string_array },
            required = { 'summary', 'evidence_ids' },
            additionalProperties = false,
          },
          challenges = {
            type = 'array',
            minItems = 1,
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
                },
                summary = { type = 'string' },
                target_ids = string_array,
                falsifier = { type = 'string' },
              },
              required = { 'kind', 'summary', 'target_ids', 'falsifier' },
              additionalProperties = false,
            },
          },
          blind_spots = string_array,
          stress_tests = {
            type = 'array',
            items = {
              type = 'object',
              properties = {
                scenario = { type = 'string' },
                prediction = { type = 'string' },
                failure_signal = { type = 'string' },
              },
              required = { 'scenario', 'prediction', 'failure_signal' },
              additionalProperties = false,
            },
          },
          verdicts = {
            type = 'array',
            items = {
              type = 'object',
              properties = {
                target_id = { type = 'string' },
                status = { type = 'string', enum = { 'keep', 'revise', 'retract' } },
                revision_instruction = {
                  type = 'string',
                  description = 'Required correction for revise; an empty string for keep or retract.',
                },
              },
              required = { 'target_id', 'status', 'revision_instruction' },
              additionalProperties = false,
            },
          },
          contradiction_resolutions = {
            type = 'array',
            items = {
              type = 'object',
              properties = {
                left_id = { type = 'string' },
                right_id = { type = 'string' },
                resolution = {
                  type = 'string',
                  description = 'Explicit qualification or resolution that permits both contradictory artifacts to remain active.',
                },
                evidence_ids = string_array,
              },
              required = { 'left_id', 'right_id', 'resolution', 'evidence_ids' },
              additionalProperties = false,
            },
          },
          structural_tradeoffs = {
            type = 'array',
            items = {
              type = 'object',
              properties = {
                statement = { type = 'string' },
                evidence_ids = string_array,
                falsifier = { type = 'string' },
              },
              required = { 'statement', 'evidence_ids', 'falsifier' },
              additionalProperties = false,
            },
          },
        },
        required = {
          'mode',
          'target_ids',
          'defense',
          'challenges',
          'blind_spots',
          'stress_tests',
          'verdicts',
          'contradiction_resolutions',
          'structural_tradeoffs',
        },
        additionalProperties = false,
      },
      strict = true,
    },
  },
}
