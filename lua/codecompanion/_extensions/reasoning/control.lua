local Constants = require('codecompanion._extensions.reasoning.constants')
local Adapters = require('codecompanion.adapters')
local HostConfig = require('codecompanion.config')
local Guidance = require('codecompanion._extensions.reasoning.guidance')
local Protocol = require('codecompanion._extensions.reasoning.protocol')
local State = require('codecompanion._extensions.reasoning.state')
local Terminal = require('codecompanion._extensions.reasoning.terminal')
local Transition = require('codecompanion._extensions.reasoning.transition')
local Hash = require('codecompanion.utils.hash')
local log = require('codecompanion.utils.log')
local owns_tool_config = require('codecompanion._extensions.reasoning').owns_tool_config

local M = {}
local controllers = setmetatable({}, { __mode = 'k' })
local unsupported_notified = setmetatable({}, { __mode = 'k' })
local terminal_guard_key = '_codecompanion_reasoning_terminal_guard'
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
    closed_cleaned = false,
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
    clear_during_submit = false,
    invalidated_submissions = setmetatable({}, { __mode = 'k' }),
    dormant_submit_stack = {},
    protected_submit_depth = 0,
    submit_epoch = nil,
    submit_prior_violations = nil,
    clearing = false,
    processing_done = false,
    boundary_issue = nil,
    halt_notified = false,
    resume_command = nil,
    resume_command_installed = false,
    methods = {},
    callbacks = {},
  }
end

local function chat_for(state)
  return state.chat_ref[1]
end

local function delete_resume_command(state)
  if not state then
    return
  end
  local command = state.resume_command or {}
  local bufnr = command.bufnr
  if state.resume_command_installed and type(bufnr) == 'number' and vim.api.nvim_buf_is_valid(bufnr) then
    pcall(vim.api.nvim_buf_del_user_command, bufnr, command.name or Constants.resume_command)
  end
  state.resume_command_installed = false
  state.resume_command = nil
end

local function remove_controller_callbacks(state, chat)
  if type(chat.remove_callback) ~= 'function' then
    return
  end
  for event, callback in pairs(state.callbacks) do
    chat:remove_callback(event, callback)
  end
end

local function resume_command_present(state)
  local command = state and state.resume_command or nil
  if not state or not state.resume_command_installed or type(command) ~= 'table' then
    return false
  end
  local bufnr = command.bufnr
  if type(bufnr) ~= 'number' or not vim.api.nvim_buf_is_valid(bufnr) then
    return false
  end
  local ok, commands = pcall(vim.api.nvim_buf_get_commands, bufnr, {})
  return ok and type(commands) == 'table' and commands[command.name] ~= nil
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

local function dormant_passthrough(state, chat)
  return not state.closed and not state.clearing and state.phase == 'dormant' and not attached_tool_set(chat)
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

local function wrappers_owned_for_uninstall(state, chat)
  if not state or not live_tools_match(chat, state) then
    return false
  end
  local guard = rawget(chat, terminal_guard_key)
  for _, slot in pairs(state.methods) do
    local target = slot.target_ref[1]
    local current = target and rawget(target, slot.key) or nil
    if current ~= slot.wrapper then
      local terminal_overlay = slot.key == 'submit'
        and target == chat
        and type(guard) == 'table'
        and current == guard.wrapper
        and guard.original == slot.wrapper
        and guard.had_raw_submit == true
      if not terminal_overlay then
        return false
      end
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
    marker.invalidated = true
  end
end

local function discard_stage(state)
  if state.staged_final then
    local final = state.staged_final
    State.discard_final(final.stage or final)
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
  state.resume_attempt = nil
  state.observed_call_ids = {}
  state.completion_classified = true
  state.consecutive_violations = 0
  state.halt_notified = false
  state.request_generation = state.request_generation + 1
  state.epoch = state.epoch + 1
  state.submitting = false
  state.submit_epoch = nil
  state.submit_prior_violations = nil
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

local function reset_for_clear(state, chat)
  local token = state.active_request_token
  local pending = state.pending_stop_token
  local construction = state.construction_lease

  invalidate_marker(token)
  invalidate_marker(pending)
  invalidate_marker(pending and pending.token)
  invalidate_marker(construction)
  if construction then
    construction.consumed = true
    if type(construction.payload) == 'table' then
      state.invalidated_submissions[construction.payload] = true
    end
  end
  invalidate_marker(state.fallback_lease)
  invalidate_marker(state.resume_attempt)
  invalidate_marker(state.executing_scope)
  for _, marker in pairs(state.call_tokens) do
    invalidate_marker(marker)
  end
  for _, lease in ipairs(state.dormant_submit_stack) do
    invalidate_marker(lease)
    for payload in pairs(lease.payloads) do
      state.invalidated_submissions[payload] = true
    end
  end

  state.active_request_token = nil
  state.pending_stop_token = nil
  state.construction_lease = nil
  state.fallback_lease = nil
  state.resume_attempt = nil
  state.executing_scope = nil
  Terminal.clear(chat)
  state.epoch = state.epoch + 1
  state.clear_during_submit = state.submitting or state.protected_submit_depth > 0 or #state.dormant_submit_stack > 0
  state.submitting = false
  state.submit_epoch = nil
  state.submit_prior_violations = nil
  state.completion_classified = true
  state.processing_done = false
  local staged = state.staged_final
  if staged and staged.stage and staged.stage.state == 'committed' then
    pcall(State.rollback_final, chat, staged.stage)
  end
  discard_stage(state)
  if type(chat.remove_tagged_message) == 'function' then
    pcall(chat.remove_tagged_message, chat, Constants.corrective_tag)
  end

  local request = chat.current_request or (token and token.handle) or state.request_handle
  local orchestrator = chat.tool_orchestrator
  chat.current_request = nil
  chat.tool_orchestrator = nil
  state.request_handle = nil
  if request and type(request.cancel) == 'function' then
    pcall(request.cancel, request)
  end
  if orchestrator and type(orchestrator.cancel) == 'function' then
    pcall(orchestrator.cancel, orchestrator)
  end

  State.clear(chat)
  state.consecutive_violations = 0
  state.resume_phase = 'active'
  state.suspended_phase = nil
  state.unsupported_adapter = false
  state.boundary_issue = nil
  state.halt_notified = false
  state.phase = 'dormant'
  unsupported_notified[chat] = nil
  return true
end

local function begin_close(state, chat)
  if state.closed then
    return false
  end
  state.closed = true
  Terminal.clear(chat)

  local pending = state.pending_stop_token
  local construction = state.construction_lease
  invalidate_marker(state.active_request_token)
  invalidate_marker(pending)
  invalidate_marker(pending and pending.token)
  invalidate_marker(construction)
  if construction then
    construction.consumed = true
  end
  invalidate_marker(state.fallback_lease)
  invalidate_marker(state.resume_attempt)
  invalidate_marker(state.executing_scope)
  for _, marker in pairs(state.call_tokens) do
    invalidate_marker(marker)
  end
  for _, lease in ipairs(state.dormant_submit_stack) do
    invalidate_marker(lease)
  end

  state.active_request_token = nil
  state.pending_stop_token = nil
  state.construction_lease = nil
  state.fallback_lease = nil
  state.resume_attempt = nil
  state.executing_scope = nil
  state.epoch = state.epoch + 1
  state.submitting = false
  state.submit_epoch = nil
  state.submit_prior_violations = nil
  state.completion_classified = true
  state.processing_done = false
  local staged = state.staged_final
  if staged and staged.stage and staged.stage.state == 'committed' then
    pcall(State.rollback_final, chat, staged.stage)
  end
  discard_stage(state)
  if type(chat.remove_tagged_message) == 'function' then
    pcall(chat.remove_tagged_message, chat, Constants.corrective_tag)
  end
  return true
end

local function cleanup_closed(state, chat)
  if state.closed_cleaned then
    return false
  end
  local orchestrator = chat.tool_orchestrator
  chat.tool_orchestrator = nil
  if orchestrator and type(orchestrator.cancel) == 'function' then
    pcall(orchestrator.cancel, orchestrator)
  end
  chat.current_request = nil
  state.request_handle = nil
  remove_controller_callbacks(state, chat)
  delete_resume_command(state)
  State.clear(chat)
  state.closed_cleaned = true
  return true
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
    or not resume_command_present(state)
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
        phase = state.phase,
        request_token = state.active_request_token,
        adapter = chat.adapter,
        operation = operation,
        call_id = type(call.id) == 'string' and call.id ~= '' and call.id or nil,
        response_call_id = type(call.call_id) == 'string' and call.call_id ~= '' and call.call_id or nil,
        tool_name = name,
        action = type(decoded) == 'table' and decoded.action or nil,
        decoded_arguments = decoded,
        arguments_malformed = malformed_json,
        arguments_invalid = operation ~= nil and type(arguments) ~= 'table' and type(arguments) ~= 'string',
        workspace = workspace,
        workspace_snapshot = workspace and vim.deepcopy(workspace) or nil,
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
    local message = chat.messages[entry.index]
    message.content = type(entry.prior) == 'string' and (entry.prior .. (entry.prior == '' and '' or '\n\n') .. encoded)
      or encoded
    message._meta = type(message._meta) == 'table' and message._meta or { cycle = chat.cycle }
    message._meta.id = Hash.hash({ role = message.role, content = message.content })
    return
  end
  local message = {
    role = 'tool',
    tools = { id = call_id, call_id = call_id },
    tool_call_id = call_id,
    content = encoded,
    opts = { visible = false },
    _meta = { cycle = chat.cycle },
  }
  message._meta.id = Hash.hash({ role = message.role, content = message.content })
  table.insert(chat.messages, message)
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

local function halt_internal(state, message, resume_phase)
  invalidate_marker(state.fallback_lease)
  state.fallback_lease = nil
  state.resume_phase = resume_phase or state.phase
  state.phase = 'halted'
  local chat = chat_for(state)
  if chat then
    if type(chat.remove_tagged_message) == 'function' then
      pcall(chat.remove_tagged_message, chat, Constants.corrective_tag)
    end
    if chat.subscribers and type(chat.subscribers.stop) == 'function' then
      chat.subscribers:stop()
    end
    if not state.halt_notified then
      state.halt_notified = true
      emit_status(chat, state, message)
    end
  end
