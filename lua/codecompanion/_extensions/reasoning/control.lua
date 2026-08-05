local Constants = require('codecompanion._extensions.reasoning.constants')
local Adapters = require('codecompanion.adapters')
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
    submit_epoch = nil,
    submit_prior_violations = nil,
    clearing = false,
    processing_done = false,
    boundary_issue = nil,
    halt_notified = false,
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
    marker.invalidated = true
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
        phase = state.phase,
        request_token = state.active_request_token,
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
  return message.tool_call_id == marker.call_id
    or tools.id == marker.call_id
    or tools.call_id == marker.call_id
    or (marker.response_call_id ~= nil and tools.call_id == marker.response_call_id)
end

local function snapshot_recorded_result(chat, marker)
  local snapshot = { refs = {}, existing = nil, content = nil }
  for _, message in ipairs(chat.messages or {}) do
    snapshot.refs[message] = true
    local tools = type(message) == 'table' and type(message.tools) == 'table' and message.tools or nil
    if not snapshot.existing and marker.call_id and tools and tools.call_id == marker.call_id then
      snapshot.existing = message
      snapshot.content = message.content
    end
  end
  return snapshot
end

local function recorded_result_entry(chat, marker, snapshot)
  if snapshot.existing then
    local present = false
    for _, message in ipairs(chat.messages or {}) do
      present = present or message == snapshot.existing
    end
    local before = snapshot.content
    local after = snapshot.existing.content
    local prefix = type(before) == 'string' and (before == '' and '' or before .. '\n\n') or nil
    if not present or type(after) ~= 'string' or not prefix or after:sub(1, #prefix) ~= prefix then
      return { message = present and snapshot.existing or nil, prefix = prefix or '' }, 'append_prefix_changed'
    end
    return {
      message = snapshot.existing,
      prefix = prefix,
      delta = after:sub(#prefix + 1),
    }
  end

  local found
  for index = #(chat.messages or {}), 1, -1 do
    local message = chat.messages[index]
    if not snapshot.refs[message] and result_matches_call(message, marker) then
      if found then
        return found, 'multiple_results'
      end
      found = { message = message, prefix = '', delta = message.content }
    end
  end
  if not found or type(found.delta) ~= 'string' then
    return found, 'result_missing'
  end
  return found
end

local function stamp_result(chat, message)
  message._meta = type(message._meta) == 'table' and message._meta or {}
  message._meta.cycle = message._meta.cycle or chat.cycle
  message._meta.id = Hash.hash({ role = message.role, content = message.content })
end

local function fallback_result_message(chat, marker, encoded)
  local call = {
    id = marker.call_id,
    call_id = marker.response_call_id,
    ['function'] = { name = marker.tool_name },
  }
  local ok, message = pcall(Adapters.call_handler, chat.adapter, 'format_response', call, encoded)
  if
    not ok
    or type(message) ~= 'table'
    or type(message.content) ~= 'string'
    or not result_matches_call(message, marker)
  then
    message = {
      role = chat.adapter.roles and chat.adapter.roles.tool or 'tool',
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
  message.role = message.role or (chat.adapter.roles and chat.adapter.roles.tool) or 'tool'
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
    entry.message.content = (entry.prefix or '') .. encoded
    stamp_result(chat, entry.message)
    return entry.message
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

  local expected = {
    workspace_id = workspace.id,
    artifact = vim.deepcopy(primary),
    progress = vim.deepcopy(workspace.counts_by_kind),
    unmet_gates = marker.operation == 'synthesis'
        and type(marker.decoded_arguments) == 'table'
        and marker.decoded_arguments.mode == 'final'
        and {}
      or Protocol.final_gates(workspace, nil),
    next_action = Protocol.transition(workspace, 'active'),
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
    local ok, values = xpcall(function()
      return packed(submit.original(current, opts, unpack(extra, 1, extra.n)))
    end, debug.traceback)
    state.submitting = false
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
      lease.consumed = true
      state.construction_lease = nil
      if not state.closed and state.phase ~= 'dormant' then
        fail_request_construction(state, nil, prior_phase)
      else
        state.completion_classified = true
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
    if marker and (marker.status == 'synthetic' or marker.status == 'classified') then
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
    local extra = packed(...)
    local ok, values = xpcall(function()
      return packed(add_tool_output.original(target, tool, unpack(extra, 1, extra.n)))
    end, debug.traceback)
    if marker.status == 'external' then
      if not ok then
        log:error('[reasoning control] external tool-result recording failed: %s', values)
        halt_internal(state, 'Structured reasoning halted after tool-result recording failed.', state.phase)
        return
      end
      local entry, result_error = recorded_result_entry(target, marker, snapshot)
      if entry and not result_error and entry.message then
        stamp_result(target, entry.message)
      end
      marker.status = 'classified'
      return unpack(values, 1, values.n)
    end

    local entry, result_error = recorded_result_entry(target, marker, snapshot)
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
      or not result_matches_call(entry.message, marker)
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

  local on_submitted = function(callback_chat, data)
    local current = chat_for(state)
    if
      not current
      or callback_chat ~= current
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
    if current and callback_chat == current then
      schedule_fallback(state)
    end
  end
  state.callbacks.on_ready = on_ready
  chat:add_callback('on_ready', on_ready)

  local on_cancelled = function(callback_chat)
    local current = chat_for(state)
    if not current or callback_chat ~= current then
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
  if type(chat.remove_callback) == 'function' then
    for event, callback in pairs(state.callbacks) do
      chat:remove_callback(event, callback)
    end
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
