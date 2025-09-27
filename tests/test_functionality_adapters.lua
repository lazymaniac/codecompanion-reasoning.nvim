---@diagnostic disable: undefined-global
local MiniTest = require('mini.test')
local new_set = MiniTest.new_set

local Config = require('codecompanion._extensions.reasoning.config')
local SessionOptimizer = require('codecompanion._extensions.reasoning.helpers.session_optimizer')
local TitleGenerator = require('codecompanion._extensions.reasoning.helpers.title_generator')

local function clear_reasoning_modules()
  local modules = {
    'codecompanion._extensions.reasoning',
    'codecompanion._extensions.reasoning.config',
    'codecompanion._extensions.reasoning.tools.ask_user',
    'codecompanion._extensions.reasoning.tools.chain_of_thoughts_agent',
    'codecompanion._extensions.reasoning.tools.tree_of_thoughts_agent',
    'codecompanion._extensions.reasoning.tools.graph_of_thoughts_agent',
    'codecompanion._extensions.reasoning.tools.meta_agent',
    'codecompanion._extensions.reasoning.tools.add_tools',
    'codecompanion._extensions.reasoning.tools.list_files',
    'codecompanion._extensions.reasoning.tools.project_knowledge',
    'codecompanion._extensions.reasoning.tools.initialize_project_knowledge',
  }

  for _, name in ipairs(modules) do
    package.loaded[name] = nil
  end
end

local T = new_set({
  hooks = {
    pre_case = function()
      Config.reset()
    end,
    post_case = function()
      Config.reset()
    end,
  },
})

T['Session optimizer respects functionality adapter config'] = function()
  Config.setup({
    functionality_adapters = {
      session_optimizer = {
        adapter = 'ollama',
        model = 'gpt-oss',
      },
    },
  })

  local optimizer = SessionOptimizer.new()

  MiniTest.expect.equality(optimizer.config.adapter, 'ollama')
  MiniTest.expect.equality(optimizer.config.model, 'gpt-oss')
end

T['Session optimizer allows runtime overrides to win'] = function()
  Config.setup({
    functionality_adapters = {
      session_optimizer = {
        adapter = 'ollama',
        model = 'gpt-oss',
      },
    },
  })

  local optimizer = SessionOptimizer.new({
    adapter = 'anthropic',
    model = 'claude-3-sonnet',
  })

  MiniTest.expect.equality(optimizer.config.adapter, 'anthropic')
  MiniTest.expect.equality(optimizer.config.model, 'claude-3-sonnet')
end

T['Title generator uses functionality adapter configuration'] = function()
  Config.setup({
    functionality_adapters = {
      title_generator = {
        adapter = 'stub-adapter',
        model = 'stub-model',
      },
    },
  })

  local original_adapters = package.loaded['codecompanion.adapters']
  local original_schema = package.loaded['codecompanion.schema']
  local original_http = package.loaded['codecompanion.http']

  local function restore()
    package.loaded['codecompanion.adapters'] = original_adapters
    package.loaded['codecompanion.schema'] = original_schema
    package.loaded['codecompanion.http'] = original_http
  end

  local ok, err = pcall(function()
    local resolve_calls = {}
    local schema_calls = {}

    local stub_adapter = {
      map_schema_to_params = function(_, params)
        params = params or {}
        params.opts = params.opts or {}
        return params
      end,
      map_roles = function(_, messages)
        return messages
      end,
      handlers = {
        chat_output = function(_, _data)
          return { status = 'success', output = { content = 'Computed Title' } }
        end,
      },
    }

    package.loaded['codecompanion.adapters'] = {
      resolve = function(name)
        table.insert(resolve_calls, name)
        return stub_adapter
      end,
    }

    package.loaded['codecompanion.schema'] = {
      get_default = function(adapter, params)
        table.insert(schema_calls, { adapter = adapter, params = params })
        params = params or {}
        params.model = params.model or 'default-model'
        return params
      end,
    }

    local request_opts = {}
    package.loaded['codecompanion.http'] = {
      new = function(opts)
        table.insert(request_opts, opts)
        return {
          request = function(_, _payload, handlers)
            handlers.callback(nil, {}, stub_adapter)
          end,
        }
      end,
    }

    local generator = TitleGenerator.new()
    local chat = {
      messages = {
        { role = 'user', content = 'Plan feature work' },
      },
      opts = {},
    }

    local titles = {}
    generator:generate(chat, function(title)
      table.insert(titles, title)
    end)

    MiniTest.expect.equality(#resolve_calls > 0, true)
    MiniTest.expect.equality(resolve_calls[#resolve_calls], 'stub-adapter')

    MiniTest.expect.equality(#schema_calls > 0, true)
    MiniTest.expect.equality(schema_calls[#schema_calls].params.model, 'stub-model')

    MiniTest.expect.equality(titles[#titles], 'Computed Title')
  end)

  restore()

  if not ok then
    error(err)
  end
end

T['Reasoning extension registers functionality adapters for tools'] = function()
  local original_config_module = package.loaded['codecompanion.config']

  package.loaded['codecompanion.config'] = {
    strategies = {
      chat = {
        tools = {},
      },
    },
    opts = {},
  }

  local ok, extension = pcall(require, 'codecompanion._extensions.reasoning')
  MiniTest.expect.equality(ok, true)

  extension.setup({
    functionality_adapters = {
      meta_agent = { adapter = 'ollama', model = 'gpt-oss' },
      reasoning_agents = { adapter = 'anthropic', model = 'claude-3-sonnet' },
    },
  })

  local cfg = package.loaded['codecompanion.config']
  local tools = cfg.strategies.chat.tools

  MiniTest.expect.equality(tools.meta_agent.adapter, 'ollama')
  MiniTest.expect.equality(tools.meta_agent.model, 'gpt-oss')
  MiniTest.expect.equality(tools.chain_of_thoughts_agent.adapter, 'anthropic')
  MiniTest.expect.equality(tools.tree_of_thoughts_agent.model, 'claude-3-sonnet')
  MiniTest.expect.equality(tools.graph_of_thoughts_agent.model, 'claude-3-sonnet')

  package.loaded['codecompanion.config'] = original_config_module
  clear_reasoning_modules()
end

return T
