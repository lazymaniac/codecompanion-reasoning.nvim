local Output = require('codecompanion._extensions.reasoning.output')
local Protocol = require('codecompanion._extensions.reasoning.protocol')

return {
  name = 'reasoning_evidence',
  cmds = {
    function(tools, args, opts)
      return Protocol.call('evidence', tools.chat, args)
    end,
  },
  output = Output.handlers,
  schema = {
    type = 'function',
    ['function'] = {
      name = 'reasoning_evidence',
      description = 'Record bounded, sourced, falsifiable observations, claims, or assumptions for the active reasoning frame.',
      parameters = {
        type = 'object',
        properties = {
          items = {
            type = 'array',
            items = {
              type = 'object',
              properties = {
                kind = {
                  type = 'string',
                  enum = { 'observation', 'claim', 'assumption' },
                  description = 'Observation is directly sourced, claim is derived, and assumption is explicitly provisional.',
                },
                statement = { type = 'string' },
                source = {
                  type = 'string',
                  description = 'Concrete basis; assumption sources must begin with assumption: and observations cannot use unknown.',
                },
                confidence = { type = 'string', enum = { 'low', 'medium', 'high' } },
                falsifier = {
                  type = 'string',
                  description = 'Observable evidence that would overturn or materially revise the item.',
                },
                perspective = { type = 'string', description = 'Exact perspective name from the active frame.' },
                addresses_unknowns = {
                  type = 'array',
                  items = { type = 'string' },
                  description = 'Exact active-frame unknowns addressed by this item; empty when it addresses none.',
                },
                supports = { type = 'array', items = { type = 'string' } },
                contradicts = { type = 'array', items = { type = 'string' } },
                qualifies = { type = 'array', items = { type = 'string' } },
                supersedes_id = {
                  type = 'string',
                  description = 'Active E artifact replaced by this item, or an empty string.',
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
                'supports',
                'contradicts',
                'qualifies',
                'supersedes_id',
              },
              additionalProperties = false,
            },
          },
        },
        required = { 'items' },
        additionalProperties = false,
      },
      strict = true,
    },
  },
}
