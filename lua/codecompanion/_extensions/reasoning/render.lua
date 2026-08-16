local Tree = require('codecompanion._extensions.reasoning.tree')

local M = {}

local escapable = {
  ['\\'] = true,
  ['`'] = true,
  ['*'] = true,
  ['_'] = true,
  ['{'] = true,
  ['}'] = true,
  ['['] = true,
  [']'] = true,
  ['('] = true,
  [')'] = true,
  ['#'] = true,
  ['>'] = true,
  ['+'] = true,
  ['-'] = true,
  ['.'] = true,
  ['!'] = true,
  ['|'] = true,
  ['~'] = true,
}

local headings = {
  solution = { 'Selected solution', 'Selected solutions' },
  hypothesis = { 'Selected hypothesis', 'Selected hypotheses' },
  scenario = { 'Selected scenario', 'Selected scenarios' },
}

local function scalar(value)
  assert(type(value) == 'string', 'rendered values must be strings')
  value = vim.trim(value):gsub('%s+', ' ')
  value = value:gsub('&', '&amp;'):gsub('<', '&lt;'):gsub('>', '&gt;')
  return (value:gsub('.', function(char)
    return escapable[char] and ('\\' .. char) or char
  end))
end

local function active(workspace, id, kind)
  local artifact = workspace.artifacts_by_id[id]
  assert(artifact, 'render reference ' .. tostring(id) .. ' is missing')
  assert(artifact.status == 'active', 'render reference ' .. id .. ' is inactive')
  assert(artifact.kind == kind, 'render reference ' .. id .. ' has the wrong kind')
  return artifact
end

local function section(lines, heading, entries)
  if #entries == 0 then
    return
  end
  if #lines > 0 then
    table.insert(lines, '')
  end
  table.insert(lines, '## ' .. heading)
  table.insert(lines, '')
  vim.list_extend(lines, entries)
end

