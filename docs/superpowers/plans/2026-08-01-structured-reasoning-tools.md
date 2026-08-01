# Structured Reasoning Tools Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the legacy extension with five deterministic, chat-scoped tools that guide difficult reasoning through framing, evidence, alternatives, adversarial review, and gated synthesis.

**Architecture:** Register one native CodeCompanion `reasoning` tool group. Each focused tool delegates to a shared protocol engine backed by a weak-key, per-chat artifact store; a deterministic guidance module returns the next required action, and a shared output module adapts results to CodeCompanion v19.22.0. No legacy subsystem or compatibility alias remains.

**Tech Stack:** Lua 5.1/LuaJIT, Neovim APIs, CodeCompanion v19.22.0 tool APIs, MiniTest, StyLua.

---

## Execution prerequisite

Execute this plan in a clean sibling worktree at `/Users/sebastian/workspace/codecompanion-reasoning-rewrite`, created from the commit containing this plan. That location keeps the audited CodeCompanion checkout available at the Makefile's default `../codecompanion.nvim` path. Do not copy the disposable staged or unstaged changes from the original `main` worktree. The implementation branch begins with the approved design at `docs/superpowers/specs/2026-08-01-structured-reasoning-tools-design.md`.

Before Task 1, bootstrap test-only dependencies once:

```bash
command -v nvim
command -v stylua
test -d ../codecompanion.nvim/.git
test "$(git -C ../codecompanion.nvim rev-parse HEAD)" = "2b959b2bf5fdb13e3b333c078ba549996e477b7c"
test "$(git -C ../codecompanion.nvim describe --tags --exact-match)" = "v19.22.0"
make deps
test -f deps/mini.nvim/lua/mini/test.lua
```

`make deps` is the only step permitted to use the network. All deterministic test commands after this bootstrap reuse the populated dependency directories and run without model calls or network access. If the pinned sibling checkout is unavailable, stop and provide another checkout only after verifying both the exact commit and tag above.

## File structure

Create or replace these runtime files:

- `lua/codecompanion/_extensions/reasoning/init.lua` — register tool definitions, the group, and optional default attachment.
- `lua/codecompanion/_extensions/reasoning/config.lua` — validate options and return defensive copies.
- `lua/codecompanion/_extensions/reasoning/state.lua` — isolate bounded append-oriented workspaces by chat.
- `lua/codecompanion/_extensions/reasoning/protocol.lua` — validate and record all five artifact operations and evaluate final gates.
- `lua/codecompanion/_extensions/reasoning/guidance.lua` — select one deterministic next action.
- `lua/codecompanion/_extensions/reasoning/output.lua` — serialize success and error payloads for CodeCompanion.
- `lua/codecompanion/_extensions/reasoning/tools/frame.lua` — expose `reasoning_frame`.
- `lua/codecompanion/_extensions/reasoning/tools/evidence.lua` — expose `reasoning_evidence`.
- `lua/codecompanion/_extensions/reasoning/tools/options.lua` — expose `reasoning_options`.
- `lua/codecompanion/_extensions/reasoning/tools/review.lua` — expose `reasoning_review`.
- `lua/codecompanion/_extensions/reasoning/tools/synthesis.lua` — expose `reasoning_synthesis`.

Create matching tests under `tests/codecompanion/_extensions/reasoning/`. Keep the existing test bootstrap in `scripts/minimal_init.lua`; `tests/helpers.lua` may remain unchanged because the new tests do not depend on its legacy fixture helpers.

Delete all legacy tools, session helpers, UI, commands, fixtures, entry-point wrappers, and project-memory files in Task 9 after the new integration suite passes.

## Shared conventions

- Public tool commands receive `(tools, args, opts)` and use `tools.chat` as the state key.
- Successful operations return `{ status = "success", data = payload }`.
- Expected validation failures return `{ status = "error", data = error_payload }`.
- Error payloads always contain `code`, `message`, `artifact_ids`, and `next_action = { tool, reason }`.
- Artifact IDs use `F`, `E`, `B`, `O`, `R`, and `S` prefixes.
- Runtime modules never read files, create UI, invoke another model, or retain the chat object inside state values.

### Task 1: Replace configuration with strict reasoning options

**Files:**
- Modify: `lua/codecompanion/_extensions/reasoning/config.lua`
- Modify: `tests/codecompanion/_extensions/reasoning/config_test.lua`

- [ ] **Step 1: Replace the old configuration test with failing validation tests**

```lua
local Config = require('codecompanion._extensions.reasoning.config')

local T = MiniTest.new_set()
local eq = MiniTest.expect.equality

T['uses deep, bounded defaults'] = function()
  local options = Config.setup()
  eq(options.auto_attach, false)
  eq(options.default_depth, 'deep')
  eq(options.limits.max_artifacts, 192)
  eq(options.limits.max_batch_items, 8)
  eq(options.limits.max_text_chars, 2000)
  eq(options.limits.max_array_items, 12)
end

T['returns defensive copies'] = function()
  local first = Config.setup()
  first.limits.max_artifacts = 1
  eq(Config.get().limits.max_artifacts, 192)
end

T['rejects invalid values'] = function()
  MiniTest.expect.error(function()
    Config.setup({ default_depth = 'extreme' })
  end, 'default_depth')
  MiniTest.expect.error(function()
    Config.setup({ limits = { max_artifacts = 0 } })
  end, 'max_artifacts')
  MiniTest.expect.error(function()
    Config.setup({ auto_attach = 'yes' })
  end, 'auto_attach')
end

T['rejects unknown options'] = function()
  MiniTest.expect.error(function()
    Config.setup({ session = true })
  end, 'unknown option')
  MiniTest.expect.error(function()
    Config.setup({ limits = { max_nodes = 10 } })
  end, 'unknown limit')
end

return T
```

- [ ] **Step 2: Run the test and verify the legacy configuration fails it**

Run: `make test_file FILE=tests/codecompanion/_extensions/reasoning/config_test.lua`

Expected: FAIL because the old defaults contain session and background-model options and do not validate the new fields.

- [ ] **Step 3: Replace `config.lua` with the minimal validated module**

```lua
local M = {}

local defaults = {
  auto_attach = false,
  default_depth = 'deep',
  limits = {
    max_artifacts = 192,
    max_batch_items = 8,
    max_text_chars = 2000,
    max_array_items = 12,
  },
}

local options = vim.deepcopy(defaults)

local function validate(candidate)
  local allowed_options = { auto_attach = true, default_depth = true, limits = true }
  for name in pairs(candidate) do
    if not allowed_options[name] then
      error('unknown option: ' .. name)
    end
  end
  if type(candidate.auto_attach) ~= 'boolean' then
    error('auto_attach must be a boolean')
  end
  if candidate.default_depth ~= 'standard' and candidate.default_depth ~= 'deep' then
    error("default_depth must be 'standard' or 'deep'")
  end
  if type(candidate.limits) ~= 'table' then
    error('limits must be a table')
  end
  local allowed_limits = {
    max_artifacts = true,
    max_batch_items = true,
    max_text_chars = true,
    max_array_items = true,
  }
  for name, value in pairs(candidate.limits) do
    if not allowed_limits[name] then
      error('unknown limit: ' .. name)
    end
    if type(value) ~= 'number' or value < 1 or value % 1 ~= 0 then
      error(name .. ' must be a positive integer')
    end
  end
end

function M.setup(user_options)
  local candidate = vim.tbl_deep_extend('force', vim.deepcopy(defaults), user_options or {})
  validate(candidate)
  options = candidate
  return vim.deepcopy(options)
end

function M.get()
  return vim.deepcopy(options)
end

return M
```

- [ ] **Step 4: Run the focused test and format the files**

Run: `make test_file FILE=tests/codecompanion/_extensions/reasoning/config_test.lua`

Expected: PASS, 4 cases and 0 failures.

Run: `stylua lua/codecompanion/_extensions/reasoning/config.lua tests/codecompanion/_extensions/reasoning/config_test.lua -f stylua.toml`

Run: `make test_file FILE=tests/codecompanion/_extensions/reasoning/config_test.lua`

Expected: PASS after formatting.

- [ ] **Step 5: Commit the configuration rewrite**

```bash
git add lua/codecompanion/_extensions/reasoning/config.lua tests/codecompanion/_extensions/reasoning/config_test.lua
git commit -m "refactor(config): define reasoning options"
```

### Task 2: Add bounded chat-scoped artifact state

**Files:**
- Create: `lua/codecompanion/_extensions/reasoning/state.lua`
- Create: `tests/codecompanion/_extensions/reasoning/state_test.lua`

- [ ] **Step 1: Write state tests for isolation, IDs, status, and bounds**

```lua
local Config = require('codecompanion._extensions.reasoning.config')
local State = require('codecompanion._extensions.reasoning.state')

local T = MiniTest.new_set({
  hooks = {
    pre_case = function()
      Config.setup({ limits = { max_artifacts = 3 } })
      State._reset()
    end,
  },
})
local eq = MiniTest.expect.equality

T['isolates workspaces by chat'] = function()
  local first_chat, second_chat = {}, {}
  local first = State.begin(first_chat)
  local second = State.begin(second_chat)
  eq(first.id, 'W1')
  eq(second.id, 'W1')
  eq(State.get(first_chat), first)
  eq(State.get(second_chat), second)
end

T['allocates deterministic artifact IDs'] = function()
  local workspace = State.begin({})
  eq(State.add(workspace, 'frame', {}).id, 'F1')
  eq(State.add(workspace, 'evidence', {}).id, 'E1')
  eq(State.add(workspace, 'evidence', {}).id, 'E2')
end

T['tracks supersession and retraction'] = function()
  local workspace = State.begin({})
  local old = State.add(workspace, 'evidence', {})
  local replacement = State.add(workspace, 'evidence', {})
  State.supersede(workspace, old.id, replacement.id)
  eq(old.status, 'superseded')
  eq(replacement.relations.supersedes[1], old.id)
  State.retract(workspace, replacement.id)
  eq(replacement.status, 'retracted')
end

T['retires a replaced aggregate member without a cross-kind relation'] = function()
  local workspace = State.begin({})
  local option = State.add(workspace, 'option', {})
  workspace.open_revisions[option.id] = 'R1'
  State.retire(workspace, option.id)
  eq(option.status, 'superseded')
  eq(option.relations.supersedes, {})
  eq(workspace.open_revisions[option.id], nil)
end

T['rejects artifacts beyond the configured limit'] = function()
  local workspace = State.begin({})
  State.add(workspace, 'frame', {})
  State.add(workspace, 'evidence', {})
  State.add(workspace, 'review', {})
  local artifact, code = State.add(workspace, 'synthesis', {})
  eq(artifact, nil)
  eq(code, 'limit_exceeded')
end

T['replaces a workspace without reusing its workspace sequence'] = function()
  local chat = {}
  eq(State.begin(chat).id, 'W1')
  eq(State.begin(chat, true).id, 'W2')
  eq(State.get(chat).artifact_order, {})
end

T['does not keep a released chat alive'] = function()
  local chat = {}
  State.begin(chat)
  eq(State._session_count(), 1)
  chat = nil
  collectgarbage('collect')
  collectgarbage('collect')
  eq(State._session_count(), 0)
end

return T
```

- [ ] **Step 2: Run the test and verify the module is missing**

Run: `make test_file FILE=tests/codecompanion/_extensions/reasoning/state_test.lua`

Expected: FAIL with `module 'codecompanion._extensions.reasoning.state' not found`.

- [ ] **Step 3: Implement the complete state module**

```lua
local Config = require('codecompanion._extensions.reasoning.config')

local M = {}
local sessions = setmetatable({}, { __mode = 'k' })
local prefixes = {
  frame = 'F',
  evidence = 'E',
  branch = 'B',
  option = 'O',
  review = 'R',
  synthesis = 'S',
}

local function new_workspace(sequence)
  return {
    id = 'W' .. sequence,
    frame_id = nil,
    artifacts_by_id = {},
    artifact_order = {},
    counts_by_kind = {},
    next_sequence = {},
    open_revisions = {},
    resolved_contradictions = {},
  }
end

function M.begin(chat, replace)
  assert(type(chat) == 'table', 'chat must be a table')
  local session = sessions[chat]
  if session and session.active and not replace then
    return nil, 'workspace_exists'
  end
  session = session or { next_workspace = 1 }
  local workspace = new_workspace(session.next_workspace)
  session.next_workspace = session.next_workspace + 1
  session.active = workspace
  sessions[chat] = session
  return workspace
end

function M.get(chat)
  local session = sessions[chat]
  return session and session.active or nil
end

function M.add(workspace, kind, data)
  local prefix = prefixes[kind]
  assert(prefix, 'unknown artifact kind: ' .. tostring(kind))
  if #workspace.artifact_order >= Config.get().limits.max_artifacts then
    return nil, 'limit_exceeded'
  end
  local sequence = (workspace.next_sequence[kind] or 0) + 1
  workspace.next_sequence[kind] = sequence
  local artifact = {
    id = prefix .. sequence,
    kind = kind,
    status = 'active',
    data = vim.deepcopy(data),
    relations = {
      supports = {},
      contradicts = {},
      qualifies = {},
      depends_on = {},
      tests = {},
      supersedes = {},
    },
  }
  workspace.artifacts_by_id[artifact.id] = artifact
  table.insert(workspace.artifact_order, artifact.id)
  workspace.counts_by_kind[kind] = (workspace.counts_by_kind[kind] or 0) + 1
  return artifact
end

function M.find(workspace, id)
  return workspace and workspace.artifacts_by_id[id] or nil
end

function M.add_relation(artifact, relation, target_id)
  assert(artifact.relations[relation], 'unknown relation: ' .. tostring(relation))
  table.insert(artifact.relations[relation], target_id)
end

function M.supersede(workspace, old_id, replacement_id)
  local old = M.find(workspace, old_id)
  local replacement = M.find(workspace, replacement_id)
  assert(old and replacement, 'supersession artifacts must exist')
  old.status = 'superseded'
  M.add_relation(replacement, 'supersedes', old_id)
  workspace.open_revisions[old_id] = nil
end

function M.retract(workspace, id)
  local artifact = M.find(workspace, id)
  assert(artifact, 'retracted artifact must exist')
  artifact.status = 'retracted'
  workspace.open_revisions[id] = nil
end

function M.retire(workspace, id)
  local artifact = M.find(workspace, id)
  assert(artifact, 'retired artifact must exist')
  artifact.status = 'superseded'
  workspace.open_revisions[id] = nil
end

function M._reset()
  sessions = setmetatable({}, { __mode = 'k' })
end

function M._session_count()
  local count = 0
  for _ in pairs(sessions) do
    count = count + 1
  end
  return count
end

return M
```

- [ ] **Step 4: Run the focused test and format**

Run: `make test_file FILE=tests/codecompanion/_extensions/reasoning/state_test.lua`

Expected: PASS, 7 cases and 0 failures.

Run: `stylua lua/codecompanion/_extensions/reasoning/state.lua tests/codecompanion/_extensions/reasoning/state_test.lua -f stylua.toml`

Run: `make test_file FILE=tests/codecompanion/_extensions/reasoning/state_test.lua`

Expected: PASS after formatting.

- [ ] **Step 5: Commit state management**

```bash
git add lua/codecompanion/_extensions/reasoning/state.lua tests/codecompanion/_extensions/reasoning/state_test.lua
git commit -m "feat(reasoning): add chat-scoped state"
```

### Task 3: Implement framing and protocol result contracts

**Files:**
- Create: `lua/codecompanion/_extensions/reasoning/protocol.lua`
- Create: `lua/codecompanion/_extensions/reasoning/guidance.lua`
- Create: `lua/codecompanion/_extensions/reasoning/tools/frame.lua`
- Create: `tests/codecompanion/_extensions/reasoning/tools/frame_test.lua`

- [ ] **Step 1: Write failing frame tests**

```lua
local Config = require('codecompanion._extensions.reasoning.config')
local Protocol = require('codecompanion._extensions.reasoning.protocol')
local State = require('codecompanion._extensions.reasoning.state')
local Frame = require('codecompanion._extensions.reasoning.tools.frame')

local T = MiniTest.new_set({
  hooks = {
    pre_case = function()
      Config.setup()
      State._reset()
    end,
  },
})
local eq = MiniTest.expect.equality

local function valid_args(action)
  return {
    action = action or 'start',
    objective = 'Choose a durable cache design',
    problem_type = 'design',
    depth = 'deep',
    constraints = { 'No external service' },
    success_criteria = { 'Survives process restart', 'Bounded memory' },
    unknowns = { 'Expected write rate' },
    perspectives = {
      { name = 'correctness', purpose = 'Find invalidation failures' },
      { name = 'operations', purpose = 'Find lifecycle failures' },
    },
    temporal_required = false,
    branching_required = true,
    branching_rationale = 'Several storage strategies are viable',
  }
end

T['starts a deep frame and recommends evidence'] = function()
  local chat = {}
  local result = Frame.cmds[1]({ chat = chat }, valid_args(), {})
  eq(result.status, 'success')
  eq(result.data.artifact.id, 'F1')
  eq(result.data.next_action.tool, 'reasoning_evidence')
end

T['rejects a deep frame with one perspective'] = function()
  local args = valid_args()
  args.perspectives = { args.perspectives[1] }
  local result = Frame.cmds[1]({ chat = {} }, args, {})
  eq(result.status, 'error')
  eq(result.data.code, 'frame_incomplete')
end

T['requires branching for design problems'] = function()
  local args = valid_args()
  args.branching_required = false
  local result = Frame.cmds[1]({ chat = {} }, args, {})
  eq(result.status, 'error')
  eq(result.data.code, 'branching_required')
end

T['requires branching for every decision-shaped problem type'] = function()
  for _, problem_type in ipairs({ 'decision', 'diagnosis', 'design', 'planning' }) do
    State._reset()
    local args = valid_args()
    args.problem_type = problem_type
    args.branching_required = false
    eq(Frame.cmds[1]({ chat = {} }, args, {}).data.code, 'branching_required')
  end
  local analysis = valid_args()
  analysis.problem_type = 'analysis'
  analysis.branching_required = false
  eq(Frame.cmds[1]({ chat = {} }, analysis, {}).status, 'success')
end

T['requires explicit replace for an active workspace'] = function()
  local chat = {}
  Frame.cmds[1]({ chat = chat }, valid_args(), {})
  local result = Frame.cmds[1]({ chat = chat }, valid_args(), {})
  eq(result.status, 'error')
  eq(result.data.code, 'workspace_exists')
end

T['rejects duplicate perspective names'] = function()
  local args = valid_args()
  args.perspectives[2].name = ' CORRECTNESS '
  local result = Frame.cmds[1]({ chat = {} }, args, {})
  eq(result.data.code, 'frame_incomplete')
end

T['rejects duplicate criteria and unknowns after normalization'] = function()
  local criteria = valid_args()
  criteria.success_criteria[2] = '  SURVIVES   process restart '
  eq(Frame.cmds[1]({ chat = {} }, criteria, {}).data.code, 'frame_incomplete')
  local unknowns = valid_args()
  unknowns.unknowns = { 'Expected write rate', ' expected   WRITE rate ' }
  eq(Frame.cmds[1]({ chat = {} }, unknowns, {}).data.code, 'frame_incomplete')
end

T['rejects whitespace-only required text'] = function()
  local args = valid_args()
  args.objective = '   '
  local result = Frame.cmds[1]({ chat = {} }, args, {})
  eq(result.data.code, 'frame_incomplete')
  eq(result.data.next_action.tool, 'reasoning_frame')
end

T['counts configured text limits in characters, not bytes'] = function()
  Config.setup({ limits = { max_text_chars = 3 } })
  eq(Protocol.text_valid('żół'), true)
  eq(Protocol.text_valid('żółć'), false)
end

T['applies the configured array cap to perspectives'] = function()
  Config.setup({ limits = { max_array_items = 1 } })
  local args = valid_args()
  args.problem_type = 'analysis'
  args.depth = 'standard'
  args.success_criteria = { 'Durable' }
  args.branching_required = false
  args.branching_rationale = 'One bounded claim is being analyzed'
  local chat = {}
  eq(Frame.cmds[1]({ chat = chat }, args, {}).data.code, 'frame_incomplete')
  args.perspectives = { args.perspectives[1] }
  eq(Frame.cmds[1]({ chat = chat }, args, {}).status, 'success')
end

T['does not remove a perspective used by active evidence'] = function()
  local chat = {}
  Frame.cmds[1]({ chat = chat }, valid_args(), {})
  local State = require('codecompanion._extensions.reasoning.state')
  State.add(State.get(chat), 'evidence', { perspective = 'operations' })
  local revised = valid_args('revise')
  revised.perspectives = { revised.perspectives[1], { name = 'security', purpose = 'Find trust failures' } }
  local result = Frame.cmds[1]({ chat = chat }, revised, {})
  eq(result.data.code, 'frame_incomplete')
end

T['does not remove an unknown addressed by active evidence'] = function()
  local chat = {}
  Frame.cmds[1]({ chat = chat }, valid_args(), {})
  State.add(State.get(chat), 'evidence', {
    perspective = 'correctness', addresses_unknowns = { 'Expected write rate' },
  })
  local revised = valid_args('revise')
  revised.unknowns = {}
  eq(Frame.cmds[1]({ chat = chat }, revised, {}).data.code, 'frame_incomplete')
end

T['replace starts a fresh sequenced workspace'] = function()
  local chat = {}
  Frame.cmds[1]({ chat = chat }, valid_args(), {})
  local replaced = valid_args('replace')
  local result = Frame.cmds[1]({ chat = chat }, replaced, {})
  eq(result.status, 'success')
  eq(result.data.workspace_id, 'W2')
  eq(result.data.artifact.id, 'F1')
end

return T
```

- [ ] **Step 2: Run the test and verify the new modules are missing**

Run: `make test_file FILE=tests/codecompanion/_extensions/reasoning/tools/frame_test.lua`

Expected: FAIL while requiring the not-yet-created `protocol` or `tools.frame` module.

- [ ] **Step 3: Add protocol helpers and the frame operation**

Implement these public functions in `protocol.lua`; keep validation helpers local to the module:

```lua
local Config = require('codecompanion._extensions.reasoning.config')
local Guidance = require('codecompanion._extensions.reasoning.guidance')
local State = require('codecompanion._extensions.reasoning.state')
local log = require('codecompanion.utils.log')

local M = {}

local function failure(code, message, artifact_ids, next_action)
  return {
    status = 'error',
    data = {
      code = code,
      message = message,
      artifact_ids = artifact_ids or {},
      next_action = next_action,
    },
  }
end

local function success(workspace, artifact)
  return {
    status = 'success',
    data = {
      workspace_id = workspace.id,
      artifact = vim.deepcopy(artifact),
      progress = vim.deepcopy(workspace.counts_by_kind),
      unmet_gates = M.final_gates(workspace, nil),
      next_action = Guidance.next(workspace),
    },
  }
end

local function text_valid(value)
  return type(value) == 'string'
    and vim.trim(value) ~= ''
    and vim.fn.strchars(value) <= Config.get().limits.max_text_chars
end

local function bounded_array(value, minimum, maximum)
  return type(value) == 'table' and #value >= minimum and #value <= maximum
end

local function frame_text_array(value, minimum)
  if not bounded_array(value, minimum or 0, Config.get().limits.max_array_items) then
    return false
  end
  for _, item in ipairs(value) do
    if not text_valid(item) then
      return false
    end
  end
  return true
end

local function unique_frame_texts(values)
  local seen = {}
  for _, value in ipairs(values) do
    local key = vim.trim(value):lower():gsub('%s+', ' ')
    if seen[key] then
      return false
    end
    seen[key] = true
  end
  return true
end

function M.frame(chat, args)
  if type(args) ~= 'table'
    or not vim.tbl_contains({ 'start', 'revise', 'replace' }, args.action)
    or not text_valid(args.objective)
    or not frame_text_array(args.constraints)
    or not frame_text_array(args.success_criteria, 1)
    or not frame_text_array(args.unknowns)
    or type(args.temporal_required) ~= 'boolean'
    or type(args.branching_required) ~= 'boolean'
    or not text_valid(args.branching_rationale)
  then
    return failure('frame_incomplete', 'objective must be non-empty and bounded', {}, 'Call reasoning_frame')
  end
  if not unique_frame_texts(args.success_criteria) or not unique_frame_texts(args.unknowns) then
    return failure('frame_incomplete', 'success criteria and unknowns must be unique', {}, 'Remove duplicate frame entries')
  end
  if not vim.tbl_contains({ 'analysis', 'decision', 'diagnosis', 'design', 'planning' }, args.problem_type) then
    return failure('frame_incomplete', 'problem_type is invalid', {}, 'Call reasoning_frame with a valid problem_type')
  end
  if args.depth ~= 'standard' and args.depth ~= 'deep' then
    return failure('frame_incomplete', 'depth must be standard or deep', {}, 'Call reasoning_frame with a valid depth')
  end
  local minimum_perspectives = args.depth == 'deep' and 2 or 1
  if not bounded_array(args.perspectives, minimum_perspectives, math.min(4, Config.get().limits.max_array_items)) then
    return failure('frame_incomplete', 'perspectives do not satisfy the selected depth', {}, 'Add distinct perspectives')
  end
  local perspective_names = {}
  for _, perspective in ipairs(args.perspectives) do
    if type(perspective) ~= 'table' or not text_valid(perspective.name) or not text_valid(perspective.purpose) then
      return failure('frame_incomplete', 'every perspective needs a bounded name and purpose', {}, 'Correct the perspectives')
    end
    local name = vim.trim(perspective.name):lower()
    if perspective_names[name] then
      return failure('frame_incomplete', 'perspective names must be unique', {}, 'Rename the duplicate perspective')
    end
    perspective_names[name] = true
  end
  local requires_branching = vim.tbl_contains({ 'decision', 'diagnosis', 'design', 'planning' }, args.problem_type)
  if requires_branching and not args.branching_required then
    return failure('branching_required', 'this problem type requires competing branches', {}, 'Set branching_required to true')
  end
  local existing = State.get(chat)
  if args.action == 'start' and existing then
    return failure('workspace_exists', 'an active workspace already exists', { existing.frame_id }, 'Use revise or replace')
  end
  if args.action == 'revise' and not existing then
    return failure('workspace_missing', 'there is no frame to revise', {}, 'Start a frame')
  end
  if args.action == 'revise' then
    local unknown_names = {}
    for _, unknown in ipairs(args.unknowns) do
      unknown_names[vim.trim(unknown):lower():gsub('%s+', ' ')] = true
    end
    for _, id in ipairs(existing.artifact_order) do
      local artifact = State.find(existing, id)
      if artifact.status == 'active'
        and artifact.kind == 'evidence'
        and not perspective_names[vim.trim(artifact.data.perspective):lower()]
      then
        return failure(
          'frame_incomplete',
          'a revised frame cannot remove a perspective used by active evidence',
          { artifact.id },
          'Retract or replace the evidence before revising the frame'
        )
      end
      if artifact.status == 'active' and artifact.kind == 'evidence' then
        for _, unknown in ipairs(artifact.data.addresses_unknowns or {}) do
          local key = vim.trim(unknown):lower():gsub('%s+', ' ')
          if not unknown_names[key] then
            return failure(
              'frame_incomplete',
              'a revised frame cannot remove an unknown addressed by active evidence',
              { artifact.id },
              'Retract or replace the evidence before revising the frame'
            )
          end
        end
      end
    end
  end
  local workspace = existing
  if args.action == 'start' then
    workspace = State.begin(chat)
  elseif args.action == 'replace' then
    workspace = State.begin(chat, true)
  end
  local frame_data = vim.deepcopy(args)
  frame_data.action = nil
  local frame = State.add(workspace, 'frame', frame_data)
  if not frame then
    return failure('limit_exceeded', 'the workspace artifact limit was reached', {}, 'Replace the workspace')
  end
  if workspace.frame_id then
    State.supersede(workspace, workspace.frame_id, frame.id)
  end
  workspace.frame_id = frame.id
  return success(workspace, frame)
end

function M.final_gates(workspace, synthesis)
  local gates = {}
  if not workspace or not workspace.frame_id then
    table.insert(gates, 'frame_missing')
  end
  return gates
end

M.failure = failure
M.success = success
M.text_valid = text_valid
M.bounded_array = bounded_array

function M.call(operation, chat, args)
  local tools_by_operation = {
    frame = 'reasoning_frame',
    evidence = 'reasoning_evidence',
    options = 'reasoning_options',
    review = 'reasoning_review',
    synthesis = 'reasoning_synthesis',
  }
  local handler = M[operation]
  if type(handler) ~= 'function' then
    log:error('[reasoning] unknown protocol operation: %s', tostring(operation))
    return failure('internal_error', 'the reasoning operation is unavailable', {}, {
      tool = tools_by_operation[operation] or 'reasoning_frame',
      reason = 'Retry with a registered reasoning tool',
    })
  end
  local ok, result = xpcall(function()
    return handler(chat, args)
  end, debug.traceback)
  if not ok then
    log:error('[reasoning] %s failed: %s', operation, result)
    return failure('internal_error', 'the reasoning operation failed internally', {}, {
      tool = tools_by_operation[operation],
      reason = 'Correct the call or report the plugin error',
    })
  end
  if result.status == 'error' and type(result.data.next_action) == 'string' then
    local tools_by_code = {
      workspace_missing = 'reasoning_frame',
      perspective_unknown = 'reasoning_frame',
      limit_exceeded = 'reasoning_frame',
    }
    result.data.next_action = {
      tool = tools_by_code[result.data.code] or tools_by_operation[operation] or 'reasoning_frame',
      reason = result.data.next_action,
    }
  end
  return result
end

return M
```

- [ ] **Step 4: Add the initial deterministic guidance module**

```lua
local M = {}

function M.next(workspace)
  local evidence_count = workspace.counts_by_kind.evidence or 0
  if evidence_count == 0 then
    return { tool = 'reasoning_evidence', reason = 'Gather evidence for the framed perspectives' }
  end
  return { tool = 'reasoning_synthesis', reason = 'Record a checkpoint and inspect remaining gates' }
end

return M
```

- [ ] **Step 5: Add the frame tool with its complete strict schema**

Create `tools/frame.lua` with the complete schema and guarded `Protocol.call` command below:

```lua
local Config = require('codecompanion._extensions.reasoning.config')
local Protocol = require('codecompanion._extensions.reasoning.protocol')

return {
  name = 'reasoning_frame',
  cmds = {
    function(tools, args, opts)
      return Protocol.call('frame', tools.chat, args)
    end,
  },
  schema = {
    type = 'function',
    ['function'] = {
      name = 'reasoning_frame',
      description = 'Frame a difficult problem with explicit constraints, success criteria, unknowns, and analytical perspectives.',
      parameters = {
        type = 'object',
        properties = {
          action = {
            type = 'string', enum = { 'start', 'revise', 'replace' },
            description = 'Start a workspace, append a frame revision, or explicitly discard and replace the workspace.',
          },
          objective = { type = 'string', description = 'The outcome this reasoning workspace must resolve.' },
          problem_type = {
            type = 'string', enum = { 'analysis', 'decision', 'diagnosis', 'design', 'planning' },
            description = 'The structural problem class; all but analysis require competing branches.',
          },
          depth = {
            type = 'string',
            enum = { 'standard', 'deep' },
            description = string.format(
              'Protocol depth; configured guidance is %s, and this field remains required.',
              Config.get().default_depth
            ),
          },
          constraints = { type = 'array', items = { type = 'string' } },
          success_criteria = { type = 'array', items = { type = 'string' } },
          unknowns = { type = 'array', items = { type = 'string' } },
          perspectives = {
            type = 'array',
            items = {
              type = 'object',
              properties = { name = { type = 'string' }, purpose = { type = 'string' } },
              required = { 'name', 'purpose' },
              additionalProperties = false,
            },
          },
          temporal_required = {
            type = 'boolean',
            description = 'Whether transitions or evolution over time require explicit temporal stress tests.',
          },
          branching_required = { type = 'boolean', description = 'Whether competing alternatives must be developed.' },
          branching_rationale = { type = 'string', description = 'Why branching is or is not appropriate.' },
        },
        required = {
          'action', 'objective', 'problem_type', 'depth', 'constraints', 'success_criteria',
          'unknowns', 'perspectives', 'temporal_required', 'branching_required', 'branching_rationale',
        },
        additionalProperties = false,
      },
      strict = true,
    },
  },
}
```

- [ ] **Step 6: Run and commit the frame slice**

Run: `make test_file FILE=tests/codecompanion/_extensions/reasoning/tools/frame_test.lua`

Expected: PASS, 13 cases and 0 failures.

Run: `stylua lua/codecompanion/_extensions/reasoning/protocol.lua lua/codecompanion/_extensions/reasoning/guidance.lua lua/codecompanion/_extensions/reasoning/tools/frame.lua tests/codecompanion/_extensions/reasoning/tools/frame_test.lua -f stylua.toml`

Run: `make test_file FILE=tests/codecompanion/_extensions/reasoning/tools/frame_test.lua`

Expected: PASS after formatting.

```bash
git add lua/codecompanion/_extensions/reasoning/protocol.lua lua/codecompanion/_extensions/reasoning/guidance.lua lua/codecompanion/_extensions/reasoning/tools/frame.lua tests/codecompanion/_extensions/reasoning/tools/frame_test.lua
git commit -m "feat(reasoning): add problem framing"
```

### Task 4: Record evidence, assumptions, and falsifiers atomically

**Files:**
- Modify: `lua/codecompanion/_extensions/reasoning/protocol.lua`
- Create: `lua/codecompanion/_extensions/reasoning/tools/evidence.lua`
- Create: `tests/codecompanion/_extensions/reasoning/tools/evidence_test.lua`

- [ ] **Step 1: Write the complete failing evidence test file**

```lua
local Config = require('codecompanion._extensions.reasoning.config')
local Evidence = require('codecompanion._extensions.reasoning.tools.evidence')
local Frame = require('codecompanion._extensions.reasoning.tools.frame')
local State = require('codecompanion._extensions.reasoning.state')

local T = MiniTest.new_set({
  hooks = {
    pre_case = function()
      Config.setup()
      State._reset()
    end,
  },
})
local eq = MiniTest.expect.equality

local function frame_args()
  return {
    action = 'start',
    objective = 'Choose a durable cache design',
    problem_type = 'design',
    depth = 'deep',
    constraints = { 'No external service' },
    success_criteria = { 'Survives process restart', 'Bounded memory' },
    unknowns = { 'Expected write rate' },
    perspectives = {
      { name = 'correctness', purpose = 'Find invalidation failures' },
      { name = 'operations', purpose = 'Find lifecycle failures' },
    },
    temporal_required = false,
    branching_required = true,
    branching_rationale = 'Several storage strategies are viable',
  }
end

local function framed_chat()
  local chat = {}
  eq(Frame.cmds[1]({ chat = chat }, frame_args(), {}).status, 'success')
  return chat
end

local function evidence_item(perspective)
  return {
    kind = 'observation',
    statement = 'The existing cache is process-local',
    source = 'lua/cache.lua:14',
    confidence = 'high',
    falsifier = 'A persistence adapter loaded by cache.lua',
    perspective = perspective or 'correctness',
    addresses_unknowns = {},
    supports = {},
    contradicts = {},
    qualifies = {},
    supersedes_id = '',
  }
end

local function record_assumption(chat)
  local item = evidence_item('correctness')
  item.kind = 'assumption'
  item.source = 'assumption: inferred from the current module layout'
  local result = Evidence.cmds[1]({ chat = chat }, { items = { item } }, {})
  eq(result.status, 'success')
  return result.data.artifacts[1]
end

T['routes cross-tool corrections to the exact corrective tool'] = function()
  local missing = Evidence.cmds[1]({ chat = {} }, { items = { evidence_item() } }, {})
  eq(missing.data.code, 'workspace_missing')
  eq(missing.data.next_action.tool, 'reasoning_frame')

  local unknown = Evidence.cmds[1]({ chat = framed_chat() }, { items = { evidence_item('missing') } }, {})
  eq(unknown.data.code, 'perspective_unknown')
  eq(unknown.data.next_action.tool, 'reasoning_frame')
end

T['records evidence and typed relations with stable IDs'] = function()
  local chat = framed_chat()
  local first = Evidence.cmds[1]({ chat = chat }, { items = { evidence_item() } }, {})
  local second_item = evidence_item('operations')
  second_item.statement = 'A journal survives process restart'
  second_item.source = 'tests/recovery_spec.lua:28'
  second_item.supports = { 'E1' }
  second_item.contradicts = { 'E1' }
  second_item.qualifies = { 'E1' }
  local second = Evidence.cmds[1]({ chat = chat }, { items = { second_item } }, {})
  eq(first.data.artifacts[1].id, 'E1')
  eq(second.data.artifacts[1].id, 'E2')
  eq(State.find(State.get(chat), 'E2').relations.supports, { 'E1' })
  eq(State.find(State.get(chat), 'E2').relations.contradicts, { 'E1' })
  eq(State.find(State.get(chat), 'E2').relations.qualifies, { 'E1' })
end

T['rejects an unknown perspective without a partial write'] = function()
  local chat = framed_chat()
  local first = evidence_item('missing')
  local second = evidence_item('correctness')
  second.statement = 'A distinct statement'
  local result = Evidence.cmds[1]({ chat = chat }, { items = { first, second } }, {})
  eq(result.status, 'error')
  eq(result.data.code, 'perspective_unknown')
  eq(State.get(chat).counts_by_kind.evidence, nil)
end

T['distinguishes missing and inactive references'] = function()
  local chat = framed_chat()
  local item = evidence_item()
  item.supports = { 'E99' }
  eq(Evidence.cmds[1]({ chat = chat }, { items = { item } }, {}).data.code, 'invalid_reference')

  local accepted = Evidence.cmds[1]({ chat = chat }, { items = { evidence_item() } }, {})
  State.retract(State.get(chat), accepted.data.artifacts[1].id)
  item.statement = 'A second distinct statement'
  item.supports = { 'E1' }
  eq(Evidence.cmds[1]({ chat = chat }, { items = { item } }, {}).data.code, 'inactive_reference')
end

T['rejects duplicate normalized statements'] = function()
  local chat = framed_chat()
  Evidence.cmds[1]({ chat = chat }, { items = { evidence_item() } }, {})
  local duplicate = evidence_item()
  duplicate.statement = '  THE existing   cache is process-local  '
  eq(Evidence.cmds[1]({ chat = chat }, { items = { duplicate } }, {}).data.code, 'duplicate_artifact')
end

T['rejects duplicate statements found in inactive history'] = function()
  local chat = framed_chat()
  Evidence.cmds[1]({ chat = chat }, { items = { evidence_item() } }, {})
  State.retract(State.get(chat), 'E1')
  local result = Evidence.cmds[1]({ chat = chat }, { items = { evidence_item() } }, {})
  eq(result.data.code, 'duplicate_artifact')
  eq(result.data.artifact_ids, { 'E1' })
end

T['rejects duplicate statements and supersession targets inside one batch'] = function()
  local chat = framed_chat()
  local original = Evidence.cmds[1]({ chat = chat }, { items = { evidence_item() } }, {}).data.artifacts[1]
  local first = evidence_item()
  first.supersedes_id = original.id
  local second = evidence_item('operations')
  second.supersedes_id = original.id
  local result = Evidence.cmds[1]({ chat = chat }, { items = { first, second } }, {})
  eq(result.data.code, 'duplicate_artifact')
  eq(result.data.artifact_ids, { 'E1' })
  eq(State.find(State.get(chat), 'E1').status, 'active')
  eq(State.get(chat).counts_by_kind.evidence, 1)
end

T['requires explicit assumption and observation sources'] = function()
  local chat = framed_chat()
  local assumption = evidence_item()
  assumption.kind = 'assumption'
  eq(Evidence.cmds[1]({ chat = chat }, { items = { assumption } }, {}).data.code, 'evidence_invalid')
  local observation = evidence_item()
  observation.source = 'unknown'
  eq(Evidence.cmds[1]({ chat = chat }, { items = { observation } }, {}).data.code, 'evidence_invalid')
end

T['requires a falsifier and validates unknown coverage'] = function()
  local chat = framed_chat()
  local missing_falsifier = evidence_item()
  missing_falsifier.falsifier = '   '
  eq(Evidence.cmds[1]({ chat = chat }, { items = { missing_falsifier } }, {}).data.code, 'evidence_invalid')

  local covered = evidence_item()
  covered.addresses_unknowns = { 'Expected write rate' }
  eq(Evidence.cmds[1]({ chat = chat }, { items = { covered } }, {}).status, 'success')

  local unknown = evidence_item('operations')
  unknown.statement = 'Writes are bursty'
  unknown.addresses_unknowns = { 'Unknown not present in the frame' }
  eq(Evidence.cmds[1]({ chat = chat }, { items = { unknown } }, {}).data.code, 'evidence_invalid')
end

T['enforces max_batch_items atomically'] = function()
  Config.setup({ limits = { max_batch_items = 1 } })
  local chat = framed_chat()
  local second = evidence_item('operations')
  second.statement = 'A second distinct statement'
  local result = Evidence.cmds[1]({ chat = chat }, { items = { evidence_item(), second } }, {})
  eq(result.data.code, 'evidence_invalid')
  eq(State.get(chat).counts_by_kind.evidence, nil)
end

T['supersedes an assumption with an observation'] = function()
  local chat = framed_chat()
  local first = record_assumption(chat)
  local replacement = evidence_item('correctness')
  replacement.statement = first.data.statement
  replacement.supersedes_id = first.id
  local result = Evidence.cmds[1]({ chat = chat }, { items = { replacement } }, {})
  eq(result.status, 'success')
  eq(State.find(State.get(chat), first.id).status, 'superseded')
  eq(result.data.artifacts[1].relations.supersedes, { first.id })
end

T['rejects a batch when total capacity is unavailable'] = function()
  Config.setup({ limits = { max_artifacts = 2 } })
  local chat = framed_chat()
  local first = evidence_item()
  local second = evidence_item('operations')
  second.statement = 'A second distinct statement'
  local result = Evidence.cmds[1]({ chat = chat }, { items = { first, second } }, {})
  eq(result.data.code, 'limit_exceeded')
  eq(State.get(chat).counts_by_kind.evidence, nil)
end

return T
```

- [ ] **Step 2: Run the test and verify `tools.evidence` is missing**

Run: `make test_file FILE=tests/codecompanion/_extensions/reasoning/tools/evidence_test.lua`

Expected: FAIL while requiring `tools.evidence`.

- [ ] **Step 3: Add atomic evidence validation and recording to `protocol.lua`**

Insert this block before `M.final_gates`. It validates the complete batch before the first call to `State.add`:

```lua
local function normalized(value)
  return vim.trim(value):lower():gsub('%s+', ' ')
end

local function text_array_valid(value, minimum)
  if not bounded_array(value, minimum or 0, Config.get().limits.max_array_items) then
    return false
  end
  for _, item in ipairs(value) do
    if not text_valid(item) then
      return false
    end
  end
  return true
end

local function active_reference(workspace, id)
  local artifact = State.find(workspace, id)
  if not artifact then
    return nil, 'invalid_reference'
  end
  if artifact.status ~= 'active' then
    return nil, 'inactive_reference'
  end
  return artifact
end

local function evidence_success(workspace, artifacts)
  return {
    status = 'success',
    data = {
      workspace_id = workspace.id,
      artifact = vim.deepcopy(artifacts[#artifacts]),
      artifacts = vim.deepcopy(artifacts),
      progress = vim.deepcopy(workspace.counts_by_kind),
      unmet_gates = M.final_gates(workspace, nil),
      next_action = Guidance.next(workspace),
    },
  }
end

function M.evidence(chat, args)
  local workspace = State.get(chat)
  if not workspace then
    return failure('workspace_missing', 'start a frame before recording evidence', {}, 'Call reasoning_frame')
  end
  if type(args) ~= 'table' or not bounded_array(args.items, 1, Config.get().limits.max_batch_items) then
    return failure('evidence_invalid', 'items must be a non-empty bounded batch', {}, 'Call reasoning_evidence')
  end

  local frame = State.find(workspace, workspace.frame_id)
  local perspectives = {}
  for _, perspective in ipairs(frame.data.perspectives) do
    perspectives[normalized(perspective.name)] = true
  end
  local frame_unknowns = {}
  for _, unknown in ipairs(frame.data.unknowns) do
    frame_unknowns[normalized(unknown)] = true
  end

  local known_statements = {}
  for _, id in ipairs(workspace.artifact_order) do
    local artifact = State.find(workspace, id)
    if artifact.kind == 'evidence' then
      known_statements[normalized(artifact.data.statement)] = artifact.id
    end
  end

  local prepared = {}
  local pending_statements = {}
  local pending_supersessions = {}
  for index, item in ipairs(args.items) do
    if type(item) ~= 'table'
      or not vim.tbl_contains({ 'observation', 'claim', 'assumption' }, item.kind)
      or not text_valid(item.statement)
      or not text_valid(item.source)
      or not vim.tbl_contains({ 'low', 'medium', 'high' }, item.confidence)
      or not text_valid(item.falsifier)
      or not text_valid(item.perspective)
      or not text_array_valid(item.addresses_unknowns)
      or not text_array_valid(item.supports)
      or not text_array_valid(item.contradicts)
      or not text_array_valid(item.qualifies)
      or type(item.supersedes_id) ~= 'string'
    then
      return failure('evidence_invalid', 'evidence item ' .. index .. ' is invalid', {}, 'Correct reasoning_evidence fields')
    end
    local source = normalized(item.source)
    if item.kind == 'assumption' and not source:match('^assumption:') then
      return failure('evidence_invalid', 'assumption sources must begin with assumption:', {}, 'Label the assumption source')
    end
    if item.kind == 'observation' and vim.tbl_contains({ 'unknown', 'unspecified', 'none' }, source) then
      return failure('evidence_invalid', 'observations require a concrete source', {}, 'Provide the observation source')
    end
    if not perspectives[normalized(item.perspective)] then
      return failure('perspective_unknown', 'evidence references an unknown perspective', {}, 'Revise the frame or perspective')
    end
    local addressed = {}
    for _, unknown in ipairs(item.addresses_unknowns) do
      local key = normalized(unknown)
      if addressed[key] or not frame_unknowns[key] then
        return failure('evidence_invalid', 'addresses_unknowns must uniquely match active frame unknowns', {}, 'Use exact unknowns from reasoning_frame')
      end
      addressed[key] = true
    end
    for _, field in ipairs({ 'supports', 'contradicts', 'qualifies' }) do
      local seen = {}
      for _, id in ipairs(item[field]) do
        if seen[id] then
          return failure('evidence_invalid', field .. ' contains a duplicate ID', { id }, 'Remove the duplicate reference')
        end
        seen[id] = true
        local _, code = active_reference(workspace, id)
        if code then
          return failure(code, 'evidence relation target is unavailable', { id }, 'Use an active artifact ID')
        end
      end
    end
    if item.supersedes_id ~= '' then
      local target, code = active_reference(workspace, item.supersedes_id)
      if code then
        return failure(code, 'superseded evidence is unavailable', { item.supersedes_id }, 'Use an active evidence ID')
      end
      if target.kind ~= 'evidence' then
        return failure('invalid_reference', 'supersedes_id must name evidence', { item.supersedes_id }, 'Use reasoning_evidence')
      end
      if pending_supersessions[item.supersedes_id] then
        return failure(
          'duplicate_artifact',
          'one evidence artifact cannot have two replacements in the same batch',
          { item.supersedes_id },
          'Submit one replacement for the evidence ID'
        )
      end
      pending_supersessions[item.supersedes_id] = true
    end
    local key = normalized(item.statement)
    local duplicate_id = known_statements[key]
    if pending_statements[key] then
      return failure(
        'duplicate_artifact',
        'the evidence batch contains duplicate normalized statements',
        duplicate_id and { duplicate_id } or {},
        'Keep one statement or submit separate revisions'
      )
    end
    if duplicate_id and item.supersedes_id ~= duplicate_id then
      return failure('duplicate_artifact', 'an evidence artifact already has the same statement', { duplicate_id }, 'Supersede the active evidence or use a distinct statement')
    end
    pending_statements[key] = true
    table.insert(prepared, vim.deepcopy(item))
  end

  if #workspace.artifact_order + #prepared > Config.get().limits.max_artifacts then
    return failure('limit_exceeded', 'the complete evidence batch exceeds the artifact limit', {}, 'Replace the workspace or reduce the batch')
  end

  local artifacts = {}
  for _, item in ipairs(prepared) do
    local artifact = assert(State.add(workspace, 'evidence', item))
    table.insert(artifacts, artifact)
  end
  for index, item in ipairs(prepared) do
    local artifact = artifacts[index]
    for _, field in ipairs({ 'supports', 'contradicts', 'qualifies' }) do
      for _, id in ipairs(item[field]) do
        State.add_relation(artifact, field, id)
      end
    end
    if item.supersedes_id ~= '' then
      State.supersede(workspace, item.supersedes_id, artifact.id)
    end
  end
  return evidence_success(workspace, artifacts)
end
```

