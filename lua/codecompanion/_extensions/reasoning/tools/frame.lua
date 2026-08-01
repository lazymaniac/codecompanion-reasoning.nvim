local Output = require('codecompanion._extensions.reasoning.output')
local Protocol = require('codecompanion._extensions.reasoning.protocol')

return {
  name = 'reasoning_frame',
  cmds = {
    function(tools, args, opts)
      return Protocol.call('frame', tools.chat, args)
    end,
  },
  output = Output.handlers,
  schema = {
    type = 'function',
    ['function'] = {
      name = 'reasoning_frame',
      description = 'Frame a difficult problem with explicit constraints, success criteria, unknowns, and analytical perspectives.',
      parameters = {
        type = 'object',
        properties = {
          action = {
            type = 'string',
            enum = { 'start', 'revise', 'replace' },
            description = 'Start a workspace, append a frame revision, or explicitly discard and replace the workspace.',
          },
          objective = { type = 'string', description = 'The outcome this reasoning workspace must resolve.' },
          problem_type = {
            type = 'string',
            enum = { 'analysis', 'decision', 'diagnosis', 'design', 'planning' },
            description = 'The structural problem class; all but analysis require competing branches.',
          },
          depth = {
            type = 'string',
            enum = { 'standard', 'deep' },
            description = 'Explicit protocol depth; the reasoning group prompt states the configured default.',
          },
          constraints = { type = 'array', items = { type = 'string' } },
          success_criteria = { type = 'array', items = { type = 'string' } },
          unknowns = { type = 'array', items = { type = 'string' } },
          perspectives = {
            type = 'array',
            items = {
              type = 'object',
              properties = { name = { type = 'string' }, purpose = { type = 'string' } },
              required = { 'name', 'purpose' },
              additionalProperties = false,
            },
          },
          temporal_required = {
            type = 'boolean',
            description = 'Whether transitions or evolution over time require explicit temporal stress tests.',
          },
          branching_required = { type = 'boolean', description = 'Whether competing alternatives must be developed.' },
          branching_rationale = { type = 'string', description = 'Why branching is or is not appropriate.' },
        },
        required = {
          'action',
          'objective',
          'problem_type',
          'depth',
          'constraints',
          'success_criteria',
          'unknowns',
          'perspectives',
          'temporal_required',
          'branching_required',
          'branching_rationale',
        },
        additionalProperties = false,
      },
      strict = true,
    },
  },
}
