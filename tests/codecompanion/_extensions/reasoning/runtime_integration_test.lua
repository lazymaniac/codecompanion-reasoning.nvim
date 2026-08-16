local CodeCompanion = require('codecompanion')
local Adapters = require('codecompanion.adapters')
local CCConfig = require('codecompanion.config')
local Constants = require('codecompanion._extensions.reasoning.constants')
local Extension = require('codecompanion._extensions.reasoning')
local TreeFixture = require('support.tree_fixture')
local ToolRegistry = require('codecompanion.interactions.chat.tool_registry')
local ToolRuntime = require('codecompanion.interactions.chat.tools')
local Builder = require('codecompanion.interactions.chat.ui.builder')
local Approvals = require('codecompanion.interactions.chat.tools.approvals')
local Parser = require('codecompanion.interactions.chat.parser')
local Log = require('codecompanion.utils.log')
local Hash = require('codecompanion.utils.hash')
local Utils = require('codecompanion.utils')
local Control = require('codecompanion._extensions.reasoning.control')
local Protocol = require('codecompanion._extensions.reasoning.protocol')
local Render = require('codecompanion._extensions.reasoning.render')
local State = require('codecompanion._extensions.reasoning.state')
local canonical_parser_messages = Parser.messages

local names = {
  'reasoning_frame',
  'reasoning_evidence',
  'reasoning_options',
  'reasoning_review',
  'reasoning_synthesis',
  'reasoning_question',
}

local buffers = {}
local original_log
local original_tools
local original_buf_get_chat
local original_global_adapter
local chats_by_buffer = {}
local call_sequence = 0

local T = MiniTest.new_set({
  hooks = {
    pre_case = function()
      original_log = Log.get_root()
      original_tools = vim.deepcopy(CCConfig.interactions.chat.tools)
      original_buf_get_chat = CodeCompanion.buf_get_chat
      Parser.messages = canonical_parser_messages
      original_global_adapter = vim.g.codecompanion_adapter
      vim.g.codecompanion_adapter = nil
      Control._reset()
      State._reset()
      local opts = CCConfig.interactions.chat.tools.opts
      opts.auto_submit_success = false
      opts.auto_submit_errors = false
      opts.default_tools = {}
      opts.system_prompt = vim.tbl_deep_extend('force', opts.system_prompt or {}, { enabled = false })
      Extension.setup({ auto_attach = false })
      for _, name in ipairs({ 'fixture_search', 'fixture_read', 'fixture_hold' }) do
        local tool_name = name
        CCConfig.interactions.chat.tools[name] = {
          description = 'Runtime integration external project tool',
          schema = {
            type = 'function',
            ['function'] = {
              name = tool_name,
              description = 'Inspect project context',
              parameters = { type = 'object', properties = {} },
            },
          },
          cmds = {
            function(tools, args, run_opts)
              local owner = tools.chat
              owner.external_calls = (owner.external_calls or 0) + 1
              if tool_name == 'fixture_hold' then
                owner.held_output_cb = run_opts.output_cb
                return
              end
              if tool_name == 'fixture_read' and args.fail then
                return { status = 'error', data = 'fixture read failed' }
              end
              return { status = 'success', data = tool_name .. ' completed' }
            end,
          },
        }
      end
      CodeCompanion.buf_get_chat = function(bufnr)
        return chats_by_buffer[bufnr]
      end
      Parser.messages = function(chat, header_line)
        chat.parser_calls = (chat.parser_calls or 0) + 1
        chat.last_parser_header = header_line
        if type(chat.pending_input) ~= 'string' then
          return nil
        end
        return { content = chat.pending_input }
      end
      call_sequence = 0
    end,
    post_case = function()
      Log.set_root(original_log)
      CodeCompanion.buf_get_chat = original_buf_get_chat
      Parser.messages = canonical_parser_messages
      vim.g.codecompanion_adapter = original_global_adapter
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
      chats_by_buffer = {}
    end,
  },
})
local eq = MiniTest.expect.equality

