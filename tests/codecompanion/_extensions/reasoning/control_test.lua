local Config = require('codecompanion._extensions.reasoning.config')
local Constants = require('codecompanion._extensions.reasoning.constants')
local Control = require('codecompanion._extensions.reasoning.control')
local Output = require('codecompanion._extensions.reasoning.output')
local State = require('codecompanion._extensions.reasoning.state')
local Terminal = require('codecompanion._extensions.reasoning.terminal')
local host_adapters = require('codecompanion.adapters')
local host_config = require('codecompanion.config')

local T
local eq = MiniTest.expect.equality
local created_buffers = {}
local original_global_adapter
local original_test_adapter

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
    reset = 0,
    request_cancel = 0,
    stop = 0,
    adapter_exit = 0,
    orchestrator_cancel = 0,
    notices = {},
    outputs = {},
    events = {},
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
    if self.fixture_submit_error then
      error('fixture submit failed')
    end
    local payload = { messages = self.messages, marker = {} }
    calls.callback_payload = payload
    self:dispatch('on_submitted', { payload = payload })
    if self.adapter.type == 'http' then
      return self:_submit_http(payload)
    end
    return self:_submit_acp(payload)
  end
  methods._submit_http = function(self, payload)
    calls.http = calls.http + 1
    calls.transport_payload = payload
    local handle = {
      cancel = function()
        calls.request_cancel = calls.request_cancel + 1
        record('request_cancel')
        if self.fixture_on_request_cancel then
          self.fixture_on_request_cancel(self)
        end
      end,
    }
    self.current_request = handle
    return handle
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
  methods.done = function(self, _, reasoning, tool_calls)
    calls.done = calls.done + 1
    self.current_request = nil
    if reasoning then
      host_adapters.call_handler(self.adapter, 'build_reasoning', reasoning)
    end
    if tool_calls then
      local formatted = host_adapters.call_handler(self.adapter, 'format_calls', tool_calls)
      if formatted then
        self.tools:execute(self, formatted)
      end
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
  end
  methods.add_buf_message = function(_, data, message_opts)
    table.insert(calls.notices, { data = data, opts = message_opts })
    return #calls.notices
  end
  methods.add_tool_output = function(_, tool, for_llm, for_user)
    table.insert(calls.outputs, { tool = tool, for_llm = for_llm, for_user = for_user })
  end
  methods.clear = function(self)
    calls.clear = calls.clear + 1
    self.messages = {}
    self.tool_registry.in_use = {}
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
  methods.restore = function()
    calls.restore = calls.restore + 1
  end

  local tools_methods = {
    execute = function(self, host_chat, tool_calls)
      calls.execute = calls.execute + 1
      self.chat = host_chat
      self.last_calls = tool_calls
    end,
    reset = function(self)
      calls.reset = calls.reset + 1
      if self.chat then
        self.chat.tool_orchestrator = nil
      end
    end,
  }

  local chat = {
    adapter = {
      type = opts.adapter_type or 'http',
      name = opts.adapter_name or 'fixture_http',
      handlers = {
        lifecycle = {},
        response = {
          build_reasoning = function(_, reasoning)
            return reasoning
          end,
        },
        tools = {
          format_calls = function(_, tool_calls)
            return tool_calls
          end,
        },
      },
    },
    bufnr = vim.api.nvim_create_buf(false, true),
    callbacks = {},
    current_request = nil,
    messages = {},
    MESSAGE_TYPES = {
      LLM_MESSAGE = 'llm_message',
      REASONING_MESSAGE = 'reasoning_message',
      SYSTEM_MESSAGE = 'system_message',
      TOOL_MESSAGE = 'tool_message',
      USER_MESSAGE = 'user_message',
    },
    restore = methods.restore,
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
      original_global_adapter = vim.g.codecompanion_adapter
      original_test_adapter = host_config.adapters.reasoning_control_test_acp
      vim.g.codecompanion_adapter = nil
    end,
    post_case = function()
      Control._reset()
      State._reset()
      vim.g.codecompanion_adapter = original_global_adapter
      host_config.adapters.reasoning_control_test_acp = original_test_adapter
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
    execute = rawget(chat.tools, 'execute'),
    before = state.callbacks.on_before_submit,
  }
  Control.reconcile(chat)
  eq(rawget(chat, 'submit'), wrappers.submit)
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
  local call_token = { valid = true }
  local lease = { valid = true }
  local stage = { state = 'prepared' }
  state.active_request_token = active_token
  state.pending_stop_token = stop_token
  state.call_tokens[call_token] = true
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

  local during = attach_all(new_chat())
  Control.reconcile(during)
  local during_foreign = 0
  during.adapter.handlers.tools.format_calls = function(_, tool_calls)
    during.tools.execute = function()
      during_foreign = during_foreign + 1
    end
    return tool_calls
  end
  during:done(nil, nil, { { id = 'during', ['function'] = { name = 'external' } } })
  eq(during_foreign, 0)
  eq(Control.phase(during), 'blocked')

  local replaced_during = attach_all(new_chat())
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
  replaced_during:done(nil, nil, { { id = 'during-replace', ['function'] = { name = 'external' } } })
  eq(replaced_foreign, 0)
  eq(Control.phase(replaced_during), 'blocked')

  local legacy_during = attach_all(new_chat())
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
  legacy_during:done(nil, nil, { { id = 'legacy-during', ['function'] = { name = 'external' } } })
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
  swap_during:done(nil, { 'private chain' }, {
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
  closed:_submit_http({})
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

T['restores submitting after preserved submit errors and exposes total placeholders'] = function()
  local chat = attach_all(new_chat())
  Control.reconcile(chat)
  chat.fixture_submit_error = true
  MiniTest.expect.error(function()
    chat:submit({ auto_submit = true })
  end, 'fixture submit failed')
  eq(Control._get(chat).submitting, false)
  eq({ Control.stage_final(chat, {}, {}) }, { nil, 'not available in this lifecycle build' })
  eq({ Control.resume(chat) }, { nil, 'not available in this lifecycle build' })
end

return T
