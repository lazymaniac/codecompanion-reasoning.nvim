local Control = require('codecompanion._extensions.reasoning.control')
local Output = require('codecompanion._extensions.reasoning.output')
local State = require('codecompanion._extensions.reasoning.state')
local Terminal = require('codecompanion._extensions.reasoning.terminal')

local original_stage_final = Control.stage_final
local original_legacy_terminal_allowed = Control.legacy_terminal_allowed
local original_discard_final = State.discard_final
local original_terminal_install = Terminal.install

local T = MiniTest.new_set({
  hooks = {
    post_case = function()
      Control.stage_final = original_stage_final
      Control.legacy_terminal_allowed = original_legacy_terminal_allowed
      State.discard_final = original_discard_final
      Terminal.install = original_terminal_install
    end,
  },
})
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

T['accepts every registered reasoning tool as a next action'] = function()
  for _, name in ipairs(require('codecompanion._extensions.reasoning.constants').tool_names) do
    local mock = mock_meta()
    Output.success({ name = 'reasoning_question' }, {
      {
        workspace_id = 'W1',
        artifact = { id = 'Q2' },
        open_items = { questions = { { id = 'Q2' } } },
        next_action = { tool = name, reason = 'Continue the protocol' },
      },
    }, mock.meta)
    local payload = vim.json.decode(mock.calls[1].for_llm)
    eq(payload.next_action.tool, name)
    eq(payload.open_items.questions[1].id, 'Q2')
    eq(mock.calls[1].for_user, 'Recorded Q2; next: ' .. name)
  end
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

T['stages an internal final before recording only its public payload'] = function()
  local mock = mock_meta()
  local events = {}
  local internal = {
    stage = { state = 'prepared' },
    markdown = '## Conclusion\n\nUse the verified result.',
  }
  local tool = {
    name = 'reasoning_synthesis',
    function_call = { id = 'call-final', ['function'] = { name = 'reasoning_synthesis' } },
  }
  Control.stage_final = function(chat, received_tool, received_internal)
    table.insert(events, 'stage')
    eq(chat, mock.meta.tools.chat)
    eq(received_tool, tool)
    eq(received_internal, internal)
    return true
  end
  mock.meta.tools.chat.add_tool_output = function(_, received_tool, for_llm, for_user)
    table.insert(events, 'record')
    table.insert(mock.calls, { tool = received_tool, for_llm = for_llm, for_user = for_user })
  end
  Terminal.install = function()
    error('controlled final must not install the compatibility guard')
  end

  Output.success(tool, {
    {
      workspace_id = 'W1',
      artifact = { id = 'S1', kind = 'synthesis', data = { mode = 'final' } },
      unmet_gates = {},
      next_action = { tool = 'none', reason = 'Final accepted' },
      _reasoning_final = internal,
    },
  }, mock.meta)

  eq(events, { 'stage', 'record' })
  local public = vim.json.decode(mock.calls[1].for_llm)
  eq(public._reasoning_final, nil)
  eq(public.artifact.id, 'S1')
  eq(mock.calls[1].for_llm:find(internal.markdown, 1, true), nil)
  eq(mock.calls[1].for_user, '')
end

T['discards malformed or refused final stages and records committed false'] = function()
  for _, case in ipairs({
    { internal = { stage = { state = 'prepared' } }, staged = true },
    {
      internal = { stage = { state = 'prepared' }, markdown = '## Conclusion\n\nSafe.' },
      staged = false,
    },
  }) do
    local mock = mock_meta()
    local discarded
    State.discard_final = function(stage)
      discarded = stage
      stage.state = 'discarded'
      return true
    end
    Control.stage_final = function()
      return case.staged
    end
    Output.success({ name = 'reasoning_synthesis' }, {
      {
        workspace_id = 'W1',
        artifact = { id = 'S1', kind = 'synthesis', data = { mode = 'final' } },
        unmet_gates = {},
        next_action = { tool = 'none', reason = 'Final accepted' },
        _reasoning_final = case.internal,
      },
    }, mock.meta)
    local payload = vim.json.decode(mock.calls[1].for_llm)
    eq(payload.code, 'internal_error')
    eq(payload.committed, false)
    eq(discarded, case.internal.stage)
    eq(mock.calls[1].for_user, 'Reasoning output rejected: internal_error')
  end

  local malformed = mock_meta()
  local stage = { state = 'prepared' }
  local discarded
  State.discard_final = function(received)
    discarded = received
    return true
  end
  Output.success({ name = 'reasoning_synthesis' }, {
    {
      artifact = { kind = 'synthesis', data = { mode = 'final' } },
      next_action = { tool = 'none', reason = 'Final accepted' },
      _reasoning_final = { stage = stage, markdown = '## Conclusion\n\nSafe.' },
    },
  }, malformed.meta)
  eq(discarded, stage)
  eq(vim.json.decode(malformed.calls[1].for_llm).committed, false)
