# Deep Perspective Lower Bound Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let deep frames contain more than four perspectives while preserving the minimum of two and the configured general array safety bound.

**Architecture:** Keep frame cardinality enforcement in `Protocol.frame`, but separate the depth-dependent lower bound from the configured upper safety bound so each failure has an accurate recovery instruction. Advertise the portable lower bound in the tool schema and retain runtime enforcement for the conditional deep requirement and configured maximum.

**Tech Stack:** Lua, Neovim, CodeCompanion function-tool schemas, mini.test

---

### Task 1: Correct perspective cardinality and recovery

**Files:**
- Modify: `tests/codecompanion/_extensions/reasoning/tools/frame_test.lua`
- Modify: `lua/codecompanion/_extensions/reasoning/protocol.lua:96`
- Modify: `lua/codecompanion/_extensions/reasoning/tools/frame.lua:39`

- [ ] **Step 1: Add a reusable perspective-resize helper**

Add this helper below `valid_args` in `frame_test.lua` so the established
`correctness` and `operations` fixture names remain unchanged:

```lua
local function resize_perspectives(args, count)
  while #args.perspectives > count do
    table.remove(args.perspectives)
  end
  for index = #args.perspectives + 1, count do
    table.insert(args.perspectives, {
      name = 'perspective-' .. index,
      purpose = 'Inspect concern ' .. index,
    })
  end
  return args
end
```

- [ ] **Step 2: Write failing cardinality and recovery tests**

Add these cases after `starts a deep frame and recommends evidence`:

```lua
T['accepts a deep frame with more than four perspectives'] = function()
  local args = resize_perspectives(valid_args(), 5)
  local result = Frame.cmds[1]({ chat = {} }, args, {})

  eq(result.status, 'success')
end

T['explains the deep perspective lower bound'] = function()
  local args = resize_perspectives(valid_args(), 1)
  local result = Frame.cmds[1]({ chat = {} }, args, {})

  eq(result.status, 'error')
  eq(result.data.code, 'frame_incomplete')
  eq(result.data.message, 'deep frames require at least 2 perspectives; received 1')
  eq(result.data.next_action.tool, 'reasoning_frame')
  eq(result.data.next_action.reason, 'Add perspectives and retry with action=start')
end

T['explains the configured perspective safety bound'] = function()
  Config.setup({ limits = { max_array_items = 4 } })
  local args = resize_perspectives(valid_args(), 5)
  local result = Frame.cmds[1]({ chat = {} }, args, {})

  eq(result.status, 'error')
  eq(result.data.code, 'frame_incomplete')
  eq(result.data.message, 'perspectives exceed max_array_items=4; received 5')
  eq(result.data.next_action.tool, 'reasoning_frame')
  eq(result.data.next_action.reason, 'Reduce perspectives to 4 or fewer and retry with action=start')
end
```

Replace the existing `rejects a deep frame with one perspective` case with the exact lower-bound case above rather than keeping duplicate coverage.

- [ ] **Step 3: Write the failing schema test**

Replace `keeps runtime configuration out of the cached depth schema` with:

```lua
T['advertises perspective lower bounds without caching the configured maximum'] = function()
  local properties = Frame.schema['function'].parameters.properties
  eq(properties.depth.description, 'Explicit protocol depth; the reasoning group prompt states the configured default.')
  eq(properties.perspectives.minItems, 1)
  eq(properties.perspectives.maxItems, nil)
  eq(
    properties.perspectives.description,
    'At least one perspective is required; deep frames require at least two. The configured max_array_items safety bound applies at runtime.'
  )
end
```

- [ ] **Step 4: Run the frame tests and verify RED**

Run:

```sh
make test_file FILE=tests/codecompanion/_extensions/reasoning/tools/frame_test.lua
```

Expected: FAIL because five perspectives still receive `frame_incomplete`, the old errors omit exact bounds, and the schema lacks `minItems` and the new description.

- [ ] **Step 5: Implement separate lower and safety bounds**

Replace the perspective cardinality block in `Protocol.frame` with:

