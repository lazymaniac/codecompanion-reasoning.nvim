local Shared = require('codecompanion._extensions.reasoning.tools.shared')

local properties = Shared.synthesis_properties()
properties.tradeoffs = Shared.strings('Decision-relevant costs the conclusion accepts.')
properties.uncertainties = Shared.strings('Material uncertainties that remain after review.')
properties.blind_spots = Shared.strings('Important areas the reasoning may still omit.')
properties.next_actions = Shared.strings('Concrete follow-up actions the conclusion implies.')

return Shared.tool('reasoning_final', 'final', {
  name = 'reasoning_final',
  description = 'Publish the answer. WHEN: every open leaf is closed, the evidence covers the framed perspectives and unknowns, the required branches exist with a supported selection, the required reviews are recorded and their corrections applied, no contradiction is unresolved, and every success criterion is verified. Cite only active artifacts: the selected option, the supporting evidence, the reviews relied on, and one result per success criterion. A rejected attempt changes nothing and reports its unmet gates, so read them and satisfy the one next_action names. Once accepted, the rendered result is the reply and the run is terminal until the user reframes.',
  parameters = Shared.parameters(properties),
})
