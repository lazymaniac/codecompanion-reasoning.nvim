# Structured Reasoning Model Evaluation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add an opt-in, reproducible control/treatment harness that measures whether the five structured-reasoning tools help a named model on four difficult fixed scenarios without using another model as judge.

**Architecture:** Keep fixtures and scoring deterministic. A pure scorer combines literal grounding terms with canonical claim labels so denials are not misclassified, then evaluates outcome, protocol, recovery, latency, and accumulated per-request token metrics. A headless runner creates two real CodeCompanion v19.22.0 HTTP chats per scenario: a control without the reasoning group and a treatment that fails closed unless all five `@{reasoning}` tools attach. Live model requests remain manual, opt-in, and outside CI.

**Tech Stack:** Lua 5.1/LuaJIT, Neovim APIs, CodeCompanion v19.22.0 chat and tool APIs, MiniTest, StyLua.

---

## Execution prerequisite

Execute this companion only after completing [the core structured-reasoning implementation plan](2026-08-01-structured-reasoning-tools.md) in the clean sibling worktree `/Users/sebastian/workspace/codecompanion-reasoning-rewrite`. The dependency bootstrap from the core plan must already be complete.

Verify the exact baseline before Task 1:

```bash
test -d ../codecompanion.nvim/.git
test "$(git -C ../codecompanion.nvim rev-parse HEAD)" = "2b959b2bf5fdb13e3b333c078ba549996e477b7c"
test "$(git -C ../codecompanion.nvim describe --tags --exact-match)" = "v19.22.0"
test -f deps/mini.nvim/lua/mini/test.lua
test -f lua/codecompanion/_extensions/reasoning/tools/synthesis.lua
make test
```

Expected: the pinned sibling checkout is present and the complete core suite passes before evaluation code is introduced. Tasks 1–5 remain deterministic and offline except for the explicitly labelled optional live command in Task 5.

## File structure

- `tests/fixtures/evaluation/architecture.lua` — constrained architecture decision.
- `tests/fixtures/evaluation/diagnosis.lua` — misleading initial diagnosis.
- `tests/fixtures/evaluation/temporal_design.lua` — delayed multi-version failure.
- `tests/fixtures/evaluation/contradictory_claim.lua` — conflicting performance observations.
- `scripts/reasoning_eval.lua` — pure scoring helpers plus the opt-in headless control/treatment runner.
- `tests/codecompanion/_extensions/reasoning/evaluation_test.lua` — fixture, scoring, and review-selection regression tests; never calls a model.
- `Makefile` — include `scripts/` in StyLua formatting.
- `README.md` — document the exact opt-in command and its limits.

### Task 1: Add the fixed four-scenario corpus

**Files:**
- Create: `tests/fixtures/evaluation/architecture.lua`
- Create: `tests/fixtures/evaluation/diagnosis.lua`
- Create: `tests/fixtures/evaluation/temporal_design.lua`
- Create: `tests/fixtures/evaluation/contradictory_claim.lua`

- [ ] **Step 1: Create the constrained architecture fixture**

Create `tests/fixtures/evaluation/architecture.lua`:

```lua
return {
  id = 'architecture',
  prompt = 'Choose a cache design and explain why it satisfies every supplied constraint.',
  evidence = {
    'The process may restart at any time.',
    'External services are prohibited.',
    'Memory must remain bounded.',
  },
  expected = {
    required_terms = { 'journal', 'recovery', 'bounded' },
    grounding_terms = { 'restart', 'external service', 'memory' },
    claim_labels = {
      { id = 'journal_recovery', class = 'required', description = 'Recommends a journal with restart recovery' },
      { id = 'bounded_memory', class = 'required', description = 'Keeps retained state or memory bounded' },
      { id = 'selects_redis', class = 'forbidden', description = 'Selects Redis or another external service' },
      { id = 'claims_zero_cost', class = 'unsupported', description = 'Claims the design has zero cost' },
      { id = 'claims_perfect_recovery', class = 'unsupported', description = 'Claims recovery is guaranteed perfect' },
    },
    minimum_reasoning_tools = 4,
  },
}
```

- [ ] **Step 2: Create the misleading-diagnosis fixture**

Create `tests/fixtures/evaluation/diagnosis.lua`:

```lua
return {
  id = 'diagnosis',
  prompt = 'Diagnose the latency growth. The initially suggested database-latency hypothesis is plausible but must be tested against all observations.',
  evidence = {
    'Database query p95 remains below 8 ms throughout the incident.',
    'Each configuration reload registers another request listener.',
    'Heap snapshots retain prior listeners and their request caches.',
    'Latency returns to baseline after unregistering duplicate listeners.',
  },
  expected = {
    required_terms = { 'listener', 'leak', 'unregister' },
    grounding_terms = { '8 ms', 'configuration reload', 'heap' },
    claim_labels = {
      { id = 'listener_leak', class = 'required', description = 'Attributes growth to duplicate retained listeners' },
      { id = 'unregister_fix', class = 'required', description = 'Uses listener unregistration as the corrective action' },
      { id = 'database_root_cause', class = 'forbidden', description = 'Concludes the database is the root cause' },
      { id = 'network_outage', class = 'unsupported', description = 'Claims a network outage caused the incident' },
      { id = 'cpu_saturation', class = 'unsupported', description = 'Claims CPU saturation caused the incident' },
    },
    minimum_reasoning_tools = 4,
  },
}
```

- [ ] **Step 3: Create the delayed temporal-failure fixture**

Create `tests/fixtures/evaluation/temporal_design.lua`:

