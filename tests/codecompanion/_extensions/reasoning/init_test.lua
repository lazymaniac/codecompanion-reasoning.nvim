local CodeCompanion = require('codecompanion')
local Constants = require('codecompanion._extensions.reasoning.constants')
local Control = require('codecompanion._extensions.reasoning.control')
local Extension = require('codecompanion._extensions.reasoning')
local Extensions = require('codecompanion._extensions')
local Frame = require('codecompanion._extensions.reasoning.tools.frame')
local ReasoningConfig = require('codecompanion._extensions.reasoning.config')
local State = require('codecompanion._extensions.reasoning.state')
local ToolRuntime = require('codecompanion.interactions.chat.tools')
local config = require('codecompanion.config')

local original_config
local original_exports
local original_reasoning_options
local original_buf_get_chat
local original_control_reconcile
local original_control_clear
local created_buffers = {}
local T = MiniTest.new_set({
  hooks = {
    pre_case = function()
      Control._reset()
      original_config = vim.deepcopy(config.config)
      original_exports = vim.deepcopy(Extensions._exports)
      original_reasoning_options = ReasoningConfig.get()
      original_buf_get_chat = CodeCompanion.buf_get_chat
      original_control_reconcile = Control.reconcile
      original_control_clear = Control.clear
      State._reset()
    end,
    post_case = function()
      CodeCompanion.buf_get_chat = original_buf_get_chat
      Control.reconcile = original_control_reconcile
      Control.clear = original_control_clear
      Control._reset()
      config.config = original_config
      Extensions._exports = original_exports
      ReasoningConfig.setup(original_reasoning_options)
      State._reset()
      for _, bufnr in ipairs(created_buffers) do
        if vim.api.nvim_buf_is_valid(bufnr) then
          vim.api.nvim_buf_delete(bufnr, { force = true })
        end
      end
      created_buffers = {}
    end,
  },
})
local eq = MiniTest.expect.equality

local names = {
  'reasoning_frame',
  'reasoning_evidence',
  'reasoning_options',
  'reasoning_review',
  'reasoning_synthesis',
  'reasoning_question',
}

local function new_control_chat()
  local bufnr = vim.api.nvim_create_buf(false, true)
  table.insert(created_buffers, bufnr)
  local callbacks = {}
  local chat = {
    adapter = { type = 'http', name = 'init-test-http' },
    bufnr = bufnr,
    callbacks = callbacks,
    current_request = nil,
    messages = {},
    tool_orchestrator = nil,
    tool_registry = { in_use = {} },
    MESSAGE_TYPES = {
      LLM_MESSAGE = 'llm',
      REASONING_MESSAGE = 'reasoning',
      SYSTEM_MESSAGE = 'system',
      TOOL_MESSAGE = 'tool',
    },
  }
  for _, name in ipairs(names) do
    chat.tool_registry.in_use[name] = true
  end
  function chat:add_callback(event, callback)
    callbacks[event] = callbacks[event] or {}
    table.insert(callbacks[event], callback)
  end
  function chat:remove_callback(event, callback)
    for index = #(callbacks[event] or {}), 1, -1 do
      if callbacks[event][index] == callback then
        table.remove(callbacks[event], index)
      end
    end
  end
  function chat:submit()
    self.original_submit_count = (self.original_submit_count or 0) + 1
  end
  function chat:_submit_http() end
  function chat:_submit_acp() end
  function chat:done()
    self.original_done_count = (self.original_done_count or 0) + 1
  end
  function chat:add_buf_message() end
  function chat:add_tool_output() end
  function chat:clear() end
  function chat:close() end
  function chat:remove_tagged_message() end
  chat.tools = {
    execute = function() end,
    tools_config = config.interactions.chat.tools,
  }
  return chat
end

local function autocmd_pattern_counts()
  local counts = {}
  for _, autocmd in ipairs(vim.api.nvim_get_autocmds({ group = Constants.augroup })) do
    for pattern in string.gmatch(autocmd.pattern or '', '[^,]+') do
      counts[pattern] = (counts[pattern] or 0) + 1
    end
  end
  return counts
end

