local Protocol = require('codecompanion._extensions.reasoning.protocol')
local State = require('codecompanion._extensions.reasoning.state')
local Tree = require('codecompanion._extensions.reasoning.tree')

local M = {}

function M.split_args(overrides)
  return vim.tbl_extend('force', {
    parent_id = '',
    axis = 'component',
    composition = 'all_of',
    residual = '',
    residual_disposition = 'none',
    residual_covered_by = '',
    child_questions = {},
  }, overrides or {})
end

function M.drop_args(overrides)
  return vim.tbl_extend('force', {
    question_id = '',
    justification = '',
    drop_reason = 'not_material',
    evidence_ids = {},
  }, overrides or {})
end

function M.answer_args(overrides)
  return vim.tbl_extend('force', {
    question_id = '',
    answer = '',
    evidence_ids = {},
    acceptance_test = 'Observe the closing result',
    resolution_kind = 'observation',
    confidence = 'medium',
  }, overrides or {})
end

-- Satisfies the decomposition gates for fixtures that exercise other parts of
-- the protocol. Leaves are dropped as out-of-scope against an active frame
-- constraint, so no evidence artifact is allocated and every existing artifact
-- ID in a fixture keeps its sequence.
function M.satisfy(chat, constraint)
  local workspace = State.get(chat)
  if not workspace then
    return nil, 'workspace_missing'
  end
  local frame = State.find(workspace, workspace.frame_id)
  constraint = constraint or (frame and frame.data.constraints and frame.data.constraints[1])
  if not Tree.root_split(workspace) then
    local result = Protocol.call(
      'split',
      chat,
      M.split_args({
        parent_id = workspace.frame_id,
        child_questions = {
          {
            text = 'Does the design survive a restart?',
            kind = 'sub_problem',
            acceptance_test = 'Observe a restart',
            resolution_kind = 'observation',
          },
          {
            text = 'Does the design bound memory?',
            kind = 'sub_problem',
            acceptance_test = 'Observe steady-state memory',
            resolution_kind = 'observation',
          },
        },
      }),
      nil
    )
    if result.status ~= 'success' then
      return nil, result.data.code
    end
  end
  for _, leaf in ipairs(Tree.open_leaves(workspace, {})) do
    local dropped = Protocol.call(
      'drop',
      chat,
      M.drop_args({
        question_id = leaf.id,
        justification = constraint,
        drop_reason = 'out_of_scope',
      }),
      nil
    )
    if dropped.status ~= 'success' then
      return nil, dropped.data.code
    end
  end
  return true
end

return M
