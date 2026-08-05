local Config = require('codecompanion._extensions.reasoning.config')
local Schema = require('codecompanion._extensions.reasoning.schema')

local T = MiniTest.new_set({ hooks = {
  pre_case = function()
    Config.setup()
  end,
} })
local eq = MiniTest.expect.equality

T['exposes default evidence batch bounds'] = function()
  local tool = Schema.resolve('reasoning_evidence', require('codecompanion._extensions.reasoning.tools.evidence'))
  local items = tool.schema['function'].parameters.properties.items
  eq(items.minItems, 1)
  eq(items.maxItems, 8)
end

T['applies current evidence batch, array, and text limits'] = function()
  Config.setup({ limits = { max_batch_items = 3, max_array_items = 5, max_text_chars = 111 } })
  local tool = Schema.resolve('reasoning_evidence', require('codecompanion._extensions.reasoning.tools.evidence'))
  local items = tool.schema['function'].parameters.properties.items
  eq(items.minItems, 1)
  eq(items.maxItems, 3)
  eq(items.items.properties.statement.maxLength, 111)
  eq(items.items.properties.supports.maxItems, 5)
  eq(items.items.properties.supports.uniqueItems, true)
  eq(items.items.properties.supports.items.maxLength, nil)
  eq(items.items.properties.supersedes_id.minLength, nil)
end

T['returns a fresh schema after configuration changes'] = function()
  local template = require('codecompanion._extensions.reasoning.tools.evidence')
  Config.setup({ limits = { max_batch_items = 4 } })
  local first = Schema.resolve('reasoning_evidence', template)
  Config.setup({ limits = { max_batch_items = 2 } })
  local second = Schema.resolve('reasoning_evidence', template)
  eq(first.schema['function'].parameters.properties.items.maxItems, 4)
  eq(second.schema['function'].parameters.properties.items.maxItems, 2)
end

T['dealiases shared review arrays before path-specific constraints'] = function()
  Config.setup({ limits = { max_array_items = 5, max_text_chars = 111 } })
  local tool = Schema.resolve('reasoning_review', require('codecompanion._extensions.reasoning.tools.review'))
  local properties = tool.schema['function'].parameters.properties
  eq(properties.defense.properties.evidence_ids.uniqueItems, true)
  eq(properties.defense.properties.evidence_ids.items.maxLength, nil)
  eq(properties.blind_spots.uniqueItems, nil)
  eq(properties.blind_spots.items.maxLength, 111)
  eq(properties.challenges.items.properties.target_ids.items.maxLength, nil)
end

T['leaves permitted-empty IDs unconstrained as prose'] = function()
  Config.setup({ limits = { max_text_chars = 111 } })
  local evidence = Schema.resolve('reasoning_evidence', require('codecompanion._extensions.reasoning.tools.evidence'))
  local options = Schema.resolve('reasoning_options', require('codecompanion._extensions.reasoning.tools.options'))
  local evidence_id = evidence.schema['function'].parameters.properties.items.items.properties.supersedes_id
  local branch_id = options.schema['function'].parameters.properties.supersedes_branch_id

  eq({ evidence_id.minLength, evidence_id.maxLength }, {})
  eq({ branch_id.minLength, branch_id.maxLength }, {})
end

return T
