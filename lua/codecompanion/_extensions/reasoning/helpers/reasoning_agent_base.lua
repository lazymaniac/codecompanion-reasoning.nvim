---@class CodeCompanion.ReasoningAgentBase

local UnifiedReasoningPrompt = require('codecompanion._extensions.reasoning.helpers.unified_reasoning_prompt')
local log_ok, log = pcall(require, 'codecompanion.utils.log')
if not log_ok then
  -- Fallback logging when CodeCompanion log is not available
  log = {
    debug = function(...) end,
    error = function(template, ...)
      local args = { ... }
      -- Convert all args to strings to avoid formatting errors
      for i = 1, #args do
        args[i] = tostring(args[i])
      end
      -- Use pcall to safely format the message
      local success, message = pcall(string.format, template, unpack(args))
      if success then
        vim.notify(message, vim.log.levels.ERROR)
      else
        vim.notify('Error formatting log message: ' .. tostring(template), vim.log.levels.ERROR)
      end
    end,
  }
end
local fmt = string.format

local ReasoningAgentBase = {}
ReasoningAgentBase.__index = ReasoningAgentBase

local global_agent_states = {}

-- Track which agents have had their companion tools added
local companion_tools_added = {}

-- Add companion tools (ask_user and add_tools) to the chat
function ReasoningAgentBase.add_companion_tools(agent, agent_type)
  local chat = agent.chat
  if not chat or not chat.tool_registry then
    log:debug('[%s] No tool registry available for companion tools', agent_type)
    return
  end

  local chat_id = chat.id or 'default'

  -- Check if we've already added tools for this chat
  if companion_tools_added[chat_id] then
    return
  end

  log:debug('[%s] Adding companion tools to chat', agent_type)

  -- Get the config to access the tools
  local config_ok, config = pcall(require, 'codecompanion.config')
  if not config_ok then
    log:debug('[%s] CodeCompanion config not available', agent_type)
    return
  end

  local tools_to_add = { 'ask_user', 'add_tool', 'memory' }
  local added_tools = {}

  for _, tool_name in ipairs(tools_to_add) do
    local tool_config = config.strategies.chat.tools[tool_name]
    if tool_config then
      local success, err = pcall(function()
        chat.tool_registry:add(tool_name, tool_config)
        table.insert(added_tools, tool_name)
        log:debug('[%s] Added companion tool: %s', agent_type, tool_name)
      end)
      if not success then
        log:debug('[%s] Failed to add companion tool %s: %s', agent_type, tool_name, tostring(err))
      end
    else
      log:debug('[%s] Tool config not found for: %s', agent_type, tool_name)
    end
  end

  if #added_tools > 0 then
    companion_tools_added[chat_id] = true

    -- Notify user about added tools - put summary first
    local tools_summary = table.concat(added_tools, ', ')
    local message = string.format(
      '🔧 Reasoning agent enhanced with %d companion tools: %s\n\nThese tools are now available to support your reasoning process:\n- **ask_user**: Get input when decisions require user expertise\n- **add_tools**: Find and add additional tools as needed',
      #added_tools,
      tools_summary
    )

    vim.schedule(function()
      chat:add_message({
        role = vim.g.codecompanion_role or 'user',
        content = message,
        tag = 'system_info',
      })
    end)
  end
end

function ReasoningAgentBase.get_state(agent_type)
  if not global_agent_states[agent_type] then
    global_agent_states[agent_type] = {
      current_instance = nil,
      session_id = nil,
      tool_instance = nil,
      sub_chats = {},
    }
  end
  return global_agent_states[agent_type]
end

function ReasoningAgentBase.clear_state(agent_type)
  global_agent_states[agent_type] = {
    current_instance = nil,
    session_id = nil,
    tool_instance = nil,
    sub_chats = {},
  }
end

local function create_validator(action_rules)
  return function(action, args)
    local required = action_rules[action]
    if not required then
      return true
    end

    for _, param in ipairs(required) do
      if not args[param] then
        return false, param .. ' is required for ' .. action
      end
    end
    return true
  end
