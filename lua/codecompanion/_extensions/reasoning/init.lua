local Config = require('codecompanion._extensions.reasoning.config')

local M = {}
local owned_default_tools = setmetatable({}, { __mode = 'k' })
local tool_names = {
  'reasoning_frame',
  'reasoning_evidence',
  'reasoning_options',
  'reasoning_review',
  'reasoning_synthesis',
}

local paths = {
  reasoning_frame = '_extensions.reasoning.tools.frame',
  reasoning_evidence = '_extensions.reasoning.tools.evidence',
  reasoning_options = '_extensions.reasoning.tools.options',
  reasoning_review = '_extensions.reasoning.tools.review',
  reasoning_synthesis = '_extensions.reasoning.tools.synthesis',
}

local descriptions = {
  reasoning_frame = 'Frame a difficult problem before developing conclusions',
  reasoning_evidence = 'Record sourced and falsifiable evidence or assumptions',
  reasoning_options = 'Create competing solutions, hypotheses, or scenarios',
  reasoning_review = 'Adversarially challenge and revise reasoning artifacts',
  reasoning_synthesis = 'Record a checkpoint or gated final synthesis',
}

function M.setup(user_options)
  local options = Config.setup(user_options)
  local tools = require('codecompanion.config').interactions.chat.tools
  tools.groups = tools.groups or {}
  tools.opts = tools.opts or {}
  tools.opts.default_tools = tools.opts.default_tools or {}
  for _, name in ipairs(tool_names) do
    tools[name] = vim.tbl_deep_extend('force', {
      path = paths[name],
      description = descriptions[name],
    }, tools[name] or {})
  end
  local system_prompt = string.format(
    [[<structured_reasoning>
Use this protocol for difficult problems. Routine requests do not need the group.
Treat each result's next_action.tool as the protocol state transition.
Call exactly one reasoning tool at a time; never batch reasoning calls.
Satisfy next_action.reason before making the next call. Never repeat unchanged rejected arguments.
1. Start with reasoning_frame. Use %s depth unless the problem warrants another explicit depth.
2. Record decision-relevant observations, claims, and labelled assumptions with reasoning_evidence. Every item needs a concrete source and an observable result that would falsify or materially revise it. Link evidence to exact framed unknowns when it addresses them.
3. For decisions, diagnoses, designs, and plans, use reasoning_options to maintain genuinely competing solutions, hypotheses, or scenarios. Do not select an option in the same call that invents it.
4. Use reasoning_review to defend the strongest case, attack it, expose hidden assumptions and blind spots, and record corrections. Use temporal stress tests when the frame requires reasoning across transitions. Resolve contradictions only with an explicit, supported qualification record.
5. A submitted final synthesis must clear every structural gate. Checkpoint mode is optional; use it when a compact progress record or a gate preview would help.
After every accepted or rejected call, follow its one non-terminal next_action.tool unless new user information changes the frame. If next_action.tool is none, stop calling reasoning tools and return the accepted conclusion to the user; never call a tool named none.
Keep artifacts concise and externally inspectable. Never record or reveal private chain-of-thought.
The tools validate structure, references, ordering, and coverage. They do not establish factual truth, guarantee independent perspectives, or replace external verification.
</structured_reasoning>]],
    options.default_depth
  )
  local group = vim.tbl_deep_extend('force', {
    description = 'Guided reasoning for difficult analysis, diagnosis, design, decision, and planning problems',
    system_prompt = system_prompt,
    tools = vim.deepcopy(tool_names),
    opts = { collapse_tools = true },
  }, tools.groups.reasoning or {})
  group.system_prompt = system_prompt
  group.tools = vim.deepcopy(tool_names)
  tools.groups.reasoning = group

  local default_tools = tools.opts.default_tools
  if options.auto_attach then
    if not vim.tbl_contains(default_tools, 'reasoning') then
      table.insert(default_tools, 'reasoning')
      owned_default_tools[default_tools] = true
    end
  elseif owned_default_tools[default_tools] then
    for index = #default_tools, 1, -1 do
      if default_tools[index] == 'reasoning' then
        table.remove(default_tools, index)
        break
      end
    end
    owned_default_tools[default_tools] = nil
  end
end

M.exports = {
  tool_names = function()
    return vim.deepcopy(tool_names)
  end,
}

return M
