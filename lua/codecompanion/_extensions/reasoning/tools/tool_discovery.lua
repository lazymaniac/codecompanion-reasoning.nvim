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

---Extract the first sentence from a description
---@param description string The full description
---@return string First sentence of the description
local function extract_first_sentence(description)
  if not description or description == '' then
    return 'No description provided'
  end

  -- Find the first sentence ending with period, exclamation, or question mark
  local first_sentence = description:match('^[^%.%!%?]*[%.%!%?]')

  if first_sentence then
    return first_sentence:gsub('^%s*(.-)%s*$', '%1') -- Trim whitespace
  else
    -- If no sentence ending found, take first 80 characters and add ellipsis
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

  -- Tools to exclude from discovery (these are automatically added or are primary agents)
  local excluded_tools = {
    -- Reasoning agents (selected directly, not addable)
    ['chain_of_thoughts_agent'] = true,
    ['tree_of_thoughts_agent'] = true,
    ['graph_of_thoughts_agent'] = true,
    ['meta_agent'] = true,
    -- Companion tools (automatically added with reasoning agents)
    ['ask_user'] = true,
    ['tool_discovery'] = true,
  }

  for tool_name, tool_config in pairs(tools_config) do
    -- Skip special keys and excluded tools
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
        system_prompt = nil,
        error = nil,
      }

      -- Try to resolve the tool to get schema and system prompt
      if is_enabled and tool_config.callback then
        local ok, resolved_tool = pcall(function()
          return Tools.resolve(tool_config)
        end)

        if ok and resolved_tool then
          tool_info.resolved = true
          tool_info.schema = resolved_tool.schema

          -- Get system prompt (can be function or string)
          if resolved_tool.system_prompt then
            if type(resolved_tool.system_prompt) == 'function' then
              local prompt_ok, system_prompt = pcall(resolved_tool.system_prompt, resolved_tool.schema)
              if prompt_ok then
                tool_info.system_prompt = system_prompt
              else
                tool_info.system_prompt = 'Error evaluating system prompt function'
              end
            elseif type(resolved_tool.system_prompt) == 'string' then
              tool_info.system_prompt = resolved_tool.system_prompt
            end
          end

          -- Additional metadata from resolved tool
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

  -- Count tools by status for summary
  local enabled_count = 0
  local total_count = 0
  for _, tool_info in pairs(all_tools) do
    total_count = total_count + 1
    if tool_info.enabled then
      enabled_count = enabled_count + 1
    end
  end

  -- First line contains the most important summary
  table.insert(
    output,
    fmt('✅ Found %d tools available (%d enabled) - Ready to enhance your workflow', total_count, enabled_count)
  )
  table.insert(output, '')
  table.insert(output, '## Available Tools:')

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
    local status = tool_info.enabled and '✓' or '✗'

    local trimmed_description = extract_first_sentence(tool_info.description)
    table.insert(output, fmt('- %s **%s:** %s', status, tool_name, trimmed_description))
  end

  return table.concat(output, '\n')
end

-- Tool action handlers
local function handle_list_tools(args)
  local format = args.format or 'simple'

  local result = list_tools()
  return { status = 'success', data = result }
end

-- Store the tool to add in global state so success handler can access it
local pending_tool_addition = nil

local function handle_add_tool(args)
  if not args.tool_name then
    return { status = 'error', data = 'tool_name is required' }
  end

  -- Tools that cannot be added (these are automatically added or are primary agents)
  local excluded_tools = {
    -- Reasoning agents (selected directly, not addable)
    ['chain_of_thoughts_agent'] = true,
    ['tree_of_thoughts_agent'] = true,
    ['graph_of_thoughts_agent'] = true,
    ['meta_agent'] = true,
    -- Companion tools (automatically added with reasoning agents)
    ['ask_user'] = true,
    ['tool_discovery'] = true,
  }

  -- Check if trying to add an excluded tool
  if excluded_tools[args.tool_name] then
    if args.tool_name:match('_agent$') or args.tool_name == 'meta_agent' then
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

  -- Get tool info including disabled tools
  local all_tools = get_all_tools_with_schemas(true) -- Include disabled to check tool existence
  local tool_info = all_tools[args.tool_name]
  if not tool_info then
    return { status = 'error', data = fmt("Tool '%s' not found", args.tool_name) }
  end

  -- Skip special keys
  if args.tool_name == 'opts' or args.tool_name == 'groups' then
    return { status = 'error', data = fmt("'%s' is not an addable tool", args.tool_name) }
  end

  log:debug('[Tool Discovery] Preparing to add tool: %s', args.tool_name)

  -- Store tool for success handler to process
  pending_tool_addition = args.tool_name

  return {
    status = 'success',
    data = fmt('Preparing to add %s to chat...', args.tool_name),
  }
