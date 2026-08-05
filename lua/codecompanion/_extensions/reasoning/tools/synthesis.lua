local Control = require('codecompanion._extensions.reasoning.control')
local Output = require('codecompanion._extensions.reasoning.output')
local Protocol = require('codecompanion._extensions.reasoning.protocol')

local string_array = { type = 'array', items = { type = 'string' } }

local function described_array(description)
  return vim.tbl_extend('force', vim.deepcopy(string_array), { description = description })
end

return {
  name = 'reasoning_synthesis',
  cmds = {
    function(tools, args, opts)
      return Protocol.call('synthesis', tools.chat, args, Control.phase(tools.chat))
    end,
  },
  output = Output.handlers,
  schema = {
    type = 'function',
    ['function'] = {
      name = 'reasoning_synthesis',
      description = 'Record a checkpoint or produce a final conclusion after deterministic reasoning gates pass.',
      parameters = {
        type = 'object',
        properties = {
          mode = {
            type = 'string',
            enum = { 'checkpoint', 'final' },
            description = 'Checkpoint records valid progress; final is rejected until every structural gate passes.',
          },
          conclusion = { type = 'string', description = 'The concise result justified by the cited artifacts.' },
          selected_option_ids = described_array(
            'Active O artifacts selected from the current branch set; empty only when no option selection is required.'
          ),
          support_ids = described_array('Active E artifacts that directly support the conclusion.'),
          review_ids = described_array(
            'Active, current-frame R artifacts relied on by the conclusion, including relevant resolution reviews.'
          ),
          criterion_results = {
            type = 'array',
            description = 'Exactly one result for every active-frame success criterion, using the criterion text.',
            items = {
              type = 'object',
              properties = {
                criterion = { type = 'string', description = 'Exact success criterion from the active frame.' },
                status = {
                  type = 'string',
                  enum = { 'passed', 'failed', 'pending', 'not_applicable' },
                  description = 'Final mode accepts only supported passed results or explained not_applicable results.',
                },
                evidence_ids = described_array(
                  'Active E artifacts verifying a passed criterion; empty only when evidence is not required.'
                ),
                explanation = { type = 'string', description = 'Why the status follows from the cited evidence.' },
              },
              required = { 'criterion', 'status', 'evidence_ids', 'explanation' },
              additionalProperties = false,
            },
          },
          tradeoffs = described_array('Decision-relevant costs accepted by the conclusion.'),
          uncertainties = described_array('Material uncertainties that remain after review.'),
          blind_spots = described_array('Important areas the reasoning may still omit.'),
          next_actions = described_array('Concrete follow-up actions implied by the conclusion.'),
          confidence = { type = 'string', enum = { 'low', 'medium', 'high' } },
        },
        required = {
          'mode',
          'conclusion',
          'selected_option_ids',
          'support_ids',
          'review_ids',
          'criterion_results',
          'tradeoffs',
          'uncertainties',
          'blind_spots',
          'next_actions',
          'confidence',
        },
        additionalProperties = false,
      },
      strict = true,
    },
  },
}
