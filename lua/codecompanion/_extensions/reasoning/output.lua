local Constants = require('codecompanion._extensions.reasoning.constants')
local Control = require('codecompanion._extensions.reasoning.control')
local State = require('codecompanion._extensions.reasoning.state')
local Terminal = require('codecompanion._extensions.reasoning.terminal')

local M = {}

local known_actions = { none = true }
for _, name in ipairs(Constants.tool_names) do
  known_actions[name] = true
end

local function text(value)
  return type(value) == 'string' and vim.trim(value) ~= ''
end

local function last(values)
  return type(values) == 'table' and values[#values] or nil
end

local function encode(value)
  local ok, encoded = pcall(vim.json.encode, value)
  return ok and encoded or nil
end

local function next_action_valid(value)
  return type(value) == 'table' and known_actions[value.tool] == true and text(value.reason)
end

local function internal_payload(tool, message)
  local retry_tool = tool and known_actions[tool.name] and tool.name or 'reasoning_start'
  return {
    code = 'internal_error',
    message = message,
    artifact_ids = {},
    committed = false,
    next_action = {
      tool = retry_tool,
      reason = 'Retry only after changing the request or frame; never repeat unchanged arguments',
    },
  }
end

local function public_payload(payload)
  local result = {}
  for key, value in pairs(payload) do
    if key ~= '_reasoning_final' then
      result[key] = value
    end
  end
  return result
end

local function discard_internal(internal)
  if type(internal) == 'table' then
    pcall(State.discard_final, internal.stage)
  end
end

local function emit_internal(tool, meta, message)
  local encoded = assert(encode(internal_payload(tool, message)))
  meta.tools.chat:add_tool_output(tool, encoded, 'Reasoning output rejected: internal_error')
end

function M.success(tool, stdout, meta)
  local payload = last(stdout)
  local artifact = type(payload) == 'table'
      and (payload.artifact or (payload.artifacts and payload.artifacts[#payload.artifacts]))
    or nil
  if type(artifact) ~= 'table' or not text(artifact.id) or not next_action_valid(payload.next_action) then
    discard_internal(type(payload) == 'table' and payload._reasoning_final or nil)
    return emit_internal(tool, meta, 'reasoning success output is malformed')
  end
  if
    payload.next_action.tool == 'none'
    and not (
      tool.name == 'reasoning_final'
      and artifact.kind == 'synthesis'
      and type(artifact.data) == 'table'
      and artifact.data.mode == 'final'
      and type(payload.unmet_gates) == 'table'
      and #payload.unmet_gates == 0
    )
  then
    discard_internal(type(payload) == 'table' and payload._reasoning_final or nil)
    return emit_internal(tool, meta, 'only an accepted final synthesis may be terminal')
  end
  local terminal = payload.next_action.tool == 'none'
  local internal = payload._reasoning_final
  if internal ~= nil then
    if
      not terminal
      or type(internal) ~= 'table'
      or type(internal.stage) ~= 'table'
      or internal.stage.state ~= 'prepared'
      or not text(internal.markdown)
    then
      discard_internal(internal)
      return emit_internal(tool, meta, 'reasoning final stage is malformed')
    end
  end
  local legacy_terminal = terminal and internal == nil and Control.legacy_terminal_allowed(meta.tools.chat)
  if terminal and internal == nil and not legacy_terminal then
    return emit_internal(tool, meta, 'reasoning final stage is unavailable')
  end

  local encoded = encode(public_payload(payload))
  if not encoded then
    discard_internal(internal)
    return emit_internal(tool, meta, 'reasoning success output could not be serialized')
  end
  if internal then
    local ok, staged = pcall(Control.stage_final, meta.tools.chat, tool, internal)
    if not ok or staged ~= true then
      discard_internal(internal)
      return emit_internal(tool, meta, 'reasoning final stage was refused')
    end
    meta.tools.chat:add_tool_output(tool, encoded, '')
    return
  end
  meta.tools.chat:add_tool_output(
    tool,
    encoded,
    string.format('Recorded %s; next: %s', artifact.id, payload.next_action.tool)
  )
  if legacy_terminal and Control.legacy_terminal_allowed(meta.tools.chat) then
    Terminal.install(meta.tools)
  end
end

function M.error(tool, stderr, meta)
  local payload = last(stderr)
  if type(payload) ~= 'table' or not text(payload.code) or not next_action_valid(payload.next_action) then
    return emit_internal(tool, meta, 'reasoning error output is malformed')
  end
  local encoded = encode(payload)
  if not encoded then
    return emit_internal(tool, meta, 'reasoning error output could not be serialized')
  end
  meta.tools.chat:add_tool_output(tool, encoded, 'Reasoning step rejected: ' .. payload.code)
end

M.handlers = { success = M.success, error = M.error }

return M
