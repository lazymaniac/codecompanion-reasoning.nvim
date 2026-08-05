# Fail-Closed Structured Reasoning Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make attaching the complete reasoning tool set commit an HTTP chat to an inspectable, fail-closed reasoning protocol while preserving unrestricted external investigation and emitting only a deterministic accepted final answer.

**Architecture:** Add revisioned state transactions, one pure transition authority, a deterministic renderer, and a per-chat lifecycle controller. The controller wraps the pinned CodeCompanion v19.22.0 chat boundary before the first reasoning-enabled request, binds HTTP callbacks to an epoch/generation request token, suppresses free-form completion output, classifies reasoning calls by request generation and call ID, bounds corrective retries, and commits a staged final only after its host tool result is recorded.

**Tech Stack:** Lua 5.1/LuaJIT, Neovim APIs, CodeCompanion.nvim v19.22.0 HTTP chat/tool APIs, MiniTest, StyLua.

---

## Execution prerequisite

Execute this plan from a clean sibling worktree created from the commit that
contains this plan. Use branch `feat/fail-closed-reasoning` and sibling path
`/Users/sebastian/workspace/codecompanion-reasoning-fail-closed`; leave `main`
available for review. Before Task 1, verify the pinned host and baseline:

```bash
git status --short
git -C deps/codecompanion.nvim describe --tags --exact-match
NVIM_LOG_FILE=/tmp/codecompanion-reasoning-baseline.log make test
```

Expected: clean status, host tag `v19.22.0`, and 161 baseline cases with zero
failures and notes.

## File structure

Create these focused runtime modules:

- `lua/codecompanion/_extensions/reasoning/constants.lua` — canonical reasoning
  tool names, sets, operation mappings, tags, event group, and resume command.
- `lua/codecompanion/_extensions/reasoning/transition.lua` — pure lifecycle and
  workspace transition calculation shared by controller and protocol dispatch.
- `lua/codecompanion/_extensions/reasoning/validation.lua` — deterministic,
  safe diagnostics for schema-shaped and semantic validation failures.
- `lua/codecompanion/_extensions/reasoning/schema.lua` — resolve fresh,
  configuration-aware JSON schemas for every chat attachment.
- `lua/codecompanion/_extensions/reasoning/render.lua` — pure citation-closed
  final Markdown rendering with escaped model-provided text.
- `lua/codecompanion/_extensions/reasoning/control.lua` — weak-key controller
  state, host method wrappers, retry leases, lifecycle reconciliation, explicit
  resume, finalization, clear, and close behavior.

Modify these runtime modules:

- `lua/codecompanion/_extensions/reasoning/state.lua` — workspace revisions,
  chat clear, and prepare/commit/discard final transactions.
- `lua/codecompanion/_extensions/reasoning/protocol.lua` — authoritative
  transition checks, precise diagnostics, downstream retirement on reframe,
  and staged final synthesis.
- `lua/codecompanion/_extensions/reasoning/output.lua` — strip internal staged
  data, bind it to the controller, and retain the legacy terminal guard only
  for partial-tool chats whose fail-closed controller is absent or dormant.
- `lua/codecompanion/_extensions/reasoning/init.lua` — dynamic tool resolution,
  stronger group prompt, and idempotent host lifecycle autocmds.
- `lua/codecompanion/_extensions/reasoning/tools/*.lua` — consume resolved schema
  bounds without changing the public five-tool command contract.

Retain this compatibility module unchanged:

- `lua/codecompanion/_extensions/reasoning/terminal.lua` — keep its one-shot
  compatibility guard isolated to partial-tool chats; an enforcing complete
  chat never installs this second submit wrapper.

Modify or verify this documentation:

- `README.md` and the original design spec — document enforced transitions,
  request-token isolation, external investigation, diagnostics, deterministic
  output, explicit resume, HTTP scope, partial-tool compatibility, and the ACP
  limitation. Verify the implementation remains aligned with the already
  approved 2026-08-05 design without rewriting that contract during execution.

Create these tests:

- `tests/codecompanion/_extensions/reasoning/transition_test.lua`.
- `tests/codecompanion/_extensions/reasoning/validation_test.lua`.
- `tests/codecompanion/_extensions/reasoning/schema_test.lua`.
- `tests/codecompanion/_extensions/reasoning/render_test.lua`.
- `tests/codecompanion/_extensions/reasoning/control_test.lua`.

Extend the existing state, tool, output, init, and runtime integration tests.

## Shared contracts

- Controller phases are `dormant`, `armed`, `active`, `reframing`,
  `finalizing`, `halted`, and `finalized`.
- `blocked` is an effective transition sentinel returned by `Control.phase`
  for a complete-but-uncontrolled, unsupported, closed, or incomplete sticky
  chat; it is never stored as controller state and permits no protocol mutation.
- `Protocol.transition(workspace, phase)` is the only expected-tool authority.
  `control.lua` never caches an independently computed next action.
- External-only calls and external-tool failures never increment, reset, or
  advance the reasoning protocol budget.
- A completion containing a reasoning call contains exactly that one tool.
- Every expected rejection contains `committed = false`, a stable code,
  artifact IDs, a state-aware `next_action`, and a safe diagnostic when a
  specific field or reference caused the error.
- Model-correctable violations one and two create one replaceable hidden
  correction and one generation-bound fallback lease. Violation three halts.
- Every HTTP callback capable of mutating chat state is bound to the request's
  controller epoch and generation; request-handle status is cancellation data,
  never completion authority.
- `internal_error` and `render_internal` halt immediately without spending the
  model-correctable budget.
- Final Markdown is staged internally, never serialized to the model, and the
  final synthesis artifact remains uncommitted until the matching host tool
  result has been recorded.
- All focused test commands use `make test_file FILE=<path>`. Run `make format`
  before each commit and the full `make test` at integration checkpoints.

### Task 1: Add canonical constants and revisioned state transactions

**Files:**
- Create: `lua/codecompanion/_extensions/reasoning/constants.lua`
- Modify: `lua/codecompanion/_extensions/reasoning/state.lua`
- Modify: `lua/codecompanion/_extensions/reasoning/protocol.lua`
- Modify: `tests/codecompanion/_extensions/reasoning/state_test.lua`

- [ ] **Step 1: Write failing revision, clear, and final-stage tests**

Append these cases before `return T` in `state_test.lua`:

```lua
T['tracks one revision for every externally visible mutation'] = function()
  local workspace = State.begin({})
  eq(workspace.revision, 0)
  local frame = State.add(workspace, 'frame', {})
  eq(workspace.revision, 1)
  State.set_frame(workspace, frame.id)
  eq(workspace.revision, 2)
  local evidence = State.add(workspace, 'evidence', {})
  eq(workspace.revision, 3)
  State.add_relation(workspace, evidence, 'depends_on', frame.id)
  eq(workspace.revision, 4)
  State.retract(workspace, evidence.id)
  eq(workspace.revision, 5)
  State.retire(workspace, frame.id)
  eq(workspace.revision, 6)
end

T['prepares and commits one revision-bound final'] = function()
  local chat = {}
  local workspace = State.begin(chat)
  local frame = State.add(workspace, 'frame', {})
  State.set_frame(workspace, frame.id)
  local before_revision = workspace.revision
  local stage = State.prepare_final(chat, { mode = 'final', frame_id = frame.id }, {
    depends_on = { frame.id },
  })

  eq(stage.reserved_id, 'S1')
  eq(stage.candidate.id, 'S1')
  eq(workspace.revision, before_revision)
  eq(workspace.next_sequence.synthesis, nil)
  eq(State.find(workspace, 'S1'), nil)

  local committed = State.commit_final(chat, stage)
  eq(committed.id, 'S1')
  eq(State.find(workspace, 'S1'), committed)
  eq(workspace.revision, before_revision + 1)

  local duplicate, code = State.commit_final(chat, stage)
  eq(duplicate, nil)
  eq(code, 'transaction_closed')
end

T['discards or rejects stale finals without consuming an ID'] = function()
  local chat = {}
  local workspace = State.begin(chat)
  local discarded = State.prepare_final(chat, { mode = 'final' }, {})
  eq(State.discard_final(discarded), true)
  eq(workspace.next_sequence.synthesis, nil)

  local stage = State.prepare_final(chat, { mode = 'final' }, {})
  State.add(workspace, 'evidence', {})
  local committed, code = State.commit_final(chat, stage)
  eq(committed, nil)
  eq(code, 'transaction_conflict')
  eq(State.find(workspace, 'S1'), nil)
end

T['rolls back the exact just-committed final after an emission failure'] = function()
  local chat = {}
  local workspace = State.begin(chat)
  local checkpoint = State.add(workspace, 'synthesis', { mode = 'checkpoint' })
  local stage = State.prepare_final(chat, { mode = 'final' }, { supersedes = { checkpoint.id } })
  local before = workspace.revision
  eq(State.commit_final(chat, stage).id, 'S2')

  eq(State.rollback_final(chat, stage), true)
  eq(stage.state, 'rolled_back')
  eq(workspace.revision, before)
  eq(workspace.next_sequence.synthesis, 1)
  eq(workspace.counts_by_kind.synthesis, 1)
  eq(State.find(workspace, 'S2'), nil)
  eq(State.find(workspace, checkpoint.id).status, 'active')
end

T['clears only the requested chat workspace'] = function()
  local first, second = {}, {}
  State.begin(first)
  State.begin(second)
  State.clear(first)
  eq(State.get(first), nil)
  eq(State.get(second).id, 'W1')
  eq(State.begin(first).id, 'W1')
end
```

- [ ] **Step 2: Run the state tests and verify RED**

Run:

```bash
make test_file FILE=tests/codecompanion/_extensions/reasoning/state_test.lua
```

Expected: FAIL because workspaces have no revision and the final transaction
and chat-clear APIs do not exist.

- [ ] **Step 3: Add the shared constants module**

Create `constants.lua` with:

```lua
local M = {}

M.tool_names = {
  'reasoning_frame',
  'reasoning_evidence',
  'reasoning_options',
  'reasoning_review',
  'reasoning_synthesis',
}

M.tool_set = {}
for _, name in ipairs(M.tool_names) do
  M.tool_set[name] = true
end

M.operation_by_tool = {
  reasoning_frame = 'frame',
  reasoning_evidence = 'evidence',
  reasoning_options = 'options',
  reasoning_review = 'review',
  reasoning_synthesis = 'synthesis',
}

M.tool_by_operation = {}
for tool, operation in pairs(M.operation_by_tool) do
  M.tool_by_operation[operation] = tool
end

M.augroup = 'codecompanion.reasoning.control'
M.corrective_tag = 'reasoning_protocol_correction'
M.resume_command = 'CodeCompanionReasoningResume'

return M
```

- [ ] **Step 4: Implement revisioned state and two-phase final allocation**

In `state.lua`, add `revision = 0` to `new_workspace`, extract artifact creation
and insertion, and add these APIs. Replace `M.add` and each mutator with the
shown implementations so every artifact, relation, and status mutation touches
the revision exactly once.

```lua
local function touch(workspace)
  workspace.revision = workspace.revision + 1
end

local function artifact_value(kind, id, data, relations)
  return {
    id = id,
    kind = kind,
    status = 'active',
    data = vim.deepcopy(data),
    relations = vim.tbl_deep_extend('force', {
      supports = {},
      contradicts = {},
      qualifies = {},
      depends_on = {},
      tests = {},
      supersedes = {},
    }, vim.deepcopy(relations or {})),
  }
end

local function insert_artifact(workspace, artifact, sequence)
  workspace.next_sequence[artifact.kind] = sequence
  workspace.artifacts_by_id[artifact.id] = artifact
  table.insert(workspace.artifact_order, artifact.id)
  workspace.counts_by_kind[artifact.kind] = (workspace.counts_by_kind[artifact.kind] or 0) + 1
  touch(workspace)
  return artifact
end

function M.add(workspace, kind, data)
  local prefix = prefixes[kind]
  assert(prefix, 'unknown artifact kind: ' .. tostring(kind))
  if #workspace.artifact_order >= Config.get().limits.max_artifacts then
    return nil, 'limit_exceeded'
  end
  local sequence = (workspace.next_sequence[kind] or 0) + 1
  return insert_artifact(workspace, artifact_value(kind, prefix .. sequence, data), sequence)
end

function M.add_relation(workspace, artifact, relation, target_id)
  assert(artifact.relations[relation], 'unknown relation: ' .. tostring(relation))
  table.insert(artifact.relations[relation], target_id)
  touch(workspace)
end

function M.supersede(workspace, old_id, replacement_id)
  local old = M.find(workspace, old_id)
  local replacement = M.find(workspace, replacement_id)
  assert(old and replacement, 'supersession artifacts must exist')
  old.status = 'superseded'
  table.insert(replacement.relations.supersedes, old_id)
  resolve_revision(workspace, old_id, 'superseded', replacement_id)
  touch(workspace)
end

function M.retract(workspace, id)
  local artifact = M.find(workspace, id)
  assert(artifact, 'retracted artifact must exist')
  artifact.status = 'retracted'
  resolve_revision(workspace, id, 'retracted')
  touch(workspace)
end

function M.retire(workspace, id)
  local artifact = M.find(workspace, id)
  assert(artifact, 'retired artifact must exist')
  artifact.status = 'superseded'
  resolve_revision(workspace, id, 'retired')
  touch(workspace)
end

function M.set_frame(workspace, frame_id)
  workspace.frame_id = frame_id
  touch(workspace)
end

function M.append_data(workspace, artifact, field, value)
  assert(type(artifact.data[field]) == 'table', 'artifact data field must be an array')
  table.insert(artifact.data[field], value)
  touch(workspace)
end

function M.open_revision(workspace, target_id, review_id)
  workspace.open_revisions[target_id] = review_id
  touch(workspace)
end

function M.resolve_contradiction(workspace, key, review_id)
  workspace.resolved_contradictions[key] = review_id
  touch(workspace)
end

function M.prepare_final(chat, data, relations)
  local workspace = M.get(chat)
  if not workspace then
    return nil, 'workspace_missing'
  end
  if #workspace.artifact_order >= Config.get().limits.max_artifacts then
    return nil, 'limit_exceeded'
  end
  local sequence = (workspace.next_sequence.synthesis or 0) + 1
  return {
    workspace = workspace,
    workspace_id = workspace.id,
    revision = workspace.revision,
    reserved_id = 'S' .. sequence,
    candidate = artifact_value('synthesis', 'S' .. sequence, data, relations),
    state = 'prepared',
  }
end

function M.commit_final(chat, stage)
  if type(stage) ~= 'table' or stage.state ~= 'prepared' then
    return nil, 'transaction_closed'
  end
  local workspace = M.get(chat)
  if
    not workspace
    or workspace ~= stage.workspace
    or workspace.id ~= stage.workspace_id
    or workspace.revision ~= stage.revision
    or type(stage.candidate) ~= 'table'
    or stage.candidate.kind ~= 'synthesis'
    or stage.candidate.status ~= 'active'
    or stage.candidate.id ~= stage.reserved_id
    or stage.reserved_id ~= 'S' .. ((workspace.next_sequence.synthesis or 0) + 1)
    or workspace.artifacts_by_id[stage.reserved_id]
  then
    stage.state = 'conflicted'
    return nil, 'transaction_conflict'
  end
  if #workspace.artifact_order >= Config.get().limits.max_artifacts then
    stage.state = 'conflicted'
    return nil, 'limit_exceeded'
  end
  for _, id in ipairs(stage.candidate.relations.supersedes) do
    local artifact = M.find(workspace, id)
    if not artifact or artifact.status ~= 'active' or artifact.kind ~= 'synthesis' then
      stage.state = 'conflicted'
      return nil, 'transaction_conflict'
    end
  end

  stage.rollback = {
    next_sequence = workspace.next_sequence.synthesis,
    count = workspace.counts_by_kind.synthesis,
    open_revisions = vim.deepcopy(workspace.open_revisions),
    resolved_revisions = vim.deepcopy(workspace.resolved_revisions),
    statuses = {},
  }
  for _, id in ipairs(stage.candidate.relations.supersedes) do
    stage.rollback.statuses[id] = M.find(workspace, id).status
  end

  local committed = insert_artifact(
    workspace,
    vim.deepcopy(stage.candidate),
    (workspace.next_sequence.synthesis or 0) + 1
  )
  for _, id in ipairs(stage.candidate.relations.supersedes) do
    local old = M.find(workspace, id)
    old.status = 'superseded'
    resolve_revision(workspace, id, 'superseded', committed.id)
  end
  stage.state = 'committed'
  stage.committed_artifact = committed
  return committed
end

function M.rollback_final(chat, stage)
  local workspace = M.get(chat)
  if
    type(stage) ~= 'table'
    or stage.state ~= 'committed'
    or workspace ~= stage.workspace
    or workspace.revision ~= stage.revision + 1
    or workspace.artifact_order[#workspace.artifact_order] ~= stage.reserved_id
    or workspace.artifacts_by_id[stage.reserved_id] ~= stage.committed_artifact
  then
    return false
  end
  table.remove(workspace.artifact_order)
  workspace.artifacts_by_id[stage.reserved_id] = nil
  workspace.next_sequence.synthesis = stage.rollback.next_sequence
  workspace.counts_by_kind.synthesis = stage.rollback.count
  workspace.open_revisions = stage.rollback.open_revisions
  workspace.resolved_revisions = stage.rollback.resolved_revisions
  for id, status in pairs(stage.rollback.statuses) do
    M.find(workspace, id).status = status
  end
  workspace.revision = stage.revision
  stage.committed_artifact = nil
  stage.state = 'rolled_back'
  return true
end

function M.discard_final(stage)
  if type(stage) ~= 'table' or stage.state ~= 'prepared' then
    return false
  end
  stage.state = 'discarded'
  return true
end

function M.clear(chat)
  workspaces_by_chat[chat] = nil
end
```

Keep `commit_final` atomic by validating every superseded ID before calling
`insert_artifact`; do not call the public `M.supersede` inside the transaction.
`rollback_final` is a narrow compensating transaction used only if assistant
history or buffer emission throws after commit; its exact revision and last-ID
guards prevent rolling back unrelated state.
Mechanically update every `State.add_relation(artifact, relation, id)` call in
`protocol.lua` to `State.add_relation(workspace, artifact, relation, id)`. Do
the same for direct mutations: use `State.set_frame`, `State.append_data`,
`State.open_revision`, and `State.resolve_contradiction`. Do not touch revisions
for internal `resolve_revision` bookkeeping separately; its public status
mutation already does so.

