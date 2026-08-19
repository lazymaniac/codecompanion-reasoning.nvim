local Shared = require('codecompanion._extensions.reasoning.tools.shared')

return Shared.tool('reasoning_options', 'options', {
  name = 'reasoning_options',
  description = 'Create a set of two to six genuinely competing solutions, hypotheses, or scenarios, each grounded in active evidence and each stating an observable prediction. WHEN: the frame requires branching and no branch set exists yet. Do not select a winner here; selection happens in the final. NEXT: attack the strongest alternative with reasoning_review. FAILS IF: fewer than two alternatives, an alternative cites no active evidence or states no prediction, or the criteria are empty or duplicated.',
  parameters = Shared.parameters(Shared.branch_properties()),
})
