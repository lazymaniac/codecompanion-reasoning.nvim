local Render = require('codecompanion._extensions.reasoning.render')

local T = MiniTest.new_set()
local eq = MiniTest.expect.equality

local function artifact(id, kind, data)
  return {
    id = id,
    kind = kind,
    status = 'active',
    data = data,
    relations = {
      supports = {},
      contradicts = {},
      qualifies = {},
      depends_on = {},
      tests = {},
      supersedes = {},
    },
  }
end

local function evidence(id, statement)
  return artifact(id, 'evidence', {
    statement = statement,
    source = 'tests/render_fixture.lua:' .. id:sub(2),
    confidence = 'high',
  })
end

local function fixture()
  local values = {
    artifact('F1', 'frame', {}),
    evidence('E1', 'Journal replay restores committed writes'),
    evidence('E2', 'Snapshots bound replay time'),
    evidence('E3', 'Checksums detect torn records'),
    evidence('E4', 'Compaction bounds disk growth'),
    evidence('E99', 'Unrelated active evidence must remain outside the closure'),
    artifact('B1', 'branch', {
      frame_id = 'F1',
      branch_type = 'solution',
      option_ids = { 'O1', 'O2' },
    }),
    artifact('O1', 'option', {
      label = 'Journal',
      summary = 'Replay an append-only journal',
      evidence_ids = { 'E2', 'E1' },
    }),
    artifact('O2', 'option', {
      label = 'Snapshot',
      summary = 'Checkpoint state and compact the journal',
      evidence_ids = { 'E1', 'E3' },
    }),
    artifact('B2', 'branch', {
      frame_id = 'F1',
      branch_type = 'hypothesis',
      option_ids = { 'O3', 'O4' },
    }),
    artifact('O3', 'option', {
      label = 'Torn write',
      summary = 'Recovery fails after a partial record',
      evidence_ids = { 'E3' },
    }),
    artifact('O4', 'option', {
      label = 'Stale snapshot',
      summary = 'Recovery loads an obsolete checkpoint',
      evidence_ids = { 'E2' },
    }),
    artifact('B3', 'branch', {
      frame_id = 'F1',
      branch_type = 'scenario',
      option_ids = { 'O5', 'O6' },
    }),
    artifact('O5', 'option', {
      label = 'Normal restart',
      summary = 'The process exits between records',
      evidence_ids = { 'E1' },
    }),
    artifact('O6', 'option', {
      label = 'Power loss',
      summary = 'The process stops during a record',
      evidence_ids = { 'E3' },
    }),
    artifact('R1', 'review', {
      challenges = {
        { kind = 'counterexample', target_ids = { 'O1' }, summary = 'Replay may exceed the startup budget' },
      },
      verdicts = {
        { target_id = 'O1', status = 'keep', revision_instruction = '' },
      },
      contradiction_resolutions = {
        {
          left_id = 'E1',
          right_id = 'E2',
          evidence_ids = { 'E3' },
          resolution = 'Snapshots and replay cover different recovery windows',
        },
      },
      structural_tradeoffs = {
        { evidence_ids = { 'E4' }, statement = 'Compaction trades write work for bounded recovery' },
      },
    }),
  }
  local workspace = {
    frame_id = 'F1',
    artifact_order = {},
    artifacts_by_id = {},
  }
  for _, value in ipairs(values) do
    workspace.artifacts_by_id[value.id] = value
    table.insert(workspace.artifact_order, value.id)
  end
  return workspace
end

local function candidate()
  return {
    mode = 'final',
    conclusion = 'Use snapshots with journal replay and checksum validation.',
    selected_option_ids = { 'O1', 'O2' },
    support_ids = { 'E3', 'E4', 'E1' },
    review_ids = { 'R1' },
    criterion_results = {
      {
        criterion = 'Durable recovery',
        status = 'passed',
        explanation = 'Replay and checksums cover committed and partial writes.',
        evidence_ids = { 'E4', 'E2' },
      },
      {
        criterion = 'Bounded recovery',
        status = 'passed',
        explanation = 'Snapshots cap the journal prefix that must be replayed.',
        evidence_ids = { 'E3' },
      },
    },
    tradeoffs = { 'Compaction adds background write work.' },
    uncertainties = { 'Crash frequency is not measured.' },
    blind_spots = { 'Filesystem-specific flush semantics.' },
    next_actions = { 'Run power-loss recovery tests.' },
    confidence = 'high',
  }
