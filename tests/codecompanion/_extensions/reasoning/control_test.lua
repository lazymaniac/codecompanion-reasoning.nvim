local Config = require('codecompanion._extensions.reasoning.config')
local Constants = require('codecompanion._extensions.reasoning.constants')
local Control = require('codecompanion._extensions.reasoning.control')
local Extension = require('codecompanion._extensions.reasoning')
local Output = require('codecompanion._extensions.reasoning.output')
local Protocol = require('codecompanion._extensions.reasoning.protocol')
local State = require('codecompanion._extensions.reasoning.state')
local Terminal = require('codecompanion._extensions.reasoning.terminal')
local host_adapters = require('codecompanion.adapters')
local host_config = require('codecompanion.config')
local host_hash = require('codecompanion.utils.hash')
local host_parser = require('codecompanion.interactions.chat.parser')
local canonical_parser_messages = host_parser.messages

local T
local eq = MiniTest.expect.equality
local created_buffers = {}
local original_global_adapter
local original_test_adapter
local original_host_config
local original_commit_final = State.commit_final
local original_rollback_final = State.rollback_final
local canonical_tool_configs

local function callback_methods()
  return {
    add_callback = function(self, event, callback)
      self.callbacks[event] = self.callbacks[event] or {}
      table.insert(self.callbacks[event], callback)
      return self
    end,
    remove_callback = function(self, event, callback)
      for index = #(self.callbacks[event] or {}), 1, -1 do
        if self.callbacks[event][index] == callback then
          table.remove(self.callbacks[event], index)
        end
      end
      return self
    end,
    dispatch = function(self, event, ...)
      for _, callback in ipairs(vim.list_slice(self.callbacks[event] or {})) do
        callback(self, ...)
      end
      return self
    end,
    dispatch_cancellable = function(self, event, ...)
      for _, callback in ipairs(self.callbacks[event] or {}) do
        if callback(self, ...) == false then
          return true
        end
      end
      return false
    end,
  }
end

local function new_chat(opts)
  opts = opts or {}
  local calls = {
    submit = 0,
    http = 0,
    acp = 0,
    done = 0,
    restore = 0,
    clear = 0,
    close = 0,
    execute = 0,
    autocmds = 0,
    external_side_effect = 0,
    reset = 0,
    request_cancel = 0,
    stop = 0,
    adapter_exit = 0,
    orchestrator_cancel = 0,
    notices = {},
    outputs = {},
    reset_opts = {},
    events = {},
    requests = {},
    add_message = 0,
    remove_tagged = 0,
    checkpoint = 0,
    ready = 0,
    parse_chat = 0,
    parse_tokens = 0,
    parse_meta = 0,
    compacting = 0,
  }
  local methods = callback_methods()
  local function record(event)
    table.insert(calls.events, event)
  end

  methods.submit = function(self, submit_opts)
    calls.submit = calls.submit + 1
    if self.current_request then
      return
    end
    submit_opts = submit_opts or {}
    if submit_opts.callback then
      submit_opts.callback()
    end
    if not submit_opts.auto_submit then
      if self.fixture_before_submit then
        self.fixture_before_submit(self)
      end
      if self:dispatch_cancellable('on_before_submit', { adapter = self.adapter }) then
        return self:restore()
      end
    end
    if self.fixture_host_submit_side_effects and not submit_opts.auto_submit then
      self:add_message({ role = 'user', content = 'submitted recovery input' })
      self.header_line = self.header_line + 10
      self.fixture_locked = true
    end
    if self.fixture_submit_error then
      error('fixture submit failed')
    end
    local payload = { messages = self.messages, marker = {} }
    calls.callback_payload = payload
    self:dispatch('on_submitted', { payload = payload })
    if self.fixture_skip_http then
      return
    end
    local result
    if self.adapter.type == 'http' then
      result = self:_submit_http(payload)
    else
      result = self:_submit_acp(payload)
    end
    if self.fixture_after_transport_error then
      error('fixture post-transport submit failed')
    end
    return result
  end
  methods._submit_http = function(self, payload)
    calls.http = calls.http + 1
    calls.transport_payload = payload
    calls.request_self = self
    if self.fixture_http_throw then
      error('fixture http construction failed')
    end
    local handle_status = 'pending'
    local on_request_cancel = self.fixture_on_request_cancel
    local handle = {
      id = 'request-' .. tostring(calls.http),
      status = function()
        return handle_status
      end,
      cancel = function()
        handle_status = 'cancelled'
        calls.request_cancel = calls.request_cancel + 1
        record('request_cancel')
        if on_request_cancel then
          on_request_cancel()
        end
      end,
      set_status = function(value)
        handle_status = value
      end,
    }
    local output, reasoning, tool_calls, meta = {}, {}, {}, {}
    local adapter = self.adapter
    local function process_chunk(data)
      if adapter.features and adapter.features.tokens then
        local token_count = host_adapters.call_handler(adapter, 'parse_tokens', data)
        if token_count then
          self.tokens = token_count
        end
      end
      local result = host_adapters.call_handler(adapter, 'parse_chat', data, tool_calls)
      local parse_meta = host_adapters.get_handler(adapter, 'parse_meta')
      if result and result.extra and type(parse_meta) == 'function' then
        result = parse_meta(adapter, result)
      end
      if not (result and result.status) then
        return
      end
      self.status = result.status
      if result.status == 'success' then
        if result.output and result.output.role then
          self._last_role = 'assistant'
        end
        if result.output and result.output.reasoning then
          table.insert(reasoning, result.output.reasoning)
          self:add_buf_message({ role = 'assistant', content = result.output.reasoning.content or '' }, {
            type = self.MESSAGE_TYPES.REASONING_MESSAGE,
          })
        end
        if result.output and result.output.meta then
          if result.output.meta.compaction then
            self:_set_status('compacting', 'Compacting the chat...')
            calls.compacting = calls.compacting + 1
          end
          meta = vim.tbl_deep_extend('force', meta, result.output.meta)
        end
        if result.output and result.output.content then
          table.insert(output, result.output.content)
          self:add_buf_message({ role = 'assistant', content = result.output.content }, {
            type = self.MESSAGE_TYPES.LLM_MESSAGE,
          })
        end
      elseif result.status == 'error' then
        self:done(output)
      end
    end
    local request = {
      self = self,
      payload = payload,
      handle = handle,
      on_chunk = function(data)
        handle_status = 'streaming'
        process_chunk(data)
      end,
      on_done = function(data)
        handle_status = 'success'
        if data and not (adapter.opts and adapter.opts.stream) then
          process_chunk(data)
        end
        self:done(output, reasoning, tool_calls, meta)
      end,
      on_error = function(error_value)
        handle_status = 'error'
        if self.status == 'cancelling' then
          return
        end
        self.status = 'error'
        calls.last_http_error = error_value
        self:done(output)
      end,
    }
    table.insert(calls.requests, request)
    if self.fixture_sync_send then
      self.fixture_sync_send(request)
    end
    self.current_request = handle
  end
  methods._submit_acp = function(self, payload)
    calls.acp = calls.acp + 1
    calls.acp_payload = payload
    self.current_request = {
      cancel = function()
        calls.request_cancel = calls.request_cancel + 1
      end,
    }
  end
  methods.add_message = function(self, data, message_opts)
    calls.add_message = calls.add_message + 1
    local message = vim.deepcopy(data)
    message._meta = message._meta or (message_opts and vim.deepcopy(message_opts._meta))
    message.visible = message.visible ~= nil and message.visible or (message_opts and message_opts.visible)
    table.insert(self.messages, message)
    record('history_message')
    if self.fixture_final_history_invalidate and data.role == host_config.constants.LLM_ROLE then
      self.fixture_final_history_invalidate(self)
    end
    if self.fixture_history_error then
      error('fixture history emission failed')
    end
    return message
  end
  methods.remove_tagged_message = function(self, tag)
    calls.remove_tagged = calls.remove_tagged + 1
    for index = #self.messages, 1, -1 do
      local message = self.messages[index]
      if message._meta and message._meta.tag == tag then
        table.remove(self.messages, index)
      end
    end
  end
  methods.checkpoint = function()
    calls.checkpoint = calls.checkpoint + 1
  end
  methods.ready_for_input = function(self, ready_opts)
    calls.ready = calls.ready + 1
    if not (ready_opts and ready_opts.auto_submit) then
      self:dispatch('on_ready')
    end
  end
  methods.tools_done = function(self, ready_opts)
    return self:ready_for_input(ready_opts)
  end
  methods._set_status = function(self, status)
    self.status = status
  end
  methods.done = function(self, output, reasoning, tool_calls, meta, done_opts)
    calls.done = calls.done + 1
    calls.last_done = {
      output = output,
      reasoning = reasoning,
      tool_calls = tool_calls,
      meta = meta,
      opts = done_opts,
    }
    if self.fixture_done_error then
      error('fixture preserved done failed')
    end
    self.current_request = nil
    local reasoning_content
    if type(reasoning) == 'table' and not vim.tbl_isempty(reasoning) then
      reasoning_content = host_adapters.call_handler(self.adapter, 'build_reasoning', reasoning)
    end
    if type(output) == 'table' and not vim.tbl_isempty(output) then
      table.insert(self.messages, {
        role = 'assistant',
        content = table.concat(output, ''),
        reasoning = reasoning_content,
      })
      reasoning_content = nil
    elseif type(meta) == 'table' and not vim.tbl_isempty(meta) then
      table.insert(self.messages, {
        role = 'assistant',
        content = '',
        reasoning = reasoning_content,
        visible = false,
        meta = vim.deepcopy(meta),
      })
      reasoning_content = nil
    end
    if type(tool_calls) == 'table' and not vim.tbl_isempty(tool_calls) then
      local formatted = host_adapters.call_handler(self.adapter, 'format_calls', tool_calls)
      if formatted then
        table.insert(self.messages, {
          role = 'assistant',
          reasoning = reasoning_content,
          tool_calls = formatted,
          visible = false,
        })
        self.tools:execute(self, formatted)
        return
      end
    end
    if self.fixture_done_submit then
      self:submit({ auto_submit = true })
    end
    if not self.fixture_skip_ready then
      self:ready_for_input()
    end
  end
  methods.stop = function(self)
    calls.stop = calls.stop + 1
    self.status = 'cancelling'
    record('stop')
    self:dispatch('on_cancelled')
    record('chat_stopped')
    if self.tool_orchestrator then
      self.tool_orchestrator:cancel()
      self.tool_orchestrator = nil
    end
    record('mcp_cancel')
    local handle = self.current_request
    self.current_request = nil
    if handle and type(handle.cancel) == 'function' then
      handle.cancel()
    end
    calls.adapter_exit = calls.adapter_exit + 1
    record('adapter_exit')
    vim.schedule(function()
      self:done(nil, nil, nil, nil, { status = 'stopped' })
    end)
  end
  methods.add_buf_message = function(self, data, message_opts)
    table.insert(calls.notices, { data = data, opts = message_opts })
    record('buffer_message')
    local final_output = message_opts and message_opts.type == self.MESSAGE_TYPES.LLM_MESSAGE
    if self.fixture_buffer_partial_lock and final_output then
      vim.bo[self.bufnr].modifiable = true
      vim.api.nvim_buf_set_lines(self.bufnr, 0, -1, false, { 'partial accepted output' })
      vim.bo[self.bufnr].modifiable = false
      error('fixture locked partial buffer emission failed')
    end
    if self.fixture_buffer_write and final_output then
      vim.api.nvim_buf_set_lines(self.bufnr, -1, -1, false, vim.split(data.content or '', '\n', { plain = true }))
    end
    if self.fixture_final_buffer_invalidate and final_output then
      self.fixture_final_buffer_invalidate(self)
    end
    if self.fixture_buffer_nil and final_output then
      return nil
    end
    if self.fixture_buffer_error and final_output then
      error('fixture buffer emission failed')
    end
    return #calls.notices
  end
  methods.add_tool_output = function(self, tool, for_llm, for_user)
    if self.fixture_require_function_name then
      self.fixture_last_function_name = tool.function_call['function'].name
    end
    local args = { tool = tool.name, for_llm = for_llm, for_user = for_user }
    self:dispatch('on_tool_output', args)
    table.insert(calls.outputs, {
      tool = tool,
      for_llm = args.for_llm,
      for_user = args.for_user,
    })
    local function_call = tool.function_call or {}
    local output = host_adapters.call_handler(self.adapter, 'format_response', function_call, args.for_llm)
    if not output then
      return
    end
    output._meta = { cycle = self.cycle }
    output._meta.id = host_hash.hash({ role = output.role, content = output.content })
    output.opts = vim.tbl_extend('force', output.opts or {}, { visible = true })
    local existing
    for _, message in ipairs(self.messages) do
      if message.tools and message.tools.call_id == function_call.id then
        existing = message
        break
      end
    end
    if existing then
      existing.content = existing.content == '' and output.content or (existing.content .. '\n\n' .. output.content)
    else
      table.insert(self.messages, output)
    end
    record('tool_result_recorded')
    if args.for_user ~= '' then
      self:add_buf_message({ role = 'assistant', content = args.for_user or args.for_llm }, {
        type = self.MESSAGE_TYPES.TOOL_MESSAGE,
      })
    end
  end
  methods.clear = function(self)
    calls.clear = calls.clear + 1
    record('host_clear')
    self.cycle = 1
    self.header_line = 1
    self.messages = {}
    self.tool_registry.in_use = {}
    if self.fixture_clear_render and vim.api.nvim_buf_is_valid(self.bufnr) then
      vim.bo[self.bufnr].modifiable = true
      vim.api.nvim_buf_set_lines(self.bufnr, 0, -1, false, { 'host cleared render' })
      vim.bo[self.bufnr].modifiable = false
    end
    if self.fixture_clear_error then
      error('fixture clear failed')
    end
    if self.fixture_clear_returns then
      return self.fixture_clear_returns()
    end
    if self.fixture_on_clear then
      self.fixture_on_clear(self)
    end
  end
  methods.close = function(self)
    calls.close = calls.close + 1
    record('close')
    if self.current_request then
      self:stop()
    end
    if self.fixture_on_close then
      self.fixture_on_close(self)
    end
    self:dispatch('on_closed')
  end
  methods.restore = function(self)
    calls.restore = calls.restore + 1
    self.fixture_locked = false
  end

  local tools_methods = {
    execute = function(self, host_chat, tool_calls)
      calls.execute = calls.execute + 1
      calls.autocmds = calls.autocmds + 1
      self.chat = host_chat
      self.last_calls = tool_calls
      calls.last_calls = tool_calls
      if self.fail_execute then
        error('fixture execute failed')
      end
      if self.unresolved_external then
        for _, unresolved_call in ipairs(tool_calls) do
          if type(unresolved_call) == 'table' then
            local copied = vim.deepcopy(unresolved_call)
            local fn = type(copied['function']) == 'table' and copied['function'] or {}
            host_chat:add_tool_output(
              { name = fn.name or 'unknown', function_call = copied },
              'host unresolved tool',
              ''
            )
          end
        end
        return
      end
      if self.external_side_effect then
        calls.external_side_effect = calls.external_side_effect + 1
      end
      host_chat.tool_orchestrator = {
        cancel = function()
          calls.orchestrator_cancel = calls.orchestrator_cancel + 1
          host_chat.tool_orchestrator = nil
        end,
      }
      return self.execute_result
    end,
    reset = function(self, reset_opts)
      calls.reset = calls.reset + 1
      record('tools_reset')
      table.insert(calls.reset_opts, vim.deepcopy(reset_opts or {}))
      if self.chat then
        self.chat.tool_orchestrator = nil
        self.chat:tools_done(reset_opts)
      end
    end,
  }

  local chat = {
    adapter = {
      type = opts.adapter_type or 'http',
      name = opts.adapter_name or 'fixture_http',
      features = { tokens = true },
      opts = { stream = true },
      handlers = {
        lifecycle = {},
        response = {
          build_reasoning = function(_, reasoning)
            return reasoning
          end,
          parse_chat = function(_, data, extracted_tools)
            calls.parse_chat = calls.parse_chat + 1
            if type(data) == 'table' and type(data.tool_calls) == 'table' then
              vim.list_extend(extracted_tools, data.tool_calls)
            end
            return data
          end,
          parse_tokens = function(_, data)
            calls.parse_tokens = calls.parse_tokens + 1
            return data and data.tokens or nil
          end,
          parse_meta = function(_, result)
            calls.parse_meta = calls.parse_meta + 1
            return result
          end,
        },
        tools = {
          format_calls = function(_, tool_calls)
            return tool_calls
          end,
          format_response = function(self, tool_call, output)
            return {
              role = self.roles and self.roles.tool or 'tool',
              tools = {
                id = tool_call.id,
                call_id = tool_call.call_id or tool_call.id,
                name = tool_call['function'] and tool_call['function'].name,
              },
              content = output,
              opts = { visible = false },
            }
          end,
        },
      },
      roles = { tool = 'tool' },
    },
    bufnr = vim.api.nvim_create_buf(false, true),
    callbacks = {},
    cycle = 1,
    current_request = nil,
    header_line = 1,
    id = 'fixture-chat',
    messages = {},
    MESSAGE_TYPES = {
      LLM_MESSAGE = 'llm_message',
      REASONING_MESSAGE = 'reasoning_message',
      SYSTEM_MESSAGE = 'system_message',
      TOOL_MESSAGE = 'tool_message',
      USER_MESSAGE = 'user_message',
    },
    restore = methods.restore,
    status = 'success',
    tokens = 0,
    subscribers = {
      stop = function(self)
        self.stopped = true
      end,
    },
    tool_registry = { in_use = vim.deepcopy(opts.in_use or {}) },
  }
  table.insert(created_buffers, chat.bufnr)

  local tools = {}
  if opts.inherited then
    setmetatable(chat, { __index = methods })
    setmetatable(tools, { __index = tools_methods })
  else
    for key, value in pairs(methods) do
      chat[key] = value
    end
    for key, value in pairs(tools_methods) do
      tools[key] = value
    end
  end
  chat.tools = tools
  tools.tools_config = vim.deepcopy(canonical_tool_configs or {})
  tools.tools_config.opts = tools.tools_config.opts or {}
  tools.constants = { STATUS_ERROR = 'error', STATUS_SUCCESS = 'success' }
  tools.status = tools.constants.STATUS_SUCCESS

  local originals = {}
  for _, key in ipairs({
    'submit',
    '_submit_http',
    '_submit_acp',
    'done',
    'add_buf_message',
    'add_tool_output',
    'clear',
    'close',
  }) do
    originals[key] = chat[key]
  end
  originals.execute = tools.execute
  return chat, calls, originals
end

local function attach_all(chat)
  for _, name in ipairs(Constants.tool_names) do
    chat.tool_registry.in_use[name] = true
  end
  return chat
end

local function start_workspace(chat, finalized)
  local workspace = State.begin(chat)
  local frame = assert(State.add(workspace, 'frame', {
    depth = 'standard',
    problem_type = 'analysis',
    branching_required = false,
    success_criteria = {},
    unknowns = {},
    temporal_required = false,
    perspectives = { { name = 'correctness', purpose = 'Check the result' } },
  }))
  State.set_frame(workspace, frame.id)
  if finalized then
    local item = assert(State.add(workspace, 'evidence', {
      perspective = 'correctness',
      addresses_unknowns = {},
    }))
    State.add(workspace, 'synthesis', {
      mode = 'final',
      frame_id = frame.id,
      selected_option_ids = {},
      support_ids = { item.id },
      review_ids = {},
      criterion_results = {},
    })
  end
  return workspace
end

