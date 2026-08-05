local Control = require('codecompanion._extensions.reasoning.control')
local Output = require('codecompanion._extensions.reasoning.output')
local Protocol = require('codecompanion._extensions.reasoning.protocol')

local string_array = { type = 'array', items = { type = 'string' } }

return {
  name = 'reasoning_options',
  cmds = {
    function(tools, args, opts)
      return Protocol.call('options', tools.chat, args, Control.phase(tools.chat))
    end,
  },
  output = Output.handlers,
  schema = {
    type = 'function',
    ['function'] = {
      name = 'reasoning_options',
      description = 'Create or replace a coherent set of competing solutions, hypotheses, or scenarios.',
      parameters = {
        type = 'object',
        properties = {
          question = { type = 'string', description = 'The decision or uncertainty these branches address.' },
          branch_type = {
            type = 'string',
            enum = { 'solution', 'hypothesis', 'scenario' },
            description = 'Use solution for designs, hypothesis for diagnoses, and scenario for possible futures.',
          },
          criteria = vim.tbl_extend('force', vim.deepcopy(string_array), {
            minItems = 1,
            maxItems = 8,
            description = 'One to eight criteria that distinguish the alternatives.',
          }),
          supersedes_branch_id = {
            type = 'string',
            description = 'Active B artifact replaced as one complete branch set, or an empty string.',
          },
          options = {
            type = 'array',
            minItems = 2,
            maxItems = 6,
            items = {
              type = 'object',
              properties = {
                label = { type = 'string' },
                summary = { type = 'string' },
                evidence_ids = vim.tbl_extend('force', vim.deepcopy(string_array), {
                  minItems = 1,
                  description = 'One or more active E artifacts that ground this alternative.',
                }),
                assumptions = string_array,
                predictions = vim.tbl_extend('force', vim.deepcopy(string_array), {
                  minItems = 1,
                  description = 'At least one observable result expected if this alternative is correct.',
                }),
                benefits = string_array,
                costs = string_array,
                risks = string_array,
                reversibility = { type = 'string', enum = { 'easy', 'moderate', 'hard' } },
              },
              required = {
                'label',
                'summary',
                'evidence_ids',
                'assumptions',
                'predictions',
                'benefits',
                'costs',
                'risks',
                'reversibility',
              },
              additionalProperties = false,
            },
          },
        },
        required = { 'question', 'branch_type', 'criteria', 'supersedes_branch_id', 'options' },
        additionalProperties = false,
      },
      strict = true,
    },
  },
}
