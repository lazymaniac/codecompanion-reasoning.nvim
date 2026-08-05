local Constants = require('codecompanion._extensions.reasoning.constants')
local Protocol = require('codecompanion._extensions.reasoning.protocol')
local State = require('codecompanion._extensions.reasoning.state')
local Terminal = require('codecompanion._extensions.reasoning.terminal')
local Transition = require('codecompanion._extensions.reasoning.transition')
local owns_tool_config = require('codecompanion._extensions.reasoning').owns_tool_config

local M = {}
local controllers = setmetatable({}, { __mode = 'k' })
local unsupported_notified = setmetatable({}, { __mode = 'k' })
local suppressing_phase = {
  armed = true,
  active = true,
  reframing = true,
  finalizing = true,
  halted = true,
}

local function weak_values(value)
  return setmetatable({ value }, { __mode = 'v' })
end

local function new_state(chat, phase)
  return {
    chat_ref = weak_values(chat),
    phase = phase,
    resume_phase = 'active',
    suspended_phase = nil,
    unsupported_adapter = false,
    consecutive_violations = 0,
    fallback_lease = nil,
    request_generation = 0,
    completion_classified = true,
    observed_call_ids = {},
    staged_final = nil,
    closed = false,
    epoch = 0,
    next_request_token = 0,
    construction_lease = nil,
    active_request_token = nil,
    pending_stop_token = nil,
    call_tokens = setmetatable({}, { __mode = 'k' }),
    executing_scope = nil,
    request_handle = nil,
    resume_attempt = nil,
    submitting = false,
    clearing = false,
    processing_done = false,
    boundary_issue = nil,
    methods = {},
    callbacks = {},
  }
end

local function chat_for(state)
  return state.chat_ref[1]
end

local function capture_method(target, key)
  local original = target and target[key] or nil
  assert(type(original) == 'function', key .. ' must resolve to a function')
  return {
    target_ref = weak_values(target),
    key = key,
    had_raw = rawget(target, key) ~= nil,
    original = original,
  }
end

local function install_wrapper(slot, wrapper)
  local target = assert(slot.target_ref[1], 'wrapper target was collected')
  slot.wrapper = wrapper
  rawset(target, slot.key, wrapper)
end

local function restore_method(slot)
  local target = slot.target_ref[1]
  if target and rawget(target, slot.key) == slot.wrapper then
    rawset(target, slot.key, slot.had_raw and slot.original or nil)
  end
end

local function packed(...)
  return { n = select('#', ...), ... }
end

local function attached_tool_set(chat)
  if type(chat) ~= 'table' then
    return false
  end
  local registry = rawget(chat, 'tool_registry')
  local in_use = type(registry) == 'table' and rawget(registry, 'in_use') or nil
  if type(in_use) ~= 'table' or getmetatable(in_use) ~= nil then
    return false
  end
  for _, name in ipairs(Constants.tool_names) do
    if rawget(in_use, name) ~= true then
      return false
    end
  end
  return true
end

local function reasoning_tools_owned(chat)
  local tools = type(chat) == 'table' and rawget(chat, 'tools') or nil
  local tools_config = type(tools) == 'table' and rawget(tools, 'tools_config') or nil
  if type(tools_config) ~= 'table' or getmetatable(tools_config) ~= nil then
    return false
  end
  if type(owns_tool_config) ~= 'function' then
    return false
  end
  for _, name in ipairs(Constants.tool_names) do
    if not owns_tool_config(name, rawget(tools_config, name)) then
      return false
    end
  end
  return true
end

local function complete_tool_set(chat)
  return attached_tool_set(chat) and reasoning_tools_owned(chat)
end

local function live_tools_match(chat, state)
  local execute = state and state.methods.execute
  return execute ~= nil and execute.target_ref[1] ~= nil and chat.tools == execute.target_ref[1]
end

local function wrappers_intact(state)
  if not state then
    return false
  end
  for _, slot in pairs(state.methods) do
    local target = slot.target_ref[1]
    if not target or rawget(target, slot.key) ~= slot.wrapper then
      return false
    end
  end
  return true
end

local function hydrated_phase(chat)
  local workspace = State.get(chat)
  if not workspace then
    return 'armed'
  end
  return Protocol.transition(workspace, 'active').tool == 'none' and 'finalized' or 'active'
end

local function invalidate_marker(marker)
  if type(marker) == 'table' then
    marker.valid = false
  end
end

local function discard_stage(state)
  if state.staged_final then
    State.discard_final(state.staged_final)
    state.staged_final = nil
  end
end

