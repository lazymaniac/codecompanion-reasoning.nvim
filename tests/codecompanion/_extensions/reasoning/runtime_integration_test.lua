local CodeCompanion = require('codecompanion')
local CCConfig = require('codecompanion.config')
local Extension = require('codecompanion._extensions.reasoning')
local ToolRegistry = require('codecompanion.interactions.chat.tool_registry')
local ToolRuntime = require('codecompanion.interactions.chat.tools')
local Approvals = require('codecompanion.interactions.chat.tools.approvals')
local Log = require('codecompanion.utils.log')
local Hash = require('codecompanion.utils.hash')
local Control = require('codecompanion._extensions.reasoning.control')
local Render = require('codecompanion._extensions.reasoning.render')
local State = require('codecompanion._extensions.reasoning.state')

local names = {
  'reasoning_frame',
  'reasoning_evidence',
  'reasoning_options',
  'reasoning_review',
  'reasoning_synthesis',
}

local buffers = {}
local original_log
local original_tools
local call_sequence = 0

local T = MiniTest.new_set({
  hooks = {
    pre_case = function()
      original_log = Log.get_root()
      original_tools = vim.deepcopy(CCConfig.interactions.chat.tools)
      Control._reset()
      State._reset()
      local opts = CCConfig.interactions.chat.tools.opts
      opts.auto_submit_success = false
      opts.auto_submit_errors = false
      opts.default_tools = {}
      opts.system_prompt = vim.tbl_deep_extend('force', opts.system_prompt or {}, { enabled = false })
      Extension.setup({ auto_attach = false })
      call_sequence = 0
    end,
    post_case = function()
      Log.set_root(original_log)
      Control._reset()
      State._reset()
      CCConfig.interactions.chat.tools = original_tools
      for _, bufnr in ipairs(buffers) do
        Approvals:reset(bufnr)
        if vim.api.nvim_buf_is_valid(bufnr) then
          vim.api.nvim_buf_delete(bufnr, { force = true })
        end
        pcall(vim.api.nvim_del_augroup_by_name, 'codecompanion.tools:' .. bufnr)
        pcall(vim.api.nvim_del_augroup_by_name, 'codecompanion.tools.list:' .. bufnr)
      end
      buffers = {}
    end,
  },
})
local eq = MiniTest.expect.equality