local function new_chat(id, opts)
  opts = opts or {}
  local bufnr = vim.api.nvim_create_buf(false, true)
  table.insert(buffers, bufnr)
  local chat = {
    callbacks = {},
    cycle = 0,
    id = id,
    bufnr = bufnr,
    messages = {},
    buffer_messages = {},
    outputs = {},
    requests = {},
    tools_done_count = 0,
    submit_count = 0,
    http_count = 0,
    acp_count = 0,
    done_count = 0,
    restore_count = 0,
    request_cancel_count = 0,
    status = '',
    tokens = 0,
    current_request = nil,
    header_line = 1,
    parsers = {},
    _btw = nil,
    _last_role = CCConfig.constants.USER_ROLE,
  }
  chat.adapter = {
    name = opts.adapter_name or 'reasoning_test',
    type = opts.adapter_type or 'http',
    roles = { tool = 'tool' },
    features = { tokens = true },
    opts = { stream = true },
    available_tools = {},
    handlers = {
      lifecycle = {},
      response = {
        build_reasoning = function(_, reasoning)
          return reasoning
        end,
        parse_chat = function(_, data, extracted_tools)
          if type(data) == 'table' and type(data.tool_calls) == 'table' then
            vim.list_extend(extracted_tools, data.tool_calls)
          end
          return data
        end,
        parse_tokens = function(_, data)
          return data and data.tokens or nil
        end,
        parse_meta = function(_, result)
          return result
        end,
      },
      tools = {
        format_calls = function(_, tool_calls)
          return tool_calls
        end,
        format_response = function(adapter, tool_call, output)
          return {
            role = adapter.roles and adapter.roles.tool or 'tool',
            content = output,
            tool_call_id = tool_call.id,
            tools = {
              id = tool_call.id,
              call_id = tool_call.call_id or tool_call.id,
              name = tool_call['function'] and tool_call['function'].name,
            },
            opts = { visible = false },
          }
        end,
      },
    },
  }
  chat.MESSAGE_TYPES = {
    LLM_MESSAGE = 'llm_message',
    REASONING_MESSAGE = 'reasoning_message',
    SYSTEM_MESSAGE = 'system_message',
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
    if message.tool_calls then
      message.tools = { calls = message.tool_calls }
      message.tool_calls = nil
    end
    message._meta = message._meta or (opts and vim.deepcopy(opts._meta))
    message.visible = message.visible ~= nil and message.visible or (opts and opts.visible)
    message.opts = vim.deepcopy(opts)
    table.insert(self.messages, message)
    return message
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
  function chat:dispatch_cancellable(event, ...)
    for _, callback in ipairs(vim.list_slice(self.callbacks[event] or {}, 1)) do
      if callback(self, ...) == false then
        return true
      end
    end
    return false
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
    local message = Adapters.call_handler(self.adapter, 'format_response', call, for_llm)
    if not message then
      return
    end
    message._meta = { cycle = self.cycle }
    message._meta.id = Hash.hash({ role = message.role, content = message.content })
    message.opts = vim.tbl_extend('force', message.opts or {}, { visible = true })
    local existing
    for _, candidate in ipairs(self.messages) do
      if candidate.tools and candidate.tools.call_id == call.id then
        existing = candidate
        break
      end
    end
    if existing then
      existing.content = existing.content == '' and message.content or (existing.content .. '\n\n' .. message.content)
    else
      table.insert(self.messages, message)
    end
    if for_user ~= '' then
      self:add_buf_message(
        { role = 'assistant', content = for_user or for_llm },
        { type = self.MESSAGE_TYPES.TOOL_MESSAGE }
      )
    end
  end
  function chat:tools_done(opts)
    self.tools_done_count = self.tools_done_count + 1
    self:ready_for_input(opts)
  end
  function chat:submit(opts)
    if self.current_request then
      return
    end
    opts = opts or {}
    self.submit_count = self.submit_count + 1
    if opts and opts.callback then
      opts.callback()
    end
    if self.adapter.type == 'http' then
      self.tools:refresh({ adapter = self.adapter })
    end
    if not opts.auto_submit then
      local pending = Parser.messages(self, self.header_line)
      local has_user = false
      for _, message in ipairs(self.messages) do
        has_user = has_user or message.role == CCConfig.constants.USER_ROLE
      end
      if not pending and not has_user then
        return
      end
      if self:dispatch_cancellable('on_before_submit', { adapter = self.adapter }) then
        return self:restore()
      end
      if pending and type(pending.content) == 'string' and vim.trim(pending.content) ~= '' then
        self:add_message({ role = CCConfig.constants.USER_ROLE, content = pending.content }, { visible = true })
        self.header_line = self.header_line + 1
      end
    end
    local shallow_messages = {}
    for index, message in ipairs(self.messages) do
      shallow_messages[index] = vim.tbl_extend('force', {}, message)
    end
    local payload = {
      messages = shallow_messages,
      marker = {},
      cycle = self.cycle,
      tools = not vim.tbl_isempty(self.tool_registry.schemas) and { self.tool_registry.schemas } or {},
    }
    self.last_submitted_payload = payload
    self:dispatch('on_submitted', { payload = payload })
    if self.adapter.type == 'http' then
      return self:_submit_http(payload)
    end
    return self:_submit_acp(payload)
  end
  function chat:_submit_http(payload)
    local owner = self.fixture_owner or self
    self.http_count = self.http_count + 1
    self.last_transport_payload = payload
    self.last_request_self = self
    local handle_status = 'pending'
    local handle = {
      id = 'request-' .. tostring(self.http_count),
      status = function()
        return handle_status
      end,
      set_status = function(_, value)
        handle_status = value
      end,
      cancel = function()
        if handle_status ~= 'cancelled' then
          handle_status = 'cancelled'
          owner.request_cancel_count = owner.request_cancel_count + 1
        end
        if owner.on_request_cancel then
          owner.on_request_cancel(owner)
        end
      end,
    }
    local output, reasoning, tool_calls, meta = {}, {}, {}, {}
    local adapter = self.adapter
    local function process(data)
      if adapter.features and adapter.features.tokens then
        local tokens = Adapters.call_handler(adapter, 'parse_tokens', data)
        if tokens then
          self.tokens = tokens
        end
      end
      local result = Adapters.call_handler(adapter, 'parse_chat', data, tool_calls)
      local parse_meta = Adapters.get_handler(adapter, 'parse_meta')
      if result and result.extra and type(parse_meta) == 'function' then
        result = parse_meta(adapter, result)
      end
      if not (result and result.status) then
        return
      end
      self.status = result.status
      if result.status == 'success' then
        if result.output and result.output.role then
          result.output.role = CCConfig.constants.LLM_ROLE
          self._last_role = result.output.role
        end
        if result.output and result.output.reasoning then
          table.insert(reasoning, result.output.reasoning)
          self:add_buf_message({ role = 'assistant', content = result.output.reasoning.content or '' }, {
            type = self.MESSAGE_TYPES.REASONING_MESSAGE,
          })
        end
        if result.output and result.output.content then
          table.insert(output, result.output.content)
          self:add_buf_message({ role = 'assistant', content = result.output.content }, {
            type = self.MESSAGE_TYPES.LLM_MESSAGE,
          })
        end
        if result.output and result.output.meta then
          meta = vim.tbl_deep_extend('force', meta, result.output.meta)
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
        process(data)
      end,
      on_status = function(value)
        handle_status = value
        self.status = value
      end,
      on_done = function(data)
        handle_status = 'success'
        if data and not (adapter.opts and adapter.opts.stream) then
          process(data)
        end
        self:done(output, reasoning, tool_calls, meta)
      end,
      on_error = function(error_value)
        handle_status = 'error'
        self.status = 'error'
        self.last_http_error = error_value
        self:done(output)
      end,
    }
    table.insert(owner.requests, request)
    if owner.sync_send then
      owner.sync_send(request)
    end
    self.current_request = handle
  end
  function chat:_submit_acp(payload)
    self.acp_count = self.acp_count + 1
    self.last_acp_payload = payload
    self.current_request = {
      cancel = function()
        self.request_cancel_count = self.request_cancel_count + 1
      end,
    }
  end
  function chat:_set_status(status)
    self.status = status
  end
  function chat:ready_for_input()
    self:dispatch('on_ready')
  end
  function chat:done(output, reasoning, tool_calls, meta, done_opts)
    self.done_count = self.done_count + 1
    self.current_request = nil
    if not vim.api.nvim_buf_is_valid(self.bufnr) then
      return
    end
    done_opts = done_opts or {}
    local reasoning_content
    if type(reasoning) == 'table' and not vim.tbl_isempty(reasoning) then
      reasoning_content = Adapters.call_handler(self.adapter, 'build_reasoning', reasoning)
    end
    if type(output) == 'table' and not vim.tbl_isempty(output) then
      self:add_message({
        role = CCConfig.constants.LLM_ROLE,
        content = vim.trim(table.concat(output, '')),
        reasoning = reasoning_content,
      }, { visible = true })
      reasoning_content = nil
    elseif type(meta) == 'table' and not vim.tbl_isempty(meta) then
      self:add_message({
        role = CCConfig.constants.LLM_ROLE,
        content = '',
        reasoning = reasoning_content,
      }, { visible = false, _meta = vim.deepcopy(meta) })
      reasoning_content = nil
    end
    if type(tool_calls) == 'table' and not vim.tbl_isempty(tool_calls) then
      local formatted = Adapters.call_handler(self.adapter, 'format_calls', tool_calls)
      if formatted then
        self:add_message({
          role = CCConfig.constants.LLM_ROLE,
          reasoning = reasoning_content,
          tool_calls = formatted,
        }, { visible = false })
        self.tools:execute(self, formatted)
        return
      end
    end
    if self._btw then
      return self:submit({ auto_submit = true })
    end
    self:ready_for_input()
    self:dispatch('on_completed', { status = self.status, stopped = done_opts.status == 'stopped' })
  end
  function chat:clear()
    self.cycle = self.cycle + 1
    self.header_line = 1
    self.messages = {}
    self.buffer_messages = {}
    self.outputs = {}
    self.context.items = {}
    self.tool_registry:clear()
    self.tools.messages = self.messages
    if vim.api.nvim_buf_is_valid(self.bufnr) then
      vim.api.nvim_buf_set_lines(self.bufnr, 0, -1, false, { '' })
    end
    Utils.fire('ChatCleared', { bufnr = self.bufnr, id = self.id })
  end
  function chat:close()
    if self.current_request then
      self:stop()
    end
    self:dispatch('on_closed')
    chats_by_buffer[self.bufnr] = nil
    pcall(vim.api.nvim_buf_delete, self.bufnr, { force = true })
  end
  function chat:restore()
    self.restore_count = self.restore_count + 1
  end
  function chat:stop()
    self.status = 'cancelling'
    self:dispatch('on_cancelled')
    local orchestrator = self.tool_orchestrator
    self.tool_orchestrator = nil
    if orchestrator and type(orchestrator.cancel) == 'function' then
      orchestrator:cancel()
    end
    local request = self.current_request
    self.current_request = nil
    if request and type(request.cancel) == 'function' then
      request.cancel()
    end
    vim.schedule(function()
      self:done(nil, nil, nil, nil, { status = 'stopped' })
    end)
  end

  chat.fixture_owner = chat
  chat.tools = ToolRuntime.new({ adapter = chat.adapter, bufnr = bufnr, messages = chat.messages })
  chat.tools.chat = chat
  chat.tool_registry = ToolRegistry.new({ chat = chat, ctx = {} })
  chats_by_buffer[bufnr] = chat
  return chat