end

local record_violation

local function result_matches_call(message, marker)
  if type(message) ~= 'table' or not marker.call_id then
    return false
  end
  local tools = type(message.tools) == 'table' and message.tools or {}
  if marker.response_call_id ~= nil then
    return tools.id == marker.call_id and tools.call_id == marker.response_call_id
  end
  return message.tool_call_id == marker.call_id or tools.id == marker.call_id or tools.call_id == marker.call_id
end

local function result_identity(message)
  return {
    role = message and message.role or nil,
    tool_call_id = message and message.tool_call_id or nil,
    tool_name = message and message.tool_name or nil,
    tools = type(message) == 'table' and vim.deepcopy(message.tools) or nil,
  }
end

local function overwrite_table(target, snapshot)
  if type(target) ~= 'table' or type(snapshot) ~= 'table' then
    return false
  end
  local restored = vim.deepcopy(snapshot)
  for key in pairs(target) do
    target[key] = nil
  end
  for key, value in pairs(restored) do
    target[key] = value
  end
  return vim.deep_equal(target, snapshot)
end

local function snapshot_recorded_result(chat, marker)
  local messages = type(chat.messages) == 'table' and chat.messages or {}
  local snapshot = {
    messages = messages,
    value = vim.deepcopy(messages),
    refs = {},
    order = {},
    values = {},
    contents = {},
    existing = nil,
    content = nil,
    identity = nil,
  }
  for index, message in ipairs(messages) do
    snapshot.refs[message] = true
    snapshot.order[index] = message
    snapshot.values[index] = vim.deepcopy(message)
    snapshot.contents[message] = message.content
    if not snapshot.existing and result_matches_call(message, marker) then
      snapshot.existing = message
      snapshot.content = message.content
      snapshot.identity = result_identity(message)
    end
  end
  return snapshot
end

local function recorded_history_intact(chat, snapshot)
  if chat.messages ~= snapshot.messages or #chat.messages < #snapshot.order then
    return false
  end
  for index, message in ipairs(snapshot.order) do
    if chat.messages[index] ~= message then
      return false
    end
    if message ~= snapshot.existing and not vim.deep_equal(message, snapshot.values[index]) then
      return false
    end
  end
  return true
end

local function restore_recorded_history(chat, snapshot)
  if not overwrite_table(snapshot.messages, snapshot.value) then
    return false
  end
  for index, message in ipairs(snapshot.order) do
    if type(message) == 'table' and not overwrite_table(message, snapshot.values[index]) then
      return false
    end
    snapshot.messages[index] = message
  end
  chat.messages = snapshot.messages
  return vim.deep_equal(chat.messages, snapshot.value)
end

