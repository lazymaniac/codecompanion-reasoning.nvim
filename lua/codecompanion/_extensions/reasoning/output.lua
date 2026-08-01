local Terminal = require('codecompanion._extensions.reasoning.terminal')

local M = {}

local known_actions = {
  reasoning_frame = true,
  reasoning_evidence = true,
  reasoning_options = true,
  reasoning_review = true,
  reasoning_synthesis = true,
  none = true,
}

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
  local retry_tool = tool and known_actions[tool.name] and tool.name or 'reasoning_frame'
  return {
    code = 'internal_error',
    message = message,
    artifact_ids = {},
    next_action = {
      tool = retry_tool,
      reason = 'Retry only after changing the request or frame; never repeat unchanged arguments',
    },
  }
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
    return emit_internal(tool, meta, 'reasoning success output is malformed')
  end
  if
    payload.next_action.tool == 'none'
    and not (
      tool.name == 'reasoning_synthesis'
      and artifact.kind == 'synthesis'
      and type(artifact.data) == 'table'
      and artifact.data.mode == 'final'
      and type(payload.unmet_gates) == 'table'
      and #payload.unmet_gates == 0
    )
  then
    return emit_internal(tool, meta, 'only an accepted final synthesis may be terminal')
  end
  local encoded = encode(payload)
  if not encoded then
    return emit_internal(tool, meta, 'reasoning success output could not be serialized')
  end
  meta.tools.chat:add_tool_output(
    tool,
    encoded,
    string.format('Recorded %s; next: %s', artifact.id, payload.next_action.tool)
  )
  if payload.next_action.tool == 'none' then
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
  if payload.next_action.tool == 'none' then
    -- v19.22.0 auto-submits errors by default. A terminal status makes this
    -- one result stop locally; Tools:reset restores the normal success state.
    meta.tools.status = 'terminal'
  end
  meta.tools.chat:add_tool_output(tool, encoded, 'Reasoning step rejected: ' .. payload.code)
end

M.handlers = { success = M.success, error = M.error }

return M