end

local function enable_locked_context_lifecycle(chat)
  local user_role = CCConfig.constants.USER_ROLE
  local function set_modifiable(value)
    vim.bo[chat.bufnr].modified = false
    vim.bo[chat.bufnr].modifiable = value
  end

  chat.ui = {
    folds = { create_reasoning_fold = function() end, create_tool_fold = function() end },
    unlock_buf = function()
      set_modifiable(true)
    end,
    lock_buf = function()
      set_modifiable(false)
    end,
    last = function()
      local last = vim.api.nvim_buf_line_count(chat.bufnr) - 1
      local line = vim.api.nvim_buf_get_lines(chat.bufnr, last, last + 1, false)[1] or ''
      return last, #line
    end,
    is_following = function()
      return false
    end,
    move_cursor = function() end,
    set_header = function(_, lines, role)
      table.insert(lines, '## ' .. role)
    end,
    render_headers = function() end,
  }
  chat.builder = Builder.new({ chat = chat })
  chat.builder.state.current_header_line = 0
  vim.api.nvim_buf_set_lines(chat.bufnr, 0, -1, false, { '## Me', '', 'Investigate this failure.' })
  chat:add_message({ role = user_role, content = 'Investigate this failure.' }, { visible = true })

  function chat:add_buf_message(message, message_opts)
    table.insert(self.buffer_messages, { message = vim.deepcopy(message), opts = vim.deepcopy(message_opts) })
    return self.builder:add_message(message, message_opts)
  end

  function chat.context:render()
    local visible = vim.tbl_filter(function(item)
      return type(item) == 'table' and (type(item.opts) ~= 'table' or item.opts.visible ~= false)
    end, self.items)
    if #visible == 0 then
      return
    end
    chat.context_render_count = (chat.context_render_count or 0) + 1
    vim.api.nvim_buf_set_lines(chat.bufnr, chat.header_line + 1, chat.header_line + 1, false, {
      '> Context:',
      '> - ' .. visible[1].id,
      '',
    })
    chat.context_render_success_count = (chat.context_render_success_count or 0) + 1
  end

  function chat:ready_for_input(ready_opts)
    ready_opts = ready_opts or {}
    if not ready_opts.auto_submit and self._last_role ~= user_role then
      self.cycle = self.cycle + 1
      self:add_buf_message({ role = user_role, content = '' })
      self.header_line = (self.builder.state.current_header_line or 0) + 1
      self.context:render()
      self:dispatch('on_ready')
    end
    self.ui:unlock_buf()
  end

  local submit = chat.submit
  function chat:submit(submit_opts)
    local transports = self.http_count
    local result = submit(self, submit_opts)
    if
      self.http_count > transports
      and self.current_request
      and not (type(submit_opts) == 'table' and submit_opts.auto_submit)
    then
      self.ui:lock_buf()
    end
    return result
  end
end

