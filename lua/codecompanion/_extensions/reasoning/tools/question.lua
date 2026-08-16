local Control = require('codecompanion._extensions.reasoning.control')
local Output = require('codecompanion._extensions.reasoning.output')
local Protocol = require('codecompanion._extensions.reasoning.protocol')

local string_array = { type = 'array', items = { type = 'string' } }

return {
  name = 'reasoning_question',
  cmds = {
    function(tools, args, opts)
      return Protocol.call('question', tools.chat, args, Control.phase(tools.chat))
    end,
  },
  output = Output.handlers,
  schema = {
    type = 'function',
    ['function'] = {
      name = 'reasoning_question',
      description = 'Split a problem into atomic sub-questions, or close one leaf with cited evidence.',
      parameters = {
        type = 'object',
        properties = {
          action = {
            type = 'string',
            enum = { 'split', 'answer', 'drop' },
            description = 'Split a parent into children, answer one leaf, or drop one leaf with justification.',
          },
          parent_id = {
            type = 'string',
            description = 'Split only: the active frame ID for the root split, an active Q for a sub-split, or an empty string.',
          },
          axis = {
            type = 'string',
            enum = { 'none', 'component', 'phase', 'failure_mode', 'actor', 'constraint', 'data_flow' },
            description = 'Split only: the single dimension every child follows; none outside a split.',
          },
          composition = {
            type = 'string',
            enum = { 'none', 'all_of', 'one_of', 'ordered' },
            description = 'Split only: how the children combine into the parent answer; none outside a split.',
          },
          residual = {
            type = 'string',
            description = 'Split only: the part of the parent these children do not cover, or an empty string when fully covered.',
          },
          residual_disposition = {
            type = 'string',
            enum = { 'none', 'covered_elsewhere', 'out_of_scope' },
            description = 'How a non-empty residual is handled; none requires an empty residual.',
          },
          residual_covered_by = {
            type = 'string',
            description = 'Active Q covering the residual, or an empty string.',
          },
          child_questions = {
            type = 'array',
            description = 'Split only: two or more distinct sub-questions under the parent; empty for answer and drop.',
            items = {
              type = 'object',
              properties = {
                text = { type = 'string', description = 'The sub-question.' },
                kind = {
                  type = 'string',
                  enum = { 'unknown', 'sub_problem', 'option_test', 'assumption_check' },
                },
                acceptance_test = {
                  type = 'string',
                  description = 'The single observable that closes this sub-question.',
                },
                resolution_kind = {
                  type = 'string',
                  enum = { 'observation', 'computation', 'judgment' },
                },
              },
              required = { 'text', 'kind', 'acceptance_test', 'resolution_kind' },
              additionalProperties = false,
            },
          },
          question_id = {
            type = 'string',
            description = 'Answer or drop only: the active leaf Q being closed, or an empty string.',
          },
          answer = { type = 'string', description = 'What the cited evidence establishes; empty for drop.' },
          justification = {
            type = 'string',
            description = 'Why the leaf needs no answer; empty for answer.',
          },
          drop_reason = {
            type = 'string',
            enum = { 'none', 'out_of_scope', 'answered_elsewhere', 'not_material' },
          },
          evidence_ids = vim.tbl_extend('force', vim.deepcopy(string_array), {
            description = 'Active E artifacts establishing the answer or the drop.',
          }),
          acceptance_test = {
            type = 'string',
            description = 'Required when closing a provisional seeded leaf; an empty string otherwise.',
          },
          resolution_kind = {
            type = 'string',
            enum = { 'none', 'observation', 'computation', 'judgment' },
            description = 'How this leaf was resolved; none outside a closure.',
          },
          confidence = { type = 'string', enum = { 'none', 'low', 'medium', 'high' } },
        },
        required = {
          'action',
          'parent_id',
          'axis',
          'composition',
          'residual',
          'residual_disposition',
          'residual_covered_by',
          'child_questions',
          'question_id',
          'answer',
          'justification',
          'drop_reason',
          'evidence_ids',
          'acceptance_test',
          'resolution_kind',
          'confidence',
        },
        additionalProperties = false,
      },
      strict = true,
    },
  },
}