- [ ] **Step 5: Run, format, and re-run the state tests**

Run:

```bash
make test_file FILE=tests/codecompanion/_extensions/reasoning/state_test.lua
make format
make test_file FILE=tests/codecompanion/_extensions/reasoning/state_test.lua
make test
```

Expected: all state cases and the complete suite pass with zero failures and
notes; the relation-signature migration leaves no stale caller.

- [ ] **Step 6: Commit the state boundary**

```bash
git add lua/codecompanion/_extensions/reasoning/constants.lua lua/codecompanion/_extensions/reasoning/state.lua lua/codecompanion/_extensions/reasoning/protocol.lua tests/codecompanion/_extensions/reasoning/state_test.lua
git commit -m "feat(reasoning): add state transactions"
```

### Task 2: Add one transition authority and atomic reframe retirement

**Files:**
- Create: `lua/codecompanion/_extensions/reasoning/transition.lua`
- Create: `tests/codecompanion/_extensions/reasoning/transition_test.lua`
- Modify: `lua/codecompanion/_extensions/reasoning/protocol.lua`
- Modify: `tests/codecompanion/_extensions/reasoning/tools/frame_test.lua`

- [ ] **Step 1: Write failing transition tests**

Create `transition_test.lua`:

```lua
local Config = require('codecompanion._extensions.reasoning.config')
local Protocol = require('codecompanion._extensions.reasoning.protocol')
local State = require('codecompanion._extensions.reasoning.state')
local Transition = require('codecompanion._extensions.reasoning.transition')

local T = MiniTest.new_set({
  hooks = {
    pre_case = function()
      Config.setup()
      State._reset()
    end,
  },
})
local eq = MiniTest.expect.equality

local function frame_args(action)
  return {
    action = action or 'start',
    objective = 'Explain the failure',
    problem_type = 'analysis',
    depth = 'standard',
    constraints = {},
    success_criteria = { 'Cite active evidence' },
    unknowns = {},
    perspectives = { { name = 'correctness', purpose = 'Check the explanation' } },
    temporal_required = false,
    branching_required = false,
    branching_rationale = 'One claim is under analysis',
  }
end

T['defines lifecycle transitions without mutating workspace'] = function()
  eq(Transition.next(nil, 'dormant'), nil)
  eq(Transition.next(nil, 'blocked').tool, 'none')
  eq(Transition.next(nil, 'armed').tool, 'reasoning_frame')
  eq(Transition.next(nil, 'reframing').tool, 'reasoning_frame')
  eq(Transition.next(nil, 'finalizing').tool, 'none')
  eq(Transition.next(nil, 'halted').tool, 'none')
  eq(Transition.next(nil, 'finalized').tool, 'none')
end

T['blocks every protocol mutation through the effective unavailable sentinel'] = function()
  local chat = {}
  local rejected = Protocol.call('frame', chat, frame_args(), 'blocked')
  eq(rejected.status, 'error')
  eq(rejected.data.code, 'transition_invalid')
  eq(rejected.data.next_action.tool, 'none')
  eq(State.get(chat), nil)
end

T['rejects an out-of-order reasoning operation before mutation'] = function()
  local chat = {}
  local started = Protocol.call('frame', chat, frame_args(), 'armed')
  eq(started.status, 'success')
  local before = vim.deepcopy(State.get(chat))

  local rejected = Protocol.call('synthesis', chat, {
    mode = 'checkpoint',
    conclusion = 'Too early',
    selected_option_ids = {},
    support_ids = {},
    review_ids = {},
    criterion_results = {},
    tradeoffs = {},
    uncertainties = {},
    blind_spots = {},
    next_actions = {},
    confidence = 'low',
  }, 'active')

  eq(rejected.status, 'error')
  eq(rejected.data.code, 'transition_invalid')
  eq(rejected.data.committed, false)
  eq(rejected.data.next_action.tool, 'reasoning_evidence')
  eq(State.get(chat), before)
end

T['rejects options and review while evidence is authoritative'] = function()
  for _, operation in ipairs({ 'options', 'review' }) do
    local chat = {}
    Protocol.call('frame', chat, frame_args(), 'armed')
    local workspace = State.get(chat)
    local before = vim.deepcopy(workspace)
    local rejected = Protocol.call(operation, chat, {}, 'active')
    eq(rejected.data.code, 'transition_invalid')
    eq(rejected.data.next_action.tool, 'reasoning_evidence')
    eq(workspace, before)
  end
end

T['keeps external callers unpoliced when no controller phase is supplied'] = function()
  local chat = {}
  local result = Protocol.call('frame', chat, frame_args(), nil)
  eq(result.status, 'success')
end

T['permits only explicit revise or replace while reframing'] = function()
  local chat = {}
  Protocol.call('frame', chat, frame_args(), 'armed')
  eq(Protocol.call('frame', chat, frame_args('revise'), 'reframing').status, 'success')

  local rejected = Protocol.call('evidence', chat, { items = {} }, 'reframing')
  eq(rejected.data.code, 'transition_invalid')
  eq(rejected.data.next_action.tool, 'reasoning_frame')
end

T['never treats replace as the first frame operation'] = function()
  local controlled = {}
  local rejected = Protocol.call('frame', controlled, frame_args('replace'), 'armed')
  eq(rejected.data.code, 'transition_invalid')
  eq(State.get(controlled), nil)

  local standalone = {}
  rejected = Protocol.call('frame', standalone, frame_args('replace'), nil)
  eq(rejected.data.code, 'transition_invalid')
  eq(State.get(standalone), nil)
end

T['returns workspace_finalized before a generic transition rejection'] = function()
  local chat = final_workspace_fixture()
  local rejected = Protocol.call('evidence', chat, { items = {} }, 'finalized')
  eq(rejected.data.code, 'workspace_finalized')
  eq(rejected.data.next_action.tool, 'none')
end

T['permits explicit revise and replace from active and finalized workspaces'] = function()
  for _, phase in ipairs({ 'active', 'finalized' }) do
    for _, action in ipairs({ 'revise', 'replace' }) do
      local chat = phase == 'finalized' and final_workspace_fixture() or active_workspace_fixture()
      local old = State.get(chat)
      local result = Protocol.call('frame', chat, frame_args(action), phase)
      eq(result.status, 'success')
      if action == 'replace' then
        local replacement = State.get(chat)
        eq(replacement == old, false)
        eq(replacement.counts_by_kind, { frame = 1 })
        eq(#replacement.artifact_order, 1)
      end
    end
  end
end

return T
```

Define `active_workspace_fixture()` and `final_workspace_fixture()` beside
`frame_args()`. Build the finalized fixture with the existing gate-complete
helpers, not by stubbing `Transition`; this proves the accepted-final detector
and transition authority agree. The controller still blocks execution in
`finalized` until the explicit resume command changes its phase to
`reframing`; direct `Protocol.call` continues to permit the documented explicit
revise/replace escape hatch.

- [ ] **Step 2: Add a failing reframe-retirement test**

Append to `frame_test.lua` using its existing `valid_args` helper:

```lua
T['revision retires every downstream artifact before rebuilding'] = function()
  local chat = {}
  local started = Frame.cmds[1]({ chat = chat }, valid_args(), {})
  local workspace = State.get(chat)
  local old_frame = workspace.frame_id
  local downstream = {}
  for _, kind in ipairs({ 'evidence', 'branch', 'option', 'review', 'synthesis' }) do
    local artifact = State.add(workspace, kind, { frame_id = old_frame })
    table.insert(downstream, artifact.id)
  end

  local revised = valid_args()
  revised.action = 'revise'
  revised.objective = 'Explain the corrected failure'
  revised.perspectives = { { name = 'operations', purpose = 'Check the corrected lifecycle' } }
  local result = Protocol.call('frame', chat, revised, 'active')

  eq(result.status, 'success')
  eq(State.find(workspace, old_frame).status, 'superseded')
  for _, id in ipairs(downstream) do
    eq(State.find(workspace, id).status, 'superseded')
  end
  eq(State.find(workspace, workspace.frame_id).status, 'active')
end
```

- [ ] **Step 3: Run the focused tests and verify RED**

Run:

```bash
make test_file FILE=tests/codecompanion/_extensions/reasoning/transition_test.lua
make test_file FILE=tests/codecompanion/_extensions/reasoning/tools/frame_test.lua
```

Expected: the transition module is missing, `Protocol.call` ignores a phase,
and revision preserves downstream artifacts.

- [ ] **Step 4: Implement the pure transition module**

Create `transition.lua`:

```lua
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
    return workspace == nil
      and operation == 'frame'
      and type(args) == 'table'
      and args.action == 'start'
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
```

- [ ] **Step 5: Enforce the optional lifecycle phase in `Protocol.call`**

Retain the `Terminal` require for partial-tool compatibility, require
`Constants` and `Transition`, export `M.transition = Transition.next`, and first
replace the common failure helper.
This establishes the non-commit contract before any transition test observes it:

```lua
local function failure(code, message, artifact_ids, next_action, diagnostic)
  local data = {
    code = code,
    message = message,
    artifact_ids = artifact_ids or {},
    committed = false,
    next_action = next_action,
  }
  if diagnostic then
    data.diagnostic = diagnostic
  end
  return { status = 'error', data = data }
end
```

Move the existing string-to-object conversion into this complete helper above
`M.call`:

```lua
local function normalize_next_action(operation, result)
  if result.status ~= 'error' or type(result.data.next_action) ~= 'string' then
    return result
  end
  local tools_by_code = {
    workspace_missing = 'reasoning_frame',
    perspective_unknown = 'reasoning_frame',
    limit_exceeded = 'reasoning_frame',
  }
  result.data.next_action = {
    tool = tools_by_code[result.data.code] or Constants.tool_by_operation[operation] or 'reasoning_frame',
    reason = result.data.next_action,
  }
  return result
end
```

Then change the call signature and pre-dispatch block to:

```lua
function M.call(operation, chat, args, lifecycle_phase)
  local tools_by_operation = Constants.tool_by_operation
  local workspace = State.get(chat)
  local explicit_reframe = operation == 'frame'
    and type(args) == 'table'
    and vim.tbl_contains({ 'revise', 'replace' }, args.action)
  if not explicit_reframe then
    local final = accepted_final(workspace)
    if final then
      return failure(
        'workspace_finalized',
        'the accepted final synthesis is terminal until the frame is explicitly revised or replaced',
        { final.id },
        { tool = 'none', reason = 'Use explicit user resume before reframing' }
      )
    end
  end

  if lifecycle_phase and not Transition.allowed(workspace, lifecycle_phase, operation, args) then
    local expected = Transition.next(workspace, lifecycle_phase)
    return failure(
      'transition_invalid',
      'the reasoning operation does not match the authoritative transition',
      {},
      expected,
      {
        path = 'tool',
        constraint = 'authoritative_transition',
        expected = expected and expected.tool or 'none',
        actual = tools_by_operation[operation] or 'unknown_operation',
      }
    )
  end

  local handler = M[operation]
  if type(handler) ~= 'function' then
    return failure(
      'internal_error',
      'the reasoning operation is unavailable',
      {},
      { tool = tools_by_operation[operation] or 'reasoning_frame', reason = 'Report the plugin error' }
    )
  end
  local ok, result = xpcall(function()
    return handler(chat, args)
  end, debug.traceback)
  if not ok then
    log:error('[reasoning] %s failed: %s', operation, result)
    return failure(
      'internal_error',
      'the reasoning operation failed internally',
      {},
      { tool = tools_by_operation[operation], reason = 'Report the plugin error' }
    )
  end
  if lifecycle_phase == nil and explicit_reframe and result.status == 'success' then
    Terminal.clear(chat)
  end
  return normalize_next_action(operation, result)
end
```

Delete the old inline code-to-tool conversion. Retain `Terminal.clear(chat)`
only after a successful explicit reframe with `lifecycle_phase == nil`; that
clears the legacy one-shot guard in a partial-tool chat without adding a second
submit wrapper to a controlled chat. Do not require a lifecycle phase for
controller-absent or open/dormant partial-tool compatibility. Task 6 supplies
the non-state `blocked` sentinel for every complete-uncontrolled, unsupported,
closed, or incomplete-sticky boundary, and a stored phase for enforcing chats.
Retain `M.failure = failure` so controller-side synthetic settlements use the
same public envelope constructor as protocol handlers.

- [ ] **Step 6: Retire downstream artifacts on successful revision**

In `Protocol.frame`, remove the old compatibility loop that blocks removing a
perspective or unknown used by evidence. After the new frame is allocated and
the old frame is superseded, retire the pre-existing active downstream IDs:

Before choosing a workspace, make replace-without-workspace invalid even when
no controller phase is supplied:

```lua
if args.action == 'replace' and not existing then
  return failure(
    'transition_invalid',
    'replace requires an existing reasoning workspace',
    {},
    { tool = 'reasoning_frame', reason = 'Start the workspace with action=start' },
    {
      path = 'action',
      constraint = 'authoritative_transition',
      expected = 'start',
      actual = 'replace',
    }
  )
end
```

```lua
local downstream = {}
if args.action == 'revise' then
  for _, id in ipairs(existing.artifact_order) do
    local artifact = State.find(existing, id)
    if artifact and artifact.status == 'active' and artifact.kind ~= 'frame' then
      table.insert(downstream, id)
    end
  end
end

local frame = State.add(workspace, 'frame', frame_data)
if not frame then
  return failure('limit_exceeded', 'the workspace artifact limit was reached', {}, 'Replace the workspace')
end
if workspace.frame_id then
  State.supersede(workspace, workspace.frame_id, frame.id)
end
State.set_frame(workspace, frame.id)
for _, id in ipairs(downstream) do
  State.retire(workspace, id)
end
return success(workspace, frame)
```

Collect IDs before allocation, but mutate statuses only after allocation
succeeds, so a limit rejection remains atomic. Keep the existing
`State.begin(chat, true)` path for `action=replace`: it must create a new empty
workspace whose only artifact is the new frame, while the old workspace object
remains unchanged for any existing audit reference. Add assertions that every
rejection preserves both `revision` and every `next_sequence` value.

- [ ] **Step 7: Run, format, and re-run transition and frame tests**

Run:

```bash
make test_file FILE=tests/codecompanion/_extensions/reasoning/transition_test.lua
make test_file FILE=tests/codecompanion/_extensions/reasoning/tools/frame_test.lua
make format
make test_file FILE=tests/codecompanion/_extensions/reasoning/transition_test.lua
make test_file FILE=tests/codecompanion/_extensions/reasoning/tools/frame_test.lua
```

Expected: both files pass with zero failures and notes.

- [ ] **Step 8: Commit authoritative transitions**

```bash
git add lua/codecompanion/_extensions/reasoning/transition.lua lua/codecompanion/_extensions/reasoning/protocol.lua tests/codecompanion/_extensions/reasoning/transition_test.lua tests/codecompanion/_extensions/reasoning/tools/frame_test.lua
git commit -m "feat(reasoning): enforce state transitions"
```

### Task 3: Return precise, safe, deterministic validation diagnostics

**Files:**
- Create: `lua/codecompanion/_extensions/reasoning/validation.lua`
- Create: `tests/codecompanion/_extensions/reasoning/validation_test.lua`
- Modify: `lua/codecompanion/_extensions/reasoning/protocol.lua`
- Modify: `tests/codecompanion/_extensions/reasoning/tools/frame_test.lua`
- Modify: `tests/codecompanion/_extensions/reasoning/tools/evidence_test.lua`
- Modify: `tests/codecompanion/_extensions/reasoning/tools/options_test.lua`
- Modify: `tests/codecompanion/_extensions/reasoning/tools/review_test.lua`
- Modify: `tests/codecompanion/_extensions/reasoning/tools/synthesis_test.lua`

- [ ] **Step 1: Write failing helper and protocol diagnostic tests**

Create `validation_test.lua` with direct cases proving that types, counts,
duplicate values, and reference failures never echo arbitrary model text:

```lua
local Validation = require('codecompanion._extensions.reasoning.validation')

local T = MiniTest.new_set()
local eq = MiniTest.expect.equality

T['describes missing, bounded, and enum failures safely'] = function()
  eq(Validation.required(nil, 'items', 'array'), {
    path = 'items', constraint = 'required', expected = 'array', actual = 'missing',
  })
  eq(Validation.text(string.rep('x', 9), 'objective', 8), {
    path = 'objective', constraint = 'max_chars', expected = 8, actual = 9,
  })
  eq(Validation.enum('model supplied markdown', 'mode', { final = true }), {
    path = 'mode', constraint = 'enum', expected = { 'final' }, actual = 'unknown_enum',
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
    path = 'unknowns[2]', constraint = 'unique_items', expected = true, actual = 'duplicate_value',
  })
  eq(Validation.artifact_ids({ 'E1', '# forged\nmodel prose' }), { 'E1', 'invalid_id' })
end

return T
```

Add one representative assertion to each tool test. Use these exact shapes:

```lua
eq(result.data.committed, false)
eq(result.data.diagnostic, {
  path = 'items', constraint = 'max_items', expected = 1, actual = 2,
})
```

For each of `armed`, `active`, and `reframing`, add one malformed expected-tool
case and assert its normalized `next_action` equals
`Protocol.transition(State.get(chat), phase)` at the point of rejection. Add a
finalized non-reframe case asserting `workspace_finalized` and `tool='none'`.
These cases make recovery state-aware instead of merely checking stable error
codes.

```lua
eq(result.data.diagnostic, {
  path = 'options[1].evidence_ids[1]',
  constraint = 'artifact_kind',
  expected = 'evidence',
  actual = 'F1',
})
```

```lua
eq(result.data.diagnostic, {
  path = 'items[1].perspective',
  constraint = 'active_frame_perspective',
  expected = { 'correctness', 'operations' },
  actual = 'unknown_value',
})
```

For every rejected call, snapshot `workspace.revision`, `artifact_order`, and
`next_sequence` before dispatch and assert they are unchanged afterward. Then
submit one valid artifact and assert its ID is still the next expected ID.
Also send a hostile reference through a real tool handler and assert neither
`result.data.artifact_ids` nor encoded output contains the hostile text;
central `failure()` must sanitize caller-provided IDs, not only
`diagnostic.actual`.

- [ ] **Step 2: Run the diagnostic tests and verify RED**

Run:

```bash
make test_file FILE=tests/codecompanion/_extensions/reasoning/validation_test.lua
make test_file FILE=tests/codecompanion/_extensions/reasoning/tools/evidence_test.lua
```

Expected: FAIL because `validation.lua`, `committed`, and field diagnostics do
not yet exist for all validation paths.