T['loads through CodeCompanion setup and resolves all schemas'] = function()
  local host_prompt = function()
    return 'host prompt'
  end
  CodeCompanion.setup({
    interactions = {
      chat = {
        opts = { system_prompt = host_prompt },
        tools = {
          host_tool = { path = 'host.tool' },
          groups = { host_group = { tools = { 'host_tool' } } },
          opts = {
            default_tools = { 'host_tool' },
            system_prompt = { enabled = false, replace_main_system_prompt = true },
          },
        },
      },
    },
    extensions = {
      reasoning = { enabled = true, opts = { auto_attach = false, default_depth = 'deep' } },
    },
  })
  local tools = config.interactions.chat.tools
  eq(tools.groups.reasoning.tools, names)
  eq(config.interactions.chat.opts.system_prompt, host_prompt)
  eq(tools.host_tool.path, 'host.tool')
  eq(tools.groups.host_group.tools, { 'host_tool' })
  eq(tools.opts.default_tools, { 'host_tool' })
  eq(tools.opts.system_prompt.enabled, false)
  eq(tools.opts.system_prompt.replace_main_system_prompt, true)

  for _, name in ipairs(names) do
    eq(type(tools[name].callback), 'function')
    eq(tools[name].path, nil)
    local resolved = ToolRuntime.resolve(tools[name])
    eq(type(resolved.cmds[1]), 'function')
    eq(resolved.schema['function'].name, name)
    eq(resolved.output ~= nil, true)
  end
end

T['preserves host overrides on reasoning registrations'] = function()
  local tools = config.interactions.chat.tools
  tools.reasoning_frame = {
    opts = { require_approval_before = true },
    visible = false,
  }
  tools.groups.reasoning = {
    description = 'Custom reasoning label',
    opts = { collapse_tools = false },
  }
  Extension.setup()
  eq(type(tools.reasoning_frame.callback), 'function')
  eq(tools.reasoning_frame.path, nil)
  eq(tools.reasoning_frame.opts.require_approval_before, true)
  eq(tools.reasoning_frame.visible, false)
  eq(tools.groups.reasoning.description, 'Custom reasoning label')
  eq(tools.groups.reasoning.opts.collapse_tools, false)
  eq(tools.groups.reasoning.tools, names)
end

T['forces canonical tool identity across host name collisions'] = function()
  local tools = config.interactions.chat.tools
  local hostile_callback = function()
    return {}
  end
  tools.reasoning_frame = {
    path = 'host.tool',
    extends = 'cmd_tool',
    callback = hostile_callback,
    cmds = { function() end },
    schema = { type = 'function', ['function'] = { name = 'host_frame' } },
    name = 'host_frame',
    enabled = false,
    _adapter_tool = true,
    _has_client_tool = true,
    description = 'Custom frame label',
    opts = {
      require_approval_before = true,
      allowed_in_yolo_mode = false,
      judge_in_yolo_mode = true,
      client_tool = 'interactions.chat.tools.run_command',
      _mcp_info = { server = 'host' },
    },
    visible = false,
  }

  Extension.setup()

  local registered = tools.reasoning_frame
  eq(registered.path, nil)
  eq(type(registered.callback), 'function')
  eq(registered.callback == hostile_callback, false)
  eq(registered.description, 'Custom frame label')
  eq(registered.opts.require_approval_before, true)
  eq(registered.opts.allowed_in_yolo_mode, false)
  eq(registered.opts.judge_in_yolo_mode, true)
  eq(registered.opts.client_tool, nil)
  eq(registered.opts._mcp_info, nil)
  eq(registered.visible, false)
  for _, field in ipairs({
    'extends',
    'cmds',
    'schema',
    'name',
    'enabled',
    '_adapter_tool',
    '_has_client_tool',
  }) do
    eq(registered[field], nil)
  end
  local resolved = ToolRuntime.resolve(registered)
  eq(resolved.schema['function'].name, 'reasoning_frame')
  eq(resolved.cmds[1], Frame.cmds[1])
end