end

function ReasoningAgentBase.create_tool_definition(agent_config)
  local agent_type = agent_config.agent_type
  local actions = agent_config.actions
  local validation_rules = agent_config.validation_rules

  local validator = create_validator(validation_rules)

  local function handle_action(args, tool_instance)
    log:debug('[%s] Handling action: %s', agent_type, args.action)

    local agent_state = ReasoningAgentBase.get_state(agent_type)
    agent_state.tool_instance = tool_instance

    -- Add companion tools when agent is first used
    if tool_instance and tool_instance.chat then
      ReasoningAgentBase.add_companion_tools(tool_instance, agent_type)
    end

    -- Validate action and arguments
    local valid_actions = vim.tbl_keys(validation_rules)
    if not vim.tbl_contains(valid_actions, args.action) then
      return {
        status = 'error',
        data = fmt("Invalid action '%s'. Valid actions: %s", args.action, table.concat(valid_actions, ', ')),
      }
    end

    local valid, error_msg = validator(args.action, args)
    if not valid then
      return { status = 'error', data = error_msg }
    end

    -- Dispatch to action handler
    local handler = actions[args.action]
    if not handler then
      return { status = 'error', data = fmt("No handler found for action '%s'", args.action) }
    end

    return handler(args, agent_state)
  end

  return {
    name = 'agent',
    cmds = {
      function(self, args, input)
        log:debug('[%s] Tool invoked - action: %s', agent_type, args.action or 'nil')
        local result = handle_action(args, self)
        log:debug('[%s] Command completed - status: %s', agent_type, result.status)
        return result
      end,
    },
    schema = {
      type = 'function',
      ['function'] = {
        name = agent_config.tool_name,
        description = agent_config.description,
        parameters = agent_config.parameters,
        strict = true,
      },
    },
    handlers = {
      on_exit = function(agent)
        local agent_state = ReasoningAgentBase.get_state(agent_type)
        log:debug('[%s] Session ended - session: %s', agent_type, agent_state.session_id or 'none')
      end,
    },
    output = ReasoningAgentBase.create_output_handlers(agent_type),
  }
end

function ReasoningAgentBase.create_output_handlers(agent_type)
  return {
    success = function(self, agent, cmd, stdout)
      local chat = agent.chat
      local result = vim.iter(stdout):flatten():join('\n')
      local llm_output = fmt('%s', result)
      log:debug('[%s] Success output generated - output_length: %d', agent_type, #result)
      chat:add_tool_output(self, llm_output, llm_output)
    end,

    error = function(self, agent, cmd, stderr)
      local chat = agent.chat
      local errors = vim.iter(stderr):flatten():join('\n')
      local agent_state = ReasoningAgentBase.get_state(agent_type)
      log:debug('[%s] Error occurred - session: %s', agent_type, agent_state.session_id or 'none')
      log:debug('[%s] Error details: %s', agent_type, errors)
      local error_output = fmt('❌ %s ERROR: %s', agent_type, errors)
      chat:add_tool_output(self, error_output)
    end,

    prompt = function(self, agent)
      log:debug(
        '[%s] Prompting user for approval - action: %s',
        agent_type,
        self.args and self.args.action or 'unknown'
      )
      return fmt('Use %s (%s)?', agent_type, self.args and self.args.action or 'unknown action')
    end,

    rejected = function(self, agent, cmd, feedback)
      local chat = agent.chat
      log:debug(
        '[%s] User rejected execution - action: %s, feedback: %s',
        agent_type,
        self.args and self.args.action or 'unknown',
        feedback or 'none'
      )
      local message = fmt('❌ %s: User declined to execute %s', agent_type, self.args and self.args.action or 'action')
      if feedback and feedback ~= '' then
        message = message .. fmt(' with feedback: %s', feedback)
      end
      chat:add_tool_output(self, message)
    end,
  }
end

return {
  ReasoningAgentBase = ReasoningAgentBase,
}