local function invalidate_runtime(state, chat, opts)
  opts = opts or {}
  invalidate_marker(state.fallback_lease)
  invalidate_marker(state.active_request_token)
  invalidate_marker(state.pending_stop_token)
  invalidate_marker(state.construction_lease)
  invalidate_marker(state.executing_scope)
  for _, value in pairs(state.call_tokens) do
    invalidate_marker(value)
  end
  state.fallback_lease = nil
  state.active_request_token = nil
  state.pending_stop_token = nil
  state.construction_lease = nil
  state.executing_scope = nil
  state.call_tokens = setmetatable({}, { __mode = 'k' })
  state.resume_attempt = nil
  state.observed_call_ids = {}
  state.completion_classified = true
  state.consecutive_violations = 0
  state.request_generation = state.request_generation + 1
  state.epoch = state.epoch + 1
  state.submitting = false
  discard_stage(state)

  local handle = state.request_handle or chat.current_request
  state.request_handle = nil
  if not opts.preserve_host_request then
    chat.current_request = nil
    if handle and type(handle.cancel) == 'function' then
      pcall(handle.cancel, handle)
    end
  end

  if not opts.preserve_host_orchestrator then
    local orchestrator = chat.tool_orchestrator
    if orchestrator and type(orchestrator.cancel) == 'function' then
      pcall(orchestrator.cancel, orchestrator)
    end
    chat.tool_orchestrator = nil
  end
end

local function original_method(state, key, chat)
  local slot = state and state.methods[key]
  return (slot and slot.original) or (chat and chat[key])
end

local function emit_status(chat, state, message)
  local add_message = original_method(state, 'add_buf_message', chat)
  if type(add_message) ~= 'function' then
    return
  end
  pcall(add_message, chat, {
    role = 'system',
    content = message,
  }, {
    type = chat.MESSAGE_TYPES and chat.MESSAGE_TYPES.SYSTEM_MESSAGE or nil,
  })
end

local function emit_unsupported(chat, state)
  if unsupported_notified[chat] then
    return
  end
  unsupported_notified[chat] = true
  emit_status(chat, state, 'Structured reasoning lifecycle control requires an HTTP adapter; this chat is blocked.')
end

local function block_boundary(chat, state, issue, message)
  if state.boundary_issue == issue then
    return
  end
  state.boundary_issue = issue
  invalidate_runtime(state, chat)
  emit_status(chat, state, message)
end

local function format_handler_slot(adapter)
  local handlers = type(adapter) == 'table' and adapter.handlers or nil
  if type(handlers) ~= 'table' then
    return
  end
  local uses_new_handlers = handlers.lifecycle ~= nil or handlers.request ~= nil or handlers.response ~= nil
  if uses_new_handlers then
    for _, category in ipairs({ 'lifecycle', 'request', 'response', 'tools' }) do
      local target = handlers[category]
      if type(target) == 'table' and type(target.format_calls) == 'function' then
        return capture_method(target, 'format_calls')
      end
    end
    return
  end
  if type(handlers.tools) == 'table' and type(handlers.tools.format_tool_calls) == 'function' then
    return capture_method(handlers.tools, 'format_tool_calls')
  end
  if type(handlers.format_tool_calls) == 'function' then
    return capture_method(handlers, 'format_tool_calls')
  end
end

local function callbacks_allowed(chat, state)
  if
    state.closed
    or state.unsupported_adapter
    or state.clearing
    or state.boundary_issue ~= nil
    or not chat.adapter
    or chat.adapter.type ~= 'http'
    or not live_tools_match(chat, state)
    or not wrappers_intact(state)
  then
    return false
  end
  if state.phase == 'dormant' then
    return not complete_tool_set(chat)
  end
  return complete_tool_set(chat)
end

local function install_format_guard(chat, state)
  local slot = format_handler_slot(chat.adapter)
  if not slot then
    return
  end
  install_wrapper(slot, function(adapter, ...)
    local values = packed(slot.original(adapter, ...))
    if not live_tools_match(chat, state) or not wrappers_intact(state) then
      block_boundary(
        chat,
        state,
        'method_ownership',
        'Structured reasoning is blocked because its controlled host methods changed; recreate this chat.'
      )
      return nil
    end
    return unpack(values, 1, values.n)
  end)
  return slot
end

local function tuple_part(value)
  local text = type(value) == 'string' and value or ''
  return #text .. ':' .. text
end

local function call_tuple(call)
  local fn = type(call) == 'table' and call['function'] or nil
  return table.concat({
    tuple_part(type(call) == 'table' and call.id or nil),
    tuple_part(type(call) == 'table' and call.call_id or nil),
    tuple_part(type(fn) == 'table' and fn.name or nil),
  }, '|')