local function new_chat(id)
  local bufnr = vim.api.nvim_create_buf(false, true)
  table.insert(buffers, bufnr)
  local chat = {
    adapter = { name = 'reasoning_test', type = 'http', roles = { tool = 'tool' } },
    callbacks = {},
    cycle = 0,
    id = id,
    bufnr = bufnr,
    messages = {},
    buffer_messages = {},
    outputs = {},
    tools_done_count = 0,
    submit_count = 0,
  }
  chat.MESSAGE_TYPES = {
    LLM_MESSAGE = 'llm_message',
    REASONING_MESSAGE = 'reasoning_message',
    TOOL_MESSAGE = 'tool_message',
    USER_MESSAGE = 'user_message',
  }
  chat.subscribers = {
    stop_count = 0,
    stop = function(self)
      self.stop_count = self.stop_count + 1
    end,
  }
  chat.context = { items = {} }
  function chat.context:add(item)
    table.insert(self.items, item)
  end
  function chat:add_message(message, opts)
    message = vim.deepcopy(message)
    message.opts = vim.deepcopy(opts)
    table.insert(self.messages, message)
  end
  function chat:remove_tagged_message(tag)
    for index = #self.messages, 1, -1 do
      local opts = self.messages[index].opts
      if type(opts) == 'table' and type(opts._meta) == 'table' and opts._meta.tag == tag then
        table.remove(self.messages, index)
      end
    end
  end
  function chat:add_callback(event, callback)
    self.callbacks[event] = self.callbacks[event] or {}
    table.insert(self.callbacks[event], callback)
  end
  function chat:remove_callback(event, callback)
    local callbacks = self.callbacks[event] or {}
    for index = #callbacks, 1, -1 do
      if callbacks[index] == callback then
        table.remove(callbacks, index)
      end
    end
  end
  function chat:dispatch(event, ...)
    for _, callback in ipairs(vim.list_slice(self.callbacks[event] or {}, 1)) do
      callback(self, ...)
    end
  end
  function chat:set_system_prompt(prompt, opts)
    self:add_message({ role = 'system', content = prompt }, opts)
  end
  function chat:make_system_prompt_context()
    return {}
  end
  function chat:add_buf_message(message, opts)
    table.insert(self.buffer_messages, { message = vim.deepcopy(message), opts = vim.deepcopy(opts) })
    local lines = vim.split(message.content or '', '\n', { plain = true })
    vim.api.nvim_buf_set_lines(self.bufnr, -1, -1, false, lines)
    return vim.api.nvim_buf_line_count(self.bufnr)
  end
  function chat:add_tool_output(tool, for_llm, for_user)
    local args = { tool = tool.name, for_llm = for_llm, for_user = for_user }
    self:dispatch('on_tool_output', args)
    for_llm = args.for_llm
    for_user = args.for_user
    table.insert(self.outputs, {
      tool = tool.name,
      call_id = tool.function_call and tool.function_call.id,
      for_llm = for_llm,
      for_user = for_user,
    })
    local call = tool.function_call or {}
    local message = {
      role = 'tool',
      content = for_llm,
      tool_call_id = call.id,
      tools = { id = call.id, call_id = call.call_id or call.id, name = tool.name },
      opts = { visible = true },
      _meta = { cycle = self.cycle },
    }
    message._meta.id = Hash.hash({ role = message.role, content = message.content })
    table.insert(self.messages, message)
    if for_user ~= '' then
      self:add_buf_message(
        { role = 'assistant', content = for_user or for_llm },
        { type = self.MESSAGE_TYPES.TOOL_MESSAGE }
      )
    end
  end
  function chat:tools_done()
    self.tools_done_count = self.tools_done_count + 1
  end
  function chat:submit(opts)
    self.submit_count = self.submit_count + 1
    if opts and opts.callback then
      opts.callback()
    end
  end
  function chat:_submit_http() end
  function chat:_submit_acp() end
  function chat:done() end
  function chat:clear() end
  function chat:close() end
  function chat:restore() end

  chat.tools = ToolRuntime.new({
    adapter = vim.tbl_extend('force', chat.adapter, { available_tools = {} }),
    bufnr = bufnr,
    messages = chat.messages,
  })
  chat.tools.chat = chat
  chat.tool_registry = ToolRegistry.new({ chat = chat, ctx = {} })
  return chat
end

local function assert_group_attached(chat)
  eq(chat.tool_registry.groups.reasoning, names)
  eq(vim.tbl_count(chat.tool_registry.in_use), 5)
  for _, name in ipairs(names) do
    eq(chat.tool_registry.in_use[name], true)
    eq(type(chat.tool_registry.schemas['<tool>' .. name .. '</tool>']), 'table')
  end
  local group_context = false
  for _, item in ipairs(chat.context.items) do
    group_context = group_context or item.id == '<group>reasoning</group>'
  end
  eq(group_context, true)
  local group_prompt = false
  for _, message in ipairs(chat.messages) do
    group_prompt = group_prompt
      or (type(message.content) == 'string' and message.content:find('<structured_reasoning>', 1, true) ~= nil)
  end
  eq(group_prompt, true)
end

local function attach_group(chat, controlled)
  eq(chat.tool_registry:add('reasoning') ~= nil, true)
  assert_group_attached(chat)
  if controlled then
    eq(Control.reconcile(chat) ~= nil, true)
    eq(Control.phase(chat), 'armed')
  end
end

local function attach_partial_tools(chat)
  for _, name in ipairs({ 'reasoning_frame', 'reasoning_evidence', 'reasoning_synthesis' }) do
    eq(chat.tool_registry:add(name) ~= nil, true)
  end
  eq(chat.tool_registry.groups.reasoning, nil)
  eq(vim.tbl_count(chat.tool_registry.in_use), 3)
end

