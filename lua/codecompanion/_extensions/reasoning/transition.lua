local Constants = require('codecompanion._extensions.reasoning.constants')
local Guidance = require('codecompanion._extensions.reasoning.guidance')

local M = {}

local terminal_reasons = {
  blocked = 'Reasoning lifecycle enforcement is unavailable for this chat',
  finalizing = 'Finish recording the accepted final synthesis',
  halted = 'Wait for explicit user resume',
  finalized = 'The accepted final is terminal until explicit reframe',
}

function M.next(workspace, phase)
  if phase == nil or phase == 'dormant' then
    return nil
  end
  if phase == 'armed' then
    return { tool = 'reasoning_frame', reason = 'Create the active problem frame with action=start' }
  end
  if phase == 'reframing' then
    return { tool = 'reasoning_frame', reason = 'Revise or replace the active frame for new user information' }
  end
  if terminal_reasons[phase] then
    return { tool = 'none', reason = terminal_reasons[phase] }
  end
  return Guidance.next(workspace)
end

function M.allowed(workspace, phase, operation, args)
  if phase == nil or phase == 'dormant' then
    return true
  end
  local explicit_reframe = operation == 'frame'
    and type(args) == 'table'
    and vim.tbl_contains({ 'revise', 'replace' }, args.action)
  if phase == 'finalized' and explicit_reframe then
    return workspace ~= nil
  end
  if phase == 'blocked' or phase == 'finalizing' or phase == 'halted' or phase == 'finalized' then
    return false
  end
  if phase == 'armed' then
    return workspace == nil and operation == 'frame' and type(args) == 'table' and args.action == 'start'
  end
  if phase == 'reframing' then
    return workspace ~= nil
      and operation == 'frame'
      and type(args) == 'table'
      and vim.tbl_contains({ 'revise', 'replace' }, args.action)
  end
  if
    phase == 'active'
    and operation == 'frame'
    and type(args) == 'table'
    and vim.tbl_contains({ 'revise', 'replace' }, args.action)
  then
    return workspace ~= nil
  end
  local expected = M.next(workspace, phase)
  return expected ~= nil and Constants.tool_by_operation[operation] == expected.tool
end

return M
