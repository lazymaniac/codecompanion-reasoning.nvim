local Protocol = require('codecompanion._extensions.reasoning.protocol')

local string_array = { type = 'array', items = { type = 'string' } }

return {
  name = 'reasoning_synthesis',
  cmds = {
    function(tools, args, opts)
      return Protocol.call('synthesis', tools.chat, args)
    end,
  },
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
          conclusion = { type = 'string' },
          selected_option_ids = string_array,
          support_ids = string_array,
          review_ids = string_array,
          criterion_results = {
            type = 'array',
            items = {
              type = 'object',
              properties = {
                criterion = { type = 'string' },
                status = { type = 'string', enum = { 'passed', 'failed', 'pending', 'not_applicable' } },
                evidence_ids = string_array,
                explanation = { type = 'string' },
              },
              required = { 'criterion', 'status', 'evidence_ids', 'explanation' },
              additionalProperties = false,
            },
          },
          tradeoffs = string_array,
          uncertainties = string_array,
          blind_spots = string_array,
          next_actions = string_array,
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
