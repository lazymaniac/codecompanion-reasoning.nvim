local M = {}

M.tool_names = {
  'reasoning_frame',
  'reasoning_evidence',
  'reasoning_options',
  'reasoning_review',
  'reasoning_synthesis',
  'reasoning_question',
}

M.tool_set = {}
for _, name in ipairs(M.tool_names) do
  M.tool_set[name] = true
end

M.operation_by_tool = {
  reasoning_frame = 'frame',
  reasoning_evidence = 'evidence',
  reasoning_options = 'options',
  reasoning_review = 'review',
  reasoning_synthesis = 'synthesis',
  reasoning_question = 'question',
}

M.tool_by_operation = {}
for tool, operation in pairs(M.operation_by_tool) do
  M.tool_by_operation[operation] = tool
end

M.augroup = 'codecompanion.reasoning.control'
M.corrective_tag = 'reasoning_protocol_correction'
M.resume_command = 'CodeCompanionReasoningResume'

return M
