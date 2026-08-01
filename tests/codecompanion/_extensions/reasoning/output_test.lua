local Output = require('codecompanion._extensions.reasoning.output')

local T = MiniTest.new_set()
local eq = MiniTest.expect.equality

local function mock_meta()
  local calls = {}
  return {
    calls = calls,
    meta = {
      tools = {
        chat = {
          add_tool_output = function(_, tool, for_llm, for_user)
            table.insert(calls, { tool = tool, for_llm = for_llm, for_user = for_user })
          end,
        },
      },
    },
  }
end

T['serializes success for the model and bounds user output'] = function()
  local mock = mock_meta()
  Output.success({ name = 'reasoning_frame' }, {
    {
      workspace_id = 'W1',
      artifact = { id = 'F1' },
      next_action = { tool = 'reasoning_evidence', reason = 'Gather evidence' },
    },
  }, mock.meta)
  eq(vim.json.decode(mock.calls[1].for_llm).artifact.id, 'F1')
  eq(mock.calls[1].for_user, 'Recorded F1; next: reasoning_evidence')
end

T['serializes stable errors'] = function()
  local mock = mock_meta()
  Output.error({ name = 'reasoning_frame' }, {
    {
      code = 'workspace_exists',
      message = 'active',
      artifact_ids = { 'F1' },
      next_action = { tool = 'reasoning_frame', reason = 'Use revise' },
    },
  }, mock.meta)
  eq(vim.json.decode(mock.calls[1].for_llm).code, 'workspace_exists')
  eq(mock.calls[1].for_user, 'Reasoning step rejected: workspace_exists')
end

T['surfaces none as the terminal next action'] = function()
  local mock = mock_meta()
  Output.success({ name = 'reasoning_synthesis' }, {
    {
      workspace_id = 'W1',
      artifact = { id = 'S1', kind = 'synthesis', data = { mode = 'final' } },
      unmet_gates = {},
      next_action = { tool = 'none', reason = 'Return the conclusion' },
    },
  }, mock.meta)
  eq(vim.json.decode(mock.calls[1].for_llm).next_action.tool, 'none')
  eq(mock.calls[1].for_user, 'Recorded S1; next: none')
end

T['keeps the model payload valid JSON when serialization fails'] = function()
  local mock = mock_meta()
  Output.success({ name = 'reasoning_frame' }, {
    {
      artifact = { id = 'F1', invalid = function() end },
      next_action = { tool = 'reasoning_evidence', reason = 'Gather evidence' },
    },
  }, mock.meta)
  local payload = vim.json.decode(mock.calls[1].for_llm)
  eq(payload.code, 'internal_error')
  eq(payload.next_action.tool, 'reasoning_frame')
  eq(mock.calls[1].for_user, 'Reasoning output rejected: internal_error')
end

T['rejects a malformed success without inventing a terminal action'] = function()
  local mock = mock_meta()
  Output.success({ name = 'reasoning_evidence' }, {}, mock.meta)
  local payload = vim.json.decode(mock.calls[1].for_llm)
  eq(payload.code, 'internal_error')
  eq(payload.next_action.tool, 'reasoning_evidence')
  eq(mock.calls[1].for_user, 'Reasoning output rejected: internal_error')

  mock = mock_meta()
  Output.success({ name = 'reasoning_frame' }, {
    { artifact = { id = 'F1' }, next_action = {} },
  }, mock.meta)
  payload = vim.json.decode(mock.calls[1].for_llm)
  eq(payload.code, 'internal_error')
  eq(payload.next_action.tool, 'reasoning_frame')
end

T['reserves none for an accepted final synthesis'] = function()
  local mock = mock_meta()
  Output.success({ name = 'reasoning_frame' }, {
    {
      artifact = { id = 'F1', kind = 'frame', data = {} },
      next_action = { tool = 'none', reason = 'Incorrect terminal' },
    },
  }, mock.meta)
  local payload = vim.json.decode(mock.calls[1].for_llm)
  eq(payload.code, 'internal_error')
  eq(payload.next_action.tool, 'reasoning_frame')
  eq(mock.calls[1].for_user, 'Reasoning output rejected: internal_error')

  mock = mock_meta()
  Output.success({ name = 'reasoning_synthesis' }, {
    {
      artifact = { id = 'S1', kind = 'synthesis', data = { mode = 'final' } },
      unmet_gates = { 'review_missing' },
      next_action = { tool = 'none', reason = 'Incorrect terminal' },
    },
  }, mock.meta)
  payload = vim.json.decode(mock.calls[1].for_llm)
  eq(payload.code, 'internal_error')
end

T['marks terminal errors so CodeCompanion does not auto-submit them'] = function()
  local mock = mock_meta()
  mock.meta.tools.status = 'error'
  Output.error({ name = 'reasoning_synthesis' }, {
    {
      code = 'workspace_finalized',
      message = 'terminal',
      artifact_ids = { 'S1' },
      next_action = { tool = 'none', reason = 'Return the accepted conclusion' },
    },
  }, mock.meta)
  eq(mock.meta.tools.status, 'terminal')
  eq(vim.json.decode(mock.calls[1].for_llm).next_action.tool, 'none')
end

return T