- [ ] **Step 3: Implement the safe diagnostic primitives**

Create `validation.lua`:

```lua
local M = {}

local function value_type(value)
  if value == nil then
    return 'missing'
  end
  if type(value) == 'table' then
    return vim.islist(value) and 'array' or 'object'
  end
  return type(value)
end

local function safe_id(value)
  if type(value) == 'string' and #value <= 32 and value:match('^[A-Z]+%d+$') then
    return value
  end
  return 'invalid_id'
end

local function diagnostic(path, constraint, expected, actual)
  return { path = path, constraint = constraint, expected = expected, actual = actual }
end

function M.required(value, path, expected)
  if value == nil then
    return diagnostic(path, 'required', expected, 'missing')
  end
  if value_type(value) ~= expected then
    return diagnostic(path, 'type', expected, value_type(value))
  end
end

function M.text(value, path, maximum)
  local required = M.required(value, path, 'string')
  if required then
    return required
  end
  local count = vim.fn.strchars(value)
  if vim.trim(value) == '' then
    return diagnostic(path, 'min_chars', 1, count)
  end
  if count > maximum then
    return diagnostic(path, 'max_chars', maximum, count)
  end
end

function M.array(value, path, minimum, maximum)
  local required = M.required(value, path, 'array')
  if required then
    return required
  end
  if #value < minimum then
    return diagnostic(path, 'min_items', minimum, #value)
  end
  if #value > maximum then
    return diagnostic(path, 'max_items', maximum, #value)
  end
end

function M.enum(value, path, allowed)
  if type(value) ~= 'string' then
    return diagnostic(path, 'type', 'string', value_type(value))
  end
  if not allowed[value] then
    local expected = vim.tbl_keys(allowed)
    table.sort(expected)
    return diagnostic(path, 'enum', expected, 'unknown_enum')
  end
end

function M.unique(values, path, key)
  local seen = {}
  for index, value in ipairs(values) do
    local identity = key and key(value) or value
    if seen[identity] then
      return diagnostic(
        ('%s[%d]'):format(path, index),
        'unique_items',
        true,
        safe_id(identity) ~= 'invalid_id' and identity or 'duplicate_value'
      )
    end
    seen[identity] = true
  end
end

function M.reference(workspace, id, path, expected_kind)
  local printable = safe_id(id)
  local artifact = printable ~= 'invalid_id' and workspace.artifacts_by_id[id] or nil
  if not artifact then
    return diagnostic(path, 'artifact_exists', true, printable)
  end
  if artifact.kind ~= expected_kind then
    return diagnostic(path, 'artifact_kind', expected_kind, printable)
  end
  if artifact.status ~= 'active' then
    return diagnostic(path, 'artifact_status', 'active', printable)
  end
end

function M.artifact_ids(values)
  local safe = {}
  for _, id in ipairs(type(values) == 'table' and values or {}) do
    table.insert(safe, safe_id(id))
  end
  return safe
end

function M.diagnostic(path, constraint, expected, actual)
  return diagnostic(path, constraint, expected, actual)
end

return M
```

- [ ] **Step 4: Refactor validators in schema order**

Require `Validation` in `protocol.lua` and change the common failure constructor
to assign `artifact_ids = Validation.artifact_ids(artifact_ids)`. Replace each compound validation block
with ordered early returns that call `failure(code, message, offenders,
state_aware_next_action, diagnostic)`. Preserve stable error codes and messages;
only add detail. Check fields in this exact order:

| Operation | Deterministic field order |
| --- | --- |
| Frame | `action`, `objective`, `problem_type`, `depth`, `constraints`, `success_criteria`, `unknowns`, `perspectives`, `temporal_required`, `branching_required`, `branching_rationale`, then frame semantics |
| Evidence | `items`, then each item: `kind`, `statement`, `source`, `confidence`, `falsifier`, `perspective`, `addresses_unknowns`, `supports`, `contradicts`, `qualifies`, `supersedes_id`, then references |
| Options | `question`, `branch_type`, `criteria`, `supersedes_branch_id`, `options`, then each option: `label`, `summary`, `evidence_ids`, `assumptions`, `predictions`, `benefits`, `costs`, `risks`, `reversibility`, then references |
| Review | `mode`, `target_ids`, `defense.summary`, `defense.evidence_ids`, `challenges` (`kind`, `summary`, `target_ids`, `falsifier`), `blind_spots`, `stress_tests`, `verdicts`, `contradiction_resolutions`, `structural_tradeoffs`, then references and coverage |
| Synthesis | `mode`, `conclusion`, `selected_option_ids`, `support_ids`, `review_ids`, `criterion_results`, `tradeoffs`, `uncertainties`, `blind_spots`, `next_actions`, `confidence`, then typed references and final gates |

Use `value_type` only through the helper so `actual` is a type, count, fixed
sentinel, safe enum label, or validated artifact ID. For framed perspective and
unknown constraints, sort the active frame's allowed strings into `expected`
and report `actual = 'unknown_value'`; never echo the offending free text.
After local validation, compute the authoritative transition again and use its
tool/reason for `next_action` whenever the prerequisite has not advanced.

- [ ] **Step 5: Run every protocol validator test**

Run:

```bash
make test_file FILE=tests/codecompanion/_extensions/reasoning/validation_test.lua
make test_file FILE=tests/codecompanion/_extensions/reasoning/tools/frame_test.lua
make test_file FILE=tests/codecompanion/_extensions/reasoning/tools/evidence_test.lua
make test_file FILE=tests/codecompanion/_extensions/reasoning/tools/options_test.lua
make test_file FILE=tests/codecompanion/_extensions/reasoning/tools/review_test.lua
make test_file FILE=tests/codecompanion/_extensions/reasoning/tools/synthesis_test.lua
make format
```

Expected: all six files pass with zero failures and notes, and rejected calls
retain the pre-call revision and next artifact ID.

- [ ] **Step 6: Commit structured diagnostics**

```bash
git add lua/codecompanion/_extensions/reasoning/validation.lua lua/codecompanion/_extensions/reasoning/protocol.lua tests/codecompanion/_extensions/reasoning/validation_test.lua tests/codecompanion/_extensions/reasoning/tools
git commit -m "feat(reasoning): add safe validation diagnostics"
```

### Task 4: Resolve configuration-bound schemas and strengthen the protocol prompt

**Files:**
- Create: `lua/codecompanion/_extensions/reasoning/schema.lua`
- Create: `tests/codecompanion/_extensions/reasoning/schema_test.lua`
- Modify: `lua/codecompanion/_extensions/reasoning/config.lua`
- Modify: `lua/codecompanion/_extensions/reasoning/init.lua`
- Modify: `lua/codecompanion/_extensions/reasoning/guidance.lua`
- Modify: `tests/codecompanion/_extensions/reasoning/config_test.lua`
- Modify: `tests/codecompanion/_extensions/reasoning/init_test.lua`
- Modify: `tests/codecompanion/_extensions/reasoning/guidance_test.lua`

- [ ] **Step 1: Write failing resolution-time schema tests**

Create `schema_test.lua` and exercise the real cached tool modules through the
resolver:

```lua
local Config = require('codecompanion._extensions.reasoning.config')
local Schema = require('codecompanion._extensions.reasoning.schema')

local T = MiniTest.new_set({ hooks = { pre_case = function() Config.setup() end } })
local eq = MiniTest.expect.equality

T['exposes default evidence batch bounds'] = function()
  local tool = Schema.resolve(
    'reasoning_evidence',
    require('codecompanion._extensions.reasoning.tools.evidence')
  )
  local items = tool.schema['function'].parameters.properties.items
  eq(items.minItems, 1)
  eq(items.maxItems, 8)
end

T['applies current evidence batch, array, and text limits'] = function()
  Config.setup({ limits = { max_batch_items = 3, max_array_items = 5, max_text_chars = 111 } })
  local tool = Schema.resolve(
    'reasoning_evidence',
    require('codecompanion._extensions.reasoning.tools.evidence')
  )
  local items = tool.schema['function'].parameters.properties.items
  eq(items.minItems, 1)
  eq(items.maxItems, 3)
  eq(items.items.properties.statement.maxLength, 111)
  eq(items.items.properties.supports.maxItems, 5)
  eq(items.items.properties.supports.uniqueItems, true)
  eq(items.items.properties.supports.items.maxLength, nil)
  eq(items.items.properties.supersedes_id.minLength, nil)
end

T['returns a fresh schema after configuration changes'] = function()
  local template = require('codecompanion._extensions.reasoning.tools.evidence')
  Config.setup({ limits = { max_batch_items = 4 } })
  local first = Schema.resolve('reasoning_evidence', template)
  Config.setup({ limits = { max_batch_items = 2 } })
  local second = Schema.resolve('reasoning_evidence', template)
  eq(first.schema['function'].parameters.properties.items.maxItems, 4)
  eq(second.schema['function'].parameters.properties.items.maxItems, 2)
end

T['dealiases shared review arrays before path-specific constraints'] = function()
  Config.setup({ limits = { max_array_items = 5, max_text_chars = 111 } })
  local tool = Schema.resolve(
    'reasoning_review',
    require('codecompanion._extensions.reasoning.tools.review')
  )
  local properties = tool.schema['function'].parameters.properties
  eq(properties.defense.properties.evidence_ids.uniqueItems, true)
  eq(properties.defense.properties.evidence_ids.items.maxLength, nil)
  eq(properties.blind_spots.uniqueItems, nil)
  eq(properties.blind_spots.items.maxLength, 111)
  eq(properties.challenges.items.properties.target_ids.items.maxLength, nil)
end

return T
```

Extend `config_test.lua` with a boundary case that rejects
`max_array_items=1`, preserves the previous valid configuration after that
rejection, and accepts `max_array_items=2`. The protocol requires at least two
options (and two perspectives for deep frames), so configuration must never
produce an array schema with `maxItems` below its literal `minItems`.

In `init_test.lua`, replace path assertions with `type(registration.callback) ==
'function'`, `registration.path == nil`, and real `ToolRuntime.resolve` checks.
Keep the collision test: arbitrary host `path`, `callback`, `cmds`, `schema`, and
identity fields must still be discarded while description, visibility, and
the three approval options remain preserved.

Add a prompt-contract test that resolves the registered group prompt and
asserts all eight rules are present: complete attachment commitment, unlimited
external tools, frame/start first, no direct final prose, retryable
`committed=false` rejection, rejected IDs do not exist, revise/replace for new
information, and accepted artifacts as the deterministic final's only source.
Assert the old “return the accepted conclusion” instruction is absent.

- [ ] **Step 2: Run the schema and init tests and verify RED**

```bash
make test_file FILE=tests/codecompanion/_extensions/reasoning/config_test.lua
make test_file FILE=tests/codecompanion/_extensions/reasoning/schema_test.lua
make test_file FILE=tests/codecompanion/_extensions/reasoning/init_test.lua
```

Expected: FAIL because registrations still resolve a cached module by `path`
and schemas do not expose configured limits; the configuration boundary still
accepts an impossible maximum of one.

- [ ] **Step 3: Implement fresh schema resolution**

Create `schema.lua`. Its resolver deep-copies the cached tool template, then
walks the copy and applies current limits:

First, strengthen `Config.validate` so `max_array_items` must be an integer of
at least two, with the stable error `max_array_items must be at least 2`.
Perform this check before assigning the candidate to module state, preserving
the existing transactional setup behavior.

```lua
local Config = require('codecompanion._extensions.reasoning.config')

local M = {}

local unique_arrays = {
  ['reasoning_frame.success_criteria'] = true,
  ['reasoning_frame.unknowns'] = true,
  ['reasoning_evidence.items.addresses_unknowns'] = true,
  ['reasoning_evidence.items.supports'] = true,
  ['reasoning_evidence.items.contradicts'] = true,
  ['reasoning_evidence.items.qualifies'] = true,
  ['reasoning_options.criteria'] = true,
  ['reasoning_options.options.evidence_ids'] = true,
  ['reasoning_review.target_ids'] = true,
  ['reasoning_review.defense.evidence_ids'] = true,
  ['reasoning_review.challenges.target_ids'] = true,
  ['reasoning_review.contradiction_resolutions.evidence_ids'] = true,
  ['reasoning_review.structural_tradeoffs.evidence_ids'] = true,
  ['reasoning_synthesis.selected_option_ids'] = true,
  ['reasoning_synthesis.support_ids'] = true,
  ['reasoning_synthesis.review_ids'] = true,
  ['reasoning_synthesis.criterion_results.evidence_ids'] = true,
  ['reasoning_synthesis.tradeoffs'] = true,
  ['reasoning_synthesis.uncertainties'] = true,
  ['reasoning_synthesis.blind_spots'] = true,
  ['reasoning_synthesis.next_actions'] = true,
}

local empty_text_allowed = {
  ['reasoning_review.verdicts.revision_instruction'] = true,
}

local artifact_id_paths = {
  ['reasoning_evidence.items.supports'] = true,
  ['reasoning_evidence.items.contradicts'] = true,
  ['reasoning_evidence.items.qualifies'] = true,
  ['reasoning_evidence.items.supersedes_id'] = true,
  ['reasoning_options.supersedes_branch_id'] = true,
  ['reasoning_options.options.evidence_ids'] = true,
  ['reasoning_review.target_ids'] = true,
  ['reasoning_review.defense.evidence_ids'] = true,
  ['reasoning_review.challenges.target_ids'] = true,
  ['reasoning_review.verdicts.target_id'] = true,
  ['reasoning_review.contradiction_resolutions.left_id'] = true,
  ['reasoning_review.contradiction_resolutions.right_id'] = true,
  ['reasoning_review.contradiction_resolutions.evidence_ids'] = true,
  ['reasoning_review.structural_tradeoffs.evidence_ids'] = true,
  ['reasoning_synthesis.selected_option_ids'] = true,
  ['reasoning_synthesis.support_ids'] = true,
  ['reasoning_synthesis.review_ids'] = true,
  ['reasoning_synthesis.criterion_results.evidence_ids'] = true,
}

local function minimum(left, right)
  return left and math.min(left, right) or right
end

local function clone_schema(value)
  if type(value) ~= 'table' then
    return value
  end
  local copy = {}
  for key, child in pairs(value) do
    copy[clone_schema(key)] = clone_schema(child)
  end
  return copy
end

local function visit(node, path, limits)
  if type(node) ~= 'table' then
    return
  end
  if node.type == 'string' and node.enum == nil and not artifact_id_paths[path] then
    if not empty_text_allowed[path] then
      node.minLength = 1
    end
    node.maxLength = limits.max_text_chars
  elseif node.type == 'array' then
    node.maxItems = minimum(node.maxItems, limits.max_array_items)
    if unique_arrays[path] then
      node.uniqueItems = true
    end
  end
  if type(node.properties) == 'table' then
    for name, child in pairs(node.properties) do
      visit(child, path .. '.' .. name, limits)
    end
  end
  if node.items then
    visit(node.items, path, limits)
  end
end

function M.resolve(name, template)
  local resolved = vim.deepcopy(template)
  resolved.schema = clone_schema(template.schema)
  local limits = Config.get().limits
  local parameters = resolved.schema['function'].parameters
  for field, node in pairs(parameters.properties) do
    visit(node, name .. '.' .. field, limits)
  end
  if name == 'reasoning_evidence' then
    local items = parameters.properties.items
    items.minItems = 1
    items.maxItems = limits.max_batch_items
  end
  return resolved
end

return M
```

Keep `unique_arrays` synchronized with every nested target/evidence-ID array in
review and options. Array traversal retains the owning property path while it
visits the item schema, yielding paths such as
`reasoning_evidence.items.supports`. Keep existing schema minima and stricter literal
maxima by taking the lower maximum. The explicit `artifact_id_paths` set keeps
both scalar IDs and array item IDs free of prose length constraints; the
resolution tests must cover a relation ID and each permitted-empty supersession
ID. `vim.deepcopy` preserves shared-table aliases inside a template, so clone
the schema tree without memoization before visiting it; JSON Schema trees here
are acyclic, and each property occurrence must become independent. Do not add
`maxLength` to enums.

- [ ] **Step 4: Replace path registration with a resolver callback**

In `init.lua`, require `Constants` and `Schema`; remove the duplicate local
tool-name list and use `Constants.tool_names`. Task 12 adds the `Control`
dependency after that module exists. Add:

```lua
local function tool_callback(name)
  return function()
    local template = require('codecompanion.' .. paths[name])
    return Schema.resolve(name, template)
  end
end
```

Change the canonical registration to `{ callback = tool_callback(name),
description = descriptions[name] }` and preserve only the existing safe
description, visible flag, and approval fields. Do not preserve a colliding
host `path`, `callback`, `cmds`, `schema`, name, adapter marker, or MCP fields.

Replace the group prompt with eight explicit runtime rules: complete attachment
commits the final-answer path; external tools are unrestricted and budget
neutral; frame/start is first; direct model-written final prose is forbidden;
rejections are retryable and `committed=false`; rejected IDs do not exist; new
user information requires revise/replace; only accepted artifacts support the
deterministic final. Retain the concise artifact/privacy instructions. Remove
the instruction to return the accepted conclusion as model prose.

Update `Guidance.next`'s terminal reason to exactly:

```lua
return { tool = 'none', reason = 'Final synthesis accepted; no further model action is permitted' }
```

- [ ] **Step 5: Run all resolution and guidance tests**

```bash
make test_file FILE=tests/codecompanion/_extensions/reasoning/config_test.lua
make test_file FILE=tests/codecompanion/_extensions/reasoning/schema_test.lua
make test_file FILE=tests/codecompanion/_extensions/reasoning/init_test.lua
make test_file FILE=tests/codecompanion/_extensions/reasoning/guidance_test.lua
make test_file FILE=tests/codecompanion/_extensions/reasoning/tools/frame_test.lua
make test_file FILE=tests/codecompanion/_extensions/reasoning/tools/evidence_test.lua
make test_file FILE=tests/codecompanion/_extensions/reasoning/tools/options_test.lua
make test_file FILE=tests/codecompanion/_extensions/reasoning/tools/review_test.lua
make test_file FILE=tests/codecompanion/_extensions/reasoning/tools/synthesis_test.lua
make format
```

Expected: all files pass; resolving evidence after a second `Config.setup`
uses the second batch limit even though its Lua module is cached.

- [ ] **Step 6: Commit dynamic constraints and prompt guidance**