end

local function position(markdown, value)
  return assert(markdown:find(value, 1, true), 'missing rendered value: ' .. value)
end

local function count_plain(value, needle)
  local count = 0
  local from = 1
  while true do
    local first, last = value:find(needle, from, true)
    if not first then
      return count
    end
    count = count + 1
    from = last + 1
  end
end

T['renders exact section and citation-closure order'] = function()
  local markdown = Render.render(fixture(), candidate())
  local previous = 0
  for _, heading in ipairs({
    'Conclusion',
    'Selected solutions',
    'Supporting evidence',
    'Adversarial review',
    'Success criteria',
    'Trade-offs',
    'Uncertainties',
    'Blind spots',
    'Next actions',
    'Confidence',
  }) do
    local current = position(markdown, '## ' .. heading .. '\n')
    eq(previous < current, true)
    previous = current
  end
  eq(count_plain(markdown, '## '), 10)

  local option_end = position(markdown, '**O2 — Snapshot:**')
  local e2 = position(markdown, '**E2:**')
  local e1 = position(markdown, '**E1:**')
  local e3 = position(markdown, '**E3:**')
  local e4 = position(markdown, '**E4:**')
  eq(option_end < e2, true)
  eq(e2 < e1 and e1 < e3 and e3 < e4, true)
  for _, id in ipairs({ 'E1', 'E2', 'E3', 'E4' }) do
    eq(count_plain(markdown, '**' .. id .. ':**'), 1)
  end
  eq(markdown:find('E99', 1, true), nil)
end

T['uses singular and plural headings for every branch type'] = function()
  for _, branch in ipairs({
    { singular = 'Selected solution', plural = 'Selected solutions', ids = { 'O1', 'O2' } },
    { singular = 'Selected hypothesis', plural = 'Selected hypotheses', ids = { 'O3', 'O4' } },
    { singular = 'Selected scenario', plural = 'Selected scenarios', ids = { 'O5', 'O6' } },
  }) do
    local one = candidate()
    one.selected_option_ids = { branch.ids[1] }
    local singular = Render.render(fixture(), one)
    eq(singular:find('## ' .. branch.singular .. '\n', 1, true) ~= nil, true)
    eq(singular:find('## ' .. branch.plural .. '\n', 1, true), nil)

    local two = candidate()
    two.selected_option_ids = vim.deepcopy(branch.ids)
    local plural = Render.render(fixture(), two)
    eq(plural:find('## ' .. branch.plural .. '\n', 1, true) ~= nil, true)
  end
end

T['renders resolved and dropped sub-questions in pre-order'] = function()
  local workspace = fixture()
  workspace.frame_lineage = { 'F1' }
  workspace.splits = { F1 = { axis = 'component', composition = 'all_of', residual = '', child_ids = { 'Q1', 'Q2' } } }
  local function push(value)
    workspace.artifacts_by_id[value.id] = value
    table.insert(workspace.artifact_order, value.id)
    return value
  end
  push(artifact('Q1', 'question', {
    parent_id = 'F1',
    text = 'Does replay restore committed writes?',
    kind = 'sub_problem',
    provisional = false,
  }))
  push(artifact('Q2', 'question', {
    parent_id = 'F1',
    text = 'Does cluster failover matter?',
    kind = 'sub_problem',
    provisional = false,
  }))
  local answered = push(artifact('C1', 'closure', {
    question_id = 'Q1',
    action = 'answer',
    answer = 'Replay restores every committed write.',
    justification = '',
    drop_reason = 'none',
  }))
  answered.relations.supports = { 'E1' }
  push(artifact('C2', 'closure', {
    question_id = 'Q2',
    action = 'drop',
    answer = '',
    justification = 'Single node only',
    drop_reason = 'out_of_scope',
  }))

  local markdown = Render.render(workspace, candidate())
  eq(position(markdown, '## Resolved sub-questions') < position(markdown, '## Dropped sub-questions'), true)
  eq(position(markdown, '## Dropped sub-questions') < position(markdown, '## Success criteria'), true)
  position(markdown, '- **Q1 — Does replay restore committed writes?:** Replay restores every committed write')
  position(markdown, '_(evidence: E1)_')
  position(markdown, '- **Q2 — Does cluster failover matter?:** Single node only')
