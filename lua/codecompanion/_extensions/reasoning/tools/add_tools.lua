local tool_filter_ok, ToolFilter = pcall(require, 'codecompanion.strategies.chat.tools.tool_filter')
if not tool_filter_ok then
  ToolFilter = {
    filter = function()
      return {}
    end,
  }
end

local tools_ok, Tools = pcall(require, 'codecompanion.strategies.chat.tools.init')
if not tools_ok then
  Tools = {
    get_tools = function()
      return {}
    end,
  }
end

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

local excluded_tools = {
  ['chain_of_thoughts_agent'] = true,
  ['tree_of_thoughts_agent'] = true,
  ['graph_of_thoughts_agent'] = true,
  ['meta_agent'] = true,
  ['ask_user'] = true,
  ['add_tools'] = true,
  ['project_knowledge'] = true,
  ['initialize_project_knowledge'] = true,
}

---Extract the first sentence from a description
---@param description string The full description
---@return string First sentence of the description
local function extract_first_sentence(description)
  if not description or description == '' then
    return 'No description provided'
  end

  local first_sentence = description:match('^[^%.%!%?]*[%.%!%?]')

  if first_sentence then
    return first_sentence:gsub('^%s*(.-)%s*$', '%1') -- Trim whitespace
  else
    if #description <= 80 then
      return description
    else
      return description:sub(1, 77) .. '...'
    end
  end
end

---Get all tools with their complete configuration and resolved details
---@return table<string, table> Map of tool names to their complete information
local function get_all_tools_with_schemas()
  local tools_config = config.strategies.chat.tools
  local enabled_tools = ToolFilter.filter_enabled_tools(tools_config)
  local result = {}

  for tool_name, tool_config in pairs(tools_config) do
    if tool_name ~= 'opts' and tool_name ~= 'groups' and not excluded_tools[tool_name] then
      local is_enabled = enabled_tools[tool_name] or false

      local tool_info = {
        name = tool_name,
        enabled = is_enabled,
        config = vim.deepcopy(tool_config),
        description = tool_config.description or 'No description provided',
        callback = tool_config.callback,
        opts = tool_config.opts or {},
        resolved = nil,
        schema = nil,
        error = nil,
      }

      if is_enabled and tool_config.callback then
        local ok, resolved_tool = pcall(function()
          return Tools.resolve(tool_config)
        end)

        if ok and resolved_tool then
          tool_info.resolved = true
          tool_info.schema = resolved_tool.schema

          if resolved_tool.handlers then
            tool_info.has_handlers = true
            tool_info.handler_types = vim.tbl_keys(resolved_tool.handlers)
          end

          if resolved_tool.output then
            tool_info.has_output_handlers = true
            tool_info.output_handlers = vim.tbl_keys(resolved_tool.output)
          end
        else
          tool_info.resolved = false
          tool_info.error = 'Failed to resolve tool'
        end
      else
        tool_info.resolved = false
        if not is_enabled then
          tool_info.error = 'Tool is disabled'
        else
          tool_info.error = 'No callback defined'
        end
      end

      result[tool_name] = tool_info
    end
  end

  return result
end

---List all available tools in a formatted way
---@return string Formatted list of tools
local function list_tools()
  local all_tools = get_all_tools_with_schemas()

  local output = {}

  local enabled_count = 0
  local total_count = 0
  for _, tool_info in pairs(all_tools) do
    total_count = total_count + 1
    if tool_info.enabled then
      enabled_count = enabled_count + 1
    end
  end

  table.insert(output, fmt('Found %d tools', total_count))
  table.insert(output, '')
  table.insert(output, 'Available Tools:')
  table.insert(output, '')

  local tools_list = {}
  for tool_name, tool_info in pairs(all_tools) do
    table.insert(tools_list, { name = tool_name, info = tool_info })
  end

  table.sort(tools_list, function(a, b)
    return a.name < b.name
  end)

  for _, tool in ipairs(tools_list) do
    local tool_name = tool.name
    local tool_info = tool.info

    local trimmed_description = extract_first_sentence(tool_info.description)
    table.insert(output, fmt('- %s: %s', tool_name, trimmed_description))
  end

  table.insert(output, '')
  table.insert(output, '---')
  table.insert(
    output,
    'NEXT STEP: After reviewing this list, immediately call add_tools with action="add_tool" to add the tools you need!'
  )
  table.insert(
    output,
    'Example: Call add_tools with action="add_tool" and tool_name="insert_edit_into_file" to add file editing capability'
  )

  return table.concat(output, '\n')
