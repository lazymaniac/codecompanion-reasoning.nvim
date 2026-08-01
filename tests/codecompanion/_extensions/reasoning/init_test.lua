local CodeCompanion = require('codecompanion')
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
local T = MiniTest.new_set({
  hooks = {
    pre_case = function()
      original_config = vim.deepcopy(config.config)
      original_exports = vim.deepcopy(Extensions._exports)
      original_reasoning_options = ReasoningConfig.get()
      State._reset()
    end,
    post_case = function()
      config.config = original_config
      Extensions._exports = original_exports
      ReasoningConfig.setup(original_reasoning_options)
      State._reset()
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
}

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
  eq(tools.reasoning_frame.path, '_extensions.reasoning.tools.frame')
  eq(tools.reasoning_evidence.path, '_extensions.reasoning.tools.evidence')
  eq(tools.reasoning_options.path, '_extensions.reasoning.tools.options')
  eq(tools.reasoning_review.path, '_extensions.reasoning.tools.review')
  eq(tools.reasoning_synthesis.path, '_extensions.reasoning.tools.synthesis')
  eq(tools.groups.reasoning.tools, names)
  eq(config.interactions.chat.opts.system_prompt, host_prompt)
  eq(tools.host_tool.path, 'host.tool')
  eq(tools.groups.host_group.tools, { 'host_tool' })
  eq(tools.opts.default_tools, { 'host_tool' })
  eq(tools.opts.system_prompt.enabled, false)
  eq(tools.opts.system_prompt.replace_main_system_prompt, true)

  for _, name in ipairs(names) do
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
  eq(tools.reasoning_frame.path, '_extensions.reasoning.tools.frame')
  eq(tools.reasoning_frame.opts.require_approval_before, true)
  eq(tools.reasoning_frame.visible, false)
  eq(tools.groups.reasoning.description, 'Custom reasoning label')
  eq(tools.groups.reasoning.opts.collapse_tools, false)
  eq(tools.groups.reasoning.tools, names)
end

T['forces canonical tool identity across host name collisions'] = function()
  local tools = config.interactions.chat.tools
  tools.reasoning_frame = {
    path = 'host.tool',
    extends = 'cmd_tool',
    callback = function()
      return {}
    end,
    cmds = { function() end },
    schema = { type = 'function', ['function'] = { name = 'host_frame' } },
    name = 'host_frame',
    enabled = false,
    _adapter_tool = true,
    _has_client_tool = true,
    description = 'Custom frame label',
    opts = {
      require_approval_before = true,
      client_tool = 'interactions.chat.tools.run_command',
      _mcp_info = { server = 'host' },
    },
    visible = false,
  }

  Extension.setup()

  local registered = tools.reasoning_frame
  eq(registered.path, '_extensions.reasoning.tools.frame')
  eq(registered.description, 'Custom frame label')
  eq(registered.opts.require_approval_before, true)
  eq(registered.opts.client_tool, nil)
  eq(registered.opts._mcp_info, nil)
  eq(registered.visible, false)
  for _, field in ipairs({
    'extends',
    'callback',
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

T['defines none as terminal without replacing the host system prompt'] = function()
  Extension.setup()
  local prompt = config.interactions.chat.tools.groups.reasoning.system_prompt
  eq(type(prompt), 'string')
  eq(prompt:find('exactly one reasoning tool at a time', 1, true) ~= nil, true)
  eq(prompt:find('never batch reasoning calls', 1, true) ~= nil, true)
  eq(prompt:find('Satisfy next_action.reason', 1, true) ~= nil, true)
  eq(prompt:find('Never repeat unchanged rejected arguments', 1, true) ~= nil, true)
  eq(prompt:find('next_action.tool is none', 1, true) ~= nil, true)
  eq(prompt:find('stop calling reasoning tools', 1, true) ~= nil, true)
  eq(prompt:find('Checkpoint mode is optional', 1, true) ~= nil, true)
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
  MiniTest.expect.error(function()
    Extension.setup({ default_depth = 'extreme' })
  end, 'default_depth')
  eq(config.interactions.chat.tools, tools_before)
  eq(ReasoningConfig.get().default_depth, 'standard')
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
