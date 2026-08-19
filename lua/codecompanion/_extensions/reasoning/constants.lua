local M = {}

--- One tool per protocol transition. Every tool takes only the fields its own
--- transition needs, so no call carries placeholder values for another action.
M.tool_names = {
  'reasoning_start',
  'reasoning_amend',
  'reasoning_revise',
  'reasoning_replace',
  'reasoning_split',
  'reasoning_answer',
  'reasoning_drop',
  'reasoning_evidence',
  'reasoning_options',
  'reasoning_options_replace',
  'reasoning_review',
  'reasoning_resolve_contradiction',
  'reasoning_checkpoint',
  'reasoning_final',
}

M.tool_set = {}
for _, name in ipairs(M.tool_names) do
  M.tool_set[name] = true
end

M.operation_by_tool = {
  reasoning_start = 'start',
  reasoning_amend = 'amend',
  reasoning_revise = 'revise',
  reasoning_replace = 'replace',
  reasoning_split = 'split',
  reasoning_answer = 'answer',
  reasoning_drop = 'drop',
  reasoning_evidence = 'evidence',
  reasoning_options = 'options',
  reasoning_options_replace = 'options_replace',
  reasoning_review = 'review',
  reasoning_resolve_contradiction = 'resolve_contradiction',
  reasoning_checkpoint = 'checkpoint',
  reasoning_final = 'final',
}

M.tool_by_operation = {}
for tool, operation in pairs(M.operation_by_tool) do
  M.tool_by_operation[operation] = tool
end

--- Families group the operations that share one validated artifact handler and
--- one authoritative transition slot. Guidance names the precise tool; the
--- transition check accepts any tool in the named tool's family, so a leaf may
--- be dropped where an answer was suggested without leaving the protocol.
M.family_by_operation = {
  start = 'frame',
  amend = 'frame',
  revise = 'frame',
  replace = 'frame',
  split = 'question',
  answer = 'question',
  drop = 'question',
  evidence = 'evidence',
  options = 'options',
  options_replace = 'options',
  review = 'review',
  resolve_contradiction = 'review',
  checkpoint = 'synthesis',
  final = 'synthesis',
}

M.family_by_tool = {}
M.tools_by_family = {}
for _, name in ipairs(M.tool_names) do
  local family = M.family_by_operation[M.operation_by_tool[name]]
  M.family_by_tool[name] = family
  M.tools_by_family[family] = M.tools_by_family[family] or {}
  table.insert(M.tools_by_family[family], name)
end

--- The frame operations that keep an existing workspace addressable instead of
--- starting one, used by the terminal and reframing lifecycle checks.
M.reframe_operations = { revise = true, replace = true }

M.augroup = 'codecompanion.reasoning.control'
M.corrective_tag = 'reasoning_protocol_correction'
M.resume_command = 'CodeCompanionReasoningResume'

return M