end

-- Tool action handlers
local function handle_list_tools(args)
  local result = list_tools()
  return { status = 'success', data = result }
end

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
        data = fmt("'%s' is automatically added as a companion tool when using reasoning agents.", args.tool_name),
      }
    end
  end

  local all_tools = get_all_tools_with_schemas()
  local tool_info = all_tools[args.tool_name]
  if not tool_info then
    return { status = 'error', data = fmt("Tool '%s' not found", args.tool_name) }
  end

  if args.tool_name == 'opts' or args.tool_name == 'groups' then
    return { status = 'error', data = fmt("'%s' is not an addable tool", args.tool_name) }
  end

  log:debug('[Add Tools] Preparing to add tool: %s', args.tool_name)

  return {
    status = 'success',
    data = args.tool_name,
  }
end

---@class CodeCompanion.Tool.AddTools: CodeCompanion.Agent.Tool
return {
  name = 'add_tools',
  cmds = {
    ---Execute add tools commands
    ---@param self CodeCompanion.Tool.AddTools
    ---@param args table The arguments from the LLM's tool call
    ---@param input? any The output from the previous function call
    ---@return { status: "success"|"error", data: string }
    function(self, args, input)
      log:debug('[Add Tools] Action: %s', args.action or 'none')

      if args.action == 'list_tools' then
        return handle_list_tools(args)
      elseif args.action == 'add_tool' then
        return handle_add_tool(args)
      else
        return {
          status = 'error',
          data = fmt('Unknown action: %s. Available actions: list_tools, add_tool', args.action or 'none'),
        }
      end
    end,
  },
  schema = {
    type = 'function',
    ['function'] = {
      name = 'add_tools',
      description = [[Manage optional tools for this chat.
Usage:
1. Call with action="list_tools" to get the exact, addable tool names and brief descriptions.
2. For each needed capability, call again with action="add_tool" and tool_name set to an exact name from the list. Do not guess names. After a tool is added, you may invoke it in subsequent tool calls by name in this conversation. If you try to use a tool that is not attached, first attach it via add_tools, then retry.

Example sequence:
- add_tools(action="list_tools")
- add_tools(action="add_tool", tool_name="<exact_name_from_list>")
- some work done, and new capability is needed
- add_tools(action="add_tool", tool_name="<another_exact_name_from_list>")

Scope: add only the tools you plan to use next.]],
      parameters = {
        type = 'object',
        properties = {
          action = {
            type = 'string',
            description = [[Required action. Use 'list_tools' to retrieve the authoritative list of addable tools. Use 'add_tool' to attach one specific tool (by exact name) to the current chat. Any other value is invalid. When action='add_tool', 'tool_name' must be provided. Attempting to add excluded tools (reasoning agents or companion tools) returns an error.]],
            enum = { 'list_tools', 'add_tool' },
          },
          tool_name = {
            type = 'string',
            description = [[Exact tool key to add when action='add_tool'. Must match a name returned by add_tools(action='list_tools'); case-sensitive; add one tool per call. Omit for action='list_tools'.]],
          },
        },
        required = { 'action' },
        additionalProperties = false,
      },
      strict = true,
    },
  },
  output = {
    ---@param self CodeCompanion.Tool.AddTools
    ---@param agent CodeCompanion.Tools.Tool
    ---@param cmd table The command that was executed
    ---@param stdout table The output from the command
    success = function(self, agent, cmd, stdout)
      local chat = agent.chat
      local result = vim.iter(stdout):flatten():join('\n')

      if cmd.action == 'add_tool' then
        local tool_name = cmd.tool_name

        log:debug('[Add Tools] Adding tool to chat: %s', tool_name)

        local raw_tools_config = config.strategies.chat.tools
        local tool_config = raw_tools_config[tool_name]

        if tool_config and chat.tool_registry then
          chat.tool_registry:add(tool_name, tool_config)

          local success_message = fmt('%s ready to use!', tool_name)

          chat:add_tool_output(self, success_message, success_message)
        else
          chat:add_tool_output(self, fmt('FAILED to add tool: %s (tool config or registry unavailable)', tool_name))
        end
      else
        log:debug('[Add Tools] Success output generated, length: %d', #result)
        chat:add_tool_output(self, result, result)
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
  },
}
