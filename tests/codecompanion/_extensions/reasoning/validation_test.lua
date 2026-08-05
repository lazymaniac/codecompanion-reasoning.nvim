local Validation = require('codecompanion._extensions.reasoning.validation')

local T = MiniTest.new_set()
local eq = MiniTest.expect.equality

T['describes missing, bounded, and enum failures safely'] = function()
  eq(Validation.required(nil, 'items', 'array'), {
    path = 'items',
    constraint = 'required',
    expected = 'array',
    actual = 'missing',
  })
  eq(Validation.text(string.rep('x', 9), 'objective', 8), {
    path = 'objective',
    constraint = 'max_chars',
    expected = 8,
    actual = 9,
  })
  eq(Validation.enum('model supplied markdown', 'mode', { final = true }), {
    path = 'mode',
    constraint = 'enum',
    expected = { 'final' },
    actual = 'unknown_enum',
  })
end

T['reports only safe IDs and duplicate sentinels'] = function()
  local workspace = {
    artifacts_by_id = {
      F1 = { id = 'F1', kind = 'frame', status = 'active' },
      E1 = { id = 'E1', kind = 'evidence', status = 'retracted' },
    },
  }
  eq(Validation.reference(workspace, 'F1', 'support_ids[1]', 'evidence').constraint, 'artifact_kind')
  eq(Validation.reference(workspace, 'E1', 'support_ids[1]', 'evidence').constraint, 'artifact_status')
  eq(Validation.reference(workspace, string.rep('x', 200), 'support_ids[1]', 'evidence').actual, 'invalid_id')
  eq(Validation.unique({ 'arbitrary prose', 'arbitrary prose' }, 'unknowns'), {
    path = 'unknowns[2]',
    constraint = 'unique_items',
    expected = true,
    actual = 'duplicate_value',
  })
  eq(Validation.artifact_ids({ 'E1', '# forged\nmodel prose' }), { 'E1', 'invalid_id' })
end

return T
