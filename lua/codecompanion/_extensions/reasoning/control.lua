local Constants = require('codecompanion._extensions.reasoning.constants')
local Protocol = require('codecompanion._extensions.reasoning.protocol')
local State = require('codecompanion._extensions.reasoning.state')
local Terminal = require('codecompanion._extensions.reasoning.terminal')

local M = {}
local controllers = setmetatable({}, { __mode = 'k' })
local unsupported_notified = setmetatable({}, { __mode = 'k' })

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

local function complete_tool_set(chat)
  if type(chat) ~= 'table' then
    return false
  end
  local in_use = chat.tool_registry and chat.tool_registry.in_use or {}
  for _, name in ipairs(Constants.tool_names) do
    if in_use[name] ~= true then
      return false
    end
  end
  return true
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
  for token, value in pairs(state.call_tokens) do
    invalidate_marker(token)
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
      or state.clearing
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
    if extra[3] ~= nil then
      extra[2] = nil
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
  install_wrapper(add_buf_message, pass_through(add_buf_message))

  local add_tool_output = state.methods.add_tool_output
  install_wrapper(add_tool_output, function(target, ...)
    if not callbacks_allowed(target, state) then
      return
    end
    return add_tool_output.original(target, ...)
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
  install_wrapper(execute, function(target, ...)
    local current = chat_for(state)
    if not current or target ~= current.tools or not callbacks_allowed(current, state) then
      return
    end
    return execute.original(target, ...)
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
  local complete = complete_tool_set(chat)
  if complete then
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
    return install(chat, hydrated_phase(chat))
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

  if not complete then
    block_boundary(
      chat,
      state,
      'tools_incomplete',
      'Structured reasoning is blocked until all reasoning tools are reattached.'
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
  local complete = complete_tool_set(chat)
  if not state then
    return complete and 'blocked' or nil
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
  if complete_tool_set(chat) then
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