```lua
return {
  id = 'temporal_design',
  prompt = 'Design a schema rollout that remains recoverable across three consecutive version changes and identify the delayed failure.',
  evidence = {
    'Version one writes field alpha and reads alpha.',
    'Version two writes alpha plus beta and reads either.',
    'Version three removes alpha from new records.',
    'Rollback from version three to version one occurs after old alpha records have expired.',
  },
  expected = {
    required_terms = { 'third', 'migration', 'rollback' },
    grounding_terms = { 'version three', 'alpha', 'rollback' },
    claim_labels = {
      { id = 'third_version_failure', class = 'required', description = 'Identifies the delayed third-version compatibility failure' },
      { id = 'rollback_risk', class = 'required', description = 'Identifies rollback risk after old alpha records expire' },
      { id = 'always_backward_compatible', class = 'forbidden', description = 'Claims the rollout is always backward compatible' },
      { id = 'no_data_loss_possible', class = 'unsupported', description = 'Claims data loss is impossible' },
      { id = 'zero_downtime_guaranteed', class = 'unsupported', description = 'Guarantees zero downtime' },
    },
    minimum_reasoning_tools = 5,
  },
}
```

- [ ] **Step 4: Create the contradictory-observation fixture**

Create `tests/fixtures/evaluation/contradictory_claim.lua`:

```lua
return {
  id = 'contradictory_claim',
  prompt = 'Assess whether the cache improved performance without discarding either observation.',
  evidence = {
    'Cache hit ratio increased from 60 percent to 92 percent.',
    'Request p95 latency worsened from 80 ms to 140 ms over the same interval.',
    'CPU time spent serializing cached values doubled.',
  },
  expected = {
    required_terms = { 'hit ratio', 'latency', 'serialization' },
    grounding_terms = { '92 percent', '140 ms', 'serializing' },
    claim_labels = {
      { id = 'benefit_unproven', class = 'required', description = 'Concludes the cache benefit is unproven or mixed' },
      { id = 'serialization_tradeoff', class = 'required', description = 'Identifies serialization cost as a tradeoff' },
      { id = 'cache_definitely_improved', class = 'forbidden', description = 'Concludes the cache definitely improved performance' },
      { id = 'database_regression', class = 'unsupported', description = 'Claims an unobserved database regression' },
      { id = 'network_congestion', class = 'unsupported', description = 'Claims unobserved network congestion' },
    },
    minimum_reasoning_tools = 4,
  },
}
```

- [ ] **Step 5: Verify the corpus is data-only and commit it**

Run:

```bash
test "$(rg -l '^return \{' tests/fixtures/evaluation/*.lua | wc -l | tr -d ' ')" = "4"
! rg -n "require\(|vim\.|io\.|os\." tests/fixtures/evaluation
stylua tests/fixtures/evaluation -f stylua.toml
```

Expected: four fixtures match, no fixture performs work, and StyLua succeeds.

```bash
git add tests/fixtures/evaluation
git commit -m "test(eval): add fixed reasoning corpus"
```

### Task 2: Add the pure scorer and review-selection regression tests

**Files:**
- Create: `scripts/reasoning_eval.lua`
- Create: `tests/codecompanion/_extensions/reasoning/evaluation_test.lua`

- [ ] **Step 1: Write the complete deterministic test first**

Create `tests/codecompanion/_extensions/reasoning/evaluation_test.lua`:

