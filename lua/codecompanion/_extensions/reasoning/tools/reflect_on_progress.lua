---@class CodeCompanion.ReflectOnProgress

local fmt = string.format
local config = require('codecompanion._extensions.reasoning.config')

local function get_active_chat()
  local ok_chat_mod, Chat = pcall(require, 'codecompanion.strategies.chat')
  if not ok_chat_mod or not Chat or not Chat.buf_get_chat then
    return nil, 'CodeCompanion chat strategy not available'
  end
  local current_buf = vim.api.nvim_get_current_buf()
  local ok_chat, chat = pcall(Chat.buf_get_chat, current_buf)
  if not ok_chat or not chat then
    return nil, 'No active CodeCompanion chat found in current buffer'
  end
  return chat
end

local function build_conversation_block(messages)
  local blocks = {}
  for _, m in ipairs(messages or {}) do
    if m and (m.role == 'user' or m.role == 'assistant') and m.content then
      local content = m.content
      if type(content) == 'table' then
        content = vim.inspect(content)
      end
      content = vim.trim(content)
      if content ~= '' then
        local prefix = (m.role == 'user') and 'User' or 'Assistant'
        table.insert(blocks, prefix .. ': ' .. content)
      end
    end
  end
  return table.concat(blocks, '\n\n')
end

local function make_reflection_prompt(conversation_text, reflection_text)
  local parts = {
    'Evaluate the following engineering conversation for progress and quality.',
    '',
    'Use only the content provided. Be concise and practical.',
    'Output bullet points only (no headings).',
    '',
    'Focus areas:',
    '- Requirements coverage: what is done and what is missing',
    '- Testing needs: behavior, error/edge cases, regression risks',
    '- Security: input validation/sanitization, secrets handling, unsafe exec, network, path traversal',
    '- Performance: algorithmic complexity, hotspots, external processes, caching opportunities',
    '- Maintainability/Style: small focused functions, early returns, clear names, repo style',
    '- Observability/Errors: useful messages, avoid noisy logs in hot paths',
    '- Backwards compatibility: API stability or migration considerations',
    '- Next steps: 1–3 concrete bullets',
    '',
    'Conversation:',
    conversation_text,
    '',
    'Reflection:',
    reflection_text,
    '',
    'Respond with bullet points only.',
  }
  return table.concat(parts, '\n')
end

local function resolve_adapter_and_settings(chat)
  local client_ok, _client = pcall(require, 'codecompanion.http')
  local schema_ok, schema = pcall(require, 'codecompanion.schema')
  local adapters_ok, adapters = pcall(require, 'codecompanion.adapters')
  if not (client_ok and schema_ok and adapters_ok) then
    return nil, nil, 'CodeCompanion HTTP client not available'
  end

  local function resolve_adapter(value)
    if value == nil then
      return nil
    end
    if type(value) == 'table' then
      return value
    end
    return adapters.resolve(value)
  end

  local cfg = config.get().reflect_on_progress or {}

  local adapter = resolve_adapter(cfg.adapter)
  if not adapter then
    adapter = resolve_adapter(chat.adapter)
  end

  if not adapter then
    return nil, nil, 'No adapter available for reflection'
  end

  local model = cfg.model or (chat.settings and chat.settings.model)
  local schema_settings = model and { model = model } or {}
  local settings = schema.get_default(adapter, schema_settings)
  settings = vim.deepcopy(adapter:map_schema_to_params(settings))
  settings.opts = settings.opts or {}
  settings.opts.stream = false

  return adapter, settings, nil
end

local function request_evaluation(prompt, adapter, settings, callback)
  local client = require('codecompanion.http')
  local payload = {
    messages = adapter:map_roles({
      { role = 'user', content = prompt },
    }),
  }

  client.new({ adapter = settings }):request(payload, {
    callback = function(err, data, _adapter)
      if err and err.stderr ~= '{}' then
        callback(nil, 'Error while generating reflection: ' .. tostring(err.stderr))
        return
      end
      if data and _adapter and _adapter.handlers and _adapter.handlers.chat_output then
        local result = _adapter.handlers.chat_output(_adapter, data)
        if result and result.status == 'success' then
          local text = vim.trim(result.output.content or '')
          callback(text)
          return
        elseif result and result.status == 'error' then
          callback(nil, 'Error while generating reflection: ' .. tostring(result.output))
          return
        end
      end
      callback(nil, 'Failed to generate reflection')
    end,
  }, {
    silent = true,
  })
end

local function handle_action(args, callback)
  local reflection_text = (args and args.content) or ''

  -- Synchronous compatibility path for tests and simple echo usage
  if type(callback) ~= 'function' then
    return {
      status = 'success',
      data = reflection_text,
    }
  end

  local chat, err = get_active_chat()
  if not chat then
    callback({ status = 'success', data = reflection_text })
    return
  end

  local conversation_text = build_conversation_block(chat.messages or {})
  if conversation_text == '' then
    callback({ status = 'success', data = reflection_text })
    return
  end

  local prompt = make_reflection_prompt(conversation_text, vim.trim(reflection_text))
  local adapter, settings, aerr = resolve_adapter_and_settings(chat)
  if not adapter then
    callback({ status = 'success', data = reflection_text })
    return
  end

  request_evaluation(prompt, adapter, settings, function(response, rerr)
    if not response or response == '' then
      callback({ status = 'success', data = reflection_text })
      return
    end
    callback({ status = 'success', data = response })
  end)
end

---@class CodeCompanion.Tool.ReflectOnProgress: CodeCompanion.Tools.Tool
return {
  name = 'reflect_on_progress',
  opts = {},
  cmds = {
    function(self, args, input, callback)
      return handle_action(args, callback)
    end,
  },
  schema = {
    type = 'function',
    ['function'] = {
      name = 'reflect_on_progress',
      description = [[
Share a brief self-reflection on current progress. The tool will return concise bullet points evaluating requirements coverage, testing needs, security, performance, maintainability, observability, compatibility, and next steps.
]],
      parameters = {
        type = 'object',
        properties = {
          content = {
            type = 'string',
            description = "Your short reflection to guide the review. Keep it focused on what's done, what's pending, and any concerns.",
          },
        },
        required = { 'content' },
        additionalProperties = false,
      },
      strict = true,
    },
  },
  output = {
    success = function(self, agent, cmd, stdout)
      local chat = agent.chat
      local result = vim.iter(stdout):flatten():join('\n')
      return chat:add_tool_output(self, result)
    end,
    error = function(self, agent, cmd, stderr)
      local chat = agent.chat
      local errors = vim.iter(stderr):flatten():join('\n')
      return chat:add_tool_output(self, errors)
    end,
  },
}
