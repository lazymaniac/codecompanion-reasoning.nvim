---@class CodeCompanion.Extension.Reasoning
local ReasoningExtension = {}

local Config = require('codecompanion._extensions.reasoning.config')
local ToolCatalog = require('codecompanion._extensions.reasoning.helpers.tool_catalog')

local function register_tools()
  local tools = {
    'ask_user',
    'chain_of_thoughts_agent',
    'tree_of_thoughts_agent',
    'graph_of_thoughts_agent',
    'meta_agent',
    'add_tools',
    'list_files',
    'project_knowledge',
    'initialize_project_knowledge',
  }

  local registered_tools = {}

  for _, tool_name in ipairs(tools) do
    local ok, tool = pcall(require, string.format('codecompanion._extensions.reasoning.tools.%s', tool_name))
    if ok then
      registered_tools[tool_name] = tool
    else
      vim.notify(string.format('Failed to load reasoning tool: %s', tool_name), vim.log.levels.WARN)
    end
  end

  return registered_tools
end

function ReasoningExtension.setup(opts)
  local merged_opts = Config.setup(opts)

  local reasoning_tools = register_tools()

  -- Initialize chat hooks for auto-save functionality
  local chat_hooks_ok, chat_hooks = pcall(require, 'codecompanion._extensions.reasoning.helpers.chat_hooks')
  if chat_hooks_ok then
    chat_hooks.setup()
  end

  -- Initialize session manager with configuration
  local session_manager_ok, session_manager =
    pcall(require, 'codecompanion._extensions.reasoning.helpers.session_manager')
  if session_manager_ok and merged_opts.chat_history then
    session_manager.setup()
  end

  -- Setup user commands if enabled
  local commands_ok, commands = pcall(require, 'codecompanion._extensions.reasoning.commands')
  if commands_ok then
    commands.setup()
  end

  local config_ok, config = pcall(require, 'codecompanion.config')
  if not config_ok then
    return {
      tools = reasoning_tools,
    }
  end

  -- System prompt: provide a function value for CodeCompanion to call.
  -- This keeps the prompt source in one place (helpers/system_prompt.lua)
  -- and appends dynamic context (tools catalog, project knowledge) if present.
  local sp_ok, SystemPrompt = pcall(require, 'codecompanion._extensions.reasoning.helpers.system_prompt')
  if sp_ok and SystemPrompt and type(SystemPrompt.get) == 'function' then
    local prompt_fn = function()
      local sections = { SystemPrompt.get() }

      local ok_tools, catalog = pcall(ToolCatalog.build_available_tools_markdown)
      if ok_tools and catalog and catalog ~= '' then
        table.insert(sections, '---\n AVAILABLE TOOLS\n' .. catalog)
      end

      local root = vim.fn.getcwd()
      local knowledge_path = root .. '/.codecompanion/project-knowledge.md'
      if vim.fn.filereadable(knowledge_path) == 1 then
        local ok, content = pcall(function()
          local f = io.open(knowledge_path, 'r')
          if not f then
            return nil
          end
          local c = f:read('*all')
          f:close()
          return c
        end)
        if ok and content and content ~= '' then
          table.insert(sections, '---\n PROJECT CONTEXT\n' .. content)
        end
      end

      return table.concat(sections, '\n\n')
    end
    config.opts = config.opts or {}
    config.strategies.chat.opts = config.strategies.chat.opts or {}
    config.strategies.chat.opts.system_prompt = prompt_fn
    if
      config.strategies.chat.tools
      and config.strategies.chat.tools.opts
      and config.strategies.chat.tools.opts.system_prompt
    then
      config.strategies.chat.tools.opts.system_prompt.enabled = false
    end
  end

  for name, tool in pairs(reasoning_tools) do
    local tool_entry = {
      id = 'reasoning:' .. name,
      description = tool.schema['function'].description,
      callback = tool,
    }

    config.strategies.chat.tools[name] = tool_entry
  end

  return {
    tools = reasoning_tools,
    config = config,
    options = merged_opts,
  }
end

-- Export the tools for direct access if needed
ReasoningExtension.exports = {
  get_tools = register_tools,
}

return ReasoningExtension
