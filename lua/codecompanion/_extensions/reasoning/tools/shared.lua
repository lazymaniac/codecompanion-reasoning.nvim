local Control = require('codecompanion._extensions.reasoning.control')
local Output = require('codecompanion._extensions.reasoning.output')
local Protocol = require('codecompanion._extensions.reasoning.protocol')

local M = {}

--- Every reasoning tool runs one protocol operation and reports through the
--- same deterministic output handlers.
function M.tool(name, operation, schema_function)
  return {
    name = name,
    cmds = {
      function(tools, args, _opts)
        return Protocol.call(operation, tools.chat, args, Control.phase(tools.chat))
      end,
    },
    output = Output.handlers,
    schema = {
      type = 'function',
      ['function'] = vim.tbl_extend('force', { strict = true }, schema_function),
    },
  }
end

function M.strings(description, extra)
  local node = { type = 'array', items = { type = 'string' } }
  if description then
    node.description = description
  end
  return vim.tbl_extend('force', node, extra or {})
end

function M.parameters(properties)
  local required = {}
  for name in pairs(properties) do
    table.insert(required, name)
  end
  table.sort(required)
  return {
    type = 'object',
    properties = properties,
    required = required,
    additionalProperties = false,
  }
end

--- The frame fields shared by start, revise, and replace. Amend takes only
--- additions and reuses the active frame for everything else. The three share
--- one vocabulary on purpose: identical fields read identically, and each tool
--- description carries what differs.
function M.frame_properties()
  return {
    objective = { type = 'string', description = 'The outcome this reasoning workspace must resolve.' },
    problem_type = {
      type = 'string',
      enum = { 'analysis', 'decision', 'diagnosis', 'design', 'planning' },
      description = 'The structural problem class; all but analysis require competing branches.',
    },
    depth = {
      type = 'string',
      enum = { 'standard', 'deep' },
      description = 'Protocol depth. Deep requires a root decomposition, two perspectives, and a full review.',
    },
    constraints = M.strings('Fixed limits the answer must respect; an out-of-scope drop must quote one exactly.'),
    success_criteria = M.strings('What the final answer must demonstrate; every criterion is verified in the final.'),
    unknowns = M.strings('What is not yet known. Each one is seeded as a provisional sub-question to close.'),
    perspectives = {
      type = 'array',
      minItems = 1,
      description = 'Analytical viewpoints evidence must cover. Deep frames require at least two.',
      items = {
        type = 'object',
        properties = {
          name = { type = 'string', description = 'Short label evidence cites verbatim.' },
          purpose = { type = 'string', description = 'The failure class this viewpoint looks for.' },
        },
        required = { 'name', 'purpose' },
        additionalProperties = false,
      },
    },
    temporal_required = {
      type = 'boolean',
      description = 'True when behaviour over time matters; every review then needs a temporal stress test.',
    },
    branching_required = {
      type = 'boolean',
      description = 'True when competing alternatives must be developed and one selected.',
    },
    branching_rationale = { type = 'string', description = 'Why branching is or is not appropriate here.' },
  }
end

--- The branch-set fields shared by creating and replacing a set of options.
function M.branch_properties()
  return {
    question = { type = 'string', description = 'The decision or uncertainty these alternatives address.' },
    branch_type = {
      type = 'string',
      enum = { 'solution', 'hypothesis', 'scenario' },
      description = 'Solution for designs, hypothesis for diagnoses, scenario for possible futures.',
    },
    criteria = M.strings('One to eight criteria that genuinely distinguish the alternatives.', {
      minItems = 1,
      maxItems = 8,
    }),
    options = {
      type = 'array',
      minItems = 2,
      maxItems = 6,
      description = 'Two to six competing alternatives, each grounded in active evidence.',
      items = {
        type = 'object',
        properties = {
          label = { type = 'string', description = 'Short name for this alternative.' },
          summary = { type = 'string', description = 'What this alternative actually does.' },
          evidence_ids = M.strings('Active E artifacts that ground this alternative.', { minItems = 1 }),
          assumptions = M.strings('What must hold for this alternative to work.'),
          predictions = M.strings('Observable results expected if this alternative is correct.', { minItems = 1 }),
          benefits = M.strings('What this alternative gains.'),
          costs = M.strings('What this alternative costs.'),
          risks = M.strings('What could go wrong with this alternative.'),
          reversibility = {
            type = 'string',
            enum = { 'easy', 'moderate', 'hard' },
            description = 'How hard this alternative is to undo once adopted.',
          },
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
  }
end

--- The synthesis fields shared by a checkpoint and a final result.
function M.synthesis_properties()
  return {
    conclusion = { type = 'string', description = 'The concise result justified by the cited artifacts.' },
    selected_option_ids = M.strings(
      'Active O artifacts selected from the current branch set; empty when no selection is required.'
    ),
    support_ids = M.strings('Active E artifacts that directly support the conclusion.'),
    review_ids = M.strings('Active R artifacts relied on, including any contradiction resolution.'),
    criterion_results = {
      type = 'array',
      description = 'One result per active-frame success criterion, quoting the criterion text exactly.',
      items = {
        type = 'object',
        properties = {
          criterion = { type = 'string', description = 'Exact success criterion from the active frame.' },
          status = {
            type = 'string',
            enum = { 'passed', 'failed', 'pending', 'not_applicable' },
            description = 'A final accepts only supported passed results or explained not_applicable results.',
          },
          evidence_ids = M.strings('Active E artifacts verifying a passed criterion.'),
          explanation = { type = 'string', description = 'Why the status follows from the cited evidence.' },
        },
        required = { 'criterion', 'status', 'evidence_ids', 'explanation' },
        additionalProperties = false,
      },
    },
    confidence = {
      type = 'string',
      enum = { 'low', 'medium', 'high' },
      description = 'Confidence in the conclusion given the cited support.',
    },
  }
end

return M