T['authenticates runtime registrations without resolving foreign callbacks'] = function()
  Extension.setup()
  local authentic = config.interactions.chat.tools.reasoning_frame
  local copied = vim.deepcopy(authentic)
  eq(Extension.owns_tool_config('reasoning_frame', authentic), true)
  eq(Extension.owns_tool_config('reasoning_frame', copied), true)
  eq(Extension.owns_tool_config('reasoning_evidence', copied), false)

  local callback_calls = 0
  eq(
    Extension.owns_tool_config('reasoning_frame', {
      callback = function()
        callback_calls = callback_calls + 1
        return Frame
      end,
    }),
    false
  )
  eq(callback_calls, 0)

  for _, redirect in ipairs({
    { extends = 'cmd_tool' },
    { path = '_extensions.reasoning.tools.frame' },
    { _adapter_tool = true },
    { _has_client_tool = true },
  }) do
    local candidate = vim.deepcopy(authentic)
    for key, value in pairs(redirect) do
      candidate[key] = value
    end
    eq(Extension.owns_tool_config('reasoning_frame', candidate), false)
  end
  local mutated_opts = vim.deepcopy(authentic)
  mutated_opts.opts = mutated_opts.opts or {}
  mutated_opts.opts.require_approval_before = function()
    callback_calls = callback_calls + 1
    return true
  end
  eq(Extension.owns_tool_config('reasoning_frame', mutated_opts), false)
  eq(callback_calls, 0)
  local inherited = setmetatable({}, { __index = authentic })
  eq(Extension.owns_tool_config('reasoning_frame', inherited), false)

  local previous = authentic.callback
  Extension.setup()
  eq(config.interactions.chat.tools.reasoning_frame.callback == previous, false)
  eq(Extension.owns_tool_config('reasoning_frame', { callback = previous }), true)
end

T['keeps only safe display overrides on a colliding group'] = function()
  config.interactions.chat.tools.groups.reasoning = {
    description = 'Custom reasoning label',
    system_prompt = 'Replace the protocol',
    tools = { 'host_tool' },
    opts = {
      collapse_tools = false,
      ignore_system_prompt = true,
      ignore_tool_system_prompt = true,
    },
  }

  Extension.setup()

  local group = config.interactions.chat.tools.groups.reasoning
  eq(group.description, 'Custom reasoning label')
  eq(group.tools, names)
  eq(group.system_prompt:find('<structured_reasoning>', 1, true) ~= nil, true)
  eq(group.opts, { collapse_tools = false })
end

T['auto-attaches the group once'] = function()
  Extension.setup({ auto_attach = true })
  Extension.setup({ auto_attach = true })
  local count = 0
  for _, name in ipairs(config.interactions.chat.tools.opts.default_tools) do
    if name == 'reasoning' then
      count = count + 1
    end
  end
  eq(count, 1)
end

T['removes only an attachment it added when configuration changes'] = function()
  local defaults = config.interactions.chat.tools.opts.default_tools
  Extension.setup({ auto_attach = true })
  Extension.setup({ auto_attach = false })
  eq(vim.tbl_contains(defaults, 'reasoning'), false)

  table.insert(defaults, 'reasoning')
  Extension.setup({ auto_attach = false })
  eq(vim.tbl_contains(defaults, 'reasoning'), true)
end

T['keeps manual attachment as the default'] = function()
  Extension.setup()
  eq(vim.tbl_contains(config.interactions.chat.tools.opts.default_tools, 'reasoning'), false)
end

T['uses the current function command contract'] = function()
  Extension.setup()
  local frame = ToolRuntime.resolve(config.interactions.chat.tools.reasoning_frame)
  local result = frame.cmds[1]({ chat = {} }, {}, {
    input = nil,
    output_cb = function() end,
    register_job = function() end,
  })
  eq(result.status, 'error')
  eq(result.data.code, 'frame_incomplete')
end