- [ ] **Step 4: Create the complete strict evidence tool**

```lua
local Protocol = require('codecompanion._extensions.reasoning.protocol')

return {
  name = 'reasoning_evidence',
  cmds = {
    function(tools, args, opts)
      return Protocol.call('evidence', tools.chat, args)
    end,
  },
  schema = {
    type = 'function',
    ['function'] = {
      name = 'reasoning_evidence',
      description = 'Record bounded, sourced, falsifiable observations, claims, or assumptions for the active reasoning frame.',
      parameters = {
        type = 'object',
        properties = {
          items = {
            type = 'array',
            items = {
              type = 'object',
              properties = {
                kind = {
                  type = 'string', enum = { 'observation', 'claim', 'assumption' },
                  description = 'Observation is directly sourced, claim is derived, and assumption is explicitly provisional.',
                },
                statement = { type = 'string' },
                source = {
                  type = 'string',
                  description = 'Concrete basis; assumption sources must begin with assumption: and observations cannot use unknown.',
                },
                confidence = { type = 'string', enum = { 'low', 'medium', 'high' } },
                falsifier = { type = 'string', description = 'Observable evidence that would overturn or materially revise the item.' },
                perspective = { type = 'string', description = 'Exact perspective name from the active frame.' },
                addresses_unknowns = {
                  type = 'array', items = { type = 'string' },
                  description = 'Exact active-frame unknowns addressed by this item; empty when it addresses none.',
                },
                supports = { type = 'array', items = { type = 'string' } },
                contradicts = { type = 'array', items = { type = 'string' } },
                qualifies = { type = 'array', items = { type = 'string' } },
                supersedes_id = { type = 'string', description = 'Active E artifact replaced by this item, or an empty string.' },
              },
              required = {
                'kind', 'statement', 'source', 'confidence', 'falsifier', 'perspective', 'addresses_unknowns',
                'supports', 'contradicts', 'qualifies', 'supersedes_id',
              },
              additionalProperties = false,
            },
          },
        },
        required = { 'items' },
        additionalProperties = false,
      },
      strict = true,
    },
  },
}
```

- [ ] **Step 5: Run, format, and commit**

Run: `make test_file FILE=tests/codecompanion/_extensions/reasoning/tools/evidence_test.lua`

Expected: PASS, including atomicity and supersession cases.

Run: `stylua lua/codecompanion/_extensions/reasoning/protocol.lua lua/codecompanion/_extensions/reasoning/tools/evidence.lua tests/codecompanion/_extensions/reasoning/tools/evidence_test.lua -f stylua.toml`

Run: `make test_file FILE=tests/codecompanion/_extensions/reasoning/tools/evidence_test.lua`

Expected: PASS after formatting.

```bash
git add lua/codecompanion/_extensions/reasoning/protocol.lua lua/codecompanion/_extensions/reasoning/tools/evidence.lua tests/codecompanion/_extensions/reasoning/tools/evidence_test.lua
git commit -m "feat(reasoning): record evidence artifacts"
```

### Task 5: Add competing branch sets and options

**Files:**
- Modify: `lua/codecompanion/_extensions/reasoning/protocol.lua`
- Create: `lua/codecompanion/_extensions/reasoning/tools/options.lua`
- Create: `tests/codecompanion/_extensions/reasoning/tools/options_test.lua`

- [ ] **Step 1: Write the complete failing branch-set test file**

Create `options_test.lua` with the shared setup and exact cases below:

```lua
local Config = require('codecompanion._extensions.reasoning.config')
local Evidence = require('codecompanion._extensions.reasoning.tools.evidence')
local Frame = require('codecompanion._extensions.reasoning.tools.frame')
local Options = require('codecompanion._extensions.reasoning.tools.options')
local State = require('codecompanion._extensions.reasoning.state')

local T = MiniTest.new_set({
  hooks = {
    pre_case = function()
      Config.setup()
      State._reset()
    end,
  },
})
local eq = MiniTest.expect.equality

local function prepared_chat()
  local chat = {}
  local frame = {
    action = 'start', objective = 'Choose a durable cache design', problem_type = 'design', depth = 'deep',
    constraints = { 'No external service' },
    success_criteria = { 'Survives process restart', 'Bounded memory' },
    unknowns = { 'Expected write rate' },
    perspectives = {
      { name = 'correctness', purpose = 'Find invalidation failures' },
      { name = 'operations', purpose = 'Find lifecycle failures' },
    },
    temporal_required = false,
    branching_required = true,
    branching_rationale = 'Several storage strategies are viable',
  }
  eq(Frame.cmds[1]({ chat = chat }, frame, {}).status, 'success')
  local evidence = {
    items = {
      {
        kind = 'observation', statement = 'The cache is process-local', source = 'lua/cache.lua:14',
        confidence = 'high', falsifier = 'A persistence adapter loaded by cache.lua', perspective = 'correctness',
        addresses_unknowns = {},
        supports = {}, contradicts = {}, qualifies = {}, supersedes_id = '',
      },
    },
  }
  eq(Evidence.cmds[1]({ chat = chat }, evidence, {}).status, 'success')
  return chat
end

local function valid_args()
  return {
    question = 'Which cache architecture satisfies the frame?',
    branch_type = 'solution',
    criteria = { 'Durability', 'Bounded memory' },
    supersedes_branch_id = '',
    options = {
      {
        label = 'journal',
        summary = 'Append mutations to a local journal',
        evidence_ids = { 'E1' },
        assumptions = { 'Disk writes are acceptable' },
        predictions = { 'Restart restores the latest committed entry' },
        benefits = { 'Durable without a service' },
        costs = { 'Compaction is required' },
        risks = { 'Partial writes' },
        reversibility = 'moderate',
      },
      {
        label = 'snapshot',
        summary = 'Write periodic complete snapshots',
        evidence_ids = { 'E1' },
        assumptions = { 'State fits in one file' },
        predictions = { 'Recovery loses changes after the last snapshot' },
        benefits = { 'Simple recovery' },
        costs = { 'Repeated full writes' },
        risks = { 'Stale recovery point' },
        reversibility = 'easy',
      },
    },
  }
end

T['creates a branch set and two options'] = function()
  local chat = prepared_chat()
  local result = Options.cmds[1]({ chat = chat }, valid_args(), {})
  eq(result.status, 'success')
  eq(result.data.artifact.id, 'B1')
  eq({ result.data.artifacts[1].id, result.data.artifacts[2].id }, { 'O1', 'O2' })
  eq(result.data.artifact.data.option_ids, { 'O1', 'O2' })
  eq(State.find(State.get(chat), 'O1').relations.depends_on, { 'B1' })
  eq(State.find(State.get(chat), 'O1').relations.supports, { 'E1' })
end

T['rejects duplicate labels and insufficient branches atomically'] = function()
  local chat = prepared_chat()
  local duplicate = valid_args()
  duplicate.options[2].label = ' JOURNAL '
  eq(Options.cmds[1]({ chat = chat }, duplicate, {}).data.code, 'options_invalid')
  local insufficient = valid_args()
  insufficient.options = { insufficient.options[1] }
  eq(Options.cmds[1]({ chat = chat }, insufficient, {}).data.code, 'branch_count_insufficient')
  eq(State.get(chat).counts_by_kind.branch, nil)
end

T['rejects invalid and inactive evidence'] = function()
  local chat = prepared_chat()
  local missing = valid_args()
  missing.options[1].evidence_ids = { 'E99' }
  eq(Options.cmds[1]({ chat = chat }, missing, {}).data.code, 'invalid_reference')
  State.retract(State.get(chat), 'E1')
  eq(Options.cmds[1]({ chat = chat }, valid_args(), {}).data.code, 'inactive_reference')
end

T['replaces a complete branch set'] = function()
  local chat = prepared_chat()
  eq(Options.cmds[1]({ chat = chat }, valid_args(), {}).status, 'success')
  local replacement = valid_args()
  replacement.supersedes_branch_id = 'B1'
  replacement.options[1].label = 'checksummed journal'
  replacement.options[2].label = 'atomic snapshot'
  local result = Options.cmds[1]({ chat = chat }, replacement, {})
  eq(result.data.artifact.id, 'B2')
  eq({ result.data.artifacts[1].id, result.data.artifacts[2].id }, { 'O3', 'O4' })
  eq(State.find(State.get(chat), 'B1').status, 'superseded')
  eq(State.find(State.get(chat), 'O1').status, 'superseded')
  eq(State.find(State.get(chat), 'O2').status, 'superseded')
end

T['requires explicit supersession when a branch set is active'] = function()
  local chat = prepared_chat()
  eq(Options.cmds[1]({ chat = chat }, valid_args(), {}).status, 'success')
  local result = Options.cmds[1]({ chat = chat }, valid_args(), {})
  eq(result.data.code, 'options_invalid')
  eq(result.data.artifact_ids, { 'B1' })
  eq(State.get(chat).counts_by_kind.branch, 1)
end

T['accepts intentional empty option analysis arrays'] = function()
  local chat = prepared_chat()
  local args = valid_args()
  for _, option in ipairs(args.options) do
    option.evidence_ids = {}
    option.assumptions = {}
    option.predictions = {}
    option.benefits = {}
    option.costs = {}
    option.risks = {}
  end
  eq(Options.cmds[1]({ chat = chat }, args, {}).status, 'success')
end

T['rejects invalid criteria and reversibility atomically'] = function()
  local chat = prepared_chat()
  local invalid_criterion = valid_args()
  invalid_criterion.criteria = { '   ' }
  eq(Options.cmds[1]({ chat = chat }, invalid_criterion, {}).data.code, 'options_invalid')
  local invalid_reversibility = valid_args()
  invalid_reversibility.options[1].reversibility = 'impossible'
  eq(Options.cmds[1]({ chat = chat }, invalid_reversibility, {}).data.code, 'options_invalid')
  eq(State.get(chat).counts_by_kind.branch, nil)
  local duplicate_criteria = valid_args()
  duplicate_criteria.criteria[2] = ' durability '
  eq(Options.cmds[1]({ chat = chat }, duplicate_criteria, {}).data.code, 'options_invalid')
end

T['applies max_array_items to the option count'] = function()
  Config.setup({ limits = { max_array_items = 2 } })
  local chat = prepared_chat()
  local args = valid_args()
  local third = vim.deepcopy(args.options[1])
  third.label = 'write-through file'
  table.insert(args.options, third)
  eq(Options.cmds[1]({ chat = chat }, args, {}).data.code, 'branch_count_insufficient')
  eq(State.get(chat).counts_by_kind.branch, nil)
end

return T
```

- [ ] **Step 2: Run and verify failure before implementation**

Run: `make test_file FILE=tests/codecompanion/_extensions/reasoning/tools/options_test.lua`

Expected: FAIL while requiring `tools.options`.

- [ ] **Step 3: Implement `Protocol.options(chat, args)` atomically**

Insert this exact function before `M.final_gates`; it reuses `normalized`, `text_array_valid`, and `active_reference` from Task 4:

```lua
function M.options(chat, args)
  local workspace = State.get(chat)
  if not workspace then
    return failure('workspace_missing', 'start a frame before creating branches', {}, 'Call reasoning_frame')
  end
  if type(args) ~= 'table'
    or not text_valid(args.question)
    or not vim.tbl_contains({ 'solution', 'hypothesis', 'scenario' }, args.branch_type)
    or not bounded_array(args.criteria, 1, math.min(8, Config.get().limits.max_array_items))
    or type(args.supersedes_branch_id) ~= 'string'
  then
    return failure('options_invalid', 'branch-set fields are invalid', {}, 'Correct reasoning_options fields')
  end
  local criteria = {}
  for _, criterion in ipairs(args.criteria) do
    if not text_valid(criterion) then
      return failure('options_invalid', 'criteria must contain bounded text', {}, 'Correct reasoning_options criteria')
    end
    local key = normalized(criterion)
    if criteria[key] then
      return failure('options_invalid', 'criteria must be unique', {}, 'Remove the duplicate criterion')
    end
    criteria[key] = true
  end
  if not bounded_array(args.options, 2, math.min(6, Config.get().limits.max_array_items)) then
    return failure('branch_count_insufficient', 'a branch set requires two to six options', {}, 'Provide competing options')
  end

  local active_branch
  for index = #workspace.artifact_order, 1, -1 do
    local artifact = State.find(workspace, workspace.artifact_order[index])
    if artifact.kind == 'branch' and artifact.status == 'active' then
      active_branch = artifact
      break
    end
  end
  if active_branch and args.supersedes_branch_id == '' then
    return failure(
      'options_invalid',
      'an active branch set must be explicitly superseded',
      { active_branch.id },
      'Set supersedes_branch_id to the active branch ID'
    )
  end

  local replaced
  if args.supersedes_branch_id ~= '' then
    local code
    replaced, code = active_reference(workspace, args.supersedes_branch_id)
    if code then
      return failure(code, 'the replaced branch set is unavailable', { args.supersedes_branch_id }, 'Use an active branch ID')
    end
    if replaced.kind ~= 'branch' then
      return failure('invalid_reference', 'supersedes_branch_id must name a branch set', { replaced.id }, 'Use an active B artifact')
    end
  end

  local labels = {}
  local prepared = {}
  for index, option in ipairs(args.options) do
    if type(option) ~= 'table'
      or not text_valid(option.label)
      or not text_valid(option.summary)
      or not text_array_valid(option.evidence_ids)
      or not text_array_valid(option.assumptions)
      or not text_array_valid(option.predictions)
      or not text_array_valid(option.benefits)
      or not text_array_valid(option.costs)
      or not text_array_valid(option.risks)
      or not vim.tbl_contains({ 'easy', 'moderate', 'hard' }, option.reversibility)
    then
      return failure('options_invalid', 'option ' .. index .. ' is invalid', {}, 'Correct the option fields')
    end
    local label = normalized(option.label)
    if labels[label] then
      return failure('options_invalid', 'option labels must be unique', {}, 'Rename the duplicate option')
    end
    labels[label] = true
    local seen_evidence = {}
    for _, id in ipairs(option.evidence_ids) do
      if seen_evidence[id] then
        return failure('options_invalid', 'option evidence_ids contains a duplicate', { id }, 'Remove the duplicate ID')
      end
      seen_evidence[id] = true
      local target, code = active_reference(workspace, id)
      if code then
        return failure(code, 'option evidence is unavailable', { id }, 'Use active evidence IDs')
      end
      if target.kind ~= 'evidence' then
        return failure('invalid_reference', 'option evidence_ids must name evidence', { id }, 'Use E artifact IDs')
      end
    end
    table.insert(prepared, vim.deepcopy(option))
  end

  if #workspace.artifact_order + 1 + #prepared > Config.get().limits.max_artifacts then
    return failure('limit_exceeded', 'the branch set exceeds the artifact limit', {}, 'Replace the workspace or reduce branches')
  end

  local branch_data = {
    question = args.question,
    branch_type = args.branch_type,
    criteria = vim.deepcopy(args.criteria),
    option_ids = {},
    supersedes_branch_id = args.supersedes_branch_id,
  }
  local branch = assert(State.add(workspace, 'branch', branch_data))
  local options = {}
  for _, option in ipairs(prepared) do
    local artifact = assert(State.add(workspace, 'option', option))
    table.insert(branch.data.option_ids, artifact.id)
    State.add_relation(artifact, 'depends_on', branch.id)
    for _, id in ipairs(option.evidence_ids) do
      State.add_relation(artifact, 'supports', id)
    end
    table.insert(options, artifact)
  end
  if replaced then
    State.supersede(workspace, replaced.id, branch.id)
    for _, id in ipairs(replaced.data.option_ids) do
      if State.find(workspace, id).status == 'active' then
        State.retire(workspace, id)
      end
    end
  end
  return {
    status = 'success',
    data = {
      workspace_id = workspace.id,
      artifact = vim.deepcopy(branch),
      artifacts = vim.deepcopy(options),
      progress = vim.deepcopy(workspace.counts_by_kind),
      unmet_gates = M.final_gates(workspace, nil),
      next_action = Guidance.next(workspace),
    },
  }
end
```

- [ ] **Step 4: Create `tools/options.lua` with the complete strict nested schema**

```lua
local Protocol = require('codecompanion._extensions.reasoning.protocol')

local string_array = { type = 'array', items = { type = 'string' } }

return {
  name = 'reasoning_options',
  cmds = {
    function(tools, args, opts)
      return Protocol.call('options', tools.chat, args)
    end,
  },
  schema = {
    type = 'function',
    ['function'] = {
      name = 'reasoning_options',
      description = 'Create or replace a coherent set of competing solutions, hypotheses, or scenarios.',
      parameters = {
        type = 'object',
        properties = {
          question = { type = 'string', description = 'The decision or uncertainty these branches address.' },
          branch_type = {
            type = 'string', enum = { 'solution', 'hypothesis', 'scenario' },
            description = 'Use solution for designs, hypothesis for diagnoses, and scenario for possible futures.',
          },
          criteria = vim.tbl_extend('force', vim.deepcopy(string_array), {
            description = 'One to eight criteria that distinguish the alternatives.',
          }),
          supersedes_branch_id = {
            type = 'string', description = 'Active B artifact replaced as one complete branch set, or an empty string.',
          },
          options = {
            type = 'array',
            items = {
              type = 'object',
              properties = {
                label = { type = 'string' },
                summary = { type = 'string' },
                evidence_ids = string_array,
                assumptions = string_array,
                predictions = string_array,
                benefits = string_array,
                costs = string_array,
                risks = string_array,
                reversibility = { type = 'string', enum = { 'easy', 'moderate', 'hard' } },
              },
              required = {
                'label', 'summary', 'evidence_ids', 'assumptions', 'predictions',
                'benefits', 'costs', 'risks', 'reversibility',
              },
              additionalProperties = false,
            },
          },
        },
        required = { 'question', 'branch_type', 'criteria', 'supersedes_branch_id', 'options' },
        additionalProperties = false,
      },
      strict = true,
    },
  },
}
```

- [ ] **Step 5: Run, format, and commit**

Run: `make test_file FILE=tests/codecompanion/_extensions/reasoning/tools/options_test.lua`

Expected: PASS for creation, validation, and replacement.

Run: `stylua lua/codecompanion/_extensions/reasoning/state.lua lua/codecompanion/_extensions/reasoning/protocol.lua lua/codecompanion/_extensions/reasoning/tools/options.lua tests/codecompanion/_extensions/reasoning/tools/options_test.lua -f stylua.toml`

Run: `make test_file FILE=tests/codecompanion/_extensions/reasoning/tools/options_test.lua`

Expected: PASS after formatting.

```bash
git add lua/codecompanion/_extensions/reasoning/protocol.lua lua/codecompanion/_extensions/reasoning/tools/options.lua tests/codecompanion/_extensions/reasoning/tools/options_test.lua
git commit -m "feat(reasoning): compare reasoning branches"
```

### Task 6: Add adversarial review and correction tracking

**Files:**
- Modify: `lua/codecompanion/_extensions/reasoning/protocol.lua`
- Create: `lua/codecompanion/_extensions/reasoning/tools/review.lua`
- Create: `tests/codecompanion/_extensions/reasoning/tools/review_test.lua`

- [ ] **Step 1: Write the complete failing review test file**

Create `review_test.lua` with this setup and the exact mutation/gate cases:

```lua
local Config = require('codecompanion._extensions.reasoning.config')
local Evidence = require('codecompanion._extensions.reasoning.tools.evidence')
local Frame = require('codecompanion._extensions.reasoning.tools.frame')
local Options = require('codecompanion._extensions.reasoning.tools.options')
local Review = require('codecompanion._extensions.reasoning.tools.review')
local State = require('codecompanion._extensions.reasoning.state')

local T = MiniTest.new_set({
  hooks = {
    pre_case = function()
      Config.setup()
      State._reset()
    end,
  },
})
local eq = MiniTest.expect.equality

local function prepare(temporal)
  local chat = {}
  local second_perspective = temporal and 'temporal' or 'operations'
  local frame = {
    action = 'start', objective = 'Choose a durable cache design', problem_type = 'design', depth = 'deep',
    constraints = { 'No external service' }, success_criteria = { 'Durable', 'Bounded' }, unknowns = {},
    perspectives = {
      { name = 'correctness', purpose = 'Find invalidation failures' },
      { name = second_perspective, purpose = 'Find lifecycle failures over time' },
    },
    temporal_required = temporal == true,
    branching_required = true, branching_rationale = 'Competing designs exist',
  }
  eq(Frame.cmds[1]({ chat = chat }, frame, {}).status, 'success')
  local evidence = {
    items = {
      {
        kind = 'observation', statement = 'The process may restart', source = 'user constraint', confidence = 'high',
        falsifier = 'The process lifetime is guaranteed', perspective = 'correctness', addresses_unknowns = {}, supports = {},
        contradicts = {}, qualifies = {}, supersedes_id = '',
      },
      {
        kind = 'claim', statement = 'Snapshots reduce write frequency', source = 'design derivation', confidence = 'medium',
        falsifier = 'Measured snapshot writes exceed journal writes', perspective = second_perspective, addresses_unknowns = {}, supports = {},
        contradicts = { 'E1' }, qualifies = {}, supersedes_id = '',
      },
    },
  }
  eq(Evidence.cmds[1]({ chat = chat }, evidence, {}).status, 'success')
  local options = {
    question = 'Which design?', branch_type = 'solution', criteria = { 'Durability', 'Memory' },
    supersedes_branch_id = '',
    options = {
      {
        label = 'journal', summary = 'Append mutations', evidence_ids = { 'E1' },
        assumptions = { 'Disk works' }, predictions = { 'Replay restores state' }, benefits = { 'Durable' },
        costs = { 'Compaction' }, risks = { 'Torn writes' }, reversibility = 'moderate',
      },
      {
        label = 'snapshot', summary = 'Write snapshots', evidence_ids = { 'E2' },
        assumptions = { 'State fits' }, predictions = { 'Recovery uses last snapshot' }, benefits = { 'Simple' },
        costs = { 'Full writes' }, risks = { 'Stale state' }, reversibility = 'easy',
      },
    },
  }
  eq(Options.cmds[1]({ chat = chat }, options, {}).status, 'success')
  return chat
end

local function full_review()
  return {
    mode = 'full',
    target_ids = { 'O1', 'E1' },
    defense = { summary = 'The journal is supported by restart requirements', evidence_ids = { 'E1' } },
    challenges = {
      {
        kind = 'counterexample', summary = 'A torn journal record can prevent recovery', target_ids = { 'O1' },
        falsifier = 'Recovery succeeds after truncating every possible partial suffix',
      },
      {
        kind = 'hidden_assumption', summary = 'Atomic rename behavior is assumed', target_ids = { 'O1' },
        falsifier = 'The selected filesystem documents the required atomicity',
      },
    },
    blind_spots = { 'Behavior on disk exhaustion' },
    stress_tests = {},
    verdicts = {
      { target_id = 'O1', status = 'revise', revision_instruction = 'Add torn-write recovery' },
      { target_id = 'E1', status = 'keep', revision_instruction = '' },
    },
    contradiction_resolutions = {},
    structural_tradeoffs = {},
  }
end

T['records a full review and an open revision'] = function()
  local chat = prepare()
  local result = Review.cmds[1]({ chat = chat }, full_review(), {})
  eq(result.status, 'success')
  eq(result.data.artifact.id, 'R1')
  eq(State.get(chat).open_revisions.O1, 'R1')
  eq(State.find(State.get(chat), 'R1').relations.depends_on, { 'O1', 'E1' })
  eq(State.find(State.get(chat), 'R1').relations.supports, { 'E1' })
end

T['rejects incomplete verdict coverage without mutation'] = function()
  local chat = prepare()
  local args = full_review()
  args.verdicts[2] = nil
  local result = Review.cmds[1]({ chat = chat }, args, {})
  eq(result.data.code, 'review_incomplete')
  eq(State.get(chat).counts_by_kind.review, nil)
  eq(State.find(State.get(chat), 'O1').status, 'active')
end

T['applies retraction immediately'] = function()
  local chat = prepare()
  local args = full_review()
  args.target_ids = { 'B1' }
  args.challenges[1].target_ids = { 'B1' }
  args.challenges[2].target_ids = { 'B1' }
  args.verdicts = { { target_id = 'B1', status = 'retract', revision_instruction = '' } }
  local result = Review.cmds[1]({ chat = chat }, args, {})
  eq(result.status, 'success')
  eq(State.find(State.get(chat), 'B1').status, 'retracted')
  eq(State.find(State.get(chat), 'O1').status, 'retracted')
  eq(State.find(State.get(chat), 'O2').status, 'retracted')
end

T['rejects direct option retraction without mutation'] = function()
  local chat = prepare()
  local args = full_review()
  args.target_ids = { 'O1' }
  args.challenges[1].target_ids = { 'O1' }
  args.challenges[2].target_ids = { 'O1' }
  args.verdicts = { { target_id = 'O1', status = 'retract', revision_instruction = '' } }
  local result = Review.cmds[1]({ chat = chat }, args, {})
  eq(result.data.code, 'review_incomplete')
  eq(result.data.next_action.tool, 'reasoning_options')
  eq(State.find(State.get(chat), 'O1').status, 'active')
  eq(State.get(chat).counts_by_kind.review, nil)
end

T['clears an evidence revision only after typed supersession'] = function()
  local chat = prepare()
  local args = full_review()
  args.target_ids = { 'E1' }
  args.challenges[1].target_ids = { 'E1' }
  args.challenges[2].target_ids = { 'E1' }
  args.verdicts = { { target_id = 'E1', status = 'revise', revision_instruction = 'Measure restart behavior' } }
  eq(Review.cmds[1]({ chat = chat }, args, {}).status, 'success')
  local replacement = {
    kind = 'observation', statement = 'The process may restart', source = 'tests/restart.lua:9', confidence = 'high',
    falsifier = 'The process lifetime is guaranteed', perspective = 'correctness', addresses_unknowns = {}, supports = {},
    contradicts = {}, qualifies = {}, supersedes_id = 'E1',
  }
  eq(Evidence.cmds[1]({ chat = chat }, { items = { replacement } }, {}).status, 'success')
  eq(State.get(chat).open_revisions.E1, nil)
end

T['requires temporal stress tests'] = function()
  local chat = prepare()
  local args = full_review()
  args.mode = 'temporal'
  eq(Review.cmds[1]({ chat = chat }, args, {}).data.code, 'review_incomplete')
  args.stress_tests = {
    { scenario = 'Three compaction cycles', prediction = 'Recovery remains complete', failure_signal = 'A key disappears' },
  }
  local result = Review.cmds[1]({ chat = chat }, args, {})
  eq(result.status, 'success')
  eq(State.find(State.get(chat), result.data.artifact.id).relations.tests, { 'O1', 'E1' })
end

T['accepts every non-temporal review mode'] = function()
  for _, mode in ipairs({ 'falsification', 'assumptions', 'cross_perspective', 'full' }) do
    State._reset()
    local chat = prepare()
    local args = full_review()
    args.mode = mode
    eq(Review.cmds[1]({ chat = chat }, args, {}).status, 'success')
  end
end

T['requires stress tests for an explicitly temporal frame'] = function()
  local chat = prepare(true)
  local args = full_review()
  eq(Review.cmds[1]({ chat = chat }, args, {}).data.code, 'review_incomplete')
  args.stress_tests = {
    { scenario = 'Three lifecycle transitions', prediction = 'State remains valid', failure_signal = 'Recovery diverges' },
  }
  eq(Review.cmds[1]({ chat = chat }, args, {}).status, 'success')
end

T['rejects structural tradeoffs with invalid evidence'] = function()
  local chat = prepare()
  local args = full_review()
  args.structural_tradeoffs = {
    { statement = 'Durability increases writes', evidence_ids = { 'E99' }, falsifier = 'A durable zero-write design' },
  }
  eq(Review.cmds[1]({ chat = chat }, args, {}).data.code, 'invalid_reference')
end

T['resolves a reviewed contradiction pair'] = function()
  local chat = prepare()
  local args = full_review()
  args.target_ids = { 'E1', 'E2' }
  args.challenges[1].target_ids = { 'E1' }
  args.challenges[2].target_ids = { 'E2' }
  args.verdicts = {
    { target_id = 'E1', status = 'keep', revision_instruction = '' },
    { target_id = 'E2', status = 'keep', revision_instruction = '' },
  }
  args.contradiction_resolutions = {
    {
      left_id = 'E1',
      right_id = 'E2',
      resolution = 'E2 qualifies E1 only for write frequency; it does not refute restart requirements',
      evidence_ids = { 'E1', 'E2' },
    },
  }
  local result = Review.cmds[1]({ chat = chat }, args, {})
  eq(result.status, 'success')
  eq(State.get(chat).resolved_contradictions['E1:E2'], 'R1')
  eq(State.find(State.get(chat), 'R1').relations.qualifies, { 'E1', 'E2' })
end

T['does not resolve a contradiction from unrelated keep verdicts'] = function()
  local chat = prepare()
  local args = full_review()
  args.target_ids = { 'E1', 'E2' }
  args.challenges[1].target_ids = { 'E1' }
  args.challenges[2].target_ids = { 'E2' }
  args.verdicts = {
    { target_id = 'E1', status = 'keep', revision_instruction = '' },
    { target_id = 'E2', status = 'keep', revision_instruction = '' },
  }
  eq(Review.cmds[1]({ chat = chat }, args, {}).status, 'success')
  eq(State.get(chat).resolved_contradictions['E1:E2'], nil)
end

T['rejects reversed duplicate contradiction resolutions atomically'] = function()
  local chat = prepare()
  local args = full_review()
  args.target_ids = { 'E1', 'E2' }
  args.challenges[1].target_ids = { 'E1' }
  args.challenges[2].target_ids = { 'E2' }
  args.verdicts = {
    { target_id = 'E1', status = 'keep', revision_instruction = '' },
    { target_id = 'E2', status = 'keep', revision_instruction = '' },
  }
  local resolution = {
    left_id = 'E1', right_id = 'E2', resolution = 'The claims apply to different scopes', evidence_ids = { 'E1' },
  }
  args.contradiction_resolutions = {
    resolution,
    {
      left_id = 'E2', right_id = 'E1', resolution = 'The same pair in reverse', evidence_ids = { 'E2' },
    },
  }
  eq(Review.cmds[1]({ chat = chat }, args, {}).data.code, 'review_incomplete')
  eq(State.get(chat).counts_by_kind.review, nil)
end

return T
```

- [ ] **Step 2: Run and verify the review module is missing**

Run: `make test_file FILE=tests/codecompanion/_extensions/reasoning/tools/review_test.lua`

Expected: FAIL while requiring `tools.review`.

- [ ] **Step 3: Implement `Protocol.review(chat, args)`**

Insert the following block before `M.final_gates`:

```lua
local function contradiction_key(left, right)
  if left > right then
    left, right = right, left
  end
  return left .. ':' .. right
end

local function validate_evidence_ids(workspace, ids)
  if not text_array_valid(ids) then
    return nil, 'review_incomplete'
  end
  for _, id in ipairs(ids) do
    local target, code = active_reference(workspace, id)
    if code then
      return nil, code, id
    end
    if target.kind ~= 'evidence' then
      return nil, 'invalid_reference', id
    end
  end
  return true
end

function M.review(chat, args)
  local workspace = State.get(chat)
  if not workspace then
    return failure('workspace_missing', 'start a frame before review', {}, 'Call reasoning_frame')
  end
  local modes = { 'falsification', 'assumptions', 'temporal', 'cross_perspective', 'full' }
  if type(args) ~= 'table'
    or not vim.tbl_contains(modes, args.mode)
    or not text_array_valid(args.target_ids, 1)
  then
    return failure('review_incomplete', 'mode and target_ids are required', {}, 'Correct reasoning_review fields')
  end

  local targets = {}
  for _, id in ipairs(args.target_ids) do
    if targets[id] then
      return failure('review_incomplete', 'target_ids must be unique', { id }, 'Remove the duplicate target')
    end
    local target, code = active_reference(workspace, id)
    if code then
      return failure(code, 'review target is unavailable', { id }, 'Use an active artifact ID')
    end
    if target.kind == 'review' then
      return failure('invalid_reference', 'reviews cannot revise another review artifact', { id }, 'Target a frame, evidence, branch, option, or synthesis')
    end
    targets[id] = target
  end

  if type(args.defense) ~= 'table' or not text_valid(args.defense.summary) then
    return failure('review_incomplete', 'a bounded defense summary is required', {}, 'Add the strongest surviving defense')
  end
  local evidence_ok, evidence_code, evidence_id = validate_evidence_ids(workspace, args.defense.evidence_ids)
  if not evidence_ok then
    return failure(evidence_code, 'defense evidence is invalid', evidence_id and { evidence_id } or {}, 'Use active evidence IDs')
  end
  if args.mode == 'full' and #args.defense.evidence_ids == 0 then
    return failure('review_incomplete', 'full review requires defense evidence', {}, 'Add evidence to the defense')
  end

  if not bounded_array(args.challenges, 1, Config.get().limits.max_array_items) then
    return failure('review_incomplete', 'at least one challenge is required', {}, 'Add an adversarial challenge')
  end
  local challenge_kinds = {
    'counterexample', 'missing_evidence', 'hidden_assumption', 'temporal_failure', 'overclaim', 'underclaim',
  }
  local has_disconfirmation, has_hidden_assumption = false, false
  for index, challenge in ipairs(args.challenges) do
    if type(challenge) ~= 'table'
      or not vim.tbl_contains(challenge_kinds, challenge.kind)
      or not text_valid(challenge.summary)
      or not text_array_valid(challenge.target_ids, 1)
      or not text_valid(challenge.falsifier)
    then
      return failure('review_incomplete', 'challenge ' .. index .. ' is invalid', {}, 'Correct the challenge fields')
    end
    for _, id in ipairs(challenge.target_ids) do
      if not targets[id] then
        return failure('invalid_reference', 'challenge targets must be in target_ids', { id }, 'Add the target to target_ids')
      end
    end
    has_disconfirmation = has_disconfirmation
      or vim.tbl_contains({ 'counterexample', 'missing_evidence', 'temporal_failure', 'overclaim' }, challenge.kind)
    has_hidden_assumption = has_hidden_assumption or challenge.kind == 'hidden_assumption'
  end
  if not text_array_valid(args.blind_spots, args.mode == 'full' and 1 or 0) then
    return failure('review_incomplete', 'blind_spots is invalid for this mode', {}, 'Record a blind spot')
  end
  if args.mode == 'full' and (not has_disconfirmation or not has_hidden_assumption) then
    return failure('review_incomplete', 'full review requires disconfirmation and a hidden assumption', {}, 'Add both challenge types')
  end
  if args.mode == 'falsification' and not has_disconfirmation then
    return failure('review_incomplete', 'falsification review requires a disconfirming challenge', {}, 'Add a falsifiable attack')
  end
  if args.mode == 'assumptions' and not has_hidden_assumption then
    return failure('review_incomplete', 'assumptions review requires a hidden-assumption challenge', {}, 'Expose a hidden assumption')
  end
  if args.mode == 'cross_perspective' and #args.target_ids < 2 then
    return failure('review_incomplete', 'cross-perspective review requires at least two targets', args.target_ids, 'Add another perspective target')
  end

  if not bounded_array(args.stress_tests, 0, Config.get().limits.max_array_items) then
    return failure('review_incomplete', 'stress_tests is invalid', {}, 'Correct the stress tests')
  end
  for index, test in ipairs(args.stress_tests) do
    if type(test) ~= 'table'
      or not text_valid(test.scenario)
      or not text_valid(test.prediction)
      or not text_valid(test.failure_signal)
    then
      return failure('review_incomplete', 'stress test ' .. index .. ' is invalid', {}, 'Correct the stress-test fields')
    end
  end
  local frame = State.find(workspace, workspace.frame_id)
  if (args.mode == 'temporal' or frame.data.temporal_required) and #args.stress_tests == 0 then
    return failure('review_incomplete', 'temporal reasoning requires a stress test', {}, 'Add a temporal stress test')
  end

  if not bounded_array(args.verdicts, #args.target_ids, #args.target_ids) then
    return failure('review_incomplete', 'every target requires exactly one verdict', args.target_ids, 'Cover every target')
  end
  local verdicts = {}
  for _, verdict in ipairs(args.verdicts) do
    if type(verdict) ~= 'table'
      or not targets[verdict.target_id]
      or verdicts[verdict.target_id]
      or not vim.tbl_contains({ 'keep', 'revise', 'retract' }, verdict.status)
      or type(verdict.revision_instruction) ~= 'string'
      or vim.fn.strchars(verdict.revision_instruction) > Config.get().limits.max_text_chars
      or (verdict.status == 'revise' and not text_valid(verdict.revision_instruction))
      or (verdict.status ~= 'revise' and verdict.revision_instruction ~= '')
    then
      return failure('review_incomplete', 'verdicts must uniquely cover every target', args.target_ids, 'Correct the verdicts')
    end
    verdicts[verdict.target_id] = verdict.status
    if targets[verdict.target_id].kind == 'option' and verdict.status == 'retract' then
      return failure(
        'review_incomplete',
        'an option cannot be retracted independently of its branch set',
        { verdict.target_id },
        {
          tool = 'reasoning_options',
          reason = 'Revise the option and replace the complete branch set',
        }
      )
    end
  end

  if not bounded_array(args.contradiction_resolutions, 0, Config.get().limits.max_array_items) then
    return failure('review_incomplete', 'contradiction_resolutions is invalid', {}, 'Correct the contradiction resolutions')
  end
  local contradiction_pairs = {}
  for index, resolution in ipairs(args.contradiction_resolutions) do
    if type(resolution) ~= 'table'
      or not text_valid(resolution.left_id)
      or not text_valid(resolution.right_id)
      or resolution.left_id == resolution.right_id
      or not text_valid(resolution.resolution)
      or not bounded_array(resolution.evidence_ids, 1, Config.get().limits.max_array_items)
    then
      return failure('review_incomplete', 'contradiction resolution ' .. index .. ' is invalid', {}, 'Correct the contradiction resolution')
    end
    local left, right = targets[resolution.left_id], targets[resolution.right_id]
    if not left or not right then
      return failure('invalid_reference', 'contradiction endpoints must both be reviewed', { resolution.left_id, resolution.right_id }, 'Target both contradictory artifacts')
    end
    if verdicts[left.id] ~= 'keep' or verdicts[right.id] ~= 'keep' then
      return failure('review_incomplete', 'resolved contradiction endpoints require keep verdicts', { left.id, right.id }, 'Keep both qualified endpoints or omit the resolution')
    end
    local actual = vim.tbl_contains(left.relations.contradicts, right.id)
      or vim.tbl_contains(right.relations.contradicts, left.id)
    if not actual then
      return failure('review_incomplete', 'the resolution does not name an active contradiction', { left.id, right.id }, 'Resolve an actual contradiction pair')
    end
    local key = contradiction_key(left.id, right.id)
    if contradiction_pairs[key] then
      return failure('review_incomplete', 'a contradiction pair may be resolved once per review', { left.id, right.id }, 'Remove the duplicate resolution')
    end
    local ok, code, id = validate_evidence_ids(workspace, resolution.evidence_ids)
    if not ok then
      return failure(code, 'contradiction-resolution evidence is invalid', id and { id } or {}, 'Use active evidence IDs')
    end
    contradiction_pairs[key] = resolution
  end

  if not bounded_array(args.structural_tradeoffs, 0, Config.get().limits.max_array_items) then
    return failure('review_incomplete', 'structural_tradeoffs is invalid', {}, 'Correct the tradeoffs')
  end
  for index, tradeoff in ipairs(args.structural_tradeoffs) do
    if type(tradeoff) ~= 'table' or not text_valid(tradeoff.statement) or not text_valid(tradeoff.falsifier) then
      return failure('review_incomplete', 'structural tradeoff ' .. index .. ' is invalid', {}, 'Correct the tradeoff')
    end
    local ok, code, id = validate_evidence_ids(workspace, tradeoff.evidence_ids)
    if not ok then
      return failure(code, 'structural tradeoff evidence is invalid', id and { id } or {}, 'Use active evidence IDs')
    end
  end
  if #workspace.artifact_order >= Config.get().limits.max_artifacts then
    return failure('limit_exceeded', 'the review exceeds the artifact limit', {}, 'Replace the workspace')
  end

  local review = assert(State.add(workspace, 'review', vim.deepcopy(args)))
  for _, id in ipairs(args.target_ids) do
    State.add_relation(review, 'depends_on', id)
  end
  if #args.stress_tests > 0 then
    for _, id in ipairs(args.target_ids) do
      State.add_relation(review, 'tests', id)
    end
  end
  for _, id in ipairs(args.defense.evidence_ids) do
    State.add_relation(review, 'supports', id)
  end
  for _, resolution in ipairs(args.contradiction_resolutions) do
    State.add_relation(review, 'qualifies', resolution.left_id)
    State.add_relation(review, 'qualifies', resolution.right_id)
    for _, id in ipairs(resolution.evidence_ids) do
      if not vim.tbl_contains(review.relations.supports, id) then
        State.add_relation(review, 'supports', id)
      end
    end
  end
  for _, verdict in ipairs(args.verdicts) do
    if verdict.status == 'retract' then
      State.retract(workspace, verdict.target_id)
      local target = targets[verdict.target_id]
      if target.kind == 'branch' then
        for _, option_id in ipairs(target.data.option_ids) do
          if State.find(workspace, option_id).status == 'active' then
            State.retract(workspace, option_id)
          end
        end
      end
    elseif verdict.status == 'revise' then
      workspace.open_revisions[verdict.target_id] = review.id
    end
  end
  for key in pairs(contradiction_pairs) do
    workspace.resolved_contradictions[key] = review.id
  end
  return success(workspace, review)
end
```

- [ ] **Step 4: Create the complete strict review tool schema**

```lua
local Protocol = require('codecompanion._extensions.reasoning.protocol')

local string_array = { type = 'array', items = { type = 'string' } }

return {
  name = 'reasoning_review',
  cmds = {
    function(tools, args, opts)
      return Protocol.call('review', tools.chat, args)
    end,
  },
  schema = {
    type = 'function',
    ['function'] = {
      name = 'reasoning_review',
      description = 'Adversarially review active artifacts, expose assumptions and blind spots, and record keep, revise, or retract verdicts.',
      parameters = {
        type = 'object',
        properties = {
          mode = {
            type = 'string',
            enum = { 'falsification', 'assumptions', 'temporal', 'cross_perspective', 'full' },
            description = 'Select the adversarial lens; full combines defense, disconfirmation, hidden assumptions, and blind spots.',
          },
          target_ids = string_array,
          defense = {
            type = 'object',
            properties = { summary = { type = 'string' }, evidence_ids = string_array },
            required = { 'summary', 'evidence_ids' },
            additionalProperties = false,
          },
          challenges = {
            type = 'array',
            items = {
              type = 'object',
              properties = {
                kind = {
                  type = 'string',
                  enum = {
                    'counterexample', 'missing_evidence', 'hidden_assumption',
                    'temporal_failure', 'overclaim', 'underclaim',
                  },
                },
                summary = { type = 'string' },
                target_ids = string_array,
                falsifier = { type = 'string' },
              },
              required = { 'kind', 'summary', 'target_ids', 'falsifier' },
              additionalProperties = false,
            },
          },
          blind_spots = string_array,
          stress_tests = {
            type = 'array',
            items = {
              type = 'object',
              properties = {
                scenario = { type = 'string' },
                prediction = { type = 'string' },
                failure_signal = { type = 'string' },
              },
              required = { 'scenario', 'prediction', 'failure_signal' },
              additionalProperties = false,
            },
          },
          verdicts = {
            type = 'array',
            items = {
              type = 'object',
              properties = {
                target_id = { type = 'string' },
                status = { type = 'string', enum = { 'keep', 'revise', 'retract' } },
                revision_instruction = {
                  type = 'string', description = 'Required correction for revise; an empty string for keep or retract.',
                },
              },
              required = { 'target_id', 'status', 'revision_instruction' },
              additionalProperties = false,
            },
          },
          contradiction_resolutions = {
            type = 'array',
            items = {
              type = 'object',
              properties = {
                left_id = { type = 'string' },
                right_id = { type = 'string' },
                resolution = {
                  type = 'string',
                  description = 'Explicit qualification or resolution that permits both contradictory artifacts to remain active.',
                },
                evidence_ids = string_array,
              },
              required = { 'left_id', 'right_id', 'resolution', 'evidence_ids' },
              additionalProperties = false,
            },
          },
          structural_tradeoffs = {
            type = 'array',
            items = {
              type = 'object',
              properties = {
                statement = { type = 'string' }, evidence_ids = string_array, falsifier = { type = 'string' },
              },
              required = { 'statement', 'evidence_ids', 'falsifier' },
              additionalProperties = false,
            },
          },
        },
        required = {
          'mode', 'target_ids', 'defense', 'challenges', 'blind_spots',
          'stress_tests', 'verdicts', 'contradiction_resolutions', 'structural_tradeoffs',
        },
        additionalProperties = false,
      },
      strict = true,
    },
  },
}
```