```lua
vim.g.reasoning_eval_library = true
local Eval = dofile('scripts/reasoning_eval.lua')
vim.g.reasoning_eval_library = false

local T = MiniTest.new_set()
local eq = MiniTest.expect.equality

local scenarios = {
  require('fixtures.evaluation.architecture'),
  require('fixtures.evaluation.diagnosis'),
  require('fixtures.evaluation.temporal_design'),
  require('fixtures.evaluation.contradictory_claim'),
}

local function output(tool, selected_option_ids)
  return {
    tool = tool,
    payload = {
      artifact = {
        kind = tool:gsub('^reasoning_', ''),
        data = {
          selected_option_ids = selected_option_ids,
        },
      },
    },
  }
end

local function rejected_review()
  return { tool = 'reasoning_review', payload = { code = 'review_incomplete' } }
end

T['loads four complete deterministic fixtures'] = function()
  eq(vim.tbl_map(function(scenario)
    return scenario.id
  end, scenarios), { 'architecture', 'diagnosis', 'temporal_design', 'contradictory_claim' })
  for _, scenario in ipairs(scenarios) do
    eq(type(scenario.prompt), 'string')
    eq(#scenario.evidence > 0, true)
    eq(#scenario.expected.required_terms > 0, true)
    eq(#scenario.expected.grounding_terms > 0, true)
    eq(#scenario.expected.claim_labels > 0, true)
    local seen_claims = {}
    local required_claims = 0
    for _, claim in ipairs(scenario.expected.claim_labels) do
      eq(type(claim.id), 'string')
      eq(seen_claims[claim.id], nil)
      seen_claims[claim.id] = true
      eq(vim.tbl_contains({ 'required', 'forbidden', 'unsupported' }, claim.class), true)
      required_claims = required_claims + (claim.class == 'required' and 1 or 0)
      eq(type(claim.description), 'string')
    end
    eq(required_claims > 0, true)
    eq(type(scenario.expected.minimum_reasoning_tools), 'number')
  end
end

T['scores outcomes and structural metrics without a judge model'] = function()
  local scored = Eval.score(scenarios[1], {
    final_text = 'Because restart is possible, external service use is forbidden, and memory is constrained, use a journal with recovery and compaction so retained state remains bounded.\nEVAL_CLAIMS: journal_recovery,bounded_memory',
    reasoning_tool_calls = 5,
    valid_reasoning_tool_calls = 4,
    gate_complete = true,
    elapsed_ms = 1250,
    token_usage = { total = 900 },
    review_changed_selection = true,
    recovered_after_rejection = true,
    timed_out = false,
  })
  eq(scored.required_coverage, 1)
  eq(scored.claim_coverage, 1)
  eq(scored.claim_protocol_valid, true)
  eq(scored.forbidden_hits, 0)
  eq(scored.unsupported_claims, 0)
  eq(scored.outcome_correct, true)
  eq(scored.evidence_grounding, 1)
  eq(scored.valid_tool_call_rate, 0.8)
  eq(scored.gate_complete, true)
  eq(scored.protocol_used, true)
  eq(scored.tool_call_count, 5)
  eq(scored.elapsed_ms, 1250)
  eq(scored.token_usage, { total = 900 })
  eq(scored.review_changed_selection, true)
  eq(scored.recovered_after_rejection, true)
  eq(scored.timed_out, false)
end

T['counts forbidden and unsupported claims'] = function()
  local scored = Eval.score(scenarios[1], {
    final_text = 'Use Redis for zero cost and guaranteed perfect recovery.\nEVAL_CLAIMS: selects_redis,claims_zero_cost,claims_perfect_recovery',
    reasoning_tool_calls = 0,
    valid_reasoning_tool_calls = 0,
    gate_complete = false,
    elapsed_ms = 20,
    token_usage = 10,
    review_changed_selection = false,
    recovered_after_rejection = false,
    timed_out = false,
  })
  eq(scored.outcome_correct, false)
  eq(scored.forbidden_hits, 1)
  eq(scored.unsupported_claims, 2)
  eq(scored.valid_tool_call_rate, 0)
  eq(scored.protocol_used, false)
end

T['does not penalize a denied claim merely because its words appear'] = function()
  local scored = Eval.score(scenarios[1], {
    final_text = 'Use a journal with recovery and bounded memory. Do not use Redis; zero cost and guaranteed perfect recovery are unsupported.\nEVAL_CLAIMS: journal_recovery,bounded_memory',
    reasoning_tool_calls = 0,
    valid_reasoning_tool_calls = 0,
    gate_complete = false,
    elapsed_ms = 20,
    token_usage = 10,
    review_changed_selection = false,
    recovered_after_rejection = false,
    timed_out = false,
  })
  eq(scored.claim_protocol_valid, true)
  eq(scored.forbidden_hits, 0)
  eq(scored.unsupported_claims, 0)
  eq(scored.outcome_correct, true)
end

T['fails closed on missing or unknown claim labels'] = function()
  local missing = Eval.score(scenarios[1], {
    final_text = 'Use a journal with recovery and bounded memory.',
  })
  eq(missing.claim_protocol_valid, false)
  eq(missing.outcome_correct, false)

  local unknown = Eval.score(scenarios[1], {
    final_text = 'Use a journal with recovery and bounded memory.\nEVAL_CLAIMS: journal_recovery,bounded_memory,invented',
  })
  eq(unknown.claim_protocol_valid, false)
  eq(unknown.outcome_correct, false)
end

T['does not mistake an empty checkpoint for a review-driven change'] = function()
  eq(Eval.selection_changed_after_review({
    output('reasoning_synthesis', {}),
    output('reasoning_review'),
    output('reasoning_synthesis', { 'O1' }),
  }), false)
end

T['does not report change when review precedes any selected option'] = function()
  eq(Eval.selection_changed_after_review({
    output('reasoning_review'),
    output('reasoning_synthesis', { 'O1' }),
  }), false)
end

T['reports a nonempty selection changed after an accepted review'] = function()
  eq(Eval.selection_changed_after_review({
    output('reasoning_synthesis', { 'O1' }),
    output('reasoning_review'),
    output('reasoning_synthesis', { 'O2' }),
  }), true)
end

T['does not report an unchanged post-review selection'] = function()
  eq(Eval.selection_changed_after_review({
    output('reasoning_synthesis', { 'O1' }),
    output('reasoning_review'),
    output('reasoning_synthesis', { 'O1' }),
  }), false)
end

T['does not attribute a change without an intervening review'] = function()
  eq(Eval.selection_changed_after_review({
    output('reasoning_synthesis', { 'O1' }),
    output('reasoning_synthesis', { 'O2' }),
  }), false)
end

T['does not attribute a change to a rejected review'] = function()
  eq(Eval.selection_changed_after_review({
    output('reasoning_synthesis', { 'O1' }),
    rejected_review(),
    output('reasoning_synthesis', { 'O2' }),
  }), false)
end

T['treats selected option IDs as a set'] = function()
  eq(Eval.selection_changed_after_review({
    output('reasoning_synthesis', { 'O1', 'O2' }),
    output('reasoning_review'),
    output('reasoning_synthesis', { 'O2', 'O1' }),
  }), false)
end

T['compares only the first nonempty synthesis after each review'] = function()
  eq(Eval.selection_changed_after_review({
    output('reasoning_synthesis', { 'O1' }),
    output('reasoning_review'),
    output('reasoning_synthesis', { 'O1' }),
    output('reasoning_synthesis', { 'O2' }),
  }), false)
end

return T
```

- [ ] **Step 2: Run the test and verify the scorer is absent**

Run: `make test_file FILE=tests/codecompanion/_extensions/reasoning/evaluation_test.lua`

Expected: FAIL because `scripts/reasoning_eval.lua` does not exist.

- [ ] **Step 3: Create the deterministic scorer library**

Create `scripts/reasoning_eval.lua`:

```lua
local M = {}

local function count_terms(text, terms)
  local count = 0
  text = (text or ''):lower()
  for _, term in ipairs(terms) do
    if text:find(term:lower(), 1, true) then
      count = count + 1
    end
  end
  return count
end

local function claim_sets(expected)
  local sets = { known = {}, required = {}, forbidden = {}, unsupported = {} }
  for _, claim in ipairs(expected.claim_labels) do
    sets.known[claim.id] = true
    sets[claim.class][claim.id] = true
  end
  return sets
end

local function parse_claims(text, known)
  local encoded
  for line in (text or ''):gmatch('[^\r\n]+') do
    local candidate = line:match('^EVAL_CLAIMS:%s*(.-)%s*$')
    if candidate then
      if encoded then
        return {}, false
      end
      encoded = candidate
    end
  end
  if not encoded or encoded == '' then
    return {}, false
  end
  if encoded == 'none' then
    return {}, true
  end
  local selected = {}
  for raw in encoded:gmatch('[^,]+') do
    local id = vim.trim(raw)
    if id == '' or not known[id] or selected[id] then
      return {}, false
    end
    selected[id] = true
  end
  return selected, true
end

function M.score(scenario, run)
  local expected = scenario.expected
  local required_hits = count_terms(run.final_text, expected.required_terms)
  local grounding_hits = count_terms(run.final_text, expected.grounding_terms)
  local sets = claim_sets(expected)
  local selected, claim_protocol_valid = parse_claims(run.final_text, sets.known)
  local required_claim_hits = 0
  local forbidden_hits = 0
  local unsupported_claims = 0
  for id in pairs(sets.required) do
    required_claim_hits = required_claim_hits + (selected[id] and 1 or 0)
  end
  for id in pairs(selected) do
    forbidden_hits = forbidden_hits + (sets.forbidden[id] and 1 or 0)
    unsupported_claims = unsupported_claims + (sets.unsupported[id] and 1 or 0)
  end
  local calls = run.reasoning_tool_calls or 0
  local valid_calls = run.valid_reasoning_tool_calls or 0
  local coverage = required_hits / #expected.required_terms
  local claim_coverage = required_claim_hits / vim.tbl_count(sets.required)
  return {
    required_coverage = coverage,
    claim_coverage = claim_coverage,
    claim_protocol_valid = claim_protocol_valid,
    forbidden_hits = forbidden_hits,
    unsupported_claims = unsupported_claims,
    evidence_grounding = grounding_hits / #expected.grounding_terms,
    outcome_correct = coverage == 1
      and claim_coverage == 1
      and claim_protocol_valid
      and forbidden_hits == 0
      and unsupported_claims == 0,
    valid_tool_call_rate = calls == 0 and 0 or valid_calls / calls,
    gate_complete = run.gate_complete == true,
    protocol_used = calls >= expected.minimum_reasoning_tools,
    tool_call_count = calls,
    elapsed_ms = run.elapsed_ms,
    token_usage = vim.deepcopy(run.token_usage),
    review_changed_selection = run.review_changed_selection == true,
    recovered_after_rejection = run.recovered_after_rejection == true,
    timed_out = run.timed_out == true,
  }
end

local function successful_artifact(output, kind)
  if type(output) ~= 'table' or output.tool ~= 'reasoning_' .. kind then
    return nil
  end
  local payload = output.payload
  if type(payload) ~= 'table' or payload.code ~= nil then
    return nil
  end
  local artifact = payload.artifact
  if type(artifact) ~= 'table' or artifact.kind ~= kind then
    return nil
  end
  return artifact
end

local function normalized_selection(artifact)
  local selected = artifact and artifact.data and artifact.data.selected_option_ids
  if type(selected) ~= 'table' or #selected == 0 then
    return nil
  end
  local normalized = vim.deepcopy(selected)
  table.sort(normalized)
  return normalized
end

function M.selection_changed_after_review(outputs)
  local last_selection
  local selection_before_review
  for _, output in ipairs(outputs) do
    local synthesis = successful_artifact(output, 'synthesis')
    if synthesis then
      local selection = normalized_selection(synthesis)
      if selection then
        if selection_before_review then
          local changed = not vim.deep_equal(selection_before_review, selection)
          selection_before_review = nil
          last_selection = selection
          if changed then
            return true
          end
        else
          last_selection = selection
        end
      end
    elseif successful_artifact(output, 'review') and last_selection then
      selection_before_review = vim.deepcopy(last_selection)
    end
  end
  return false
end

return M
```

The helper deliberately compares only nonempty synthesis selections separated by an accepted review artifact. An empty checkpoint followed by a selected final answer is therefore not counted as review-driven change.

- [ ] **Step 4: Run, format, and commit the deterministic scorer**

Run: `make test_file FILE=tests/codecompanion/_extensions/reasoning/evaluation_test.lua`

Expected: PASS, 13 cases and 0 failures, without model or network access.

Run:

```bash
stylua scripts/reasoning_eval.lua tests/codecompanion/_extensions/reasoning/evaluation_test.lua -f stylua.toml
make test_file FILE=tests/codecompanion/_extensions/reasoning/evaluation_test.lua
```

```bash
git add scripts/reasoning_eval.lua tests/codecompanion/_extensions/reasoning/evaluation_test.lua
git commit -m "test(eval): add deterministic reasoning scorer"
```

### Task 3: Add the headless CodeCompanion control/treatment runner

**Files:**
- Modify: `scripts/reasoning_eval.lua`
- Modify: `tests/codecompanion/_extensions/reasoning/evaluation_test.lua`

- [ ] **Step 1: Add runner-shape tests without making a request**

Append these cases before `return T` in `tests/codecompanion/_extensions/reasoning/evaluation_test.lua`:

```lua
T['builds the same evidence prompt for control and treatment'] = function()
  local prompt = Eval.prompt_for(scenarios[2])
  eq(prompt:find(scenarios[2].prompt, 1, true) ~= nil, true)
  for _, evidence in ipairs(scenarios[2].evidence) do
    eq(prompt:find(evidence, 1, true) ~= nil, true)
  end
  for _, claim in ipairs(scenarios[2].expected.claim_labels) do
    eq(prompt:find(claim.id, 1, true) ~= nil, true)
  end
  eq(prompt:find('If structured reasoning tools are available', 1, true) ~= nil, true)
  eq(prompt:find('EVAL_CLAIMS:', 1, true) ~= nil, true)
end

T['rejects incomplete live options before creating a chat'] = function()
  MiniTest.expect.error(function()
    Eval.validate_run_options({ treatment = true, timeout_ms = 1000 })
  end, 'adapter')
  MiniTest.expect.error(function()
    Eval.validate_run_options({ adapter = 'ollama', treatment = true, timeout_ms = 1000 })
  end, 'model')
  MiniTest.expect.error(function()
    Eval.validate_run_options({ adapter = 'ollama', model = 'qwen3.6:27b', treatment = true, timeout_ms = 0 })
  end, 'timeout_ms')
end

T['fails closed unless the complete reasoning group attaches'] = function()
  MiniTest.expect.error(function()
    Eval.attach_reasoning({ tool_registry = { add = function() end } })
  end, 'attach')

  local registry = {
    groups = { reasoning = { 'frame', 'evidence', 'options', 'review', 'synthesis' } },
  }
  registry.add = function()
    return registry
  end
  eq(Eval.attach_reasoning({ tool_registry = registry }), registry)
end

T['accumulates per-request token usage'] = function()
  local total = Eval.add_token_usage({}, 100)
  total = Eval.add_token_usage(total, { total = 30, prompt = 20, completion = 10 })
  eq(total, { total = 130, prompt = 20, completion = 10 })
end

T['counts malformed output as a rejection that can be recovered'] = function()
  local metrics = Eval.recovery_metrics({
    { tool = 'reasoning_frame', payload = nil },
    { tool = 'reasoning_frame', payload = { workspace_id = 'W1', artifact = {} } },
  })
  eq(metrics.valid_calls, 1)
  eq(metrics.recovered_after_rejection, true)
end
```

Run: `make test_file FILE=tests/codecompanion/_extensions/reasoning/evaluation_test.lua`

Expected: FAIL because the prompt, option validation, attachment, token-accumulation, and recovery helpers are absent.

- [ ] **Step 2: Replace the scorer library with the complete runner**

Replace `scripts/reasoning_eval.lua` with:

```lua
local M = {}

local reasoning_tools = {
  reasoning_frame = true,
  reasoning_evidence = true,
  reasoning_options = true,
  reasoning_review = true,
  reasoning_synthesis = true,
}

local function count_terms(text, terms)
  local count = 0
  text = (text or ''):lower()
  for _, term in ipairs(terms) do
    if text:find(term:lower(), 1, true) then
      count = count + 1
    end
  end
  return count
end

local function claim_sets(expected)
  local sets = { known = {}, required = {}, forbidden = {}, unsupported = {} }
  for _, claim in ipairs(expected.claim_labels) do
    sets.known[claim.id] = true
    sets[claim.class][claim.id] = true
  end
  return sets
end

local function parse_claims(text, known)
  local encoded
  for line in (text or ''):gmatch('[^\r\n]+') do
    local candidate = line:match('^EVAL_CLAIMS:%s*(.-)%s*$')
    if candidate then
      if encoded then
        return {}, false
      end
      encoded = candidate
    end
  end
  if not encoded or encoded == '' then
    return {}, false
  end
  if encoded == 'none' then
    return {}, true
  end
  local selected = {}
  for raw in encoded:gmatch('[^,]+') do
    local id = vim.trim(raw)
    if id == '' or not known[id] or selected[id] then
      return {}, false
    end
    selected[id] = true
  end
  return selected, true
end

function M.score(scenario, run)
  local expected = scenario.expected
  local required_hits = count_terms(run.final_text, expected.required_terms)
  local grounding_hits = count_terms(run.final_text, expected.grounding_terms)
  local sets = claim_sets(expected)
  local selected, claim_protocol_valid = parse_claims(run.final_text, sets.known)
  local required_claim_hits = 0
  local forbidden_hits = 0
  local unsupported_claims = 0
  for id in pairs(sets.required) do
    required_claim_hits = required_claim_hits + (selected[id] and 1 or 0)
  end
  for id in pairs(selected) do
    forbidden_hits = forbidden_hits + (sets.forbidden[id] and 1 or 0)
    unsupported_claims = unsupported_claims + (sets.unsupported[id] and 1 or 0)
  end
  local calls = run.reasoning_tool_calls or 0
  local valid_calls = run.valid_reasoning_tool_calls or 0
  local coverage = required_hits / #expected.required_terms
  local claim_coverage = required_claim_hits / vim.tbl_count(sets.required)
  return {
    required_coverage = coverage,
    claim_coverage = claim_coverage,
    claim_protocol_valid = claim_protocol_valid,
    forbidden_hits = forbidden_hits,
    unsupported_claims = unsupported_claims,
    evidence_grounding = grounding_hits / #expected.grounding_terms,
    outcome_correct = coverage == 1
      and claim_coverage == 1
      and claim_protocol_valid
      and forbidden_hits == 0
      and unsupported_claims == 0,
    valid_tool_call_rate = calls == 0 and 0 or valid_calls / calls,
    gate_complete = run.gate_complete == true,
    protocol_used = calls >= expected.minimum_reasoning_tools,
    tool_call_count = calls,
    elapsed_ms = run.elapsed_ms,
    token_usage = vim.deepcopy(run.token_usage),
    review_changed_selection = run.review_changed_selection == true,
    recovered_after_rejection = run.recovered_after_rejection == true,
    timed_out = run.timed_out == true,
  }
end

local function successful_artifact(output, kind)
  if type(output) ~= 'table' or output.tool ~= 'reasoning_' .. kind then
    return nil
  end
  local payload = output.payload
  if type(payload) ~= 'table' or payload.code ~= nil then
    return nil
  end
  local artifact = payload.artifact
  if type(artifact) ~= 'table' or artifact.kind ~= kind then
    return nil
  end
  return artifact
end

local function normalized_selection(artifact)
  local selected = artifact and artifact.data and artifact.data.selected_option_ids
  if type(selected) ~= 'table' or #selected == 0 then
    return nil
  end
  local normalized = vim.deepcopy(selected)
  table.sort(normalized)
  return normalized
end

function M.selection_changed_after_review(outputs)
  local last_selection
  local selection_before_review
  for _, output in ipairs(outputs) do
    local synthesis = successful_artifact(output, 'synthesis')
    if synthesis then
      local selection = normalized_selection(synthesis)
      if selection then
        if selection_before_review then
          local changed = not vim.deep_equal(selection_before_review, selection)
          selection_before_review = nil
          last_selection = selection
          if changed then
            return true
          end
        else
          last_selection = selection
        end
      end
    elseif successful_artifact(output, 'review') and last_selection then
      selection_before_review = vim.deepcopy(last_selection)
    end
  end
  return false
end

function M.prompt_for(scenario)
  local lines = {
    scenario.prompt,
    '',
    'Treat only these supplied observations as evidence:',
  }
  for _, item in ipairs(scenario.evidence) do
    table.insert(lines, '- ' .. item)
  end
  table.insert(lines, '')
  table.insert(lines, 'If structured reasoning tools are available, follow their next actions, record a checkpoint before final synthesis, and continue until final gates pass. Otherwise answer directly. State the conclusion, evidence, tradeoffs, uncertainty, and next verification.')
  table.insert(lines, '')
  table.insert(lines, 'End with exactly one EVAL_CLAIMS line listing every claim your answer affirms as comma-separated IDs, or none. Do not list a claim merely because you discuss or deny it:')
  for _, claim in ipairs(scenario.expected.claim_labels) do
    table.insert(lines, '- ' .. claim.id .. ': ' .. claim.description)
  end
  table.insert(lines, 'Format: EVAL_CLAIMS: claim_id,other_claim_id')
  return table.concat(lines, '\n')
end

function M.validate_run_options(opts)
  assert(type(opts) == 'table', 'run options must be a table')
  assert(type(opts.adapter) == 'string' and opts.adapter ~= '', 'adapter is required')
  assert(type(opts.model) == 'string' and opts.model ~= '', 'model is required')
  assert(type(opts.treatment) == 'boolean', 'treatment must be a boolean')
  assert(type(opts.timeout_ms) == 'number' and opts.timeout_ms > 0, 'timeout_ms must be positive')
end

function M.attach_reasoning(chat)
  local added = chat.tool_registry:add('reasoning')
  assert(added ~= nil, 'failed to attach the reasoning group')
  local group = added.groups and added.groups.reasoning
  assert(type(group) == 'table' and #group == 5, 'failed to attach all five reasoning tools')
  return added
end

function M.add_token_usage(total, usage)
  total = vim.deepcopy(total or {})
  if type(usage) == 'number' then
    total.total = (total.total or 0) + usage
  elseif type(usage) == 'table' then
    for name, value in pairs(usage) do
      if type(value) == 'number' then
        total[name] = (total[name] or 0) + value
      end
    end
  end
  return total
end

function M.recovery_metrics(outputs)
  local valid_calls = 0
  local saw_rejection = false
  local recovered_after_rejection = false
  for _, output in ipairs(outputs) do
    if reasoning_tools[output.tool] then
      local payload = output.payload
      local accepted = type(payload) == 'table'
        and payload.code == nil
        and type(payload.workspace_id) == 'string'
      if accepted then
        valid_calls = valid_calls + 1
        recovered_after_rejection = recovered_after_rejection or saw_rejection
      else
        saw_rejection = true
      end
    end
  end
  return {
    valid_calls = valid_calls,
    recovered_after_rejection = recovered_after_rejection,
  }
end

local function decode_payload(value)
  if type(value) ~= 'string' then
    return nil
  end
  local ok, decoded = pcall(vim.json.decode, value)
  return ok and decoded or nil
end

local function final_assistant_text(messages)
  local llm_role = require('codecompanion.config').constants.LLM_ROLE
  for index = #messages, 1, -1 do
    local message = messages[index]
    if message.role == llm_role and type(message.content) == 'string' and vim.trim(message.content) ~= '' then
      return message.content
    end
  end
  return ''
end

local function tool_names(messages)
  local names = {}
  for _, message in ipairs(messages) do
    for _, call in ipairs(message.tools and message.tools.calls or {}) do
      local name = call['function'] and call['function'].name
      if name then
        table.insert(names, name)
      end
    end
  end
  return names
end

local function summarize_artifact(tool_name, payload)
  local artifact = payload and payload.artifact
  if not artifact then
    return nil
  end
  local data = artifact.data or {}
  return {
    tool = tool_name,
    id = artifact.id,
    kind = artifact.kind,
    summary = data.conclusion or data.statement or data.summary or data.objective or data.question,
    selected_option_ids = vim.deepcopy(data.selected_option_ids),
    unmet_gates = vim.deepcopy(payload.unmet_gates or {}),
  }
end

function M.run_scenario(scenario, opts)
  M.validate_run_options(opts)
  local CodeCompanion = require('codecompanion')
  local finished = false
  local cancelled = false
  local observed_outputs = {}
  local token_usage = {}
  local function capture_tokens(active_chat)
    token_usage = M.add_token_usage(token_usage, active_chat.tokens)
    active_chat.tokens = nil
  end
  local started = vim.uv.hrtime()
  local chat = CodeCompanion.chat({
    params = { adapter = opts.adapter, model = opts.model },
    user_prompt = M.prompt_for(scenario),
    auto_submit = false,
    hidden = true,
    yolo_mode = true,
    callbacks = {
      on_submitted = function(active_chat)
        capture_tokens(active_chat)
      end,
      on_completed = function(active_chat)
        capture_tokens(active_chat)
        finished = true
      end,
      on_cancelled = function(active_chat)
        capture_tokens(active_chat)
        cancelled = true
        finished = true
      end,
      on_tool_output = function(_, args)
        table.insert(observed_outputs, {
          tool = args.tool,
          payload = decode_payload(args.for_llm),
        })
      end,
    },
  })
  assert(chat, 'CodeCompanion could not create the evaluation chat')
  assert(chat.adapter.type == 'http', 'the evaluation runner requires an HTTP adapter')
  if opts.treatment then
    M.attach_reasoning(chat)
  end
  chat:submit()

  local completed = vim.wait(opts.timeout_ms, function()
    return finished
  end, 20)
  local timed_out = not completed
  if timed_out then
    chat:stop()
    vim.wait(1000, function()
      return chat.current_request == nil
    end, 20)
    capture_tokens(chat)
  end

  local names = tool_names(chat.messages)
  local reasoning_call_count = 0
  for _, name in ipairs(names) do
    if reasoning_tools[name] then
      reasoning_call_count = reasoning_call_count + 1
    end
  end

  local gate_complete = false
  local artifacts = {}
  for _, output in ipairs(observed_outputs) do
    local summary = summarize_artifact(output.tool, output.payload)
    if summary then
      table.insert(artifacts, summary)
      if output.tool == 'reasoning_synthesis' then
        local data = output.payload.artifact.data
        gate_complete = gate_complete or (data.mode == 'final' and #summary.unmet_gates == 0)
      end
    end
  end
  local recovery = M.recovery_metrics(observed_outputs)

  local result = {
    scenario_id = scenario.id,
    treatment = opts.treatment,
    final_text = final_assistant_text(chat.messages),
    tool_names = names,
    reasoning_tool_calls = reasoning_call_count,
    valid_reasoning_tool_calls = recovery.valid_calls,
    gate_complete = gate_complete,
    artifact_summaries = artifacts,
    review_changed_selection = M.selection_changed_after_review(observed_outputs),
    recovered_after_rejection = recovery.recovered_after_rejection,
    elapsed_ms = math.floor((vim.uv.hrtime() - started) / 1000000),
    token_usage = vim.deepcopy(token_usage),
    timed_out = timed_out,
    cancelled = cancelled,
  }
  chat:close()
  result.score = M.score(scenario, result)
  return result
end

local function required_env(name)
  local value = os.getenv(name)
  if not value or value == '' then
    error(name .. ' is required for live reasoning evaluation')
  end
  return value
end

function M.main()
  local adapter = required_env('REASONING_EVAL_ADAPTER')
  local model = required_env('REASONING_EVAL_MODEL')
  local timeout_ms = tonumber(os.getenv('REASONING_EVAL_TIMEOUT_MS') or '180000')
  assert(timeout_ms and timeout_ms > 0, 'REASONING_EVAL_TIMEOUT_MS must be a positive number')

  require('codecompanion').setup({
    interactions = {
      chat = {
        tools = {
          opts = {
            auto_submit_errors = true,
            auto_submit_success = true,
            default_tools = {},
          },
        },
      },
    },
    extensions = {
      reasoning = { enabled = true, opts = { auto_attach = false } },
    },
  })
  local scenarios = {
    require('fixtures.evaluation.architecture'),
    require('fixtures.evaluation.diagnosis'),
    require('fixtures.evaluation.temporal_design'),
    require('fixtures.evaluation.contradictory_claim'),
  }
  local report = {
    adapter = adapter,
    model = model,
    timeout_ms = timeout_ms,
    comparisons = {},
  }
  for _, scenario in ipairs(scenarios) do
    local control = M.run_scenario(scenario, {
      adapter = adapter,
      model = model,
      timeout_ms = timeout_ms,
      treatment = false,
    })
    local treatment = M.run_scenario(scenario, {
      adapter = adapter,
      model = model,
      timeout_ms = timeout_ms,
      treatment = true,
    })
    table.insert(report.comparisons, {
      scenario_id = scenario.id,
      control = control,
      treatment = treatment,
    })
  end

  local encoded = vim.json.encode(report)
  local output = os.getenv('REASONING_EVAL_OUTPUT')
  if output and output ~= '' then
    local ok, error_message = pcall(vim.fn.writefile, { encoded }, output)
    assert(ok, 'failed to write REASONING_EVAL_OUTPUT: ' .. tostring(error_message))
  else
    io.stdout:write(encoded .. '\n')
  end
  return report
end

if not vim.g.reasoning_eval_library then
  M.main()
end

return M
```