local function frame_args(action)
  return {
    action = action or 'start',
    objective = 'Determine the safest implementation',
    problem_type = 'analysis',
    depth = 'standard',
    constraints = {},
    success_criteria = { 'Preserve host behavior' },
    unknowns = { 'Which boundary can drift' },
    perspectives = { { name = 'correctness', purpose = 'Check the result' } },
    temporal_required = false,
    branching_required = false,
    branching_rationale = 'The task is analytical rather than a choice among alternatives',
  }
end

local function formatted_call(id, name, arguments)
  return {
    id = id,
    type = 'function',
    ['function'] = {
      name = name,
      arguments = arguments == nil and {} or arguments,
    },
  }
end

local function decoded_tool_payloads(chat)
  local payloads = {}
  for _, message in ipairs(chat.messages) do
    if message.role == 'tool' then
      local ok, payload = pcall(vim.json.decode, message.content)
      if ok then
        table.insert(payloads, payload)
      end
    end
  end
  return payloads
end

local function controlled_chat(phase)
  local chat, calls = new_chat()
  attach_all(chat)
  if phase ~= 'armed' then
    start_workspace(chat, phase == 'finalized')
  end
  Control.reconcile(chat)
  Control._get(chat).phase = phase
  return chat, calls, Control._get(chat)
end

local function final_args()
  return {
    mode = 'final',
    conclusion = 'Use the verified implementation boundary',
    selected_option_ids = {},
    support_ids = { 'E1' },
    review_ids = {},
    criterion_results = {},
    tradeoffs = { 'Strict recovery requires explicit user action' },
    uncertainties = {},
    blind_spots = {},
    next_actions = { 'Keep the lifecycle controller installed' },
    confidence = 'high',
  }
end

local function final_ready_chat()
  local chat, calls, state = controlled_chat('active')
  assert(State.add(State.get(chat), 'evidence', {
    kind = 'observation',
    statement = 'The controlled boundary rejects unauthenticated completion',
    source = 'tests/control_test.lua',
    confidence = 'high',
    falsifier = 'An unauthenticated completion mutates state',
    perspective = 'correctness',
    addresses_unknowns = {},
  }))
  return chat, calls, state
end

local function prepare_final_output(chat, id, call_id)
  local call = formatted_call(id or 'final-call', 'reasoning_synthesis', final_args())
  call.call_id = call_id
  chat.tools:execute(chat, { call })
  local result = Protocol.call('synthesis', chat, vim.deepcopy(call['function'].arguments), 'active')
  local tool = { name = 'reasoning_synthesis', function_call = call }
  return result, tool, call
end

local function record_final_output(chat, result, tool)
  return Output.success(tool, { result.data }, { tools = chat.tools })
end