end

T['uses the one-shot terminal guard only for standalone compatibility finals'] = function()
  for _, allowed in ipairs({ true, false }) do
    local mock = mock_meta()
    local installs = 0
    Control.legacy_terminal_allowed = function(chat)
      eq(chat, mock.meta.tools.chat)
      return allowed
    end
    Terminal.install = function(tools)
      eq(tools, mock.meta.tools)
      installs = installs + 1
    end
    Output.success({ name = 'reasoning_synthesis' }, {
      {
        workspace_id = 'W1',
        artifact = { id = 'S1', kind = 'synthesis', data = { mode = 'final' } },
        unmet_gates = {},
        next_action = { tool = 'none', reason = 'Final accepted' },
      },
    }, mock.meta)
    eq(installs, allowed and 1 or 0)
    local payload = vim.json.decode(mock.calls[1].for_llm)
    if allowed then
      eq(payload.artifact.id, 'S1')
      eq(mock.calls[1].for_user, 'Recorded S1; next: none')
    else
      eq(payload.code, 'internal_error')
      eq(payload.committed, false)
      eq(mock.calls[1].for_user, 'Reasoning output rejected: internal_error')
    end
  end
end

T['rechecks legacy compatibility after the host records a standalone final'] = function()
  local mock = mock_meta()
  local checks = 0
  local installs = 0
  Control.legacy_terminal_allowed = function(chat)
    eq(chat, mock.meta.tools.chat)
    checks = checks + 1
    return checks == 1
  end
  Terminal.install = function()
    installs = installs + 1
  end

  Output.success({ name = 'reasoning_synthesis' }, {
    {
      workspace_id = 'W1',
      artifact = { id = 'S1', kind = 'synthesis', data = { mode = 'final' } },
      unmet_gates = {},
      next_action = { tool = 'none', reason = 'Final accepted' },
    },
  }, mock.meta)

  eq(checks, 2)
  eq(installs, 0)
  eq(vim.json.decode(mock.calls[1].for_llm).artifact.id, 'S1')
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
  eq(payload.committed, false)
  eq(payload.next_action.tool, 'reasoning_frame')
  eq(mock.calls[1].for_user, 'Reasoning output rejected: internal_error')

  mock = mock_meta()
  local stage = { state = 'prepared' }
  local discarded
  State.discard_final = function(received)
    discarded = received
    return true
  end
  Output.success({ name = 'reasoning_synthesis' }, {
    {
      artifact = {
        id = 'S1',
        kind = 'synthesis',
        data = { mode = 'final' },
        invalid = function() end,
      },
      unmet_gates = {},
      next_action = { tool = 'none', reason = 'Final accepted' },
      _reasoning_final = { stage = stage, markdown = '## Conclusion\n\nSafe.' },
    },
  }, mock.meta)
  eq(discarded, stage)
  payload = vim.json.decode(mock.calls[1].for_llm)
  eq(payload.code, 'internal_error')
  eq(payload.committed, false)
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

T['does not mutate host tool status for terminal errors'] = function()
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
  eq(mock.meta.tools.status, 'error')
  eq(vim.json.decode(mock.calls[1].for_llm).next_action.tool, 'none')
end

return T