This uses the audited CodeCompanion v19.22.0 HTTP flow: `CodeCompanion.chat`, `chat.tool_registry:add`, `chat:submit`, `on_submitted`, `on_tool_output`, `on_completed`, and `chat:close`. Control and treatment receive identical prompts and adapter/model settings. Only treatment attaches the reasoning group, and attachment fails closed unless all five tools are present. Per-request token reports are captured before CodeCompanion overwrites them, malformed reasoning output counts as a rejected call, and a later accepted output records recovery. `yolo_mode` prevents an interactive approval prompt, while the reasoning group contains only local deterministic commands.

- [ ] **Step 3: Run the offline runner-shape tests**

Run: `make test_file FILE=tests/codecompanion/_extensions/reasoning/evaluation_test.lua`

Expected: PASS, 18 cases and 0 failures. No chat is created by these tests and no model or network access occurs.

- [ ] **Step 4: Format, rerun, and commit the runner**

Run:

```bash
stylua scripts/reasoning_eval.lua tests/codecompanion/_extensions/reasoning/evaluation_test.lua -f stylua.toml
make test_file FILE=tests/codecompanion/_extensions/reasoning/evaluation_test.lua
```

```bash
git add scripts/reasoning_eval.lua tests/codecompanion/_extensions/reasoning/evaluation_test.lua
git commit -m "test(eval): add CodeCompanion comparison runner"
```

### Task 4: Include the harness in formatting and document opt-in use