T['defines the complete structured runtime contract without replacing the host system prompt'] = function()
  Extension.setup()
  local prompt = config.interactions.chat.tools.groups.reasoning.system_prompt
  eq(type(prompt), 'string')
  for _, rule in ipairs({
    'Attaching the complete reasoning group commits this conversation to the structured final-answer path',
    'External project tools are unrestricted and budget-neutral',
    'The first reasoning call must be reasoning_frame with action=start',
    'Never write the final answer directly as model prose',
    'A rejected call is retryable and returns committed=false',
    'Rejected artifact IDs do not exist',
    'New user information requires reasoning_frame with action=revise or action=replace',
    'The deterministic final answer may use only accepted artifacts',
    'Split the problem into atomic sub-questions before gathering evidence',
    'Every leaf must be closed by reasoning_question',
    'Work discovered mid-run uses reasoning_frame with action=amend',
  }) do
    eq(prompt:find(rule, 1, true) ~= nil, true)
  end
  eq(prompt:find('search, read files, inspect symbols and history, run commands and tests', 1, true) ~= nil, true)
  eq(prompt:find('return the accepted conclusion', 1, true), nil)
  eq(prompt:find('private chain-of-thought', 1, true) ~= nil, true)
  eq(config.interactions.chat.opts.system_prompt, original_config.interactions.chat.opts.system_prompt)
end

T['refreshes protocol guidance when the configured default depth changes'] = function()
  Extension.setup({ default_depth = 'standard' })
  local standard = config.interactions.chat.tools.groups.reasoning.system_prompt
  eq(standard:find('Use standard depth', 1, true) ~= nil, true)

  Extension.setup({ default_depth = 'deep' })
  local deep = config.interactions.chat.tools.groups.reasoning.system_prompt
  eq(deep:find('Use deep depth', 1, true) ~= nil, true)
  eq(deep:find('Use standard depth', 1, true), nil)
end

T['rejects invalid setup atomically'] = function()
  Extension.setup({ default_depth = 'standard' })
  local tools_before = vim.deepcopy(config.interactions.chat.tools)
  local autocmds_before = vim.api.nvim_get_autocmds({ group = Constants.augroup })
  MiniTest.expect.error(function()
    Extension.setup({ default_depth = 'extreme' })
  end, 'default_depth')
  eq(config.interactions.chat.tools, tools_before)
  eq(ReasoningConfig.get().default_depth, 'standard')
  eq(vim.api.nvim_get_autocmds({ group = Constants.augroup }), autocmds_before)
end

T['repeated setup does not reset active reasoning state'] = function()
  local chat = {}
  local result = Frame.cmds[1]({ chat = chat }, {
    action = 'start',
    objective = 'Preserve this workspace',
    problem_type = 'analysis',
    depth = 'standard',
    constraints = {},
    success_criteria = { 'State remains available' },
    unknowns = {},
    perspectives = { { name = 'correctness', purpose = 'Check setup isolation' } },
    temporal_required = false,
    branching_required = false,
    branching_rationale = 'This test evaluates one claim',
  }, {})
  eq(result.status, 'success')
  local workspace = State.get(chat)
  Extension.setup()
  Extension.setup()
  eq(State.get(chat), workspace)
  eq(State.find(workspace, 'F1').data.objective, 'Preserve this workspace')
end

T['installs one lifecycle callback per event and routes only valid chat buffers'] = function()
  Extension.setup()
  Extension.setup()

  local patterns = autocmd_pattern_counts()
  eq(patterns.CodeCompanionChatToolAdded, 1)
  eq(patterns.CodeCompanionChatAdapter, 1)
  eq(patterns.CodeCompanionChatCleared, 1)

  local chat = {}
  local bufnr = vim.api.nvim_create_buf(false, true)
  table.insert(created_buffers, bufnr)
  local lookups = 0
  local reconciled = {}
  local cleared = {}
  CodeCompanion.buf_get_chat = function(candidate)
    lookups = lookups + 1
    return candidate == bufnr and chat or nil
  end
  Control.reconcile = function(candidate)
    table.insert(reconciled, candidate)
  end
  Control.clear = function(candidate)
    table.insert(cleared, candidate)
  end

  for _, pattern in ipairs({ 'CodeCompanionChatToolAdded', 'CodeCompanionChatAdapter' }) do
    vim.api.nvim_exec_autocmds('User', { pattern = pattern, data = { bufnr = bufnr } })
  end
  vim.api.nvim_exec_autocmds('User', {
    pattern = 'CodeCompanionChatCleared',
    data = { bufnr = bufnr },
  })
  eq(reconciled, { chat, chat })
  eq(cleared, { chat })
  eq(lookups, 3)

  vim.api.nvim_exec_autocmds('User', { pattern = 'CodeCompanionChatToolAdded', data = {} })
  local deleted = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_delete(deleted, { force = true })
  vim.api.nvim_exec_autocmds('User', {
    pattern = 'CodeCompanionChatAdapter',
    data = { bufnr = deleted },
  })
  eq(reconciled, { chat, chat })
  eq(cleared, { chat })
  eq(lookups, 3)