- [ ] **Step 5: Run, format, and commit**

Run: `make test_file FILE=tests/codecompanion/_extensions/reasoning/tools/review_test.lua`

Expected: PASS for all review modes and mutation rules.

Run: `stylua lua/codecompanion/_extensions/reasoning/protocol.lua lua/codecompanion/_extensions/reasoning/tools/review.lua tests/codecompanion/_extensions/reasoning/tools/review_test.lua -f stylua.toml`

Run: `make test_file FILE=tests/codecompanion/_extensions/reasoning/tools/review_test.lua`

Expected: PASS after formatting.

```bash
git add lua/codecompanion/_extensions/reasoning/protocol.lua lua/codecompanion/_extensions/reasoning/tools/review.lua tests/codecompanion/_extensions/reasoning/tools/review_test.lua
git commit -m "feat(reasoning): add adversarial review"
```

### Task 7: Enforce deep synthesis gates and deterministic guidance

**Files:**
- Modify: `lua/codecompanion/_extensions/reasoning/protocol.lua`
- Modify: `lua/codecompanion/_extensions/reasoning/guidance.lua`
- Create: `lua/codecompanion/_extensions/reasoning/tools/synthesis.lua`
- Create: `tests/codecompanion/_extensions/reasoning/tools/synthesis_test.lua`
- Create: `tests/codecompanion/_extensions/reasoning/guidance_test.lua`

- [ ] **Step 1: Write the complete failing synthesis-gate test file**

Create `synthesis_test.lua` with helpers that build every state through public tool commands:

```lua
local Config = require('codecompanion._extensions.reasoning.config')
local Evidence = require('codecompanion._extensions.reasoning.tools.evidence')
local Frame = require('codecompanion._extensions.reasoning.tools.frame')
local Options = require('codecompanion._extensions.reasoning.tools.options')
local Review = require('codecompanion._extensions.reasoning.tools.review')
local State = require('codecompanion._extensions.reasoning.state')
local Synthesis = require('codecompanion._extensions.reasoning.tools.synthesis')

local T = MiniTest.new_set({
  hooks = {
    pre_case = function()
      Config.setup()
      State._reset()
    end,
  },
})
local eq = MiniTest.expect.equality

local function contains(values, expected)
  eq(vim.tbl_contains(values, expected), true)
end

local function add_frame(chat, depth, branching, unknowns, temporal_required)
  return Frame.cmds[1]({ chat = chat }, {
    action = 'start', objective = 'Choose a durable cache design',
    problem_type = branching and 'design' or 'analysis', depth = depth,
    constraints = { 'No external service' },
    success_criteria = { 'Survives process restart', 'Bounded memory' }, unknowns = unknowns or {},
    perspectives = depth == 'deep' and {
      { name = 'correctness', purpose = 'Find recovery failures' },
      { name = 'operations', purpose = 'Find lifecycle failures' },
    } or { { name = 'correctness', purpose = 'Find recovery failures' } },
    temporal_required = temporal_required == true,
    branching_required = branching,
    branching_rationale = branching and 'Competing designs exist' or 'This analysis tests one claim',
  }, {})
end

local function add_evidence(chat, statement, perspective, contradicts, addresses_unknowns)
  return Evidence.cmds[1]({ chat = chat }, {
    items = {
      {
        kind = 'observation', statement = statement, source = 'tests/recovery.lua:10', confidence = 'high',
        falsifier = 'A controlled test produces the opposite result', perspective = perspective,
        addresses_unknowns = addresses_unknowns or {},
        supports = {}, contradicts = contradicts or {}, qualifies = {}, supersedes_id = '',
      },
    },
  }, {})
end

local function add_options(chat, supported)
  local ids = supported == false and {} or { 'E1' }
  return Options.cmds[1]({ chat = chat }, {
    question = 'Which design?', branch_type = 'solution', criteria = { 'Durability', 'Memory' },
    supersedes_branch_id = '',
    options = {
      {
        label = 'journal', summary = 'Append checksummed mutations', evidence_ids = ids,
        assumptions = { 'Disk writes work' }, predictions = { 'Replay restores state' }, benefits = { 'Durability' },
        costs = { 'Compaction' }, risks = { 'Torn writes' }, reversibility = 'moderate',
      },
      {
        label = 'snapshot', summary = 'Write atomic snapshots', evidence_ids = { 'E1' },
        assumptions = { 'State fits' }, predictions = { 'Restart loads a snapshot' }, benefits = { 'Simplicity' },
        costs = { 'Full writes' }, risks = { 'Stale state' }, reversibility = 'easy',
      },
    },
  }, {})
end

local function add_review(chat, revise, target_ids, temporal)
  target_ids = target_ids or { 'O1', 'E1' }
  local verdicts = {}
  for _, id in ipairs(target_ids) do
    table.insert(verdicts, {
      target_id = id,
      status = revise and id == target_ids[1] and 'revise' or 'keep',
      revision_instruction = revise and id == target_ids[1] and 'Correct the selected artifact' or '',
    })
  end
  return Review.cmds[1]({ chat = chat }, {
    mode = 'full', target_ids = target_ids,
    defense = { summary = 'Restart evidence supports the journal', evidence_ids = { 'E1' } },
    challenges = {
      {
        kind = 'counterexample', summary = 'A torn write can break replay', target_ids = { target_ids[1] },
        falsifier = 'Truncation recovery succeeds for every partial suffix',
      },
      {
        kind = 'hidden_assumption', summary = 'Atomic filesystem behavior is assumed', target_ids = { target_ids[1] },
        falsifier = 'Filesystem documentation guarantees the operation',
      },
    },
    blind_spots = { 'Disk exhaustion' },
    stress_tests = temporal and {
      {
        scenario = 'Three restart and compaction cycles',
        prediction = 'Recovery remains complete',
        failure_signal = 'A committed key disappears',
      },
    } or {},
    verdicts = verdicts,
    contradiction_resolutions = {}, structural_tradeoffs = {},
  }, {})
end

local function resolve_contradiction(chat, evidence_id)
  return Review.cmds[1]({ chat = chat }, {
    mode = 'full', target_ids = { 'E1', 'E2' },
    defense = { summary = 'Both observations apply to different scopes', evidence_ids = { evidence_id } },
    challenges = {
      {
        kind = 'counterexample', summary = 'The scopes may still overlap', target_ids = { 'E1' },
        falsifier = 'A controlled trace shows the scopes never overlap',
      },
      {
        kind = 'hidden_assumption', summary = 'Scope separation is assumed', target_ids = { 'E2' },
        falsifier = 'The source explicitly defines separate scopes',
      },
    },
    blind_spots = { 'A third runtime mode may exist' }, stress_tests = {},
    verdicts = {
      { target_id = 'E1', status = 'keep', revision_instruction = '' },
      { target_id = 'E2', status = 'keep', revision_instruction = '' },
    },
    contradiction_resolutions = {
      {
        left_id = 'E1', right_id = 'E2',
        resolution = 'The claims are retained as scope-qualified observations', evidence_ids = { evidence_id },
      },
    },
    structural_tradeoffs = {},
  }, {})
end

local function final_args()
  return {
    mode = 'final',
    conclusion = 'Use a journal with checksummed records and truncation recovery',
    selected_option_ids = { 'O1' }, support_ids = { 'E1', 'E2' }, review_ids = { 'R1' },
    criterion_results = {
      {
        criterion = 'Survives process restart', status = 'passed', evidence_ids = { 'E1' },
        explanation = 'Recovery test replays committed records',
      },
      {
        criterion = 'Bounded memory', status = 'passed', evidence_ids = { 'E2' },
        explanation = 'Compaction bounds retained entries',
      },
    },
    tradeoffs = { 'More write amplification for deterministic recovery' },
    uncertainties = { 'Disk-full behavior needs platform testing' },
    blind_spots = { 'Network filesystems were not evaluated' },
    next_actions = { 'Implement the journal behind the cache interface' }, confidence = 'medium',
  }
end

local function deep_workspace(opts)
  opts = opts or {}
  local chat = {}
  eq(add_frame(chat, 'deep', true).status, 'success')
  eq(add_evidence(chat, 'Restart loses process-local state', 'correctness').status, 'success')
  if not opts.one_perspective then
    eq(add_evidence(chat, 'Compaction bounds retained entries', 'operations', opts.contradiction and { 'E1' } or {}).status, 'success')
  end
  if not opts.no_branches then
    eq(add_options(chat, not opts.unsupported_option).status, 'success')
  end
  if not opts.no_review and not opts.no_branches then
    eq(add_review(chat, opts.open_revision).status, 'success')
  end
  return chat
end

T['checkpoint succeeds and reports the highest-priority gate'] = function()
  local chat = {}
  eq(add_frame(chat, 'deep', true).status, 'success')
  local args = final_args()
  args.mode = 'checkpoint'
  args.selected_option_ids, args.support_ids, args.review_ids, args.criterion_results = {}, {}, {}, {}
  local result = Synthesis.cmds[1]({ chat = chat }, args, {})
  eq(result.status, 'success')
  contains(result.data.unmet_gates, 'evidence_missing')
  eq(result.data.next_action.tool, 'reasoning_evidence')
end

T['deep final requires two-perspective evidence'] = function()
  local args = final_args()
  args.support_ids = { 'E1' }
  args.criterion_results[2].evidence_ids = { 'E1' }
  local result = Synthesis.cmds[1]({ chat = deep_workspace({ one_perspective = true }) }, args, {})
  eq(result.data.code, 'synthesis_gate_failed')
  contains(result.data.unmet_gates, 'perspective_coverage_missing')
end

T['final requires evidence coverage for framed unknowns'] = function()
  local chat = {}
  eq(add_frame(chat, 'standard', false, { 'Expected write rate' }).status, 'success')
  eq(add_evidence(chat, 'Restart loses process-local state', 'correctness').status, 'success')
  local args = final_args()
  args.selected_option_ids, args.review_ids = {}, {}
  args.support_ids = { 'E1' }
  args.criterion_results[2].evidence_ids = { 'E1' }
  contains(Synthesis.cmds[1]({ chat = chat }, args, {}).data.unmet_gates, 'unknown_coverage_missing')

  eq(add_evidence(chat, 'Write rate is bounded', 'correctness', {}, { 'Expected write rate' }).status, 'success')
  args.support_ids = { 'E1', 'E2' }
  args.criterion_results[2].evidence_ids = { 'E2' }
  eq(Synthesis.cmds[1]({ chat = chat }, args, {}).status, 'success')

  State.retract(State.get(chat), 'E2')
  args.support_ids = { 'E1' }
  args.criterion_results[2].evidence_ids = { 'E1' }
  contains(Synthesis.cmds[1]({ chat = chat }, args, {}).data.unmet_gates, 'unknown_coverage_missing')
end

T['final requires branches when the frame requires them'] = function()
  local args = final_args()
  args.selected_option_ids = {}
  args.review_ids = {}
  local result = Synthesis.cmds[1]({ chat = deep_workspace({ no_branches = true, no_review = true }) }, args, {})
  contains(result.data.unmet_gates, 'branches_missing')
end

T['deep final requires a full review of selected support'] = function()
  local args = final_args()
  args.review_ids = {}
  local result = Synthesis.cmds[1]({ chat = deep_workspace({ no_review = true }) }, args, {})
  contains(result.data.unmet_gates, 'full_review_missing')
end

T['final blocks open revisions and unresolved contradictions'] = function()
  local revised = Synthesis.cmds[1]({ chat = deep_workspace({ open_revision = true }) }, final_args(), {})
  contains(revised.data.unmet_gates, 'revision_unresolved')
  local contradicted = Synthesis.cmds[1]({ chat = deep_workspace({ contradiction = true }) }, final_args(), {})
  contains(contradicted.data.unmet_gates, 'contradiction_unresolved')
end

T['frame and selected branch revisions cannot be bypassed by option selection'] = function()
  for _, case in ipairs({
    { target_id = 'F1', tool = 'reasoning_frame' },
    { target_id = 'B1', tool = 'reasoning_options' },
  }) do
    State._reset()
    local chat = deep_workspace()
    eq(add_review(chat, true, { case.target_id }).status, 'success')
    local result = Synthesis.cmds[1]({ chat = chat }, final_args(), {})
    contains(result.data.unmet_gates, 'revision_unresolved')
    eq(result.data.next_action.tool, case.tool)
  end
end

T['final revalidates cited contradiction resolutions and their evidence'] = function()
  local chat = deep_workspace({ contradiction = true })
  eq(add_evidence(chat, 'The claims refer to distinct runtime scopes', 'correctness').status, 'success')
  eq(resolve_contradiction(chat, 'E3').status, 'success')
  local args = final_args()
  contains(Synthesis.cmds[1]({ chat = chat }, args, {}).data.unmet_gates, 'contradiction_unresolved')

  args.review_ids = { 'R1', 'R2' }
  eq(Synthesis.cmds[1]({ chat = chat }, args, {}).status, 'success')

  State.retract(State.get(chat), 'E3')
  contains(Synthesis.cmds[1]({ chat = chat }, args, {}).data.unmet_gates, 'contradiction_unresolved')
end

T['deep final ignores revisions unrelated to selected support'] = function()
  local chat = deep_workspace()
  eq(add_review(chat, true, { 'O2' }).status, 'success')
  local result = Synthesis.cmds[1]({ chat = chat }, final_args(), {})
  eq(result.status, 'success')
end

T['final requires exact passing criterion coverage'] = function()
  local missing = final_args()
  missing.criterion_results[2] = nil
  contains(Synthesis.cmds[1]({ chat = deep_workspace() }, missing, {}).data.unmet_gates, 'criterion_coverage_incomplete')
  local duplicate = final_args()
  duplicate.criterion_results[2].criterion = duplicate.criterion_results[1].criterion
  contains(Synthesis.cmds[1]({ chat = deep_workspace() }, duplicate, {}).data.unmet_gates, 'criterion_coverage_incomplete')
  local failed = final_args()
  failed.criterion_results[2].status = 'failed'
  contains(Synthesis.cmds[1]({ chat = deep_workspace() }, failed, {}).data.unmet_gates, 'criterion_not_verified')
  local pending = final_args()
  pending.criterion_results[2].status = 'pending'
  contains(Synthesis.cmds[1]({ chat = deep_workspace() }, pending, {}).data.unmet_gates, 'criterion_not_verified')
end

T['accepts explained not-applicable criteria and rejects empty explanations'] = function()
  local args = final_args()
  args.criterion_results[2].status = 'not_applicable'
  args.criterion_results[2].evidence_ids = {}
  args.criterion_results[2].explanation = 'The bounded-memory criterion is external to this conceptual comparison'
  eq(Synthesis.cmds[1]({ chat = deep_workspace() }, args, {}).status, 'success')

  local invalid = final_args()
  invalid.criterion_results[2].status = 'not_applicable'
  invalid.criterion_results[2].evidence_ids = {}
  invalid.criterion_results[2].explanation = '   '
  eq(Synthesis.cmds[1]({ chat = deep_workspace() }, invalid, {}).data.code, 'synthesis_invalid')
end

T['rejects well-formed references of the wrong artifact kind'] = function()
  local selected = final_args()
  selected.selected_option_ids = { 'E1' }
  eq(Synthesis.cmds[1]({ chat = deep_workspace() }, selected, {}).data.code, 'invalid_reference')
  local support = final_args()
  support.support_ids = { 'O1' }
  eq(Synthesis.cmds[1]({ chat = deep_workspace() }, support, {}).data.code, 'invalid_reference')
  local reviews = final_args()
  reviews.review_ids = { 'O1' }
  eq(Synthesis.cmds[1]({ chat = deep_workspace() }, reviews, {}).data.code, 'invalid_reference')
end

T['final rejects a selected option without active evidence'] = function()
  local result = Synthesis.cmds[1]({ chat = deep_workspace({ unsupported_option = true }) }, final_args(), {})
  contains(result.data.unmet_gates, 'selected_option_unsupported')
end

T['deep final succeeds after every gate is met'] = function()
  local result = Synthesis.cmds[1]({ chat = deep_workspace() }, final_args(), {})
  eq(result.status, 'success')
  eq(result.data.artifact.id, 'S1')
  eq(result.data.unmet_gates, {})
  eq(result.data.next_action.reason, 'All structural gates are ready for final synthesis')
  eq(result.data.artifact.relations.supports, { 'E1', 'E2' })
  eq(result.data.artifact.relations.depends_on, { 'O1', 'R1' })
end

T['standard analysis succeeds with one perspective and no branch'] = function()
  local chat = {}
  eq(add_frame(chat, 'standard', false).status, 'success')
  eq(add_evidence(chat, 'Restart loses process-local state', 'correctness').status, 'success')
  local args = final_args()
  args.selected_option_ids, args.review_ids = {}, {}
  args.support_ids = { 'E1' }
  args.criterion_results[2].evidence_ids = { 'E1' }
  local result = Synthesis.cmds[1]({ chat = chat }, args, {})
  eq(result.status, 'success')
end

T['temporal final requires a cited stress-tested review'] = function()
  local chat = {}
  eq(add_frame(chat, 'standard', false, {}, true).status, 'success')
  eq(add_evidence(chat, 'Restart loses process-local state', 'correctness').status, 'success')
  local args = final_args()
  args.selected_option_ids, args.review_ids = {}, {}
  args.support_ids = { 'E1' }
  args.criterion_results[1].evidence_ids = { 'E1' }
  args.criterion_results[2].evidence_ids = { 'E1' }
  contains(Synthesis.cmds[1]({ chat = chat }, args, {}).data.unmet_gates, 'temporal_review_missing')

  eq(add_review(chat, false, { 'E1' }, true).status, 'success')
  args.review_ids = { 'R1' }
  eq(Synthesis.cmds[1]({ chat = chat }, args, {}).status, 'success')
end

T['a review without stress tests does not survive a temporal frame revision'] = function()
  local chat = {}
  eq(add_frame(chat, 'standard', false).status, 'success')
  eq(add_evidence(chat, 'Restart loses process-local state', 'correctness').status, 'success')
  eq(add_review(chat, false, { 'E1' }).status, 'success')
  local revised = {
    action = 'revise', objective = 'Choose a durable cache design', problem_type = 'analysis', depth = 'standard',
    constraints = { 'No external service' }, success_criteria = { 'Survives process restart', 'Bounded memory' },
    unknowns = {}, perspectives = { { name = 'correctness', purpose = 'Find recovery failures' } },
    temporal_required = true, branching_required = false,
    branching_rationale = 'This analysis tests one claim over time',
  }
  eq(Frame.cmds[1]({ chat = chat }, revised, {}).status, 'success')
  local args = final_args()
  args.selected_option_ids = {}
  args.support_ids = { 'E1' }
  args.review_ids = { 'R1' }
  args.criterion_results[1].evidence_ids = { 'E1' }
  args.criterion_results[2].evidence_ids = { 'E1' }
  contains(Synthesis.cmds[1]({ chat = chat }, args, {}).data.unmet_gates, 'temporal_review_missing')
end

T['standard final blocks a revision affecting cited support'] = function()
  local chat = {}
  eq(add_frame(chat, 'standard', false).status, 'success')
  eq(add_evidence(chat, 'Restart loses process-local state', 'correctness').status, 'success')
  eq(add_review(chat, true, { 'E1' }).status, 'success')
  local args = final_args()
  args.selected_option_ids = {}
  args.support_ids = { 'E1' }
  args.review_ids = { 'R1' }
  args.criterion_results[2].evidence_ids = { 'E1' }
  contains(Synthesis.cmds[1]({ chat = chat }, args, {}).data.unmet_gates, 'revision_unresolved')
end

T['standard final ignores a revision unrelated to cited support'] = function()
  local chat = {}
  eq(add_frame(chat, 'standard', false).status, 'success')
  eq(add_evidence(chat, 'Restart loses process-local state', 'correctness').status, 'success')
  eq(add_evidence(chat, 'Write rate is uncertain', 'correctness').status, 'success')
  eq(add_review(chat, true, { 'E2' }).status, 'success')
  local args = final_args()
  args.selected_option_ids = {}
  args.support_ids = { 'E1' }
  args.review_ids = { 'R1' }
  args.criterion_results[1].evidence_ids = { 'E1' }
  args.criterion_results[2].evidence_ids = { 'E1' }
  eq(Synthesis.cmds[1]({ chat = chat }, args, {}).status, 'success')
end

return T
```

- [ ] **Step 2: Run the tests and verify synthesis is unavailable**

Run: `make test_file FILE=tests/codecompanion/_extensions/reasoning/tools/synthesis_test.lua`

Expected: FAIL while requiring `tools.synthesis`.

- [ ] **Step 3: Replace `Protocol.final_gates` and add `Protocol.synthesis`**

Replace the temporary `M.final_gates` from Task 3 with this complete gate evaluator and synthesis operation:

```lua
local gate_order = {
  'frame_missing',
  'evidence_missing',
  'perspective_coverage_missing',
  'unknown_coverage_missing',
  'branches_missing',
  'selected_option_missing',
  'selected_option_unsupported',
  'support_inactive',
  'review_missing',
  'temporal_review_missing',
  'full_review_missing',
  'revision_unresolved',
  'contradiction_unresolved',
  'criterion_coverage_incomplete',
  'criterion_not_verified',
  'criterion_support_missing',
}

local function active_artifacts(workspace, kind)
  local result = {}
  for _, id in ipairs(workspace.artifact_order) do
    local artifact = State.find(workspace, id)
    if artifact.status == 'active' and (not kind or artifact.kind == kind) then
      table.insert(result, artifact)
    end
  end
  return result
end

local function latest_active(workspace, kind)
  for index = #workspace.artifact_order, 1, -1 do
    local artifact = State.find(workspace, workspace.artifact_order[index])
    if artifact.status == 'active' and artifact.kind == kind then
      return artifact
    end
  end
end

local function contradiction_pairs(workspace)
  local pairs_by_key = {}
  for _, artifact in ipairs(active_artifacts(workspace)) do
    for _, other_id in ipairs(artifact.relations.contradicts) do
      local other = State.find(workspace, other_id)
      if other and other.status == 'active' then
        local key = contradiction_key(artifact.id, other_id)
        pairs_by_key[key] = { artifact.id, other_id }
      end
    end
  end
  return pairs_by_key
end

local function id_set(values)
  local result = {}
  for _, value in ipairs(values or {}) do
    result[value] = true
  end
  return result
end

function M.final_gates(workspace, synthesis)
  local failed = {}
  local function add(name)
    failed[name] = true
  end

  local frame = workspace and State.find(workspace, workspace.frame_id) or nil
  if not frame or frame.status ~= 'active' then
    add('frame_missing')
  else
    local evidence = active_artifacts(workspace, 'evidence')
    if #evidence == 0 then
      add('evidence_missing')
    end
    if frame.data.depth == 'deep' then
      local covered = {}
      for _, artifact in ipairs(evidence) do
        covered[normalized(artifact.data.perspective)] = true
      end
      if vim.tbl_count(covered) < 2 then
        add('perspective_coverage_missing')
      end
    end
    local branch = latest_active(workspace, 'branch')
    if frame.data.branching_required and not branch then
      add('branches_missing')
    end

    local selected_ids = synthesis and synthesis.selected_option_ids or {}
    local support_ids = synthesis and synthesis.support_ids or {}
    local review_ids = synthesis and synthesis.review_ids or {}
    local selected = id_set(selected_ids)
    local support = id_set(support_ids)
    local criterion_results = synthesis and synthesis.criterion_results or {}
    local relevant = id_set(selected_ids)
    relevant[frame.id] = true
    for id in pairs(support) do
      relevant[id] = true
    end
    for _, result in ipairs(criterion_results) do
      for _, id in ipairs(result.evidence_ids or {}) do
        relevant[id] = true
      end
    end
    local branch_options = branch and id_set(branch.data.option_ids) or {}
    if branch and (frame.data.branching_required or #selected_ids > 0) then
      relevant[branch.id] = true
    end
    if frame.data.branching_required and #selected_ids == 0 then
      add('selected_option_missing')
    end
    for _, id in ipairs(selected_ids) do
      local option = State.find(workspace, id)
      if not option or option.status ~= 'active' or option.kind ~= 'option' or not branch_options[id] then
        add('selected_option_missing')
      else
        local supported = false
        for _, evidence_id in ipairs(option.data.evidence_ids) do
          local artifact = State.find(workspace, evidence_id)
          supported = supported or (artifact and artifact.status == 'active' and artifact.kind == 'evidence')
          relevant[evidence_id] = true
        end
        if not supported or #option.data.predictions == 0 then
          add('selected_option_unsupported')
        end
      end
    end
    for _, id in ipairs(support_ids) do
      local artifact = State.find(workspace, id)
      if not artifact or artifact.status ~= 'active' or artifact.kind ~= 'evidence' then
        add('support_inactive')
      end
    end
    local unknowns = {}
    for _, unknown in ipairs(frame.data.unknowns) do
      unknowns[normalized(unknown)] = true
    end
    for _, artifact in ipairs(evidence) do
      if not synthesis or relevant[artifact.id] then
        for _, unknown in ipairs(artifact.data.addresses_unknowns or {}) do
          unknowns[normalized(unknown)] = nil
        end
      end
    end
    if next(unknowns) ~= nil then
      add('unknown_coverage_missing')
    end

    local pairs_by_key = contradiction_pairs(workspace)
    local has_contradiction = next(pairs_by_key) ~= nil
    local reviews = {}
    if synthesis then
      for _, id in ipairs(review_ids) do
        local review = State.find(workspace, id)
        if review and review.status == 'active' and review.kind == 'review' then
          table.insert(reviews, review)
        end
      end
    else
      reviews = active_artifacts(workspace, 'review')
    end
    local reviews_by_id = {}
    for _, review in ipairs(reviews) do
      reviews_by_id[review.id] = review
    end
    local checkpoint = latest_active(workspace, 'synthesis')
    local function review_relevant(review)
      if not synthesis then
        return true
      end
      for _, id in ipairs(review.data.target_ids or {}) do
        if relevant[id] or (checkpoint and id == checkpoint.id) then
          return true
        end
      end
      return false
    end
    if (branch or has_contradiction) and #reviews == 0 then
      add('review_missing')
    end
    if frame.data.temporal_required then
      local stress_tested = false
      for _, review in ipairs(reviews) do
        stress_tested = stress_tested
          or (#(review.data.stress_tests or {}) > 0 and review_relevant(review))
      end
      if not stress_tested then
        add('temporal_review_missing')
      end
    end

    if frame.data.depth == 'deep' then
      if checkpoint then
        relevant[checkpoint.id] = true
      end
      local full_review = false
      for _, review in ipairs(reviews) do
        if review.data.mode == 'full' and review_relevant(review) then
          full_review = true
        end
      end
      if not full_review then
        add('full_review_missing')
      end
    end

    for id in pairs(workspace.open_revisions) do
      if not synthesis or relevant[id] then
        add('revision_unresolved')
      end
    end
    local function contradiction_resolution_valid(key)
      local review = reviews_by_id[workspace.resolved_contradictions[key]]
      if not review then
        return false
      end
      for _, resolution in ipairs(review.data.contradiction_resolutions or {}) do
        if contradiction_key(resolution.left_id, resolution.right_id) == key then
          local evidence_valid = #(resolution.evidence_ids or {}) > 0
          for _, id in ipairs(resolution.evidence_ids or {}) do
            local artifact = State.find(workspace, id)
            evidence_valid = evidence_valid
              and artifact ~= nil
              and artifact.status == 'active'
              and artifact.kind == 'evidence'
          end
          if evidence_valid then
            return true
          end
        end
      end
      return false
    end
    for key, pair in pairs(pairs_by_key) do
      if (not synthesis or relevant[pair[1]] or relevant[pair[2]])
        and not contradiction_resolution_valid(key)
      then
        add('contradiction_unresolved')
      end
    end

    local expected_criteria = {}
    for _, criterion in ipairs(frame.data.success_criteria) do
      expected_criteria[normalized(criterion)] = criterion
    end
    local observed_criteria = {}
    for _, result in ipairs(criterion_results) do
      local key = normalized(result.criterion)
      if not expected_criteria[key] or observed_criteria[key] then
        add('criterion_coverage_incomplete')
      end
      observed_criteria[key] = true
      if result.status == 'failed' or result.status == 'pending' then
        add('criterion_not_verified')
      elseif result.status == 'not_applicable' and not text_valid(result.explanation) then
        add('criterion_not_verified')
      elseif result.status == 'passed' then
        if #result.evidence_ids == 0 then
          add('criterion_support_missing')
        end
        for _, id in ipairs(result.evidence_ids) do
          local artifact = State.find(workspace, id)
          if not artifact or artifact.status ~= 'active' or artifact.kind ~= 'evidence' then
            add('criterion_support_missing')
          end
        end
      end
    end
    for key in pairs(expected_criteria) do
      if not observed_criteria[key] then
        add('criterion_coverage_incomplete')
      end
    end
  end

  local ordered = {}
  for _, name in ipairs(gate_order) do
    if failed[name] then
      table.insert(ordered, name)
    end
  end
  return ordered
end

local function synthesis_references_valid(workspace, ids, kind)
  for _, id in ipairs(ids) do
    local artifact, code = active_reference(workspace, id)
    if code then
      return nil, code, id
    end
    if artifact.kind ~= kind then
      return nil, 'invalid_reference', id
    end
  end
  return true
end

local function unique_strings(values)
  local seen = {}
  for _, value in ipairs(values) do
    if seen[value] then
      return false
    end
    seen[value] = true
  end
  return true
end

function M.synthesis(chat, args)
  local workspace = State.get(chat)
  if not workspace then
    return failure('workspace_missing', 'start a frame before synthesis', {}, 'Call reasoning_frame')
  end
  if type(args) ~= 'table'
    or not vim.tbl_contains({ 'checkpoint', 'final' }, args.mode)
    or not text_valid(args.conclusion)
    or not text_array_valid(args.selected_option_ids)
    or not text_array_valid(args.support_ids)
    or not text_array_valid(args.review_ids)
    or not unique_strings(args.selected_option_ids)
    or not unique_strings(args.support_ids)
    or not unique_strings(args.review_ids)
    or not bounded_array(args.criterion_results, 0, Config.get().limits.max_array_items)
    or not text_array_valid(args.tradeoffs)
    or not text_array_valid(args.uncertainties)
    or not text_array_valid(args.blind_spots)
    or not text_array_valid(args.next_actions)
    or not vim.tbl_contains({ 'low', 'medium', 'high' }, args.confidence)
  then
    return failure('synthesis_invalid', 'synthesis fields are invalid', {}, 'Correct reasoning_synthesis fields')
  end
  for index, result in ipairs(args.criterion_results) do
    if type(result) ~= 'table'
      or not text_valid(result.criterion)
      or not vim.tbl_contains({ 'passed', 'failed', 'pending', 'not_applicable' }, result.status)
      or not text_array_valid(result.evidence_ids)
      or not unique_strings(result.evidence_ids)
      or not text_valid(result.explanation)
    then
      return failure('synthesis_invalid', 'criterion result ' .. index .. ' is invalid', {}, 'Correct criterion_results')
    end
  end
  for _, reference in ipairs({
    { args.selected_option_ids, 'option' },
    { args.support_ids, 'evidence' },
    { args.review_ids, 'review' },
  }) do
    local ok, code, id = synthesis_references_valid(workspace, reference[1], reference[2])
    if not ok then
      return failure(code, 'synthesis reference is unavailable', { id }, 'Use active typed artifact IDs')
    end
  end
  for _, result in ipairs(args.criterion_results) do
    local ok, code, id = synthesis_references_valid(workspace, result.evidence_ids, 'evidence')
    if not ok then
      return failure(code, 'criterion evidence is unavailable', { id }, 'Use active evidence IDs')
    end
  end

  local gates = M.final_gates(workspace, args)
  if args.mode == 'final' and #gates > 0 then
    local rejected = failure(
      'synthesis_gate_failed',
      'final synthesis is blocked by: ' .. table.concat(gates, ', '),
      {},
      Guidance.next(workspace, args)
    )
    rejected.data.unmet_gates = gates
    return rejected
  end
  if #workspace.artifact_order >= Config.get().limits.max_artifacts then
    return failure('limit_exceeded', 'the synthesis exceeds the artifact limit', {}, 'Replace the workspace')
  end

  local synthesis = assert(State.add(workspace, 'synthesis', vim.deepcopy(args)))
  local recorded_support = {}
  for _, id in ipairs(args.support_ids) do
    if not recorded_support[id] then
      State.add_relation(synthesis, 'supports', id)
      recorded_support[id] = true
    end
  end
  for _, result in ipairs(args.criterion_results) do
    for _, id in ipairs(result.evidence_ids) do
      if not recorded_support[id] then
        State.add_relation(synthesis, 'supports', id)
        recorded_support[id] = true
      end
    end
  end
  for _, id in ipairs(args.selected_option_ids) do
    State.add_relation(synthesis, 'depends_on', id)
  end
  for _, id in ipairs(args.review_ids) do
    State.add_relation(synthesis, 'depends_on', id)
  end
  local revised = {}
  for target_id in pairs(workspace.open_revisions) do
    local target = State.find(workspace, target_id)
    if target and target.status == 'active' and target.kind == 'synthesis' then
      table.insert(revised, target_id)
    end
  end
  for _, target_id in ipairs(revised) do
    State.supersede(workspace, target_id, synthesis.id)
  end
  return {
    status = 'success',
    data = {
      workspace_id = workspace.id,
      artifact = vim.deepcopy(synthesis),
      progress = vim.deepcopy(workspace.counts_by_kind),
      unmet_gates = args.mode == 'final' and {} or M.final_gates(workspace, args),
      next_action = Guidance.next(workspace, args),
    },
  }
end
```

- [ ] **Step 4: Test and replace `guidance.lua` in TDD order**

The implementation reference appears first so its complete interface stays adjacent to `Protocol.synthesis`. Execute this step in the following order: create `guidance_test.lua` from the second code block, run the focused test and observe the expected failure, then replace `guidance.lua` with the first code block.

Replace `guidance.lua` with:

```lua
local M = {}

local function normalized(value)
  return vim.trim(value):lower():gsub('%s+', ' ')
end

local function active(workspace, kind)
  local result = {}
  for _, id in ipairs(workspace.artifact_order or {}) do
    local artifact = workspace.artifacts_by_id[id]
    if artifact and artifact.status == 'active' and (not kind or artifact.kind == kind) then
      table.insert(result, artifact)
    end
  end
  return result
end

local function latest(workspace, kind)
  local values = active(workspace, kind)
  return values[#values]
end

local function contradiction_resolution_valid(workspace, key, cited_reviews)
  local review_id = workspace.resolved_contradictions[key]
  if not review_id or (cited_reviews and not cited_reviews[review_id]) then
    return false
  end
  local review = workspace.artifacts_by_id[review_id]
  if not review or review.status ~= 'active' or review.kind ~= 'review' then
    return false
  end
  for _, resolution in ipairs(review.data.contradiction_resolutions or {}) do
    local left, right = resolution.left_id, resolution.right_id
    if left > right then
      left, right = right, left
    end
    if left .. ':' .. right == key then
      local valid = #(resolution.evidence_ids or {}) > 0
      for _, id in ipairs(resolution.evidence_ids or {}) do
        local evidence = workspace.artifacts_by_id[id]
        valid = valid and evidence and evidence.status == 'active' and evidence.kind == 'evidence'
      end
      if valid then
        return true
      end
    end
  end
  return false
end

local function contradiction_open(workspace, relevant, cited_reviews)
  for _, artifact in ipairs(active(workspace)) do
    for _, other_id in ipairs(artifact.relations.contradicts) do
      local other = workspace.artifacts_by_id[other_id]
      if other and other.status == 'active' then
        local left, right = artifact.id, other_id
        if left > right then
          left, right = right, left
        end
        if not contradiction_resolution_valid(workspace, left .. ':' .. right, cited_reviews)
          and (relevant == nil or relevant[left] or relevant[right])
        then
          return true
        end
      end
    end
  end
  return false
end

local function revision_tool(workspace, relevant)
  local tool_by_kind = {
    frame = 'reasoning_frame',
    evidence = 'reasoning_evidence',
    branch = 'reasoning_options',
    option = 'reasoning_options',
    synthesis = 'reasoning_synthesis',
  }
  for index = #(workspace.artifact_order or {}), 1, -1 do
    local review = workspace.artifacts_by_id[workspace.artifact_order[index]]
    if review and review.kind == 'review' then
      for _, verdict in ipairs(review.data.verdicts or {}) do
        if workspace.open_revisions[verdict.target_id] == review.id
          and (relevant == nil or relevant[verdict.target_id])
        then
          local target = workspace.artifacts_by_id[verdict.target_id]
          return target and tool_by_kind[target.kind]
        end
      end
    end
  end
  local target_ids = vim.tbl_keys(workspace.open_revisions or {})
  table.sort(target_ids)
  for _, target_id in ipairs(target_ids) do
    local target = workspace.artifacts_by_id[target_id]
    if target and (relevant == nil or relevant[target_id]) then
      return tool_by_kind[target.kind]
    end
  end
end

function M.next(workspace, synthesis)
  if not workspace then
    return { tool = 'reasoning_frame', reason = 'Create the active problem frame' }
  end
  local frame = workspace.artifacts_by_id[workspace.frame_id]
  if not frame or frame.status ~= 'active' then
    return { tool = 'reasoning_frame', reason = 'Create the active problem frame' }
  end
  local branching_by_type = {
    decision = true,
    diagnosis = true,
    design = true,
    planning = true,
  }
  local perspective_count = #(frame.data.perspectives or {})
  if (frame.data.depth == 'deep' and perspective_count < 2)
    or perspective_count == 0
    or (branching_by_type[frame.data.problem_type] and not frame.data.branching_required)
  then
    return { tool = 'reasoning_frame', reason = 'Correct uncovered frame requirements' }
  end

  local current_synthesis = synthesis
  if not current_synthesis then
    local checkpoint = latest(workspace, 'synthesis')
    current_synthesis = checkpoint and checkpoint.data or nil
  end
  local relevant
  if current_synthesis then
    relevant = { [frame.id] = true }
    for _, id in ipairs(current_synthesis.selected_option_ids or {}) do
      relevant[id] = true
      local option = workspace.artifacts_by_id[id]
      for _, evidence_id in ipairs((option and option.data.evidence_ids) or {}) do
        relevant[evidence_id] = true
      end
    end
    for _, id in ipairs(current_synthesis.support_ids or {}) do
      relevant[id] = true
    end
    for _, result in ipairs(current_synthesis.criterion_results or {}) do
      for _, id in ipairs(result.evidence_ids or {}) do
        relevant[id] = true
      end
    end
  end
  local cited_reviews
  if current_synthesis then
    cited_reviews = {}
    for _, id in ipairs(current_synthesis.review_ids or {}) do
      cited_reviews[id] = true
    end
  end

  local required_perspectives = frame.data.depth == 'deep' and 2 or 1
  local covered = {}
  local active_evidence = active(workspace, 'evidence')
  for _, artifact in ipairs(active_evidence) do
    covered[normalized(artifact.data.perspective)] = true
  end
  if vim.tbl_count(covered) < required_perspectives then
    return { tool = 'reasoning_evidence', reason = 'Gather evidence for uncovered perspectives' }
  end
  local uncovered_unknowns = {}
  for _, unknown in ipairs(frame.data.unknowns or {}) do
    uncovered_unknowns[normalized(unknown)] = true
  end
  for _, artifact in ipairs(active_evidence) do
    if relevant == nil or relevant[artifact.id] then
      for _, unknown in ipairs(artifact.data.addresses_unknowns or {}) do
        uncovered_unknowns[normalized(unknown)] = nil
      end
    end
  end
  if next(uncovered_unknowns) ~= nil then
    return { tool = 'reasoning_evidence', reason = 'Gather evidence for unresolved framed unknowns' }
  end
  local branch = latest(workspace, 'branch')
  if frame.data.branching_required and not branch then
    return { tool = 'reasoning_options', reason = 'Create the required competing branches' }
  end
  if relevant and branch
    and (frame.data.branching_required or #(current_synthesis.selected_option_ids or {}) > 0)
  then
    relevant[branch.id] = true
  end
  if branch then
    local option_ids = branch.data.option_ids
    if current_synthesis and #(current_synthesis.selected_option_ids or {}) > 0 then
      local current_options = {}
      for _, id in ipairs(branch.data.option_ids) do
        current_options[id] = true
      end
      for _, id in ipairs(current_synthesis.selected_option_ids) do
        local selected = workspace.artifacts_by_id[id]
        if not current_options[id]
          or not selected
          or selected.status ~= 'active'
          or selected.kind ~= 'option'
        then
          return {
            tool = 'reasoning_synthesis',
            reason = 'Select active options from the current branch set in the next synthesis',
          }
        end
      end
      option_ids = current_synthesis.selected_option_ids
    end
    for _, option_id in ipairs(option_ids) do
      local option = workspace.artifacts_by_id[option_id]
      if option and option.status == 'active' then
        local supported = false
        for _, evidence_id in ipairs(option.data.evidence_ids) do
          local evidence = workspace.artifacts_by_id[evidence_id]
          supported = supported or (evidence and evidence.status == 'active' and evidence.kind == 'evidence')
        end
        if not supported or #option.data.predictions == 0 then
          return {
            tool = 'reasoning_options',
            reason = 'Replace the branch set so every option cites active evidence and states testable predictions',
          }
        end
      end
    end
  end
  if frame.data.branching_required
    and current_synthesis
    and #(current_synthesis.selected_option_ids or {}) == 0
  then
    return { tool = 'reasoning_synthesis', reason = 'Select a supported option in the next synthesis' }
  end
  if contradiction_open(workspace, relevant, cited_reviews) then
    return { tool = 'reasoning_review', reason = 'Review an unresolved contradiction' }
  end

  local correction_tool = revision_tool(workspace, relevant)
  if correction_tool then
    return { tool = correction_tool, reason = 'Apply the latest required revision' }
  end

  local reviews = {}
  for _, review in ipairs(active(workspace, 'review')) do
    if cited_reviews == nil or cited_reviews[review.id] then
      table.insert(reviews, review)
    end
  end
  local checkpoint = latest(workspace, 'synthesis')
  local function review_relevant(review)
    if relevant == nil then
      return true
    end
    for _, id in ipairs(review.data.target_ids or {}) do
      if relevant[id] or (checkpoint and id == checkpoint.id) then
        return true
      end
    end
    return false
  end
  local has_any_review = false
  local has_relevant_full_review = false
  for _, review in ipairs(reviews) do
    local temporal_ok = not frame.data.temporal_required
      or (#(review.data.stress_tests or {}) > 0 and review_relevant(review))
    has_any_review = has_any_review or temporal_ok
    if review.data.mode == 'full' and temporal_ok then
      if review_relevant(review) then
        has_relevant_full_review = true
      end
    end
  end
  if (branch or frame.data.temporal_required) and not has_any_review then
    return { tool = 'reasoning_review', reason = 'Adversarially review the strongest current case' }
  end
  if frame.data.depth == 'deep' and not has_relevant_full_review then
    return { tool = 'reasoning_review', reason = 'Run a full review of selected or supporting artifacts' }
  end

  local covered_criteria = {}
  local expected_criteria = {}
  for _, criterion in ipairs(frame.data.success_criteria) do
    expected_criteria[normalized(criterion)] = true
  end
  local criterion_invalid = false
  local observed_criteria = {}
  for _, result in ipairs((current_synthesis and current_synthesis.criterion_results) or {}) do
    local key = normalized(result.criterion)
    criterion_invalid = criterion_invalid or not expected_criteria[key] or observed_criteria[key] == true
    observed_criteria[key] = true
    local covered_result = result.status == 'not_applicable'
      and type(result.explanation) == 'string'
      and vim.trim(result.explanation) ~= ''
    if result.status == 'passed' and #(result.evidence_ids or {}) > 0 then
      covered_result = true
      for _, id in ipairs(result.evidence_ids) do
        local evidence = workspace.artifacts_by_id[id]
        covered_result = covered_result
          and evidence ~= nil
          and evidence.status == 'active'
          and evidence.kind == 'evidence'
      end
    end
    if covered_result then
      covered_criteria[key] = true
    end
  end
  for _, criterion in ipairs(frame.data.success_criteria) do
    if criterion_invalid or not covered_criteria[normalized(criterion)] then
      return { tool = 'reasoning_synthesis', reason = 'Record verification for every success criterion' }
    end
  end
  return { tool = 'reasoning_synthesis', reason = 'All structural gates are ready for final synthesis' }
end

return M
```

Create `guidance_test.lua`:

```lua
local Guidance = require('codecompanion._extensions.reasoning.guidance')

local T = MiniTest.new_set()
local eq = MiniTest.expect.equality

local function artifact(id, kind, data)
  return {
    id = id, kind = kind, status = 'active', data = data,
    relations = { supports = {}, contradicts = {}, qualifies = {}, depends_on = {}, tests = {}, supersedes = {} },
  }
end

local function workspace()
  local frame = artifact('F1', 'frame', {
    depth = 'deep', problem_type = 'design', branching_required = true, success_criteria = { 'Durable' },
    unknowns = {}, temporal_required = false,
    perspectives = {
      { name = 'correctness', purpose = 'Find failures' },
      { name = 'operations', purpose = 'Find lifecycle failures' },
    },
  })
  return {
    frame_id = 'F1', artifact_order = { 'F1' }, artifacts_by_id = { F1 = frame },
    open_revisions = {}, resolved_contradictions = {},
  }
end

local function add(ws, value)
  ws.artifacts_by_id[value.id] = value
  table.insert(ws.artifact_order, value.id)
  return value
end

local function evidence(id, perspective)
  return artifact(id, 'evidence', { perspective = perspective, addresses_unknowns = {} })
end

local function complete_workspace()
  local ws = workspace()
  add(ws, evidence('E1', 'correctness'))
  add(ws, evidence('E2', 'operations'))
  local option1 = artifact('O1', 'option', { evidence_ids = { 'E1' }, predictions = { 'Replay succeeds' } })
  local option2 = artifact('O2', 'option', { evidence_ids = { 'E2' }, predictions = { 'Snapshot loads' } })
  add(ws, artifact('B1', 'branch', { option_ids = { 'O1', 'O2' } }))
  add(ws, option1)
  add(ws, option2)
  add(ws, artifact('R1', 'review', { mode = 'full', target_ids = { 'O1', 'E1' }, stress_tests = {} }))
  return ws
end

T['uses deterministic priority order'] = function()
  eq(Guidance.next(nil), { tool = 'reasoning_frame', reason = 'Create the active problem frame' })

  local malformed = workspace()
  malformed.artifacts_by_id.F1.data.perspectives[2] = nil
  eq(Guidance.next(malformed), { tool = 'reasoning_frame', reason = 'Correct uncovered frame requirements' })

  local ws = workspace()
  eq(Guidance.next(ws).tool, 'reasoning_evidence')
  add(ws, evidence('E1', 'correctness'))
  eq(Guidance.next(ws).tool, 'reasoning_evidence')
  add(ws, evidence('E2', 'operations'))
  eq(Guidance.next(ws).tool, 'reasoning_options')

  local unsupported = artifact('O1', 'option', { evidence_ids = {}, predictions = { 'A result' } })
  add(ws, artifact('B1', 'branch', { option_ids = { 'O1' } }))
  add(ws, unsupported)
  eq(Guidance.next(ws).tool, 'reasoning_options')

  unsupported.data.evidence_ids = { 'E1' }
  ws.artifacts_by_id.E2.relations.contradicts = { 'E1' }
  eq(Guidance.next(ws).tool, 'reasoning_review')
  ws.artifacts_by_id.E2.relations.contradicts = {}
  ws.open_revisions.E1 = 'R1'
  eq(Guidance.next(ws).tool, 'reasoning_evidence')

  local complete = complete_workspace()
  eq(Guidance.next(complete).reason, 'Record verification for every success criterion')
  local synthesis = {
    selected_option_ids = { 'O1' }, support_ids = { 'E1' }, review_ids = { 'R1' },
    criterion_results = { { criterion = 'Durable', status = 'passed', evidence_ids = { 'E1' } } },
  }
  eq(Guidance.next(complete, synthesis), {
    tool = 'reasoning_synthesis', reason = 'All structural gates are ready for final synthesis',
  })
end

T['routes immutable option repair through branch replacement'] = function()
  local ws = complete_workspace()
  ws.artifacts_by_id.O1.data.evidence_ids = {}
  eq(Guidance.next(ws), {
    tool = 'reasoning_options',
    reason = 'Replace the branch set so every option cites active evidence and states testable predictions',
  })

  ws.artifacts_by_id.O1.data.evidence_ids = { 'E1' }
  ws.artifacts_by_id.O1.data.predictions = {}
  eq(Guidance.next(ws).tool, 'reasoning_options')
end

T['requires a new selection after branch replacement retires the checkpoint selection'] = function()
  local ws = complete_workspace()
  ws.artifacts_by_id.B1.status = 'superseded'
  ws.artifacts_by_id.O1.status = 'superseded'
  ws.artifacts_by_id.O2.status = 'superseded'
  add(ws, artifact('B2', 'branch', { option_ids = { 'O3', 'O4' } }))
  add(ws, artifact('O3', 'option', { evidence_ids = { 'E1' }, predictions = { 'Replay succeeds' } }))
  add(ws, artifact('O4', 'option', { evidence_ids = { 'E2' }, predictions = { 'Snapshot loads' } }))
  add(ws, artifact('S1', 'synthesis', {
    selected_option_ids = { 'O1' }, support_ids = { 'E1' }, review_ids = { 'R1' }, criterion_results = {},
  }))
  eq(Guidance.next(ws), {
    tool = 'reasoning_synthesis',
    reason = 'Select active options from the current branch set in the next synthesis',
  })
end

T['normalizes criterion whitespace exactly like final gates'] = function()
  local ws = complete_workspace()
  ws.artifacts_by_id.F1.data.success_criteria = { 'Durable   recovery' }
  local synthesis = {
    selected_option_ids = { 'O1' }, support_ids = { 'E1' }, review_ids = { 'R1' },
    criterion_results = {
      { criterion = ' durable recovery ', status = 'passed', evidence_ids = { 'E1' } },
    },
  }
  eq(Guidance.next(ws, synthesis).reason, 'All structural gates are ready for final synthesis')
end


T['accepts a cited non-full review for a standard branch'] = function()
  local ws = complete_workspace()
  ws.artifacts_by_id.F1.data.depth = 'standard'
  ws.artifacts_by_id.R1.data.mode = 'falsification'
  local synthesis = {
    selected_option_ids = { 'O1' }, support_ids = { 'E1' }, review_ids = { 'R1' },
    criterion_results = { { criterion = 'Durable', status = 'passed', evidence_ids = { 'E1' } } },
  }
  eq(Guidance.next(ws, synthesis).reason, 'All structural gates are ready for final synthesis')
end

T['requires a relevant cited full review in deep mode'] = function()
  local ws = complete_workspace()
  ws.artifacts_by_id.R1.data.target_ids = { 'O2' }
  local synthesis = {
    selected_option_ids = { 'O1' }, support_ids = { 'E1' }, review_ids = { 'R1' },
    criterion_results = { { criterion = 'Durable', status = 'passed', evidence_ids = { 'E1' } } },
  }
  eq(Guidance.next(ws, synthesis), {
    tool = 'reasoning_review', reason = 'Run a full review of selected or supporting artifacts',
  })
end

T['asks synthesis to select an option when a branch result omits selection'] = function()
  local ws = complete_workspace()
  local synthesis = {
    selected_option_ids = {}, support_ids = { 'E1' }, review_ids = { 'R1' },
    criterion_results = { { criterion = 'Durable', status = 'passed', evidence_ids = { 'E1' } } },
  }
  eq(Guidance.next(ws, synthesis), {
    tool = 'reasoning_synthesis', reason = 'Select a supported option in the next synthesis',
  })
end

T['does not count unsupported passed criteria as verified'] = function()
  local ws = complete_workspace()
  local synthesis = {
    selected_option_ids = { 'O1' }, support_ids = { 'E1' }, review_ids = { 'R1' },
    criterion_results = { { criterion = 'Durable', status = 'passed', evidence_ids = {} } },
  }
  eq(Guidance.next(ws, synthesis).reason, 'Record verification for every success criterion')
end

T['prioritizes evidence for an uncovered framed unknown'] = function()
  local ws = workspace()
  ws.artifacts_by_id.F1.data.unknowns = { 'Expected write rate' }
  add(ws, evidence('E1', 'correctness'))
  add(ws, evidence('E2', 'operations'))
  eq(Guidance.next(ws), {
    tool = 'reasoning_evidence', reason = 'Gather evidence for unresolved framed unknowns',
  })
end

return T
```

Run after creating only `guidance_test.lua`:

`make test_file FILE=tests/codecompanion/_extensions/reasoning/guidance_test.lua`

Expected: FAIL because the temporary guidance module from Task 3 does not implement frame correction, branching, contradiction, revision, review, or criterion priorities.

Then replace `guidance.lua` with the complete implementation block at the start of this step and rerun the same command.

Expected: PASS with 0 failures.

- [ ] **Step 5: Create the complete strict synthesis tool**

```lua
local Protocol = require('codecompanion._extensions.reasoning.protocol')

local string_array = { type = 'array', items = { type = 'string' } }

return {
  name = 'reasoning_synthesis',
  cmds = {
    function(tools, args, opts)
      return Protocol.call('synthesis', tools.chat, args)
    end,
  },
  schema = {
    type = 'function',
    ['function'] = {
      name = 'reasoning_synthesis',
      description = 'Record a checkpoint or produce a final conclusion after deterministic reasoning gates pass.',
      parameters = {
        type = 'object',
        properties = {
          mode = {
            type = 'string', enum = { 'checkpoint', 'final' },
            description = 'Checkpoint always records valid input; final is rejected until every structural gate passes.',
          },
          conclusion = { type = 'string' },
          selected_option_ids = string_array,
          support_ids = string_array,
          review_ids = string_array,
          criterion_results = {
            type = 'array',
            items = {
              type = 'object',
              properties = {
                criterion = { type = 'string' },
                status = { type = 'string', enum = { 'passed', 'failed', 'pending', 'not_applicable' } },
                evidence_ids = string_array,
                explanation = { type = 'string' },
              },
              required = { 'criterion', 'status', 'evidence_ids', 'explanation' },
              additionalProperties = false,
            },
          },
          tradeoffs = string_array,
          uncertainties = string_array,
          blind_spots = string_array,
          next_actions = string_array,
          confidence = { type = 'string', enum = { 'low', 'medium', 'high' } },
        },
        required = {
          'mode', 'conclusion', 'selected_option_ids', 'support_ids', 'review_ids',
          'criterion_results', 'tradeoffs', 'uncertainties', 'blind_spots', 'next_actions', 'confidence',
        },
        additionalProperties = false,
      },
      strict = true,
    },
  },
}
```

- [ ] **Step 6: Run, format, and commit**

Run: `make test_file FILE=tests/codecompanion/_extensions/reasoning/tools/synthesis_test.lua`

Run: `make test_file FILE=tests/codecompanion/_extensions/reasoning/guidance_test.lua`

Expected: both files PASS with 0 failures.

Run: `stylua lua/codecompanion/_extensions/reasoning/protocol.lua lua/codecompanion/_extensions/reasoning/guidance.lua lua/codecompanion/_extensions/reasoning/tools/synthesis.lua tests/codecompanion/_extensions/reasoning/tools/synthesis_test.lua tests/codecompanion/_extensions/reasoning/guidance_test.lua -f stylua.toml`

Run: `make test_file FILE=tests/codecompanion/_extensions/reasoning/tools/synthesis_test.lua`

Run: `make test_file FILE=tests/codecompanion/_extensions/reasoning/guidance_test.lua`

Expected: both PASS after formatting.

```bash
git add lua/codecompanion/_extensions/reasoning/protocol.lua lua/codecompanion/_extensions/reasoning/guidance.lua lua/codecompanion/_extensions/reasoning/tools/synthesis.lua tests/codecompanion/_extensions/reasoning/tools/synthesis_test.lua tests/codecompanion/_extensions/reasoning/guidance_test.lua
git commit -m "feat(reasoning): enforce synthesis gates"
```

### Task 8: Add shared output and current CodeCompanion registration

**Files:**
- Create: `lua/codecompanion/_extensions/reasoning/output.lua`
- Modify: all five files under `lua/codecompanion/_extensions/reasoning/tools/`
- Modify: `lua/codecompanion/_extensions/reasoning/init.lua`
- Create: `tests/codecompanion/_extensions/reasoning/output_test.lua`
- Modify: `tests/codecompanion/_extensions/reasoning/init_test.lua`
- Create: `tests/codecompanion/_extensions/reasoning/runtime_integration_test.lua`

- [ ] **Step 1: Write failing output tests with a mock chat**

```lua
local Output = require('codecompanion._extensions.reasoning.output')

local T = MiniTest.new_set()
local eq = MiniTest.expect.equality

local function mock_meta()
  local calls = {}
  return {
    calls = calls,
    meta = {
      tools = {
        chat = {
          add_tool_output = function(_, tool, for_llm, for_user)
            table.insert(calls, { tool = tool, for_llm = for_llm, for_user = for_user })
          end,
        },
      },
    },
  }
end

T['serializes success for the model and bounds user output'] = function()
  local mock = mock_meta()
  Output.success({ name = 'reasoning_frame' }, {
    { workspace_id = 'W1', artifact = { id = 'F1' }, next_action = { tool = 'reasoning_evidence' } },
  }, mock.meta)
  eq(vim.json.decode(mock.calls[1].for_llm).artifact.id, 'F1')
  eq(mock.calls[1].for_user, 'Recorded F1; next: reasoning_evidence')
end

T['serializes stable errors'] = function()
  local mock = mock_meta()
  Output.error({ name = 'reasoning_frame' }, {
    {
      code = 'workspace_exists', message = 'active', artifact_ids = { 'F1' },
      next_action = { tool = 'reasoning_frame', reason = 'Use revise' },
    },
  }, mock.meta)
  eq(vim.json.decode(mock.calls[1].for_llm).code, 'workspace_exists')
  eq(mock.calls[1].for_user, 'Reasoning step rejected: workspace_exists')
end

return T
```

- [ ] **Step 2: Replace `init_test.lua` with complete current-API integration tests**

```lua
local CodeCompanion = require('codecompanion')
local Extension = require('codecompanion._extensions.reasoning')
local ToolRuntime = require('codecompanion.interactions.chat.tools')
local config = require('codecompanion.config')

local original_tools
local original_system_prompt
local T = MiniTest.new_set({
  hooks = {
    pre_case = function()
      original_tools = vim.deepcopy(config.interactions.chat.tools)
      original_system_prompt = config.interactions.chat.opts.system_prompt
    end,
    post_case = function()
      config.interactions.chat.tools = original_tools
    end,
  },
})
local eq = MiniTest.expect.equality

local names = {
  'reasoning_frame',
  'reasoning_evidence',
  'reasoning_options',
  'reasoning_review',
  'reasoning_synthesis',
}

T['loads through CodeCompanion setup and resolves all schemas'] = function()
  CodeCompanion.setup({
    extensions = {
      reasoning = { enabled = true, opts = { auto_attach = false, default_depth = 'deep' } },
    },
  })
  local tools = config.interactions.chat.tools
  eq(tools.reasoning_frame.path, '_extensions.reasoning.tools.frame')
  eq(tools.reasoning_evidence.path, '_extensions.reasoning.tools.evidence')
  eq(tools.reasoning_options.path, '_extensions.reasoning.tools.options')
  eq(tools.reasoning_review.path, '_extensions.reasoning.tools.review')
  eq(tools.reasoning_synthesis.path, '_extensions.reasoning.tools.synthesis')
  eq(tools.groups.reasoning.tools, names)
  eq(config.interactions.chat.opts.system_prompt, original_system_prompt)

  for _, name in ipairs(names) do
    local resolved = ToolRuntime.resolve(tools[name])
    eq(type(resolved.cmds[1]), 'function')
    eq(resolved.schema['function'].name, name)
    eq(resolved.output ~= nil, true)
  end
end

T['auto-attaches the group once'] = function()
  Extension.setup({ auto_attach = true })
  Extension.setup({ auto_attach = true })
  local count = 0
  for _, name in ipairs(config.interactions.chat.tools.opts.default_tools) do
    if name == 'reasoning' then
      count = count + 1
    end
  end
  eq(count, 1)
end

T['keeps manual attachment as the default'] = function()
  Extension.setup()
  eq(vim.tbl_contains(config.interactions.chat.tools.opts.default_tools, 'reasoning'), false)
end

T['uses the current function command contract'] = function()
  Extension.setup()
  local frame = ToolRuntime.resolve(config.interactions.chat.tools.reasoning_frame)
  local result = frame.cmds[1]({ chat = {} }, {}, {
    input = nil,
    output_cb = function() end,
    register_job = function() end,
  })
  eq(result.status, 'error')
  eq(result.data.code, 'frame_incomplete')
end

return T
```

- [ ] **Step 3: Add a runner-backed integration test for the complete current runtime path**

Create `runtime_integration_test.lua`. This uses a chat-shaped boundary object but leaves the real `ToolRegistry:add -> Tools:execute -> Orchestrator -> Runner -> command -> output handler -> chat:add_tool_output` stack intact, with all model submission disabled:

```lua
local CodeCompanion = require('codecompanion')
local CCConfig = require('codecompanion.config')
local ToolRegistry = require('codecompanion.interactions.chat.tool_registry')
local ToolRuntime = require('codecompanion.interactions.chat.tools')
local State = require('codecompanion._extensions.reasoning.state')

local T = MiniTest.new_set()
local eq = MiniTest.expect.equality

local names = {
  'reasoning_frame',
  'reasoning_evidence',
  'reasoning_options',
  'reasoning_review',
  'reasoning_synthesis',
}

local buffers = {}
local original_tools
local call_sequence = 0

T.hooks = {
  pre_case = function()
    original_tools = vim.deepcopy(CCConfig.interactions.chat.tools)
    State._reset()
    CodeCompanion.setup({
      interactions = {
        chat = {
          tools = {
            opts = {
              auto_submit_success = false,
              auto_submit_errors = false,
              default_tools = {},
              system_prompt = { enabled = false },
            },
          },
        },
      },
      extensions = {
        reasoning = { enabled = true, opts = { auto_attach = false } },
      },
    })
  end,
  post_case = function()
    State._reset()
    CCConfig.interactions.chat.tools = original_tools
    for _, bufnr in ipairs(buffers) do
      if vim.api.nvim_buf_is_valid(bufnr) then
        vim.api.nvim_buf_delete(bufnr, { force = true })
      end
      pcall(vim.api.nvim_del_augroup_by_name, 'codecompanion.tools:' .. bufnr)
      pcall(vim.api.nvim_del_augroup_by_name, 'codecompanion.tools.list:' .. bufnr)
    end
    buffers = {}
  end,
}

local function new_chat(id)
  local bufnr = vim.api.nvim_create_buf(false, true)
  table.insert(buffers, bufnr)
  local chat = {
    id = id,
    bufnr = bufnr,
    messages = {},
    outputs = {},
    tools_done_count = 0,
    submit_count = 0,
  }
  chat.context = { items = {} }
  function chat.context:add(item)
    table.insert(self.items, item)
  end
  function chat:add_message(message, opts)
    message = vim.deepcopy(message)
    message.opts = vim.deepcopy(opts)
    table.insert(self.messages, message)
  end
  function chat:set_system_prompt(prompt, opts)
    self:add_message({ role = 'system', content = prompt }, opts)
  end
  function chat:make_system_prompt_context()
    return {}
  end
  function chat:add_tool_output(tool, for_llm, for_user)
    table.insert(self.outputs, { tool = tool.name, for_llm = for_llm, for_user = for_user })
  end
  function chat:tools_done()
    self.tools_done_count = self.tools_done_count + 1
  end
  function chat:submit()
    self.submit_count = self.submit_count + 1
  end

  chat.tools = ToolRuntime.new({
    adapter = { name = 'reasoning_test', type = 'http', available_tools = {} },
    bufnr = bufnr,
    messages = chat.messages,
  })
  chat.tools.chat = chat
  chat.tool_registry = ToolRegistry.new({ chat = chat, ctx = {} })
  return chat
end

local function attach_group(chat)
  eq(chat.tool_registry:add('reasoning') ~= nil, true)
  eq(chat.tool_registry.groups.reasoning, names)
  eq(vim.tbl_count(chat.tool_registry.in_use), 5)
  for _, name in ipairs(names) do
    eq(chat.tool_registry.in_use[name], true)
    eq(type(chat.tool_registry.schemas['<tool>' .. name .. '</tool>']), 'table')
  end
  local group_context = false
  for _, item in ipairs(chat.context.items) do
    group_context = group_context or item.id == '<group>reasoning</group>'
  end
  eq(group_context, true)
  local group_prompt = false
  for _, message in ipairs(chat.messages) do
    group_prompt = group_prompt
      or (type(message.content) == 'string' and message.content:find('<structured_reasoning>', 1, true) ~= nil)
  end
  eq(group_prompt, true)
end

local function invoke(chat, name, arguments)
  call_sequence = call_sequence + 1
  local output_count = #chat.outputs
  local completed_count = chat.tools_done_count
  chat.tools:execute(chat, {
    {
      id = 'reasoning-call-' .. call_sequence,
      type = 'function',
      ['function'] = { name = name, arguments = vim.deepcopy(arguments) },
    },
  })
  eq(vim.wait(1000, function()
    return chat.tools_done_count > completed_count
  end, 10), true)
  eq(#chat.outputs, output_count + 1)
  eq(chat.tool_orchestrator, nil)
  return chat.outputs[#chat.outputs]
end

local function frame_args(objective)
  return {
    action = 'start',
    objective = objective,
    problem_type = 'analysis',
    depth = 'standard',
    constraints = {},
    success_criteria = { 'Reach a supported conclusion' },
    unknowns = {},
    perspectives = { { name = 'correctness', purpose = 'Check whether the conclusion follows' } },
    temporal_required = false,
    branching_required = false,
    branching_rationale = 'This test evaluates one claim',
  }
end

local function evidence_args()
  return {
    items = {
      {
        kind = 'observation',
        statement = 'The supplied test observation is available',
        source = 'user statement',
        confidence = 'high',
        falsifier = 'The user withdraws the observation',
        perspective = 'correctness',
        addresses_unknowns = {},
        supports = {},
        contradicts = {},
        qualifies = {},
        supersedes_id = '',
      },
    },
  }
end

T['runs registered tools through v19.22.0 and isolates chats'] = function()
  eq(CodeCompanion.version(), '19.22.0')
  local first = new_chat(1)
  local second = new_chat(2)
  attach_group(first)
  attach_group(second)

  local success = invoke(first, 'reasoning_frame', frame_args('First chat objective'))
  local success_payload = vim.json.decode(success.for_llm)
  eq(success.tool, 'reasoning_frame')
  eq(success_payload.workspace_id, 'W1')
  eq(success_payload.artifact.id, 'F1')
  eq(success_payload.next_action.tool, 'reasoning_evidence')
  eq(success_payload.artifacts_by_id, nil)
  eq(success.for_user, 'Recorded F1; next: reasoning_evidence')
  eq(#success.for_user < 96, true)

  local rejected = invoke(second, 'reasoning_evidence', evidence_args())
  local error_payload = vim.json.decode(rejected.for_llm)
  eq(rejected.tool, 'reasoning_evidence')
  eq(error_payload.code, 'workspace_missing')
  eq(error_payload.next_action.tool, 'reasoning_frame')
  eq(rejected.for_user, 'Reasoning step rejected: workspace_missing')
  eq(State.get(second), nil)

  local second_success = invoke(second, 'reasoning_frame', frame_args('Second chat objective'))
  eq(vim.json.decode(second_success.for_llm).workspace_id, 'W1')
  local first_workspace = State.get(first)
  local second_workspace = State.get(second)
  eq(first_workspace == second_workspace, false)
  eq(first_workspace.id, 'W1')
  eq(second_workspace.id, 'W1')
  eq(State.find(first_workspace, 'F1').data.objective, 'First chat objective')
  eq(State.find(second_workspace, 'F1').data.objective, 'Second chat objective')
  eq(first.submit_count, 0)
  eq(second.submit_count, 0)
end

return T
```