function M.render(workspace, candidate)
  assert(type(workspace) == 'table', 'workspace is required')
  assert(type(candidate) == 'table', 'final synthesis candidate is required')

  local selected, evidence, reviews = {}, {}, {}
  local seen_evidence = {}
  local function add_evidence(id)
    if not seen_evidence[id] then
      seen_evidence[id] = true
      table.insert(evidence, active(workspace, id, 'evidence'))
    end
  end

  for _, id in ipairs(candidate.selected_option_ids or {}) do
    local option = active(workspace, id, 'option')
    table.insert(selected, option)
    for _, evidence_id in ipairs(option.data.evidence_ids or {}) do
      add_evidence(evidence_id)
    end
  end
  for _, id in ipairs(candidate.support_ids or {}) do
    add_evidence(id)
  end
  for _, result in ipairs(candidate.criterion_results or {}) do
    for _, id in ipairs(result.evidence_ids or {}) do
      add_evidence(id)
    end
  end
  for _, id in ipairs(candidate.review_ids or {}) do
    table.insert(reviews, active(workspace, id, 'review'))
  end

  local branch
  if #selected > 0 then
    local selected_ids = {}
    for _, option in ipairs(selected) do
      selected_ids[option.id] = true
    end
    for _, id in ipairs(workspace.artifact_order) do
      local value = workspace.artifacts_by_id[id]
      if
        value
        and value.kind == 'branch'
        and value.status == 'active'
        and value.data.frame_id == workspace.frame_id
      then
        local members = {}
        for _, option_id in ipairs(value.data.option_ids or {}) do
          members[option_id] = true
        end
        local contains_all = true
        for option_id in pairs(selected_ids) do
          contains_all = contains_all and members[option_id] == true
        end
        if contains_all then
          branch = value
          break
        end
      end
    end
    assert(branch, 'selected options are not members of an active branch')
  end

  local lines = {}
  section(lines, 'Conclusion', { scalar(candidate.conclusion) })
  if branch then
    local titles = assert(headings[branch.data.branch_type], 'unknown branch type')
    local entries = {}
    for _, option in ipairs(selected) do
      table.insert(
        entries,
        string.format('- **%s — %s:** %s', scalar(option.id), scalar(option.data.label), scalar(option.data.summary))
      )
    end
    section(lines, titles[#selected == 1 and 1 or 2], entries)
  end

  local evidence_entries = {}
  for _, item in ipairs(evidence) do
    table.insert(
      evidence_entries,
      string.format(
        '- **%s:** %s _(source: %s; confidence: %s)_',
        scalar(item.id),
        scalar(item.data.statement),
        scalar(item.data.source),
        scalar(item.data.confidence)
      )
    )
  end
  section(lines, 'Supporting evidence', evidence_entries)

  local review_entries = {}
  for _, review in ipairs(reviews) do
    table.insert(review_entries, '- **' .. scalar(review.id) .. '**')
    for _, challenge in ipairs(review.data.challenges or {}) do
      table.insert(
        review_entries,
        string.format(
          '  - Challenge (%s; targets: %s): %s',
          scalar(challenge.kind),
          scalar(table.concat(challenge.target_ids or {}, ', ')),
          scalar(challenge.summary)
        )
      )
    end
    for _, verdict in ipairs(review.data.verdicts or {}) do
      local instruction = vim.trim(verdict.revision_instruction or '')
      local suffix = instruction ~= '' and (': ' .. scalar(instruction)) or ''
      table.insert(
        review_entries,
        string.format('  - Verdict (%s): %s%s', scalar(verdict.target_id), scalar(verdict.status), suffix)
      )
    end
    for _, resolution in ipairs(review.data.contradiction_resolutions or {}) do
      table.insert(
        review_entries,
        string.format(
          '  - Resolution (%s/%s; evidence: %s): %s',
          scalar(resolution.left_id),
          scalar(resolution.right_id),
          scalar(table.concat(resolution.evidence_ids or {}, ', ')),
          scalar(resolution.resolution)
        )
      )
    end
    for _, tradeoff in ipairs(review.data.structural_tradeoffs or {}) do
      table.insert(
        review_entries,
        string.format(
          '  - Structural trade-off (evidence: %s): %s',
          scalar(table.concat(tradeoff.evidence_ids or {}, ', ')),
          scalar(tradeoff.statement)
        )
      )
    end
  end
  section(lines, 'Adversarial review', review_entries)

  local resolved, dropped = {}, {}
  if Tree.root_split(workspace) then
    for _, node in ipairs(Tree.preorder(workspace)) do
      local closure = #Tree.children(workspace, node.id) == 0 and Tree.closure(workspace, node.id) or nil
      if closure and closure.data.action == 'answer' then
        table.insert(
          resolved,
          string.format(
            '- **%s — %s:** %s _(evidence: %s)_',
            scalar(node.id),
            scalar(node.data.text),
            scalar(closure.data.answer),
            scalar(table.concat(closure.relations.supports or {}, ', '))
          )
        )
      elseif closure then
        table.insert(
          dropped,
          string.format(
            '- **%s — %s:** %s _(%s)_',
            scalar(node.id),
            scalar(node.data.text),
            scalar(closure.data.justification),
            scalar(closure.data.drop_reason)
          )
        )
      end
    end
  end
  section(lines, 'Resolved sub-questions', resolved)
  section(lines, 'Dropped sub-questions', dropped)

  local criteria = {}
  for _, result in ipairs(candidate.criterion_results or {}) do
    table.insert(
      criteria,
      string.format(
        '- **%s** — %s: %s _(evidence: %s)_',
        scalar(result.criterion),
        scalar(result.status),
        scalar(result.explanation),
        scalar(table.concat(result.evidence_ids or {}, ', '))
      )
    )
  end
  section(lines, 'Success criteria', criteria)

  for _, definition in ipairs({
    { 'Trade-offs', candidate.tradeoffs },
    { 'Uncertainties', candidate.uncertainties },
    { 'Blind spots', candidate.blind_spots },
    { 'Next actions', candidate.next_actions },
  }) do
    local entries = {}
    for _, value in ipairs(definition[2] or {}) do
      table.insert(entries, '- ' .. scalar(value))
    end
    section(lines, definition[1], entries)
  end

  section(lines, 'Confidence', { scalar(candidate.confidence) })
  return table.concat(lines, '\n') .. '\n'
end

return M