end

T['repeated valid setup preserves a live controller'] = function()
  Extension.setup()
  local chat = new_control_chat()
  local state = Control.reconcile(chat)
  eq(type(state), 'table')
  local submit = rawget(chat, 'submit')

  Extension.setup()
  Extension.setup()

  eq(Control._get(chat), state)
  eq(Control._count(), 1)
  eq(rawget(chat, 'submit'), submit)
end

T['_reset removes lifecycle callbacks'] = function()
  Extension.setup()
  eq(type(vim.api.nvim_get_autocmds({ group = Constants.augroup })), 'table')
  Control._reset()
  MiniTest.expect.error(function()
    vim.api.nvim_get_autocmds({ group = Constants.augroup })
  end, "Invalid 'group'")
end

T['_reset restores settled controllers and tombstones busy controllers'] = function()
  Extension.setup()
  local settled = new_control_chat()
  local settled_state = Control.reconcile(settled)
  local settled_submit_original = settled_state.methods.submit.original
  local settled_execute_original = settled_state.methods.execute.original

  local busy = new_control_chat()
  local busy_state = Control.reconcile(busy)
  local busy_submit_wrapper = rawget(busy, 'submit')
  local busy_done_wrapper = rawget(busy, 'done')
  local busy_execute_wrapper = rawget(busy.tools, 'execute')
  local request_cancels = 0
  local orchestrator_cancels = 0
  local handle = {
    cancel = function()
      request_cancels = request_cancels + 1
      busy:submit({ auto_submit = true })
      busy:done()
    end,
  }
  busy.current_request = handle
  busy_state.request_handle = handle
  busy.tool_orchestrator = {
    cancel = function()
      orchestrator_cancels = orchestrator_cancels + 1
      busy:submit({ auto_submit = true })
      busy:done()
    end,
  }

  Control._reset()

  eq(rawget(settled, 'submit'), settled_submit_original)
  eq(rawget(settled.tools, 'execute'), settled_execute_original)
  eq(settled_state.closed, false)
  eq(rawget(busy, 'submit'), busy_submit_wrapper)
  eq(rawget(busy, 'done'), busy_done_wrapper)
  eq(rawget(busy.tools, 'execute'), busy_execute_wrapper)
  eq(busy_state.closed, true)
  eq(busy_state.closed_cleaned, true)
  eq(busy.current_request, nil)
  eq(request_cancels, 1)
  eq(orchestrator_cancels, 1)
  eq(busy.original_submit_count, nil)
  eq(busy.original_done_count, nil)
  eq(Control._count(), 0)
  eq(next(busy.callbacks.on_submitted or {}), nil)
  eq(vim.api.nvim_buf_get_commands(busy.bufnr, {})[Constants.resume_command], nil)

  busy:submit({ auto_submit = true })
  busy:done()
  eq(busy.original_submit_count, nil)
  eq(busy.original_done_count, nil)
end

T['does not load or register legacy lifecycle surfaces'] = function()
  local legacy_modules = {
    'codecompanion._extensions.reasoning.commands',
    'codecompanion._extensions.reasoning.helpers.chat_hooks',
    'codecompanion._extensions.reasoning.helpers.session_manager',
    'codecompanion._extensions.reasoning.helpers.system_prompt',
    'codecompanion._extensions.reasoning.tools.list_files',
    'codecompanion._extensions.reasoning.tools.project_knowledge',
  }
  for _, name in ipairs(legacy_modules) do
    package.loaded[name] = nil
  end
  Extension.setup()
  for _, name in ipairs(legacy_modules) do
    eq(package.loaded[name], nil)
  end
  eq(vim.fn.exists(':CodeCompanionChatHistory'), 0)
  eq(vim.fn.exists(':CodeCompanionProjectKnowledge'), 0)
end

return T