end

---@class CodeCompanion.Tool.ToolDiscovery: CodeCompanion.Agent.Tool
return {
  name = 'tool_discovery',
  cmds = {
    ---Execute tool discovery commands
    ---@param self CodeCompanion.Tool.ToolDiscovery
    ---@param args table The arguments from the LLM's tool call
    ---@param input? any The output from the previous function call
    ---@return { status: "success"|"error", data: string }
    function(self, args, input)
      log:debug('[Tool Discovery] Action: %s', args.action or 'none')

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
      name = 'tool_discovery',
      description = 'Discover and add coding tools: list available tools and add them to enhance your capabilities for the current task.',
      parameters = {
        type = 'object',
        properties = {
          action = {
            type = 'string',
            description = "'list_tools' to see available tools, 'add_tool' to add a specific tool to current chat",
            enum = { 'list_tools', 'add_tool' },
          },
          tool_name = {
            type = 'string',
            description = 'Exact tool name to add (required for add_tool action)',
          },
        },
        required = { 'action' },
        additionalProperties = false,
      },
      strict = true,
    },
  },
  system_prompt = [[# ROLE
You discover and add coding tools to enhance task capabilities.

# USAGE PATTERN
1. When facing unfamiliar tasks → Use 'list_tools' to see what's available
2. When you need specific capability → Use 'add_tool' with exact tool name
3. Proactively discover tools before asking user to add them manually

# DECISION LOGIC
- File operations mentioned → Look for "edit", "write", "modify" tools
- Code changes needed → ALWAYS suggest file editing tools first
- Testing/CI/CD mentioned → Look for testing tools
- Analysis/debugging → Look for analysis tools
- Build/deploy → Look for build tools
- User says "I need X" → Discover X instead of asking them to add it

# PRIORITY TOOLS FOR CODING
- File editing tools (edit, write, modify) should be suggested immediately for any code changes
- Always prefer automated tools over manual user actions

# WORKFLOW
list_tools → review capabilities → add_tool [name] → use new tool

# CONSTRAINTS
- Always use exact tool names for add_tool
- Don't add reasoning agents (they're selected via meta_agent)
- Don't add ask_user/tool_discovery (auto-added)]],
  output = {
    ---@param self CodeCompanion.Tool.ToolDiscovery
    ---@param agent CodeCompanion.Tools.Tool
    ---@param cmd table The command that was executed
    ---@param stdout table The output from the command
    success = function(self, agent, cmd, stdout)
      local chat = agent.chat
      local result = vim.iter(stdout):flatten():join('\n')

      -- Check if we need to add a tool to the chat
      if pending_tool_addition then
        local tool_name = pending_tool_addition
        pending_tool_addition = nil -- Clear the pending state

        log:debug('[Tool Discovery] Adding tool to chat: %s', tool_name)

        -- Get the tool configuration
        local raw_tools_config = config.strategies.chat.tools
        local tool_config = raw_tools_config[tool_name]

        if tool_config and chat.tool_registry then
          chat.tool_registry:add(tool_name, tool_config)

          local success_message = fmt('✅ %s added and ready!', tool_name)

          chat:add_tool_output(self, success_message, success_message)
        else
          chat:add_tool_output(self, fmt('❌ FAILED to add tool: %s (tool config or registry unavailable)', tool_name))
        end
      else
        log:debug('[Tool Discovery] Success output generated, length: %d', #result)
        chat:add_tool_output(self, result, result)
      end
    end,

    ---@param self CodeCompanion.Tool.ToolDiscovery
    ---@param agent CodeCompanion.Tools.Tool
    ---@param cmd table
    ---@param stderr table The error output from the command
    error = function(self, agent, cmd, stderr)
      local chat = agent.chat
      local errors = vim.iter(stderr):flatten():join('\n')
      pending_tool_addition = nil -- Clear pending state on error
      log:debug('[Tool Discovery] Error occurred: %s', errors)
      chat:add_tool_output(self, fmt('❌ Tool Discovery ERROR: %s', errors))
    end,
  },
}