end

local function artifact_ids_before(workspace)
  local ids = {}
  for id in pairs(workspace and workspace.artifacts_by_id or {}) do
    ids[id] = true
  end
  return ids
end

local function bind_call_markers(state, chat, calls)
  local workspace = State.get(chat)
  local bucket = state.observed_call_ids[state.request_generation]
  if not bucket then
    bucket = {}
    state.observed_call_ids[state.request_generation] = bucket
  end
  local reasoning = {}
  for _, call in ipairs(calls) do
    if type(call) == 'table' then
      local fn = type(call['function']) == 'table' and call['function'] or {}
      local name = fn.name
      local operation = Constants.operation_by_tool[name]
      local arguments = fn.arguments
      local decoded = arguments
      local malformed_json = false
      if operation and type(arguments) == 'string' then
        local candidate = arguments == '' and '{}' or arguments
        local ok
        ok, decoded = pcall(vim.json.decode, candidate)
        malformed_json = not ok
      end
      local marker = {
        valid = true,
        status = operation and (malformed_json and 'malformed_pending' or 'executing') or 'external',
        epoch = state.epoch,
        generation = state.request_generation,
        request_token = state.active_request_token,
        operation = operation,
        action = type(decoded) == 'table' and decoded.action or nil,
        decoded_arguments = decoded,
        arguments_malformed = malformed_json,
        arguments_invalid = operation ~= nil and type(arguments) ~= 'table' and type(arguments) ~= 'string',
        workspace = workspace,
        workspace_id = workspace and workspace.id or nil,
        revision = workspace and workspace.revision or nil,
        artifact_ids_before = artifact_ids_before(workspace),
      }
      state.call_tokens[call] = marker
      if operation then
        local id = call.id
        if type(id) == 'string' and id ~= '' then
          marker.duplicate = bucket[id] ~= nil
          bucket[id] = bucket[id] or marker
        end
        table.insert(reasoning, { call = call, marker = marker, name = name })
      end
    end
  end
  return reasoning, bucket
end

local function new_executing_scope(state, calls)
  local scope = {
    valid = true,
    epoch = state.epoch,
    generation = state.request_generation,
    by_tuple = {},
  }
  for _, call in ipairs(calls) do
    if type(call) == 'table' then
      local marker = state.call_tokens[call]
      if marker then
        local key = call_tuple(call)
        scope.by_tuple[key] = scope.by_tuple[key] or {}
        table.insert(scope.by_tuple[key], { marker = marker, claimed = false })
      end
    end
  end
  return scope
end

local function claim_scope_marker(state, call, marker)
  local scope = state.executing_scope
  if not scope or not scope.valid then
    return marker
  end
  local entries = scope.by_tuple[call_tuple(call)] or {}
  if marker then
    for _, entry in ipairs(entries) do
      if entry.marker == marker and not entry.claimed then
        entry.claimed = true
        break
      end
    end
    return marker
  end
  if scope.epoch ~= state.epoch or scope.generation ~= state.request_generation then
    return
  end
  for _, entry in ipairs(entries) do
    if not entry.claimed then
      entry.claimed = true
      state.call_tokens[call] = entry.marker
      return entry.marker
    end
  end
end

local function message_snapshot(chat)
  local snapshot = {}
  for index, message in ipairs(chat.messages or {}) do
    snapshot[index] = type(message.content) == 'string' and message.content or nil
  end
  return snapshot
end

