local ToolCatalog = require('codecompanion._extensions.reasoning.helpers.tool_catalog')

local config_ok, config = pcall(require, 'codecompanion.config')
if not config_ok then
  config = { strategies = { chat = { tools = {} } } }
end

local log_ok, log = pcall(require, 'codecompanion.utils.log')
if not log_ok then
  log = {
    debug = function(...) end,
    error = function(...)
      vim.notify(string.format(...), vim.log.levels.ERROR)
    end,
  }
end
local fmt = string.format

local excluded_tools = ToolCatalog.excluded_tools

local AddTools = {
  name = 'add_tools',
}

local function handle_add_tool(args)
  if not args.tool_name then
    return { status = 'error', data = 'tool_name is required' }
  end

  if excluded_tools[args.tool_name] then
    if args.tool_name:match('_agent$') then
      return {
        status = 'error',
        data = fmt(
          "'%s' is a reasoning agent, not an addable tool. Reasoning agents are selected directly when starting a chat.",
          args.tool_name
        ),
      }
    else
      return {
        status = 'error',
        data = fmt(
          "'%s' is automatically added to every chat, so you never need to request it manually.",
          args.tool_name
        ),
      }
    end
  end

  local catalog = ToolCatalog.get_tool_catalog()
  local tool_info = catalog[args.tool_name]
  if not tool_info then
    return { status = 'error', data = fmt("Tool '%s' not found", args.tool_name) }
  end

  if not tool_info.enabled then
    return {
      status = 'error',
      data = fmt("Tool '%s' is disabled or unavailable in the current configuration", args.tool_name),
    }
  end

  log:debug('[Add Tools] Preparing to add tool: %s', args.tool_name)

  return {
    status = 'success',
    data = args.tool_name,
  }
end

---@class CodeCompanion.Tool.AddTools: CodeCompanion.Agent.Tool
AddTools.cmds = {
  ---Execute add tools commands
  ---@param self CodeCompanion.Tool.AddTools
  ---@param args table The arguments from the LLM's tool call
  ---@param input? any The output from the previous function call
  ---@return { status: "success"|"error", data: string }
  function(self, args, input)
    args = args or {}
    log:debug('[Add Tools] Requested tool: %s', args.tool_name or 'none')
    return handle_add_tool(args)
  end,
}

AddTools.schema = {
  type = 'function',
  ['function'] = {
    name = 'add_tools',
    description = [[Attach optional tools (capabilities) to the current chat.

Usage:
- Review the AVAILABLE TOOLS section in the system prompt to find the exact tool names.
- Call with tool_name set to a matching name when you are ready to use that capability.
- Add only the tools you plan to invoke next.]],
    parameters = {
      type = 'object',
      properties = {
        tool_name = {
          type = 'string',
          description = [[Exact tool key to add. Must match a name from the AVAILABLE TOOLS section of the system prompt.]],
        },
      },
      required = { 'tool_name' },
      additionalProperties = false,
    },
    strict = true,
  },
}

AddTools.output = {
  ---@param self CodeCompanion.Tool.AddTools
  ---@param agent CodeCompanion.Tools.Tool
  ---@param cmd table The command that was executed
  ---@param stdout table The output from the command
  success = function(self, agent, cmd, stdout)
    local chat = agent.chat
    local tool_name = cmd.tool_name

    log:debug('[Add Tools] Adding tool to chat: %s', tool_name)

    local raw_tools_config = config.strategies.chat.tools
    local tool_config = raw_tools_config[tool_name]

    if tool_config and chat.tool_registry then
      chat.tool_registry:add(tool_name, vim.deepcopy(tool_config))

      local success_message = fmt('%s ready to use!', tool_name)

      chat:add_tool_output(self, success_message, success_message)
    else
      chat:add_tool_output(self, fmt('FAILED to add tool: %s (tool config or registry unavailable)', tool_name))
    end
  end,

  ---@param self CodeCompanion.Tool.AddTools
  ---@param agent CodeCompanion.Tools.Tool
  ---@param cmd table
  ---@param stderr table The error output from the command
  error = function(self, agent, cmd, stderr)
    local chat = agent.chat
    local errors = vim.iter(stderr):flatten():join('\n')
    log:debug('[Add Tools] Error occurred: %s', errors)
    chat:add_tool_output(self, fmt('Add Tools ERROR: %s', errors))
  end,
}

return AddTools