```bash
git add lua/codecompanion/_extensions/reasoning/config.lua lua/codecompanion/_extensions/reasoning/schema.lua lua/codecompanion/_extensions/reasoning/init.lua lua/codecompanion/_extensions/reasoning/guidance.lua tests/codecompanion/_extensions/reasoning/config_test.lua tests/codecompanion/_extensions/reasoning/schema_test.lua tests/codecompanion/_extensions/reasoning/init_test.lua tests/codecompanion/_extensions/reasoning/guidance_test.lua
git commit -m "feat(reasoning): resolve current protocol schemas"
```

### Task 5: Render citation-closed final Markdown deterministically

**Files:**
- Create: `lua/codecompanion/_extensions/reasoning/render.lua`
- Create: `tests/codecompanion/_extensions/reasoning/render_test.lua`

- [ ] **Step 1: Write failing closure, ordering, and escaping tests**

Build a workspace fixture with one active frame, solution/hypothesis/scenario
branches, options, evidence, reviews, and one unrelated active evidence record.
The test must call `Render.render(workspace, synthesis_data)` directly and
assert:

- exact heading order from Conclusion through Confidence;
- singular and plural headings for all three branch types;
- option evidence appears immediately in first-occurrence closure order;
- direct and criterion evidence is deduplicated after option evidence;
- unrelated `E99` never appears;
- empty optional sections are absent;
- missing, inactive, wrong-kind, and cross-branch references throw;
- `# Forged`, `> Forged`, `- forged`, `1. forged`, `---`, a fenced block,
  `[link]:`, `<script>`, pipes, and embedded newlines cannot create headings,
  blockquotes, injected lists, HTML, tables, code fences, or link definitions.

Use exact index assertions rather than a snapshot so each ordering invariant is
named. End the injection case with:

```lua
eq(select(2, markdown:gsub('\n## ', '')), 1)
eq(markdown:find('<script>', 1, true), nil)
eq(markdown:find('\n---\n', 1, true), nil)
eq(markdown:find('\n[link]:', 1, true), nil)
eq(markdown:find('\n> Forged', 1, true), nil)
eq(markdown:find('\n- forged', 1, true), nil)
eq(markdown:find('\n1. forged', 1, true), nil)
eq(markdown:find('```', 1, true), nil)
```

- [ ] **Step 2: Run the renderer tests and verify RED**

```bash
make test_file FILE=tests/codecompanion/_extensions/reasoning/render_test.lua
```

Expected: FAIL loading the missing renderer.

- [ ] **Step 3: Implement the pure renderer**

Create `render.lua` with no I/O, controller dependency, or state mutation:

```lua
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
      table.insert(entries, string.format(
        '- **%s — %s:** %s',
        scalar(option.id),
        scalar(option.data.label),
        scalar(option.data.summary)
      ))
    end
    section(lines, titles[#selected == 1 and 1 or 2], entries)
  end

  local evidence_entries = {}
  for _, item in ipairs(evidence) do
    table.insert(evidence_entries, string.format(
      '- **%s:** %s _(source: %s; confidence: %s)_',
      scalar(item.id),
      scalar(item.data.statement),
      scalar(item.data.source),
      scalar(item.data.confidence)
    ))
  end
  section(lines, 'Supporting evidence', evidence_entries)

  local review_entries = {}
  for _, review in ipairs(reviews) do
    table.insert(review_entries, '- **' .. scalar(review.id) .. '**')
    for _, challenge in ipairs(review.data.challenges or {}) do
      table.insert(review_entries, string.format(
        '  - Challenge (%s; targets: %s): %s',
        scalar(challenge.kind),
        scalar(table.concat(challenge.target_ids or {}, ', ')),
        scalar(challenge.summary)
      ))
    end
    for _, verdict in ipairs(review.data.verdicts or {}) do
      local instruction = vim.trim(verdict.revision_instruction or '')
      local suffix = instruction ~= '' and (': ' .. scalar(instruction)) or ''
      table.insert(review_entries, string.format(
        '  - Verdict (%s): %s%s',
        scalar(verdict.target_id),
        scalar(verdict.status),
        suffix
      ))
    end
    for _, resolution in ipairs(review.data.contradiction_resolutions or {}) do
      table.insert(review_entries, string.format(
        '  - Resolution (%s/%s; evidence: %s): %s',
        scalar(resolution.left_id),
        scalar(resolution.right_id),
        scalar(table.concat(resolution.evidence_ids or {}, ', ')),
        scalar(resolution.resolution)
      ))
    end
    for _, tradeoff in ipairs(review.data.structural_tradeoffs or {}) do
      table.insert(review_entries, string.format(
        '  - Structural trade-off (evidence: %s): %s',
        scalar(table.concat(tradeoff.evidence_ids or {}, ', ')),
        scalar(tradeoff.statement)
      ))
    end
  end
  section(lines, 'Adversarial review', review_entries)

  local criteria = {}
  for _, result in ipairs(candidate.criterion_results or {}) do
    table.insert(criteria, string.format(
      '- **%s** — %s: %s _(evidence: %s)_',
      scalar(result.criterion),
      scalar(result.status),
      scalar(result.explanation),
      scalar(table.concat(result.evidence_ids or {}, ', '))
    ))
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
```

- [ ] **Step 4: Run, format, and re-run renderer tests**

```bash
make test_file FILE=tests/codecompanion/_extensions/reasoning/render_test.lua
make format
make test_file FILE=tests/codecompanion/_extensions/reasoning/render_test.lua
```

Expected: every closure, section-order, plurality, omission, and injection case
passes with zero failures and notes.

- [ ] **Step 5: Commit the renderer**

```bash
git add lua/codecompanion/_extensions/reasoning/render.lua tests/codecompanion/_extensions/reasoning/render_test.lua
git commit -m "feat(reasoning): render deterministic finals"
```

### Task 6: Arm a metatable-safe per-chat lifecycle controller

**Files:**
- Create: `lua/codecompanion/_extensions/reasoning/control.lua`
- Create: `tests/codecompanion/_extensions/reasoning/control_test.lua`
- Modify: `lua/codecompanion/_extensions/reasoning/tools/frame.lua`
- Modify: `lua/codecompanion/_extensions/reasoning/tools/evidence.lua`
- Modify: `lua/codecompanion/_extensions/reasoning/tools/options.lua`
- Modify: `lua/codecompanion/_extensions/reasoning/tools/review.lua`
- Modify: `lua/codecompanion/_extensions/reasoning/tools/synthesis.lua`

- [ ] **Step 1: Build a pinned-host controller fixture and failing arming tests**

In `control_test.lua`, create a `new_chat(opts)` fixture exposing the exact
v19.22.0 surfaces used by the controller: raw or inherited `submit`,
`_submit_http`, `done`, `add_buf_message`, `add_tool_output`, `clear`, and
`close`; `tools.execute/reset`; callback
registration/removal/dispatch; `adapter.type`; `tool_registry.in_use`;
`MESSAGE_TYPES`; `messages`; `subscribers.stop`; `restore`; and a valid buffer.
Use `Control._reset()` and `State._reset()` in hooks.

Mirror the pinned submit callback contract exactly: the fixture creates one
payload table, dispatches `on_submitted(chat, { payload = payload })`, and then
passes that same table identity to `_submit_http(payload)`. Retain both the
callback data and transport argument so Task 8 can assert the construction
lease is bound to the actual v19.22.0 boundary, not a fixture convenience.

Add cases for:

- four attached tools do not install a controller;
- the fifth HTTP tool synchronously produces phase `armed`;
- `Control.phase` returns nil only for controller-absent or open/dormant
  partial compatibility, and the effective `blocked` sentinel for
  complete-before-install, ACP-complete, closed, unsupported, or
  incomplete-sticky boundaries;
- `legacy_terminal_allowed` is true only for those two partial cases;
- a workspace hydrates `active`, while an accepted final hydrates `finalized`;
- repeated reconciliation preserves the same wrappers and callbacks;
- after the last strong chat reference is released, two
  `collectgarbage('collect')` calls remove the chat and make `Control._count()`
  return zero;
- raw methods and inherited methods are captured and restored exactly;
- an initially ACP chat receives one unsupported notice and no wrappers;
- HTTP to ACP suspends, emits one unsupported notice, and blocks; repeated
  reconciliation emits no duplicate, then ACP to HTTP restores the phase;
- switching to ACP during a request/tool output invalidates their tokens and
  discards late callbacks; switching with a prepared final discards the stage,
  halts with `resume_phase='active'`, and switching back never restores a
  stage-less `finalizing` phase;
- tool removal after arming causes submit to fail closed;
- a bare/programmatic submit while `chat.tool_orchestrator` is live is settled
  without a request; the host continuation is allowed only after finalization
  clears the orchestrator;
- removal during the preserved manual submit is caught by `on_before_submit`;
- a configured `vim.g.codecompanion_adapter` that resolves to ACP is caught
  before the host's silent post-callback adapter swap.
- a partial-tool chat that previously installed the legacy terminal guard
  clears it before fifth-tool controller capture; retries and resume never
  delegate through nested submit wrappers.
- after clear, a dormant controller can also run partial-tool compatibility;
  if that installs a guard, fifth-tool rearm unwraps it back to the existing
  controller submit wrapper before entering `armed`.

The synchronous arming test must simulate group loading order: add each name to
`in_use`, call `Control.reconcile(chat)`, and assert the fifth call installs
before invoking a simulated `auto_submit`.

- [ ] **Step 2: Run the controller tests and verify RED**

```bash
make test_file FILE=tests/codecompanion/_extensions/reasoning/control_test.lua
```

Expected: FAIL loading the missing controller.

- [ ] **Step 3: Add controller state and method-preservation primitives**

Start `control.lua` with weak-key state and these exact public functions:

```lua
Control.setup_autocmds()
Control.reconcile(chat)
Control.phase(chat)
Control.legacy_terminal_allowed(chat)
Control.stage_final(chat, tool, finalization)
Control.resume(chat)
Control.clear(chat)
Control.uninstall(chat)
Control._get(chat)
Control._count()
Control._reset()
```

The initial state contains every lifecycle field up front:

```lua
local controllers = setmetatable({}, { __mode = 'k' })
local unsupported_notified = setmetatable({}, { __mode = 'k' })

local function new_state(chat, phase)
  return {
    chat_ref = setmetatable({ chat }, { __mode = 'v' }),
    phase = phase,
    resume_phase = 'active',
    suspended_phase = nil,
    unsupported_adapter = false,
    consecutive_violations = 0,
    fallback_lease = nil,
    request_generation = 0,
    completion_classified = true,
    observed_call_ids = {},
    staged_final = nil,
    closed = false,
    epoch = 0,
    next_request_token = 0,
    construction_lease = nil,
    active_request_token = nil,
    pending_stop_token = nil,
    call_tokens = setmetatable({}, { __mode = 'k' }),
    executing_scope = nil,
    request_handle = nil,
    resume_attempt = nil,
    submitting = false,
    clearing = false,
    methods = {},
    callbacks = {},
  }
end

local function chat_for(state)
  return state.chat_ref[1]
end
```

Capture and restore raw and inherited methods without invoking metatable writes:

```lua
local function capture_method(target, key)
  local original = target and target[key] or nil
  assert(type(original) == 'function', key .. ' must resolve to a function')
  return {
    target_ref = setmetatable({ target }, { __mode = 'v' }),
    key = key,
    had_raw = rawget(target, key) ~= nil,
    original = original,
  }
end

local function install_wrapper(slot, wrapper)
  local target = assert(slot.target_ref[1], 'wrapper target was collected')
  slot.wrapper = wrapper
  rawset(target, slot.key, wrapper)
end

local function restore_method(slot)
  local target = slot.target_ref[1]
  if target and rawget(target, slot.key) == slot.wrapper then
    rawset(target, slot.key, slot.had_raw and slot.original or nil)
  end
end
```

Do not store a strong `chat` or method target anywhere in the weak-map value;
otherwise the value points back to its weak key and LuaJIT cannot collect the
entry. Wrappers/callbacks keep state alive only while their owning live chat is
reachable, and scheduled callbacks obtain the chat through `chat_for(state)`
and return when it has been collected.

Capture eight boundaries during the first install: `submit`, `_submit_http`,
`done`, `add_buf_message`, `add_tool_output`, `clear`, and `close` on `chat`,
plus `execute` on `chat.tools`. The `_submit_http` slot is required because the
pinned host discards its client's request ID before dynamically calling
`self:done`; Task 8 uses this captured boundary to bind every HTTP callback to
an unambiguous epoch/generation token without copying host transport code. The
clear slot is required because pinned
`Chat:clear()` fires `ChatCleared` only after rendering; it invalidates and
cancels first, then delegates so any cancellation-driven `Tools:reset` output
is wiped by the preserved clear. The close slot is required because pinned `Chat:close()` calls
`stop()` before dispatching `on_closed`; its instance wrapper marks controller
state closed before that host cancellation begins. Install pass-through
wrappers immediately; later tasks add classification behavior without changing
wrapper identity.
At this checkpoint, implement `uninstall` for a settled chat by removing the
registered `on_before_submit` callback, restoring the eight captured slots, and
removing the weak state; Task 11 adds busy-state refusal and full callback/
command cleanup. Define `stage_final` and `resume` to return `nil,
'not available in this lifecycle build'` until their TDD tasks replace them,
so the declared module API is total at every commit.
Implement the initial `clear` as `State.clear(chat)` plus `phase='dormant'` for
an installed state, and expose `_get`/`_reset` for the fixture. Task 11 replaces
that minimal reset with generation invalidation and cancellation before host
event wiring becomes active.

- [ ] **Step 4: Implement attachment and adapter reconciliation**

Use `Constants.tool_names` and the pinned `in_use` map:

```lua
local function complete_tool_set(chat)
  local in_use = chat.tool_registry and chat.tool_registry.in_use or {}
  for _, name in ipairs(Constants.tool_names) do
    if in_use[name] ~= true then
      return false
    end
  end
  return true
end

local function hydrated_phase(chat)
  local workspace = State.get(chat)
  if not workspace then
    return 'armed'
  end
  return Protocol.transition(workspace, 'active').tool == 'none' and 'finalized' or 'active'
end
```

`Control.reconcile(chat)` follows this order:

1. Return for closed state.
2. If the full tool set is absent and no state exists, do nothing.
3. If the current adapter is ACP and no state exists, emit one unsupported
   notice through the resolved original `add_buf_message`, but install nothing.
4. If HTTP and complete with no state, call `Terminal.clear(chat)` before
   capture, then install wrappers and callbacks synchronously, hydrate phase,
   and create the command later in Task 9. Require `terminal.lua` only for this
   one compatibility handoff; after capture a controlled chat never installs
   or delegates through that guard.
5. If installed HTTP changes to ACP, store the current phase in
   `suspended_phase`, invalidate request tokens, staged-final, and retry state, set
   `unsupported_adapter=true`, emit one concise unsupported-adapter notice for
   that transition, keep wrappers, and settle new submits. Reconciliation while
   already unsupported is silent. If the phase was `finalizing`, discard the
   prepared stage and halt with `resume_phase='active'`; never store or restore
   `finalizing` without its stage.
6. If it changes back to HTTP with the complete set, restore
   `suspended_phase`, clear the flag, and keep the sticky controller.
7. If tools disappear after installation, keep the controller and make submit
   fail closed with a concise reattachment status.

The HTTP→ACP invalidation follows the clear ordering without deleting the
workspace: mark active/pending tokens invalid, clear them, increment epoch,
clear construction/`submitting` leases plus retry/resume/correction state,
cancel and clear any HTTP handle and tool
orchestrator, then discard a stage. This makes every extant call marker stale
before cancellation callbacks can run.

Call `Terminal.clear(chat)` before every transition into an enforcing phase,
both fresh install and dormant fifth-tool rearm. In the dormant case the guard
restores its captured original—which is the existing controller submit
wrapper—so wrapper identity remains stable.

The submit wrapper delegates through `slot.original(chat, opts)` only when the
adapter is HTTP, the full set remains attached,
`chat.tool_orchestrator == nil`, `state.active_request_token == nil`,
`state.construction_lease == nil`, `state.clearing == false`, and
`state.submitting == false`. Set
`submitting=true` immediately before calling the preserved submit and restore
it in a finally path on every return or throw. This closes synchronous re-entry
from `on_submitted`, before the pinned host assigns `current_request`, and
prevents a second request generation from
starting after `Chat:done` clears `current_request` but before asynchronous tool
output completes. Keeping the active token through preserved `done` also
settles synchronous subscriber/`on_ready` submits while that token is
`settling`. The pinned host continuation runs only after tool
finalization clears the orchestrator. On a blocked call, invoke
`opts.callback` exactly once when present; otherwise call `chat:restore()` once.
Do not clear or inject `chat._btw`. Store `chat.current_request` after the
preserved submit returns only as the cancellation handle; request-token
identity, never handle status, is completion authority.

Expose `legacy_terminal_allowed(chat)` for `output.lua`: it returns true only
when fewer than all five tools are attached and controller state is absent or
open/dormant. It returns false for complete, enforcing, installed-unsupported,
incomplete-sticky, and closed controllers. This is the sole predicate allowed
to authorize the compatibility submit wrapper.

Register an `on_before_submit` callback that returns `false` only when its
second attachment/adapter check fails. Before returning, resolve a configured
`vim.g.codecompanion_adapter` with the same `codecompanion.adapters` and
`codecompanion.config.adapters` path used by pinned `Chat:submit`; reject an ACP
target because the host swaps it after this callback without another adapter
event.

Implement the idempotent event registration now; Task 12 connects it to
extension setup:

```lua
function M.setup_autocmds()
  local group = vim.api.nvim_create_augroup(Constants.augroup, { clear = true })
  vim.api.nvim_create_autocmd('User', {
    group = group,
    pattern = {
      'CodeCompanionChatToolAdded',
      'CodeCompanionChatAdapter',
      'CodeCompanionChatCleared',
    },
    callback = function(event)
      local bufnr = event.data and event.data.bufnr
      local chat = type(bufnr) == 'number' and require('codecompanion').buf_get_chat(bufnr) or nil
      if not chat then
        return
      end
      if event.match == 'CodeCompanionChatCleared' then
        M.clear(chat)
      else
        M.reconcile(chat)
      end
    end,
  })
end
```

Return nil only for controller-absent or open/dormant partial compatibility.
Use the non-state `blocked` sentinel everywhere a controller boundary exists
but mutation cannot be enforced:

```lua
function M.phase(chat)
  local state = controllers[chat]
  local complete = complete_tool_set(chat)
  if not state then
    return complete and 'blocked' or nil
  end
  if state.closed or state.unsupported_adapter then
    return 'blocked'
  end
  if state.phase == 'dormant' then
    return complete and 'blocked' or nil
  end
  return complete and state.phase or 'blocked'
end

function M.legacy_terminal_allowed(chat)
  if complete_tool_set(chat) then
    return false
  end
  local state = controllers[chat]
  return not state
    or (not state.closed and not state.unsupported_adapter and state.phase == 'dormant')
end
```

- [ ] **Step 5: Pass the controller phase at every protocol command boundary**

In all five tool modules require `Control` and change each command to the same
pattern:

```lua
return Protocol.call('frame', tools.chat, args, Control.phase(tools.chat))
```

Use the corresponding operation in the other modules. Controller-absent and
open/dormant partial attachments receive nil, preserving individual-tool
behavior. Complete-but-not-yet-installed,
unsupported, closed, and incomplete-sticky boundaries receive `blocked`; an
enforcing controller supplies its current stored phase. `Protocol.call`
rechecks the transition just before mutation.

- [ ] **Step 6: Run, format, and re-run controller and tool tests**

```bash
make test_file FILE=tests/codecompanion/_extensions/reasoning/control_test.lua
make test_file FILE=tests/codecompanion/_extensions/reasoning/tools/frame_test.lua
make test_file FILE=tests/codecompanion/_extensions/reasoning/tools/evidence_test.lua
make test_file FILE=tests/codecompanion/_extensions/reasoning/tools/options_test.lua
make test_file FILE=tests/codecompanion/_extensions/reasoning/tools/review_test.lua
make test_file FILE=tests/codecompanion/_extensions/reasoning/tools/synthesis_test.lua
make format
make test_file FILE=tests/codecompanion/_extensions/reasoning/control_test.lua
```

Expected: controller and existing standalone tool cases pass. The wrapper
identity is stable across repeated reconciliation.

- [ ] **Step 7: Commit lifecycle arming**

```bash
git add lua/codecompanion/_extensions/reasoning/control.lua lua/codecompanion/_extensions/reasoning/tools tests/codecompanion/_extensions/reasoning/control_test.lua
git commit -m "feat(reasoning): arm chat lifecycle control"
```

### Task 7: Suppress free-form output and preflight reasoning batches atomically

**Files:**
- Modify: `lua/codecompanion/_extensions/reasoning/control.lua`
- Modify: `tests/codecompanion/_extensions/reasoning/control_test.lua`

- [ ] **Step 1: Add failing output-filter and batch tests**

Extend `control_test.lua` with cases proving:

- `LLM_MESSAGE` and `REASONING_MESSAGE` buffer writes are suppressed in
  `armed`, `active`, `reframing`, `finalizing`, and `halted`;
- tool, system, and user writes remain visible;
- prose/reasoning accompanying tool calls is removed before history while the
  formatted calls still reach `tools.execute`;
- an external-only batch with multiple calls delegates unchanged, on success
  and failure, without changing phase or violation count;
- the pinned unresolved-external path, which deep-copies its formatted call,
  remains recorded with host-default visibility and budget-neutral without
  weakening stale-call identity;
- one reasoning call delegates only when it matches the current transition;
- controller preflight and direct `Protocol.call` return the same transition,
  code, and `next_action` for equivalent armed, active, reframing, finalizing,
  halted, and finalized inputs, including out-of-order options and review
  calls;
- mixed and multiple-reasoning batches run no call, create no orchestrator or
  autocmd, record one synthetic response per distinct call ID, reset exactly
  once with `{ auto_submit=false }`, and count one completion violation;
- every table-shaped call in those rejected batches has an exact marker before
  synthetic settlement, so mixed/multi-reasoning rejection never depends on an
  accepted-call-only assertion;
- known reasoning calls with non-table/non-string arguments are rejected;
- valid JSON strings are decoded only for preflight and still delegate in their
  original host shape;
- invalid JSON strings delegate to the pinned host malformed-call path;
- duplicate reasoning IDs in one generation settle once;
- anonymous malformed envelopes remain host errors, not reasoning violations;
- `finalizing`, `halted`, and `finalized` execute no late calls.

Snapshot an external side-effect counter before rejected mixed batches and
assert it remains zero.

- [ ] **Step 2: Run the controller tests and verify RED**

```bash
make test_file FILE=tests/codecompanion/_extensions/reasoning/control_test.lua
```

Expected: FAIL because the installed wrappers still delegate all buffer writes
and formatted tool batches.

- [ ] **Step 3: Implement intermediate-output filtering**

Use a single phase predicate and preserve non-prose messages:

```lua
local suppressing_phase = {
  armed = true,
  active = true,
  reframing = true,
  finalizing = true,
  halted = true,
}

local function wrapped_add_buf_message(state, chat, data, opts)
  local kind = type(opts) == 'table' and opts.type or nil
  if
    not state.closed
    and suppressing_phase[state.phase]
    and (kind == chat.MESSAGE_TYPES.LLM_MESSAGE or kind == chat.MESSAGE_TYPES.REASONING_MESSAGE)
  then
    return nil
  end
  return state.methods.add_buf_message.original(chat, data, opts)
end
```

Add a controller-only `emit_status` helper that calls the captured original
method so halt/adapter notices bypass this filter without opening a general
model-prose path.

Update the `done` wrapper to discard `output` and `reasoning` whenever the
controller is enforcing, but pass the original `tools` and `opts` so the host
still formats, records, and executes tool calls. Preserve `meta` only when a
tool call or stopped/error cleanup is present. For a successful zero-call
completion pass `meta=nil`; pinned `Chat:done` otherwise writes a hidden empty
assistant history entry even after prose is stripped. Assert both visible
output and the history length/roles remain unchanged. Task 8 adds zero-call
classification and request-token guards.

- [ ] **Step 4: Implement formatted-call preflight and synthetic settlement**

Inspect only the formatted calls given to `chat.tools:execute`. Classify names
through `Constants.tool_set`. Decode a string argument with `pcall(vim.json.decode,
arguments)` only to check the transition; on decode failure delegate unchanged
so v19.22.0 reaches its normal malformed-call path, but bind the marker with
`status='malformed_pending'`. A valid known reasoning call uses
`status='executing'`; this distinction lets Task 8 separate model JSON failure
from an internal tool-resolver failure.

Use `Protocol.transition(State.get(chat), state.phase)` at call time. Permit an
exact expected tool, frame/start in `armed`, and frame/revise-or-replace in
`reframing` or as an explicit reframe from `active`. Do not cache the result.
The protocol command performs the same check again before mutation.
Apply controller lifecycle gates first: a call in `finalized` is synthetically
settled with the same `workspace_finalized` envelope that `Protocol.call`
returns, while `finalizing`/`halted` use their state-aware blocked envelope.
An explicit frame reframe is still blocked in `finalized`; the resume command
must move the controller to `reframing`, where preflight and `Protocol.call`
both permit revise/replace. Test equality on those equivalent phases rather
than bypassing the explicit-resume boundary.
Before deciding whether a batch is accepted or rejected, require the complete
tool set and make a first pass that binds every formatted call table, including
external calls, to an immutable entry in `state.call_tokens`. Argument decoding
and the proposed marker status occur in this pass; lifecycle, batch-shape,
duplicate, and transition decisions occur only after it. This object-identity
binding guarantees `settle_rejected_batch` already has a marker for every
table-shaped call it can record, and is also what lets clear
discard an old asynchronous output even if a later request reuses its string
ID:

```lua
local workspace = State.get(chat)
local ids_before = {}
for id in pairs(workspace and workspace.artifacts_by_id or {}) do
  ids_before[id] = true
end
local marker = {
  status = is_reasoning
      and (arguments_malformed and 'malformed_pending' or 'executing')
    or 'external',
  epoch = state.epoch,
  generation = state.request_generation,
  request_token = state.active_request_token,
  operation = Constants.operation_by_tool[call_name],
  action = type(decoded_arguments) == 'table' and decoded_arguments.action or nil,
  workspace = workspace,
  workspace_id = workspace and workspace.id or nil,
  revision = workspace and workspace.revision or nil,
  artifact_ids_before = ids_before,
}
state.call_tokens[call] = marker
```

For reasoning calls, consult
`observed_call_ids[current_generation][call.id]` for duplication, bind the new
table marker regardless, and record the first marker in that ID slot. A
pre-existing slot makes the batch a `reasoning_call_duplicate`; synthetic
settlement still uses each call table's exact marker. Never store string-only marker states. The
post-record wrapper in Task 8 changes only `marker.status` to `classified` or
`synthetic`. Keep the token through the preserved `done` delegation so calls
formatted and executed inside `Chat:done` inherit that request's epoch and
generation; clear invalidates them by epoch even after the HTTP request itself
has settled.

Around the captured `tools.execute` delegation, install a temporary
`state.executing_scope` containing the exact markers indexed by the tuple
`{id, call_id, function.name}` and clear it in a finally block. Pinned
`Tools:_handle_tool_error` deep-copies an unresolved formatted call and invokes
`add_tool_output` synchronously inside this scope. If exact table lookup misses,
the output wrapper may bind that copy only when the live scope has the same
epoch/generation and the tuple identifies exactly one unclaimed marker. No
scope-based fallback is allowed after `execute` returns, so an asynchronous
stale result with a reused string ID can never authenticate this way.

Settle an atomic rejection without calling the captured executor:

```lua
local function halt_internal(state, message)
  state.fallback_lease = nil
  state.resume_phase = state.phase
  state.phase = 'halted'
  local chat = chat_for(state)
  if chat then
    chat.subscribers:stop()
  end
  emit_status(state, message)
end

local function settle_rejected_batch(state, tools, chat, calls, payload)
  tools.chat = chat
  tools.status = tools.constants.STATUS_ERROR
  local encoded = assert(vim.json.encode(payload))
  local seen = {}
  local verified = true
  for _, call in ipairs(calls) do
    local id = type(call) == 'table' and call.id or nil
    if type(id) == 'string' and id ~= '' and not seen[id] then
      seen[id] = true
      local marker = assert(state.call_tokens[call], 'formatted call marker is missing')
      marker.status = 'synthetic_pending'
      state.observed_call_ids[state.request_generation][id] =
        state.observed_call_ids[state.request_generation][id] or marker
      local fn = type(call['function']) == 'table' and call['function'] or {}
      local recorded = record_and_verify_synthetic(state, marker, {
        name = type(fn.name) == 'string' and fn.name or 'unknown',
        function_call = call,
      }, encoded, '')
      verified = recorded and verified
    end
  end
  if not verified then
    halt_internal(state, 'reasoning synthetic settlement was rewritten')
    tools:reset({ auto_submit = false })
    return false
  end
  state.consecutive_violations = math.min(3, state.consecutive_violations + 1)
  tools:reset({ auto_submit = false })
  return true
end
```

Initialize `observed_call_ids[generation]` before indexing it. Construct one
public failure payload with `Protocol.failure`:

```lua
local payload = Protocol.failure(
  'reasoning_batch_invalid',
  'a reasoning completion must contain exactly one reasoning tool call',
  {},
  Protocol.transition(State.get(chat), state.phase),
  {
    path = 'tool_calls',
    constraint = 'sole_reasoning_call',
    expected = 1,
    actual = #calls,
  }
).data
```

`record_and_verify_synthetic` snapshots any same-ID result, delegates through
the installed `add_tool_output`, decodes only the newly recorded delta, and
requires the exact intended `code` plus `committed=false`. Only then set
`marker.status='synthetic'` and return true. If a mutable `on_tool_output`
callback rewrites the rejection, replace that delta with a public
`internal_error` and return false without incrementing or resetting. The outer
settlement still closes every distinct call, then halts uncounted and owns the
single `tools:reset`. Assert exact violation and reset counts for this hostile
case. This helper is shared with Task 8's ordinary post-record classifier.

Use stable codes `reasoning_batch_invalid`, `reasoning_call_malformed`,
`reasoning_call_duplicate`, and `transition_invalid`. A lifecycle-blocked late
batch is settled without incrementing the violation count. Synthetic
settlement marks IDs before calling `add_tool_output`, so post-record
classification cannot count the same rejection again.

- [ ] **Step 5: Run, format, and re-run the controller tests**

```bash
make test_file FILE=tests/codecompanion/_extensions/reasoning/control_test.lua
make format
make test_file FILE=tests/codecompanion/_extensions/reasoning/control_test.lua
```

Expected: all output and preflight cases pass; rejected batches call reset once
and never increment workspace revision or an external side-effect counter.

- [ ] **Step 6: Commit the controlled execution boundary**

```bash
git add lua/codecompanion/_extensions/reasoning/control.lua tests/codecompanion/_extensions/reasoning/control_test.lua
git commit -m "feat(reasoning): preflight reasoning completions"
```

### Task 8: Classify each completion once and bound corrective retries

**Files:**
- Modify: `lua/codecompanion/_extensions/reasoning/control.lua`
- Modify: `tests/codecompanion/_extensions/reasoning/control_test.lua`

- [ ] **Step 1: Add failing generation, budget, and lease tests**

Add cases covering this matrix:

- every successful zero-call completion is suppressed and counted once,
  including text-only, reasoning-only, metadata-only, and empty output;
- a suppressed zero-call completion adds neither visible prose nor a hidden
  empty assistant history message;
- duplicate `done`, stopped output, `on_cancelled`, and transport-error status
  never count;
- free-form text alongside tools is suppressed but not counted;
- external-tool success and failure neither increment nor reset the budget;
- accepted frame/evidence/options/review/checkpoint output resets the budget;
- a decoded protocol rejection and a host malformed known-reasoning result each
  count once by `{ generation, call_id }`;
- invalid JSON is rewritten in place to structured
  `reasoning_call_malformed`, `committed=false`, safe diagnostic, and the
  authoritative next action; a valid reasoning call whose resolver throws is
  instead rewritten to `internal_error` and halts uncounted;
- reusing a call ID in a later generation classifies only the newly appended
  host-result segment, even though v19.22.0 merges it into the old message;
- same-shape `on_tool_output` tampering with an accepted artifact's text,
  relations, or collection order is detected against State and halts uncounted;
- `internal_error` and `render_internal` halt immediately without spending the
  budget;
- violations one and two replace one tagged hidden correction and produce one
  generation/epoch-bound fallback lease;
- a confirmed host continuation consumes the lease, while a no-op submit does
  not;
- `on_ready` schedules exactly one fallback when all host auto-submit options
  are disabled;
- approval, YOLO, success, and error auto-submit paths never combine with the
  fallback to produce two requests;
- violation three stops subscribers, clears correction/lease, records
  `resume_phase`, enters `halted`, and emits one visible status;
- halted submit settles a supplied callback once; callback-free settlement
  restores once and preserves `_btw`;
- request A is cleared, the controller rearms, and request B starts; A's late
  stream/status/error/tool-bearing/done callbacks are ignored before rearm,
  while B is pending, and after B's handle reports `success`;
- retained A content, reasoning, and compaction chunks are dropped at callback
  ingress without buffer writes, status changes, or `ChatCompacting` events;
- B's token-bound completion still classifies exactly once after those A
  callbacks, proving the decision does not depend on handle timing;
- recursive submit from the synchronous `on_submitted` callback is settled,
  leaving exactly one generation and one request token;
- direct, duplicate, and mismatched-payload `_submit_http` calls outside the
  exact unconsumed construction lease start no transport and create no token;
- the payload object observed in pinned `on_submitted` is the exact object
  accepted once by the subsequent `_submit_http`, while an equal deep copy is
  rejected;
- clear inside `on_submitted` invalidates the construction lease before the
  pinned host reaches `_submit_http`, so no request survives the clear;
- synchronous subscriber/`on_ready` submit from inside preserved `done` is
  settled while the old token is `settling`, leaving one generation;
- a synchronous throw from the preserved `_submit_http`/client `send()` path
  invalidates its token, clears construction/request leases, halts internally
  without spending the violation budget, and cannot poison a later resume;
- an old asynchronous tool result is ignored when a new request reuses its
  string call ID because the formatted call-table identity differs;
- cancellation invalidates the owed lease and correction before `Tools:reset`
  can reach `on_ready`; draining every scheduled callback submits nothing.

Use a fake request handle with `id`, `status()`, and `cancel()`, retain the
per-request proxy passed to the preserved `_submit_http`, and use a synchronous
custom-request fake as well as queued callbacks. The stale-A cases must pass
even when B reports `success`; a pending/streaming-only test would merely encode
the insufficient handle-status heuristic.

- [ ] **Step 2: Run the controller tests and verify RED**

```bash
make test_file FILE=tests/codecompanion/_extensions/reasoning/control_test.lua
```

Expected: FAIL because generations, post-record classification, hidden
corrections, and leases are not implemented.

- [ ] **Step 3: Bind HTTP callbacks to submitted generations**

Register exact callback identities in `state.callbacks`. The submission
callback is the sole generation increment and lease compare-and-set point:

```lua
local function on_submitted(state, data)
  if not state.submitting then
    return
  end
  state.request_generation = state.request_generation + 1
  state.completion_classified = false
  state.observed_call_ids[state.request_generation] = {}
  state.construction_lease = {
    epoch = state.epoch,
    generation = state.request_generation,
    payload = type(data) == 'table' and data.payload or nil,
    consumed = false,
  }

  local lease = state.fallback_lease
  if
    lease
    and lease.epoch == state.epoch
    and lease.generation < state.request_generation
  then
    state.fallback_lease = nil
  end
  if state.resume_attempt then
    state.resume_attempt.confirmed = true
    state.resume_attempt.generation = state.request_generation
  end
end
```

The pinned host's client has a request ID, but `_submit_http` discards it and
later calls dynamic `self:done(...)`. Consequently a `done` wrapper plus
`current_request:status()` cannot distinguish a late A completion from B's
completion after clear/rearm. Replace the pass-through `_submit_http` wrapper
with request-origin binding. Enter it only while `state.submitting == true`,
`completion_classified == false`, no active token exists, and one unconsumed
`construction_lease` matches the current epoch/generation and the exact payload
table passed by `on_submitted`. A direct, duplicate, or mismatched
request-construction call is settled without invoking the host transport.
Atomically mark that lease consumed and clear it, then create the token from the
lease's epoch/generation:

```lua
local lease = state.construction_lease
lease.consumed = true
state.construction_lease = nil
local token = {
  id = state.next_request_token + 1,
  epoch = lease.epoch,
  generation = lease.generation,
  handle = nil,
  invalidated = false,
  settling = false,
  settled = false,
}
state.next_request_token = token.id
state.active_request_token = token
if state.resume_attempt and state.resume_attempt.epoch == state.epoch then
  state.resume_attempt.constructed = true
  state.resume_attempt.request_token = token
end
```

Invoke the captured host method with a per-request proxy as `self`, not by
copying `_submit_http`. The host callbacks then close over that proxy. The
proxy holds only a weak chat reference and provides raw token-bound
`done`, `add_buf_message`, and `_set_status` functions plus immutable snapshots
of `MESSAGE_TYPES`, `bufnr`, and chat ID. Its metatable delegates other
reads/calls to the live chat only while this exact token is current, and ignores
stale writes. Shadow `status`, `tokens`, and `_last_role`; forward their writes
to the real chat while current, but keep later invalidated writes only in the
shadow.

Return a request-local adapter proxy from the chat proxy's raw `adapter` field.
Clone the adapter handler tree and wrap `parse_chat`, `parse_tokens`, and
`parse_meta`, including their legacy aliases, so they return nil before calling
the real handler when `token_current` is false. This is the callback-ingress
gate: stale content/reasoning chunks cannot reach `MESSAGE_TYPES`, and a stale
compaction chunk cannot call `_set_status` or fire `ChatCompacting`. Delegate
all non-response adapter behavior required during synchronous request
construction. Tests invoke the actual retained client `on_chunk`, `on_done`,
and `on_error` callbacks for content, reasoning, compaction, error, and
completion instead of calling proxy methods directly.

On every proxy `current_request` assignment, always store the value in
`token.handle`. Copy it to `chat.current_request` and `state.request_handle`
only while the token is current. This records a handle returned after a
synchronous completion for cancellation/accounting without resurrecting it on
the live chat.

```lua
local function token_current(state, token)
  return not state.closed
    and not token.invalidated
    and not token.settling
    and not token.settled
    and state.active_request_token == token
    and token.epoch == state.epoch
    and token.generation == state.request_generation
end
```

The proxy's raw `done` calls `complete_bound_request(state, token, ...)`.
That function atomically changes `settling=true` before any host delegation,
classifies the generation, and retains the token until the preserved real-chat
`done` returns so formatted calls created inside `Chat:done` can inherit its
epoch/generation. It then marks `settled=true`, clears the exact active token
and cancellation handle, and never consults handle status. Duplicate or stale
proxy callbacks return without touching chat state. If a custom request calls
back synchronously before `send()` returns its handle, the later proxy
assignment records but does not resurrect the already-settled handle.

Invoke the captured `_submit_http` slot under `xpcall`. If request construction
throws after `on_submitted`, keep the traceback only in the plugin log, mark the
exact token invalidated and settled, clear it from active/request fields, set
`completion_classified=true`, invalidate any resume attempt, increment the
epoch, and enter the uncounted internal-halt path with the pre-request lifecycle
phase as `resume_phase`. Return nil to the pinned submit rather than exposing
raw transport text or leaving a half-live request. The outer submit wrapper
must restore `submitting=false` in its finally path. Neither path may leave a
fallback lease or correction capable of starting another request.

Upgrade the outer submit wrapper to use the same safe `xpcall`/finally pattern.
After the preserved submit returns, an unconsumed construction lease means the
host dispatched `on_submitted` but built no HTTP request. When that exact
epoch/generation belongs to the live `resume_attempt`, leave the lease and
unclassified generation in place for the immediately returning `M.resume`
transaction to settle and roll back; do not emit an internal halt. For every
ordinary submission, invalidate and clear the exact lease, settle its
generation, increment epoch, and halt internally. A preserved-submit throw
always follows the safe internal-halt path—including during resume—and never
exposes its traceback. A normal pre-submit no-op has no construction lease and
remains a settled no-op. Clear during `on_submitted` deletes the lease and
changes epoch before the host can call `_submit_http`; the outer finally must
preserve the resulting dormant state rather than converting that deliberate
clear into an internal halt.

For a successful completion with no calls, count one violation regardless of
whether output or reasoning is blank, pass `output=nil`, `reasoning=nil`, and
`meta=nil` to the preserved `done`, and let host cleanup proceed. For a
tool-bearing completion, pass the original tools and metadata but strip prose
and reasoning. For a token-bound transport error or stopped completion,
delegate cleanup once without counting.

Register `on_cancelled` to clear `fallback_lease`, consume/clear any
construction lease, remove the tagged correction, invalidate any resume attempt and active token, clear
`active_request_token`, set `completion_classified=true`, and increment the
epoch before the host resets tools. That epoch change invalidates both request
callbacks and asynchronous formatted-call markers, including cancellation
during tool execution. Store a cleanup lease—not the token itself—as:

```lua
state.pending_stop_token = {
  token = token,
  cleanup_epoch = state.epoch,
  generation = state.request_generation,
}
```

The public real-chat `done` wrapper accepts only the anonymous scheduled
`{status='stopped'}` cleanup when this exact lease still matches the current
epoch/generation and no newer active token exists; otherwise it clears the
stale lease and returns. All ordinary HTTP completions must arrive through a
bound proxy. This prevents a delayed `Chat:stop` callback from clearing request
B and prevents cancelled tools from recording late output or reviving a retry.

- [ ] **Step 4: Classify the recorded tool result, not incoming output**

Wrap `add_tool_output` in this order:

1. Resolve `state.call_tokens[tool.function_call]` by table identity before any
   host side effect, with only the live, unique `executing_scope` copy fallback
   defined in Task 7. Return without delegation when closed or when its
   epoch/generation is stale. An otherwise unbound output delegates unchanged
   only in `dormant`; while enforcing it is settled as an internal error and
   halts.
2. Return for a marker already `synthetic` or `classified`. A
   `synthetic_pending` marker takes a dedicated nested path: delegate and expose
   the recorded delta to the outer `record_and_verify_synthetic` helper, but do
   not run generic classification or increment the budget. Snapshot any
   pre-existing matching result object plus its exact content.
3. Call the captured original method under `xpcall`. A throw is an uncounted
   internal halt, not a model rejection or a stranded `finalizing` phase.
4. Scan `chat.messages` backward for the matching recorded result. If it is the
   snapshotted object and the host appended `old_content .. '\n\n' .. delta`,
   decode only `delta`; otherwise decode the newly inserted entry's content.
5. Decode that post-callback segment; never classify the incoming
   `for_llm`, because `on_tool_output` may rewrite it.

Match both pinned response layouts:

```lua
local function result_matches_call(message, call)
  local tools = message.tools or {}
  return tools.id == call.id
    or tools.call_id == call.id
    or (call.call_id ~= nil and tools.call_id == call.call_id)
end
```

Treat a reused-ID entry whose post-call content does not have the exact pinned
append prefix as an uncounted `internal_error`; never decode concatenated JSON
or fall back to the pre-callback input.

For a known reasoning name, validate the recorded payload against the marker's
pre-call snapshot before classifying it. Use this exact operation contract:

```lua
local accepted_shape = {
  frame = { primary = 'frame' },
  evidence = { primary = 'evidence', collection = 'evidence', collection_required = true },
  options = { primary = 'branch', collection = 'option', collection_required = true },
  review = { primary = 'review' },
  synthesis = { primary = 'synthesis' },
}
```

A recorded success is progress only when `workspace_id` equals the current
workspace, every reported ID resolves to an active artifact of the expected
kind, the primary/collection fields have the exact shape above, and the set of
reported IDs equals the set allocated since `marker.artifact_ids_before`.
The decoded primary artifact must be `vim.deep_equal` to its complete
`State.find(...)` value, and a required collection must deep-equal the complete
newly allocated State artifacts in emitted order. Comparing only IDs, kinds,
or counts is forbidden: `on_tool_output` may preserve shape while rewriting
data or relations.
Workspace identity must remain `marker.workspace`, except frame/start from no
workspace and frame/replace, which must create a clean new workspace containing
only the returned frame. Its `progress` and `next_action` must equal current
state and `Protocol.transition(current_workspace, 'active')`. This makes an
accepted artifact—not arbitrary JSON containing an `artifact` key—the only
budget reset.

A decoded rejection or host malformed result is model-correctable only when
workspace identity, revision, artifact IDs, statuses, and relations remain at
the marker snapshot and `committed == false`. If a successful protocol mutation
was rewritten into an error, or a rejected call was rewritten into fake
success, rewrite the recorded delta to `internal_error` and halt without
spending the budget. An already-committed ordinary success is not rolled back:
derive `resume_phase` from the post-mutation workspace (normally `active`), not
the pre-call `armed`/`reframing` phase, so recovery cannot deadlock against an
existing frame. Add hostile `on_tool_output` tests for both directions plus
corrupted frame/start and reframe resume cases.
Task 10 validates its uncommitted staged final before this generic path.

For `marker.status='malformed_pending'`, replace only the recorded host-error
delta with `Protocol.failure('reasoning_call_malformed', ...)`, including
`committed=false`, `Protocol.transition(current_workspace, state.phase)`, and:

```lua
local diagnostic = {
  path = 'arguments',
  constraint = 'json_object',
  expected = 'object',
  actual = 'invalid_json',
}
```

Recompute the exact role/content hash, set the marker classified, and count one
model violation. Conversely, non-JSON output from an `executing` marker means a
known reasoning call decoded and passed preflight but host tool resolution
failed; rewrite it to `internal_error` and halt uncounted. Do not expose either
raw host string to the model.

Mark `marker.status='classified'` before changing budget. On genuine progress,
set phase from `armed`/`reframing` to `active`, reset
`consecutive_violations=0`, invalidate the lease, and remove the tagged
correction. Ignore a valid external marker for budget purposes.

If the preserved host method creates no matching result, insert a fixed public
`internal_error` tool response for the same call instead of leaving an orphan.
Use `codecompanion.adapters.call_handler(adapter, 'format_response', call,
encoded)` and, only if the supported adapter unexpectedly returns nil, a
minimal hidden `role='tool'` fallback containing both pinned ID fields. Insert
it directly (the captured method already failed to record), assign
`_meta.cycle`, and compute exactly:

```lua
message._meta.id = require('codecompanion.utils.hash').hash({
  role = message.role,
  content = message.content,
})
```

For every rewrite of a reused-ID record, preserve the snapshotted prefix and
replace only this invocation's delta, then recompute the same exact hash. Halt
as an uncounted internal error; never guess from the incoming output or report
a model-correctable malformed call.

- [ ] **Step 5: Implement corrections, leases, and the third-violation halt**

Replace the temporary counter from Task 7 with `record_violation(state,
payload)`. Before changing phase, query `Protocol.transition` and build one
hidden correction:

```lua
local function replace_correction(state, transition, code)
  local chat = chat_for(state)
  if not chat then
    return
  end
  chat:remove_tagged_message(Constants.corrective_tag)
  chat:add_message({
    role = 'system',
    content = string.format(
      'Reasoning protocol correction (%s): call %s next. %s Rejected calls commit no artifacts; change the arguments before retrying.',
      code,
      transition.tool,
      transition.reason
    ),
  }, {
    visible = false,
    _meta = { tag = Constants.corrective_tag },
  })
end
```

For counts one/two, replace correction and assign exactly:

```lua
state.fallback_lease = {
  generation = state.request_generation,
  epoch = state.epoch,
}
```

For count three, invalidate the lease, remove correction, save the current
phase in `resume_phase`, stop `chat.subscribers`, enter `halted`, and emit one
status containing expected tool/reason and
`:CodeCompanionReasoningResume`. For `internal_error`/`render_internal`, use
the same halt path with the previous phase but do not increment the count.

The `on_ready` callback schedules only the still-owed object identity:

```lua
local function schedule_fallback(state)
  local lease = state.fallback_lease
  if not lease then
    return
  end
  vim.schedule(function()
    local chat = chat_for(state)
    if
      not chat
      or state.closed
      or state.fallback_lease ~= lease
      or lease.epoch ~= state.epoch
      or lease.generation ~= state.request_generation
      or state.unsupported_adapter
      or not complete_tool_set(chat)
      or chat.adapter.type ~= 'http'
      or chat.current_request
      or chat.tool_orchestrator
      or not ({ armed = true, active = true, reframing = true })[state.phase]
    then
      return
    end
    chat:submit({ auto_submit = true })
    state.request_handle = chat.current_request
  end)
end
```

The scheduled path deliberately re-enters the installed submit wrapper so its
attachment, adapter, lifecycle, and settlement gates remain the single submit
authority. The existing submit wrapper must now block `finalizing`, `halted`, and
`finalized` in addition to adapter/tool failures. Never treat a bare submit as
manual recovery.

- [ ] **Step 6: Run, format, and re-run the controller tests**

```bash
make test_file FILE=tests/codecompanion/_extensions/reasoning/control_test.lua
make format
make test_file FILE=tests/codecompanion/_extensions/reasoning/control_test.lua
```

Expected: the full matrix passes. Assert exact submit counts after draining
`vim.schedule` callbacks, not merely that a lease was cleared.

- [ ] **Step 7: Commit bounded recovery**

```bash
git add lua/codecompanion/_extensions/reasoning/control.lua tests/codecompanion/_extensions/reasoning/control_test.lua
git commit -m "feat(reasoning): bound corrective retries"
```

### Task 9: Add explicit user resume and post-final reframing

**Files:**
- Modify: `lua/codecompanion/_extensions/reasoning/control.lua`
- Modify: `tests/codecompanion/_extensions/reasoning/control_test.lua`

- [ ] **Step 1: Add failing command and resume-transaction tests**

Cover:

- install creates one buffer-local `:CodeCompanionReasoningResume` command;
- bare `chat.submit()` remains blocked in `halted` and `finalized`;
- command rejects blank/no unsent user content, ACP, missing reasoning tools,
  current requests, active tool orchestrators, and every non-recovery phase;
- halted resume preserves workspace, restores its exact `resume_phase`, and
  starts a fresh three-violation budget;
- finalized resume moves to `reframing` before the request is submitted, so
  free-form streaming is suppressed for the entire follow-up;
- a synchronous `on_submitted` confirmation commits the resume;
- a request that constructs and completes synchronously commits the resume even
  though no handle remains after `submit` returns;
- `on_submitted` without token construction rolls phase/count back, consumes
  the exact construction lease, marks that phantom generation classified, and
  leaves uninstall/a later resume usable;
- a preserved-submit or `_submit_http` construction throw during resume keeps
  the uncounted internal halt created by Task 8 instead of restoring the prior
  halted/finalized phase;
- late callbacks retained by a failed resume token are ignored after rollback;
- a pending fallback callback captured before resume cannot submit afterward;
- external investigation is allowed while reframing, but only frame/revise or
  frame/replace can advance back to active;
- command deletion occurs on live uninstall and close.
- the command callback retains no strong chat reference; after installation,
  releasing the last external reference still lets the weak controller collect.

Mock `codecompanion.interactions.chat.parser.messages` at its real signature,
`parser.messages(chat, chat.header_line)`, and return `{ content='new facts' }`
or `nil` per case.

- [ ] **Step 2: Run the controller tests and verify RED**

```bash
make test_file FILE=tests/codecompanion/_extensions/reasoning/control_test.lua
```

Expected: FAIL because no buffer command or transactional recovery path exists.

- [ ] **Step 3: Install the sole explicit recovery command**

During controller installation:

```lua
local command_state = state
vim.api.nvim_buf_create_user_command(
  chat.bufnr,
  Constants.resume_command,
  function()
    local current = chat_for(command_state)
    if current then
      M.resume(current)
    end
  end,
  { desc = 'Resume the fail-closed reasoning protocol' }
)
```

Store the command identity in state. Live uninstall/close uses
`pcall(vim.api.nvim_buf_del_user_command, chat.bufnr,
Constants.resume_command)`. Clear keeps it because dormant state must be able to
rearm and late generations still need tombstone wrappers. Never close over the
chat itself: Neovim retains the callback and would defeat weak-key collection.

- [ ] **Step 4: Implement verified resume as a transaction**

Start with the pinned parser and all preconditions:

```lua
local parser = require('codecompanion.interactions.chat.parser')
local pending = parser.messages(chat, chat.header_line)
local has_input = pending
  and type(pending.content) == 'string'
  and vim.trim(pending.content) ~= ''
```

Require `phase == 'halted' or phase == 'finalized'`, no current request, no
`chat.tool_orchestrator`, supported HTTP, and `complete_tool_set(chat)`. Reuse the configured-adapter
precheck from Task 6. Then:

```lua
local previous = {
  phase = state.phase,
  count = state.consecutive_violations,
  lease = state.fallback_lease,
}
local target = state.phase == 'finalized' and 'reframing' or state.resume_phase
state.epoch = state.epoch + 1
state.fallback_lease = nil
state.consecutive_violations = 0
state.phase = target
local attempt = {
  confirmed = false,
  constructed = false,
  generation = nil,
  request_token = nil,
  epoch = state.epoch,
}
state.resume_attempt = attempt
chat:remove_tagged_message(Constants.corrective_tag)

local ok = pcall(chat.submit, chat, {})
local token = attempt.request_token
local confirmed = ok
  and state.resume_attempt == attempt
  and attempt.confirmed
  and attempt.constructed
  and token ~= nil
  and not token.invalidated
  and state.epoch == attempt.epoch
  and (
    (state.active_request_token == token and chat.current_request ~= nil)
    or token.settled == true
  )
state.request_handle = confirmed and chat.current_request or nil
if state.resume_attempt == attempt then
  state.resume_attempt = nil
end
if not confirmed then
  local preserve_internal_halt = state.phase == 'halted' and state.epoch ~= attempt.epoch
  local preserve_reset = state.closed or state.phase == 'dormant'
  if token and state.active_request_token == token then
    local partial = chat.current_request or token.handle
    token.invalidated = true
    state.active_request_token = nil
    chat.current_request = nil
    state.request_handle = nil
    if partial and type(partial.cancel) == 'function' then
      pcall(partial.cancel, partial)
    end
  elseif token then
    token.invalidated = true
  end
  if state.pending_stop_token and state.pending_stop_token.token == token then
    state.pending_stop_token = nil
  end
  local construction = state.construction_lease
  if
    construction
    and construction.epoch == attempt.epoch
    and construction.generation == attempt.generation
  then
    construction.consumed = true
    state.construction_lease = nil
  end
  if attempt.generation == state.request_generation then
    state.completion_classified = true
  end
  if state.epoch == attempt.epoch then
    state.epoch = state.epoch + 1
  end
  if preserve_internal_halt or preserve_reset then
    return false
  end
  state.phase = previous.phase
  state.consecutive_violations = previous.count
  state.fallback_lease = nil
  emit_status(state, ok and 'Reasoning resume did not construct a request' or 'Reasoning resume failed internally')
  return false
end
return true
```

Do not restore the old lease on rollback: incrementing `epoch` intentionally
invalidates automatic recovery once the user attempts explicit recovery. The
`on_submitted` callback from Task 8 flips `confirmed` synchronously before the
preserved submit returns, but that callback alone is not success: pinned
`Chat:submit` dispatches it before `_submit_http` constructs the handle. The
Task 8 `_submit_http` wrapper must set `constructed=true` and bind its exact
token on the live `resume_attempt` before invoking the preserved transport.
Accept either that token still owning a nonnil current handle or that exact
token having completed synchronously. This closes the `on_submitted`-only false
positive without misclassifying a valid synchronous custom request. A failed
attempt explicitly settles its recorded generation and consumes its exact
construction lease before rollback. If Task 8 already incremented epoch and
entered `halted` for an internal construction failure, preserve that halt and
its diagnostic; rollback must never erase a fail-closed internal error.
Likewise, a clear or close that wins during the attempt keeps its dormant/closed
state instead of being rolled back into a recovery phase.

- [ ] **Step 5: Run, format, and re-run resume tests**

```bash
make test_file FILE=tests/codecompanion/_extensions/reasoning/control_test.lua
make test_file FILE=tests/codecompanion/_extensions/reasoning/transition_test.lua
make format
make test_file FILE=tests/codecompanion/_extensions/reasoning/control_test.lua
```

Expected: all command and transaction cases pass. Assert the phase observed
inside preserved submit is already `reframing` for post-final recovery.

- [ ] **Step 6: Commit explicit recovery**

```bash
git add lua/codecompanion/_extensions/reasoning/control.lua tests/codecompanion/_extensions/reasoning/control_test.lua
git commit -m "feat(reasoning): add explicit resume command"
```

### Task 10: Stage, record, commit, and emit final synthesis exactly once

**Files:**
- Modify: `lua/codecompanion/_extensions/reasoning/protocol.lua`
- Modify: `lua/codecompanion/_extensions/reasoning/output.lua`
- Modify: `lua/codecompanion/_extensions/reasoning/control.lua`
- Modify: `tests/codecompanion/_extensions/reasoning/tools/synthesis_test.lua`
- Modify: `tests/codecompanion/_extensions/reasoning/output_test.lua`
- Modify: `tests/codecompanion/_extensions/reasoning/control_test.lua`
- Modify: `tests/codecompanion/_extensions/reasoning/runtime_integration_test.lua`

- [ ] **Step 1: Add failing protocol final-stage tests**

Extend `synthesis_test.lua` with a gate-complete fixture and assert that a
controlled call prepares but does not allocate:

```lua
local workspace = State.get(chat)
local revision = workspace.revision
local sequence = workspace.next_sequence.synthesis
local result = Protocol.call('synthesis', chat, final_args(), 'active')

eq(result.status, 'success')
eq(result.data.artifact.id, 'S1')
eq(result.data._reasoning_final.stage.candidate.id, 'S1')
eq(type(result.data._reasoning_final.markdown), 'string')
eq(workspace.revision, revision)
eq(workspace.next_sequence.synthesis, sequence)
eq(State.find(workspace, 'S1'), nil)
```

Also prove:

- a discarded stage consumes no revision or ID;
- mutation between prepare and commit returns `transaction_conflict`;
- a renderer throw, nil return, or blank-string return yields
  `render_internal`, `committed=false`, no stage, no ID consumption, and no
  standalone commit;
- checkpoint synthesis remains immediately committed;
- a standalone final call with no controller phase validates/renders and commits
  immediately for backward-compatible individual-tool use, and output installs
  the legacy one-shot terminal guard rather than assuming a controller exists.

- [ ] **Step 2: Add failing output and post-record controller tests**

In `output_test.lua`, spy on `Control.stage_final` and assert:

- the exact internal object is passed before `chat:add_tool_output`;
- `_reasoning_final` and Markdown are absent from decoded `for_llm`;
- a staged final uses `for_user=''`;
- a missing/malformed/refused stage becomes `internal_error` and discards the
  prepared transaction;
- a standalone final has no internal stage, records normally, and installs
  `Terminal` exactly once only when `Control.legacy_terminal_allowed(chat)` is
  true;
- complete-before-install, installed-unsupported, incomplete-sticky, and
  otherwise enforcing controller states use the `blocked` lifecycle sentinel,
  commit no standalone final, and never install the legacy guard;
- non-final user output remains `Recorded <ID>; next: <tool>`;
- every output-generated internal error includes `committed=false`;
- the special `tools.status='terminal'` path is gone.

In `control_test.lua`, assert:

- stage binds generation, epoch, primary call ID, response call ID, workspace
  object/revision, reserved ID, and Markdown;
- the host result is recorded before state commit;
- classification reads content after `on_tool_output` mutation;
- a matching result commits the reserved ID, then adds one assistant history
  message, then emits one buffer message through the captured original;
- duplicate output callbacks do not re-commit or re-render;
- missing/mismatched record, call, payload ID, or workspace revision discards,
  records or rewrites a public `internal_error` for that call, and halts without
  model prose;
- history or buffer emission failure restores snapshots, calls
  `State.rollback_final`, rewrites the tool result to `internal_error`, and
  leaves no accepted synthesis;
- `ToolsFinished` or subscriber submit after final is settled without a new
  request.
- a renderer throw, nil return, or blank-string return records
  `render_internal`, commits no synthesis, leaves no stage or Markdown, halts
  with `resume_phase='active'`, and never reaches `finalized`.

In `runtime_integration_test.lua`, keep the existing literal-`none` loop
regression but make its scope explicit: a partial-tool chat uses `Terminal` for
one legacy continuation and then settles `workspace_finalized`; a complete
controlled chat never installs that guard or starts the continuation.

- [ ] **Step 3: Run the three focused files and verify RED**

```bash
make test_file FILE=tests/codecompanion/_extensions/reasoning/tools/synthesis_test.lua
make test_file FILE=tests/codecompanion/_extensions/reasoning/output_test.lua
make test_file FILE=tests/codecompanion/_extensions/reasoning/control_test.lua
```

Expected: FAIL because final synthesis still allocates synchronously and the
terminal guard submits another model turn.

- [ ] **Step 4: Prepare controlled final synthesis in `Protocol.synthesis`**

Change `Protocol.call` to invoke `handler(chat, args, lifecycle_phase)`; other
handlers safely ignore the extra argument. Change synthesis to accept the
optional phase. After all existing validation and final gates, build relations
without mutating state. Require the renderer at module scope:

```lua
local Render = require('codecompanion._extensions.reasoning.render')
```

```lua
local relations = {
  supports = {},
  contradicts = {},
  qualifies = {},
  depends_on = { workspace.frame_id },
  tests = {},
  supersedes = {},
}
local supports = {}
for _, id in ipairs(args.support_ids) do
  if not supports[id] then
    supports[id] = true
    table.insert(relations.supports, id)
  end
end
for _, criterion in ipairs(args.criterion_results) do
  for _, id in ipairs(criterion.evidence_ids) do
    if not supports[id] then
      supports[id] = true
      table.insert(relations.supports, id)
    end
  end
end
vim.list_extend(relations.depends_on, args.selected_option_ids)
vim.list_extend(relations.depends_on, args.review_ids)
for _, target_id in ipairs(workspace.artifact_order) do
  local target = State.find(workspace, target_id)
  if
    workspace.open_revisions[target_id]
    and target
    and target.status == 'active'
    and target.kind == 'synthesis'
  then
    table.insert(relations.supersedes, target_id)
  end
end
```

Checkpoint mode continues through the ordinary `State.add` mutation path. For
final mode:

```lua
local synthesis_data = vim.deepcopy(args)
synthesis_data.frame_id = workspace.frame_id
local stage, code = State.prepare_final(chat, synthesis_data, relations)
if not stage then
  return failure(code, 'the final synthesis could not be prepared', {}, Guidance.next(workspace, args))
end

local rendered, markdown = pcall(Render.render, workspace, stage.candidate.data)
if not rendered or type(markdown) ~= 'string' or vim.trim(markdown) == '' then
  State.discard_final(stage)
  return failure(
    'render_internal',
    'the deterministic final could not be rendered',
    {},
    { tool = 'reasoning_synthesis', reason = 'Resume after inspecting the plugin failure' }
  )
end

if lifecycle_phase == nil then
  local committed, commit_code = State.commit_final(chat, stage)
  if not committed then
    return failure(commit_code, 'the final synthesis transaction conflicted', {}, Guidance.next(workspace, args))
  end
  return success_payload(workspace, committed, {}, {
    tool = 'none', reason = 'Final synthesis accepted; no further model action is permitted',
  })
end

local projected_progress = vim.deepcopy(workspace.counts_by_kind)
projected_progress.synthesis = (projected_progress.synthesis or 0) + 1
return {
  status = 'success',
  data = {
    workspace_id = workspace.id,
    artifact = vim.deepcopy(stage.candidate),
    progress = projected_progress,
    unmet_gates = {},
    next_action = {
      tool = 'none', reason = 'Final synthesis accepted; no further model action is permitted',
    },
    _reasoning_final = { stage = stage, markdown = markdown },
  },
}
```

Extract the shared result construction before using it:

```lua
local function success_payload(workspace, artifact, unmet_gates, next_action)
  return {
    status = 'success',
    data = {
      workspace_id = workspace.id,
      artifact = vim.deepcopy(artifact),
      progress = vim.deepcopy(workspace.counts_by_kind),
      unmet_gates = unmet_gates or M.final_gates(workspace, nil),
      next_action = next_action or Guidance.next(workspace),
    },
  }
end
```

Make the existing `success` delegate to this helper so standalone and
checkpoint shapes stay identical. Rendering is validation: catch its
exception, nil return, or blank return before either controlled staging or
standalone commit. Log a thrown traceback internally, but return only the fixed
safe message for every renderer failure.

- [ ] **Step 5: Strip internal data and stage before recording output**

Retain `Terminal` and require `Control` and `State`. Add:

```lua
local function public_payload(payload)
  local result = {}
  for key, value in pairs(payload) do
    if key ~= '_reasoning_final' then
      result[key] = value
    end
  end
  return result
end
```

For a validated terminal final, encode `public_payload(payload)`, validate the
internal stage, and call `Control.stage_final(meta.tools.chat, tool, internal)`
before `add_tool_output`. If validation/staging fails, call
`State.discard_final(internal and internal.stage)` before emitting an internal
error. A staged final records with `for_user=''`; a standalone already-committed
final without `_reasoning_final` uses the ordinary bounded user message and
calls `Terminal.install(meta.tools)` only when
`Control.legacy_terminal_allowed(meta.tools.chat)` returns true. Otherwise it
must not create a second submit wrapper. Never install `Terminal` when the
internal controlled stage is present, so wrapper order cannot vary.

Add `committed=false` to `internal_payload`. Remove error-side terminal status;
the controller's halt/final phases settle host auto-submit uniformly.

- [ ] **Step 6: Bind and verify the final stage in the controller**

Implement `Control.stage_final`:

```lua
function M.stage_final(chat, tool, finalization)
  local state = controllers[chat]
  local call = type(tool) == 'table' and tool.function_call or nil
  local marker = state and type(call) == 'table' and state.call_tokens[call] or nil
  local stage = finalization and finalization.stage
  if
    not state
    or state.closed
    or state.unsupported_adapter
    or state.phase ~= 'active'
    or type(tool) ~= 'table'
    or tool.name ~= 'reasoning_synthesis'
    or type(call) ~= 'table'
    or type(call.id) ~= 'string'
    or call.id == ''
    or not marker
    or marker.status ~= 'executing'
    or marker.epoch ~= state.epoch
    or marker.generation ~= state.request_generation
    or marker.operation ~= 'synthesis'
    or type(stage) ~= 'table'
    or stage.state ~= 'prepared'
    or type(stage.workspace) ~= 'table'
    or stage.workspace ~= State.get(chat)
    or stage.revision ~= stage.workspace.revision
    or type(stage.candidate) ~= 'table'
    or stage.candidate.kind ~= 'synthesis'
    or type(stage.candidate.data) ~= 'table'
    or stage.candidate.data.mode ~= 'final'
    or stage.workspace_id ~= stage.workspace.id
    or stage.reserved_id ~= stage.candidate.id
    or type(finalization.markdown) ~= 'string'
    or vim.trim(finalization.markdown) == ''
  then
    return nil, 'reasoning final stage is unavailable'
  end
  state.staged_final = {
    generation = state.request_generation,
    epoch = state.epoch,
    call_id = call.id,
    response_call_id = call.call_id,
    marker = marker,
    workspace = stage.workspace,
    revision = stage.revision,
    reserved_id = stage.reserved_id,
    stage = stage,
    markdown = finalization.markdown,
  }
  state.phase = 'finalizing'
  state.fallback_lease = nil
  chat:remove_tagged_message(Constants.corrective_tag)
  chat.subscribers:stop()
  return true
end
```

In the post-record `add_tool_output` wrapper, handle a matching staged final
before generic progress classification. Verify generation/epoch/call IDs,
exact marker identity/status, decoded public `workspace_id`,
`artifact.id == reserved_id`, `vim.deep_equal(artifact, stage.candidate)`,
terminal next action,
exact stage workspace/revision, and the matching history result. Call the
captured host method under `xpcall`; a pre-record throw must discard the stage,
settle an internal-error record directly, and halt rather than leaving
`finalizing`. Any mismatch rewrites the matching invocation delta—or inserts
the missing internal response using Task 8's settlement helper—to a public
`internal_error` with `committed=false`, recomputes the exact role/content hash,
discards the stage, clears it, and halts with `resume_phase='active'` without
spending budget. Add a hostile rewrite test that changes only the conclusion or
citations while preserving the final artifact ID/kind/mode; it must fail this
deep-equality check and never commit or render the tampered payload.

- [ ] **Step 7: Commit and emit with compensating rollback**

After post-record verification, snapshot `#chat.messages` and all current buffer
lines. Call `State.commit_final(chat, staged.stage)`. If it returns no artifact,
rewrite the recorded result to `internal_error`, clear the stage, and halt
without emitting. Otherwise run these two emissions under one `pcall`:

```lua
chat:add_message({
  role = require('codecompanion.config').constants.LLM_ROLE,
  content = staged.markdown,
}, { visible = true })
state.methods.add_buf_message.original(chat, {
  role = require('codecompanion.config').constants.LLM_ROLE,
  content = staged.markdown,
}, { type = chat.MESSAGE_TYPES.LLM_MESSAGE })
```

On success, clear `staged_final`, mark its ID classified, reset violations,
enter `finalized`, and leave wrappers installed. On failure:

1. truncate only messages added after the recorded tool-result snapshot;
2. restore the exact buffer-line snapshot with `nvim_buf_set_lines` when valid;
3. call `State.rollback_final(chat, staged.stage)` and assert it succeeds;
4. rewrite only this invocation's tool-result delta to `internal_error`, retain
   any pre-existing reused-ID prefix, and recompute exactly
   `hash.hash({ role = message.role, content = message.content })`;
5. clear stage and halt with `resume_phase='active'`;
6. emit no model prose.

This compensation is guarded by the exact revision/last-ID checks from Task 1,
and `finalizing` blocks every competing mutation. It closes the host's lack of
a cross-history/buffer/workspace transaction without making rollback generally
available.

- [ ] **Step 8: Verify controlled and legacy terminal paths stay disjoint**

Assert complete/enforcing controller scenarios never install
`_codecompanion_reasoning_terminal_guard`, while dormant partial-tool and
controller-absent partial-tool scenarios still get one bounded legacy
continuation. Then run the focused files and the full suite; retaining the
guard keeps every pre-autocmd integration commit green:

```bash
make test_file FILE=tests/codecompanion/_extensions/reasoning/state_test.lua
make test_file FILE=tests/codecompanion/_extensions/reasoning/render_test.lua
make test_file FILE=tests/codecompanion/_extensions/reasoning/tools/synthesis_test.lua
make test_file FILE=tests/codecompanion/_extensions/reasoning/output_test.lua
make test_file FILE=tests/codecompanion/_extensions/reasoning/control_test.lua
make format
make test
```

Expected: all focused files and the full suite pass, the internal field never
appears in JSON, controlled chats perform no post-final request, and only a
partial-tool chat uses the compatibility guard.

- [ ] **Step 9: Commit atomic finalization**

```bash
git add lua/codecompanion/_extensions/reasoning/protocol.lua lua/codecompanion/_extensions/reasoning/output.lua lua/codecompanion/_extensions/reasoning/control.lua tests/codecompanion/_extensions/reasoning/tools/synthesis_test.lua tests/codecompanion/_extensions/reasoning/output_test.lua tests/codecompanion/_extensions/reasoning/control_test.lua tests/codecompanion/_extensions/reasoning/runtime_integration_test.lua
git commit -m "feat(reasoning): finalize accepted output atomically"
```

### Task 11: Make clear, uninstall, and close safe under late callbacks

**Files:**
- Modify: `lua/codecompanion/_extensions/reasoning/control.lua`
- Modify: `tests/codecompanion/_extensions/reasoning/control_test.lua`

- [ ] **Step 1: Add failing clear, restoration, and tombstone tests**

Add cases for:

- clear during a request and during tool execution cancels both, discards a
  prepared final, removes correction/lease, deletes only that chat workspace,
  invalidates active/pending request tokens and resume attempts, increments
  epoch without inventing a submitted generation, and enters `dormant`;
- cancellation-driven `Tools:reset` may run before preserved `Chat:clear`, but
  the final cleared buffer/cycle/header remains exactly the host's clean render;
- synchronous request/orchestrator cancellation callbacks that call `submit`
  during clear are settled by `state.clearing` and start no generation;
- dormant wrappers delegate a new ordinary request/output unchanged;
- one to four reattached reasoning tools remain dormant, while the fifth HTTP
  attachment re-enters `armed` with a fresh workspace;
- a late result/done from the invalidated generation is ignored before and
  after rearm, even when its call ID is reused only in old history;
- live settled uninstall restores raw methods, removes raw wrappers to reveal
  inherited methods, removes exact callbacks/command, and is idempotent;
- uninstall refuses an active request, orchestrator, or staged final;
- uninstall also refuses token-only construction, queued stopped cleanup, or
  an executing scope, cancellation handle, fallback lease, active
  construction/`submitting` lease, or unsettled/unclassified completion even when
  `current_request` is nil;
- the instance `close` wrapper sets `closed` before pinned `Chat:close()` calls
  `stop`; an orchestrator left without a request is cleared before controller
  cancellation; callbacks/command/workspace are cleaned afterward;
- late submit, done, buffer output, tool output, tool execution,
  `ToolsFinished`, and subscriber callbacks after close are all no-ops;
- close retains raw tombstone wrappers rather than exposing original methods.
- a partial final followed by host clear removes the legacy terminal guard, so
  the next ordinary submit is not trapped by stale compatibility state.

Use cancellation fakes that synchronously invoke late callbacks to prove the
ordering, not only final field values.

- [ ] **Step 2: Run the controller tests and verify RED**

```bash
make test_file FILE=tests/codecompanion/_extensions/reasoning/control_test.lua
```

Expected: FAIL because clear and close still leave live retry/generation paths.

- [ ] **Step 3: Implement explicit clear reset with dormant wrappers**

Use one private reset path so the pre-host wrapper and post-host event cannot
reset twice. `reset_for_clear(state, chat)` must execute in this order:

```lua
local function reset_for_clear(state, chat)
  local token = state.active_request_token
  if token then
    token.invalidated = true
  end
  if state.pending_stop_token and state.pending_stop_token.token then
    state.pending_stop_token.token.invalidated = true
  end
  if state.construction_lease then
    state.construction_lease.consumed = true
  end
  state.construction_lease = nil
  state.active_request_token = nil
  state.pending_stop_token = nil
  Terminal.clear(chat)
  state.epoch = state.epoch + 1
  state.submitting = false
  state.completion_classified = true
  state.fallback_lease = nil
  state.resume_attempt = nil
  if state.staged_final then
    State.discard_final(state.staged_final.stage)
  end
  state.staged_final = nil
  chat:remove_tagged_message(Constants.corrective_tag)

  local request = chat.current_request or (token and token.handle) or state.request_handle
  chat.current_request = nil
  state.request_handle = nil
  if request and type(request.cancel) == 'function' then
    pcall(request.cancel, request)
  end
  local orchestrator = chat.tool_orchestrator
  chat.tool_orchestrator = nil
  if orchestrator and type(orchestrator.cancel) == 'function' then
    pcall(orchestrator.cancel, orchestrator)
  end

  State.clear(chat)
  state.consecutive_violations = 0
  state.resume_phase = 'active'
  state.suspended_phase = nil
  state.unsupported_adapter = false
  state.phase = 'dormant'
  return true
end

function M.clear(chat)
  local state = controllers[chat]
  if not state or state.closed then
    Terminal.clear(chat)
    State.clear(chat)
    return false
  end
  if state.clearing then
    return false
  end
  state.clearing = true
  local ok, result = xpcall(function()
    return reset_for_clear(state, chat)
  end, debug.traceback)
  state.clearing = false
  if not ok then
    error(result, 0)
  end
  return result
end
```

Retain old `observed_call_ids` buckets and weak `call_tokens`; each marker
includes the epoch in which it was created, so a late post-clear output is
rejected by exact call identity before host delegation even though clear does
not fabricate a submitted request generation. The invalidated request proxy
also drops late stream, status, error, and done callbacks. Do not delegate any
of them.
Install the clear wrapper as:

```lua
local unpack_values = table.unpack or unpack

local function pack(...)
  return { n = select('#', ...), ... }
end

local function unpack_after_status(values)
  return unpack_values(values, 2, values.n)
end

local function wrapped_clear(state, chat, ...)
  if state.closed then
    return nil
  end
  local args = pack(...)
  state.clearing = true
  local result = pack(xpcall(function()
    reset_for_clear(state, chat)
    return state.methods.clear.original(chat, unpack(args, 1, args.n))
  end, debug.traceback))
  state.clearing = false
  if not result[1] then
    error(result[2], 0)
  end
  return unpack_after_status(result)
end
```

The `CodeCompanionChatCleared` callback sees `clearing=true` and returns without
resetting twice. Use `xpcall` plus a finally-style assignment so `clearing`
cannot remain true if the preserved host clear throws; `pack` and
`unpack_after_status` preserve all Lua 5.1 return values. Reconciliation moves an
existing dormant state to `armed` only after all five tools are present on
HTTP. Dormant ordinary activity uses new generation buckets and delegates
unchanged.

- [ ] **Step 4: Implement conservative live uninstall**

Return `false` unless the state exists, is open, and has no current request,
stored request handle, active request token, pending stop token, executing
scope, orchestrator, fallback lease, submit-construction lease, resume attempt,
or staged final, and `completion_classified == true`. In field terms,
`fallback_lease == nil`, `construction_lease == nil`, and
`submitting == false`; scheduled callbacks are safe
only because they compare the captured lease object before acting. Remove every
callback with `chat:remove_callback(name, exact_function)`, delete the command,
and call `restore_method` for all eight slots. Only then remove
`controllers[chat]`. Preserve the reasoning workspace: uninstall controls host
lifecycle ownership, not the user's accepted audit data.

- [ ] **Step 5: Install closed tombstone behavior before cancellation**

Pinned `Chat:close()` calls `stop()` before `on_closed`, so the captured close
slot—not the callback—is the required first boundary. Its wrapper must set
`closed=true`, call `Terminal.clear(chat)` to expose the controller submit
tombstone, mark the active and pending request tokens invalid, clear them,
consume/clear any construction lease, increment epoch, clear `submitting`,
settle completion, and invalidate
lease/resume/stage/correction before delegating once to the captured original.
The host then performs its normal request cancellation and adapter/MCP cleanup;
every other controller wrapper already sees `closed` and returns immediately.

The exact `on_closed` callback, reached inside that preserved close call, must:

1. save and clear any tool orchestrator that remains after host stop, then
   cancel the saved object;
2. clear the stored request handle without re-running an already completed host
   cancellation;
3. remove all exact callbacks and the buffer command;
4. call `State.clear(chat)`;
5. leave all eight raw wrapper fields and `controllers[chat]` in place as weak
   tombstones.

Keep the callback idempotent as a fallback for a host-driven close notification
that reaches it without the wrapper: if `closed` is still false, perform the
same pre-delegation invalidation before cleanup.

Do not call `restore_method` or remove the weak state on close. A scheduled host
callback must see `closed` rather than an exposed original method after the
buffer has been deleted, including callbacks retained by the per-request
`_submit_http` proxy.

- [ ] **Step 6: Run, format, and re-run cleanup tests**

```bash
make test_file FILE=tests/codecompanion/_extensions/reasoning/control_test.lua
make test_file FILE=tests/codecompanion/_extensions/reasoning/state_test.lua
make format
make test_file FILE=tests/codecompanion/_extensions/reasoning/control_test.lua
```

Expected: all cancellation-order and tombstone cases pass, and weak state is
collectable after the closed chat loses its last strong reference.

- [ ] **Step 7: Commit lifecycle cleanup**

```bash
git add lua/codecompanion/_extensions/reasoning/control.lua tests/codecompanion/_extensions/reasoning/control_test.lua
git commit -m "feat(reasoning): clean lifecycle state safely"
```

### Task 12: Wire host events and reproduce the abandoned structured run end to end

**Files:**
- Modify: `lua/codecompanion/_extensions/reasoning/control.lua`
- Modify: `lua/codecompanion/_extensions/reasoning/init.lua`
- Modify: `tests/codecompanion/_extensions/reasoning/init_test.lua`
- Modify: `tests/codecompanion/_extensions/reasoning/runtime_integration_test.lua`

- [ ] **Step 1: Add failing idempotent-autocmd tests**

In `init_test.lua`, call `Extension.setup()` twice, inspect
`vim.api.nvim_get_autocmds({ group=Constants.augroup })`, and assert exactly one
callback exists for each pinned pattern:

```lua
eq(patterns.CodeCompanionChatToolAdded, 1)
eq(patterns.CodeCompanionChatAdapter, 1)
eq(patterns.CodeCompanionChatCleared, 1)
```

Patch `CodeCompanion.buf_get_chat` to return a fake chat for its buffer, fire
each `User` event, and assert tool/adapter events reconcile while clear invokes
the dormant reset. A missing/deleted buffer must be a no-op.

- [ ] **Step 2: Upgrade the runtime fixture before adding scenarios**

Extend `new_chat` with the pinned host contract rather than controller-specific
shortcuts:

- `adapter` on the chat and an HTTP `format_response` shape with `tools.call_id`;
- callback add/remove/dispatch and cancellable dispatch;
- `MESSAGE_TYPES`, `status`, `current_request`, `subscribers`, `restore`,
  `header_line`, `parsers`, `_btw`, `close`, and buffer-output recording;
- `done` that records formatted assistant calls before `tools:execute`;
- `add_tool_output` that dispatches mutable `on_tool_output`, records a matching
  tool response in `messages`, and records visible output only when nonempty;
- `submit` that creates one payload, synchronously dispatches
  `on_submitted(chat, { payload=payload })`, and passes that exact table to an
  actual fake `_submit_http(payload)` method; `_submit_http` must retain the `self` it
  receives so tests can invoke token-bound proxy stream/status/done callbacks,
  assign request handles through that proxy, and simulate a callback that
  completes synchronously before the handle is returned;
- a buffer-to-chat lookup used by real synchronous `ChatToolAdded` events;
- `Control._reset()` in both hooks and restoration of patched host globals.

Keep real `ToolRegistry` and `ToolRuntime` so invalid JSON, reset/on-ready,
approval, YOLO, and formatted execution exercise v19.22.0 behavior.

- [ ] **Step 3: Add the fail-closed runtime regression scenarios**

Replace complete-group terminal-guard expectations with these named cases,
while retaining Task 10's separate partial-tool compatibility case:

1. Attach the group, run multiple external search/read calls before frame and
   between accepted artifacts, and prove transition/budget is unchanged.
2. Complete separately with text only, reasoning only, and empty success
   immediately after attachment; prove no history or buffer prose and exactly
   one retry for each.
3. Attach on ACP; prove one unsupported status and no protected request. Switch
   HTTP to ACP before the first call, prove blocked, then switch back and resume
   the original phase.
4. Clear request A during active work, prove dormant ordinary delegation, then
   reattach the fifth tool and start B. After B's handle reports success,
   deliver A's retained proxy stream/status/done plus an old tool output whose
   string call ID B reused; prove B and the fresh workspace are untouched, then
   complete B exactly once.
5. Reproduce the failed sequence exactly: accepted frame, rejected evidence,
   a call citing its nonexistent rejected ID, out-of-order synthesis, then an
   attempted prose answer. Assert no rejected ID is allocated, no prose reaches
   history/buffer, and the third consecutive counted violation halts without a
   fourth request.
6. Prove bare submit remains blocked, while the buffer-local resume command
   submits nonblank unsent user text against the intact workspace.
7. Run the full deep frame/evidence/options/checkpoint/review/final flow. Assert
   the final host tool result precedes the rendered assistant message, internal data is absent, the workspace
   commits once, renderer Markdown appears once, controller is finalized, and
   submit count does not increase.
8. Resume after final, keep all streamed prose suppressed through external
   investigation, accept only revise/replace, retire downstream history, and
   return active.
9. Close during asynchronous reasoning/finalization and prove late tool,
   completion, subscriber, and scheduled retry callbacks change nothing.

For the completed-flow case, compute expected Markdown before invoking the
final tool:

```lua
local expected = Render.render(State.get(chat), final_args())
local submits = chat.submit_count
local result = invoke(chat, 'reasoning_synthesis', final_args())
local public = vim.json.decode(result.for_llm)

eq(public.artifact.id, 'S2')
eq(public._reasoning_final, nil)
eq(State.get(chat).counts_by_kind.synthesis, 2)
eq(Control._get(chat).phase, 'finalized')
eq(Control._get(chat).staged_final, nil)
eq(chat.submit_count, submits)

local rendered = vim.tbl_filter(function(message)
  return message.role == CCConfig.constants.LLM_ROLE and message.content == expected
end, chat.messages)
eq(#rendered, 1)
```

- [ ] **Step 4: Connect setup to the controller only after valid config**

In `init.lua`, call `Control.setup_autocmds()` immediately after successful
`Config.setup(user_options)` and before tool registration. A configuration
validation error must leave the previous autocmd group unchanged. Repeated
valid setup replaces the group but does not reset controllers already attached
to live chats.

Finish the test-only `Control._reset()` so it safely uninstalls live settled
controllers, marks busy ones closed, clears weak notification/controller maps,
and deletes `Constants.augroup`. Production code never calls `_reset`.

- [ ] **Step 5: Run focused integration, then the full suite**

```bash
make test_file FILE=tests/codecompanion/_extensions/reasoning/init_test.lua
make test_file FILE=tests/codecompanion/_extensions/reasoning/runtime_integration_test.lua
make format
make test
```

Expected: init and runtime integration pass, followed by the entire suite with
zero failures and notes. Record the new total case count in the commit handoff;
do not retain the old 161-case expectation after adding coverage.

- [ ] **Step 6: Commit host lifecycle integration**

```bash
git add lua/codecompanion/_extensions/reasoning/control.lua lua/codecompanion/_extensions/reasoning/init.lua tests/codecompanion/_extensions/reasoning/init_test.lua tests/codecompanion/_extensions/reasoning/runtime_integration_test.lua
git commit -m "test(reasoning): enforce fail-closed runtime flow"
```

### Task 13: Document the enforced contract and run release-level verification

**Files:**
- Modify: `README.md`
- Modify: `docs/superpowers/specs/2026-08-01-structured-reasoning-tools-design.md`
- Verify: `docs/superpowers/specs/2026-08-05-fail-closed-structured-reasoning-design.md`

- [ ] **Step 1: Rewrite README claims around the actual enforcement boundary**

Update the opening, Requirements, Workflow, Error semantics, Configuration,
and Privacy/scope sections with these exact facts:

- attaching all five tools to an HTTP chat synchronously arms a fail-closed
  protocol and commits that chat's final-answer path to deterministic rendering;
- ACP is explicitly unsupported because v19.22.0 does not transmit registered
  client schemas through that transport; adapter switching blocks rather than
  falsely claiming enforcement;
- external project search, file reads, commands, diagnostics, and other tools
  are unrestricted before frame and between artifacts, and success/failure is
  budget neutral;
- the first reasoning call is frame/start and later reasoning calls must be the
  sole call in their completion and match the authoritative transition;
- free-form model output is suppressed; accepted structured artifacts are the
  only final source;
- errors include `committed=false` and a safe field diagnostic, and rejected IDs
  never exist;
- violations one/two receive a bounded correction, violation three halts, and
  recovery requires nonblank unsent text plus
  `:CodeCompanionReasoningResume`;
- final synthesis is staged until its matching host result is recorded, then
  rendered once with no post-final model request;
- post-final ordinary submit remains blocked; explicit resume enters reframing
  and requires revise/replace;
- the retry budget is fixed at three and intentionally not configurable;
- individual/partial tool attachment retains the legacy one-shot terminal
  behavior and is explicitly outside the fail-closed guarantee; the second
  submit wrapper is never installed on a controlled complete-tool chat;
- the sole extension UI command is the buffer-local resume command; the plugin
  still does no file discovery, project-memory access, secondary model calls,
  or private chain-of-thought capture.

Include a concise public error example:

```json
{
  "code": "evidence_invalid",
  "committed": false,
  "artifact_ids": [],
  "diagnostic": {
    "path": "items",
    "constraint": "max_items",
    "expected": 8,
    "actual": 10
  },
  "next_action": {
    "tool": "reasoning_evidence",
    "reason": "Record a bounded evidence batch"
  }
}
```

Add one renderer example that visibly orders Conclusion, selected branch,
Supporting evidence, Adversarial review, Success criteria, optional reflection
sections, and Confidence. State that model-supplied Markdown/HTML is escaped.

- [ ] **Step 2: Mark the older design as superseded and verify the approved contract**

Append this limitation to the 2026-08-01 design:

```markdown
- The fail-closed lifecycle, bounded recovery, deterministic rendering, and
  authoritative transition enforcement are provided only for supported HTTP
  chats by the superseding 2026-08-05 design. Prompt sequencing is guidance,
  not the enforcement boundary, and ACP remains unsupported by this controller.
```

Do not rewrite the historical design into the new design; make the supersession
explicit so future readers do not mistake its terminal wrapper for the
complete-tool architecture.

Re-read the approved 2026-08-05 design and verify the implementation still
matches its committed contract: status `Approved for implementation`; captured
`clear`, `close`, and `_submit_http` methods; request-token and exact call-table
identity fields; pre-event clear/close interposition; and the partial-tool
terminal compatibility boundary. Do not edit the approved design merely to
describe implementation details. If the implementation requires a contract
change, stop and obtain design review before updating it.

- [ ] **Step 3: Run static acceptance scans**

```bash
rg -n 'reasoning\.terminal|Terminal\.' lua tests
rg -n 'return the accepted conclusion|tools\.status = .terminal.' lua README.md
rg -n '_reasoning_final' lua tests
git diff --exit-code -- docs/superpowers/specs/2026-08-05-fail-closed-structured-reasoning-design.md
git diff --check
```

Expected: the terminal scan finds only `terminal.lua`, explicit partial-tool
branches in protocol/output, compatibility tests, and `Terminal.clear` handoff/
cleanup calls in `control.lua`; `control.lua` must never call
`Terminal.install` or capture a live guard. The second scan returns no obsolete
prompt or `tools.status='terminal'` behavior. The internal-field scan finds
only the protocol/output/controller implementation and explicit non-leakage
tests; inspect each match to confirm no encoded/history fixture contains the
private stage. `git diff --check` prints nothing.

- [ ] **Step 4: Run formatter and the complete test suite**

```bash
make format
git diff --check
NVIM_LOG_FILE=/tmp/codecompanion-reasoning-final.log make test
```

Expected: formatting succeeds, diff check is silent, and every MiniTest case
passes with zero failures and notes. Inspect the final log only if the command
reports a failure; do not claim the old 161-case baseline as the new total.

- [ ] **Step 5: Commit documentation**

```bash
git add README.md docs/superpowers/specs/2026-08-01-structured-reasoning-tools-design.md
git commit -m "docs(reasoning): explain fail-closed execution"
```

- [ ] **Step 6: Verify the committed branch is clean and reproducible**

```bash
git status --short
git log --oneline --decorate -13
NVIM_LOG_FILE=/tmp/codecompanion-reasoning-post-commit.log make test
```

Expected: status is empty, the planned commits are visible in order, and the
post-commit suite again passes with zero failures and notes. Record the actual
case count and CodeCompanion tag `v19.22.0` in the implementation handoff.
