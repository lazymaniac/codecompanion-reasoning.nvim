local M = {}

function M.next(workspace)
  local evidence_count = workspace.counts_by_kind.evidence or 0
  if evidence_count == 0 then
    return { tool = 'reasoning_evidence', reason = 'Gather evidence for the framed perspectives' }
  end
  return { tool = 'reasoning_synthesis', reason = 'Record a checkpoint and inspect remaining gates' }
end

return M