- [ ] **Step 4: Run all three files and verify the new output and registration are absent**

Run: `make test_file FILE=tests/codecompanion/_extensions/reasoning/output_test.lua`

Expected: FAIL while requiring `codecompanion._extensions.reasoning.output`.

Run: `make test_file FILE=tests/codecompanion/_extensions/reasoning/init_test.lua`

Expected: FAIL because the legacy extension still reads `config.strategies` and does not register the five path-based tools.

Run: `make test_file FILE=tests/codecompanion/_extensions/reasoning/runtime_integration_test.lua`

Expected: FAIL before the native tool group and shared output handlers exist.

- [ ] **Step 5: Implement `output.lua`**

```lua
local M = {}

local function last(values)
  return type(values) == 'table' and values[#values] or {}
end

local function encode(value)
  local ok, encoded = pcall(vim.json.encode, value)
  return ok and encoded or vim.inspect(value)
end

function M.success(tool, stdout, meta)
  local payload = last(stdout)
  local artifact = payload.artifact or (payload.artifacts and payload.artifacts[#payload.artifacts])
  local artifact_id = artifact and artifact.id or 'artifact'
  local next_tool = payload.next_action and payload.next_action.tool or 'none'
  meta.tools.chat:add_tool_output(tool, encode(payload), string.format('Recorded %s; next: %s', artifact_id, next_tool))
end

function M.error(tool, stderr, meta)
  local payload = last(stderr)
  local code = payload.code or 'internal_error'
  meta.tools.chat:add_tool_output(tool, encode(payload), 'Reasoning step rejected: ' .. code)
end

M.handlers = { success = M.success, error = M.error }

return M
```

- [ ] **Step 6: Assign shared output handlers to all five tools**

Apply this exact patch:

```diff
*** Begin Patch
*** Update File: lua/codecompanion/_extensions/reasoning/tools/frame.lua
@@
 local Config = require('codecompanion._extensions.reasoning.config')
 local Protocol = require('codecompanion._extensions.reasoning.protocol')
+local Output = require('codecompanion._extensions.reasoning.output')
@@
   cmds = {
@@
   },
+  output = Output.handlers,
   schema = {
*** Update File: lua/codecompanion/_extensions/reasoning/tools/evidence.lua
@@
 local Protocol = require('codecompanion._extensions.reasoning.protocol')
+local Output = require('codecompanion._extensions.reasoning.output')
@@
   cmds = {
@@
   },
+  output = Output.handlers,
   schema = {
*** Update File: lua/codecompanion/_extensions/reasoning/tools/options.lua
@@
 local Protocol = require('codecompanion._extensions.reasoning.protocol')
+local Output = require('codecompanion._extensions.reasoning.output')
@@
   cmds = {
@@
   },
+  output = Output.handlers,
   schema = {
*** Update File: lua/codecompanion/_extensions/reasoning/tools/review.lua
@@
 local Protocol = require('codecompanion._extensions.reasoning.protocol')
+local Output = require('codecompanion._extensions.reasoning.output')
@@
   cmds = {
@@
   },
+  output = Output.handlers,
   schema = {
*** Update File: lua/codecompanion/_extensions/reasoning/tools/synthesis.lua
@@
 local Protocol = require('codecompanion._extensions.reasoning.protocol')
+local Output = require('codecompanion._extensions.reasoning.output')
@@
   cmds = {
@@
   },
+  output = Output.handlers,
   schema = {
*** End Patch
```

- [ ] **Step 7: Replace extension setup with current registration**

```lua
local Config = require('codecompanion._extensions.reasoning.config')

local M = {}
local tool_names = {
  'reasoning_frame',
  'reasoning_evidence',
  'reasoning_options',
  'reasoning_review',
  'reasoning_synthesis',
}

local paths = {
  reasoning_frame = '_extensions.reasoning.tools.frame',
  reasoning_evidence = '_extensions.reasoning.tools.evidence',
  reasoning_options = '_extensions.reasoning.tools.options',
  reasoning_review = '_extensions.reasoning.tools.review',
  reasoning_synthesis = '_extensions.reasoning.tools.synthesis',
}

local descriptions = {
  reasoning_frame = 'Frame a difficult problem before developing conclusions',
  reasoning_evidence = 'Record sourced and falsifiable evidence or assumptions',
  reasoning_options = 'Create competing solutions, hypotheses, or scenarios',
  reasoning_review = 'Adversarially challenge and revise reasoning artifacts',
  reasoning_synthesis = 'Record a checkpoint or gated final synthesis',
}

function M.setup(user_options)
  local options = Config.setup(user_options)
  local tools = require('codecompanion.config').interactions.chat.tools
  tools.groups = tools.groups or {}
  tools.opts = tools.opts or {}
  tools.opts.default_tools = tools.opts.default_tools or {}
  for _, name in ipairs(tool_names) do
    tools[name] = { path = paths[name], description = descriptions[name] }
  end
  tools.groups.reasoning = {
    description = 'Guided reasoning for difficult analysis, diagnosis, design, decision, and planning problems',
    system_prompt = string.format([[<structured_reasoning>
Use this protocol for difficult problems; routine requests do not need every tool.
1. Start with reasoning_frame. Use %s depth unless the problem warrants another explicit depth.
2. Record externally meaningful observations, claims, and labelled assumptions with reasoning_evidence. Every item needs a source and a result that would falsify or materially revise it; link evidence to exact framed unknowns when it addresses them.
3. For decisions, diagnoses, designs, and plans, use reasoning_options to maintain competing solutions, hypotheses, or scenarios. Do not select an option in the call that invents it.
4. Use reasoning_review to defend the strongest case, attack it, expose hidden assumptions and blind spots, and record corrections. Use stress-tested temporal review when the frame requires reasoning across transitions. Resolve contradictions only with an explicit, supported qualification record.
5. Use reasoning_synthesis checkpoint mode whenever a compact progress record helps. Use final mode only after the returned gates are empty.
After every accepted call, follow its single next_action unless new user information changes the frame. Correct rejected calls using their stable error payload. Record concise decision-relevant artifacts, never private chain-of-thought.
The tools validate structure, references, ordering, and coverage. They do not establish factual truth, guarantee independent perspectives, or replace external verification.
</structured_reasoning>]], options.default_depth),
    tools = vim.deepcopy(tool_names),
    opts = { collapse_tools = true },
  }
  if options.auto_attach and not vim.tbl_contains(tools.opts.default_tools, 'reasoning') then
    table.insert(tools.opts.default_tools, 'reasoning')
  end
end

M.exports = {
  tool_names = function()
    return vim.deepcopy(tool_names)
  end,
}

return M
```

- [ ] **Step 8: Run integration-focused tests, format, and commit**

Run: `make test_file FILE=tests/codecompanion/_extensions/reasoning/output_test.lua`

Run: `make test_file FILE=tests/codecompanion/_extensions/reasoning/init_test.lua`

Run: `make test_file FILE=tests/codecompanion/_extensions/reasoning/runtime_integration_test.lua`

Expected: all three PASS; the runner-backed test executes success and error paths, attaches the group, and proves chat isolation without model submission.

Run: `stylua lua/codecompanion/_extensions/reasoning/init.lua lua/codecompanion/_extensions/reasoning/output.lua lua/codecompanion/_extensions/reasoning/tools tests/codecompanion/_extensions/reasoning/init_test.lua tests/codecompanion/_extensions/reasoning/output_test.lua tests/codecompanion/_extensions/reasoning/runtime_integration_test.lua -f stylua.toml`

Run: `make test_file FILE=tests/codecompanion/_extensions/reasoning/output_test.lua`

Run: `make test_file FILE=tests/codecompanion/_extensions/reasoning/init_test.lua`

Run: `make test_file FILE=tests/codecompanion/_extensions/reasoning/runtime_integration_test.lua`

Expected: all three PASS after formatting.

```bash
git add lua/codecompanion/_extensions/reasoning/init.lua lua/codecompanion/_extensions/reasoning/output.lua lua/codecompanion/_extensions/reasoning/tools tests/codecompanion/_extensions/reasoning/init_test.lua tests/codecompanion/_extensions/reasoning/output_test.lua tests/codecompanion/_extensions/reasoning/runtime_integration_test.lua
git commit -m "feat(reasoning): register native tool group"
```

### Task 9: Remove the legacy surface and rewrite documentation

**Files:**
- Delete: `lua/codecompanion-reasoning.lua`
- Delete: `plugin/codecompanion-reasoning.lua`
- Delete: `lua/codecompanion/_extensions/reasoning/commands.lua`
- Delete: `lua/codecompanion/_extensions/reasoning/helpers/`
- Delete: `lua/codecompanion/_extensions/reasoning/ui/`
- Delete legacy tool modules not among the five new modules.
- Delete legacy tests and fixtures that correspond to removed code.
- Delete: `.codecompanion/project-knowledge.md`
- Delete: `.codecompanion/.project-knowledge-prompted`
- Modify: `README.md`
- Modify: `tests/codecompanion-reasoning_test.lua` by deleting it.

- [ ] **Step 1: Capture the pre-cleanup inventory**

Run:

```bash
rg --files lua/codecompanion/_extensions/reasoning | sort
```

Expected: both the six new core modules and five new tools are present alongside the legacy helpers, UI, commands, and tool modules that Step 2 removes.

- [ ] **Step 2: Delete exact legacy paths**

Run this exact removal command from the clean implementation worktree:

```bash
git rm -r \
  .codecompanion/.project-knowledge-prompted \
  .codecompanion/project-knowledge.md \
  lua/codecompanion-reasoning.lua \
  plugin/codecompanion-reasoning.lua \
  lua/codecompanion/_extensions/reasoning/commands.lua \
  lua/codecompanion/_extensions/reasoning/helpers \
  lua/codecompanion/_extensions/reasoning/ui \
  tests/codecompanion-reasoning_test.lua \
  tests/codecompanion/_extensions/reasoning/commands_test.lua \
  tests/codecompanion/_extensions/reasoning/helpers \
  tests/codecompanion/_extensions/reasoning/ui \
  tests/tmp_init_ai \
  tests/tmp_sessions
```

Then remove the ten old tool modules and their tests without touching the five new modules:

```bash
git rm \
  lua/codecompanion/_extensions/reasoning/tools/add_tools.lua \
  lua/codecompanion/_extensions/reasoning/tools/ask_user.lua \
  lua/codecompanion/_extensions/reasoning/tools/chain_of_thoughts_agent.lua \
  lua/codecompanion/_extensions/reasoning/tools/graph_of_thoughts_agent.lua \
  lua/codecompanion/_extensions/reasoning/tools/initialize_project_knowledge.lua \
  lua/codecompanion/_extensions/reasoning/tools/list_files.lua \
  lua/codecompanion/_extensions/reasoning/tools/meta_agent.lua \
  lua/codecompanion/_extensions/reasoning/tools/project_knowledge.lua \
  lua/codecompanion/_extensions/reasoning/tools/reflect_on_progress.lua \
  lua/codecompanion/_extensions/reasoning/tools/tree_of_thoughts_agent.lua \
  tests/codecompanion/_extensions/reasoning/tools/add_tools_test.lua \
  tests/codecompanion/_extensions/reasoning/tools/ask_user_test.lua \
  tests/codecompanion/_extensions/reasoning/tools/chain_of_thoughts_agent_test.lua \
  tests/codecompanion/_extensions/reasoning/tools/graph_of_thoughts_agent_test.lua \
  tests/codecompanion/_extensions/reasoning/tools/initialize_project_knowledge_test.lua \
  tests/codecompanion/_extensions/reasoning/tools/list_files_test.lua \
  tests/codecompanion/_extensions/reasoning/tools/meta_agent_test.lua \
  tests/codecompanion/_extensions/reasoning/tools/project_knowledge_test.lua \
  tests/codecompanion/_extensions/reasoning/tools/reflect_on_progress_test.lua \
  tests/codecompanion/_extensions/reasoning/tools/tree_of_thoughts_agent_test.lua
```

Verify the exact retained runtime set after both removals:

```bash
rg --files lua/codecompanion/_extensions/reasoning | sort
```

Expected:

```text
lua/codecompanion/_extensions/reasoning/config.lua
lua/codecompanion/_extensions/reasoning/guidance.lua
lua/codecompanion/_extensions/reasoning/init.lua
lua/codecompanion/_extensions/reasoning/output.lua
lua/codecompanion/_extensions/reasoning/protocol.lua
lua/codecompanion/_extensions/reasoning/state.lua
lua/codecompanion/_extensions/reasoning/tools/evidence.lua
lua/codecompanion/_extensions/reasoning/tools/frame.lua
lua/codecompanion/_extensions/reasoning/tools/options.lua
lua/codecompanion/_extensions/reasoning/tools/review.lua
lua/codecompanion/_extensions/reasoning/tools/synthesis.lua
```

- [ ] **Step 3: Replace `README.md` with the complete focused documentation**

````markdown
# CodeCompanion Structured Reasoning

Five deterministic tools for guiding difficult analysis, diagnosis, design, decisions, and planning in [CodeCompanion.nvim](https://github.com/olimorris/codecompanion.nvim).

The extension records concise reasoning artifacts and enforces structural gates. It does not expose private chain-of-thought or claim that a well-shaped argument is factually true.

## Requirements

- Neovim supported by CodeCompanion
- CodeCompanion.nvim v19.22.0 or compatible current API
- A tool-capable model; the protocol targets Qwen3.6-27B-class models or stronger

## Installation

With lazy.nvim:

```lua
{
  'olimorris/codecompanion.nvim',
  dependencies = {
    'lazymaniac/codecompanion-reasoning.nvim',
  },
  opts = {
    extensions = {
      reasoning = {
        enabled = true,
        opts = {},
      },
    },
  },
}
```

Add `@{reasoning}` to a chat only when the problem benefits from explicit evidence, competing alternatives, adversarial review, and verification. Easy questions usually do not benefit from the extra calls.

## Tools

### `reasoning_frame`

Starts, revises, or explicitly replaces a chat-local workspace.

```json
{
  "action": "start",
  "objective": "Choose a durable cache design",
  "problem_type": "design",
  "depth": "deep",
  "constraints": ["No external service"],
  "success_criteria": ["Survives restart", "Keeps memory bounded"],
  "unknowns": ["Expected write rate"],
  "perspectives": [
    { "name": "correctness", "purpose": "Find recovery failures" },
    { "name": "operations", "purpose": "Find lifecycle failures" }
  ],
  "temporal_required": false,
  "branching_required": true,
  "branching_rationale": "Several storage strategies are viable"
}
```

### `reasoning_evidence`

Records observations, claims, and explicitly labelled assumptions. Every item needs a source, confidence, falsifier, and frame perspective.

```json
{
  "items": [{
    "kind": "observation",
    "statement": "The current cache is process-local",
    "source": "lua/cache.lua:14",
    "confidence": "high",
    "falsifier": "A persistence adapter loaded by cache.lua",
    "perspective": "correctness",
    "addresses_unknowns": [],
    "supports": [],
    "contradicts": [],
    "qualifies": [],
    "supersedes_id": ""
  }]
}
```

Assumption sources begin with `assumption:` so they cannot be confused with direct observations.

### `reasoning_options`

Creates two to six competing solutions, hypotheses, or scenarios as one coherent branch set.

```json
{
  "question": "Which cache architecture satisfies the frame?",
  "branch_type": "solution",
  "criteria": ["Durability", "Bounded memory"],
  "supersedes_branch_id": "",
  "options": [
    {
      "label": "journal",
      "summary": "Append mutations to a checksummed journal",
      "evidence_ids": ["E1"],
      "assumptions": ["Disk writes are available"],
      "predictions": ["Replay restores committed entries"],
      "benefits": ["Durable without a service"],
      "costs": ["Compaction"],
      "risks": ["Torn writes"],
      "reversibility": "moderate"
    },
    {
      "label": "snapshot",
      "summary": "Write periodic atomic snapshots",
      "evidence_ids": ["E1"],
      "assumptions": ["State fits in one file"],
      "predictions": ["Recovery loads the last snapshot"],
      "benefits": ["Simple recovery"],
      "costs": ["Repeated full writes"],
      "risks": ["Stale recovery point"],
      "reversibility": "easy"
    }
  ]
}
```

### `reasoning_review`

Defends the strongest current case, attacks it with falsifiable challenges, records blind spots, and gives every target a `keep`, `revise`, or `retract` verdict.

```json
{
  "mode": "full",
  "target_ids": ["O1", "E1"],
  "defense": { "summary": "Restart evidence supports the journal", "evidence_ids": ["E1"] },
  "challenges": [
    {
      "kind": "counterexample",
      "summary": "A torn record can break replay",
      "target_ids": ["O1"],
      "falsifier": "Recovery succeeds for every partial suffix"
    },
    {
      "kind": "hidden_assumption",
      "summary": "Atomic filesystem behavior is assumed",
      "target_ids": ["O1"],
      "falsifier": "The target filesystem guarantees the operation"
    }
  ],
  "blind_spots": ["Disk exhaustion"],
  "stress_tests": [],
  "verdicts": [
    { "target_id": "O1", "status": "revise", "revision_instruction": "Add torn-write recovery" },
    { "target_id": "E1", "status": "keep", "revision_instruction": "" }
  ],
  "contradiction_resolutions": [],
  "structural_tradeoffs": []
}
```

### `reasoning_synthesis`

Records an ungated checkpoint or attempts a gated final result.

```json
{
  "mode": "final",
  "conclusion": "Use a checksummed journal with truncation recovery",
  "selected_option_ids": ["O1"],
  "support_ids": ["E1", "E2"],
  "review_ids": ["R1"],
  "criterion_results": [
    { "criterion": "Survives restart", "status": "passed", "evidence_ids": ["E1"], "explanation": "Replay test passes" },
    { "criterion": "Keeps memory bounded", "status": "passed", "evidence_ids": ["E2"], "explanation": "Compaction test passes" }
  ],
  "tradeoffs": ["Higher write amplification"],
  "uncertainties": ["Disk-full behavior needs platform testing"],
  "blind_spots": ["Network filesystems were not evaluated"],
  "next_actions": ["Implement behind the cache interface"],
  "confidence": "medium"
}
```

## Protocol

The normal flow is iterative:

```text
Frame -> Evidence <-> Options <-> Review -> Synthesis
```

Every accepted call returns newly recorded artifacts, compact progress counts, current unmet gates, and one deterministic `next_action`.

Standard depth requires a frame, cited evidence for framed unknowns, branches when the frame requires them, review when branches or contradictions exist, a stress-tested review for temporal frames, no unresolved revision affecting the active frame, selected branch or option, or cited support, and complete passing or justified-not-applicable criteria.

Deep depth additionally requires evidence from at least two perspectives, supported competing options, a relevant full adversarial review with a falsification attempt, no unresolved revisions or contradictions affecting the result, and supported selected options and passed criteria.

Revisions are append-oriented. Frame, evidence, options, or synthesis creates a replacement and leaves the old artifact marked `superseded`. Review may mark an artifact `retracted` or open a typed revision requirement. Expected failures return a stable code, affected IDs, and the corrective next action; they do not partially write a failed batch.

## Configuration

```lua
opts = {
  auto_attach = false,
  default_depth = 'deep',
  limits = {
    max_artifacts = 192,
    max_batch_items = 8,
    max_text_chars = 2000,
    max_array_items = 12,
  },
}
```

- `auto_attach`: add the `@{reasoning}` group to every chat. The default is `false`.
- `default_depth`: prompt guidance for `standard` or `deep`; strict calls still state the depth.
- `max_artifacts`: total append-oriented artifacts in one workspace.
- `max_batch_items`: evidence records accepted in one call.
- `max_text_chars`: maximum size of one text field.
- `max_array_items`: maximum size of a general artifact array.

All limits are positive integers. Invalid configuration fails setup.

## Privacy and scope

The extension keeps bounded artifacts in memory and keys them weakly by the active chat object. It performs no persistence, project-memory access, file discovery, commands, UI, or secondary model calls. It asks for decision-relevant summaries, not raw private chain-of-thought. Releasing a chat makes its workspace eligible for collection.

The protocol checks structure, references, ordering, and coverage. It cannot establish that evidence is true, perspectives are genuinely independent, or a critique is insightful.

## Breaking migration

This rewrite removes `chain_of_thoughts_agent`, `tree_of_thoughts_agent`, `graph_of_thoughts_agent`, `meta_agent`, `add_tools`, `ask_user`, `reflect_on_progress`, `list_files`, `project_knowledge`, and `initialize_project_knowledge`. It also removes the replacement system prompt, sessions, restoration, titles, commands, pickers, popup UI, project-memory files, and compatibility entry points.

Use CodeCompanion's current built-in groups and tools for file operations, user questions, memory, general agent behavior, and chat/session features.

````

- [ ] **Step 4: Assert the repository has only the intended runtime surface**

Run:

```bash
! rg -n "session_manager|session_restorer|project_knowledge|list_files|ask_user|meta_agent|add_tools|chain_of_thoughts_agent|tree_of_thoughts_agent|graph_of_thoughts_agent|reflect_on_progress|codecompanion\.strategies" lua tests
rg -n "Breaking migration|chain_of_thoughts_agent|project_knowledge" README.md
```

Expected: the first command has no matches, and the second matches only the documented breaking-migration section.

- [ ] **Step 5: Run the complete deterministic suite**

Run: `make test`

Expected: PASS with 0 failures and, after the one-time dependency bootstrap, no network or external model interaction.

- [ ] **Step 6: Commit the breaking cleanup**

```bash
git add -A
git commit -m "refactor!: remove legacy plugin surface" -m "BREAKING CHANGE: replace legacy agents and ancillary features with five chat-scoped structured reasoning tools."
```

### Companion Evaluation Plan

The optional control/treatment model evaluation is deliberately separate from the core rewrite. Implement it only after this plan is complete by following [the companion evaluation plan](2026-08-01-structured-reasoning-evaluation.md).

### Task 10: Final formatting, compatibility verification, and audit

**Files:**
- Modify only files changed by formatting or defects found by verification.

- [ ] **Step 1: Format the complete runtime and tests**

Run: `make format`

Expected: StyLua completes without errors.

- [ ] **Step 2: Prove formatting is idempotent and run the full suite from a clean process**

Run: `git diff --exit-code`

Expected: no output; every file was already formatted before its task commit.

Run: `make test`

Expected: all cases PASS, 0 failures, 0 notes indicating runtime errors.

- [ ] **Step 3: Verify current CodeCompanion paths and removed scope**

Run:

```bash
! rg -n "codecompanion\.strategies|session_manager|session_restorer|project_knowledge|list_files|ask_user|meta_agent|add_tools|chain_of_thoughts_agent|tree_of_thoughts_agent|graph_of_thoughts_agent|reflect_on_progress" lua tests
```

Expected: no matches.

Run:

```bash
rg --files lua/codecompanion/_extensions/reasoning | sort
```

Expected: exactly the 11 runtime files listed in this plan's file-structure section.

- [ ] **Step 4: Verify the final diff and commit history**

Run: `git diff --check`

Expected: no whitespace errors.

Run: `git status --short`

Expected: empty.

Run: `git log --oneline --decorate -10`

Expected: focused commits corresponding to Tasks 1-9.