local function recorded_delta(chat, before)
  local changed = {}
  for index, message in ipairs(chat.messages or {}) do
    local after = type(message.content) == 'string' and message.content or nil
    local prior = before[index]
    if after ~= prior and after ~= nil then
      local delta = after
      if type(prior) == 'string' and after:sub(1, #prior) == prior then
        delta = after:sub(#prior + 1):gsub('^\n\n', '')
      end
      table.insert(changed, { index = index, prior = prior, content = delta })
    end
  end
  return changed
end

local function internal_settlement_payload(state)
  return Protocol.failure(
    'internal_error',
    'reasoning synthetic settlement was rewritten',
    {},
    Protocol.transition(State.get(chat_for(state)), state.phase)
      or { tool = 'none', reason = 'Wait for explicit user recovery' }
  ).data
end

local function replace_recorded_delta(chat, changed, call_id, payload)
  local encoded = assert(vim.json.encode(payload))
  local entry = changed[1]
  if entry and chat.messages[entry.index] then
    chat.messages[entry.index].content = type(entry.prior) == 'string'
        and (entry.prior .. (entry.prior == '' and '' or '\n\n') .. encoded)
      or encoded
    return
  end
  table.insert(chat.messages, {
    role = 'tool',
    tool_call_id = call_id,
    content = encoded,
  })
end

local function record_and_verify_synthetic(state, marker, tool, payload)
  local chat = chat_for(state)
  if not chat then
    return false
  end
  local before = message_snapshot(chat)
  local encoded = assert(vim.json.encode(payload))
  local ok = pcall(function()
    chat:add_tool_output(tool, encoded, '')
  end)
  local changed = recorded_delta(chat, before)
  local verified = false
  if ok and #changed == 1 then
    local decoded_ok, decoded = pcall(vim.json.decode, changed[1].content)
    verified = decoded_ok and vim.deep_equal(decoded, payload)
  end
  marker.status = 'synthetic'
  if not verified then
    replace_recorded_delta(
      chat,
      changed,
      tool.function_call and tool.function_call.id,
      internal_settlement_payload(state)
    )
  end
  return verified
end

local function settlement_tool(state, marker, call)
  local fn = type(call['function']) == 'table' and call['function'] or {}
  local name = type(fn.name) == 'string' and fn.name ~= '' and fn.name or 'unknown'
  local safe_call = {
    id = call.id,
    call_id = call.call_id,
    type = type(call.type) == 'string' and call.type or 'function',
    ['function'] = {
      name = name,
      arguments = {},
    },
  }
  state.call_tokens[safe_call] = marker
  return {
    name = name,
    function_call = safe_call,
  }
end

local function halt_internal(state, message)
  state.fallback_lease = nil
  state.resume_phase = state.phase
  state.phase = 'halted'
  local chat = chat_for(state)
  if chat then
    if chat.subscribers and type(chat.subscribers.stop) == 'function' then
      chat.subscribers:stop()
    end
    emit_status(chat, state, message)
  end
end

local function settle_rejected_batch(state, tools, chat, calls, payload, count_violation)
  tools.chat = chat
  tools.status = tools.constants and tools.constants.STATUS_ERROR or 'error'
  local bucket = state.observed_call_ids[state.request_generation] or {}
  state.observed_call_ids[state.request_generation] = bucket
  local scope = new_executing_scope(state, calls)
  scope.settling = true
  state.executing_scope = scope
  local seen = {}
  local verified = true
  for _, call in ipairs(calls) do
    if type(call) == 'table' then
      local marker = assert(state.call_tokens[call], 'formatted call marker is missing')
      marker.status = 'synthetic_pending'
      local id = call.id
      if type(id) == 'string' and id ~= '' then
        bucket[id] = bucket[id] or marker
      end
    end
  end
  for _, call in ipairs(calls) do
    if type(call) == 'table' then
      local marker = state.call_tokens[call]
      local id = call.id
      if type(id) == 'string' and id ~= '' and not seen[id] then
        seen[id] = true
        scope.current_marker = marker
        local recorded = record_and_verify_synthetic(state, marker, settlement_tool(state, marker, call), payload)
        scope.current_marker = nil
        verified = recorded and verified
      end
    end
  end
  for _, call in ipairs(calls) do
    local marker = type(call) == 'table' and state.call_tokens[call] or nil
    if marker then
      marker.status = 'synthetic'
    end
  end
  if not verified then
    halt_internal(state, 'reasoning synthetic settlement was rewritten')
  elseif count_violation then
    state.consecutive_violations = math.min(3, state.consecutive_violations + 1)
  end
  local ok, result = xpcall(function()
    return tools:reset({ auto_submit = false })
  end, debug.traceback)
  scope.valid = false
  if state.executing_scope == scope then
    state.executing_scope = nil
  end
  if not ok then
    error(result, 0)
  end
  return verified
end

local function transition_failure(operation, chat, args, phase, actual_tool)
  if phase == 'finalized' then
    return Protocol.call('evidence', chat, {}, phase).data
  end
  if operation then
    local result = Protocol.call(operation, chat, args, phase)
    if result.status == 'error' then
      return result.data
    end
  end
  local expected = Protocol.transition(State.get(chat), phase)
    or { tool = 'none', reason = 'Reasoning lifecycle enforcement is unavailable' }
  return Protocol.failure(
    'transition_invalid',
    'the reasoning operation does not match the authoritative transition',
    {},
    expected,
    {
      path = 'tool',
      constraint = 'authoritative_transition',
      expected = expected.tool,
      actual = actual_tool or (operation and Constants.tool_by_operation[operation]) or 'unknown_operation',
    }
  ).data
end

local function delegate_execute(state, calls, callback)
  local scope = new_executing_scope(state, calls)
  state.executing_scope = scope
  local ok, values = xpcall(function()
    return packed(callback())
  end, debug.traceback)
  scope.valid = false
  if state.executing_scope == scope then
    state.executing_scope = nil
  end
  if not ok then
    error(values, 0)
  end
  return unpack(values, 1, values.n)
end

local function preflight_execute(state, tools, chat, calls, callback)
  if state.phase == 'dormant' or type(calls) ~= 'table' then
    return callback()
  end
  local reasoning = bind_call_markers(state, chat, calls)
  local terminal = state.phase == 'finalizing' or state.phase == 'halted' or state.phase == 'finalized'
  if terminal then
    local first = reasoning[1]
    local first_call = first and first.call or calls[1]
    local fn = type(first_call) == 'table' and first_call['function'] or {}
    local payload = transition_failure(
      first and first.marker.operation or nil,
      chat,
      first and first.marker.decoded_arguments or {},
      state.phase,
      type(fn) == 'table' and fn.name or 'unknown_operation'
    )
    return settle_rejected_batch(state, tools, chat, calls, payload, false)
  end
  if #reasoning == 0 then
    return delegate_execute(state, calls, callback)
  end
  if #reasoning ~= 1 or #calls ~= 1 then
    local payload = Protocol.failure(
      'reasoning_batch_invalid',
      'a reasoning completion must contain exactly one reasoning tool call',
      {},
      Protocol.transition(State.get(chat), state.phase),
      {
        path = 'tool_calls',
        constraint = 'sole_reasoning_call',
        expected = 1,
        actual = #calls,
      }
    ).data
    return settle_rejected_batch(state, tools, chat, calls, payload, true)
  end

  local item = reasoning[1]
  local marker = item.marker
  if marker.arguments_invalid then
    local payload = Protocol.failure(
      'reasoning_call_malformed',
      'reasoning tool arguments must be a table or JSON string',
      {},
      Protocol.transition(State.get(chat), state.phase),
      { path = 'tool_calls[1].function.arguments', constraint = 'table_or_json_string' }
    ).data
    return settle_rejected_batch(state, tools, chat, calls, payload, true)
  end
  if marker.arguments_malformed then
    return delegate_execute(state, calls, callback)
  end
  if marker.duplicate then
    local payload = Protocol.failure(
      'reasoning_call_duplicate',
      'the reasoning call ID was already observed in this request generation',
      {},
      Protocol.transition(State.get(chat), state.phase),
      { path = 'tool_calls[1].id', constraint = 'unique_per_generation', actual = item.call.id }
    ).data
    return settle_rejected_batch(state, tools, chat, calls, payload, true)
  end
  local allowed = state.phase ~= 'finalized'
    and Transition.allowed(marker.workspace, state.phase, marker.operation, marker.decoded_arguments)
  if not allowed then
    local payload = transition_failure(marker.operation, chat, marker.decoded_arguments, state.phase, item.name)
    return settle_rejected_batch(state, tools, chat, calls, payload, true)
  end
  return delegate_execute(state, calls, callback)
end

local function configured_target_is_acp(chat)
  local configured = vim.g.codecompanion_adapter
  if type(configured) ~= 'string' or configured == '' or (chat.adapter and chat.adapter.name == configured) then
    return false
  end
  local ok, resolved = pcall(function()
    local config = require('codecompanion.config')
    return require('codecompanion.adapters').resolve(config.adapters[configured])
  end)
  return ok and type(resolved) == 'table' and resolved.type == 'acp'
end

local function blocked_submit(chat, opts)
  if type(opts) == 'table' and type(opts.callback) == 'function' then
    opts.callback()
    return
  end
  if type(chat.restore) == 'function' then
    return chat:restore()
  end
end

local function pass_through(slot)
  return function(target, ...)
    return slot.original(target, ...)
  end
end

local function install(chat, phase)
  local state = new_state(chat, phase)
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
    state.methods[key] = capture_method(chat, key)
  end
  state.methods.execute = capture_method(chat.tools, 'execute')
  controllers[chat] = state

  local submit = state.methods.submit
  install_wrapper(submit, function(target, opts, ...)
    local current = chat_for(state)
    if not current or current ~= target then
      return
    end
    M.reconcile(current)
    if
      state.closed
      or state.unsupported_adapter
      or state.boundary_issue ~= nil
      or not complete_tool_set(current)
      or not live_tools_match(current, state)
      or not wrappers_intact(state)
      or not current.adapter
      or current.adapter.type ~= 'http'
      or current.tool_orchestrator ~= nil
      or state.active_request_token ~= nil
      or state.construction_lease ~= nil
      or state.executing_scope ~= nil
      or state.clearing
      or state.processing_done
      or state.submitting
    then
      return blocked_submit(current, opts)
    end

    local extra = packed(...)
    state.submitting = true
    local ok, values = xpcall(function()
      return packed(submit.original(current, opts, unpack(extra, 1, extra.n)))
    end, debug.traceback)
    state.submitting = false
    state.request_handle = current.current_request
    if not ok then
      error(values, 0)
    end
    return unpack(values, 1, values.n)
  end)

  local submit_http = state.methods._submit_http
  install_wrapper(submit_http, function(target, payload, ...)
    local current = chat_for(state)
    if not current or current ~= target then
      return
    end
    M.reconcile(current)
    if
      state.closed
      or state.unsupported_adapter
      or state.boundary_issue ~= nil
      or not complete_tool_set(current)
      or not live_tools_match(current, state)
      or not wrappers_intact(state)
      or not current.adapter
      or current.adapter.type ~= 'http'
      or state.executing_scope ~= nil
    then
      return blocked_submit(current)
    end
    return submit_http.original(current, payload, ...)
  end)

  local submit_acp = state.methods._submit_acp
  install_wrapper(submit_acp, function(target)
    local current = chat_for(state)
    if not current or current ~= target then
      return
    end
    M.reconcile(current)
    return blocked_submit(current)
  end)

  local done = state.methods.done
  install_wrapper(done, function(target, ...)
    if state.processing_done or not callbacks_allowed(target, state) then
      return
    end
    local extra = packed(...)
    local has_tools = type(extra[3]) == 'table' and not vim.tbl_isempty(extra[3])
    if suppressing_phase[state.phase] then
      extra[1] = nil
      extra[2] = nil
      local done_opts = extra[5]
      if not has_tools and not (type(done_opts) == 'table' and done_opts.status ~= nil) then
        extra[4] = nil
      end
    end
    state.processing_done = true
    local format_slot = extra[3] ~= nil and install_format_guard(target, state) or nil
    local ok, values = xpcall(function()
      return packed(done.original(target, unpack(extra, 1, extra.n)))
    end, debug.traceback)
    if format_slot then
      restore_method(format_slot)
    end
    if state.boundary_issue == nil and (not live_tools_match(target, state) or not wrappers_intact(state)) then
      block_boundary(
        target,
        state,
        'method_ownership',
        'Structured reasoning is blocked because its controlled host methods changed; recreate this chat.'
      )
    end
    state.processing_done = false
    if target.current_request == nil then
      state.request_handle = nil
    end
    if not ok then
      error(values, 0)
    end
    return unpack(values, 1, values.n)
  end)

  local add_buf_message = state.methods.add_buf_message
  install_wrapper(add_buf_message, function(target, data, opts, ...)
    local kind = type(opts) == 'table' and opts.type or nil
    local scope = state.executing_scope
    if
      not state.closed
      and (
        (
          suppressing_phase[state.phase]
          and (kind == target.MESSAGE_TYPES.LLM_MESSAGE or kind == target.MESSAGE_TYPES.REASONING_MESSAGE)
        ) or (scope and scope.settling and kind == target.MESSAGE_TYPES.TOOL_MESSAGE)
      )
    then
      return
    end
    return add_buf_message.original(target, data, opts, ...)
  end)

  local add_tool_output = state.methods.add_tool_output
  install_wrapper(add_tool_output, function(target, tool, ...)
    local call = type(tool) == 'table' and tool.function_call or nil
    local marker = type(call) == 'table' and claim_scope_marker(state, call, state.call_tokens[call]) or nil
    local scope = state.executing_scope
    if scope and scope.settling then
      local current = chat_for(state)
      if
        not current
        or target ~= current
        or state.closed
        or state.unsupported_adapter
        or not current.adapter
        or current.adapter.type ~= 'http'
        or not live_tools_match(current, state)
        or not wrappers_intact(state)
        or not marker
        or marker.status ~= 'synthetic_pending'
        or marker ~= scope.current_marker
        or scope.output_active
      then
        return
      end
      scope.output_active = true
      local extra = packed(...)
      local ok, values = xpcall(function()
        return packed(add_tool_output.original(target, tool, unpack(extra, 1, extra.n)))
      end, debug.traceback)
      scope.output_active = false
      if not ok then
        error(values, 0)
      end
      return unpack(values, 1, values.n)
    elseif not callbacks_allowed(target, state) then
      return
    end
    if marker and marker.status == 'synthetic' then
      return
    end
    return add_tool_output.original(target, tool, ...)
  end)

  local clear = state.methods.clear
  install_wrapper(clear, function(target, ...)
    if state.clearing then
      return clear.original(target, ...)
    end
    state.clearing = true
    invalidate_runtime(state, target)
    State.clear(target)
    state.phase = 'dormant'
    state.suspended_phase = nil
    state.resume_phase = 'active'
    state.boundary_issue = nil
    local extra = packed(...)
    local ok, values = xpcall(function()
      return packed(clear.original(target, unpack(extra, 1, extra.n)))
    end, debug.traceback)
    state.clearing = false
    if not ok then
      error(values, 0)
    end
    return unpack(values, 1, values.n)
  end)

  local close = state.methods.close
  install_wrapper(close, function(target, ...)
    if state.closed then
      return
    end
    state.closed = true
    local host_will_stop = target.current_request ~= nil
    invalidate_runtime(state, target, {
      preserve_host_request = host_will_stop,
      preserve_host_orchestrator = host_will_stop,
    })
    return close.original(target, ...)
  end)

  local execute = state.methods.execute
  install_wrapper(execute, function(target, host_chat, calls, ...)
    local current = chat_for(state)
    if
      not current
      or host_chat ~= current
      or target ~= current.tools
      or state.executing_scope ~= nil
      or current.tool_orchestrator ~= nil
    then
      return
    end
    M.reconcile(current)
    if
      state.closed
      or state.unsupported_adapter
      or not current.adapter
      or current.adapter.type ~= 'http'
      or not live_tools_match(current, state)
      or not wrappers_intact(state)
    then
      return
    end
    if not complete_tool_set(current) then
      local batch = type(calls) == 'table' and calls or {}
      bind_call_markers(state, current, batch)
      local attached = attached_tool_set(current)
      local code = attached and 'reasoning_tool_ownership' or 'reasoning_tools_incomplete'
      local message = attached
          and 'structured reasoning is blocked because a runtime reasoning tool registration changed'
        or 'structured reasoning is blocked until every reasoning tool is reattached'
      local payload = Protocol.failure(
        code,
        message,
        {},
        { tool = 'none', reason = 'Restore the authentic complete reasoning tool group before continuing' },
        { path = 'tools', constraint = attached and 'authentic_reasoning_tool_set' or 'complete_reasoning_tool_set' }
      ).data
      return settle_rejected_batch(state, target, current, batch, payload, false)
    end
    if not callbacks_allowed(current, state) then
      return
    end
    local extra = packed(...)
    return preflight_execute(state, target, current, calls, function()
      return execute.original(target, current, calls, unpack(extra, 1, extra.n))
    end)
  end)

  local on_before_submit = function(callback_chat)
    local current = chat_for(state)
    if not current or callback_chat ~= current then
      return false
    end
    M.reconcile(current)
    if
      state.closed
      or state.unsupported_adapter
      or state.boundary_issue ~= nil
      or not complete_tool_set(current)
      or not live_tools_match(current, state)
      or not wrappers_intact(state)
      or not current.adapter
      or current.adapter.type ~= 'http'
      or configured_target_is_acp(current)
    then
      if configured_target_is_acp(current) then
        emit_unsupported(current, state)
      end
      return false
    end
    return true
  end
  state.callbacks.on_before_submit = on_before_submit
  chat:add_callback('on_before_submit', on_before_submit)
  return state
end

function M.setup_autocmds()
  local group = vim.api.nvim_create_augroup(Constants.augroup, { clear = true })
  vim.api.nvim_create_autocmd('User', {
    group = group,
    pattern = {
      'CodeCompanionChatToolAdded',
      'CodeCompanionChatAdapter',
      'CodeCompanionChatCleared',
    },
    callback = function(event)
      local bufnr = event.data and event.data.bufnr
      local chat = type(bufnr) == 'number' and require('codecompanion').buf_get_chat(bufnr) or nil
      if not chat then
        return
      end
      if event.match == 'CodeCompanionChatCleared' then
        M.clear(chat)
      else
        M.reconcile(chat)
      end
    end,
  })
end

function M.reconcile(chat)
  if type(chat) ~= 'table' then
    return
  end
  local state = controllers[chat]
  if state and state.closed then
    return state
  end
  local attached = attached_tool_set(chat)
  local owned = attached and reasoning_tools_owned(chat)
  local complete = attached and owned
  if attached then
    Terminal.clear(chat)
  elseif not state then
    return
  end

  local adapter_type = chat.adapter and chat.adapter.type or 'unsupported'
  if not state then
    if adapter_type ~= 'http' then
      emit_unsupported(chat)
      return
    end
    unsupported_notified[chat] = nil
    state = install(chat, hydrated_phase(chat))
    if not owned then
      block_boundary(
        chat,
        state,
        'tool_ownership',
        'Structured reasoning is blocked because a runtime reasoning tool registration changed; recreate this chat.'
      )
    end
    return state
  end

  if adapter_type ~= 'http' then
    if not state.unsupported_adapter then
      local suspended = state.phase
      if suspended == 'finalizing' then
        state.phase = 'halted'
        state.resume_phase = 'active'
        suspended = 'halted'
      end
      state.suspended_phase = suspended
      state.unsupported_adapter = true
      invalidate_runtime(state, chat)
      emit_unsupported(chat, state)
    end
    return state
  end

  if state.unsupported_adapter then
    if not complete or not live_tools_match(chat, state) or not wrappers_intact(state) then
      return state
    end
    local restored = state.suspended_phase or hydrated_phase(chat)
    if restored == 'finalizing' and state.staged_final == nil then
      restored = 'halted'
      state.resume_phase = 'active'
    end
    state.phase = restored
    state.suspended_phase = nil
    state.unsupported_adapter = false
    unsupported_notified[chat] = nil
  end

  if not attached then
    block_boundary(
      chat,
      state,
      'tools_incomplete',
      'Structured reasoning is blocked until all reasoning tools are reattached.'
    )
    return state
  end
  if not owned then
    block_boundary(
      chat,
      state,
      'tool_ownership',
      'Structured reasoning is blocked because a runtime reasoning tool registration changed; recreate this chat.'
    )
    return state
  end
  if not live_tools_match(chat, state) or not wrappers_intact(state) then
    block_boundary(
      chat,
      state,
      'method_ownership',
      'Structured reasoning is blocked because its controlled host methods changed; recreate this chat.'
    )
    return state
  end
  state.boundary_issue = nil

  if state.phase == 'dormant' and complete and live_tools_match(chat, state) then
    state.phase = hydrated_phase(chat)
  end
  return state
end

function M.phase(chat)
  local state = controllers[chat]
  local attached = attached_tool_set(chat)
  local complete = complete_tool_set(chat)
  if not state then
    return attached and 'blocked' or nil
  end
  if not state.closed then
    local adapter_type = chat.adapter and chat.adapter.type or 'unsupported'
    if adapter_type ~= 'http' or state.unsupported_adapter then
      M.reconcile(chat)
    end
  end
  if
    state.closed
    or state.unsupported_adapter
    or state.boundary_issue ~= nil
    or not chat.adapter
    or chat.adapter.type ~= 'http'
    or not live_tools_match(chat, state)
    or not wrappers_intact(state)
  then
    return 'blocked'
  end
  if state.phase == 'dormant' then
    return complete and 'blocked' or nil
  end
  return complete and state.phase or 'blocked'
end

function M.legacy_terminal_allowed(chat)
  if attached_tool_set(chat) then
    return false
  end
  local state = controllers[chat]
  if not state then
    return true
  end
  return not state.closed
    and not state.unsupported_adapter
    and state.boundary_issue == nil
    and live_tools_match(chat, state)
    and wrappers_intact(state)
    and state.phase == 'dormant'
end

function M.stage_final()
  return nil, 'not available in this lifecycle build'
end

function M.resume()
  return nil, 'not available in this lifecycle build'
end

function M.clear(chat)
  State.clear(chat)
  local state = controllers[chat]
  if state then
    if not state.clearing then
      invalidate_runtime(state, chat)
    end
    state.phase = 'dormant'
    state.suspended_phase = nil
    state.resume_phase = 'active'
    state.boundary_issue = nil
  end
end

function M.uninstall(chat)
  local state = controllers[chat]
  if not state then
    return false
  end
  Terminal.clear(chat)
  local callback = state.callbacks.on_before_submit
  if callback and type(chat.remove_callback) == 'function' then
    chat:remove_callback('on_before_submit', callback)
  end
  for _, slot in pairs(state.methods) do
    restore_method(slot)
  end
  controllers[chat] = nil
  unsupported_notified[chat] = nil
  return true
end

function M._get(chat)
  return controllers[chat]
end

function M._count()
  local count = 0
  for _ in pairs(controllers) do
    count = count + 1
  end
  return count
end

function M._reset()
  local chats = {}
  for chat in pairs(controllers) do
    table.insert(chats, chat)
  end
  for _, chat in ipairs(chats) do
    local state = controllers[chat]
    if state then
      invalidate_runtime(state, chat)
    end
    M.uninstall(chat)
  end
  controllers = setmetatable({}, { __mode = 'k' })
  unsupported_notified = setmetatable({}, { __mode = 'k' })
end

return M