local function invoke_many(chat, calls)
  local output_count = #chat.outputs
  local completed_count = chat.tools_done_count
  local tool_calls = {}
  for _, call in ipairs(calls) do
    call_sequence = call_sequence + 1
    table.insert(tool_calls, {
      id = 'reasoning-call-' .. call_sequence,
      type = 'function',
      ['function'] = { name = call.name, arguments = vim.deepcopy(call.arguments) },
    })
  end
  local scheduled = {}
  local original_schedule = vim.schedule
  vim.schedule = function(callback)
    table.insert(scheduled, callback)
  end
  local ok, err = xpcall(function()
    chat.tools:execute(chat, tool_calls)
    while #scheduled > 0 do
      table.remove(scheduled, 1)()
    end
  end, debug.traceback)
  vim.schedule = original_schedule
  if not ok then
    error(err, 0)
  end
  eq(chat.tools_done_count > completed_count, true)
  eq(#chat.outputs, output_count + #calls)
  eq(chat.tool_orchestrator, nil)
  local outputs = {}
  for index = output_count + 1, #chat.outputs do
    table.insert(outputs, chat.outputs[index])
  end
  return outputs
end

local function invoke(chat, name, arguments)
  return invoke_many(chat, { { name = name, arguments = arguments } })[1]
end

local function frame_args(objective)
  return {
    action = 'start',
    objective = objective,
    problem_type = 'analysis',
    depth = 'standard',
    constraints = {},
    success_criteria = { 'Reach a supported conclusion' },
    unknowns = {},
    perspectives = { { name = 'correctness', purpose = 'Check whether the conclusion follows' } },
    temporal_required = false,
    branching_required = false,
    branching_rationale = 'This test evaluates one claim',
  }
end

local function evidence_args()
  return {
    items = {
      {
        kind = 'observation',
        statement = 'The supplied test observation is available',
        source = 'user statement',
        confidence = 'high',
        falsifier = 'The user withdraws the observation',
        perspective = 'correctness',
        addresses_unknowns = {},
        supports = {},
        contradicts = {},
        qualifies = {},
        supersedes_id = '',
      },
    },
  }
end

local function deep_frame_args()
  return {
    action = 'start',
    objective = 'Choose a durable cache design',
    problem_type = 'design',
    depth = 'deep',
    constraints = { 'No external service' },
    success_criteria = { 'Survives process restart', 'Bounded memory' },
    unknowns = {},
    perspectives = {
      { name = 'correctness', purpose = 'Find recovery failures' },
      { name = 'operations', purpose = 'Find lifecycle failures' },
    },
    temporal_required = false,
    branching_required = true,
    branching_rationale = 'Competing durable designs exist',
  }
end

local function deep_evidence_args()
  return {
    items = {
      {
        kind = 'observation',
        statement = 'A checksummed journal can replay committed mutations',
        source = 'tests/recovery.lua:10',
        confidence = 'high',
        falsifier = 'Truncation recovery loses a committed mutation',
        perspective = 'correctness',
        addresses_unknowns = {},
        supports = {},
        contradicts = {},
        qualifies = {},
        supersedes_id = '',
      },
      {
        kind = 'observation',
        statement = 'Compaction bounds retained journal entries',
        source = 'tests/compaction.lua:12',
        confidence = 'high',
        falsifier = 'Retained entries grow after completed compaction',
        perspective = 'operations',
        addresses_unknowns = {},
        supports = {},
        contradicts = {},
        qualifies = {},
        supersedes_id = '',
      },
    },
  }
end

local function options_args()
  return {
    question = 'Which durable representation should the cache use?',
    branch_type = 'solution',
    criteria = { 'Durability', 'Memory' },
    supersedes_branch_id = '',
    options = {
      {
        label = 'journal',
        summary = 'Append checksummed mutations',
        evidence_ids = { 'E1' },
        assumptions = { 'Disk writes are available' },
        predictions = { 'Replay restores committed state' },
        benefits = { 'Incremental persistence' },
        costs = { 'Compaction work' },
        risks = { 'Torn writes' },
        reversibility = 'moderate',
      },
      {
        label = 'snapshot',
        summary = 'Write atomic snapshots',
        evidence_ids = { 'E2' },
        assumptions = { 'State fits in one snapshot' },
        predictions = { 'Restart loads the latest snapshot' },
        benefits = { 'Simple recovery' },
        costs = { 'Full-state writes' },
        risks = { 'Stale snapshots' },
        reversibility = 'easy',
      },
    },
  }
end

local function review_args()
  return {
    mode = 'full',
    target_ids = { 'O1', 'E1' },
    defense = {
      summary = 'Replay evidence supports the journal option',
      evidence_ids = { 'E1' },
    },
    challenges = {
      {
        kind = 'counterexample',
        summary = 'A torn suffix may defeat recovery',
        target_ids = { 'O1' },
        falsifier = 'Recovery succeeds for every partial suffix',
      },
      {
        kind = 'hidden_assumption',
        summary = 'The observation assumes durable flush semantics',
        target_ids = { 'E1' },
        falsifier = 'The source demonstrates recovery without durable flushes',
      },
    },
    blind_spots = { 'Disk exhaustion' },
    stress_tests = {},
    verdicts = {
      { target_id = 'O1', status = 'keep', revision_instruction = '' },
      { target_id = 'E1', status = 'keep', revision_instruction = '' },
    },
    contradiction_resolutions = {},
    structural_tradeoffs = {},
  }
end

local function synthesis_args()
  return {
    mode = 'final',
    conclusion = 'Use a checksummed journal with compaction and truncation recovery',
    selected_option_ids = { 'O1' },
    support_ids = { 'E1', 'E2' },
    review_ids = { 'R1' },
    criterion_results = {
      {
        criterion = 'Survives process restart',
        status = 'passed',
        evidence_ids = { 'E1' },
        explanation = 'Replay restores committed mutations',
      },
      {
        criterion = 'Bounded memory',
        status = 'passed',
        evidence_ids = { 'E2' },
        explanation = 'Compaction bounds retained entries',
      },
    },
    tradeoffs = { 'Recovery guarantees add write and compaction work' },
    uncertainties = { 'Disk-full behavior needs platform testing' },
    blind_spots = { 'Network filesystems were not evaluated' },
    next_actions = { 'Implement the journal behind the cache interface' },
    confidence = 'medium',
  }
end

local function standard_synthesis_args()
  return {
    mode = 'final',
    conclusion = 'The supplied observation supports the conclusion',
    selected_option_ids = {},
    support_ids = { 'E1' },
    review_ids = {},
    criterion_results = {
      {
        criterion = 'Reach a supported conclusion',
        status = 'passed',
        evidence_ids = { 'E1' },
        explanation = 'The observation directly supports the bounded claim',
      },
    },
    tradeoffs = {},
    uncertainties = {},
    blind_spots = {},
    next_actions = {},
    confidence = 'high',
  }
end

T['runs registered tools through v19.22.0 and isolates chats'] = function()
  eq(CodeCompanion.version(), '19.22.0')
  local first = new_chat(1)
  local second = new_chat(2)
  attach_group(first, true)
  attach_group(second, true)

  local success = invoke(first, 'reasoning_frame', frame_args('First chat objective'))
  local success_payload = vim.json.decode(success.for_llm)
  eq(success.tool, 'reasoning_frame')
  eq(success.call_id, 'reasoning-call-1')
  eq(success_payload.workspace_id, 'W1')
  eq(success_payload.artifact.id, 'F1')
  eq(success_payload.next_action.tool, 'reasoning_evidence')
  eq(success_payload.artifacts_by_id, nil)
  eq(success.for_user, 'Recorded F1; next: reasoning_evidence')
  eq(#success.for_user < 96, true)

  local rejected = invoke(second, 'reasoning_evidence', evidence_args())
  local error_payload = vim.json.decode(rejected.for_llm)
  eq(rejected.tool, 'reasoning_evidence')
  eq(rejected.call_id, 'reasoning-call-2')
  eq(error_payload.code, 'transition_invalid')
  eq(error_payload.committed, false)
  eq(error_payload.next_action.tool, 'reasoning_frame')
  eq(rejected.for_user, '')
  eq(State.get(second), nil)

  local second_success = invoke(second, 'reasoning_frame', frame_args('Second chat objective'))
  eq(vim.json.decode(second_success.for_llm).workspace_id, 'W1')
  local first_workspace = State.get(first)
  local second_workspace = State.get(second)
  eq(first_workspace == second_workspace, false)
  eq(first_workspace.id, 'W1')
  eq(second_workspace.id, 'W1')
  eq(State.find(first_workspace, 'F1').data.objective, 'First chat objective')
  eq(State.find(second_workspace, 'F1').data.objective, 'Second chat objective')
  eq(first.submit_count, 0)
  eq(second.submit_count, 0)
end

T['executes the complete deep protocol and terminates after final synthesis'] = function()
  local chat = new_chat(3)
  attach_group(chat, true)

  local frame = vim.json.decode(invoke(chat, 'reasoning_frame', deep_frame_args()).for_llm)
  eq(frame.artifact.id, 'F1')
  eq(frame.next_action.tool, 'reasoning_evidence')

  local evidence = vim.json.decode(invoke(chat, 'reasoning_evidence', deep_evidence_args()).for_llm)
  eq(evidence.artifacts[1].id, 'E1')
  eq(evidence.artifacts[2].id, 'E2')
  eq(evidence.next_action.tool, 'reasoning_options')

  local options = vim.json.decode(invoke(chat, 'reasoning_options', options_args()).for_llm)
  eq(options.artifact.id, 'B1')
  eq(options.artifacts[1].id, 'O1')
  eq(options.next_action.tool, 'reasoning_review')

  local review = vim.json.decode(invoke(chat, 'reasoning_review', review_args()).for_llm)
  eq(review.artifact.id, 'R1')
  eq(review.next_action.tool, 'reasoning_synthesis')

  local final_output = invoke(chat, 'reasoning_synthesis', synthesis_args())
  local final = vim.json.decode(final_output.for_llm)
  eq(final.artifact.id, 'S1')
  eq(final.unmet_gates, {})
  eq(final.next_action.tool, 'none')
  eq(final_output.for_user, '')
  eq(Control.phase(chat), 'finalized')
  eq(rawget(chat, '_codecompanion_reasoning_terminal_guard'), nil)

  chat.tools.tools_config.opts.auto_submit_errors = true
  local submit_count = chat.submit_count
  local duplicate_output = invoke(chat, 'reasoning_synthesis', synthesis_args())
  local duplicate = vim.json.decode(duplicate_output.for_llm)
  eq(duplicate.code, 'workspace_finalized')
  eq(duplicate.artifact_ids, { 'S1' })
  eq(duplicate.next_action.tool, 'none')
  eq(duplicate_output.for_user, '')
  eq(State.get(chat).counts_by_kind.synthesis, 1)
  eq(chat.submit_count, submit_count)

  local queued = invoke_many(chat, {
    { name = 'reasoning_evidence', arguments = evidence_args() },
    { name = 'reasoning_options', arguments = options_args() },
  })
  eq(#queued, 2)
  for _, output in ipairs(queued) do
    local payload = vim.json.decode(output.for_llm)
    eq(payload.code, 'workspace_finalized')
    eq(payload.next_action.tool, 'none')
  end
  eq(State.get(chat).counts_by_kind.synthesis, 1)
  eq(chat.submit_count, submit_count)
end

T['auto-attached group resolves through a live registry'] = function()
  Extension.setup({ auto_attach = true })
  local chat = new_chat(4)
  for _, name in ipairs(CCConfig.interactions.chat.tools.opts.default_tools) do
    chat.tool_registry:add(name)
  end
  assert_group_attached(chat)
  eq(Control.reconcile(chat) ~= nil, true)
  local result = vim.json.decode(invoke(chat, 'reasoning_frame', frame_args('Auto-attached objective')).for_llm)
  eq(result.artifact.id, 'F1')
end

T['continues inline execution through CodeCompanion auto-submit'] = function()
  CCConfig.interactions.chat.tools.opts.auto_submit_success = true
  CCConfig.interactions.chat.tools.opts.auto_submit_errors = true
  local chat = new_chat(5)
  attach_group(chat, true)
  local result = vim.json.decode(invoke(chat, 'reasoning_frame', frame_args('Inline objective')).for_llm)
  eq(result.next_action.tool, 'reasoning_evidence')
  eq(chat.submit_count, 1)
end

T['partial-tool chat uses one legacy terminal continuation and stops literal none loops'] = function()
  local chat = new_chat(6)
  attach_partial_tools(chat)
  eq(Approvals:toggle_yolo_mode(chat.bufnr), true)

  invoke(chat, 'reasoning_frame', frame_args('Terminal guard objective'))
  invoke(chat, 'reasoning_evidence', evidence_args())
  local final = vim.json.decode(invoke(chat, 'reasoning_synthesis', standard_synthesis_args()).for_llm)
  eq(final.next_action.tool, 'none')
  eq(rawget(chat, '_codecompanion_reasoning_terminal_guard') ~= nil, true)
  local submit_count = chat.submit_count
  eq(submit_count, 3)

  local duplicate = vim.json.decode(invoke(chat, 'reasoning_synthesis', standard_synthesis_args()).for_llm)
  eq(duplicate.code, 'workspace_finalized')
  eq(duplicate.next_action.tool, 'none')
  eq(chat.submit_count, submit_count)

  Log.set_root(Log.new({ handlers = {} }))
  local invalid = invoke(chat, 'none', {})
  Log.set_root(original_log)
  eq(invalid.tool, 'none')
  eq(invalid.for_llm:find('Tool `none` not found', 1, true) ~= nil, true)
  eq(chat.submit_count, submit_count)

  local revised = frame_args('Reopened after new user information')
  revised.action = 'revise'
  local reopened = vim.json.decode(invoke(chat, 'reasoning_frame', revised).for_llm)
  eq(reopened.artifact.id, 'F2')
  eq(chat.submit_count, submit_count + 1)
end

T['complete controlled chat finalizes without a legacy continuation'] = function()
  local chat = new_chat(7)
  attach_group(chat, true)

  invoke(chat, 'reasoning_frame', frame_args('Controlled terminal objective'))
  invoke(chat, 'reasoning_evidence', evidence_args())
  local render_args = standard_synthesis_args()
  render_args.frame_id = State.get(chat).frame_id
  local expected_markdown = Render.render(State.get(chat), render_args)
  local submit_count = chat.submit_count
  eq(submit_count, 0)
  chat.tools.tools_config.opts.auto_submit_success = true

  local final_output = invoke(chat, 'reasoning_synthesis', standard_synthesis_args())
  local final = vim.json.decode(final_output.for_llm)
  eq(final.artifact.id, 'S1')
  eq(final.next_action.tool, 'none')
  eq(final_output.for_user, '')
  eq(Control.phase(chat), 'finalized')
  eq(rawget(chat, '_codecompanion_reasoning_terminal_guard'), nil)
  eq(State.get(chat).counts_by_kind.synthesis, 1)
  eq(chat.submit_count, submit_count)
  local result_index
  local rendered_index
  local rendered_count = 0
  for index, message in ipairs(chat.messages) do
    if message.role == 'tool' and type(message.content) == 'string' then
      local decoded_ok, decoded = pcall(vim.json.decode, message.content)
      if decoded_ok and type(decoded.artifact) == 'table' and decoded.artifact.id == 'S1' then
        result_index = index
      end
    end
    if message.role == CCConfig.constants.LLM_ROLE and message.content == expected_markdown then
      rendered_index = index
      rendered_count = rendered_count + 1
    end
  end
  eq(type(result_index), 'number')
  eq(type(rendered_index), 'number')
  eq(result_index < rendered_index, true)
  eq(rendered_count, 1)
  local buffer_rendered_count = 0
  for _, entry in ipairs(chat.buffer_messages) do
    if entry.message.content == expected_markdown then
      buffer_rendered_count = buffer_rendered_count + 1
    end
  end
  eq(buffer_rendered_count, 1)

  local duplicate = vim.json.decode(invoke(chat, 'reasoning_synthesis', standard_synthesis_args()).for_llm)
  eq(duplicate.code, 'workspace_finalized')
  eq(duplicate.next_action.tool, 'none')
  eq(State.get(chat).counts_by_kind.synthesis, 1)
  eq(chat.submit_count, submit_count)
end

return T