end

T['renders a tree-less workspace exactly as before'] = function()
  local markdown = Render.render(fixture(), candidate())
  eq(markdown:find('sub-questions', 1, true), nil)
end

T['omits empty optional sections'] = function()
  local final = candidate()
  final.selected_option_ids = {}
  final.support_ids = {}
  final.review_ids = {}
  final.criterion_results = {}
  final.tradeoffs = {}
  final.uncertainties = {}
  final.blind_spots = {}
  final.next_actions = {}
  local markdown = Render.render(fixture(), final)

  for _, heading in ipairs({
    'Selected solution',
    'Supporting evidence',
    'Adversarial review',
    'Success criteria',
    'Trade-offs',
    'Uncertainties',
    'Blind spots',
    'Next actions',
  }) do
    eq(markdown:find('## ' .. heading, 1, true), nil)
  end
  eq(count_plain(markdown, '## '), 2)
end

T['rejects missing inactive wrong-kind and cross-branch references'] = function()
  local missing = candidate()
  missing.selected_option_ids = {}
  missing.support_ids = { 'E404' }
  missing.review_ids = {}
  missing.criterion_results = {}
  MiniTest.expect.error(function()
    Render.render(fixture(), missing)
  end, 'render reference E404 is missing')

  local inactive_workspace = fixture()
  inactive_workspace.artifacts_by_id.E1.status = 'superseded'
  local inactive = vim.deepcopy(missing)
  inactive.support_ids = { 'E1' }
  MiniTest.expect.error(function()
    Render.render(inactive_workspace, inactive)
  end, 'render reference E1 is inactive')

  local wrong_kind = vim.deepcopy(missing)
  wrong_kind.support_ids = { 'F1' }
  MiniTest.expect.error(function()
    Render.render(fixture(), wrong_kind)
  end, 'render reference F1 has the wrong kind')

  local cross_branch = vim.deepcopy(missing)
  cross_branch.selected_option_ids = { 'O1', 'O3' }
  cross_branch.support_ids = {}
  MiniTest.expect.error(function()
    Render.render(fixture(), cross_branch)
  end, 'selected options are not members of an active branch')
end

T['neutralizes Markdown HTML and newline injection'] = function()
  local hostile = [[# Forged
> Forged
- forged
1. forged
---
```lua
forged()
```
[link]: https://example.invalid
<script>alert('forged')</script>
left | right]]
  local final = candidate()
  final.conclusion = hostile
  final.selected_option_ids = {}
  final.support_ids = {}
  final.review_ids = {}
  final.criterion_results = {}
  final.tradeoffs = {}
  final.uncertainties = {}
  final.blind_spots = {}
  final.next_actions = {}
  final.confidence = hostile
  local markdown = Render.render(fixture(), final)

  eq(select(2, markdown:gsub('\n## ', '')), 1)
  eq(markdown:find('<script>', 1, true), nil)
  eq(markdown:find('\n---\n', 1, true), nil)
  eq(markdown:find('\n[link]:', 1, true), nil)
  eq(markdown:find('\n> Forged', 1, true), nil)
  eq(markdown:find('\n- forged', 1, true), nil)
  eq(markdown:find('\n1. forged', 1, true), nil)
  eq(markdown:find('```', 1, true), nil)
  eq(markdown:find('\n|', 1, true), nil)
  eq(markdown:find('\\|', 1, true) ~= nil, true)
end

return T
