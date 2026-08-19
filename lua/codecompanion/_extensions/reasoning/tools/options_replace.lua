local Shared = require('codecompanion._extensions.reasoning.tools.shared')

local properties = Shared.branch_properties()
properties.supersedes_branch_id = {
  type = 'string',
  description = 'The active B artifact being replaced; its options are retired together.',
}

return Shared.tool('reasoning_options_replace', 'options_replace', {
  name = 'reasoning_options_replace',
  description = 'Replace an existing branch set with a corrected one, retiring the old set and its options together. WHEN: a review opened a revision on an option or on the set, or an option lost the evidence that grounded it. Options are never edited individually: restate the whole set, including the alternatives that did not change. FAILS IF: the superseded ID is not the single active branch set, or the replacement itself is not a valid branch set.',
  parameters = Shared.parameters(properties),
})
