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
    return { tool = 'reasoning_start', reason = 'Create the active problem frame' }
  end
  if phase == 'reframing' then
    return {
      tool = 'reasoning_revise',
      reason = 'Revise the active frame for the new user information, or replace it',
    }
  end
  if terminal_reasons[phase] then
    return { tool = 'none', reason = terminal_reasons[phase] }
  end
  return Guidance.next(workspace)
end

--- The authoritative transition names one precise tool. Any tool in that
--- tool's family satisfies it, so a leaf may be dropped where an answer was
--- suggested, a branch set replaced instead of created, or a checkpoint
--- recorded where a final is ready.
function M.allowed(workspace, phase, operation)
  if phase == nil or phase == 'dormant' then
    return true
  end
  local reframe = Constants.reframe_operations[operation] == true
  if phase == 'finalized' and reframe then
    return workspace ~= nil
  end
  if phase == 'blocked' or phase == 'finalizing' or phase == 'halted' or phase == 'finalized' then
    return false
  end
  if phase == 'armed' then
    return workspace == nil and operation == 'start'
  end
  if phase == 'reframing' then
    return workspace ~= nil and reframe
  end
  local family = Constants.family_by_operation[operation]
  if phase == 'active' and family == 'frame' and operation ~= 'start' then
    return workspace ~= nil
  end
  local expected = M.next(workspace, phase)
  return expected ~= nil and family ~= nil and Constants.family_by_tool[expected.tool] == family
end

return M