```lua
local minimum_perspectives = args.depth == 'deep' and 2 or 1
local maximum_perspectives = Config.get().limits.max_array_items
if type(args.perspectives) ~= 'table' then
  return failure(
    'frame_incomplete',
    'perspectives must be an array',
    {},
    string.format('Provide perspectives and retry with action=%s', args.action)
  )
end
local perspective_count = #args.perspectives
if perspective_count < minimum_perspectives then
  return failure(
    'frame_incomplete',
    string.format(
      '%s frames require at least %d perspectives; received %d',
      args.depth,
      minimum_perspectives,
      perspective_count
    ),
    {},
    string.format('Add perspectives and retry with action=%s', args.action)
  )
end
if perspective_count > maximum_perspectives then
  return failure(
    'frame_incomplete',
    string.format(
      'perspectives exceed max_array_items=%d; received %d',
      maximum_perspectives,
      perspective_count
    ),
    {},
    string.format(
      'Reduce perspectives to %d or fewer and retry with action=%s',
      maximum_perspectives,
      args.action
    )
  )
end
```

This removes `math.min(4, Config.get().limits.max_array_items)` without weakening the configured safety bound.

- [ ] **Step 6: Advertise the portable schema constraint**

Add these fields to the `perspectives` property in `frame.lua`, immediately after `type = 'array'`:

```lua
minItems = 1,
description = 'At least one perspective is required; deep frames require at least two. The configured max_array_items safety bound applies at runtime.',
```

Do not add `maxItems`: `max_array_items` is runtime configuration and must not be cached in the resolved schema.

- [ ] **Step 7: Run the frame tests and verify GREEN**

Run:

```sh
make test_file FILE=tests/codecompanion/_extensions/reasoning/tools/frame_test.lua
```

Expected: all frame tests pass with zero failures and notes.

- [ ] **Step 8: Format and re-run the focused tests**

Run:

```sh
make format
make test_file FILE=tests/codecompanion/_extensions/reasoning/tools/frame_test.lua
```

Expected: formatting completes and all frame tests pass.

- [ ] **Step 9: Commit the behavior change**

```sh
git add lua/codecompanion/_extensions/reasoning/protocol.lua lua/codecompanion/_extensions/reasoning/tools/frame.lua tests/codecompanion/_extensions/reasoning/tools/frame_test.lua
git commit -m "fix(reasoning): remove perspective ceiling"
```

### Task 2: Align canonical documentation and verify the repository

**Files:**
- Modify: `docs/superpowers/specs/2026-08-01-structured-reasoning-tools-design.md:188`
- Modify: `docs/superpowers/specs/2026-08-01-structured-reasoning-tools-design.md:307`

- [ ] **Step 1: Update the public-tool contract**

Replace:

```markdown
- `perspectives`: two to four objects containing a unique `name` and `purpose` in deep mode; one to four in standard mode.
```

with:

```markdown
- `perspectives`: objects containing a unique `name` and `purpose`; deep mode requires at least two and standard mode at least one, subject only to the configured `max_array_items` safety bound.
```

- [ ] **Step 2: Update the deep profile gate**

Replace:

```markdown
- Two to four perspectives in the frame.
```

with:

```markdown
- At least two perspectives in the frame, subject to the configured `max_array_items` safety bound.
```

- [ ] **Step 3: Check documentation consistency**

Run:

```sh
rg -n "two to four|one to four|2–4" README.md docs/superpowers/specs/2026-08-01-structured-reasoning-tools-design.md lua tests
```

Expected: no output; the canonical contract no longer claims that frames are limited to four perspectives.

- [ ] **Step 4: Run complete verification**

Run:

```sh
make format
make test
git diff --check
```

Expected: formatting completes, all tests pass with zero failures and notes, and `git diff --check` produces no output.

- [ ] **Step 5: Commit the documentation alignment**

```sh
git add docs/superpowers/specs/2026-08-01-structured-reasoning-tools-design.md
git commit -m "docs(reasoning): align perspective bounds"
```

- [ ] **Step 6: Confirm readiness for the next live run**

Run:

```sh
git status --short
git log -3 --oneline
```

Expected: the worktree is clean and the latest commits contain the behavior change, documentation alignment, and approved design. Report deterministic verification separately from any later live-model result.