**Files:**
- Modify: `Makefile`
- Modify: `README.md`

- [ ] **Step 1: Make the repository formatter cover scripts**

Change the `format` target in `Makefile` from:

```make
format:
	@echo Formatting...
	@stylua tests/ lua/ -f ./stylua.toml
```

to:

```make
format:
	@echo Formatting...
	@stylua tests/ lua/ scripts/reasoning_eval.lua -f ./stylua.toml
```

- [ ] **Step 2: Add the complete Evaluation section to README**

Append this section after `## Breaking migration` and its explanatory text:

````markdown
## Evaluation

The repository includes a fixed four-scenario control/treatment harness for checking a named model through a CodeCompanion HTTP adapter. Control and treatment receive the same prompt, evidence, adapter, model, and machine-readable claim-label contract; only treatment gets `@{reasoning}`. Scoring is deterministic and literal—there is no judge model, and denied claims are not counted merely because their words appear.

The Markdown Tree-sitter parser is mandatory. Verify it in the same headless environment before starting the eight conversations:

```bash
nvim --headless --noplugin -i NONE -u ./scripts/minimal_init.lua \
  +'lua local b=vim.api.nvim_create_buf(false,true); local ok,p=pcall(vim.treesitter.get_parser,b,"markdown"); assert(ok and p,"Markdown Tree-sitter parser is required")' \
  +qa
```

```bash
REASONING_EVAL_ADAPTER=ollama \
REASONING_EVAL_MODEL=qwen3.6:27b \
REASONING_EVAL_TIMEOUT_MS=180000 \
REASONING_EVAL_OUTPUT=/tmp/codecompanion-reasoning-eval.json \
nvim --headless --noplugin -i NONE -u ./scripts/minimal_init.lua -l ./scripts/reasoning_eval.lua
```

The command performs eight external model conversations, can take several minutes, and never runs in CI. It requires an already configured CodeCompanion HTTP adapter and reachable named model. Results apply only to that model, adapter configuration, fixed corpus, and claim-label contract; they do not prove universal benefit, factual correctness, or genuine independent reasoning.
````

- [ ] **Step 3: Verify formatting coverage and documentation**

Run:

```bash
make format
rg -n "scripts/reasoning_eval.lua" Makefile
rg -n "Markdown Tree-sitter parser|eight external model conversations|REASONING_EVAL_TIMEOUT_MS=180000|never runs in CI" README.md
```

Expected: StyLua completes, the Makefile includes `scripts/reasoning_eval.lua`, and all four safety/usage details appear in README.

- [ ] **Step 4: Run deterministic tests and commit documentation integration**

Run: `make test`

Expected: PASS with 0 failures and no model or network access.

```bash
git add Makefile README.md scripts/reasoning_eval.lua tests/codecompanion/_extensions/reasoning/evaluation_test.lua tests/fixtures/evaluation
git commit -m "docs(eval): document opt-in comparison"
```

### Task 5: Verify deterministically, then optionally run the named model

**Files:**
- Modify only files changed by formatting or defects found by verification.

- [ ] **Step 1: Re-run the scorer and selection regressions in a clean process**

Run: `make test_file FILE=tests/codecompanion/_extensions/reasoning/evaluation_test.lua`

Expected: PASS, 18 cases and 0 failures. Specifically, claim-label parsing fails closed, negated claims are not penalized, malformed output followed by an accepted call counts as recovery, per-request tokens accumulate, the empty-checkpoint regression is false, rejected reviews do not count, option order is ignored, and the `O1 -> review -> O2` regression is true.

- [ ] **Step 2: Format and run the complete deterministic suite**

Run:

```bash
make format
git diff --exit-code
git diff --check
make test
```

Expected: formatting is idempotent, no whitespace errors exist, and every test passes without a model request.

- [ ] **Step 3: Audit the harness boundary and repository state**

Run:

```bash
rg -n "reasoning_eval|fixtures/evaluation" Makefile README.md scripts tests
! rg -n "reasoning_eval" lua/codecompanion/_extensions/reasoning
git status --short
git log --oneline --decorate -5
```

Expected: evaluation code is confined to the script, tests, fixtures, Makefile, and README; runtime modules do not depend on it; the worktree is clean; and the focused evaluation commits are visible.

- [ ] **Step 4: Run the optional live comparison only when the endpoint is deliberately available**

This is the only network/model step. Confirm the local adapter and exact model first, then run:

```bash
nvim --headless --noplugin -i NONE -u ./scripts/minimal_init.lua \
  +'lua local b=vim.api.nvim_create_buf(false,true); local ok,p=pcall(vim.treesitter.get_parser,b,"markdown"); assert(ok and p,"Markdown Tree-sitter parser is required")' \
  +qa
REASONING_EVAL_ADAPTER=ollama \
REASONING_EVAL_MODEL=qwen3.6:27b \
REASONING_EVAL_TIMEOUT_MS=180000 \
REASONING_EVAL_OUTPUT=/tmp/codecompanion-reasoning-eval.json \
nvim --headless --noplugin -i NONE -u ./scripts/minimal_init.lua \
  -l ./scripts/reasoning_eval.lua
nvim --headless --clean -i NONE \
  +'lua local p="/tmp/codecompanion-reasoning-eval.json"; local r=vim.json.decode(table.concat(vim.fn.readfile(p), "\n")); assert(#r.comparisons == 4)' \
  +qa
```

Expected: the parser preflight succeeds, the evaluation Neovim process exits successfully after eight conversations, and the final process verifies exactly four control/treatment comparisons in the retained JSON report.

If the adapter, credentials, endpoint, or named model is unavailable, skip this step. Report only the deterministic harness verification; do not claim that the tools improved model quality. If the live command succeeds, report control and treatment metrics per scenario, including negative or mixed results, without generalizing beyond this corpus.