local function assert_group_attached(chat)
  eq(chat.tool_registry.groups.reasoning, names)
  eq(vim.tbl_count(chat.tool_registry.in_use), #names)
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
    eq(Control._get(chat) ~= nil, true)
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

local function run_scheduled(queue, callback, drain)
  queue = queue or {}
  local original_schedule = vim.schedule
  vim.schedule = function(item)
    table.insert(queue, item)
  end
  local ok, err = xpcall(callback or function() end, debug.traceback)
  if ok and drain then
    while #queue > 0 do
      local item = table.remove(queue, 1)
      local item_ok, item_err = xpcall(item, debug.traceback)
      if not item_ok then
        ok, err = false, item_err
        break
      end
    end
  end
  vim.schedule = original_schedule
  if not ok then
    error(err, 0)
  end
  return queue
end

local function drain_scheduled(queue)
  return run_scheduled(queue, nil, true)
end

local function model_call(name, arguments, id, call_id)
  call_sequence = call_sequence + 1
  local call = {
    id = id or ('reasoning-call-' .. call_sequence),
    type = 'function',
    ['function'] = { name = name, arguments = vim.deepcopy(arguments or {}) },
  }
  call.call_id = call_id
  return call
end

local function completion(calls, opts)
  opts = opts or {}
  local output = {}
  if opts.role ~= nil then
    output.role = opts.role
  end
  if opts.content ~= nil then
    output.content = opts.content
  end
  if opts.reasoning ~= nil then
    output.reasoning = { content = opts.reasoning }
  end
  if opts.meta ~= nil then
    output.meta = vim.deepcopy(opts.meta)
  end
  return {
    status = opts.status or 'success',
    output = output,
    tool_calls = calls or {},
    tokens = opts.tokens or 7,
  }
end

local function submit_request(chat, opts)
  local before = #chat.requests
  chat:submit(opts or { auto_submit = true })
  eq(#chat.requests, before + 1)
  local request = chat.requests[#chat.requests]
  eq(request.payload == chat.last_submitted_payload, true)
  eq(request.payload == chat.last_transport_payload, true)
  eq(request.self == chat.last_request_self, true)
  return request
end

local function complete_request(chat, request, data, drain)
  local before = #chat.outputs
  local queue = run_scheduled(nil, function()
    request.on_chunk(data or completion())
    request.on_done()
  end, drain ~= false)
  local outputs = {}
  for index = before + 1, #chat.outputs do
    table.insert(outputs, chat.outputs[index])
  end
  return outputs, queue
end

local function complete_reasoning_request(chat, name, arguments, id, opts)
  local request = submit_request(chat)
  local outputs = complete_request(chat, request, completion({ model_call(name, arguments, id) }, opts))
  eq(#outputs, 1)
  return vim.json.decode(outputs[1].for_llm), outputs[1], request
end

local function add_external_tools(chat)
  eq(chat.tool_registry:add('fixture_search') ~= nil, true)
  eq(chat.tool_registry:add('fixture_read') ~= nil, true)
end

local function complete_pending_ordinary_request(chat)
  if chat.current_request == nil then
    return
  end
  local request = chat.requests[#chat.requests]
  run_scheduled(nil, function()
    request.on_chunk(completion())
    request.on_done()
  end, true)
  eq(chat.current_request, nil)
end

local function invoke_many(chat, calls)
  local output_count = #chat.outputs
  local completed_count = chat.tools_done_count
  local tool_calls = {}
  for _, call in ipairs(calls) do
    table.insert(tool_calls, model_call(call.name, call.arguments))
  end
  run_scheduled(nil, function()
    chat.tools:execute(chat, tool_calls)
  end, true)
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

local function question_args(overrides)
  return vim.tbl_extend('force', TreeFixture.args(), overrides or {})
end

local function deep_split_args(chat)
  return question_args({
    parent_id = State.get(chat).frame_id,
    child_questions = {
      {
        text = 'Does a durable representation replay committed mutations?',
        kind = 'sub_problem',
        acceptance_test = 'Observe a replayed commit after restart',
        resolution_kind = 'observation',
      },
      {
        text = 'Does the retained journal stay bounded?',
        kind = 'sub_problem',
        acceptance_test = 'Observe retained entries after compaction',
        resolution_kind = 'observation',
      },
    },
  })
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
        addresses_questions = { 'Q1' },
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
        addresses_questions = { 'Q2' },
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

local function checkpoint_args()
  local args = synthesis_args()
  args.mode = 'checkpoint'
  args.conclusion = 'Checkpoint: the journal remains the strongest reviewed design'
  return args
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
  eq(second.submit_count, 1)
end

T['keeps external project investigation state and retry budget neutral'] = function()
  local chat = new_chat(8)
  attach_group(chat, true)
  add_external_tools(chat)

  local external_calls = {}
  for index = 1, 10 do
    local name = index % 2 == 0 and 'fixture_read' or 'fixture_search'
    table.insert(
      external_calls,
      model_call(name, {
        query = 'project query ' .. index,
        path = 'project-file-' .. index .. '.lua',
        fail = index == 2,
      }, 'external-before-' .. index)
    )
  end
  local before_frame = submit_request(chat)
  local external_before = complete_request(chat, before_frame, completion(external_calls))
  eq(#external_before, 10)
  eq(chat.external_calls, 10)
  eq(State.get(chat), nil)
  eq(Control.phase(chat), 'armed')
  eq(Control._get(chat).consecutive_violations, 0)
  eq(#chat.requests, 1)

  local frame_request = submit_request(chat)
  local frame_outputs = complete_request(
    chat,
    frame_request,
    completion({
      model_call('reasoning_frame', frame_args('Investigate with project tools'), 'frame-after-search'),
    })
  )
  local frame = vim.json.decode(frame_outputs[1].for_llm)
  eq(frame.artifact.id, 'F1')
  eq(frame.next_action.tool, 'reasoning_evidence')
  local workspace = State.get(chat)
  local snapshot = vim.deepcopy(workspace)

  local between = submit_request(chat)
  local external_between = complete_request(
    chat,
    between,
    completion({
      model_call('fixture_read', { path = 'protocol.lua' }, 'external-read-2'),
      model_call('fixture_search', { query = 'transition enforcement' }, 'external-search-2'),
    })
  )
  eq(#external_between, 2)
  eq(chat.external_calls, 12)
  eq(State.get(chat), workspace)
  eq(workspace, snapshot)
  eq(Control._get(chat).consecutive_violations, 0)
  eq(#chat.requests, 3)

  local evidence_request = submit_request(chat)
  local evidence_outputs = complete_request(
    chat,
    evidence_request,
    completion({
      model_call('reasoning_evidence', evidence_args(), 'evidence-after-search'),
    })
  )
  local evidence = vim.json.decode(evidence_outputs[1].for_llm)
  eq(evidence.artifact.id, 'E1')
  eq(evidence.next_action.tool, 'reasoning_synthesis')
  eq(Control._get(chat).consecutive_violations, 0)
  eq(#chat.requests, 4)
end

T['suppresses text reasoning and empty completions with one corrective retry each'] = function()
  local variants = {
    { id = 9, data = completion({}, { content = 'unstructured answer' }) },
    { id = 10, data = completion({}, { reasoning = 'private reasoning stream' }) },
    { id = 11, data = completion(), synchronous = true },
  }

  for _, variant in ipairs(variants) do
    local chat = new_chat(variant.id)
    attach_group(chat, true)
    local queue
    if variant.synchronous then
      chat.sync_send = function(request)
        request.on_chunk(variant.data)
        request.on_done()
      end
      queue = run_scheduled(nil, function()
        chat:submit({ auto_submit = true })
      end, false)
      chat.sync_send = nil
      eq(#chat.requests, 1)
      eq(chat.current_request, nil)
      eq(chat.requests[1].payload, chat.last_submitted_payload)
      eq(chat.requests[1].payload, chat.last_transport_payload)
      drain_scheduled(queue)
    else
      local request = submit_request(chat)
      complete_request(chat, request, variant.data)
    end

    local leaked_history = vim.tbl_filter(function(message)
      return message.role == CCConfig.constants.LLM_ROLE and type(message.content) == 'string' and message.content ~= ''
    end, chat.messages)
    local leaked_buffer = vim.tbl_filter(function(entry)
      local kind = entry.opts and entry.opts.type
      return kind == chat.MESSAGE_TYPES.LLM_MESSAGE or kind == chat.MESSAGE_TYPES.REASONING_MESSAGE
    end, chat.buffer_messages)
    eq(#leaked_history, 0)
    eq(#leaked_buffer, 0)
    eq(Control.phase(chat), 'armed')
    eq(Control._get(chat).consecutive_violations, 1)
    eq(#chat.requests, 2)
    eq(chat.submit_count, 2)
    eq(chat.http_count, 2)
    eq(chat.current_request ~= nil, true)
    chat:clear()
  end
end

T['keeps the locked host buffer lifecycle coherent after zero-call completions'] = function()
  local variants = {
    completion({}, { role = 'assistant', content = 'I will answer without the required frame.' }),
    completion({}, { role = 'assistant', reasoning = 'I will reason without the required frame.' }),
    completion(),
  }

  for index, data in ipairs(variants) do
    local chat = new_chat(20 + index)
    enable_locked_context_lifecycle(chat)
    attach_group(chat, true)
    chat.context:add({ id = '<buf>locked-context</buf>', opts = { visible = true } })

    local request = submit_request(chat, { auto_submit = false })
    eq(vim.bo[chat.bufnr].modifiable, false)
    local _, queue = complete_request(chat, request, data, false)

    eq(Control.phase(chat), 'armed')
    eq(Control._get(chat).consecutive_violations, 1)
    eq(chat.context_render_count, 1)
    eq(chat.context_render_success_count, 1)
    eq(vim.bo[chat.bufnr].modifiable, true)
    eq(#chat.requests, 1)
    eq(#vim.tbl_filter(function(entry)
      local kind = entry.opts and entry.opts.type
      return kind == chat.MESSAGE_TYPES.LLM_MESSAGE or kind == chat.MESSAGE_TYPES.REASONING_MESSAGE
    end, chat.buffer_messages), 0)

    drain_scheduled(queue)
    eq(#chat.requests, 2)
    eq(vim.bo[chat.bufnr].modifiable, true)
    chat:clear()
  end
end

T['keeps the locked host buffer lifecycle coherent after rejected tool completions'] = function()
  local chat = new_chat(24)
  enable_locked_context_lifecycle(chat)
  attach_group(chat, true)
  chat.context:add({ id = '<buf>locked-tool-context</buf>', opts = { visible = true } })

  local request = submit_request(chat, { auto_submit = false })
  eq(vim.bo[chat.bufnr].modifiable, false)
  local outputs, queue = complete_request(
    chat,
    request,
    completion({
      model_call('reasoning_evidence', evidence_args(), 'locked-rejected-tool'),
    }, { role = 'assistant' }),
    false
  )

  eq(#outputs, 1)
  eq(vim.json.decode(outputs[1].for_llm).code, 'transition_invalid')
  eq(Control.phase(chat), 'armed')
  eq(Control._get(chat).consecutive_violations, 1)
  eq(chat.tools_done_count, 1)
  eq(chat.context_render_count, 1)
  eq(chat.context_render_success_count, 1)
  eq(vim.bo[chat.bufnr].modifiable, true)
  eq(#chat.requests, 1)

  drain_scheduled(queue)
  eq(#chat.requests, 2)
  eq(vim.bo[chat.bufnr].modifiable, true)
  chat:clear()
end

T['blocks ACP once and restores the suspended HTTP phase'] = function()
  local function unsupported_count(chat)
    return #vim.tbl_filter(function(entry)
      return type(entry.message.content) == 'string'
        and entry.message.content:find('requires an HTTP adapter', 1, true) ~= nil
    end, chat.buffer_messages)
  end

  local acp = new_chat(12, { adapter_type = 'acp', adapter_name = 'reasoning_acp' })
  attach_group(acp, false)
  eq(Control._get(acp), nil)
  eq(Control.phase(acp), 'blocked')
  eq(unsupported_count(acp), 1)
  Utils.fire('ChatAdapter', { bufnr = acp.bufnr, id = acp.id, adapter = acp.adapter })
  eq(unsupported_count(acp), 1)
  eq(acp.current_request, nil)
  eq(acp.acp_count, 0)

  local chat = new_chat(13)
  attach_group(chat, true)
  chat.adapter.type = 'acp'
  Utils.fire('ChatAdapter', { bufnr = chat.bufnr, id = chat.id, adapter = chat.adapter })
  eq(Control.phase(chat), 'blocked')
  eq(Control._get(chat).unsupported_adapter, true)
  eq(unsupported_count(chat), 1)
  chat:submit({ auto_submit = true })
  eq(chat.submit_count, 0)
  eq(chat.http_count, 0)
  eq(chat.acp_count, 0)
  eq(chat.current_request, nil)
  Utils.fire('ChatAdapter', { bufnr = chat.bufnr, id = chat.id, adapter = chat.adapter })
  eq(unsupported_count(chat), 1)

  chat.adapter.type = 'http'
  Utils.fire('ChatAdapter', { bufnr = chat.bufnr, id = chat.id, adapter = chat.adapter })
  eq(Control.phase(chat), 'armed')
  eq(Control._get(chat).unsupported_adapter, false)
  local request = submit_request(chat)
  local outputs = complete_request(
    chat,
    request,
    completion({
      model_call('reasoning_frame', frame_args('Resume the suspended HTTP phase'), 'restored-http-frame'),
    })
  )
  eq(vim.json.decode(outputs[1].for_llm).artifact.id, 'F1')
  eq(Control.phase(chat), 'active')
end

T['clear isolates stale request callbacks and reused call IDs from a fresh run'] = function()
  local chat = new_chat(14)
  attach_group(chat, true)
  eq(chat.tool_registry:add('fixture_hold') ~= nil, true)

  local old_call = model_call('fixture_hold', { query = 'old run' }, 'shared-call')
  local request_a = submit_request(chat)
  local old_outputs = complete_request(chat, request_a, completion({ old_call }))
  eq(#old_outputs, 0)
  local old_orchestrator = chat.tool_orchestrator
  eq(type(old_orchestrator), 'table')
  eq(type(chat.held_output_cb), 'function')

  chat:clear()
  eq(Control._get(chat).phase, 'dormant')
  eq(Control.phase(chat), nil)
  eq(State.get(chat), nil)
  eq(old_orchestrator.cancelled, true)
  eq(chat.tool_orchestrator, nil)

  chat.pending_input = 'Continue as an ordinary chat while dormant'
  local ordinary = submit_request(chat, {})
  complete_request(chat, ordinary, completion({}, { content = 'ordinary dormant response' }))
  chat.pending_input = nil
  eq(Control._get(chat).phase, 'dormant')
  eq(chat.messages[#chat.messages].content, 'ordinary dormant response')

  for index = 1, #names - 1 do
    eq(chat.tool_registry:add(names[index]) ~= nil, true)
    eq(Control._get(chat).phase, 'dormant')
    eq(Control.phase(chat), nil)
  end
  eq(chat.tool_registry:add(names[#names]) ~= nil, true)
  eq(Control.phase(chat), 'armed')

  local fresh_call = model_call('reasoning_frame', frame_args('Fresh workspace after clear'), 'shared-call')
  local request_b = submit_request(chat)
  request_b.on_chunk(completion({ fresh_call }))
  request_b.on_status('success')
  eq(request_b.handle.status(), 'success')
  local handle_b = chat.current_request
  local status_b = chat.status
  local tokens_b = chat.tokens
  local messages_b = vim.deepcopy(chat.messages)
  local buffer_b = vim.deepcopy(chat.buffer_messages)
  local outputs_b = vim.deepcopy(chat.outputs)
  local violations_b = Control._get(chat).consecutive_violations

  request_a.on_chunk(completion({ old_call }, { content = 'late prose from A', tokens = 999 }))
  request_a.on_status('late-a')
  request_a.on_error({ message = 'late A error' })
  request_a.on_done()
  chat.held_output_cb({ status = 'success', data = 'late held output' })
  chat:add_tool_output({ name = 'fixture_hold', function_call = old_call }, 'late old tool output', 'late old UI')

  eq(chat.current_request, handle_b)
  eq(chat.status, status_b)
  eq(chat.tokens, tokens_b)
  eq(chat.messages, messages_b)
  eq(chat.buffer_messages, buffer_b)
  eq(chat.outputs, outputs_b)
  eq(Control._get(chat).consecutive_violations, violations_b)
  eq(State.get(chat), nil)

  local output_before = #chat.outputs
  run_scheduled(nil, function()
    request_b.on_done()
  end, true)
  eq(#chat.outputs, output_before + 1)
  eq(vim.json.decode(chat.outputs[#chat.outputs].for_llm).artifact.id, 'F1')
  eq(State.get(chat).counts_by_kind.frame, 1)
  eq(Control.phase(chat), 'active')
  local workspace_b = vim.deepcopy(State.get(chat))
  local messages_after_b = vim.deepcopy(chat.messages)

  request_a.on_chunk(completion({ old_call }, { content = 'second late A prose', tokens = 1001 }))
  request_a.on_status('second-late-a')
  request_a.on_done()
  request_b.on_done()
  chat:add_tool_output({ name = 'fixture_hold', function_call = old_call }, 'late old tool output', 'late old UI')
  eq(State.get(chat), workspace_b)
  eq(chat.messages, messages_after_b)
  eq(State.get(chat).counts_by_kind.frame, 1)
end

T['halts the abandoned run after three rejected completions without publishing prose'] = function()
  local chat = new_chat(15)
  attach_group(chat, true)

  local frame_request = submit_request(chat)
  local frame_outputs = complete_request(
    chat,
    frame_request,
    completion({
      model_call('reasoning_frame', frame_args('Reproduce the abandoned structured run'), 'abandoned-frame'),
    })
  )
  eq(vim.json.decode(frame_outputs[1].for_llm).artifact.id, 'F1')

  local invalid_evidence = evidence_args()
  invalid_evidence.items[1].source = 'unknown'
  local first_rejection_request = submit_request(chat)
  local first_outputs = complete_request(
    chat,
    first_rejection_request,
    completion({
      model_call('reasoning_evidence', invalid_evidence, 'abandoned-rejection-1'),
    })
  )
  local first_rejection = vim.json.decode(first_outputs[1].for_llm)
  eq(first_rejection.code, 'evidence_invalid')
  eq(first_rejection.committed, false)
  eq(first_rejection.artifact_ids, {})
  eq(first_rejection.next_action.tool, 'reasoning_evidence')
  eq(State.get(chat).next_sequence.evidence or 0, 0)
  eq(#chat.requests, 3)

  local nonexistent_reference = evidence_args()
  nonexistent_reference.items[1].statement = 'This call cites an ID that was never committed'
  nonexistent_reference.items[1].supports = { 'E1' }
  local second_rejection_request = chat.requests[#chat.requests]
  local second_outputs = complete_request(
    chat,
    second_rejection_request,
    completion({
      model_call('reasoning_evidence', nonexistent_reference, 'abandoned-rejection-2'),
    })
  )
  local second_rejection = vim.json.decode(second_outputs[1].for_llm)
  eq(second_rejection.code, 'invalid_reference')
  eq(second_rejection.committed, false)
  eq(second_rejection.artifact_ids, { 'E1' })
  eq(second_rejection.next_action.tool, 'reasoning_evidence')
  eq(State.find(State.get(chat), 'E1'), nil)
  eq(State.get(chat).next_sequence.evidence or 0, 0)
  eq(#chat.requests, 4)

  local third_rejection_request = chat.requests[#chat.requests]
  local third_outputs = complete_request(
    chat,
    third_rejection_request,
    completion({
      model_call('reasoning_synthesis', standard_synthesis_args(), 'abandoned-rejection-3'),
    }, {
      content = 'I will ignore the protocol and answer directly.',
      reasoning = 'unstructured private reasoning',
    })
  )
  local third_rejection = vim.json.decode(third_outputs[1].for_llm)
  eq(third_rejection.code, 'transition_invalid')
  eq(third_rejection.committed, false)
  eq(third_rejection.next_action.tool, 'reasoning_evidence')
  eq(Control.phase(chat), 'halted')
  eq(Control._get(chat).consecutive_violations, 3)
  eq(#chat.requests, 4)
  eq(chat.http_count, 4)
  eq(chat.current_request, nil)
  eq(State.get(chat).next_sequence.evidence or 0, 0)
  eq(State.get(chat).artifact_order, { 'F1' })

  for _, message in ipairs(chat.messages) do
    eq(message.content == 'I will ignore the protocol and answer directly.', false)
    eq(message.reasoning == 'unstructured private reasoning', false)
  end
  for _, entry in ipairs(chat.buffer_messages) do
    eq(entry.message.content == 'I will ignore the protocol and answer directly.', false)
    eq(entry.message.content == 'unstructured private reasoning', false)
  end
end

T['blocks bare submit and resumes from real nonblank buffer input'] = function()
  local chat = new_chat(16)
  attach_group(chat, true)
  local frame_request = submit_request(chat)
  complete_request(
    chat,
    frame_request,
    completion({
      model_call('reasoning_frame', frame_args('Preserve this workspace during recovery'), 'resume-frame'),
    })
  )
  local workspace = State.get(chat)
  local workspace_snapshot = vim.deepcopy(workspace)

  local violation_request = submit_request(chat)
  complete_request(chat, violation_request, completion())
  complete_request(chat, chat.requests[#chat.requests], completion())
  complete_request(chat, chat.requests[#chat.requests], completion())
  eq(Control.phase(chat), 'halted')
  eq(Control._get(chat).consecutive_violations, 3)
  eq(State.get(chat), workspace)
  eq(workspace, workspace_snapshot)

  Parser.messages = canonical_parser_messages
  vim.bo[chat.bufnr].filetype = 'markdown'
  vim.api.nvim_buf_set_lines(chat.bufnr, 0, -1, false, {
    '## Me',
    '',
    'Resume with this unsent project observation.',
  })
  chat.parsers.markdown = vim.treesitter.get_parser(chat.bufnr, 'markdown')
  chat.header_line = 1
  local parsed_input = Parser.messages(chat, chat.header_line)
  eq(parsed_input.content, 'Resume with this unsent project observation.')
  local messages_before = vim.deepcopy(chat.messages)
  local submits_before = chat.submit_count
  local transports_before = chat.http_count
  local header_before = chat.header_line
  local restores_before = chat.restore_count

  chat:submit({})
  eq(chat.submit_count, submits_before)
  eq(chat.http_count, transports_before)
  eq(chat.header_line, header_before)
  eq(chat.messages, messages_before)
  eq(chat.restore_count, restores_before + 1)
  eq(State.get(chat), workspace)

  eq(vim.api.nvim_buf_get_commands(chat.bufnr, {})[Constants.resume_command] ~= nil, true)
  vim.api.nvim_buf_call(chat.bufnr, function()
    vim.cmd(Constants.resume_command)
  end)
  eq(chat.submit_count, submits_before + 1)
  eq(chat.http_count, transports_before + 1)
  eq(#chat.requests, transports_before + 1)
  eq(Control.phase(chat), 'active')
  eq(State.get(chat), workspace)
  eq(workspace, workspace_snapshot)
  local resume_request = chat.requests[#chat.requests]
  local submitted_text = false
  for _, message in ipairs(resume_request.payload.messages) do
    submitted_text = submitted_text
      or message.role == CCConfig.constants.USER_ROLE
        and message.content == 'Resume with this unsent project observation.'
  end
  eq(submitted_text, true)

  local outputs = complete_request(
    chat,
    resume_request,
    completion({
      model_call('reasoning_evidence', evidence_args(), 'resume-evidence'),
    })
  )
  eq(vim.json.decode(outputs[1].for_llm).artifact.id, 'E1')
  eq(Control.phase(chat), 'active')
end

T['executes the complete deep protocol and terminates after final synthesis'] = function()
  local chat = new_chat(3)
  attach_group(chat, true)

  local frame = complete_reasoning_request(chat, 'reasoning_frame', deep_frame_args(), 'deep-frame')
  eq(frame.artifact.id, 'F1')
  eq(frame.next_action.tool, 'reasoning_question')

  local split = complete_reasoning_request(chat, 'reasoning_question', deep_split_args(chat), 'deep-split')
  eq(split.artifacts[1].id, 'Q1')
  eq(split.artifacts[2].id, 'Q2')
  eq(split.next_action.tool, 'reasoning_evidence')
  eq(split.next_action.reason, 'Gather evidence for sub-question Q1')

  local evidence = complete_reasoning_request(chat, 'reasoning_evidence', deep_evidence_args(), 'deep-evidence')
  eq(evidence.artifacts[1].id, 'E1')
  eq(evidence.artifacts[2].id, 'E2')
  eq(evidence.next_action.tool, 'reasoning_question')
  eq(evidence.next_action.reason, 'Close sub-question Q1 with its cited evidence')

  for index, id in ipairs({ 'Q1', 'Q2' }) do
    local closed = complete_reasoning_request(
      chat,
      'reasoning_question',
      question_args({
        action = 'answer',
        question_id = id,
        answer = 'The cited observation closes ' .. id,
        evidence_ids = { 'E' .. index },
        confidence = 'high',
      }),
      'deep-close-' .. id
    )
    eq(closed.artifact.id, 'C' .. index)
  end
  eq(Protocol.transition(State.get(chat), 'active').tool, 'reasoning_options')

  local options = complete_reasoning_request(chat, 'reasoning_options', options_args(), 'deep-options')
  eq(options.artifact.id, 'B1')
  eq(options.artifacts[1].id, 'O1')
  eq(options.next_action.tool, 'reasoning_review')

  local review = complete_reasoning_request(chat, 'reasoning_review', review_args(), 'deep-review')
  eq(review.artifact.id, 'R1')
  eq(review.next_action.tool, 'reasoning_synthesis')

  local checkpoint = complete_reasoning_request(chat, 'reasoning_synthesis', checkpoint_args(), 'deep-checkpoint')
  eq(checkpoint.artifact.id, 'S1')
  eq(checkpoint.next_action.tool, 'reasoning_synthesis')
  eq(State.get(chat).counts_by_kind.synthesis, 1)

  local final_arguments = synthesis_args()
  local render_arguments = vim.deepcopy(final_arguments)
  render_arguments.frame_id = State.get(chat).frame_id
  local expected_markdown = Render.render(State.get(chat), render_arguments)
  local revision_before = State.get(chat).revision
  eq(Control.phase(chat), 'active')
  eq(chat.current_request, nil)
  eq(chat.tool_orchestrator, nil)
  CCConfig.interactions.chat.tools.opts.auto_submit_success = true
  local final_request = submit_request(chat)
  local submits_before_final = chat.submit_count
  local transports_before_final = chat.http_count
  local final_outputs = complete_request(
    chat,
    final_request,
    completion({
      model_call('reasoning_synthesis', final_arguments, 'deep-final'),
    }, {
      content = 'hostile prose after a valid final call',
      reasoning = 'hostile final reasoning',
    })
  )
  eq(#final_outputs, 1)
  local final_output = final_outputs[1]
  local final = vim.json.decode(final_output.for_llm)
  eq(final.artifact.id, 'S2')
  eq(final.unmet_gates, {})
  eq(final.next_action.tool, 'none')
  eq(final._reasoning_final, nil)
  eq(final_output.for_user, '')
  eq(Control.phase(chat), 'finalized')
  eq(Control._get(chat).staged_final, nil)
  eq(rawget(chat, '_codecompanion_reasoning_terminal_guard'), nil)
  eq(State.get(chat).counts_by_kind.synthesis, 2)
  eq(State.get(chat).revision, revision_before + 1)
  eq(chat.submit_count, submits_before_final)
  eq(chat.http_count, transports_before_final)

  local result_index
  local rendered_index
  local rendered_count = 0
  for index, message in ipairs(chat.messages) do
    if message.role == chat.adapter.roles.tool and type(message.content) == 'string' then
      local decoded_ok, decoded = pcall(vim.json.decode, message.content)
      if decoded_ok and type(decoded.artifact) == 'table' and decoded.artifact.id == 'S2' then
        result_index = index
      end
    end
    if message.role == CCConfig.constants.LLM_ROLE and message.content == expected_markdown then
      rendered_index = index
      rendered_count = rendered_count + 1
    end
    eq(message.content == 'hostile prose after a valid final call', false)
    eq(message.reasoning == 'hostile final reasoning', false)
  end
  eq(type(result_index), 'number')
  eq(type(rendered_index), 'number')
  eq(result_index < rendered_index, true)
  eq(rendered_count, 1)
  local buffer_rendered = vim.tbl_filter(function(entry)
    return entry.message.content == expected_markdown
  end, chat.buffer_messages)
  eq(#buffer_rendered, 1)

  local committed = vim.deepcopy(State.get(chat))
  final_request.on_done()
  eq(State.get(chat), committed)
  eq(State.get(chat).counts_by_kind.synthesis, 2)
  eq(#vim.tbl_filter(function(message)
    return message.role == CCConfig.constants.LLM_ROLE and message.content == expected_markdown
  end, chat.messages), 1)
end

T['reframes after final while suppressing investigation prose and retiring downstream artifacts'] = function()
  local chat = new_chat(17)
  attach_group(chat, true)
  add_external_tools(chat)
  complete_reasoning_request(chat, 'reasoning_frame', deep_frame_args(), 'reframe-frame')
  complete_reasoning_request(chat, 'reasoning_question', deep_split_args(chat), 'reframe-split')
  complete_reasoning_request(chat, 'reasoning_evidence', deep_evidence_args(), 'reframe-evidence')
  for index, id in ipairs({ 'Q1', 'Q2' }) do
    complete_reasoning_request(
      chat,
      'reasoning_question',
      question_args({
        action = 'answer',
        question_id = id,
        answer = 'The cited observation closes ' .. id,
        evidence_ids = { 'E' .. index },
        confidence = 'high',
      }),
      'reframe-close-' .. id
    )
  end
  complete_reasoning_request(chat, 'reasoning_options', options_args(), 'reframe-options')
  complete_reasoning_request(chat, 'reasoning_review', review_args(), 'reframe-review')
  complete_reasoning_request(chat, 'reasoning_synthesis', checkpoint_args(), 'reframe-checkpoint')
  local final, _, final_request =
    complete_reasoning_request(chat, 'reasoning_synthesis', synthesis_args(), 'reframe-final')
  eq(final.artifact.id, 'S2')
  eq(Control.phase(chat), 'finalized')
  local workspace = State.get(chat)
  local old_ids = vim.deepcopy(workspace.artifact_order)
  local workspace_before_investigation = vim.deepcopy(workspace)

  chat.pending_input = 'New project facts require revising the accepted frame.'
  local final_submits = chat.submit_count
  local final_transports = chat.http_count
  local final_history = vim.deepcopy(chat.messages)
  chat:submit({})
  eq(chat.submit_count, final_submits)
  eq(chat.http_count, final_transports)
  eq(chat.messages, final_history)
  vim.api.nvim_buf_call(chat.bufnr, function()
    vim.cmd(Constants.resume_command)
  end)
  chat.pending_input = nil
  eq(Control.phase(chat), 'reframing')
  eq(State.get(chat), workspace)
  local investigation_request = chat.requests[#chat.requests]
  eq(investigation_request ~= final_request, true)
  local investigation_outputs = complete_request(
    chat,
    investigation_request,
    completion({
      model_call('fixture_search', { query = 'new project facts' }, 'reframe-search'),
      model_call('fixture_read', { path = 'new-context.lua' }, 'reframe-read'),
    }, {
      content = 'premature post-final answer',
      reasoning = 'premature post-final reasoning',
    })
  )
  eq(#investigation_outputs, 2)
  eq(Control.phase(chat), 'reframing')
  eq(Control._get(chat).consecutive_violations, 0)
  eq(State.get(chat), workspace)
  eq(workspace, workspace_before_investigation)
  for _, message in ipairs(chat.messages) do
    eq(message.content == 'premature post-final answer', false)
    eq(message.reasoning == 'premature post-final reasoning', false)
  end
  for _, entry in ipairs(chat.buffer_messages) do
    eq(entry.message.content == 'premature post-final answer', false)
    eq(entry.message.content == 'premature post-final reasoning', false)
  end

  local rejected_request = submit_request(chat)
  local rejected_outputs = complete_request(
    chat,
    rejected_request,
    completion({
      model_call('reasoning_evidence', evidence_args(), 'reframe-wrong-tool'),
    })
  )
  local rejected = vim.json.decode(rejected_outputs[1].for_llm)
  eq(rejected.code, 'transition_invalid')
  eq(rejected.committed, false)
  eq(rejected.next_action.tool, 'reasoning_frame')
  eq(Control.phase(chat), 'reframing')
  eq(Control._get(chat).consecutive_violations, 1)
  eq(State.get(chat), workspace)
  eq(workspace, workspace_before_investigation)

  local revised = deep_frame_args()
  revised.action = 'revise'
  revised.objective = 'Choose a durable cache design using the new project facts'
  local retry_request = chat.requests[#chat.requests]
  local revised_outputs = complete_request(
    chat,
    retry_request,
    completion({
      model_call('reasoning_frame', revised, 'reframe-revise'),
    })
  )
  local revision = vim.json.decode(revised_outputs[1].for_llm)
  eq(revision.artifact.id, 'F2')
  eq(revision.next_action.tool, 'reasoning_question')
  eq(State.get(chat), workspace)
  eq(workspace.id, 'W1')
  eq(workspace.frame_id, 'F2')
  eq(Control.phase(chat), 'active')
  eq(Control._get(chat).consecutive_violations, 0)
  eq(State.find(workspace, 'F2').status, 'active')
  for _, id in ipairs(old_ids) do
    eq(State.find(workspace, id).status, 'superseded')
  end
  eq(workspace.next_sequence.evidence, 2)
end

T['close invalidates pending retries requests tools and finalization callbacks'] = function()
  local retry_chat = new_chat(18)
  attach_group(retry_chat, true)
  local retry_request = submit_request(retry_chat)
  local _, fallback_queue = complete_request(retry_chat, retry_request, completion(), false)
  eq(Control._get(retry_chat).consecutive_violations, 1)
  eq(#retry_chat.requests, 1)
  local retry_state = Control._get(retry_chat)
  run_scheduled(fallback_queue, function()
    retry_chat:close()
  end, false)
  eq(retry_state.closed, true)
  eq(retry_state.closed_cleaned, true)
  eq(State.get(retry_chat), nil)
  drain_scheduled(fallback_queue)
  eq(retry_chat.http_count, 1)
  eq(#retry_chat.requests, 1)

  local active = new_chat(19)
  attach_group(active, true)
  local active_state = Control._get(active)
  local active_request = submit_request(active)
  local late_call = model_call('reasoning_frame', frame_args('Late closed request'), 'late-close-call')
  local late_writer = function()
    active:add_buf_message({ role = 'assistant', content = 'late subscriber output' }, {
      type = active.MESSAGE_TYPES.LLM_MESSAGE,
    })
  end
  local stopped_queue = run_scheduled(nil, function()
    active:close()
  end, false)
  eq(active_state.closed, true)
  eq(active_state.closed_cleaned, true)
  eq(active.request_cancel_count, 1)
  eq(State.get(active), nil)
  eq(vim.api.nvim_buf_is_valid(active.bufnr), false)
  for _, callback in pairs(active.callbacks) do
    eq(#callback, 0)
  end
  local active_snapshot = {
    status = active.status,
    tokens = active.tokens,
    submit = active.submit_count,
    http = active.http_count,
    done = active.done_count,
    cancels = active.request_cancel_count,
    messages = vim.deepcopy(active.messages),
    buffer = vim.deepcopy(active.buffer_messages),
    outputs = vim.deepcopy(active.outputs),
  }
  active_request.on_chunk(completion({ late_call }, {
    content = 'late closed prose',
    reasoning = 'late closed reasoning',
    tokens = 9001,
  }))
  active_request.on_status('late-status')
  active_request.on_error({ message = 'late error' })
  active_request.on_done()
  active:add_tool_output({ name = 'reasoning_frame', function_call = late_call }, 'late tool result', 'late tool UI')
  late_writer()
  active:submit({ auto_submit = true })
  active:done({ 'late done' })
  active:clear()
  active:close()
  drain_scheduled(stopped_queue)
  eq(active.status, active_snapshot.status)
  eq(active.tokens, active_snapshot.tokens)
  eq(active.submit_count, active_snapshot.submit)
  eq(active.http_count, active_snapshot.http)
  eq(active.done_count, active_snapshot.done)
  eq(active.request_cancel_count, active_snapshot.cancels)
  eq(active.messages, active_snapshot.messages)
  eq(active.buffer_messages, active_snapshot.buffer)
  eq(active.outputs, active_snapshot.outputs)
  eq(State.get(active), nil)

  local finalizing = new_chat(20)
  attach_group(finalizing, true)
  complete_reasoning_request(
    finalizing,
    'reasoning_frame',
    frame_args('Close during finalization'),
    'close-final-frame'
  )
  complete_reasoning_request(finalizing, 'reasoning_evidence', evidence_args(), 'close-final-evidence')
  local finalizing_workspace = State.get(finalizing)
  local final_arguments = standard_synthesis_args()
  local render_arguments = vim.deepcopy(final_arguments)
  render_arguments.frame_id = finalizing_workspace.frame_id
  local forbidden_markdown = Render.render(finalizing_workspace, render_arguments)
  local finalizing_state = Control._get(finalizing)
  local close_from_subscriber = 0
  finalizing.subscribers.stop = function(self)
    self.stop_count = self.stop_count + 1
    close_from_subscriber = close_from_subscriber + 1
    finalizing:close()
  end
  local finalizing_request = submit_request(finalizing)
  local finalizing_call = model_call('reasoning_synthesis', final_arguments, 'close-final-call')
  local finalizing_queue = run_scheduled(nil, function()
    finalizing_request.on_chunk(completion({ finalizing_call }))
    finalizing_request.on_done()
  end, false)
  eq(close_from_subscriber, 1)
  eq(finalizing_state.closed, true)
  eq(finalizing_state.closed_cleaned, true)
  eq(finalizing.request_cancel_count, 0)
  eq(State.get(finalizing), nil)
  eq(vim.api.nvim_buf_is_valid(finalizing.bufnr), false)
  eq(finalizing_workspace.counts_by_kind.synthesis or 0, 0)
  eq(State.find(finalizing_workspace, 'S1'), nil)
  eq(#vim.tbl_filter(function(message)
    return message.role == CCConfig.constants.LLM_ROLE and message.content == forbidden_markdown
  end, finalizing.messages), 0)
  local finalizing_snapshot = {
    status = finalizing.status,
    tokens = finalizing.tokens,
    submit = finalizing.submit_count,
    http = finalizing.http_count,
    done = finalizing.done_count,
    messages = vim.deepcopy(finalizing.messages),
    buffer = vim.deepcopy(finalizing.buffer_messages),
    outputs = vim.deepcopy(finalizing.outputs),
  }
  finalizing_request.on_chunk(completion({ finalizing_call }, { content = 'late final prose' }))
  finalizing_request.on_status('late-final-status')
  finalizing_request.on_done()
  finalizing:add_tool_output(
    { name = 'reasoning_synthesis', function_call = finalizing_call },
    'late final result',
    'late final UI'
  )
  drain_scheduled(finalizing_queue)
  eq(finalizing.status, finalizing_snapshot.status)
  eq(finalizing.tokens, finalizing_snapshot.tokens)
  eq(finalizing.submit_count, finalizing_snapshot.submit)
  eq(finalizing.http_count, finalizing_snapshot.http)
  eq(finalizing.done_count, finalizing_snapshot.done)
  eq(finalizing.messages, finalizing_snapshot.messages)
  eq(finalizing.buffer_messages, finalizing_snapshot.buffer)
  eq(finalizing.outputs, finalizing_snapshot.outputs)
  eq(State.get(finalizing), nil)
  eq(finalizing_workspace.counts_by_kind.synthesis or 0, 0)
end

T['auto-attached group resolves through a live registry'] = function()
  Extension.setup({ auto_attach = true })
  local chat = new_chat(4)
  for _, name in ipairs(CCConfig.interactions.chat.tools.opts.default_tools) do
    chat.tool_registry:add(name)
  end
  assert_group_attached(chat)
  eq(Control._get(chat) ~= nil, true)
  eq(Control.phase(chat), 'armed')
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
  complete_pending_ordinary_request(chat)
  invoke(chat, 'reasoning_evidence', evidence_args())
  complete_pending_ordinary_request(chat)
  local final = vim.json.decode(invoke(chat, 'reasoning_synthesis', standard_synthesis_args()).for_llm)
  complete_pending_ordinary_request(chat)
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