local function recorded_result_entry(chat, marker, snapshot)
  local candidates = {}
  local correlated = {}
  local existing_present = snapshot.existing == nil
  local existing_changed = snapshot.existing == nil
  for _, message in ipairs(chat.messages or {}) do
    if message == snapshot.existing then
      existing_present = true
    end
    local prior = snapshot.contents[message]
    local changed = not snapshot.refs[message] or message.content ~= prior
    if changed then
      local entry = {
        message = message,
        prefix = '',
        delta = message.content,
        is_new = not snapshot.refs[message],
        prior = prior,
        reused = message == snapshot.existing,
        identity_before = message == snapshot.existing and snapshot.identity or nil,
      }
      existing_changed = existing_changed or message == snapshot.existing
      if type(message.content) ~= 'string' then
        entry.error = 'result_content_invalid'
      elseif snapshot.refs[message] then
        local prefix = type(prior) == 'string' and (prior == '' and '' or prior .. '\n\n') or nil
        entry.prefix = prefix or ''
        if not prefix or message.content:sub(1, #prefix) ~= prefix then
          entry.error = 'append_prefix_changed'
        else
          entry.delta = message.content:sub(#prefix + 1)
        end
      end
      table.insert(candidates, entry)
      if result_matches_call(message, marker) then
        table.insert(correlated, entry)
      end
    end
  end
  local found = correlated[1] or (#candidates == 1 and candidates[1] or nil)
  if not recorded_history_intact(chat, snapshot) then
    return found, 'history_boundary_changed', candidates
  end
  if not existing_present or not existing_changed then
    local before = snapshot.content
    local prefix = type(before) == 'string' and (before == '' and '' or before .. '\n\n') or ''
    return { message = existing_present and snapshot.existing or nil, prefix = prefix },
      'append_prefix_changed',
      candidates
  end
  if #candidates > 1 then
    return correlated[1], 'multiple_results', candidates
  elseif #correlated == 1 then
    found = correlated[1]
  elseif #candidates == 1 then
    found = candidates[1]
  end
  if not found or type(found.delta) ~= 'string' then
    return found, 'result_missing', candidates
  end
  if found.error then
    return found, found.error, candidates
  end
  return found, nil, candidates
end

local function stamp_result(chat, message)
  message._meta = type(message._meta) == 'table' and message._meta or {}
  message._meta.cycle = message._meta.cycle or chat.cycle
  message._meta.id = Hash.hash({ role = message.role, content = message.content })
end

local function fallback_result_message(chat, marker, encoded)
  local adapter = type(chat.adapter) == 'table' and chat.adapter or {}
  local tool_role = type(adapter.roles) == 'table' and adapter.roles.tool or 'tool'
  local call = {
    id = marker.call_id,
    call_id = marker.response_call_id,
    ['function'] = { name = marker.tool_name },
  }
  local ok, message = pcall(Adapters.call_handler, adapter, 'format_response', call, encoded)
  if
    not ok
    or type(message) ~= 'table'
    or type(message.content) ~= 'string'
    or not result_matches_call(message, marker)
  then
    message = {
      role = tool_role,
      tools = {
        id = marker.call_id,
        call_id = marker.response_call_id or marker.call_id,
        name = marker.tool_name,
      },
      tool_call_id = marker.call_id,
      content = encoded,
      opts = { visible = false },
    }
  end
  message.role = message.role or tool_role
  message.content = encoded
  message.opts = vim.tbl_extend('force', message.opts or {}, { visible = false })
  stamp_result(chat, message)
  table.insert(chat.messages, message)
  return message
end

local function rewrite_recorded_result(state, marker, entry, payload)
  local chat = chat_for(state)
  if not chat then
    return
  end
  local encoded = assert(vim.json.encode(payload))
  if entry and entry.message then
    local message = entry.message
    message.role = type(chat.adapter) == 'table' and type(chat.adapter.roles) == 'table' and chat.adapter.roles.tool
      or 'tool'
    local has_identity = false
    if type(message.tools) == 'table' then
      message.tools.id = marker.call_id
      message.tools.call_id = marker.response_call_id or marker.call_id
      message.tools.name = marker.tool_name
      has_identity = true
    end
    if message.tool_call_id ~= nil then
      message.tool_call_id = marker.call_id
      has_identity = true
    end
    if message.tool_name ~= nil then
      message.tool_name = marker.tool_name
      has_identity = true
    end
    if not has_identity then
      message.tools = {
        id = marker.call_id,
        call_id = marker.response_call_id or marker.call_id,
        name = marker.tool_name,
      }
    end
    message.content = (entry.prefix or '') .. encoded
    stamp_result(chat, message)
    return message
  end
  return fallback_result_message(chat, marker, encoded)
end

local function internal_result(state, marker, entry, message, resume_phase)
  marker.status = 'classified'
  local workspace = State.get(chat_for(state))
  local ok, transition = pcall(Protocol.transition, workspace, resume_phase or marker.phase or state.phase)
  if not ok or type(transition) ~= 'table' then
    transition = { tool = 'none', reason = 'Wait for explicit user recovery' }
  end
  local payload = Protocol.failure('internal_error', message, {}, transition).data
  rewrite_recorded_result(state, marker, entry, payload)
  halt_internal(state, 'Structured reasoning halted after an internal result-integrity failure.', resume_phase)
end

local accepted_shape = {
  frame = { primary = 'frame' },
  evidence = { primary = 'evidence', collection = 'evidence', collection_required = true },
  options = { primary = 'branch', collection = 'option', collection_required = true },
  review = { primary = 'review' },
  synthesis = { primary = 'synthesis' },
}

local function ordered_new_artifacts(workspace, marker, clean_workspace)
  local artifacts = {}
  for _, id in ipairs(workspace.artifact_order or {}) do
    if clean_workspace or not marker.artifact_ids_before[id] then
      table.insert(artifacts, workspace.artifacts_by_id[id])
    end
  end
  return artifacts
end

local function accepted_payload(state, marker, payload)
  local chat = chat_for(state)
  local workspace = chat and State.get(chat) or nil
  local shape = accepted_shape[marker.operation]
  if not workspace or not shape or type(payload) ~= 'table' then
    return false
  end
  local clean_workspace = marker.operation == 'frame' and (marker.workspace == nil or marker.action == 'replace')
  if clean_workspace then
    if workspace == marker.workspace or #workspace.artifact_order ~= 1 then
      return false
    end
  elseif workspace ~= marker.workspace then
    return false
  end

  local newly_allocated = ordered_new_artifacts(workspace, marker, clean_workspace)
  local primary = type(payload.artifact) == 'table' and State.find(workspace, payload.artifact.id) or nil
  if not primary or primary.kind ~= shape.primary or primary.status ~= 'active' then
    return false
  end
  local expected_collection
  if shape.collection_required then
    expected_collection = {}
    for _, artifact in ipairs(newly_allocated) do
      if artifact.kind == shape.collection then
        table.insert(expected_collection, artifact)
      end
    end
    if #expected_collection == 0 or not vim.deep_equal(payload.artifacts, expected_collection) then
      return false
    end
    if marker.operation == 'evidence' and primary ~= expected_collection[#expected_collection] then
      return false
    end
  elseif payload.artifacts ~= nil then
    return false
  end

  local reported = { [primary.id] = true }
  for _, artifact in ipairs(expected_collection or {}) do
    reported[artifact.id] = true
  end
  if #newly_allocated == 0 then
    return false
  end
  for _, artifact in ipairs(newly_allocated) do
    if artifact.status ~= 'active' or not reported[artifact.id] then
      return false
    end
  end
  local reported_count = 0
  for _ in pairs(reported) do
    reported_count = reported_count + 1
  end
  if reported_count ~= #newly_allocated then
    return false
  end

  local synthesis_arguments = marker.operation == 'synthesis'
      and type(marker.decoded_arguments) == 'table'
      and marker.decoded_arguments
    or nil
  local final_synthesis = synthesis_arguments and synthesis_arguments.mode == 'final'
  local expected = {
    workspace_id = workspace.id,
    artifact = vim.deepcopy(primary),
    progress = vim.deepcopy(workspace.counts_by_kind),
    unmet_gates = final_synthesis and {} or Protocol.final_gates(workspace, synthesis_arguments),
    next_action = synthesis_arguments and Guidance.next(workspace, synthesis_arguments)
      or Protocol.transition(workspace, 'active'),
  }
  if expected_collection then
    expected.artifacts = vim.deepcopy(expected_collection)
  end
  return vim.deep_equal(payload, expected)
end

local function workspace_unchanged(marker, workspace)
  if workspace ~= marker.workspace then
    return false
  end
  return vim.deep_equal(workspace, marker.workspace_snapshot)
end

local function count_marker_violation(state, marker, payload)
  local bucket = state.observed_call_ids[marker.generation] or {}
  local canonical = marker.call_id and bucket[marker.call_id] or marker
  if marker.violation_counted or (canonical and canonical.violation_counted) then
    return
  end
  marker.violation_counted = true
  if canonical then
    canonical.violation_counted = true
  end
  record_violation(state, payload)
end

local function classify_recorded_result(state, marker, entry)
  local chat = chat_for(state)
  if not chat then
    return
  end
  if marker.call_id == nil or marker.tool_name ~= Constants.tool_by_operation[marker.operation] then
    return internal_result(state, marker, entry, 'reasoning call identity changed before its result was recorded')
  end
  local decoded_ok, payload = pcall(vim.json.decode, entry.delta)
  if marker.status == 'malformed_pending' then
    if not workspace_unchanged(marker, State.get(chat)) then
      return internal_result(state, marker, entry, 'malformed reasoning arguments unexpectedly mutated protocol state')
    end
    payload = Protocol.failure(
      'reasoning_call_malformed',
      'reasoning tool arguments must be a JSON object',
      {},
      Protocol.transition(State.get(chat), state.phase),
      {
        path = 'arguments',
        constraint = 'json_object',
        expected = 'object',
        actual = 'invalid_json',
      }
    ).data
    marker.status = 'classified'
    rewrite_recorded_result(state, marker, entry, payload)
    count_marker_violation(state, marker, payload)
    return
  end
  if not decoded_ok or type(payload) ~= 'table' then
    return internal_result(state, marker, entry, 'reasoning tool resolution failed internally')
  end
  if payload.code == 'internal_error' or payload.code == 'render_internal' then
    marker.status = 'classified'
    local workspace = State.get(chat)
    local resume_phase = workspace_unchanged(marker, workspace) and marker.phase
      or (workspace and 'active' or marker.phase)
    return halt_internal(state, 'Structured reasoning halted after an internal protocol failure.', resume_phase)
  end
  if accepted_payload(state, marker, payload) then
    marker.status = 'classified'
    state.consecutive_violations = 0
    invalidate_marker(state.fallback_lease)
    state.fallback_lease = nil
    if type(chat.remove_tagged_message) == 'function' then
      pcall(chat.remove_tagged_message, chat, Constants.corrective_tag)
    end
    if state.phase == 'armed' or state.phase == 'reframing' then
      state.phase = 'active'
    end
    return
  end
  local transition = Protocol.transition(State.get(chat), state.phase)
  local rejection = payload.committed == false
    and type(payload.code) == 'string'
    and payload.code ~= ''
    and vim.deep_equal(payload.next_action, transition)
    and workspace_unchanged(marker, State.get(chat))
  if rejection then
    marker.status = 'classified'
    count_marker_violation(state, marker, payload)
    return
  end
  return internal_result(
    state,
    marker,
    entry,
    'recorded reasoning output did not match committed protocol state',
    State.get(chat) and 'active' or state.phase
  )
end

local function recorded_result_correlation_valid(chat, message, marker, entry)
  if type(chat) ~= 'table' or type(message) ~= 'table' then
    return false
  end
  local expected_role = type(chat.adapter) == 'table'
      and type(chat.adapter.roles) == 'table'
      and chat.adapter.roles.tool
    or 'tool'
  if message.role ~= expected_role then
    return false
  end
  if entry and entry.reused and not vim.deep_equal(result_identity(message), entry.identity_before) then
    return false
  end
  local tools = type(message.tools) == 'table' and message.tools or {}
  local has_id = false
  if message.tool_call_id ~= nil and message.tool_call_id ~= marker.call_id then
    return false
  elseif message.tool_call_id ~= nil then
    has_id = true
  end
  if marker.response_call_id ~= nil then
    if tools.id ~= marker.call_id or tools.call_id ~= marker.response_call_id then
      return false
    end
    has_id = true
  else
    if tools.id ~= nil and tools.id ~= marker.call_id then
      return false
    elseif tools.id ~= nil then
      has_id = true
    end
    if tools.call_id ~= nil and tools.call_id ~= marker.call_id then
      return false
    elseif tools.call_id ~= nil then
      has_id = true
    end
  end
  local stale_merged_name = entry and entry.reused and has_id
  if tools.name ~= nil and tools.name ~= marker.tool_name and not stale_merged_name then
    return false
  end
  if message.tool_name ~= nil and message.tool_name ~= marker.tool_name and not stale_merged_name then
    return false
  end
  local canonical_ollama = marker.response_call_id == nil
    and not has_id
    and message.tool_call_id == nil
    and message.tool_name == marker.tool_name
    and next(tools) == nil
  return has_id or canonical_ollama
end

local function expected_final_payload(staged)
  local workspace = staged.workspace_prepared or staged.workspace
  local progress = vim.deepcopy(workspace.counts_by_kind)
  progress.synthesis = (progress.synthesis or 0) + 1
  return {
    workspace_id = workspace.id,
    artifact = vim.deepcopy(staged.candidate or staged.stage.candidate),
    progress = progress,
    unmet_gates = {},
    next_action = {
      tool = 'none',
      reason = 'Final synthesis accepted; no further model action is permitted',
    },
  }
end

local function candidate_contains_final(candidate)
  if not candidate or type(candidate.delta) ~= 'string' then
    return false
  end
  local ok, payload = pcall(vim.json.decode, candidate.delta)
  if not ok or type(payload) ~= 'table' then
    return false
  end
  local artifact = payload.artifact
  return (type(payload.next_action) == 'table' and payload.next_action.tool == 'none')
    or (
      type(artifact) == 'table'
      and artifact.kind == 'synthesis'
      and type(artifact.data) == 'table'
      and artifact.data.mode == 'final'
    )
end

local function remove_candidate(chat, candidate)
  if not candidate or not candidate.message then
    return
  end
  if candidate.is_new then
    for index = #chat.messages, 1, -1 do
      if chat.messages[index] == candidate.message then
        table.remove(chat.messages, index)
        return
      end
    end
    return
  end
  candidate.message.content = candidate.prior
  if candidate.identity_before then
    candidate.message.role = candidate.identity_before.role
    candidate.message.tool_call_id = candidate.identity_before.tool_call_id
    candidate.message.tool_name = candidate.identity_before.tool_name
    candidate.message.tools = vim.deepcopy(candidate.identity_before.tools)
  end
  stamp_result(chat, candidate.message)
end

local function select_final_entry(chat, entry, candidates)
  local selected = entry
  if not selected then
    for index = #(candidates or {}), 1, -1 do
      if candidate_contains_final(candidates[index]) then
        selected = candidates[index]
        break
      end
    end
  end
  for _, candidate in ipairs(candidates or {}) do
    if candidate ~= selected then
      remove_candidate(chat, candidate)
    end
  end
  return selected
end

local function fail_staged_final(state, staged, marker, entry, candidates, message)
  local chat = chat_for(state)
  if not chat then
    return
  end
  entry = select_final_entry(chat, entry, candidates)
  if staged and staged.stage and staged.stage.state == 'prepared' then
    State.discard_final(staged.stage)
  end
  if state.staged_final == staged then
    state.staged_final = nil
  end
  return internal_result(state, marker, entry, message, 'active')
end

local function settle_invalidated_final(state, staged, marker, entry, candidates)
  local chat = chat_for(state)
  if not chat then
    return
  end
  entry = select_final_entry(chat, entry, candidates)
  if staged and staged.stage and staged.stage.state == 'prepared' then
    State.discard_final(staged.stage)
  end
  if state.staged_final == staged then
    state.staged_final = nil
  end
  marker.status = 'classified'
  local workspace = State.get(chat)
  local transition_ok, transition = pcall(Protocol.transition, workspace, state.phase)
  if not transition_ok or type(transition) ~= 'table' then
    transition = workspace and { tool = 'none', reason = 'Wait for explicit user recovery' }
      or { tool = 'reasoning_frame', reason = 'Start a new reasoning workspace' }
  end
  local payload = Protocol.failure(
    'internal_error',
    'reasoning finalization was invalidated while its host result was recorded',
    {},
    transition
  ).data
  rewrite_recorded_result(state, marker, entry, payload)
end

local function final_boundary_current(state, staged, marker)
  local chat = chat_for(state)
  local call = staged and staged.call or nil
  return type(chat) == 'table'
    and callbacks_allowed(chat, state)
    and state.phase == 'finalizing'
    and state.staged_final == staged
    and staged.epoch == state.epoch
    and staged.generation == state.request_generation
    and staged.marker == marker
    and staged.adapter == chat.adapter
    and marker.adapter == staged.adapter
    and marker.status == 'executing'
    and marker.valid ~= false
    and not marker.invalidated
    and marker.epoch == staged.epoch
    and marker.generation == staged.generation
    and marker.phase == 'active'
    and marker.operation == 'synthesis'
    and marker.tool_name == 'reasoning_synthesis'
    and marker.workspace == staged.workspace
    and marker.revision == staged.revision
    and type(call) == 'table'
    and state.call_tokens[call] == marker
    and vim.deep_equal(call, staged.call_snapshot)
    and call.id == staged.call_id
    and (call.call_id or nil) == staged.response_call_id
    and type(call['function']) == 'table'
    and call['function'].name == marker.tool_name
    and vim.deep_equal(staged.stage.candidate, staged.candidate)
    and staged.markdown_hash == Hash.hash({ content = staged.markdown })
end

local function staged_final_matches(state, staged, call, marker, entry)
  local chat = chat_for(state)
  local message = entry and entry.message or nil
  if
    not final_boundary_current(state, staged, marker)
    or call ~= staged.call
    or State.get(chat) ~= staged.workspace
    or staged.workspace.revision ~= staged.revision
    or not vim.deep_equal(staged.workspace, staged.workspace_prepared)
    or staged.stage.workspace ~= staged.workspace
    or staged.stage.revision ~= staged.revision
    or staged.stage.state ~= 'prepared'
    or staged.stage.reserved_id ~= staged.reserved_id
    or staged.stage.candidate.id ~= staged.reserved_id
    or not recorded_result_correlation_valid(chat, message, marker, entry)
    or type(message._meta) ~= 'table'
    or message._meta.id ~= Hash.hash({ role = message.role, content = message.content })
  then
    return false
  end
  local occurrences = 0
  for _, candidate in ipairs(chat.messages or {}) do
    if candidate == message then
      occurrences = occurrences + 1
    end
  end
  if occurrences ~= 1 then
    return false
  end
  local decoded_ok, payload = pcall(vim.json.decode, entry.delta)
  return decoded_ok and vim.deep_equal(payload, expected_final_payload(staged))
end

local function capture_final_history(chat, entry)
  if type(chat.messages) ~= 'table' or not entry or type(entry.message) ~= 'table' then
    return
  end
  local snapshot = {
    messages = chat.messages,
    value = vim.deepcopy(chat.messages),
    refs = {},
    count = #chat.messages,
  }
  local occurrences = 0
  for index, message in ipairs(chat.messages) do
    snapshot.refs[index] = message
    if message == entry.message then
      occurrences = occurrences + 1
    end
  end
  return occurrences == 1 and snapshot or nil
end

local function final_history_current(chat, snapshot, emitted)
  if type(snapshot) ~= 'table' or chat.messages ~= snapshot.messages then
    return false
  end
  local expected = vim.deepcopy(snapshot.value)
  if emitted then
    expected[snapshot.count + 1] = vim.deepcopy(emitted.value)
  end
  if not vim.deep_equal(chat.messages, expected) then
    return false
  end
  for index, message in ipairs(snapshot.refs) do
    if chat.messages[index] ~= message then
      return false
    end
  end
  return not emitted or chat.messages[snapshot.count + 1] == emitted.ref
end

local function restore_final_history(chat, snapshot)
  if type(snapshot) ~= 'table' or type(snapshot.messages) ~= 'table' then
    return false
  end
  if not overwrite_table(snapshot.messages, snapshot.value) then
    return false
  end
  for index, message in ipairs(snapshot.refs) do
    local value = snapshot.value[index]
    if type(message) == 'table' and type(value) == 'table' then
      if not overwrite_table(message, value) then
        return false
      end
      snapshot.messages[index] = message
    end
  end
  chat.messages = snapshot.messages
  return final_history_current(chat, snapshot)
end

local function capture_final_buffer(chat)
  if type(chat.bufnr) ~= 'number' or not vim.api.nvim_buf_is_valid(chat.bufnr) then
    return
  end
  local lines_ok, lines = pcall(vim.api.nvim_buf_get_lines, chat.bufnr, 0, -1, false)
  local option_ok, modifiable = pcall(function()
    return vim.bo[chat.bufnr].modifiable
  end)
  if not lines_ok or not option_ok then
    return
  end
  return { bufnr = chat.bufnr, lines = lines, modifiable = modifiable }
end

local function restore_final_buffer(snapshot)
  if type(snapshot) ~= 'table' or type(snapshot.bufnr) ~= 'number' or not vim.api.nvim_buf_is_valid(snapshot.bufnr) then
    return false, 'buffer_invalid'
  end
  local restored, restore_error = xpcall(function()
    if not vim.bo[snapshot.bufnr].modifiable then
      vim.bo[snapshot.bufnr].modifiable = true
    end
    vim.api.nvim_buf_set_lines(snapshot.bufnr, 0, -1, false, snapshot.lines)
    assert(
      vim.deep_equal(vim.api.nvim_buf_get_lines(snapshot.bufnr, 0, -1, false), snapshot.lines),
      'buffer lines did not restore exactly'
    )
    vim.bo[snapshot.bufnr].modifiable = snapshot.modifiable
    assert(vim.bo[snapshot.bufnr].modifiable == snapshot.modifiable, 'buffer lock did not restore exactly')
  end, debug.traceback)
  if not restored then
    pcall(function()
      vim.bo[snapshot.bufnr].modifiable = snapshot.modifiable
    end)
    return false, restore_error
  end
  return true
end

local function restore_final_emission(chat, history, buffer)
  local history_ok = restore_final_history(chat, history)
  local buffer_ok, buffer_error = restore_final_buffer(buffer)
  return history_ok and buffer_ok, history_ok and buffer_error or 'history_restore_failed'
end

local function rollback_final_workspace(chat, staged)
  local workspace = staged and staged.workspace or nil
  local stage = staged and staged.stage or nil
  if type(workspace) ~= 'table' or type(stage) ~= 'table' or type(staged.workspace_before) ~= 'table' then
    return false
  end
  if stage.state == 'committed' and State.get(chat) == workspace then
    pcall(State.rollback_final, chat, stage)
  end
  if
    not vim.deep_equal(workspace, staged.workspace_before) and not overwrite_table(workspace, staged.workspace_before)
  then
    return false
  end
  if not vim.deep_equal(workspace, staged.workspace_before) then
    return false
  end
  stage.committed_artifact = nil
  stage.rollback = nil
  stage.state = 'rolled_back'
  return true
end

local function committed_final_current(state, staged, marker)
  local chat = chat_for(state)
  local workspace = staged and staged.workspace or nil
  local stage = staged and staged.stage or nil
  return final_boundary_current(state, staged, marker)
    and type(stage) == 'table'
    and stage.state == 'committed'
    and State.get(chat) == workspace
    and workspace.revision == stage.revision + 1
    and workspace.artifact_order[#workspace.artifact_order] == staged.reserved_id
    and workspace.artifacts_by_id[staged.reserved_id] == stage.committed_artifact
    and type(staged.workspace_committed) == 'table'
    and vim.deep_equal(workspace, staged.workspace_committed)
end

local function lifecycle_consumed_final(state, staged, marker)
  return state.closed
    or state.unsupported_adapter
    or state.phase ~= 'finalizing'
    or state.staged_final ~= staged
    or staged.epoch ~= state.epoch
    or staged.generation ~= state.request_generation
    or staged.marker ~= marker
    or marker.valid == false
    or marker.invalidated
end

local function host_clear_consumed_final(state, chat, history)
  return not state.closed
    and not state.unsupported_adapter
    and state.phase == 'dormant'
    and State.get(chat) == nil
    and type(history) == 'table'
    and chat.messages ~= history.messages
end

local function commit_and_emit_final(state, staged, marker, entry, candidates)
  local chat = chat_for(state)
  local snapshots_ok, snapshots = xpcall(function()
    local history = assert(capture_final_history(chat, entry), 'final history could not be snapshotted')
    local buffer = assert(capture_final_buffer(chat), 'final buffer could not be snapshotted')
    return {
      history = history,
      buffer = buffer,
      workspace = vim.deepcopy(staged.workspace),
    }
  end, debug.traceback)
  if not snapshots_ok then
    log:error('[reasoning control] final snapshot failed: %s', snapshots)
    return fail_staged_final(
      state,
      staged,
      marker,
      entry,
      candidates,
      'reasoning final output could not be snapshotted'
    )
  end
  staged.workspace_before = snapshots.workspace

  local committed_ok, committed, commit_code = xpcall(function()
    return State.commit_final(chat, staged.stage)
  end, debug.traceback)
  if not committed_ok or not committed or not vim.deep_equal(committed, staged.stage.candidate) then
    if staged.stage.state == 'committed' then
      rollback_final_workspace(chat, staged)
    end
    if not committed_ok then
      log:error('[reasoning control] final commit failed: %s', committed)
    end
    return fail_staged_final(
      state,
      staged,
      marker,
      entry,
      candidates,
      'reasoning final transaction failed: ' .. tostring(commit_code or 'internal')
    )
  end
  staged.workspace_committed = vim.deepcopy(staged.workspace)

  local role = require('codecompanion.config').constants.LLM_ROLE
  local emitted, emission_error = xpcall(function()
    chat:add_message({ role = role, content = staged.markdown }, { visible = true })
    assert(committed_final_current(state, staged, marker), 'final lifecycle changed during history emission')
    local emitted_message = chat.messages[snapshots.history.count + 1]
    assert(type(emitted_message) == 'table', 'final history emission is missing')
    assert(emitted_message.role == role, 'final history role changed')
    assert(emitted_message.content == staged.markdown, 'final history content changed')
    local emitted_snapshot = { ref = emitted_message, value = vim.deepcopy(emitted_message) }
    assert(final_history_current(chat, snapshots.history, emitted_snapshot), 'final history changed during emission')

    local line = state.methods.add_buf_message.original(chat, {
      role = role,
      content = staged.markdown,
    }, {
      type = chat.MESSAGE_TYPES.LLM_MESSAGE,
    })
    assert(line ~= nil, 'final buffer emission returned nil')
    assert(committed_final_current(state, staged, marker), 'final lifecycle changed during buffer emission')
    assert(
      final_history_current(chat, snapshots.history, emitted_snapshot),
      'final history changed during buffer emission'
    )
    assert(State.finalize_final(chat, staged.stage), 'final transaction could not be sealed')
  end, debug.traceback)
  if not emitted then
    log:error('[reasoning control] final emission failed: %s', emission_error)
    if state.closed and State.get(chat) == nil then
      local history_restored = restore_final_history(chat, snapshots.history)
      local buffer_restored = true
      if vim.api.nvim_buf_is_valid(snapshots.buffer.bufnr) then
        buffer_restored = restore_final_buffer(snapshots.buffer)
      end
      if not history_restored or not buffer_restored then
        log:error('[reasoning control] close-time final emission compensation failed')
      end
      if state.staged_final == staged then
        state.staged_final = nil
      end
      return
    end
    local cleared = host_clear_consumed_final(state, chat, snapshots.history)
    local invalidated = lifecycle_consumed_final(state, staged, marker)
    if not cleared then
      local restored, restore_error = restore_final_emission(chat, snapshots.history, snapshots.buffer)
      if not restored then
        log:error('[reasoning control] final emission restoration failed: %s', restore_error)
      end
    end
    if not rollback_final_workspace(chat, staged) then
      log:error('[reasoning control] final workspace restoration failed')
      if State.get(chat) == staged.workspace then
        State.clear(chat)
      end
    end
    if cleared then
      if state.staged_final == staged then
        state.staged_final = nil
      end
      return
    end
    if invalidated then
      return settle_invalidated_final(state, staged, marker, entry, candidates)
    end
    return fail_staged_final(state, staged, marker, entry, candidates, 'reasoning final emission failed internally')
  end

  staged.workspace_before = nil
  staged.workspace_committed = nil
  state.staged_final = nil
  marker.status = 'classified'
  state.consecutive_violations = 0
  invalidate_marker(state.fallback_lease)
  state.fallback_lease = nil
  state.phase = 'finalized'
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
    local first = type(calls[1]) == 'table' and state.call_tokens[calls[1]] or nil
    if first then
      count_marker_violation(state, first, payload)
    else
      record_violation(state, payload)
    end
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
  if operation and phase ~= 'reframing' then
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

local function snapshot_resume_submission(chat)
  local messages = type(chat.messages) == 'table' and chat.messages or nil
  local boundary = {}
  for index, message in ipairs(messages or {}) do
    boundary[index] = message
  end
  return {
    header_line = chat.header_line,
    messages = messages,
    boundary = boundary,
  }
end

local function restore_resume_submission(chat, snapshot)
  chat.header_line = snapshot.header_line
  if snapshot.messages then
    for index = #snapshot.messages, 1, -1 do
      snapshot.messages[index] = nil
    end
    for index, message in ipairs(snapshot.boundary) do
      snapshot.messages[index] = message
    end
    chat.messages = snapshot.messages
  end
  if type(chat.restore) == 'function' then
    pcall(chat.restore, chat)
  end
end

local recoverable_phase = {
  armed = true,
  active = true,
  reframing = true,
}

local function token_current(state, token)
  return not state.closed
    and not token.invalidated
    and token.valid ~= false
    and not token.settling
    and not token.settled
    and state.active_request_token == token
    and token.epoch == state.epoch
    and token.generation == state.request_generation
end

local function replace_correction(state, transition, code)
  local chat = chat_for(state)
  if not chat then
    return
  end
  if type(chat.remove_tagged_message) == 'function' then
    pcall(chat.remove_tagged_message, chat, Constants.corrective_tag)
  end
  if type(chat.add_message) == 'function' then
    pcall(chat.add_message, chat, {
      role = 'system',
      content = string.format(
        'Reasoning protocol correction (%s): call %s next. %s Rejected calls commit no artifacts; change the arguments before retrying.',
        code,
        transition.tool,
        transition.reason
      ),
    }, {
      visible = false,
      _meta = { tag = Constants.corrective_tag },
    })
  end
end

record_violation = function(state, payload)
  state.consecutive_violations = math.min(3, state.consecutive_violations + 1)
  local chat = chat_for(state)
  local transition = chat and Protocol.transition(State.get(chat), state.phase) or nil
  transition = transition or { tool = 'none', reason = 'Wait for explicit user recovery' }
  if state.consecutive_violations < 3 then
    replace_correction(state, transition, type(payload) == 'table' and payload.code or 'completion_missing')
    invalidate_marker(state.fallback_lease)
    state.fallback_lease = {
      valid = true,
      generation = state.request_generation,
      epoch = state.epoch,
    }
    return
  end
  halt_internal(
    state,
    string.format(
      'Reasoning halted after three rejected completions. Expected %s: %s Use :%s to resume.',
      transition.tool,
      transition.reason,
      Constants.resume_command
    ),
    state.phase
  )
end

local function request_adapter_proxy(state, token, adapter)
  local seen = {}
  local function clone(value)
    if type(value) ~= 'table' then
      return value
    end
    if seen[value] then
      return seen[value]
    end
    local copy = {}
    seen[value] = copy
    for child_key, child in pairs(value) do
      copy[child_key] = clone(child)
    end
    return setmetatable(copy, getmetatable(value))
  end

  local function protected(storage)
    return setmetatable({}, {
      __index = storage,
      __newindex = function() end,
    })
  end

  local function guarded(handler)
    if type(handler) ~= 'function' then
      return nil
    end
    return function(...)
      if not token_current(state, token) then
        return
      end
      return handler(...)
    end
  end

  local storage = clone(adapter)
  local source_handlers = type(adapter.handlers) == 'table' and adapter.handlers or {}
  local handlers = clone(source_handlers)
  local modern = source_handlers.lifecycle ~= nil or source_handlers.request ~= nil or source_handlers.response ~= nil
  if modern then
    local response_source = type(source_handlers.response) == 'table' and source_handlers.response or {}
    local response = clone(response_source)
    for _, name in ipairs({ 'parse_chat', 'parse_tokens', 'parse_meta' }) do
      response[name] = guarded(response_source[name])
    end
    handlers.response = protected(response)
  else
    handlers.response = nil
  end
  for _, name in ipairs({ 'chat_output', 'tokens', 'parse_message_meta' }) do
    handlers[name] = guarded(source_handlers[name])
  end
  for _, category in ipairs({ 'lifecycle', 'request', 'tools' }) do
    if type(handlers[category]) == 'table' then
      handlers[category] = protected(handlers[category])
    end
  end
  storage.handlers = protected(handlers)

  return setmetatable({}, {
    __index = storage,
    __newindex = function(_, key, value)
      if key ~= 'handlers' then
        storage[key] = value
      end
    end,
  })
end

local complete_bound_request

local function readonly_snapshot(value)
  if type(value) ~= 'table' then
    return value
  end
  local storage = {}
  for key, child in pairs(value) do
    storage[key] = readonly_snapshot(child)
  end
  return setmetatable({}, {
    __index = storage,
    __newindex = function() end,
  })
end

local function request_chat_proxy(state, token, chat)
  local shadow = {
    status = chat.status,
    tokens = chat.tokens,
    _last_role = chat._last_role,
    current_request = nil,
  }
  local immutable = {
    adapter = request_adapter_proxy(state, token, chat.adapter),
    bufnr = chat.bufnr,
    id = chat.id,
    MESSAGE_TYPES = readonly_snapshot(chat.MESSAGE_TYPES),
  }
  immutable.done = function(_, ...)
    return complete_bound_request(state, token, ...)
  end
  immutable.add_buf_message = function(_, ...)
    local current = chat_for(state)
    local slot = state.methods.add_buf_message
    if token_current(state, token) and current and rawget(current, slot.key) == slot.wrapper then
      return slot.wrapper(current, ...)
    end
  end
  local set_status = chat._set_status
  immutable._set_status = function(_, ...)
    local current = chat_for(state)
    if
      token_current(state, token)
      and current
      and current._set_status == set_status
      and type(set_status) == 'function'
    then
      return set_status(current, ...)
    end
  end
  return setmetatable({}, {
    __index = function(_, key)
      if immutable[key] ~= nil then
        return immutable[key]
      end
      if shadow[key] ~= nil then
        return shadow[key]
      end
      local current = chat_for(state)
      if token_current(state, token) and current then
        return current[key]
      end
    end,
    __newindex = function(_, key, value)
      if immutable[key] ~= nil then
        return
      end
      if key == 'current_request' then
        shadow.current_request = value
        token.handle = value
        local current = chat_for(state)
        if token_current(state, token) and current then
          current.current_request = value
          state.request_handle = value
        end
        return
      end
      shadow[key] = value
      local current = chat_for(state)
      if token_current(state, token) and current then
        current[key] = value
      end
    end,
  })
end

local function run_preserved_done(state, target, done, extra, classify)
  if state.processing_done then
    return
  end
  local has_tools = type(extra[3]) == 'table' and not vim.tbl_isempty(extra[3])
  local done_opts = extra[5]
  local stopped = type(done_opts) == 'table' and done_opts.status == 'stopped'
  local failed = target.status == 'error' or target.status == 'cancelling'
  if classify and not state.completion_classified then
    state.completion_classified = true
    if not has_tools and not stopped and not failed then
      record_violation(state)
    end
  end
  if suppressing_phase[state.phase] then
    extra[1] = nil
    extra[2] = nil
    if not has_tools and not (type(done_opts) == 'table' and done_opts.status ~= nil) then
      extra[4] = nil
    end
  end
  if
    classify
    and suppressing_phase[state.phase]
    and not has_tools
    and not stopped
    and not failed
    and not target._btw
  then
    target._last_role = HostConfig.constants.LLM_ROLE
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
  if not ok then
    error(values, 0)
  end
  return unpack(values, 1, values.n)
end

complete_bound_request = function(state, token, ...)
  if not token_current(state, token) then
    return
  end
  local chat = chat_for(state)
  if not chat then
    return
  end
  token.settling = true
  local prior_phase = state.phase
  local extra = packed(...)
  local ok, values = xpcall(function()
    return packed(run_preserved_done(state, chat, state.methods.done, extra, true))
  end, debug.traceback)
  token.settling = false
  token.settled = true
  if state.active_request_token == token then
    state.active_request_token = nil
  end
  chat.current_request = nil
  state.request_handle = nil
  if not ok then
    log:error('[reasoning control] bound request completion failed: %s', values)
    if type(token.prior_violations) == 'number' then
      state.consecutive_violations = token.prior_violations
    end
    state.completion_classified = true
    state.epoch = state.epoch + 1
    halt_internal(state, 'Reasoning request completion failed internally.', prior_phase)
    return
  end
  return unpack(values, 1, values.n)
end

local function fail_request_construction(state, token, resume_phase)
  local prior_violations = token and token.prior_violations or state.submit_prior_violations
  if token then
    token.invalidated = true
    token.settled = true
  end
  if state.active_request_token == token then
    state.active_request_token = nil
  end
  state.construction_lease = nil
  state.request_handle = nil
  state.completion_classified = true
  local chat = chat_for(state)
  if chat then
    local handle = (token and token.handle) or chat.current_request
    if handle and type(handle.cancel) == 'function' then
      pcall(handle.cancel, handle)
    end
    chat.current_request = nil
    if type(chat.remove_tagged_message) == 'function' then
      pcall(chat.remove_tagged_message, chat, Constants.corrective_tag)
    end
  end
  if type(prior_violations) == 'number' then
    state.consecutive_violations = prior_violations
  end
  state.epoch = state.epoch + 1
  halt_internal(state, 'Reasoning request construction failed internally.', resume_phase)
end

local function schedule_fallback(state)
  local lease = state.fallback_lease
  if not lease then
    return
  end
  vim.schedule(function()
    local chat = chat_for(state)
    if
      not chat
      or state.closed
      or state.fallback_lease ~= lease
      or lease.epoch ~= state.epoch
      or lease.generation ~= state.request_generation
      or state.unsupported_adapter
      or not complete_tool_set(chat)
      or not chat.adapter
      or chat.adapter.type ~= 'http'
      or chat.current_request
      or chat.tool_orchestrator
      or not recoverable_phase[state.phase]
    then
      return
    end
    chat:submit({ auto_submit = true })
    state.request_handle = chat.current_request
  end)
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
  local resume_command = {
    bufnr = chat.bufnr,
    name = Constants.resume_command,
  }
  resume_command.callback = function()
    local current = chat_for(state)
    if current then
      M.resume(current)
    end
  end
  state.resume_command = resume_command
  state.resume_command_installed =
    pcall(vim.api.nvim_buf_create_user_command, resume_command.bufnr, resume_command.name, resume_command.callback, {
      desc = 'Resume the fail-closed reasoning protocol',
      force = true,
    })

  local submit = state.methods.submit
  install_wrapper(submit, function(target, opts, ...)
    local current = chat_for(state)
    if not current or current ~= target then
      return
    end
    if state.closed or state.clearing then
      return
    end
    if dormant_passthrough(state, current) then
      local lease = {
        valid = true,
        payloads = setmetatable({}, { __mode = 'k' }),
      }
      table.insert(state.dormant_submit_stack, lease)
      local extra = packed(...)
      local result = packed(xpcall(function()
        return submit.original(target, opts, unpack(extra, 1, extra.n))
      end, debug.traceback))
      lease.valid = false
      assert(state.dormant_submit_stack[#state.dormant_submit_stack] == lease, 'dormant submit lease order changed')
      table.remove(state.dormant_submit_stack)
      if #state.dormant_submit_stack == 0 and state.protected_submit_depth == 0 then
        state.clear_during_submit = false
      end
      if not result[1] then
        error(result[2], 0)
      end
      return unpack(result, 2, result.n)
    end
    M.reconcile(current)
    if
      state.unsupported_adapter
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
      or not recoverable_phase[state.phase]
    then
      return blocked_submit(current, opts)
    end

    local extra = packed(...)
    local prior_phase = state.phase
    local prior_epoch = state.epoch
    local prior_violations = state.consecutive_violations
    state.submit_prior_violations = prior_violations
    state.submit_epoch = prior_epoch
    state.submitting = true
    state.protected_submit_depth = state.protected_submit_depth + 1
    local ok, values = xpcall(function()
      return packed(submit.original(current, opts, unpack(extra, 1, extra.n)))
    end, debug.traceback)
    state.protected_submit_depth = state.protected_submit_depth - 1
    state.submitting = false
    if state.protected_submit_depth == 0 and #state.dormant_submit_stack == 0 then
      state.clear_during_submit = false
    end
    if not ok then
      log:error('[reasoning control] preserved submit failed: %s', values)
      if not state.closed and state.phase ~= 'dormant' then
        fail_request_construction(state, state.active_request_token, prior_phase)
      end
      state.submit_prior_violations = nil
      state.submit_epoch = nil
      return
    end
    local lease = state.construction_lease
    if lease and lease.epoch == prior_epoch and not lease.consumed then
      local attempt = state.resume_attempt
      local resume_phantom = attempt and attempt.epoch == lease.epoch and attempt.generation == lease.generation
      if not resume_phantom then
        lease.consumed = true
        state.construction_lease = nil
        if not state.closed and state.phase ~= 'dormant' then
          fail_request_construction(state, nil, prior_phase)
        else
          state.completion_classified = true
        end
      end
    end
    state.submit_prior_violations = nil
    state.submit_epoch = nil
    return unpack(values, 1, values.n)
  end)

  local submit_http = state.methods._submit_http
  install_wrapper(submit_http, function(target, payload, ...)
    local current = chat_for(state)
    if not current or current ~= target then
      return
    end
    if state.closed or state.clearing then
      return
    end
    if state.invalidated_submissions[payload] then
      return
    end
    if dormant_passthrough(state, current) then
      return submit_http.original(target, payload, ...)
    end
    M.reconcile(current)
    if
      state.unsupported_adapter
      or state.boundary_issue ~= nil
      or not complete_tool_set(current)
      or not live_tools_match(current, state)
      or not wrappers_intact(state)
      or not current.adapter
      or current.adapter.type ~= 'http'
      or state.executing_scope ~= nil
      or not state.submitting
      or state.completion_classified
      or state.active_request_token ~= nil
    then
      return
    end
    local lease = state.construction_lease
    if
      not lease
      or lease.consumed
      or lease.payload ~= payload
      or lease.epoch ~= state.epoch
      or lease.generation ~= state.request_generation
    then
      return
    end
    lease.consumed = true
    state.construction_lease = nil
    local token = {
      id = state.next_request_token + 1,
      epoch = lease.epoch,
      generation = lease.generation,
      handle = nil,
      valid = true,
      invalidated = false,
      settling = false,
      settled = false,
      prior_phase = lease.phase,
      prior_violations = lease.consecutive_violations,
    }
    state.next_request_token = token.id
    state.active_request_token = token
    if state.resume_attempt and state.resume_attempt.epoch == state.epoch then
      state.resume_attempt.constructed = true
      state.resume_attempt.request_token = token
    end
    local proxy = request_chat_proxy(state, token, current)
    token.proxy = proxy
    local extra = packed(...)
    local ok, values = xpcall(function()
      return packed(submit_http.original(proxy, payload, unpack(extra, 1, extra.n)))
    end, debug.traceback)
    if not ok then
      log:error('[reasoning control] HTTP request construction failed: %s', values)
      fail_request_construction(state, token, token.prior_phase or state.phase)
      return
    end
    if token_current(state, token) and token.handle == nil then
      fail_request_construction(state, token, token.prior_phase or state.phase)
      return
    end
    return unpack(values, 1, values.n)
  end)

  local submit_acp = state.methods._submit_acp
  install_wrapper(submit_acp, function(target, ...)
    local current = chat_for(state)
    if not current or current ~= target then
      return
    end
    if state.closed or state.clearing then
      return
    end
    if dormant_passthrough(state, current) then
      return submit_acp.original(target, ...)
    end
    M.reconcile(current)
    return blocked_submit(current)
  end)

  local done = state.methods.done
  install_wrapper(done, function(target, ...)
    local current = chat_for(state)
    if not current or current ~= target or state.closed or state.clearing then
      return
    end
    if dormant_passthrough(state, current) then
      return done.original(target, ...)
    end
    if state.processing_done or not callbacks_allowed(target, state) then
      return
    end
    local extra = packed(...)
    local done_opts = extra[5]
    local stopped = type(done_opts) == 'table' and done_opts.status == 'stopped'
    local lease = state.pending_stop_token
    if
      not stopped
      or not lease
      or lease.valid == false
      or lease.cleanup_epoch ~= state.epoch
      or lease.generation ~= state.request_generation
      or state.active_request_token ~= nil
    then
      invalidate_marker(lease)
      state.pending_stop_token = nil
      return
    end
    lease.valid = false
    state.pending_stop_token = nil
    local values = packed(run_preserved_done(state, target, done, extra, false))
    if target.current_request == nil then
      state.request_handle = nil
    end
    return unpack(values, 1, values.n)
  end)

  local add_buf_message = state.methods.add_buf_message
  install_wrapper(add_buf_message, function(target, data, opts, ...)
    local current = chat_for(state)
    if not current or current ~= target or state.closed or state.clearing then
      return
    end
    local kind = type(opts) == 'table' and opts.type or nil
    if
      state.processing_done
      and type(data) == 'table'
      and data.role == HostConfig.constants.USER_ROLE
      and (data.content == nil or data.content == '')
    then
      opts = vim.tbl_extend('force', {}, type(opts) == 'table' and opts or {}, { force_role = true })
    end
    local scope = state.executing_scope
    if
      (
        suppressing_phase[state.phase]
        and (kind == target.MESSAGE_TYPES.LLM_MESSAGE or kind == target.MESSAGE_TYPES.REASONING_MESSAGE)
      )
      or (state.phase == 'finalizing' and kind == target.MESSAGE_TYPES.TOOL_MESSAGE)
      or (scope and scope.settling and kind == target.MESSAGE_TYPES.TOOL_MESSAGE)
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
    if marker and (marker.status == 'synthetic' or marker.status == 'classified') then
      return
    end
    local staged = state.staged_final
    if staged and staged.recording then
      return
    end
    if
      marker
      and (marker.valid == false or marker.epoch ~= state.epoch or marker.generation ~= state.request_generation)
    then
      return
    end
    if not marker then
      if state.phase == 'dormant' then
        return add_tool_output.original(target, tool, ...)
      end
      halt_internal(state, 'Structured reasoning halted after an unauthenticated tool result.', state.phase)
      return
    end

    local snapshot = snapshot_recorded_result(target, marker)
    local final_recording = staged and staged.marker == marker
    if final_recording then
      staged.recording = true
    end
    local extra = packed(...)
    local ok, values = xpcall(function()
      return packed(add_tool_output.original(target, tool, unpack(extra, 1, extra.n)))
    end, debug.traceback)
    if final_recording then
      staged.recording = false
      local entry, result_error, candidates = recorded_result_entry(target, marker, snapshot)
      if state.staged_final ~= staged then
        if not ok then
          log:error('[reasoning control] invalidated final tool-result recording failed: %s', values)
        end
        return settle_invalidated_final(state, staged, marker, entry, candidates)
      end
      if result_error == 'history_boundary_changed' then
        if not restore_recorded_history(target, snapshot) then
          log:error('[reasoning control] pre-final history restoration failed')
        end
        entry = nil
        candidates = {}
      elseif entry and entry.message then
        stamp_result(target, entry.message)
      end
      if not ok or result_error or not staged_final_matches(state, staged, call, marker, entry) then
        if not ok then
          log:error('[reasoning control] final tool-result recording failed: %s', values)
        end
        return fail_staged_final(
          state,
          staged,
          marker,
          entry,
          candidates,
          not ok and 'reasoning final result recording failed'
            or (
              result_error and 'reasoning final result append integrity failed'
              or 'reasoning final result did not match its prepared transaction'
            )
        )
      end
      return commit_and_emit_final(state, staged, marker, entry, candidates)
    end
    if marker.status == 'external' then
      if not ok then
        log:error('[reasoning control] external tool-result recording failed: %s', values)
        halt_internal(state, 'Structured reasoning halted after tool-result recording failed.', state.phase)
        return
      end
      local entry, result_error = recorded_result_entry(target, marker, snapshot)
      if result_error == 'history_boundary_changed' then
        if not restore_recorded_history(target, snapshot) then
          log:error('[reasoning control] external result history restoration failed')
        end
        halt_internal(state, 'Structured reasoning halted after external result history changed.', state.phase)
        return
      elseif result_error then
        halt_internal(state, 'Structured reasoning halted after external result integrity failed.', state.phase)
        return
      elseif entry and entry.message then
        stamp_result(target, entry.message)
      end
      marker.status = 'classified'
      return unpack(values, 1, values.n)
    end

    local entry, result_error = recorded_result_entry(target, marker, snapshot)
    if result_error == 'history_boundary_changed' then
      if not restore_recorded_history(target, snapshot) then
        log:error('[reasoning control] reasoning result history restoration failed')
      end
      entry = nil
    end
    if not ok or result_error then
      if not ok then
        log:error('[reasoning control] tool-result recording failed: %s', values)
      end
      internal_result(
        state,
        marker,
        entry,
        not ok and 'reasoning tool-result recording failed' or 'reasoning tool-result append integrity failed',
        State.get(target) and 'active' or state.phase
      )
      return
    end
    stamp_result(target, entry.message)
    if
      call.id ~= marker.call_id
      or (call.call_id or nil) ~= marker.response_call_id
      or type(call['function']) ~= 'table'
      or call['function'].name ~= marker.tool_name
      or not recorded_result_correlation_valid(target, entry.message, marker, entry)
    then
      internal_result(state, marker, entry, 'reasoning call/result correlation changed before classification')
      return
    end
    local classified, classification_error = xpcall(function()
      classify_recorded_result(state, marker, entry)
    end, debug.traceback)
    if not classified then
      log:error('[reasoning control] tool-result classification failed: %s', classification_error)
      internal_result(
        state,
        marker,
        entry,
        'reasoning tool-result classification failed internally',
        State.get(target) and 'active' or state.phase
      )
    end
    return unpack(values, 1, values.n)
  end)

  local clear = state.methods.clear
  install_wrapper(clear, function(target, ...)
    local current = chat_for(state)
    if not current or current ~= target or state.closed or state.clearing then
      return
    end
    state.clearing = true
    local extra = packed(...)
    local result = packed(xpcall(function()
      reset_for_clear(state, target)
      return clear.original(target, unpack(extra, 1, extra.n))
    end, debug.traceback))
    state.clearing = false
    if not result[1] then
      error(result[2], 0)
    end
    return unpack(result, 2, result.n)
  end)

  local close = state.methods.close
  install_wrapper(close, function(target, ...)
    local current = chat_for(state)
    if not current or current ~= target or not begin_close(state, target) then
      return
    end
    local extra = packed(...)
    local result = packed(xpcall(function()
      return close.original(target, unpack(extra, 1, extra.n))
    end, debug.traceback))
    cleanup_closed(state, target)
    if not result[1] then
      error(result[2], 0)
    end
    return unpack(result, 2, result.n)
  end)

  local execute = state.methods.execute
  install_wrapper(execute, function(target, host_chat, calls, ...)
    local current = chat_for(state)
    if not current or host_chat ~= current or target ~= current.tools then
      return
    end
    if state.closed or state.clearing then
      return
    end
    if dormant_passthrough(state, current) then
      return execute.original(target, host_chat, calls, ...)
    end
    if state.executing_scope ~= nil or current.tool_orchestrator ~= nil then
      return
    end
    M.reconcile(current)
    if
      state.unsupported_adapter
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
    if state.closed or state.clearing or dormant_passthrough(state, current) then
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

  local on_submitted = function(callback_chat, data)
    local current = chat_for(state)
    local payload = type(data) == 'table' and data.payload or nil
    local dormant_lease = state.dormant_submit_stack[#state.dormant_submit_stack]
    if
      current
      and callback_chat == current
      and state.phase == 'dormant'
      and dormant_lease
      and type(payload) == 'table'
    then
      dormant_lease.payloads[payload] = true
      if state.clear_during_submit or dormant_lease.valid == false then
        state.invalidated_submissions[payload] = true
      end
      return
    end
    if
      current
      and callback_chat == current
      and state.clear_during_submit
      and state.phase == 'dormant'
      and type(payload) == 'table'
    then
      state.invalidated_submissions[payload] = true
      return
    end
    if
      not current
      or callback_chat ~= current
      or state.closed
      or state.clearing
      or not state.submitting
      or state.submit_epoch ~= state.epoch
      or not recoverable_phase[state.phase]
    then
      return
    end
    state.request_generation = state.request_generation + 1
    state.completion_classified = false
    state.observed_call_ids[state.request_generation] = {}
    state.construction_lease = {
      valid = true,
      epoch = state.epoch,
      generation = state.request_generation,
      payload = type(data) == 'table' and data.payload or nil,
      consumed = false,
      phase = state.phase,
      consecutive_violations = state.consecutive_violations,
    }
    local fallback = state.fallback_lease
    if fallback and fallback.epoch == state.epoch and fallback.generation < state.request_generation then
      fallback.valid = false
      state.fallback_lease = nil
    end
    if state.resume_attempt and state.resume_attempt.epoch == state.epoch then
      state.resume_attempt.confirmed = true
      state.resume_attempt.generation = state.request_generation
    end
  end
  state.callbacks.on_submitted = on_submitted
  chat:add_callback('on_submitted', on_submitted)

  local on_ready = function(callback_chat)
    local current = chat_for(state)
    if current and callback_chat == current and not state.closed and not state.clearing then
      schedule_fallback(state)
    end
  end
  state.callbacks.on_ready = on_ready
  chat:add_callback('on_ready', on_ready)

  local on_cancelled = function(callback_chat)
    local current = chat_for(state)
    if not current or callback_chat ~= current or state.closed or state.clearing then
      return
    end
    local token = state.active_request_token
    invalidate_marker(state.fallback_lease)
    invalidate_marker(state.construction_lease)
    invalidate_marker(token)
    invalidate_marker(state.resume_attempt)
    state.fallback_lease = nil
    state.construction_lease = nil
    state.active_request_token = nil
    state.request_handle = nil
    state.resume_attempt = nil
    state.completion_classified = true
    state.epoch = state.epoch + 1
    if type(current.remove_tagged_message) == 'function' then
      pcall(current.remove_tagged_message, current, Constants.corrective_tag)
    end
    state.pending_stop_token = {
      valid = true,
      token = token,
      cleanup_epoch = state.epoch,
      generation = state.request_generation,
    }
  end
  state.callbacks.on_cancelled = on_cancelled
  chat:add_callback('on_cancelled', on_cancelled)

  local on_closed = function(callback_chat)
    local current = chat_for(state)
    if not current or callback_chat ~= current then
      return
    end
    begin_close(state, current)
    cleanup_closed(state, current)
  end
  state.callbacks.on_closed = on_closed
  chat:add_callback('on_closed', on_closed)
  if not state.resume_command_installed then
    block_boundary(
      chat,
      state,
      'resume_command',
      'Structured reasoning is blocked because its explicit recovery command could not be installed; recreate this chat.'
    )
  end
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
      if type(bufnr) ~= 'number' or not vim.api.nvim_buf_is_valid(bufnr) then
        return
      end
      local chat = require('codecompanion').buf_get_chat(bufnr)
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

  if state.phase == 'dormant' and not attached then
    state.boundary_issue = nil
    return state
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
  if not resume_command_present(state) then
    block_boundary(
      chat,
      state,
      'resume_command',
      'Structured reasoning is blocked because its explicit recovery command is unavailable; recreate this chat.'
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

function M.stage_final(chat, tool, finalization)
  local state = type(chat) == 'table' and controllers[chat] or nil
  local call = type(tool) == 'table' and tool.function_call or nil
  local marker = state and type(call) == 'table' and state.call_tokens[call] or nil
  local stage = type(finalization) == 'table' and finalization.stage or nil
  if
    not state
    or state.closed
    or state.unsupported_adapter
    or state.boundary_issue ~= nil
    or state.phase ~= 'active'
    or state.staged_final ~= nil
    or not callbacks_allowed(chat, state)
    or not chat.adapter
    or chat.adapter.type ~= 'http'
    or type(tool) ~= 'table'
    or tool.name ~= 'reasoning_synthesis'
    or type(call) ~= 'table'
    or type(call.id) ~= 'string'
    or call.id == ''
    or type(call['function']) ~= 'table'
    or call['function'].name ~= tool.name
    or not marker
    or marker.valid == false
    or marker.invalidated
    or marker.status ~= 'executing'
    or marker.epoch ~= state.epoch
    or marker.generation ~= state.request_generation
    or marker.operation ~= 'synthesis'
    or marker.adapter ~= chat.adapter
    or marker.tool_name ~= tool.name
    or marker.call_id ~= call.id
    or marker.response_call_id ~= (call.call_id or nil)
    or type(stage) ~= 'table'
    or stage.state ~= 'prepared'
    or type(stage.workspace) ~= 'table'
    or stage.workspace ~= State.get(chat)
    or marker.workspace ~= stage.workspace
    or marker.revision ~= stage.revision
    or stage.revision ~= stage.workspace.revision
    or type(stage.candidate) ~= 'table'
    or stage.candidate.kind ~= 'synthesis'
    or stage.candidate.status ~= 'active'
    or type(stage.candidate.data) ~= 'table'
    or stage.candidate.data.mode ~= 'final'
    or stage.workspace_id ~= stage.workspace.id
    or stage.reserved_id ~= stage.candidate.id
    or type(finalization.markdown) ~= 'string'
    or vim.trim(finalization.markdown) == ''
  then
    return nil, 'reasoning final stage is unavailable'
  end

  local staged = {
    generation = state.request_generation,
    epoch = state.epoch,
    call_id = call.id,
    response_call_id = call.call_id,
    call = call,
    call_snapshot = vim.deepcopy(call),
    marker = marker,
    adapter = chat.adapter,
    workspace = stage.workspace,
    revision = stage.revision,
    reserved_id = stage.reserved_id,
    stage = stage,
    candidate = vim.deepcopy(stage.candidate),
    workspace_prepared = vim.deepcopy(stage.workspace),
    markdown = finalization.markdown,
    markdown_hash = Hash.hash({ content = finalization.markdown }),
    recording = false,
  }
  state.staged_final = staged
  state.phase = 'finalizing'
  invalidate_marker(state.fallback_lease)
  state.fallback_lease = nil
  if type(chat.remove_tagged_message) == 'function' then
    pcall(chat.remove_tagged_message, chat, Constants.corrective_tag)
  end
  local subscribers = chat.subscribers
  local stopped = type(subscribers) == 'table'
    and type(subscribers.stop) == 'function'
    and pcall(subscribers.stop, subscribers)
  local boundary_ok = stopped
    and final_boundary_current(state, staged, marker)
    and State.get(chat) == staged.workspace
    and staged.workspace.revision == staged.revision
    and vim.deep_equal(staged.workspace, staged.workspace_prepared)
    and staged.stage.workspace == staged.workspace
    and staged.stage.revision == staged.revision
    and staged.stage.state == 'prepared'
    and staged.stage.reserved_id == staged.reserved_id
    and staged.stage.candidate.id == staged.reserved_id
  if not boundary_ok then
    if state.staged_final == staged then
      State.discard_final(staged.stage)
      state.staged_final = nil
      if state.phase == 'finalizing' then
        halt_internal(state, 'Structured reasoning halted because final-stage ownership changed.', 'active')
      end
    end
    return nil, 'reasoning final stage could not stop automatic submission'
  end
  return true
end

function M.resume(chat)
  local state = type(chat) == 'table' and controllers[chat] or nil
  if not state or state.closed or state.clearing then
    return false
  end
  M.reconcile(chat)
  if
    (state.phase ~= 'halted' and state.phase ~= 'finalized')
    or state.unsupported_adapter
    or state.boundary_issue ~= nil
    or not chat.adapter
    or chat.adapter.type ~= 'http'
    or configured_target_is_acp(chat)
    or not complete_tool_set(chat)
    or not live_tools_match(chat, state)
    or not wrappers_intact(state)
    or chat.current_request ~= nil
    or state.active_request_token ~= nil
    or state.request_handle ~= nil
    or state.pending_stop_token ~= nil
    or state.construction_lease ~= nil
    or state.resume_attempt ~= nil
    or chat.tool_orchestrator ~= nil
  then
    return false
  end

  local ok_parser, pending = pcall(function()
    local parser = require('codecompanion.interactions.chat.parser')
    return parser.messages(chat, chat.header_line)
  end)
  local has_input = ok_parser and pending and type(pending.content) == 'string' and vim.trim(pending.content) ~= ''
  if not has_input then
    return false
  end

  local previous = {
    phase = state.phase,
    resume_phase = state.resume_phase,
    count = state.consecutive_violations,
    lease = state.fallback_lease,
    halt_notified = state.halt_notified,
  }
  local target = state.phase == 'finalized' and 'reframing' or state.resume_phase
  if not recoverable_phase[target] then
    return false
  end

  invalidate_marker(previous.lease)
  invalidate_marker(state.pending_stop_token)
  state.pending_stop_token = nil
  state.epoch = state.epoch + 1
  state.fallback_lease = nil
  state.consecutive_violations = 0
  state.phase = target
  state.halt_notified = false
  local attempt = {
    valid = true,
    confirmed = false,
    constructed = false,
    generation = nil,
    request_token = nil,
    epoch = state.epoch,
  }
  state.resume_attempt = attempt
  if type(chat.remove_tagged_message) == 'function' then
    pcall(chat.remove_tagged_message, chat, Constants.corrective_tag)
  end
  local submission_snapshot = snapshot_resume_submission(chat)

  local ok = pcall(chat.submit, chat, {})
  local token = attempt.request_token
  local confirmed = ok
    and state.resume_attempt == attempt
    and attempt.confirmed
    and attempt.constructed
    and token ~= nil
    and token.valid ~= false
    and not token.invalidated
    and state.epoch == attempt.epoch
    and ((state.active_request_token == token and chat.current_request ~= nil) or token.settled == true)
  state.request_handle = confirmed and chat.current_request or nil
  if state.resume_attempt == attempt then
    state.resume_attempt = nil
  end
  attempt.valid = false
  if confirmed then
    return true
  end

  local preserve_internal_halt = state.phase == 'halted' and state.epoch ~= attempt.epoch
  local preserve_reset = state.closed or state.phase == 'dormant'
  if token and state.active_request_token == token then
    local partial = chat.current_request or token.handle
    token.invalidated = true
    state.active_request_token = nil
    chat.current_request = nil
    state.request_handle = nil
    if partial and type(partial.cancel) == 'function' then
      pcall(partial.cancel, partial)
    end
  elseif token then
    token.invalidated = true
  end
  if state.pending_stop_token and state.pending_stop_token.token == token then
    invalidate_marker(state.pending_stop_token)
    state.pending_stop_token = nil
  end
  local construction = state.construction_lease
  if construction and construction.epoch == attempt.epoch and construction.generation == attempt.generation then
    construction.consumed = true
    construction.valid = false
    state.construction_lease = nil
  end
  if attempt.generation == state.request_generation then
    state.completion_classified = true
  end
  if state.epoch == attempt.epoch then
    state.epoch = state.epoch + 1
  end
  if not preserve_reset then
    restore_resume_submission(chat, submission_snapshot)
  end
  if preserve_internal_halt or preserve_reset then
    return false
  end

  state.phase = previous.phase
  state.resume_phase = previous.resume_phase
  state.consecutive_violations = previous.count
  state.fallback_lease = nil
  state.halt_notified = previous.halt_notified
  emit_status(
    chat,
    state,
    ok and 'Reasoning resume did not construct a request.' or 'Reasoning resume failed internally.'
  )
  return false
end

function M.clear(chat)
  local state = controllers[chat]
  if not state or state.closed then
    Terminal.clear(chat)
    State.clear(chat)
    return false
  end
  if state.clearing then
    return false
  end
  state.clearing = true
  local ok, result = xpcall(function()
    return reset_for_clear(state, chat)
  end, debug.traceback)
  state.clearing = false
  if not ok then
    error(result, 0)
  end
  return result
end

function M.uninstall(chat)
  local state = controllers[chat]
  if
    not state
    or state.closed
    or state.clearing
    or state.processing_done
    or state.submitting
    or state.clear_during_submit
    or #state.dormant_submit_stack > 0
    or state.protected_submit_depth > 0
    or not state.completion_classified
    or chat.current_request ~= nil
    or state.request_handle ~= nil
    or state.active_request_token ~= nil
    or state.pending_stop_token ~= nil
    or state.executing_scope ~= nil
    or chat.tool_orchestrator ~= nil
    or state.fallback_lease ~= nil
    or state.construction_lease ~= nil
    or state.resume_attempt ~= nil
    or state.staged_final ~= nil
    or not wrappers_owned_for_uninstall(state, chat)
  then
    return false
  end
  Terminal.clear(chat)
  delete_resume_command(state)
  remove_controller_callbacks(state, chat)
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
    if state and not M.uninstall(chat) then
      if not state.closed then
        begin_close(state, chat)
      end
      local request = chat.current_request or state.request_handle
      chat.current_request = nil
      state.request_handle = nil
      if request and type(request.cancel) == 'function' then
        pcall(request.cancel, request)
      end
      cleanup_closed(state, chat)
    end
  end
  controllers = setmetatable({}, { __mode = 'k' })
  unsupported_notified = setmetatable({}, { __mode = 'k' })
  pcall(vim.api.nvim_del_augroup_by_name, Constants.augroup)
end

return M