local function submit_request(chat, calls)
  chat:submit({ auto_submit = true })
  return calls.requests[#calls.requests]
end

local function drain_scheduled()
  vim.wait(10, function()
    return false
  end, 1)
end

local function resume_command_exists(chat)
  return vim.api.nvim_buf_get_commands(chat.bufnr, {})[Constants.resume_command] ~= nil
end

local function invoke_resume_command(chat)
  vim.api.nvim_buf_call(chat.bufnr, function()
    vim.cmd(Constants.resume_command)
  end)
end

local function set_resume_input(chat, content, calls)
  host_parser.messages = function(parser_chat, header_line)
    if calls then
      calls.parser_messages = (calls.parser_messages or 0) + 1
    end
    eq(parser_chat, chat)
    eq(header_line, chat.header_line)
    return content == nil and nil or { content = content }
  end
end

local function record_protocol_result(chat, call, result)
  chat.tool_orchestrator = nil
  chat:add_tool_output({
    name = call['function'].name,
    function_call = call,
  }, type(result) == 'string' and result or vim.json.encode(result.data), '')
end

local function execute_protocol_call(chat, call, phase)
  chat.tools:execute(chat, { call })
  local operation = Constants.operation_by_tool[call['function'].name]
  local result = Protocol.call(operation, chat, vim.deepcopy(call['function'].arguments), phase)
  record_protocol_result(chat, call, result)
  return result
end

local function install_legacy_guard(chat)
  return Terminal.install({
    chat = chat,
    bufnr = chat.bufnr,
    tools_config = { opts = { auto_submit_success = true } },
  })
end

T = MiniTest.new_set({
  hooks = {
    pre_case = function()
      Config.setup()
      Control._reset()
      State._reset()
      original_host_config = vim.deepcopy(host_config.config)
      host_parser.messages = canonical_parser_messages
      Extension.setup()
      canonical_tool_configs = {}
      for _, name in ipairs(Constants.tool_names) do
        canonical_tool_configs[name] = vim.deepcopy(host_config.interactions.chat.tools[name])
      end
      original_global_adapter = vim.g.codecompanion_adapter
      original_test_adapter = host_config.adapters.reasoning_control_test_acp
      vim.g.codecompanion_adapter = nil
    end,
    post_case = function()
      Control._reset()
      State._reset()
      vim.g.codecompanion_adapter = original_global_adapter
      host_config.adapters.reasoning_control_test_acp = original_test_adapter
      host_config.config = original_host_config
      host_parser.messages = canonical_parser_messages
      State.commit_final = original_commit_final
      State.rollback_final = original_rollback_final
      canonical_tool_configs = nil
      for _, bufnr in ipairs(created_buffers) do
        if vim.api.nvim_buf_is_valid(bufnr) then
          vim.api.nvim_buf_delete(bufnr, { force = true })
        end
      end
      created_buffers = {}
    end,
  },
})

T['arms synchronously only after the fifth HTTP reasoning tool'] = function()
  local chat, calls, originals = new_chat()
  for index = 1, 4 do
    chat.tool_registry.in_use[Constants.tool_names[index]] = true
    Control.reconcile(chat)
    eq(Control._get(chat), nil)
    eq(Control.phase(chat), nil)
    eq(chat.submit, originals.submit)
  end

  chat.tool_registry.in_use[Constants.tool_names[5]] = true
  Control.reconcile(chat)
  eq(Control.phase(chat), 'armed')
  eq(chat.submit == originals.submit, false)

  local nested_callback = 0
  chat:add_callback('on_submitted', function(inner)
    inner:submit({
      auto_submit = true,
      callback = function()
        nested_callback = nested_callback + 1
      end,
    })
  end)
  local outer_callback = 0
  chat:submit({
    auto_submit = true,
    callback = function()
      outer_callback = outer_callback + 1
    end,
  })
  eq(calls.submit, 1)
  eq(calls.http, 1)
  eq(calls.callback_payload == calls.transport_payload, true)
  eq(outer_callback, 1)
  eq(nested_callback, 1)
end

T['reports effective blocked phases and limits legacy terminal compatibility'] = function()
  local partial = new_chat()
  eq(Control.phase(partial), nil)
  eq(Control.legacy_terminal_allowed(partial), true)

  local complete = attach_all(new_chat())
  eq(Control.phase(complete), 'blocked')
  eq(Control.legacy_terminal_allowed(complete), false)

  local acp = attach_all(new_chat({ adapter_type = 'acp' }))
  eq(Control.phase(acp), 'blocked')
  Control.reconcile(acp)
  eq(Control._get(acp), nil)
  eq(Control.legacy_terminal_allowed(acp), false)

  Control.reconcile(complete)
  complete.tool_registry.in_use[Constants.tool_names[5]] = nil
  eq(Control.phase(complete), 'blocked')
  eq(Control.legacy_terminal_allowed(complete), false)

  Control.clear(complete)
  eq(Control.phase(complete), nil)
  eq(Control.legacy_terminal_allowed(complete), true)
  attach_all(complete)
  eq(Control.phase(complete), 'blocked')
  Control.reconcile(complete)
  eq(Control.phase(complete), 'armed')

  complete:close()
  eq(Control.phase(complete), 'blocked')
  eq(Control.legacy_terminal_allowed(complete), false)
end

T['hydrates active and finalized workspaces'] = function()
  local active = attach_all(new_chat())
  start_workspace(active, false)
  Control.reconcile(active)
  eq(Control.phase(active), 'active')

  local finalized = attach_all(new_chat())
  start_workspace(finalized, true)
  Control.reconcile(finalized)
  eq(Control.phase(finalized), 'finalized')
end

T['reconciliation is idempotent and controller state is collectible'] = function()
  local chat = attach_all(new_chat())
  Control.reconcile(chat)
  local state = Control._get(chat)
  local wrappers = {
    submit = rawget(chat, 'submit'),
    http = rawget(chat, '_submit_http'),
    acp = rawget(chat, '_submit_acp'),
    http = rawget(chat, '_submit_http'),
    execute = rawget(chat.tools, 'execute'),
    before = state.callbacks.on_before_submit,
  }
  Control.reconcile(chat)
  eq(rawget(chat, 'submit'), wrappers.submit)
  eq(rawget(chat, '_submit_http'), wrappers.http)
  eq(rawget(chat, '_submit_acp'), wrappers.acp)
  eq(rawget(chat, '_submit_http'), wrappers.http)
  eq(rawget(chat.tools, 'execute'), wrappers.execute)
  eq(Control._get(chat).callbacks.on_before_submit, wrappers.before)

  Control._reset()
  local weak
  local function create_controlled_chat()
    local value = attach_all(new_chat())
    Control.reconcile(value)
    weak = setmetatable({ value }, { __mode = 'v' })
  end
  create_controlled_chat()
  eq(Control._count(), 1)
  collectgarbage('collect')
  collectgarbage('collect')
  eq(weak[1], nil)
  eq(Control._count(), 0)
end

T['restores raw and inherited method ownership exactly'] = function()
  for _, inherited in ipairs({ false, true }) do
    local chat, _, originals = new_chat({ inherited = inherited })
    attach_all(chat)
    local raw_before = {}
    for _, key in ipairs({
      'submit',
      '_submit_http',
      '_submit_acp',
      'done',
      'add_buf_message',
      'add_tool_output',
      'clear',
      'close',
    }) do
      raw_before[key] = rawget(chat, key) ~= nil
    end
    local execute_raw_before = rawget(chat.tools, 'execute') ~= nil
    Control.reconcile(chat)
    eq(Control.uninstall(chat), true)
    for key, had_raw in pairs(raw_before) do
      eq(rawget(chat, key) ~= nil, had_raw)
      eq(chat[key], originals[key])
    end
    eq(rawget(chat.tools, 'execute') ~= nil, execute_raw_before)
    eq(chat.tools.execute, originals.execute)
    eq(#(chat.callbacks.on_before_submit or {}), 0)
  end
end

T['keeps initial ACP unsupported and notifies once without wrappers'] = function()
  local chat, calls, originals = new_chat({ adapter_type = 'acp' })
  attach_all(chat)
  Control.reconcile(chat)
  Control.reconcile(chat)

  eq(Control._get(chat), nil)
  eq(Control.phase(chat), 'blocked')
  eq(chat.submit, originals.submit)
  eq(#calls.notices, 1)
end

T['invalidates work and never restores a stage-less finalizing phase across ACP'] = function()
  local chat, calls = new_chat()
  attach_all(chat)
  Control.reconcile(chat)
  local state = Control._get(chat)
  state.phase = 'finalizing'
  state.resume_phase = 'finalizing'
  local active_token = { valid = true }
  local stop_token = { valid = true }
  local call = {}
  local call_token = { valid = true }
  local lease = { valid = true }
  local stage = { state = 'prepared' }
  state.active_request_token = active_token
  state.pending_stop_token = stop_token
  state.call_tokens[call] = call_token
  state.construction_lease = lease
  state.staged_final = stage
  state.resume_attempt = {}
  chat.current_request = {
    cancel = function()
      calls.request_cancel = calls.request_cancel + 1
      if chat.fixture_on_request_cancel then
        chat.fixture_on_request_cancel(chat)
      end
    end,
  }
  state.request_handle = chat.current_request
  chat.tool_orchestrator = {
    cancel = function()
      calls.orchestrator_cancel = calls.orchestrator_cancel + 1
      chat.tool_orchestrator = nil
    end,
  }
  local epoch = state.epoch
  chat.fixture_on_request_cancel = function()
    Control.reconcile(chat)
  end

  chat.adapter = { type = 'acp', name = 'fixture_acp' }
  Control.reconcile(chat)
  eq(Control.phase(chat), 'blocked')
  eq(state.unsupported_adapter, true)
  eq(state.phase, 'halted')
  eq(state.suspended_phase, 'halted')
  eq(state.resume_phase, 'active')
  eq(state.staged_final, nil)
  eq(stage.state, 'discarded')
  eq(active_token.valid, false)
  eq(stop_token.valid, false)
  eq(call_token.valid, false)
  eq(lease.valid, false)
  eq(state.active_request_token, nil)
  eq(state.pending_stop_token, nil)
  eq(state.construction_lease, nil)
  eq(state.request_handle, nil)
  eq(state.epoch, epoch + 1)
  eq(chat.current_request, nil)
  eq(chat.tool_orchestrator, nil)
  eq(calls.request_cancel, 1)
  eq(calls.orchestrator_cancel, 1)
  eq(#calls.notices, 1)

  chat:done(nil, nil, { { id = 'late', ['function'] = { name = 'external' } } })
  chat:add_tool_output({}, 'late', 'late')
  chat.tools:execute(chat, {})
  eq(calls.done, 0)
  eq(calls.execute, 0)
  eq(#calls.outputs, 0)

  Control.reconcile(chat)
  eq(#calls.notices, 1)
  chat.adapter = { type = 'http', name = 'fixture_http' }
  Control.reconcile(chat)
  eq(Control.phase(chat), 'halted')
  eq(state.unsupported_adapter, false)
  chat.adapter = { type = 'acp', name = 'fixture_acp' }
  Control.reconcile(chat)
  eq(#calls.notices, 2)

  local dormant = attach_all(new_chat())
  Control.reconcile(dormant)
  Control.clear(dormant)
  dormant.adapter = { type = 'acp', name = 'fixture_acp' }
  Control.reconcile(dormant)
  dormant.adapter = { type = 'http', name = 'fixture_http' }
  Control.reconcile(dormant)
  eq(Control.phase(dormant), 'armed')
end

T['fails closed for removed tools and live orchestrators'] = function()
  local chat, calls = new_chat()
  attach_all(chat)
  Control.reconcile(chat)
  chat.tool_registry.in_use[Constants.tool_names[5]] = nil
  local callback_count = 0
  chat:submit({
    callback = function()
      callback_count = callback_count + 1
    end,
  })
  eq(callback_count, 1)
  eq(calls.submit, 0)
  eq(calls.http, 0)
  eq(#calls.notices, 1)
  MiniTest.expect.equality(calls.notices[1].data.content:match('reattach') ~= nil, true)
  chat:submit()
  eq(calls.restore, 1)

  attach_all(chat)
  Control.reconcile(chat)
  chat.tool_orchestrator = {}
  chat:submit()
  eq(calls.restore, 2)
  eq(calls.submit, 0)
  chat.tool_orchestrator = nil
  chat:submit({ auto_submit = true })
  eq(calls.submit, 1)
  eq(calls.http, 1)
end

T['catches removal and configured ACP at the preserved manual callback boundary'] = function()
  local chat, calls = new_chat()
  attach_all(chat)
  Control.reconcile(chat)
  chat.fixture_before_submit = function(value)
    value.tool_registry.in_use[Constants.tool_names[5]] = nil
  end
  chat:submit()
  eq(calls.submit, 1)
  eq(calls.http, 0)
  eq(calls.restore, 1)

  local configured, configured_calls = new_chat()
  attach_all(configured)
  Control.reconcile(configured)
  host_config.adapters.reasoning_control_test_acp = {
    name = 'reasoning_control_test_acp',
    type = 'acp',
  }
  vim.g.codecompanion_adapter = 'reasoning_control_test_acp'
  configured:submit()
  eq(configured_calls.submit, 1)
  eq(configured_calls.http, 0)
  eq(configured_calls.acp, 0)
  eq(configured_calls.restore, 1)
end

T['guards a late adapter swap after on_before_submit'] = function()
  local chat, calls = new_chat()
  attach_all(chat)
  Control.reconcile(chat)
  eq(vim.g.codecompanion_adapter, nil)
  eq(Control.phase(chat), 'armed')
  chat:add_callback('on_before_submit', function(value)
    value.adapter = { type = 'acp', name = 'late_acp' }
  end)

  chat:submit()
  eq(calls.submit, 1)
  eq(calls.http, 0)
  eq(calls.acp, 0)
  eq(calls.restore, 1)
  eq(chat.adapter.type, 'acp')
  eq(Control._get(chat).unsupported_adapter, true)
  eq(Control.phase(chat), 'blocked')
end

T['clears legacy terminal guards on complete HTTP ACP and dormant rearm'] = function()
  local http, _, http_originals = new_chat()
  for index = 1, 4 do
    http.tool_registry.in_use[Constants.tool_names[index]] = true
  end
  eq(install_legacy_guard(http), true)
  eq(rawget(http, '_codecompanion_reasoning_terminal_guard') ~= nil, true)
  http.tool_registry.in_use[Constants.tool_names[5]] = true
  Control.reconcile(http)
  eq(rawget(http, '_codecompanion_reasoning_terminal_guard'), nil)
  eq(Control._get(http).methods.submit.original, http_originals.submit)

  local acp, _, acp_originals = new_chat({ adapter_type = 'acp' })
  for index = 1, 4 do
    acp.tool_registry.in_use[Constants.tool_names[index]] = true
  end
  eq(install_legacy_guard(acp), true)
  acp.tool_registry.in_use[Constants.tool_names[5]] = true
  Control.reconcile(acp)
  eq(rawget(acp, '_codecompanion_reasoning_terminal_guard'), nil)
  eq(acp.submit, acp_originals.submit)
  eq(Control.phase(acp), 'blocked')

  local dormant = attach_all(new_chat())
  Control.reconcile(dormant)
  local wrapper = rawget(dormant, 'submit')
  Control.clear(dormant)
  dormant.tool_registry.in_use[Constants.tool_names[5]] = nil
  eq(install_legacy_guard(dormant), true)
  eq(rawget(dormant, 'submit') == wrapper, false)
  dormant.tool_registry.in_use[Constants.tool_names[5]] = true
  Control.reconcile(dormant)
  eq(rawget(dormant, '_codecompanion_reasoning_terminal_guard'), nil)
  eq(rawget(dormant, 'submit'), wrapper)
  eq(Control.phase(dormant), 'armed')
end

T['does not install a legacy guard when recording completes the controlled tool set'] = function()
  local chat = new_chat()
  for index = 1, #Constants.tool_names - 1 do
    chat.tool_registry.in_use[Constants.tool_names[index]] = true
  end
  local workspace = start_workspace(chat, false)
  assert(State.add(workspace, 'evidence', {
    kind = 'observation',
    statement = 'The standalone final is supported',
    source = 'tests/control_test.lua',
    confidence = 'high',
    falsifier = 'The supporting observation is withdrawn',
    perspective = 'correctness',
    addresses_unknowns = {},
  }))
  local result = Protocol.call('synthesis', chat, final_args(), nil)
  eq(result.status, 'success')
  eq(result.data.artifact.id, 'S1')
  chat.tools.chat = chat
  chat:add_callback('on_tool_output', function(value)
    attach_all(value)
    Control.reconcile(value)
  end)
  local call = formatted_call('standalone-final', 'reasoning_synthesis', final_args())

  record_final_output(chat, result, { name = 'reasoning_synthesis', function_call = call })

  eq(Control.phase(chat), 'finalized')
  eq(rawget(chat, '_codecompanion_reasoning_terminal_guard'), nil)
  eq(Control._get(chat).boundary_issue, nil)
end

T['keeps controlled terminal output on the existing submit wrapper'] = function()
  local chat = attach_all(new_chat())
  Control.reconcile(chat)
  chat.tools.chat = chat
  local wrapper = rawget(chat, 'submit')
  Output.success({ name = 'reasoning_synthesis' }, {
    {
      workspace_id = 'W1',
      artifact = { id = 'S1', kind = 'synthesis', data = { mode = 'final' } },
      unmet_gates = {},
      next_action = { tool = 'none', reason = 'Terminal' },
    },
  }, { tools = chat.tools })
  eq(rawget(chat, 'submit'), wrapper)
  eq(rawget(chat, '_codecompanion_reasoning_terminal_guard'), nil)
end

T['blocks command mutation on live ACP and replaced tools boundaries'] = function()
  local modules = {
    require('codecompanion._extensions.reasoning.tools.frame'),
    require('codecompanion._extensions.reasoning.tools.evidence'),
    require('codecompanion._extensions.reasoning.tools.options'),
    require('codecompanion._extensions.reasoning.tools.review'),
    require('codecompanion._extensions.reasoning.tools.synthesis'),
  }
  local acp = attach_all(new_chat())
  Control.reconcile(acp)
  acp.adapter = { type = 'acp', name = 'eventless_acp' }
  for _, tool in ipairs(modules) do
    local result = tool.cmds[1]({ chat = acp }, {}, {})
    eq(result.data.code, 'transition_invalid')
    eq(result.data.committed, false)
  end
  eq(State.get(acp), nil)

  local replaced = attach_all(new_chat())
  Control.reconcile(replaced)
  replaced.tools = { execute = function() end, reset = function() end }
  local result = modules[1].cmds[1]({ chat = replaced }, {}, {})
  eq(result.data.code, 'transition_invalid')
  eq(State.get(replaced), nil)

  local drifted = attach_all(new_chat())
  Control.reconcile(drifted)
  local foreign_execute = 0
  drifted.tools.execute = function()
    foreign_execute = foreign_execute + 1
  end
  eq(Control.phase(drifted), 'blocked')
  result = modules[1].cmds[1]({ chat = drifted }, {}, {})
  eq(result.data.code, 'transition_invalid')
  eq(State.get(drifted), nil)
  drifted:done(nil, nil, { { id = 'foreign', ['function'] = { name = 'external' } } })
  eq(foreign_execute, 0)

  local during, during_calls = new_chat()
  attach_all(during)
  Control.reconcile(during)
  local during_foreign = 0
  during.adapter.handlers.tools.format_calls = function(_, tool_calls)
    during.tools.execute = function()
      during_foreign = during_foreign + 1
    end
    return tool_calls
  end
  local during_request = submit_request(during, during_calls)
  -- Use the bound transport callback, matching the only authenticated completion path.
  during_request.on_chunk({
    status = 'success',
    tool_calls = { { id = 'during', ['function'] = { name = 'external' } } },
  })
  during_request.on_done()
  eq(during_foreign, 0)
  eq(Control.phase(during), 'blocked')

  local replaced_during, replaced_calls = new_chat()
  attach_all(replaced_during)
  Control.reconcile(replaced_during)
  local replaced_foreign = 0
  replaced_during.adapter.handlers.tools.format_calls = function(_, tool_calls)
    replaced_during.tools = {
      execute = function()
        replaced_foreign = replaced_foreign + 1
      end,
    }
    return tool_calls
  end
  local replaced_request = submit_request(replaced_during, replaced_calls)
  replaced_request.on_chunk({
    status = 'success',
    tool_calls = { { id = 'during-replace', ['function'] = { name = 'external' } } },
  })
  replaced_request.on_done()
  eq(replaced_foreign, 0)
  eq(Control.phase(replaced_during), 'blocked')

  local legacy_during, legacy_calls = new_chat()
  attach_all(legacy_during)
  Control.reconcile(legacy_during)
  local legacy_foreign = 0
  legacy_during.adapter.handlers = {
    tools = {
      format_tool_calls = function(_, tool_calls)
        legacy_during.tools.execute = function()
          legacy_foreign = legacy_foreign + 1
        end
        return tool_calls
      end,
    },
  }
  local legacy_request = submit_request(legacy_during, legacy_calls)
  legacy_request.self:done(nil, nil, { { id = 'legacy-during', ['function'] = { name = 'external' } } })
  eq(legacy_foreign, 0)
  eq(Control.phase(legacy_during), 'blocked')

  local swap_during, swap_calls = new_chat()
  attach_all(swap_during)
  Control.reconcile(swap_during)
  local swap_foreign = 0
  local build_calls = 0
  local second_adapter = {
    type = 'http',
    name = 'second',
    handlers = {
      lifecycle = {},
      tools = {
        format_calls = function(_, tool_calls)
          swap_during.tools.execute = function()
            swap_foreign = swap_foreign + 1
          end
          return tool_calls
        end,
      },
    },
  }
  swap_during.adapter.handlers.response.build_reasoning = function(_, reasoning)
    build_calls = build_calls + 1
    swap_during.adapter = second_adapter
    return reasoning
  end
  local swap_request = submit_request(swap_during, swap_calls)
  swap_request.self:done(nil, { 'private chain' }, {
    { id = 'reasoning-swap', ['function'] = { name = 'external' } },
  })
  eq(build_calls, 0)
  eq(swap_foreign, 0)
  eq(swap_calls.execute, 1)
end

T['clear and close invalidate request tool and prepared-final activity'] = function()
  local cleared, clear_calls = new_chat()
  attach_all(cleared)
  start_workspace(cleared, false)
  Control.reconcile(cleared)
  local clear_state = Control._get(cleared)
  local stage = { state = 'prepared' }
  clear_state.staged_final = stage
  cleared.current_request = {
    cancel = function()
      clear_calls.request_cancel = clear_calls.request_cancel + 1
    end,
  }
  clear_state.request_handle = cleared.current_request
  cleared.tool_orchestrator = {
    cancel = function()
      clear_calls.orchestrator_cancel = clear_calls.orchestrator_cancel + 1
      cleared.tool_orchestrator = nil
    end,
  }
  cleared:clear()
  eq(State.get(cleared), nil)
  eq(Control.phase(cleared), nil)
  eq(clear_state.phase, 'dormant')
  eq(stage.state, 'discarded')
  eq(clear_calls.request_cancel, 1)
  eq(clear_calls.orchestrator_cancel, 1)

  local closed, close_calls = new_chat()
  attach_all(closed)
  Control.reconcile(closed)
  closed:submit({ auto_submit = true })
  closed.tool_orchestrator = {
    cancel = function()
      close_calls.orchestrator_cancel = close_calls.orchestrator_cancel + 1
      table.insert(close_calls.events, 'orchestrator_cancel')
      closed.tool_orchestrator = nil
    end,
  }
  local reentered_close = false
  closed:add_callback('on_cancelled', function()
    table.insert(close_calls.events, 'on_cancelled')
    if not reentered_close then
      reentered_close = true
      closed:close()
    end
  end)
  closed:add_callback('on_closed', function()
    table.insert(close_calls.events, 'on_closed')
  end)
  closed:close()
  eq(close_calls.stop, 1)
  eq(close_calls.close, 1)
  eq(close_calls.adapter_exit, 1)
  eq(close_calls.request_cancel, 1)
  eq(close_calls.orchestrator_cancel, 1)
  eq(close_calls.events, {
    'close',
    'stop',
    'on_cancelled',
    'chat_stopped',
    'orchestrator_cancel',
    'mcp_cancel',
    'request_cancel',
    'adapter_exit',
    'on_closed',
  })
  eq(Control.phase(closed), 'blocked')
  closed:done(nil, nil, { { id = 'late', ['function'] = { name = 'external' } } })
  closed:add_tool_output({}, 'late', 'late')
  closed.tools:execute(closed, {})
  eq(close_calls.done, 0)
  eq(close_calls.execute, 0)
  eq(#close_calls.outputs, 0)

  local orphan, orphan_calls = new_chat()
  attach_all(orphan)
  Control.reconcile(orphan)
  orphan.tool_orchestrator = {
    cancel = function()
      orphan_calls.orchestrator_cancel = orphan_calls.orchestrator_cancel + 1
      orphan.tool_orchestrator = nil
    end,
  }
  orphan:close()
  eq(orphan_calls.stop, 0)
  eq(orphan_calls.orchestrator_cancel, 1)
end

T['clear resets one lifecycle without fabricating a generation'] = function()
  local chat, calls, state = controlled_chat('active')
  local other = {}
  local other_workspace = State.begin(other)
  chat.fixture_skip_ready = true
  local resume_during_clear
  chat.fixture_on_request_cancel = function()
    resume_during_clear = Control.resume(chat)
    chat:submit({ auto_submit = true })
    chat:done(nil, nil, nil, nil, { status = 'stopped' })
  end
  local request = submit_request(chat, calls)
  local generation = state.request_generation
  local epoch = state.epoch
  local active = state.active_request_token
  local pending_token = { valid = true }
  local pending = { valid = true, token = pending_token }
  local fallback = { valid = true }
  local construction = { valid = true, consumed = false }
  local resume = { valid = true }
  local stage = { state = 'prepared' }
  local scope = { valid = true }
  local observed = state.observed_call_ids
  chat.tools.chat = chat
  state.pending_stop_token = pending
  state.fallback_lease = fallback
  state.construction_lease = construction
  state.resume_attempt = resume
  state.executing_scope = scope
  state.staged_final = { stage = stage }
  table.insert(chat.messages, {
    role = 'system',
    content = 'remove correction',
    _meta = { tag = Constants.corrective_tag },
  })
  chat.tool_orchestrator = {
    cancel = function()
      calls.orchestrator_cancel = calls.orchestrator_cancel + 1
      table.insert(calls.events, 'orchestrator_cancel')
      chat:submit({ auto_submit = true })
      chat.tool_orchestrator = nil
      chat.tools:reset({ auto_submit = false })
    end,
  }
  chat.cycle = 7
  chat.header_line = 23
  chat.fixture_clear_render = true
  state.phase = 'halted'
  state.resume_phase = 'active'
  set_resume_input(chat, 'do not resume during clear', calls)
  local clear_event = 0
  chat.fixture_on_clear = function(inner)
    clear_event = clear_event + 1
    eq(Control.clear(inner), false)
  end

  chat:clear()

  eq(calls.clear, 1)
  eq(calls.request_cancel, 1)
  eq(calls.orchestrator_cancel, 1)
  eq(calls.reset, 1)
  eq(calls.submit, 1)
  eq(calls.done, 0)
  eq(calls.restore, 0)
  eq(calls.parser_messages, nil)
  eq(resume_during_clear, false)
  eq(clear_event, 1)
  eq(calls.events, { 'request_cancel', 'orchestrator_cancel', 'tools_reset', 'host_clear' })
  eq(state.phase, 'dormant')
  eq(state.request_generation, generation)
  eq(state.epoch, epoch + 1)
  eq(state.active_request_token, nil)
  eq(state.pending_stop_token, nil)
  eq(state.fallback_lease, nil)
  eq(state.construction_lease, nil)
  eq(state.resume_attempt, nil)
  eq(state.executing_scope, nil)
  eq(state.staged_final, nil)
  eq(state.completion_classified, true)
  eq(state.clearing, false)
  eq(active.valid, false)
  eq(pending.valid, false)
  eq(pending_token.valid, false)
  eq(fallback.valid, false)
  eq(construction.valid, false)
  eq(construction.consumed, true)
  eq(resume.valid, false)
  eq(scope.valid, false)
  eq(state.observed_call_ids, observed)
  eq(stage.state, 'discarded')
  eq(State.get(chat), nil)
  eq(State.get(other), other_workspace)
  eq(chat.current_request, nil)
  eq(chat.tool_orchestrator, nil)
  eq(chat.cycle, 1)
  eq(chat.header_line, 1)
  eq(chat.messages, {})
  eq(vim.api.nvim_buf_get_lines(chat.bufnr, 0, -1, false), { 'host cleared render' })
  eq(request.handle:status(), 'cancelled')
end

T['clear preserves host returns and always releases its reentrancy guard'] = function()
  local chat, calls, state = controlled_chat('active')
  chat.fixture_clear_returns = function()
    return nil, 'tail', false
  end
  local first, second, third = chat:clear()
  eq({ first, second, third }, { nil, 'tail', false })
  eq(state.clearing, false)
  eq(state.phase, 'dormant')
  eq(calls.clear, 1)

  attach_all(chat)
  Control.reconcile(chat)
  chat.fixture_clear_returns = nil
  chat.fixture_clear_error = true
  local ok, err = pcall(chat.clear, chat)
  eq(ok, false)
  eq(type(err) == 'string' and err:find('fixture clear failed', 1, true) ~= nil, true)
  eq(state.clearing, false)
  eq(state.phase, 'dormant')
  eq(State.get(chat), nil)
  eq(calls.clear, 2)
end

T['dormant wrappers pass ordinary activity until the fifth tool rearms'] = function()
  local chat, calls, state = controlled_chat('active')
  chat:clear()
  local generation = state.request_generation

  chat:submit({ auto_submit = true })
  eq(calls.submit, 1)
  eq(calls.http, 1)
  eq(state.request_generation, generation)
  local request = calls.requests[#calls.requests]
  request.on_done()
  eq(calls.done, 1)

  local external = formatted_call('ordinary-after-clear', 'read_file', {})
  chat:add_tool_output({ name = 'read_file', function_call = external }, 'ordinary result', '')
  eq(#calls.outputs, 1)
  chat.tools:execute(chat, { external })
  eq(calls.execute, 1)
  chat.tool_orchestrator = nil

  for index = 1, #Constants.tool_names - 1 do
    chat.tool_registry.in_use[Constants.tool_names[index]] = true
    Control.reconcile(chat)
    eq(state.phase, 'dormant')
    eq(Control.phase(chat), nil)
  end
  chat.tool_registry.in_use[Constants.tool_names[#Constants.tool_names]] = true
  Control.reconcile(chat)
  eq(state.phase, 'armed')
  eq(Control.phase(chat), 'armed')
  eq(State.get(chat), nil)
end

T['dormant fifth attachment reconciles ownership before delegation'] = function()
  local chat, calls, state = controlled_chat('active')
  chat:clear()
  attach_all(chat)
  chat.tools.tools_config.reasoning_frame = {
    cmds = {
      function()
        calls.external_side_effect = calls.external_side_effect + 1
      end,
    },
  }

  chat:submit({ auto_submit = true })
  chat.tools:execute(chat, { formatted_call('forged-dormant', 'reasoning_frame', frame_args()) })

  eq(calls.submit, 0)
  eq(calls.execute, 0)
  eq(calls.external_side_effect, 0)
  eq(state.phase, 'dormant')
  eq(state.boundary_issue, 'tool_ownership')
  eq(Control.phase(chat), 'blocked')
  eq(State.get(chat), nil)
end

T['dormant submit lease blocks a clear-winning host continuation'] = function()
  local chat, calls, state = controlled_chat('active')
  chat:clear()
  local uninstalled
  chat:add_callback('on_submitted', function(inner)
    inner:clear()
    uninstalled = Control.uninstall(inner)
  end)

  chat:submit({ auto_submit = true })

  eq(calls.submit, 1)
  eq(calls.http, 0)
  eq(calls.clear, 2)
  eq(uninstalled, false)
  eq(state.phase, 'dormant')
  eq(state.clear_during_submit, false)
  eq(#state.dormant_submit_stack, 0)
  eq(chat.current_request, nil)
  eq(Control._get(chat), state)
end

T['uninstall refuses every unsettled owner and preserves accepted state when safe'] = function()
  local blockers = {
    closed = function(_, state)
      state.closed = true
    end,
    current_request = function(chat)
      chat.current_request = {}
    end,
    request_handle = function(_, state)
      state.request_handle = {}
    end,
    active_request = function(_, state)
      state.active_request_token = {}
    end,
    pending_stop = function(_, state)
      state.pending_stop_token = {}
    end,
    executing = function(_, state)
      state.executing_scope = {}
    end,
    orchestrator = function(chat)
      chat.tool_orchestrator = {}
    end,
    fallback = function(_, state)
      state.fallback_lease = {}
    end,
    construction = function(_, state)
      state.construction_lease = {}
    end,
    resume = function(_, state)
      state.resume_attempt = {}
    end,
    staged = function(_, state)
      state.staged_final = { stage = { state = 'prepared' } }
    end,
    submitting = function(_, state)
      state.submitting = true
    end,
    processing_done = function(_, state)
      state.processing_done = true
    end,
    clearing = function(_, state)
      state.clearing = true
    end,
    cleared_submission = function(_, state)
      state.clear_during_submit = true
    end,
    protected_submission = function(_, state)
      state.protected_submit_depth = 1
    end,
    unclassified = function(_, state)
      state.completion_classified = false
    end,
  }

  for name, block in pairs(blockers) do
    Control._reset()
    State._reset()
    local chat = attach_all(new_chat())
    Control.reconcile(chat)
    local state = Control._get(chat)
    local wrapper = rawget(chat, 'submit')
    block(chat, state)
    eq(Control.uninstall(chat), false)
    eq(Control._get(chat), state)
    eq(rawget(chat, 'submit'), wrapper)
    eq(resume_command_exists(chat), true)
  end

  Control._reset()
  State._reset()
  local chat = attach_all(new_chat())
  local workspace = start_workspace(chat, false)
  Control.reconcile(chat)
  eq(Control.uninstall(chat), true)
  eq(Control.uninstall(chat), false)
  eq(Control._get(chat), nil)
  eq(State.get(chat), workspace)
  eq(resume_command_exists(chat), false)
  eq(#(chat.callbacks.on_before_submit or {}), 0)
end

T['uninstall refuses wrapper drift but accepts an exact terminal overlay'] = function()
  local drifted = attach_all(new_chat())
  Control.reconcile(drifted)
  local state = Control._get(drifted)
  local replacement = function() end
  rawset(drifted, 'done', replacement)
  eq(Control.uninstall(drifted), false)
  eq(Control._get(drifted), state)
  eq(rawget(drifted, 'done'), replacement)
  eq(resume_command_exists(drifted), true)
  eq(#(drifted.callbacks.on_before_submit or {}), 1)

  Control._reset()
  local overlaid = attach_all(new_chat())
  Control.reconcile(overlaid)
  overlaid:clear()
  eq(install_legacy_guard(overlaid), true)
  local guard = rawget(overlaid, '_codecompanion_reasoning_terminal_guard')
  guard.had_raw_submit = false
  eq(Control.uninstall(overlaid), false)
  eq(Control._get(overlaid) ~= nil, true)
  guard.had_raw_submit = true
  eq(Control.uninstall(overlaid), true)
  eq(Control._get(overlaid), nil)
  eq(rawget(overlaid, '_codecompanion_reasoning_terminal_guard'), nil)
end

T['close leaves inert tombstones and cleans controller-owned state'] = function()
  local chat, calls = new_chat()
  attach_all(chat)
  start_workspace(chat, false)
  Control.reconcile(chat)
  local state = Control._get(chat)
  local wrappers = {
    submit = rawget(chat, 'submit'),
    done = rawget(chat, 'done'),
    buffer = rawget(chat, 'add_buf_message'),
    output = rawget(chat, 'add_tool_output'),
    clear = rawget(chat, 'clear'),
    close = rawget(chat, 'close'),
    execute = rawget(chat.tools, 'execute'),
  }
  chat.tool_orchestrator = {
    cancel = function()
      calls.orchestrator_cancel = calls.orchestrator_cancel + 1
      chat.tool_orchestrator = nil
    end,
  }

  chat:close()

  eq(state.closed, true)
  eq(State.get(chat), nil)
  eq(Control._get(chat), state)
  eq(resume_command_exists(chat), false)
  eq(rawget(chat, 'submit'), wrappers.submit)
  eq(rawget(chat, 'done'), wrappers.done)
  eq(rawget(chat, 'add_buf_message'), wrappers.buffer)
  eq(rawget(chat, 'add_tool_output'), wrappers.output)
  eq(rawget(chat, 'clear'), wrappers.clear)
  eq(rawget(chat, 'close'), wrappers.close)
  eq(rawget(chat.tools, 'execute'), wrappers.execute)
  eq(calls.orchestrator_cancel, 1)
  eq(Control.uninstall(chat), false)

  local before = vim.deepcopy(calls)
  local callback = 0
  chat:submit({
    callback = function()
      callback = callback + 1
    end,
  })
  chat:_submit_http({ late = true })
  chat:_submit_acp({ late = true })
  chat:done()
  chat:add_buf_message({ role = 'assistant', content = 'late prose' }, { type = chat.MESSAGE_TYPES.LLM_MESSAGE })
  chat:add_tool_output({}, 'late output', 'late output')
  chat.tools:execute(chat, {})
  chat:clear()
  chat:close()
  chat:dispatch('on_ready')
  drain_scheduled()
  eq(callback, 0)
  eq(calls.submit, before.submit)
  eq(calls.http, before.http)
  eq(calls.acp, before.acp)
  eq(calls.done, before.done)
  eq(#calls.notices, #before.notices)
  eq(#calls.outputs, #before.outputs)
  eq(calls.execute, before.execute)
  eq(calls.clear, before.clear)
  eq(calls.close, before.close)
  eq(#(chat.callbacks.on_before_submit or {}), 0)
  eq(#(chat.callbacks.on_submitted or {}), 0)
  eq(#(chat.callbacks.on_ready or {}), 0)
  eq(#(chat.callbacks.on_cancelled or {}), 0)
  eq(#(chat.callbacks.on_closed or {}), 0)
end

T['explicit clear removes a partial-chat legacy terminal guard'] = function()
  local chat = new_chat()
  eq(install_legacy_guard(chat), true)
  eq(rawget(chat, '_codecompanion_reasoning_terminal_guard') ~= nil, true)

  eq(Control.clear(chat), false)

  eq(rawget(chat, '_codecompanion_reasoning_terminal_guard'), nil)
  eq(State.get(chat), nil)
end

T['halts safely after preserved submit errors and exposes total placeholders'] = function()
  local chat = attach_all(new_chat())
  Control.reconcile(chat)
  chat.fixture_submit_error = true
  chat:submit({ auto_submit = true })
  local state = Control._get(chat)
  eq(state.submitting, false)
  eq(state.phase, 'halted')
  eq(state.resume_phase, 'armed')
  eq(state.consecutive_violations, 0)
  eq({ Control.stage_final(chat, {}, {}) }, { nil, 'reasoning final stage is unavailable' })
  eq(Control.resume(chat), false)
end

T['suppresses model prose while preserving tool system and user traffic'] = function()
  for _, phase in ipairs({ 'armed', 'active', 'reframing', 'finalizing', 'halted' }) do
    local chat, calls = controlled_chat(phase)
    for _, item in ipairs({
      { type = chat.MESSAGE_TYPES.LLM_MESSAGE, content = 'private prose' },
      { type = chat.MESSAGE_TYPES.REASONING_MESSAGE, content = 'private reasoning' },
      { type = chat.MESSAGE_TYPES.TOOL_MESSAGE, content = 'tool result' },
      { type = chat.MESSAGE_TYPES.SYSTEM_MESSAGE, content = 'system status' },
      { type = chat.MESSAGE_TYPES.USER_MESSAGE, content = 'user text' },
    }) do
      chat:add_buf_message({ role = 'assistant', content = item.content }, { type = item.type })
    end
    local expected = phase == 'finalizing' and { 'system status', 'user text' }
      or { 'tool result', 'system status', 'user text' }
    eq(
      vim.tbl_map(function(item)
        return item.data.content
      end, calls.notices),
      expected
    )
  end

  local chat, calls = controlled_chat('active')
  chat.messages = { { role = 'user', content = 'inspect the project' } }
  local tool_calls = { formatted_call('external-1', 'read_file', { path = 'README.md' }) }
  local request = submit_request(chat, calls)
  request.on_chunk({
    status = 'success',
    output = { content = 'free-form answer', reasoning = { content = 'private chain' } },
    tool_calls = tool_calls,
  })
  request.on_done()
  eq(calls.execute, 1)
  eq(calls.last_calls, tool_calls)
  eq(#chat.messages, 2)
  eq(
    vim.tbl_map(function(message)
      return message.role
    end, chat.messages),
    { 'user', 'assistant' }
  )
  local encoded = vim.json.encode(chat.messages)
  eq(encoded:find('free%-form answer') == nil, true)
  eq(encoded:find('private chain', 1, true) == nil, true)

  local zero, zero_calls = controlled_chat('active')
  zero.messages = { { role = 'user', content = 'continue' } }
  zero.fixture_skip_ready = true
  local zero_request = submit_request(zero, zero_calls)
  zero_request.on_chunk({
    status = 'success',
    output = { content = 'unstructured', reasoning = { content = 'hidden' } },
  })
  zero_request.on_done()
  eq(zero_calls.done, 1)
  eq(zero.messages[1], { role = 'user', content = 'continue' })
  eq(zero.messages[2]._meta.tag, Constants.corrective_tag)
end

T['delegates external batches unchanged and authenticates unresolved deep copies only in scope'] = function()
  local chat, calls, state = controlled_chat('armed')
  chat.tools.external_side_effect = true
  chat.tools.execute_result = 'delegated'
  local batch = {
    formatted_call('external-a', 'read_file', { path = 'README.md' }),
    formatted_call('external-b', 'run_command', { command = 'rg TODO' }),
  }
  eq(chat.tools:execute(chat, batch), 'delegated')
  eq(calls.execute, 1)
  eq(calls.last_calls, batch)
  eq(calls.external_side_effect, 1)
  eq(state.phase, 'armed')
  eq(state.consecutive_violations, 0)
  eq(state.executing_scope, nil)

  local failing, failing_calls, failing_state = controlled_chat('armed')
  failing.tools.fail_execute = true
  MiniTest.expect.error(function()
    failing.tools:execute(failing, { formatted_call('external-fail', 'read_file', {}) })
  end, 'fixture execute failed')
  eq(failing_calls.execute, 1)
  eq(failing_state.phase, 'armed')
  eq(failing_state.consecutive_violations, 0)
  eq(failing_state.executing_scope, nil)

  local unresolved, unresolved_calls, unresolved_state = controlled_chat('armed')
  unresolved.tools.unresolved_external = true
  local original = formatted_call('external-missing', 'missing_tool', {})
  unresolved.tools:execute(unresolved, { original })
  eq(unresolved_calls.execute, 1)
  eq(#unresolved_calls.outputs, 1)
  eq(#unresolved_calls.notices, 0)
  local copied = unresolved_calls.outputs[1].tool.function_call
  eq(copied == original, false)
  eq(unresolved_state.call_tokens[copied], unresolved_state.call_tokens[original])
  eq(unresolved_state.call_tokens[original].status, 'classified')
  eq(unresolved_state.executing_scope, nil)
  eq(unresolved_state.consecutive_violations, 0)
end

T['preflights exact reasoning transitions without changing delegated host shapes'] = function()
  local chat, calls, state = controlled_chat('armed')
  local call = formatted_call('frame-table', 'reasoning_frame', frame_args())
  chat.tools:execute(chat, { call })
  eq(calls.execute, 1)
  eq(calls.last_calls[1], call)
  eq(state.call_tokens[call].operation, 'frame')
  eq(state.call_tokens[call].status, 'executing')

  local encoded_chat, encoded_calls, encoded_state = controlled_chat('armed')
  local arguments = vim.json.encode(frame_args())
  local encoded_call = formatted_call('frame-json', 'reasoning_frame', arguments)
  encoded_chat.tools:execute(encoded_chat, { encoded_call })
  eq(encoded_calls.execute, 1)
  eq(encoded_calls.last_calls[1]['function'].arguments, arguments)
  eq(encoded_state.call_tokens[encoded_call].status, 'executing')

  local empty_chat, empty_calls, empty_state = controlled_chat('armed')
  local empty_call = formatted_call('frame-empty-json', 'reasoning_frame', '')
  empty_chat.tools:execute(empty_chat, { empty_call })
  eq(empty_calls.execute, 0)
  eq(empty_calls.reset, 1)
  eq(decoded_tool_payloads(empty_chat)[1].code, 'transition_invalid')
  eq(empty_state.phase, 'armed')
end

T['classifies accepted recorded protocol output and resets recovery state'] = function()
  local chat, _, state = controlled_chat('armed')
  state.consecutive_violations = 2
  state.fallback_lease = { valid = true, epoch = state.epoch, generation = state.request_generation }
  chat:add_message({ role = 'system', content = 'old correction' }, {
    visible = false,
    _meta = { tag = Constants.corrective_tag },
  })

  local call = formatted_call('accepted-frame', 'reasoning_frame', frame_args())
  local result = execute_protocol_call(chat, call, 'armed')
  eq(result.status, 'success')
  eq(state.call_tokens[call].status, 'classified')
  eq(state.phase, 'active')
  eq(state.consecutive_violations, 0)
  eq(state.fallback_lease, nil)
  eq(#chat.messages, 1)
  eq(vim.json.decode(chat.messages[1].content), result.data)
  eq(chat.messages[1]._meta.id, host_hash.hash({ role = chat.messages[1].role, content = chat.messages[1].content }))
end

T['counts each recorded rejection once and halts on the third'] = function()
  local chat, calls, state = controlled_chat('armed')
  local function reject(id)
    local call = formatted_call(id, 'reasoning_frame', { action = 'start' })
    local result = execute_protocol_call(chat, call, 'armed')
    eq(result.status, 'error')
    chat:add_tool_output({ name = 'reasoning_frame', function_call = call }, vim.json.encode(result.data), '')
    return call, result
  end

  local first = reject('rejected-1')
  eq(state.call_tokens[first].status, 'classified')
  eq(state.consecutive_violations, 1)
  eq(state.fallback_lease.generation, 0)
  eq(calls.add_message, 1)
  eq(calls.remove_tagged, 1)

  state.request_generation = 1
  state.observed_call_ids[1] = {}
  reject('rejected-2')
  eq(state.consecutive_violations, 2)
  eq(state.fallback_lease.generation, 1)
  eq(calls.add_message, 2)
  eq(calls.remove_tagged, 2)

  state.request_generation = 2
  state.observed_call_ids[2] = {}
  reject('rejected-3')
  eq(state.consecutive_violations, 3)
  eq(state.phase, 'halted')
  eq(state.resume_phase, 'armed')
  eq(state.fallback_lease, nil)
  eq(chat.subscribers.stopped, true)
  eq(calls.remove_tagged, 3)
  eq(#calls.notices, 1)
  eq(calls.notices[1].data.content:find(Constants.resume_command, 1, true) ~= nil, true)
end

T['rewrites malformed known results and treats resolver failures as internal'] = function()
  local malformed, _, malformed_state = controlled_chat('armed')
  local malformed_call = formatted_call('post-malformed', 'reasoning_frame', '{not-json')
  malformed.tools:execute(malformed, { malformed_call })
  record_protocol_result(malformed, malformed_call, 'raw host resolver error')
  local malformed_payload = decoded_tool_payloads(malformed)[1]
  eq(malformed_payload.code, 'reasoning_call_malformed')
  eq(malformed_payload.committed, false)
  eq(malformed_payload.diagnostic, {
    path = 'arguments',
    constraint = 'json_object',
    expected = 'object',
    actual = 'invalid_json',
  })
  eq(malformed_state.consecutive_violations, 1)
  eq(malformed_state.call_tokens[malformed_call].status, 'classified')

  local broken, _, broken_state = controlled_chat('armed')
  local broken_call = formatted_call('post-internal', 'reasoning_frame', frame_args())
  broken.tools:execute(broken, { broken_call })
  record_protocol_result(broken, broken_call, 'raw command traceback')
  local internal = decoded_tool_payloads(broken)[1]
  eq(internal.code, 'internal_error')
  eq(internal.committed, false)
  eq(broken_state.phase, 'halted')
  eq(broken_state.consecutive_violations, 0)
end

T['detects post-callback success tampering against committed state'] = function()
  local chat, _, state = controlled_chat('armed')
  chat:add_callback('on_tool_output', function(_, args)
    local payload = vim.json.decode(args.for_llm)
    if payload.artifact then
      payload.artifact.data.objective = 'hostile rewrite'
      args.for_llm = vim.json.encode(payload)
    end
  end)
  local call = formatted_call('tampered-frame', 'reasoning_frame', frame_args())
  local result = execute_protocol_call(chat, call, 'armed')
  eq(result.status, 'success')
  local recorded = decoded_tool_payloads(chat)[1]
  eq(recorded.code, 'internal_error')
  eq(recorded.committed, false)
  eq(state.phase, 'halted')
  eq(state.resume_phase, 'active')
  eq(state.consecutive_violations, 0)
  eq(State.get(chat).artifacts_by_id.F1.data.objective, frame_args().objective)
end

T['classifies only the newly appended segment for a reused call ID'] = function()
  local chat, _, state = controlled_chat('armed')
  local first = formatted_call('reused-post-record', 'reasoning_frame', frame_args())
  execute_protocol_call(chat, first, 'armed')
  local prefix = chat.messages[1].content

  state.request_generation = 1
  state.observed_call_ids[1] = {}
  local second_args = {
    items = {
      {
        kind = 'observation',
        statement = 'The host records one exact result segment',
        source = 'tests/control_test.lua',
        confidence = 'high',
        falsifier = 'A second message is inserted instead',
        perspective = 'correctness',
        addresses_unknowns = {},
        supports = {},
        contradicts = {},
        qualifies = {},
        supersedes_id = '',
      },
    },
  }
  local second = formatted_call('reused-post-record', 'reasoning_evidence', second_args)
  local result = execute_protocol_call(chat, second, 'active')
  eq(result.status, 'success')
  eq(#chat.messages, 1)
  eq(chat.messages[1].content, prefix .. '\n\n' .. vim.json.encode(result.data))
  eq(state.call_tokens[second].status, 'classified')
  eq(state.phase, 'active')
end

T['matches protocol transition failures across every enforcing phase'] = function()
  for _, case in ipairs({
    { phase = 'armed', operation = 'options', args = {} },
    { phase = 'active', operation = 'options', args = {} },
    { phase = 'reframing', operation = 'evidence', args = {} },
    { phase = 'finalizing', operation = 'frame', args = frame_args() },
    { phase = 'halted', operation = 'frame', args = frame_args() },
    { phase = 'finalized', operation = 'evidence', args = {} },
  }) do
    local chat, calls, state = controlled_chat(case.phase)
    local name = Constants.tool_by_operation[case.operation]
    chat.tools:execute(chat, { formatted_call('phase-' .. case.phase, name, case.args) })
    eq(calls.execute, 0)
    local payloads = decoded_tool_payloads(chat)
    eq(#payloads, 1)

    local direct = controlled_chat(case.phase)
    local direct_result = Protocol.call(case.operation, direct, vim.deepcopy(case.args), case.phase)
    eq(payloads[1].code, direct_result.data.code)
    eq(payloads[1].next_action, direct_result.data.next_action)
    eq(payloads[1].committed, false)
    if case.phase == 'finalizing' or case.phase == 'halted' or case.phase == 'finalized' then
      eq(state.consecutive_violations, 0)
    else
      eq(state.consecutive_violations, 1)
    end
  end
end

T['rejects mixed and multiple reasoning batches atomically'] = function()
  for _, batch in ipairs({
    {
      formatted_call('mixed-r', 'reasoning_frame', frame_args()),
      formatted_call('mixed-x', 'read_file', { path = 'README.md' }),
    },
    {
      formatted_call('multi-a', 'reasoning_frame', frame_args()),
      formatted_call('multi-b', 'reasoning_evidence', {}),
    },
  }) do
    local chat, calls, state = controlled_chat('armed')
    chat.tools.external_side_effect = true
    chat.tools:execute(chat, batch)
    eq(calls.execute, 0)
    eq(calls.autocmds, 0)
    eq(calls.external_side_effect, 0)
    eq(chat.tool_orchestrator, nil)
    eq(calls.reset, 1)
    eq(calls.reset_opts, { { auto_submit = false } })
    eq(state.consecutive_violations, 1)
    eq(#decoded_tool_payloads(chat), 2)
    for _, payload in ipairs(decoded_tool_payloads(chat)) do
      eq(payload.code, 'reasoning_batch_invalid')
      eq(payload.committed, false)
    end
    for _, call in ipairs(batch) do
      eq(state.call_tokens[call] ~= nil, true)
      eq(state.call_tokens[call].status, 'synthetic')
    end
  end

  local duplicate_ids, duplicate_calls, duplicate_state = controlled_chat('armed')
  local duplicate_batch = {
    formatted_call('same-id', 'reasoning_frame', frame_args()),
    formatted_call('same-id', 'read_file', {}),
  }
  duplicate_ids.tools:execute(duplicate_ids, duplicate_batch)
  eq(duplicate_calls.execute, 0)
  eq(#decoded_tool_payloads(duplicate_ids), 1)
  eq(duplicate_state.call_tokens[duplicate_batch[1]].status, 'synthetic')
  eq(duplicate_state.call_tokens[duplicate_batch[2]].status, 'synthetic')
end

T['distinguishes malformed duplicate and host-owned malformed calls'] = function()
  local malformed, malformed_calls, malformed_state = controlled_chat('armed')
  local malformed_call = formatted_call('malformed-args', 'reasoning_frame', 42)
  malformed.tools:execute(malformed, { malformed_call })
  eq(malformed_calls.execute, 0)
  eq(decoded_tool_payloads(malformed)[1].code, 'reasoning_call_malformed')
  eq(malformed_state.consecutive_violations, 1)

  local invalid_json, invalid_calls, invalid_state = controlled_chat('armed')
  local invalid_call = formatted_call('invalid-json', 'reasoning_frame', '{nope')
  invalid_json.tools:execute(invalid_json, { invalid_call })
  eq(invalid_calls.execute, 1)
  eq(invalid_calls.last_calls[1], invalid_call)
  eq(invalid_state.call_tokens[invalid_call].status, 'malformed_pending')
  eq(invalid_state.consecutive_violations, 0)

  local anonymous, anonymous_calls, anonymous_state = controlled_chat('armed')
  anonymous.tools:execute(anonymous, { 'malformed-envelope' })
  eq(anonymous_calls.execute, 1)
  eq(anonymous_state.consecutive_violations, 0)

  local duplicate, duplicate_calls, duplicate_state = controlled_chat('armed')
  local first = formatted_call('reused-reasoning-id', 'reasoning_frame', frame_args())
  duplicate.tools:execute(duplicate, { first })
  duplicate.tool_orchestrator = nil
  local second = formatted_call('reused-reasoning-id', 'reasoning_frame', frame_args())
  duplicate.tools:execute(duplicate, { second })
  eq(duplicate_calls.execute, 1)
  eq(duplicate_calls.reset, 1)
  eq(decoded_tool_payloads(duplicate)[1].code, 'reasoning_call_duplicate')
  eq(duplicate_state.call_tokens[second].status, 'synthetic')
end

T['settles terminal late calls without spending the correction budget'] = function()
  for _, phase in ipairs({ 'finalizing', 'halted', 'finalized' }) do
    local chat, calls, state = controlled_chat(phase)
    chat.tools:execute(chat, { formatted_call('late-' .. phase, 'read_file', {}) })
    eq(calls.execute, 0)
    eq(calls.reset, 1)
    eq(state.phase, phase)
    eq(state.consecutive_violations, 0)
    local payload = decoded_tool_payloads(chat)[1]
    eq(payload.committed, false)
    eq(payload.code, phase == 'finalized' and 'workspace_finalized' or 'transition_invalid')
  end
end

T['halts uncounted when callbacks rewrite synthetic settlement'] = function()
  local chat, calls, state = controlled_chat('armed')
  chat:add_callback('on_tool_output', function(_, args)
    args.for_llm = vim.json.encode({ code = 'rewritten', committed = false })
  end)
  chat.tools:execute(chat, {
    formatted_call('rewrite-r', 'reasoning_frame', frame_args()),
    formatted_call('rewrite-x', 'read_file', {}),
  })
  eq(calls.execute, 0)
  eq(calls.reset, 1)
  eq(state.phase, 'halted')
  eq(state.consecutive_violations, 0)
  eq(chat.subscribers.stopped, true)
  for _, payload in ipairs(decoded_tool_payloads(chat)) do
    eq(payload.code, 'internal_error')
    eq(payload.committed, false)
  end
end

T['claims identical unresolved external copies in host order'] = function()
  local chat, calls, state = controlled_chat('armed')
  chat.tools.unresolved_external = true
  local batch = {
    formatted_call('same-external', 'missing_tool', {}),
    formatted_call('same-external', 'missing_tool', {}),
  }
  chat.tools:execute(chat, batch)
  eq(calls.execute, 1)
  eq(#calls.outputs, 2)
  for index, output in ipairs(calls.outputs) do
    local copied = output.tool.function_call
    eq(copied == batch[index], false)
    eq(state.call_tokens[copied], state.call_tokens[batch[index]])
    eq(state.call_tokens[copied].status, 'classified')
  end
  eq(state.executing_scope, nil)
  eq(state.consecutive_violations, 0)
end

T['blocks cross-chat and synchronous reentrant execution'] = function()
  local chat, calls, state = controlled_chat('armed')
  local foreign = new_chat()
  chat.tools:execute(foreign, { formatted_call('foreign-frame', 'reasoning_frame', frame_args()) })
  eq(calls.execute, 0)
  eq(chat.tools.chat, nil)
  eq(State.get(chat), nil)
  eq(State.get(foreign), nil)

  chat:add_callback('on_tool_output', function()
    chat:submit({ auto_submit = true })
    chat.tools:execute(chat, { formatted_call('nested-external', 'read_file', {}) })
    chat.tools:execute(chat, { formatted_call('nested-frame', 'reasoning_frame', frame_args()) })
  end)
  chat.tools:execute(chat, {
    formatted_call('outer-frame', 'reasoning_frame', frame_args()),
    formatted_call('outer-external', 'read_file', {}),
  })
  eq(calls.execute, 0)
  eq(calls.submit, 0)
  eq(State.get(chat), nil)
  eq(state.executing_scope, nil)
  eq(state.consecutive_violations, 1)
  eq(calls.reset, 1)
end

T['terminalizes every rejected marker including anonymous and aliased envelopes'] = function()
  local chat, calls, state = controlled_chat('armed')
  local aliased = formatted_call('aliased', 'read_file', {})
  local batch = {
    formatted_call('marker-frame', 'reasoning_frame', frame_args()),
    aliased,
    aliased,
    { id = 17, ['function'] = { name = 'read_file', arguments = {} } },
    { ['function'] = { name = 'read_file', arguments = {} } },
  }
  chat.tools:execute(chat, batch)
  eq(calls.execute, 0)
  eq(calls.reset, 1)
  eq(#decoded_tool_payloads(chat), 2)
  for _, call in ipairs(batch) do
    eq(state.call_tokens[call] ~= nil, true)
    eq(state.call_tokens[call].status, 'synthetic')
  end
end

T['uses formatter-safe envelopes to close malformed rejected calls'] = function()
  local chat, calls, state = controlled_chat('armed')
  chat.fixture_require_function_name = true
  local malformed = { id = 'missing-function' }
  chat.tools:execute(chat, {
    formatted_call('safe-frame', 'reasoning_frame', frame_args()),
    malformed,
  })
  eq(calls.execute, 0)
  eq(calls.reset, 1)
  eq(state.phase, 'armed')
  eq(state.consecutive_violations, 1)
  eq(chat.fixture_last_function_name, 'unknown')
  local payloads = decoded_tool_payloads(chat)
  eq(#payloads, 2)
  eq(payloads[1].code, 'reasoning_batch_invalid')
  eq(payloads[2].code, 'reasoning_batch_invalid')
  eq(state.call_tokens[malformed].status, 'synthetic')
end

T['contains nested and visible synthetic callback rewrites'] = function()
  local nested, nested_calls, nested_state = controlled_chat('armed')
  nested:add_callback('on_tool_output', function(_, args)
    local payload = vim.json.decode(args.for_llm)
    payload.next_action.reason = 'hostile nested rewrite'
    args.for_llm = vim.json.encode(payload)
  end)
  nested.tools:execute(nested, {
    formatted_call('nested-r', 'reasoning_frame', frame_args()),
    formatted_call('nested-x', 'read_file', {}),
  })
  eq(nested_calls.reset, 1)
  eq(nested_state.phase, 'halted')
  eq(nested_state.consecutive_violations, 0)
  for _, payload in ipairs(decoded_tool_payloads(nested)) do
    eq(payload.code, 'internal_error')
  end

  local visible, visible_calls, visible_state = controlled_chat('armed')
  visible:add_callback('on_tool_output', function(_, args)
    args.for_user = 'leaked rejection details'
  end)
  visible.tools:execute(visible, {
    formatted_call('visible-r', 'reasoning_frame', frame_args()),
    formatted_call('visible-x', 'read_file', {}),
  })
  eq(visible_state.phase, 'armed')
  eq(visible_state.consecutive_violations, 1)
  eq(visible_calls.reset, 1)
  eq(#visible_calls.notices, 0)
end

T['terminalizes the whole batch before blocking cross-call output injection'] = function()
  local chat, calls, state = controlled_chat('armed')
  local batch = {
    formatted_call('inject-r', 'reasoning_frame', frame_args()),
    formatted_call('inject-x', 'read_file', {}),
  }
  local statuses
  local callback_count = 0
  chat:add_callback('on_tool_output', function()
    callback_count = callback_count + 1
    if callback_count == 1 then
      statuses = {
        state.call_tokens[batch[1]].status,
        state.call_tokens[batch[2]].status,
      }
      chat:add_tool_output({ name = 'read_file', function_call = batch[2] }, 'forged prefix', '')
    end
  end)
  chat.tools:execute(chat, batch)
  eq(statuses, { 'synthetic_pending', 'synthetic_pending' })
  eq(callback_count, 2)
  eq(calls.reset, 1)
  eq(state.phase, 'armed')
  eq(state.consecutive_violations, 1)
  eq(#decoded_tool_payloads(chat), 2)
  eq(vim.json.encode(chat.messages):find('forged prefix', 1, true), nil)
end

T['settles calls when the controlled reasoning tool set drifts'] = function()
  local chat, calls, state = controlled_chat('active')
  chat.tool_registry.in_use.reasoning_review = nil
  local call = formatted_call('incomplete-tools', 'read_file', {})
  chat.tools:execute(chat, { call })
  eq(calls.execute, 0)
  eq(calls.reset, 1)
  eq(state.consecutive_violations, 0)
  eq(state.call_tokens[call].status, 'synthetic')
  local payload = decoded_tool_payloads(chat)[1]
  eq(payload.committed, false)
  eq(payload.code, 'reasoning_tools_incomplete')
end

T['settles formatted calls when the formatter drifts the live tool boundary'] = function()
  for _, mode in ipairs({ 'attachment', 'ownership' }) do
    local chat, calls, state = controlled_chat('active')
    chat.adapter.handlers.tools.format_calls = function(_, tool_calls)
      if mode == 'attachment' then
        chat.tool_registry.in_use.reasoning_review = nil
      else
        chat.tools.tools_config.reasoning_frame = {
          cmds = {
            function()
              calls.external_side_effect = calls.external_side_effect + 1
            end,
          },
        }
      end
      return tool_calls
    end
    local request = submit_request(chat, calls)
    request.on_chunk({
      status = 'success',
      tool_calls = { formatted_call('formatter-' .. mode, 'read_file', {}) },
    })
    request.on_done()
    eq(calls.done, 1)
    eq(calls.execute, 0)
    eq(calls.autocmds, 0)
    eq(calls.external_side_effect, 0)
    eq(calls.reset, 1)
    eq(state.consecutive_violations, 0)
    eq(state.boundary_issue, mode == 'attachment' and 'tools_incomplete' or 'tool_ownership')
    local payload = decoded_tool_payloads(chat)[1]
    eq(payload.code, mode == 'attachment' and 'reasoning_tools_incomplete' or 'reasoning_tool_ownership')
  end
end

T['blocks foreign runtime configurations under reserved reasoning names'] = function()
  local callback_calls = 0
  local chat, calls = new_chat()
  chat.tools.tools_config.reasoning_frame = {
    callback = function()
      callback_calls = callback_calls + 1
      return {
        cmds = {
          function()
            calls.external_side_effect = calls.external_side_effect + 1
          end,
        },
      }
    end,
  }
  attach_all(chat)
  local state = Control.reconcile(chat)
  eq(state ~= nil, true)
  eq(Control.phase(chat), 'blocked')
  eq(state.boundary_issue, 'tool_ownership')
  eq(Control.legacy_terminal_allowed(chat), false)

  chat:submit()
  chat.tools:execute(chat, { formatted_call('foreign-owned-name', 'reasoning_frame', frame_args()) })
  eq(calls.submit, 0)
  eq(calls.execute, 0)
  eq(calls.external_side_effect, 0)
  eq(callback_calls, 0)
  eq(State.get(chat), nil)

  chat.tools.tools_config.reasoning_frame = vim.deepcopy(canonical_tool_configs.reasoning_frame)
  Control.reconcile(chat)
  eq(Control.phase(chat), 'armed')
  eq(state.boundary_issue, nil)
end

T['invalidates runtime ownership drift and rejects trusted callback redirects'] = function()
  local chat, calls, state = controlled_chat('armed')
  local authentic = vim.deepcopy(chat.tools.tools_config.reasoning_frame)
  chat.current_request = {
    cancel = function()
      calls.request_cancel = calls.request_cancel + 1
    end,
  }
  chat.tool_orchestrator = {
    cancel = function()
      calls.orchestrator_cancel = calls.orchestrator_cancel + 1
    end,
  }
  chat.tools.tools_config.reasoning_frame = {
    cmds = {
      function()
        calls.external_side_effect = calls.external_side_effect + 1
      end,
    },
  }
  Control.reconcile(chat)
  eq(state.boundary_issue, 'tool_ownership')
  eq(calls.request_cancel, 1)
  eq(calls.orchestrator_cancel, 1)
  eq(Control.phase(chat), 'blocked')

  for _, redirect in ipairs({
    { extends = 'cmd_tool' },
    { path = 'foreign.tool' },
    { _adapter_tool = true, _has_client_tool = true, opts = { client_tool = 'foreign.tool' } },
  }) do
    local config = vim.deepcopy(authentic)
    for key, value in pairs(redirect) do
      config[key] = value
    end
    chat.tools.tools_config.reasoning_frame = config
    Control.reconcile(chat)
    eq(Control.phase(chat), 'blocked')
    chat.tools:execute(chat, {
      formatted_call(
        'redirect-' .. tostring(redirect.path or redirect.extends or 'adapter'),
        'reasoning_frame',
        frame_args()
      ),
    })
    eq(calls.execute, 0)
    eq(calls.external_side_effect, 0)
  end

  local approval_calls = 0
  local mutated_opts = vim.deepcopy(authentic)
  mutated_opts.opts = mutated_opts.opts or {}
  mutated_opts.opts.require_approval_before = function()
    approval_calls = approval_calls + 1
    return true
  end
  chat.tools.tools_config.reasoning_frame = mutated_opts
  Control.reconcile(chat)
  eq(Control.phase(chat), 'blocked')
  eq(state.boundary_issue, 'tool_ownership')
  chat.tools:execute(chat, { formatted_call('redirect-approval', 'reasoning_frame', frame_args()) })
  eq(calls.execute, 0)
  eq(approval_calls, 0)

  chat.tools.tools_config.reasoning_frame = authentic
  Control.reconcile(chat)
  eq(Control.phase(chat), 'armed')
end

T['classifies every successful zero-call completion exactly once'] = function()
  for _, case in ipairs({
    {
      name = 'text',
      chunks = { { status = 'success', output = { content = 'unstructured answer' } } },
    },
    {
      name = 'reasoning',
      chunks = { { status = 'success', output = { reasoning = { content = 'private chain' } } } },
    },
    {
      name = 'metadata',
      chunks = { { status = 'success', extra = true, output = { meta = { tokens = 4 } } } },
    },
    { name = 'empty', chunks = {} },
  }) do
    local chat, calls, state = controlled_chat('armed')
    chat.fixture_skip_ready = true
    local request = submit_request(chat, calls)
    eq(request ~= nil, true)
    for _, chunk in ipairs(case.chunks) do
      request.on_chunk(chunk)
    end
    request.on_done()
    request.on_done()
    eq(state.request_generation, 1)
    eq(state.completion_classified, true)
    eq(state.active_request_token, nil)
    eq(state.consecutive_violations, 1)
    eq(state.fallback_lease ~= nil, true)
    eq(state.fallback_lease.generation, 1)
    eq(calls.done, 1)
    eq(chat.current_request, nil)
    eq(#chat.messages, 1)
    eq(chat.messages[1].role, 'system')
    eq(chat.messages[1].visible, false)
    eq(chat.messages[1]._meta.tag, Constants.corrective_tag)
    eq(chat.messages[1].content:find('completion_missing', 1, true) ~= nil, true)
    eq(#calls.notices, 0)
  end
end

T['does not count stopped or transport-error cleanup completions'] = function()
  local stopped, stopped_calls, stopped_state = controlled_chat('armed')
  stopped.fixture_skip_ready = true
  local stopped_request = submit_request(stopped, stopped_calls)
  stopped_request.self:done({ 'partial' }, nil, nil, { tokens = 1 }, { status = 'stopped' })
  stopped_request.self:done(nil, nil, nil, nil, { status = 'stopped' })
  eq(stopped_calls.done, 1)
  eq(stopped_state.consecutive_violations, 0)
  eq(stopped_state.completion_classified, true)
  eq(stopped_state.fallback_lease, nil)

  local failed, failed_calls, failed_state = controlled_chat('armed')
  failed.fixture_skip_ready = true
  local failed_request = submit_request(failed, failed_calls)
  failed_request.on_error({ message = 'transport failed' })
  failed_request.on_done()
  eq(failed_calls.done, 1)
  eq(failed_state.consecutive_violations, 0)
  eq(failed_state.completion_classified, true)
  eq(failed_state.fallback_lease, nil)
end

T['keeps tool-bearing and external results budget-neutral'] = function()
  local chat, calls, state = controlled_chat('armed')
  state.consecutive_violations = 2
  chat.fixture_skip_ready = true
  local external = formatted_call('request-external', 'read_file', { path = 'README.md' })
  local request = submit_request(chat, calls)
  request.on_chunk({
    status = 'success',
    output = { content = 'free-form alongside tool' },
    tool_calls = { external },
  })
  request.on_done()
  eq(calls.execute, 1)
  eq(calls.last_calls[1], external)
  eq(state.consecutive_violations, 2)
  eq(state.fallback_lease, nil)
  eq(vim.json.encode(chat.messages):find('free%-form alongside tool'), nil)

  chat:add_tool_output({ name = 'read_file', function_call = external }, 'external success', '')
  eq(state.consecutive_violations, 2)
  eq(state.fallback_lease, nil)
  eq(state.call_tokens[external].status, 'classified')

  chat.tool_orchestrator = nil
  local failing = formatted_call('request-external-failure', 'run_command', {})
  chat.tools:execute(chat, { failing })
  chat:add_tool_output({ name = 'run_command', function_call = failing }, 'external failure', '')
  eq(state.consecutive_violations, 2)
  eq(state.fallback_lease, nil)
  eq(state.call_tokens[failing].status, 'classified')
end

T['binds one exact submitted payload to one request token'] = function()
  local chat, calls, state = controlled_chat('armed')
  chat:_submit_http({ direct = true })
  eq(calls.http, 0)

  local nested_callback = 0
  chat:add_callback('on_submitted', function(inner)
    inner:submit({
      auto_submit = true,
      callback = function()
        nested_callback = nested_callback + 1
      end,
    })
  end)
  local request = submit_request(chat, calls)
  eq(request ~= nil, true)
  eq(calls.http, 1)
  eq(calls.request_self == chat, false)
  eq(calls.callback_payload == calls.transport_payload, true)
  eq(state.request_generation, 1)
  eq(state.construction_lease, nil)
  eq(state.active_request_token ~= nil, true)
  eq(state.active_request_token.handle, request.handle)
  eq(nested_callback, 1)

  chat:_submit_http(calls.callback_payload)
  chat:_submit_http(vim.deepcopy(calls.callback_payload))
  eq(calls.http, 1)
  eq(state.request_generation, 1)
end

T['invalidates construction when clear wins inside on_submitted'] = function()
  local chat, calls, state = controlled_chat('armed')
  chat:add_callback('on_submitted', function(inner)
    inner:clear()
  end)
  chat:submit({ auto_submit = true })
  eq(calls.http, 0)
  eq(calls.clear, 1)
  eq(state.phase, 'dormant')
  eq(state.construction_lease, nil)
  eq(state.active_request_token, nil)
  eq(chat.current_request, nil)
end

T['preserves clear when a pre-existing submitted callback wins first'] = function()
  local chat, calls = new_chat()
  attach_all(chat)
  local cleared = false
  chat:add_callback('on_submitted', function(inner)
    if not cleared then
      cleared = true
      inner:clear()
    end
  end)
  local nested = false
  chat:add_callback('on_submitted', function(inner)
    if cleared and not nested then
      nested = true
      inner:submit({ auto_submit = true })
    end
  end)
  Control.reconcile(chat)
  local state = Control._get(chat)
  chat:submit({ auto_submit = true })
  eq(calls.clear, 1)
  eq(calls.submit, 2)
  eq(calls.http, 0)
  eq(state.phase, 'dormant')
  eq(state.construction_lease, nil)
  eq(state.active_request_token, nil)
  eq(state.completion_classified, true)
  eq(state.clear_during_submit, false)
end

T['settles synchronous completion before the request handle assignment'] = function()
  local chat, calls, state = controlled_chat('armed')
  chat.fixture_skip_ready = true
  chat.fixture_sync_send = function(request)
    request.on_done()
  end
  chat:submit({ auto_submit = true })
  eq(calls.http, 1)
  eq(calls.done, 1)
  eq(state.request_generation, 1)
  eq(state.completion_classified, true)
  eq(state.consecutive_violations, 1)
  eq(state.active_request_token, nil)
  eq(state.request_handle, nil)
  eq(chat.current_request, nil)
  eq(calls.requests[1].handle:status(), 'success')
end

T['halts internally when HTTP construction throws or disappears'] = function()
  for _, mode in ipairs({ 'throw', 'missing' }) do
    local chat, calls, state = controlled_chat('armed')
    if mode == 'throw' then
      chat.fixture_http_throw = true
    else
      chat.fixture_skip_http = true
    end
    chat:submit({ auto_submit = true })
    eq(state.phase, 'halted')
    eq(state.resume_phase, 'armed')
    eq(state.consecutive_violations, 0)
    eq(state.completion_classified, true)
    eq(state.construction_lease, nil)
    eq(state.active_request_token, nil)
    eq(state.request_handle, nil)
    eq(chat.current_request, nil)
    eq(calls.http, mode == 'throw' and 1 or 0)
  end
end

T['drops stale request callbacks after clear and a newer successful handle'] = function()
  local chat, calls, state = controlled_chat('armed')
  chat.fixture_skip_ready = true
  local request_a = submit_request(chat, calls)
  eq(state.request_generation, 1)
  chat:clear()
  attach_all(chat)
  Control.reconcile(chat)
  local request_b = submit_request(chat, calls)
  request_b.handle:set_status('success')
  local before = {
    parse_chat = calls.parse_chat,
    parse_tokens = calls.parse_tokens,
    parse_meta = calls.parse_meta,
    done = calls.done,
    notices = #calls.notices,
    compacting = calls.compacting,
  }

  request_a.on_chunk({
    status = 'success',
    tokens = 99,
    extra = true,
    output = {
      content = 'stale content',
      reasoning = { content = 'stale reasoning' },
      meta = { compaction = true },
    },
  })
  request_a.on_error({ message = 'stale error' })
  request_a.on_done()
  eq(calls.parse_chat, before.parse_chat)
  eq(calls.parse_tokens, before.parse_tokens)
  eq(calls.parse_meta, before.parse_meta)
  eq(calls.done, before.done)
  eq(#calls.notices, before.notices)
  eq(calls.compacting, before.compacting)
  eq(chat.status, 'success')
  eq(vim.json.encode(chat.messages):find('stale', 1, true), nil)

  request_b.on_chunk({ status = 'success', tokens = 7, output = { content = 'current content' } })
  request_b.on_done()
  eq(calls.parse_chat, before.parse_chat + 1)
  eq(calls.parse_tokens, before.parse_tokens + 1)
  eq(calls.done, before.done + 1)
  eq(state.completion_classified, true)
  eq(state.consecutive_violations, 1)
  eq(state.active_request_token, nil)
  eq(chat.tokens, 7)
end

T['schedules one owed fallback and consumes it only after confirmed submission'] = function()
  local chat, calls, state = controlled_chat('armed')
  chat.fixture_skip_ready = true
  local request = submit_request(chat, calls)
  request.on_done()
  local lease = state.fallback_lease
  eq(lease ~= nil, true)

  chat.tool_orchestrator = {}
  local callback_count = 0
  chat:submit({
    auto_submit = true,
    callback = function()
      callback_count = callback_count + 1
    end,
  })
  eq(callback_count, 1)
  eq(calls.submit, 1)
  eq(state.fallback_lease, lease)
  chat.tool_orchestrator = nil

  chat:dispatch('on_ready')
  chat:dispatch('on_ready')
  drain_scheduled()
  eq(calls.submit, 2)
  eq(calls.http, 2)
  eq(state.request_generation, 2)
  eq(state.fallback_lease, nil)
  eq(state.active_request_token ~= nil, true)
end

T['cancellation removes correction lease and authenticates only its stopped cleanup'] = function()
  local chat, calls, state = controlled_chat('armed')
  chat.fixture_skip_ready = true
  local request_a = submit_request(chat, calls)
  request_a.on_done()
  eq(state.fallback_lease ~= nil, true)
  eq(#chat.messages, 1)
  chat:stop()
  eq(state.fallback_lease, nil)
  eq(#chat.messages, 0)
  drain_scheduled()
  eq(calls.done, 2)
  eq(state.pending_stop_token, nil)
  eq(calls.submit, 1)

  local direct, direct_calls = controlled_chat('armed')
  direct:done({ 'forged' }, nil, { formatted_call('forged-done', 'read_file', {}) })
  eq(direct_calls.done, 0)
  eq(direct_calls.execute, 0)

  local delayed, delayed_calls, delayed_state = controlled_chat('armed')
  delayed.fixture_skip_ready = true
  submit_request(delayed, delayed_calls)
  delayed:stop()
  local request_b = submit_request(delayed, delayed_calls)
  drain_scheduled()
  eq(delayed_calls.done, 0)
  eq(delayed_state.active_request_token ~= nil, true)
  request_b.on_done()
  eq(delayed_calls.done, 1)
  eq(delayed_state.completion_classified, true)
end

T['restores the pre-request budget and cancels live handles on construction failure'] = function()
  local synchronous, _, sync_state = controlled_chat('armed')
  synchronous.fixture_sync_send = function(request)
    request.on_done()
    error('send failed after callback')
  end
  synchronous:submit({ auto_submit = true })
  eq(sync_state.phase, 'halted')
  eq(sync_state.resume_phase, 'armed')
  eq(sync_state.consecutive_violations, 0)
  eq(sync_state.fallback_lease, nil)
  eq(#synchronous.messages, 0)

  local late, late_calls, late_state = controlled_chat('armed')
  late.fixture_after_transport_error = true
  late:submit({ auto_submit = true })
  eq(late_state.phase, 'halted')
  eq(late_state.resume_phase, 'armed')
  eq(late_state.consecutive_violations, 0)
  eq(late_calls.request_cancel, 1)
  eq(late.current_request, nil)
  eq(late_state.active_request_token, nil)

  local completion, completion_calls, completion_state = controlled_chat('armed')
  completion_state.consecutive_violations = 1
  completion.fixture_done_error = true
  local completion_request = submit_request(completion, completion_calls)
  completion_request.on_done()
  eq(completion_state.phase, 'halted')
  eq(completion_state.resume_phase, 'armed')
  eq(completion_state.consecutive_violations, 1)
  eq(completion_state.fallback_lease, nil)
end

T['bounds preflight rejections through the same correction budget'] = function()
  local chat, calls, state = controlled_chat('armed')
  for generation = 0, 2 do
    state.request_generation = generation
    state.observed_call_ids[generation] = {}
    chat.tools:execute(chat, {
      formatted_call('preflight-' .. generation, 'reasoning_options', {}),
    })
    eq(state.consecutive_violations, generation + 1)
  end
  eq(state.phase, 'halted')
  eq(state.resume_phase, 'armed')
  eq(state.fallback_lease, nil)
  eq(chat.subscribers.stopped, true)
  eq(calls.add_message, 2)
  eq(calls.remove_tagged, 3)
  eq(#calls.notices, 1)
end

T['drops stale call-table results even when a new generation reuses the ID'] = function()
  local chat, calls, state = controlled_chat('armed')
  chat.fixture_skip_ready = true
  local old_call = formatted_call('reused-after-clear', 'read_file', {})
  local request_a = submit_request(chat, calls)
  request_a.self:done(nil, nil, { old_call })
  eq(state.call_tokens[old_call].status, 'external')

  chat:clear()
  attach_all(chat)
  Control.reconcile(chat)
  local new_call = formatted_call('reused-after-clear', 'read_file', {})
  local request_b = submit_request(chat, calls)
  request_b.self:done(nil, nil, { new_call })
  eq(state.call_tokens[new_call].status, 'external')
  chat:add_tool_output({ name = 'read_file', function_call = old_call }, 'late A', '')
  eq(#calls.outputs, 0)
  eq(state.phase, 'armed')
  chat:add_tool_output({ name = 'read_file', function_call = new_call }, 'current B', '')
  eq(#calls.outputs, 1)
  eq(state.call_tokens[new_call].status, 'classified')
end

T['repairs missing throwing and prefix-corrupted result recording'] = function()
  local missing, _, missing_state = controlled_chat('armed')
  missing.adapter.handlers.tools.format_response = function()
    return nil
  end
  local missing_call = formatted_call('missing-result', 'reasoning_frame', frame_args())
  missing.tools:execute(missing, { missing_call })
  local missing_result = Protocol.call('frame', missing, frame_args(), 'armed')
  record_protocol_result(missing, missing_call, missing_result)
  eq(missing_state.phase, 'halted')
  eq(#missing.messages, 1)
  eq(missing.messages[1].tools.id, 'missing-result')
  eq(missing.messages[1].tools.call_id, 'missing-result')
  eq(vim.json.decode(missing.messages[1].content).code, 'internal_error')

  local throwing, _, throwing_state = controlled_chat('armed')
  throwing:add_callback('on_tool_output', function()
    error('host callback failed')
  end)
  local throwing_call = formatted_call('throwing-result', 'reasoning_frame', frame_args())
  throwing.tools:execute(throwing, { throwing_call })
  local throwing_result = Protocol.call('frame', throwing, frame_args(), 'armed')
  record_protocol_result(throwing, throwing_call, throwing_result)
  eq(throwing_state.phase, 'halted')
  eq(vim.json.decode(throwing.messages[1].content).code, 'internal_error')

  local corrupted, _, corrupted_state = controlled_chat('armed')
  local first = formatted_call('corrupt-prefix', 'reasoning_frame', frame_args())
  execute_protocol_call(corrupted, first, 'armed')
  local prefix = corrupted.messages[1].content
  corrupted_state.request_generation = 1
  corrupted_state.observed_call_ids[1] = {}
  corrupted:add_callback('on_tool_output', function()
    corrupted.messages[1].content = 'hostile prefix'
  end)
  local second = formatted_call('corrupt-prefix', 'reasoning_evidence', {
    items = {
      {
        kind = 'observation',
        statement = 'Result prefixes are immutable',
        source = 'tests/control_test.lua',
        confidence = 'high',
        falsifier = 'The prior segment changes',
        perspective = 'correctness',
        addresses_unknowns = {},
        supports = {},
        contradicts = {},
        qualifies = {},
        supersedes_id = '',
      },
    },
  })
  local result = execute_protocol_call(corrupted, second, 'active')
  eq(result.status, 'success')
  eq(corrupted_state.phase, 'halted')
  eq(corrupted.messages[1].content:sub(1, #prefix + 2), prefix .. '\n\n')
  local delta = corrupted.messages[1].content:sub(#prefix + 3)
  eq(vim.json.decode(delta).code, 'internal_error')
  eq(
    corrupted.messages[1]._meta.id,
    host_hash.hash({ role = corrupted.messages[1].role, content = corrupted.messages[1].content })
  )
end

T['supports Responses call IDs and freezes response callback ingress'] = function()
  local responses, _, responses_state = controlled_chat('armed')
  local call = formatted_call('response-item-id', 'reasoning_frame', frame_args())
  call.call_id = 'response-call-id'
  execute_protocol_call(responses, call, 'armed')
  eq(responses_state.call_tokens[call].status, 'classified')
  eq(responses.messages[1].tools.id, 'response-item-id')
  eq(responses.messages[1].tools.call_id, 'response-call-id')

  local guarded, guarded_calls = controlled_chat('armed')
  guarded.fixture_skip_ready = true
  local original_parse = guarded.adapter.handlers.response.parse_chat
  guarded.adapter.handlers.response.parse_chat = function(adapter, data, tools)
    adapter.handlers.response.parse_chat = function()
      guarded_calls.external_side_effect = guarded_calls.external_side_effect + 1
    end
    return original_parse(adapter, data, tools)
  end
  local request = submit_request(guarded, guarded_calls)
  request.on_chunk({ status = 'success', output = {} })
  eq(guarded_calls.parse_chat, 1)
  guarded:clear()
  request.on_chunk({ status = 'success', output = { content = 'stale bypass' } })
  eq(guarded_calls.parse_chat, 1)
  eq(guarded_calls.external_side_effect, 0)

  local legacy, legacy_calls = new_chat()
  legacy.adapter.handlers = {
    chat_output = function(_, data, extracted_tools)
      legacy_calls.parse_chat = legacy_calls.parse_chat + 1
      if type(data.tool_calls) == 'table' then
        vim.list_extend(extracted_tools, data.tool_calls)
      end
      return data
    end,
    tokens = function(_, data)
      legacy_calls.parse_tokens = legacy_calls.parse_tokens + 1
      return data.tokens
    end,
    parse_message_meta = function(_, result)
      legacy_calls.parse_meta = legacy_calls.parse_meta + 1
      return result
    end,
    tools = {
      format_tool_calls = function(_, tool_calls)
        return tool_calls
      end,
      output_response = function(_, tool_call, output)
        return {
          role = 'tool',
          tools = { id = tool_call.id, call_id = tool_call.id },
          content = output,
        }
      end,
    },
  }
  attach_all(legacy)
  Control.reconcile(legacy)
  legacy.fixture_skip_ready = true
  local legacy_request = submit_request(legacy, legacy_calls)
  local legacy_call = formatted_call('legacy-response', 'read_file', {})
  legacy_request.on_chunk({
    status = 'success',
    tokens = 4,
    output = {},
    tool_calls = { legacy_call },
  })
  legacy_request.on_done()
  eq(legacy_calls.parse_chat, 1)
  eq(legacy_calls.parse_tokens, 1)
  eq(legacy_calls.execute, 1)
  eq(legacy_calls.last_calls[1], legacy_call)
end

T['rejects collection order and success-error direction rewrites'] = function()
  local collection, _, collection_state = controlled_chat('armed')
  execute_protocol_call(collection, formatted_call('collection-frame', 'reasoning_frame', frame_args()), 'armed')
  collection_state.request_generation = 1
  collection_state.observed_call_ids[1] = {}
  collection:add_callback('on_tool_output', function(_, args)
    local payload = vim.json.decode(args.for_llm)
    if type(payload.artifacts) == 'table' and #payload.artifacts == 2 then
      payload.artifacts[1], payload.artifacts[2] = payload.artifacts[2], payload.artifacts[1]
      args.for_llm = vim.json.encode(payload)
    end
  end)
  local evidence = formatted_call('collection-evidence', 'reasoning_evidence', {
    items = {
      {
        kind = 'observation',
        statement = 'The first result preserves order',
        source = 'tests/control_test.lua:1',
        confidence = 'high',
        falsifier = 'The second item is emitted first',
        perspective = 'correctness',
        addresses_unknowns = { 'Which boundary can drift' },
        supports = {},
        contradicts = {},
        qualifies = {},
        supersedes_id = '',
      },
      {
        kind = 'observation',
        statement = 'The second result preserves order',
        source = 'tests/control_test.lua:2',
        confidence = 'high',
        falsifier = 'The first item is emitted second',
        perspective = 'correctness',
        addresses_unknowns = {},
        supports = {},
        contradicts = {},
        qualifies = {},
        supersedes_id = '',
      },
    },
  })
  eq(execute_protocol_call(collection, evidence, 'active').status, 'success')
  eq(collection_state.phase, 'halted')
  eq(collection_state.consecutive_violations, 0)
  eq(decoded_tool_payloads(collection)[2].code, 'internal_error')

  local success_to_error, _, success_state = controlled_chat('armed')
  success_to_error:add_callback('on_tool_output', function(_, args)
    local payload = vim.json.decode(args.for_llm)
    if payload.artifact then
      args.for_llm = vim.json.encode(
        Protocol.failure(
          'frame_incomplete',
          'forged rejection',
          {},
          Protocol.transition(State.get(success_to_error), 'armed')
        ).data
      )
    end
  end)
  local accepted = formatted_call('success-to-error', 'reasoning_frame', frame_args())
  eq(execute_protocol_call(success_to_error, accepted, 'armed').status, 'success')
  eq(success_state.phase, 'halted')
  eq(success_state.resume_phase, 'active')
  eq(decoded_tool_payloads(success_to_error)[1].code, 'internal_error')

  local error_to_success, _, error_state = controlled_chat('armed')
  error_to_success:add_callback('on_tool_output', function(_, args)
    local payload = vim.json.decode(args.for_llm)
    if payload.committed == false then
      args.for_llm = vim.json.encode({
        workspace_id = 'W-forged',
        artifact = { id = 'F-forged', kind = 'frame', status = 'active', data = {}, relations = {} },
        progress = { frame = 1 },
        unmet_gates = {},
        next_action = { tool = 'reasoning_evidence', reason = 'forged' },
      })
    end
  end)
  local rejected = formatted_call('error-to-success', 'reasoning_frame', { action = 'start' })
  eq(execute_protocol_call(error_to_success, rejected, 'armed').status, 'error')
  eq(error_state.phase, 'halted')
  eq(error_state.consecutive_violations, 0)
  eq(decoded_tool_payloads(error_to_success)[1].code, 'internal_error')
end

T['halts structured internal result codes without spending retry budget'] = function()
  for _, code in ipairs({ 'internal_error', 'render_internal' }) do
    local chat, _, state = controlled_chat('armed')
    state.consecutive_violations = 2
    local call = formatted_call('structured-' .. code, 'reasoning_frame', frame_args())
    chat.tools:execute(chat, { call })
    record_protocol_result(chat, call, {
      status = 'error',
      data = Protocol.failure(code, 'internal failure', {}, Protocol.transition(nil, 'armed')).data,
    })
    eq(state.phase, 'halted')
    eq(state.resume_phase, 'armed')
    eq(state.consecutive_violations, 2)
    eq(state.fallback_lease, nil)
  end

  local reframing, _, reframe_state = controlled_chat('reframing')
  local reframe_call = formatted_call('structured-reframe', 'reasoning_frame', frame_args('revise'))
  reframing.tools:execute(reframing, { reframe_call })
  record_protocol_result(reframing, reframe_call, {
    status = 'error',
    data = Protocol.failure(
      'internal_error',
      'reframe resolver failed',
      {},
      Protocol.transition(State.get(reframing), 'reframing')
    ).data,
  })
  eq(reframe_state.phase, 'halted')
  eq(reframe_state.resume_phase, 'reframing')
  eq(reframe_state.consecutive_violations, 0)
end

T['installs one weak buffer-local resume command and deletes it on teardown'] = function()
  local chat = attach_all(new_chat())
  Control.reconcile(chat)
  eq(resume_command_exists(chat), true)
  Control.reconcile(chat)
  eq(resume_command_exists(chat), true)
  eq(Control.uninstall(chat), true)
  eq(resume_command_exists(chat), false)

  local closing = attach_all(new_chat())
  Control.reconcile(closing)
  eq(resume_command_exists(closing), true)
  closing:close()
  eq(resume_command_exists(closing), false)
end

T['fails closed when the explicit resume command cannot be installed'] = function()
  local chat, calls = new_chat()
  attach_all(chat)
  local create_command = vim.api.nvim_buf_create_user_command
  vim.api.nvim_buf_create_user_command = function()
    error('fixture command creation failed')
  end
  local ok, state = pcall(Control.reconcile, chat)
  vim.api.nvim_buf_create_user_command = create_command

  eq(ok, true)
  eq(state.boundary_issue, 'resume_command')
  eq(Control.phase(chat), 'blocked')
  Control.reconcile(chat)
  eq(state.boundary_issue, 'resume_command')
  eq(Control.resume(chat), false)
  eq(#calls.notices, 1)
end

T['blocks bare terminal submits and rejects invalid explicit recovery preconditions'] = function()
  for _, phase in ipairs({ 'halted', 'finalized' }) do
    local chat, calls = controlled_chat(phase)
    chat._btw = 'queued follow-up'
    local callback_count = 0
    chat:submit({
      callback = function()
        callback_count = callback_count + 1
      end,
    })
    chat:submit()
    eq(callback_count, 1)
    eq(calls.submit, 0)
    eq(calls.restore, 1)
    eq(chat._btw, 'queued follow-up')
  end

  local blank, blank_calls = controlled_chat('halted')
  for _, content in ipairs({ false, '', '   ' }) do
    set_resume_input(blank, content == false and nil or content, blank_calls)
    eq(Control.resume(blank), false)
  end
  eq(blank_calls.submit, 0)

  local active, active_calls = controlled_chat('active')
  set_resume_input(active, 'new facts', active_calls)
  eq(Control.resume(active), false)

  local requested, requested_calls = controlled_chat('halted')
  set_resume_input(requested, 'new facts', requested_calls)
  requested.current_request = {}
  eq(Control.resume(requested), false)
  requested.current_request = nil
  requested.tool_orchestrator = {}
  eq(Control.resume(requested), false)

  local stale_handle, stale_calls, stale_state = controlled_chat('halted')
  set_resume_input(stale_handle, 'new facts', stale_calls)
  stale_state.request_handle = {}
  eq(Control.resume(stale_handle), false)
  stale_state.request_handle = nil
  stale_state.pending_stop_token = { valid = true }
  eq(Control.resume(stale_handle), false)
  stale_state.pending_stop_token = nil
  stale_state.resume_attempt = { valid = true }
  eq(Control.resume(stale_handle), false)

  local missing, missing_calls = controlled_chat('halted')
  set_resume_input(missing, 'new facts', missing_calls)
  missing.tool_registry.in_use.reasoning_review = nil
  eq(Control.resume(missing), false)

  local acp, acp_calls = controlled_chat('halted')
  set_resume_input(acp, 'new facts', acp_calls)
  acp.adapter = { type = 'acp', name = 'resume_acp' }
  eq(Control.resume(acp), false)
end

T['commits halted and finalized resume only after exact request construction'] = function()
  local halted, halted_calls, halted_state = controlled_chat('halted')
  local workspace = State.get(halted)
  halted_state.resume_phase = 'active'
  halted_state.consecutive_violations = 3
  local old_lease = { valid = true, epoch = halted_state.epoch, generation = halted_state.request_generation }
  halted_state.fallback_lease = old_lease
  set_resume_input(halted, 'new evidence from the project', halted_calls)
  eq(Control.resume(halted), true)
  eq(State.get(halted), workspace)
  eq(halted_state.phase, 'active')
  eq(halted_state.consecutive_violations, 0)
  eq(halted_state.fallback_lease, nil)
  eq(old_lease.valid, false)
  eq(halted_state.resume_attempt, nil)
  eq(halted_state.active_request_token ~= nil, true)
  eq(halted_calls.submit, 1)
  eq(halted_calls.http, 1)

  local finalized, finalized_calls, finalized_state = controlled_chat('finalized')
  local observed_phase
  finalized.fixture_before_submit = function()
    observed_phase = finalized_state.phase
  end
  set_resume_input(finalized, 'the requirements changed', finalized_calls)
  invoke_resume_command(finalized)
  eq(observed_phase, 'reframing')
  eq(finalized_state.phase, 'reframing')
  eq(finalized_state.resume_attempt, nil)
  eq(finalized_calls.submit, 1)
  eq(finalized_calls.http, 1)
end

T['accepts synchronous completion and rolls back phantom resume generations'] = function()
  local synchronous, sync_calls, sync_state = controlled_chat('halted')
  sync_state.resume_phase = 'active'
  synchronous.fixture_skip_ready = true
  synchronous.fixture_sync_send = function(request)
    request.on_done()
  end
  set_resume_input(synchronous, 'continue with the correction', sync_calls)
  eq(Control.resume(synchronous), true)
  eq(sync_state.phase, 'active')
  eq(sync_state.resume_attempt, nil)
  eq(sync_state.active_request_token, nil)
  eq(sync_state.completion_classified, true)
  eq(sync_state.consecutive_violations, 1)

  local phantom, phantom_calls, phantom_state = controlled_chat('halted')
  phantom_state.resume_phase = 'active'
  phantom_state.consecutive_violations = 2
  phantom.fixture_skip_http = true
  phantom.fixture_host_submit_side_effects = true
  phantom.header_line = 7
  local original_messages = vim.deepcopy(phantom.messages)
  set_resume_input(phantom, 'retry after fixing input', phantom_calls)
  eq(Control.resume(phantom), false)
  eq(phantom_state.phase, 'halted')
  eq(phantom_state.consecutive_violations, 2)
  eq(phantom_state.fallback_lease, nil)
  eq(phantom_state.construction_lease, nil)
  eq(phantom_state.completion_classified, true)
  eq(phantom_state.resume_attempt, nil)
  eq(phantom_calls.submit, 1)
  eq(phantom_calls.http, 0)
  eq(phantom.header_line, 7)
  eq(phantom.messages, original_messages)
  eq(phantom.fixture_locked, false)
  eq(phantom_calls.restore, 1)

  phantom.fixture_skip_http = false
  eq(Control.resume(phantom), true)
  eq(phantom_state.phase, 'active')
  eq(phantom_calls.submit, 2)
  eq(phantom_calls.http, 1)
end

T['preserves internal halts from failed resume and drops their retained callbacks'] = function()
  for _, mode in ipairs({ 'submit', 'http', 'retained' }) do
    local chat, calls, state = controlled_chat('halted')
    state.resume_phase = 'active'
    state.consecutive_violations = 3
    chat.fixture_host_submit_side_effects = true
    chat.header_line = 9
    local original_messages = vim.deepcopy(chat.messages)
    if mode == 'submit' then
      chat.fixture_submit_error = true
    elseif mode == 'http' then
      chat.fixture_http_throw = true
    else
      chat.fixture_sync_send = function()
        error('request failed after callback capture')
      end
    end
    set_resume_input(chat, 'recover explicitly', calls)
    eq(Control.resume(chat), false)
    eq(state.phase, 'halted')
    eq(state.resume_phase, 'active')
    eq(state.consecutive_violations, 0)
    eq(state.resume_attempt, nil)
    eq(state.active_request_token, nil)
    eq(state.construction_lease, nil)
    eq(chat.header_line, 9)
    eq(chat.messages, original_messages)
    eq(chat.fixture_locked, false)
    eq(calls.restore, 1)
    if mode == 'retained' then
      local request = calls.requests[1]
      local before = { parse = calls.parse_chat, done = calls.done }
      request.on_chunk({ status = 'success', output = { content = 'late failure output' } })
      request.on_done()
      eq(calls.parse_chat, before.parse)
      eq(calls.done, before.done)
    end
  end
end

T['invalidates pre-resume fallback and requires reframe after final output'] = function()
  local chat, calls, state = controlled_chat('finalized')
  local old_lease = { valid = true, epoch = state.epoch, generation = state.request_generation }
  state.fallback_lease = old_lease
  chat:dispatch('on_ready')
  set_resume_input(chat, 'new constraints invalidate the final', calls)
  eq(Control.resume(chat), true)
  drain_scheduled()
  eq(calls.submit, 1)
  eq(old_lease.valid, false)
  eq(state.phase, 'reframing')

  local request = calls.requests[1]
  local external = formatted_call('reframe-read', 'read_file', { path = 'README.md' })
  request.on_chunk({ status = 'success', tool_calls = { external } })
  request.on_done()
  eq(state.phase, 'reframing')
  chat:add_tool_output({ name = 'read_file', function_call = external }, 'investigation result', '')
  chat.tool_orchestrator = nil

  local invalid = formatted_call('reframe-evidence', 'reasoning_evidence', {})
  chat.tools:execute(chat, { invalid })
  eq(state.phase, 'reframing')
  eq(state.call_tokens[invalid].status, 'synthetic')

  state.request_generation = state.request_generation + 1
  state.observed_call_ids[state.request_generation] = {}
  chat.tool_orchestrator = nil
  local revise = formatted_call('reframe-revise', 'reasoning_frame', frame_args('revise'))
  eq(execute_protocol_call(chat, revise, 'reframing').status, 'success')
  eq(state.phase, 'active')
end

T['binds a prepared final to the exact live call and controller generation'] = function()
  local chat, _, state = final_ready_chat()
  state.request_generation = 4
  state.observed_call_ids[4] = {}
  local fallback = { valid = true, epoch = state.epoch, generation = 4 }
  state.fallback_lease = fallback
  local result, tool, call = prepare_final_output(chat, 'response-item-final', 'response-call-final')
  local internal = result.data._reasoning_final

  eq(Control.stage_final(chat, tool, internal), true)
  local staged = state.staged_final
  eq(staged.generation, 4)
  eq(staged.epoch, state.epoch)
  eq(staged.call_id, call.id)
  eq(staged.response_call_id, call.call_id)
  eq(staged.marker, state.call_tokens[call])
  eq(staged.adapter, chat.adapter)
  eq(staged.workspace, State.get(chat))
  eq(staged.revision, State.get(chat).revision)
  eq(staged.reserved_id, 'S1')
  eq(staged.stage, internal.stage)
  eq(staged.markdown, internal.markdown)
  eq(state.phase, 'finalizing')
  eq(state.fallback_lease, nil)
  eq(fallback.valid, false)
  eq(chat.subscribers.stopped, true)
end

T['refuses every stale or malformed final stage without leaving active'] = function()
  local cases = {
    function(_, _, _, call)
      call.id = 'changed-call'
    end,
    function(_, _, _, call)
      call.call_id = 'changed-response-call'
    end,
    function(_, state, _, call)
      state.call_tokens[call].valid = false
    end,
    function(_, state)
      state.request_generation = state.request_generation + 1
    end,
    function(_, _, internal)
      internal.stage.revision = internal.stage.revision + 1
    end,
    function(_, _, internal)
      internal.stage.candidate.data.mode = 'checkpoint'
    end,
    function(_, _, internal)
      internal.stage.reserved_id = 'S-forged'
    end,
    function(_, _, internal)
      internal.markdown = '   '
    end,
  }

  for _, mutate in ipairs(cases) do
    Control._reset()
    State._reset()
    local chat, _, state = final_ready_chat()
    local result, tool, call = prepare_final_output(chat, 'refused-final')
    local internal = result.data._reasoning_final
    mutate(chat, state, internal, call)
    eq(Control.stage_final(chat, tool, internal), nil)
    eq(state.phase, 'active')
    eq(state.staged_final, nil)
    eq(chat.subscribers.stopped, nil)
    eq(State.find(State.get(chat), 'S1'), nil)
  end
end

T['records then commits and emits one exact controlled final'] = function()
  local chat, calls, state = final_ready_chat()
  local result, tool, call = prepare_final_output(chat, 'atomic-final')
  local markdown = result.data._reasoning_final.markdown
  State.commit_final = function(...)
    table.insert(calls.events, 'commit')
    eq(State.find(State.get(chat), 'S1'), nil)
    return original_commit_final(...)
  end
  local reentered = false
  chat:add_callback('on_tool_output', function(_, args)
    if not reentered then
      reentered = true
      chat:add_tool_output(tool, args.for_llm, '')
    end
    args.for_user = 'must not leak before final verification'
  end)

  record_final_output(chat, result, tool)

  eq(calls.events, { 'tool_result_recorded', 'commit', 'history_message', 'buffer_message' })
  eq(state.phase, 'finalized')
  eq(state.staged_final, nil)
  eq(state.call_tokens[call].status, 'classified')
  eq(state.consecutive_violations, 0)
  eq(State.find(State.get(chat), 'S1').data.conclusion, final_args().conclusion)
  eq(#chat.messages, 2)
  eq(vim.json.decode(chat.messages[1].content)._reasoning_final, nil)
  eq(chat.messages[2].role, host_config.constants.LLM_ROLE)
  eq(chat.messages[2].content, markdown)
  eq(calls.notices[1].data.content, markdown)
  eq(reentered, true)
  eq(vim.json.encode(calls.notices):find('must not leak', 1, true), nil)
  eq(rawget(chat, '_codecompanion_reasoning_terminal_guard'), nil)

  local before = {
    messages = #chat.messages,
    notices = #calls.notices,
    events = #calls.events,
  }
  record_final_output(chat, result, tool)
  chat:dispatch('on_ready')
  drain_scheduled()
  chat:submit({ auto_submit = true })
  eq(#chat.messages, before.messages)
  eq(#calls.notices, before.notices)
  eq(#calls.events, before.events)
  eq(calls.submit, 0)
  eq(State.get(chat).counts_by_kind.synthesis, 1)
end

T['seals a successful final against retained rollback capability'] = function()
  local chat, _, state = final_ready_chat()
  local result, tool = prepare_final_output(chat, 'sealed-final')
  local stage = result.data._reasoning_final.stage

  record_final_output(chat, result, tool)

  eq(state.phase, 'finalized')
  eq(stage.state, 'finalized')
  eq(State.rollback_final(chat, stage), false)
  eq(State.find(State.get(chat), 'S1') ~= nil, true)
  eq(#chat.messages, 2)
end

T['does not run dynamic cleanup after final verification'] = function()
  local chat, _, state = final_ready_chat()
  local result, tool = prepare_final_output(chat, 'post-verification-cleanup')
  local cleanup_calls = 0
  chat:add_callback('on_tool_output', function()
    chat.remove_tagged_message = function(value)
      cleanup_calls = cleanup_calls + 1
      value.messages[1].content = 'tampered after verification'
    end
  end)

  record_final_output(chat, result, tool)

  eq(cleanup_calls, 0)
  eq(state.phase, 'finalized')
  eq(vim.json.decode(chat.messages[1].content).artifact.id, 'S1')
  eq(State.find(State.get(chat), 'S1') ~= nil, true)
end

T['accepts authenticated ordinary Responses and Ollama result layouts'] = function()
  local layouts = {
    ordinary = function(call, output)
      return {
        role = 'tool',
        tools = { call_id = call.id, name = call['function'].name },
        content = output,
      }
    end,
    responses = function(call, output)
      return {
        role = 'tool',
        tools = { id = call.id, call_id = call.call_id, name = call['function'].name },
        content = output,
      }
    end,
    ollama = function(call, output)
      return {
        role = 'tool',
        tool_name = call['function'].name,
        content = output,
      }
    end,
  }

  for name, formatter in pairs(layouts) do
    Control._reset()
    State._reset()
    local chat, _, state = final_ready_chat()
    chat.adapter.handlers.tools.format_response = function(_, call, output)
      return formatter(call, output)
    end
    local response_id = name == 'responses' and 'response-call-final' or nil
    local result, tool = prepare_final_output(chat, name .. '-final', response_id)
    record_final_output(chat, result, tool)
    eq(state.phase, 'finalized')
    eq(State.find(State.get(chat), 'S1') ~= nil, true)
    eq(#chat.messages, 2)
  end

  Control._reset()
  State._reset()
  local ollama, _, ollama_state = controlled_chat('armed')
  ollama.adapter.handlers.tools.format_response = function(_, call, output)
    return { role = 'tool', tool_name = call['function'].name, content = output }
  end
  local frame = formatted_call('ollama-frame', 'reasoning_frame', frame_args())
  eq(execute_protocol_call(ollama, frame, 'armed').status, 'success')
  eq(ollama_state.phase, 'active')
  eq(ollama_state.call_tokens[frame].status, 'classified')
end

T['scrubs every mismatched staged-final record and halts uncounted'] = function()
  local cases = {
    {
      name = 'deep payload',
      arrange = function(chat)
        chat:add_callback('on_tool_output', function(_, args)
          local payload = vim.json.decode(args.for_llm)
          payload.artifact.data.conclusion = 'hostile substituted conclusion'
          args.for_llm = vim.json.encode(payload)
        end)
      end,
    },
    {
      name = 'payload id',
      arrange = function(chat)
        chat:add_callback('on_tool_output', function(_, args)
          local payload = vim.json.decode(args.for_llm)
          payload.artifact.id = 'S-forged'
          args.for_llm = vim.json.encode(payload)
        end)
      end,
    },
    {
      name = 'workspace id',
      arrange = function(chat)
        chat:add_callback('on_tool_output', function(_, args)
          local payload = vim.json.decode(args.for_llm)
          payload.workspace_id = 'W-forged'
          args.for_llm = vim.json.encode(payload)
        end)
      end,
    },
    {
      name = 'workspace revision',
      arrange = function(chat)
        chat:add_callback('on_tool_output', function()
          State.retract(State.get(chat), 'E1')
        end)
      end,
    },
    {
      name = 'adapter identity',
      arrange = function(chat)
        chat:add_callback('on_tool_output', function()
          chat.adapter = vim.deepcopy(chat.adapter)
        end)
      end,
    },
    {
      name = 'adapter transport',
      arrange = function(chat)
        chat:add_callback('on_tool_output', function()
          chat.adapter.type = 'acp'
        end)
      end,
    },
    {
      name = 'tool boundary',
      arrange = function(chat)
        chat:add_callback('on_tool_output', function()
          chat.tool_registry.in_use.reasoning_synthesis = nil
        end)
      end,
    },
    {
      name = 'wrapper boundary',
      arrange = function(chat)
        chat:add_callback('on_tool_output', function()
          rawset(chat, 'submit', function() end)
        end)
      end,
    },
    {
      name = 'missing record',
      arrange = function(chat)
        chat.adapter.handlers.tools.format_response = function()
          return nil
        end
      end,
    },
    {
      name = 'throwing formatter',
      arrange = function(chat)
        chat.adapter.handlers.tools.format_response = function()
          error('fixture final formatter failed')
        end
      end,
    },
    {
      name = 'multiple records',
      arrange = function(chat)
        chat:add_callback('on_tool_output', function(_, args)
          chat:add_message({ role = 'tool', content = args.for_llm }, { visible = false })
        end)
      end,
    },
    {
      name = 'multiple records with nonfinal noise',
      arrange = function(chat)
        chat:add_callback('on_tool_output', function()
          chat:add_message({ role = 'tool', content = vim.json.encode({ code = 'noise' }) }, { visible = false })
        end)
      end,
    },
    {
      name = 'multiple records with nonstring noise',
      arrange = function(chat)
        chat:add_callback('on_tool_output', function()
          chat:add_message({ role = 'tool', content = {} }, { visible = false })
        end)
      end,
    },
    {
      name = 'wrong result identity',
      arrange = function(chat)
        chat.adapter.handlers.tools.format_response = function(_, _, output)
          return {
            role = 'tool',
            tools = { id = 'wrong-item', call_id = 'wrong-call', name = 'reasoning_synthesis' },
            content = output,
          }
        end
      end,
    },
    {
      name = 'partial responses identity',
      call_id = 'response-call-partial',
      arrange = function(chat)
        chat.adapter.handlers.tools.format_response = function(_, call, output)
          return {
            role = 'tool',
            tools = { call_id = call.id, name = 'reasoning_synthesis' },
            content = output,
          }
        end
      end,
    },
    {
      name = 'missing result identity',
      arrange = function(chat)
        chat.adapter.handlers.tools.format_response = function(_, _, output)
          return { role = 'tool', content = output }
        end
      end,
    },
    {
      name = 'name-only result identity',
      arrange = function(chat)
        chat.adapter.handlers.tools.format_response = function(_, _, output)
          return { role = 'tool', tools = { name = 'reasoning_synthesis' }, content = output }
        end
      end,
    },
    {
      name = 'wrong result name with matching id',
      arrange = function(chat)
        chat.adapter.handlers.tools.format_response = function(_, call, output)
          return {
            role = 'tool',
            tools = { id = call.id, call_id = call.call_id or call.id, name = 'reasoning_evidence' },
            content = output,
          }
        end
      end,
    },
    {
      name = 'wrong result role',
      arrange = function(chat)
        chat.adapter.handlers.tools.format_response = function(_, _, output)
          return { role = 'assistant', tool_name = 'reasoning_synthesis', content = output }
        end
      end,
    },
    {
      name = 'live call identity',
      arrange = function(chat, call)
        chat:add_callback('on_tool_output', function()
          call.id = 'mutated-live-call'
        end)
      end,
    },
  }

  for _, case in ipairs(cases) do
    Control._reset()
    State._reset()
    local chat, calls, state = final_ready_chat()
    state.consecutive_violations = 2
    local result, tool, call = prepare_final_output(chat, 'mismatch-' .. case.name:gsub(' ', '-'), case.call_id)
    local stage = result.data._reasoning_final.stage
    case.arrange(chat, call)
    record_final_output(chat, result, tool)

    eq(state.phase, 'halted')
    eq(state.resume_phase, 'active')
    eq(state.consecutive_violations, 2)
    eq(state.staged_final, nil)
    eq(stage.state, 'discarded')
    eq(State.find(State.get(chat), 'S1'), nil)
    local tool_messages = {}
    for _, message in ipairs(chat.messages) do
      if message.role == 'tool' then
        table.insert(tool_messages, message)
      end
    end
    eq(#tool_messages, 1)
    eq(#chat.messages, 1)
    local payload = vim.json.decode(tool_messages[1].content)
    eq(payload.code, 'internal_error')
    eq(payload.committed, false)
    eq(payload.artifact, nil)
    eq(#calls.notices >= 1, true)
  end
end

T['rejects a coordinated mutation of the staged candidate and public result'] = function()
  local chat, _, state = final_ready_chat()
  local result, tool = prepare_final_output(chat, 'mutated-staged-candidate')
  local stage = result.data._reasoning_final.stage
  chat:add_callback('on_tool_output', function(_, args)
    stage.candidate.data.conclusion = 'Hostile conclusion after deterministic rendering'
    local payload = vim.json.decode(args.for_llm)
    payload.artifact = vim.deepcopy(stage.candidate)
    args.for_llm = vim.json.encode(payload)
  end)

  record_final_output(chat, result, tool)

  eq(stage.state, 'discarded')
  eq(state.phase, 'halted')
  eq(State.find(State.get(chat), 'S1'), nil)
  eq(#chat.messages, 1)
  eq(vim.json.decode(chat.messages[1].content).code, 'internal_error')
end

T['rejects and restores pre-record history replacement'] = function()
  local chat, _, state = final_ready_chat()
  local prior = { role = 'user', content = 'preserve prior reasoning context' }
  table.insert(chat.messages, prior)
  local result, tool = prepare_final_output(chat, 'replaced-pre-record-history')
  local stage = result.data._reasoning_final.stage
  chat:add_callback('on_tool_output', function(value)
    value.messages = {}
  end)

  record_final_output(chat, result, tool)

  eq(stage.state, 'discarded')
  eq(state.phase, 'halted')
  eq(State.find(State.get(chat), 'S1'), nil)
  eq(#chat.messages, 2)
  eq(chat.messages[1], prior)
  eq(chat.messages[1].content, 'preserve prior reasoning context')
  eq(vim.json.decode(chat.messages[2].content).code, 'internal_error')
end

T['rejects multiple staged-final records when the host reuses a result message'] = function()
  local chat, _, state = final_ready_chat()
  local result, tool, call = prepare_final_output(chat, 'reused-multiple-final')
  local stage = result.data._reasoning_final.stage
  local prefix = vim.json.encode({ prior = 'preserved' })
  local prior = {
    role = 'tool',
    tools = { call_id = call.id, name = 'reasoning_synthesis' },
    content = prefix,
    _meta = { cycle = chat.cycle },
  }
  prior._meta.id = host_hash.hash({ role = prior.role, content = prior.content })
  table.insert(chat.messages, prior)
  chat:add_callback('on_tool_output', function(_, args)
    chat:add_message({ role = 'tool', tool_name = 'reasoning_synthesis', content = args.for_llm }, { visible = false })
  end)

  record_final_output(chat, result, tool)

  eq(stage.state, 'discarded')
  eq(state.phase, 'halted')
  eq(state.resume_phase, 'active')
  eq(state.staged_final, nil)
  eq(State.find(State.get(chat), 'S1'), nil)
  eq(#chat.messages, 1)
  eq(chat.messages[1], prior)
  eq(chat.messages[1].content:sub(1, #prefix + 2), prefix .. '\n\n')
  local payload = vim.json.decode(chat.messages[1].content:sub(#prefix + 3))
  eq(payload.code, 'internal_error')
  eq(payload.committed, false)
end

T['rejects identity mutation on a reused staged-final result'] = function()
  local mutations = {
    name = function(message)
      message.tools.name = 'reasoning_evidence'
    end,
    call_id = function(message)
      message.tools.call_id = 'hostile-replacement'
    end,
  }

  for name, mutate in pairs(mutations) do
    Control._reset()
    State._reset()
    local chat, _, state = final_ready_chat()
    local result, tool, call = prepare_final_output(chat, 'reused-identity-' .. name)
    local stage = result.data._reasoning_final.stage
    local prefix = vim.json.encode({ prior = 'preserved' })
    local prior = {
      role = 'tool',
      tools = { call_id = call.id, name = 'reasoning_synthesis' },
      content = prefix,
      _meta = { cycle = chat.cycle },
    }
    prior._meta.id = host_hash.hash({ role = prior.role, content = prior.content })
    table.insert(chat.messages, prior)
    chat:add_callback('on_tool_output', function()
      mutate(prior)
    end)

    record_final_output(chat, result, tool)

    eq(stage.state, 'discarded')
    eq(state.phase, 'halted')
    eq(State.find(State.get(chat), 'S1'), nil)
    eq(#chat.messages, 1)
    eq(chat.messages[1], prior)
    eq(prior.tools.call_id, call.id)
    eq(prior.tools.name, 'reasoning_synthesis')
    eq(prior.content:sub(1, #prefix + 2), prefix .. '\n\n')
    eq(vim.json.decode(prior.content:sub(#prefix + 3)).code, 'internal_error')
  end
end

T['scrubs a recorded final when host callbacks invalidate its prepared stage'] = function()
  local cases = {
    clear = function(chat)
      chat:clear()
    end,
    close = function(chat)
      chat:close()
    end,
    reconcile = function(chat)
      chat.adapter.type = 'acp'
      Control.reconcile(chat)
    end,
    missing_adapter = function(chat)
      chat.adapter = nil
      Control.reconcile(chat)
    end,
  }

  for name, invalidate in pairs(cases) do
    Control._reset()
    State._reset()
    local chat, _, state = final_ready_chat()
    local result, tool = prepare_final_output(chat, 'invalidate-' .. name)
    local stage = result.data._reasoning_final.stage
    chat:add_callback('on_tool_output', function(value)
      invalidate(value)
    end)

    record_final_output(chat, result, tool)

    eq(stage.state, 'discarded')
    eq(state.staged_final, nil)
    eq(State.find(State.get(chat), 'S1'), nil)
    local internal = 0
    local accepted = 0
    for _, message in ipairs(chat.messages) do
      if type(message.content) == 'string' then
        local decoded_ok, payload = pcall(vim.json.decode, message.content)
        if decoded_ok and payload.code == 'internal_error' then
          internal = internal + 1
        elseif decoded_ok and type(payload.artifact) == 'table' and payload.artifact.id == 'S1' then
          accepted = accepted + 1
        end
      end
    end
    eq(internal, 1)
    eq(accepted, 0)
    if name == 'clear' then
      eq(state.phase, 'dormant')
    elseif name == 'close' then
      eq(state.closed, true)
    else
      eq(state.unsupported_adapter, true)
    end
  end
end

T['rolls back final state history and buffer when either emission fails'] = function()
  for _, mode in ipairs({ 'history', 'buffer', 'nil' }) do
    Control._reset()
    State._reset()
    local chat, _, state = final_ready_chat()
    local result, tool, call = prepare_final_output(chat, 'rollback-final')
    local stage = result.data._reasoning_final.stage
    local prefix = vim.json.encode({ prior = 'preserved' })
    local prior = {
      role = 'tool',
      tools = { call_id = call.id, name = 'reasoning_synthesis' },
      content = prefix,
      _meta = { cycle = chat.cycle },
    }
    prior._meta.id = host_hash.hash({ role = prior.role, content = prior.content })
    table.insert(chat.messages, prior)
    vim.api.nvim_buf_set_lines(chat.bufnr, 0, -1, false, { 'buffer before final' })
    if mode == 'history' then
      chat.fixture_history_error = true
    elseif mode == 'buffer' then
      chat.fixture_buffer_write = true
      chat.fixture_buffer_error = true
    else
      chat.fixture_buffer_nil = true
    end
    local rollbacks = 0
    State.rollback_final = function(...)
      rollbacks = rollbacks + 1
      return original_rollback_final(...)
    end

    record_final_output(chat, result, tool)

    eq(rollbacks, 1)
    eq(stage.state, 'rolled_back')
    eq(state.phase, 'halted')
    eq(state.resume_phase, 'active')
    eq(state.staged_final, nil)
    eq(State.find(State.get(chat), 'S1'), nil)
    eq(State.get(chat).next_sequence.synthesis, nil)
    eq(State.get(chat).counts_by_kind.synthesis, nil)
    eq(#chat.messages, 1)
    eq(chat.messages[1], prior)
    eq(chat.messages[1].content:sub(1, #prefix + 2), prefix .. '\n\n')
    local delta = chat.messages[1].content:sub(#prefix + 3)
    local payload = vim.json.decode(delta)
    eq(payload.code, 'internal_error')
    eq(payload.committed, false)
    eq(chat.messages[1]._meta.id, host_hash.hash({ role = chat.messages[1].role, content = chat.messages[1].content }))
    eq(vim.api.nvim_buf_get_lines(chat.bufnr, 0, -1, false), { 'buffer before final' })
  end
end

T['does not overwrite lifecycle invalidation during final history or buffer emission'] = function()
  for _, mode in ipairs({ 'history', 'buffer' }) do
    Control._reset()
    State._reset()
    local chat, _, state = final_ready_chat()
    local result, tool = prepare_final_output(chat, 'invalidate-emission-' .. mode)
    local stage = result.data._reasoning_final.stage
    local markdown = result.data._reasoning_final.markdown
    vim.api.nvim_buf_set_lines(chat.bufnr, 0, -1, false, { 'before invalidated emission' })
    chat.fixture_buffer_write = true
    local invalidate = function(value)
      value:close()
    end
    if mode == 'history' then
      chat.fixture_final_history_invalidate = invalidate
    else
      chat.fixture_final_buffer_invalidate = invalidate
    end

    record_final_output(chat, result, tool)

    eq(state.closed, true)
    eq(state.phase == 'finalized', false)
    eq(state.staged_final, nil)
    eq(stage.state, 'rolled_back')
    eq(State.get(chat), nil)
    eq(vim.api.nvim_buf_get_lines(chat.bufnr, 0, -1, false), { 'before invalidated emission' })
    local internal = 0
    local rendered = 0
    for _, message in ipairs(chat.messages) do
      if message.content == markdown then
        rendered = rendered + 1
      elseif type(message.content) == 'string' then
        local decoded_ok, payload = pcall(vim.json.decode, message.content)
        if decoded_ok and payload.code == 'internal_error' then
          internal = internal + 1
        end
      end
    end
    eq(rendered, 0)
    eq(internal, 0)
  end
end

T['revalidates the exact recorded result after final history and buffer callbacks'] = function()
  local mutations = {
    content = function(message)
      message.content = message.content .. ' '
    end,
    identity = function(message)
      message.tools.name = 'reasoning_evidence'
    end,
    hash = function(message)
      message._meta.id = 'forged-result-hash'
    end,
  }
  for _, emission in ipairs({ 'history', 'buffer' }) do
    for name, mutate in pairs(mutations) do
      Control._reset()
      State._reset()
      local chat, _, state = final_ready_chat()
      local result, tool = prepare_final_output(chat, 'mutate-' .. emission .. '-' .. name)
      local stage = result.data._reasoning_final.stage
      local hook = function(value)
        mutate(value.messages[1])
      end
      if emission == 'history' then
        chat.fixture_final_history_invalidate = hook
      else
        chat.fixture_final_buffer_invalidate = hook
      end

      record_final_output(chat, result, tool)

      eq(stage.state, 'rolled_back')
      eq(state.phase, 'halted')
      eq(state.resume_phase, 'active')
      eq(State.find(State.get(chat), 'S1'), nil)
      eq(#chat.messages, 1)
      local payload = vim.json.decode(chat.messages[1].content)
      eq(payload.code, 'internal_error')
      eq(payload.committed, false)
      eq(
        chat.messages[1]._meta.id,
        host_hash.hash({ role = chat.messages[1].role, content = chat.messages[1].content })
      )
    end
  end
end

T['restores exact history when an emission callback removes the recorded result'] = function()
  local chat, _, state = final_ready_chat()
  local result, tool = prepare_final_output(chat, 'remove-recorded-final')
  local stage = result.data._reasoning_final.stage
  chat.fixture_final_history_invalidate = function(value)
    table.remove(value.messages, 1)
  end

  record_final_output(chat, result, tool)

  eq(stage.state, 'rolled_back')
  eq(state.phase, 'halted')
  eq(State.find(State.get(chat), 'S1'), nil)
  eq(#chat.messages, 1)
  eq(vim.json.decode(chat.messages[1].content).code, 'internal_error')
end

T['revalidates the emitted assistant history after buffer callbacks'] = function()
  local chat, _, state = final_ready_chat()
  local result, tool = prepare_final_output(chat, 'mutate-final-assistant')
  local stage = result.data._reasoning_final.stage
  chat.fixture_final_buffer_invalidate = function(value)
    value.messages[2].content = value.messages[2].content .. ' hostile suffix'
  end

  record_final_output(chat, result, tool)

  eq(stage.state, 'rolled_back')
  eq(state.phase, 'halted')
  eq(State.find(State.get(chat), 'S1'), nil)
  eq(#chat.messages, 1)
  eq(vim.json.decode(chat.messages[1].content).code, 'internal_error')
end

T['restores the pre-final workspace after emission-time mutation'] = function()
  local chat, _, state = final_ready_chat()
  local workspace = State.get(chat)
  local revision = workspace.revision
  local result, tool = prepare_final_output(chat, 'mutate-emission-workspace')
  local stage = result.data._reasoning_final.stage
  chat.fixture_final_history_invalidate = function()
    State.retract(workspace, 'E1')
  end

  record_final_output(chat, result, tool)

  eq(stage.state, 'rolled_back')
  eq(state.phase, 'halted')
  eq(workspace.revision, revision)
  eq(State.find(workspace, 'E1').status, 'active')
  eq(State.find(workspace, 'S1'), nil)
  eq(vim.json.decode(chat.messages[1].content).code, 'internal_error')
end

T['unlocks verifies and relocks the buffer during final compensation'] = function()
  local chat, _, state = final_ready_chat()
  local result, tool = prepare_final_output(chat, 'locked-buffer-compensation')
  local stage = result.data._reasoning_final.stage
  vim.api.nvim_buf_set_lines(chat.bufnr, 0, -1, false, { 'buffer before locked failure' })
  vim.bo[chat.bufnr].modifiable = false
  chat.fixture_buffer_partial_lock = true

  record_final_output(chat, result, tool)

  eq(stage.state, 'rolled_back')
  eq(state.phase, 'halted')
  eq(vim.api.nvim_buf_get_lines(chat.bufnr, 0, -1, false), { 'buffer before locked failure' })
  eq(vim.bo[chat.bufnr].modifiable, false)
  eq(State.find(State.get(chat), 'S1'), nil)
end

T['preserves the host clear render when clear invalidates final emission'] = function()
  for _, emission in ipairs({ 'history', 'buffer' }) do
    Control._reset()
    State._reset()
    local chat = final_ready_chat()
    local result, tool = prepare_final_output(chat, 'clear-emission-' .. emission)
    local stage = result.data._reasoning_final.stage
    chat.fixture_buffer_write = true
    chat.fixture_clear_render = true
    local hook = function(value)
      value:clear()
    end
    if emission == 'history' then
      chat.fixture_final_history_invalidate = hook
    else
      chat.fixture_final_buffer_invalidate = hook
    end

    record_final_output(chat, result, tool)

    eq(State.get(chat), nil)
    eq(Control._get(chat).phase, 'dormant')
    eq(Control._get(chat).staged_final, nil)
    eq(stage.state == 'prepared', false)
    eq(chat.messages, {})
    eq(vim.api.nvim_buf_get_lines(chat.bufnr, 0, -1, false), { 'host cleared render' })
    eq(vim.bo[chat.bufnr].modifiable, false)
  end
end

T['compensates a controller-only clear without restoring its workspace'] = function()
  for _, emission in ipairs({ 'history', 'buffer' }) do
    Control._reset()
    State._reset()
    local chat, _, state = final_ready_chat()
    local result, tool = prepare_final_output(chat, 'controller-clear-' .. emission)
    local stage = result.data._reasoning_final.stage
    vim.api.nvim_buf_set_lines(chat.bufnr, 0, -1, false, { 'before controller-only clear' })
    chat.fixture_buffer_write = true
    local hook = function(value)
      Control.clear(value)
    end
    if emission == 'history' then
      chat.fixture_final_history_invalidate = hook
    else
      chat.fixture_final_buffer_invalidate = hook
    end

    record_final_output(chat, result, tool)

    eq(State.get(chat), nil)
    eq(state.phase, 'dormant')
    eq(state.staged_final, nil)
    eq(stage.state, 'rolled_back')
    eq(#chat.messages, 1)
    eq(vim.json.decode(chat.messages[1].content).code, 'internal_error')
    eq(vim.api.nvim_buf_get_lines(chat.bufnr, 0, -1, false), { 'before controller-only clear' })
  end
end

T['does not strand a prepared final when subscriber stop changes the boundary'] = function()
  local cases = {
    adapter = function(chat)
      chat.adapter.type = 'acp'
    end,
    tools = function(chat)
      chat.tool_registry.in_use.reasoning_synthesis = nil
    end,
    wrapper = function(chat)
      rawset(chat, 'submit', function() end)
    end,
    resume_command = function(chat)
      vim.api.nvim_buf_del_user_command(chat.bufnr, Constants.resume_command)
    end,
  }

  for name, mutate in pairs(cases) do
    Control._reset()
    State._reset()
    local chat, _, state = final_ready_chat()
    local result, tool = prepare_final_output(chat, 'stop-boundary-' .. name)
    local stage = result.data._reasoning_final.stage
    chat.subscribers.stop = function()
      mutate(chat)
    end

    record_final_output(chat, result, tool)

    eq(stage.state, 'discarded')
    eq(state.staged_final, nil)
    eq(state.phase, 'halted')
    eq(state.resume_phase, 'active')
    eq(State.find(State.get(chat), 'S1'), nil)
    for _, message in ipairs(chat.messages) do
      eq(message.content == result.data._reasoning_final.markdown, false)
    end
  end
end

T['rewrites a final commit conflict without emitting accepted prose'] = function()
  local chat, calls, state = final_ready_chat()
  local result, tool = prepare_final_output(chat, 'commit-conflict')
  local stage = result.data._reasoning_final.stage
  State.commit_final = function()
    return nil, 'transaction_conflict'
  end

  record_final_output(chat, result, tool)

  eq(stage.state, 'discarded')
  eq(state.phase, 'halted')
  eq(state.resume_phase, 'active')
  eq(state.staged_final, nil)
  eq(State.find(State.get(chat), 'S1'), nil)
  eq(#chat.messages, 1)
  eq(vim.json.decode(chat.messages[1].content).code, 'internal_error')
  for _, notice in ipairs(calls.notices) do
    eq(notice.data.content == result.data._reasoning_final.markdown, false)
  end
end

return T
