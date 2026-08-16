# Inquiry Tree Decomposition Implementation Plan

> **For agentic workers:** Steps use checkbox (`- [ ]`) syntax for tracking. Run
> `make format` before each commit and the full `make test` at every task
> boundary; zero failures and zero notes is the bar.

**Goal:** Decompose a framed problem into atomic leaves, close every leaf against
cited active evidence, and block the final synthesis while any leaf is open —
while making mid-run discovery cost one call instead of the whole workspace.

**Design:** [2026-08-16-inquiry-tree-decomposition-design.md](../specs/2026-08-16-inquiry-tree-decomposition-design.md).
That spec is authoritative for the split and closure rule tables, the tool
schema, the gate list, and the frontier shape; this plan does not restate them.

**Architecture:** Append-only `question` (`Q`) and `closure` (`C`) artifacts with
derived open/closed state, one new tool `reasoning_question`
(`split | answer | drop`), a frame *lineage* that lets `reasoning_frame
action=amend` add work without retiring anything, four new final gates, and a
bounded deterministic frontier on every payload.

**Tech Stack:** Lua 5.1/LuaJIT, Neovim APIs, CodeCompanion.nvim v19.22.0 chat and
tool APIs, MiniTest, StyLua.

---

## Execution prerequisite

Execute directly on `main`, one commit per task. Before Task 1, verify the pinned
host and baseline:

```bash
git -C deps/codecompanion.nvim describe --tags --exact-match
make test
```

Expected: host tag `v19.22.0`, zero failures and zero notes.

## Shared contracts

- Node state is **derived**, never stored: an open leaf is an active `question`
  with no active children and no valid active `closure`.
- Every action allocates artifacts; no handler mutates an existing artifact's
  `data`. Status changes go through `State.retire`/`State.supersede`.
- `Protocol.transition` remains the only expected-tool authority; `Tree` is pure
  and shared by `guidance.lua` and `protocol.lua` to keep them in agreement.
- Every rejection keeps `committed = false`, a stable code, a safe diagnostic,
  and an unchanged `revision`, `artifact_order`, and `next_sequence`.
- No rejection path echoes model-authored text; artifact IDs are sanitized by
  `Validation.artifact_ids`.

### Task 1: Config limits, artifact kinds, lineage state

**Files:** `config.lua`, `state.lua`, `tests/.../config_test.lua`, `tests/.../state_test.lua`

- [x] **Step 1: Write failing config and state tests**

`config_test.lua`: new defaults (`max_artifacts=320`, `max_children=6`,
`max_questions=64`, `max_tree_depth=4`, `frontier_items=12`, three booleans
true), transactional rejection of impossible tree bounds, and boolean typing.
`state_test.lua`: `Q`/`C` prefixes and sequences, one revision per lineage and
root-split mutation, `in_lineage` touching no revision, `reset_lineage` dropping
a replaced frame, and `rollback_final` leaving lineage and root split intact.

- [x] **Step 2: Run both files and verify RED**

- [x] **Step 3: Implement config and state**

`config.lua` gains the four limits and three booleans, a `boolean_options` list,
and a `limit_minimums` table (`max_children=2`, `max_array_items=2`); allowed
limits derive from `defaults.limits` so a new limit cannot be forgotten.
`state.lua` gains `question`/`closure` prefixes, `frame_lineage`, `root_split`,
and `reset_lineage` / `extend_lineage` / `set_root_split` (each `touch`) plus the
pure reader `in_lineage`.

- [x] **Step 4: Run, format, re-run, full suite**

- [x] **Step 5: Commit**

```bash
git commit -m "feat(reasoning): add inquiry tree state primitives"
```

### Task 2: Frame amend and lineage-aware currency

**Files:** `protocol.lua`, `guidance.lua`, `transition.lua`,
`tests/.../tools/frame_test.lua`, `tests/.../guidance_test.lua`,
`tests/.../transition_test.lua`

- [x] **Step 1: Write failing amend and currency tests**

Amend adds unknowns, criteria, perspectives, and constraints, retires zero
artifacts, and extends the lineage. Amend rejects removals and
`objective`/`problem_type`/`depth` changes with `amend_invalid` and an
`append_only` diagnostic, leaving `revision` unchanged. A review recorded under
the pre-amend frame stays current after amend; `revise` and `replace` still
reset the lineage and retire downstream work.

- [x] **Step 2: Run the three files and verify RED**

- [x] **Step 3: Implement amend and lineage currency**

`M.frame` gains the amend branch (normalized set-difference validation, new
frame artifact, `State.supersede` of the old frame, `State.extend_lineage`, no
retirement). `start | revise | replace` call `State.reset_lineage`. Replace
`artifact.data.frame_id == frame.id` with `State.in_lineage(...)` in
`guidance.lua` (`review_sound`, `resolution_review`, the synthesis and branch
`latest` predicates) and `protocol.lua` (`review_current_and_sound` and the
`latest_active` predicates inside `final_gates`). Add `amend` to the active-phase
frame allowance in `transition.lua`; leave `explicit_reframe` as
`{ revise, replace }` so amend stays blocked on a finalized workspace.

- [x] **Step 4: Run, format, re-run, full suite**

- [x] **Step 5: Commit**

```bash
git commit -m "feat(reasoning): amend frames without retiring work"
```

### Task 3: Pure `tree.lua` helpers

**Files:** create `lua/.../reasoning/tree.lua`, create `tests/.../tree_test.lua`

- [x] **Step 1: Write failing tree tests**

Hand-built workspaces in the style of `guidance_test.lua`'s `artifact()` and
`workspace()` helpers. Cover `children`, `closure`, `open_leaves` in pre-order
with an `artifact_order` tiebreak, `depth`, `closure_valid` flipping to false
once cited evidence is retracted, and `frontier` ordering plus exact truncation
counts.

- [x] **Step 2: Run the file and verify RED**

- [x] **Step 3: Implement the pure module**

Workspace in, tables out. Bounds are passed by the caller so `tree.lua` requires
neither `config.lua` nor `guidance.lua`, keeping it free of require cycles.

- [x] **Step 4: Run, format, re-run, full suite**

- [x] **Step 5: Commit**

```bash
git commit -m "feat(reasoning): add pure inquiry tree helpers"
```

### Task 4: `reasoning_question` tool and the split action

**Files:** `constants.lua`, create `tools/question.lua`, `schema.lua`,
`protocol.lua`, `init.lua`, `output.lua`, `control.lua`, create
`tests/.../tools/question_test.lua`, `tests/.../schema_test.lua`,
`tests/.../init_test.lua`, `tests/.../output_test.lua`, `tests/.../control_test.lua`

This task must land whole: the tool has to register, resolve, and pass the
controller in one commit or the suite breaks.

- [x] **Step 1: Write failing split, registration, and acceptance tests**

All twelve split rules from the spec, each asserting `committed = false`, the
exact diagnostic, and an unchanged workspace. A payload whose `next_action.tool`
is `reasoning_question` must round-trip through `output.lua` instead of becoming
`internal_error`. The controller shape wiring is exercised in Task 6, once guidance routes to the
tool and the preflight stops synthesizing a rejection for it. The registered group must expose six tools and
the three new prompt rules.

- [x] **Step 2: Run the five files and verify RED**

- [x] **Step 3: Implement the tool and its split action**

`Constants` gains `reasoning_question` appended to `tool_names` and the operation
maps. `tools/question.lua` carries the spec's schema. `schema.lua` gains the new
unique-array and artifact-ID paths plus the `child_questions` bound
`[2, max_children]`. `protocol.M.question` implements split. `init.lua` gains the
path, description, prompt rules 9–11, and the rule-7 wording change.
**`output.lua` `known_actions` gains `reasoning_question`** — without it every
payload naming the tool is rewritten to `internal_error`. `control.lua` gains
`accepted_shape.question = { by_action = { split, answer, drop } }` with
`accepted_payload` resolving through `by_action[marker.action]` and falling back
to the flat table.

- [x] **Step 4: Run, format, re-run, full suite**

- [x] **Step 5: Commit**

```bash
git commit -m "feat(reasoning): add inquiry tree splitting"
```

### Task 5: Seeded questions and evidence linkage

> Executed note: the closure actions landed with Task 4, because a registered
> tool whose documented actions all reject is not a shippable commit. This task
> covered seeding and evidence linkage.

**Files:** `protocol.lua`, `tools/evidence.lua`, `schema.lua`,
`tests/.../tools/question_test.lua`, `tests/.../tools/evidence_test.lua`,
`tests/.../tools/frame_test.lua`, `tests/.../control_test.lua`

- [x] **Step 1: Write failing closure and seeding tests**

All nine closure rules from the spec, including the provisional-node
`acceptance_test` requirement, `require_observation_for_closure`, and
`judgment_requires_review`. `start | revise | replace | amend` seed exactly one
provisional `question` per newly added unknown and none for pre-existing ones.
Evidence `addresses_questions` validates references; `addresses_unknowns` still
maps to seeded question IDs by exact normalized text and no longer closes
anything by itself.

- [x] **Step 2: Run the four files and verify RED**

- [x] **Step 3: Implement closure, seeding, and linkage**

`answer` and `drop` each allocate one `closure` artifact with
`relations.depends_on = { question_id }` and `relations.supports = evidence_ids`.

- [x] **Step 4: Run, format, re-run, full suite**

- [x] **Step 5: Commit**

```bash
git commit -m "feat(reasoning): close inquiry tree leaves"
```

### Task 6: Gates and guidance for open leaves

**Files:** `protocol.lua`, `guidance.lua`, `tests/.../tools/synthesis_test.lua`,
`tests/.../guidance_test.lua`, `tests/.../transition_test.lua`

- [x] **Step 1: Write failing gate and guidance tests**

`decomposition_missing`, `open_questions`, `closure_unsupported`, and
`residual_unresolved` each fire with the right blocker IDs and `gate_order`
position between `unknown_coverage_missing` and `branches_missing`. Guidance
returns root-split-first, then the first open leaf in pre-order, alternating
evidence and closure, and reopens a leaf whose evidence was retracted. Update
`transition_test.lua`'s finalized fixture so the accepted-final detector and the
new gates agree.

- [x] **Step 2: Run the three files and verify RED**

- [x] **Step 3: Implement the gates and the guidance block**

The root split is required when `depth == 'deep'` or `#unknowns > 0`, so a
standard frame with no unknowns behaves exactly as before. `next_action.reason`
names the target leaf ID.

- [x] **Step 4: Run, format, re-run, full suite**

- [x] **Step 5: Commit**

```bash
git commit -m "feat(reasoning): gate finals on open leaves"
```

### Task 7: Frontier payload and rendering

**Files:** `protocol.lua`, `render.lua`, `tests/.../render_test.lua`,
`tests/.../output_test.lua`, `tests/.../control_test.lua`,
`tests/.../tools/synthesis_test.lua`

- [x] **Step 1: Write failing frontier and rendering tests**

`open_items` on every success payload and on the `synthesis_gate_failed`
rejection, deterministic order, exact `truncated` counts at `frontier_items`, and
question text trimmed to 160 characters. The controller still classifies a
rejection that carries the extra block. Tree-less rendered output stays
byte-identical; resolved and dropped sub-question sections are escaped and
ordered pre-order.

- [x] **Step 2: Run the four files and verify RED**

- [x] **Step 3: Implement the frontier and rendering**

One `Tree.frontier(workspace, limits)` serves both the success and rejection
paths so they cannot disagree. Render sections are omitted entirely when
`root_split` is nil.

- [x] **Step 4: Run, format, re-run, full suite**

- [x] **Step 5: Commit**

```bash
git commit -m "feat(reasoning): report the reasoning frontier"
```

### Task 8: Runtime integration and documentation

**Files:** `tests/.../runtime_integration_test.lua`, `README.md`, the design spec

- [x] **Step 1: Write the failing end-to-end runs**

One enforced run: frame start → root split → evidence → close leaves → amend
adding a discovered unknown, asserting zero retirements → close it → gated final
→ terminal. One rejected run: a premature final returns `open_questions` and a
frontier naming exactly the open leaves.

- [x] **Step 2: Run the file and verify RED**

- [x] **Step 3: Document the enforced contract**

README gains the tree tool, amend semantics, and the six-tool completeness note:
a user config listing only the five old tool names now attaches an incomplete
set, so the controller stays dormant and the legacy one-shot terminal guard
applies. Set the design spec status to `Implemented`.

- [x] **Step 4: Run, format, re-run, full suite**

- [x] **Step 5: Commit**

```bash
git commit -m "feat(reasoning): document and verify the inquiry tree"
```

## Acceptance criteria

1. A final synthesis is rejected with `open_questions` while any active leaf
   lacks a valid closure, and `open_items.questions` names exactly those leaves
   in pre-order.
2. Retracting the only evidence under a closure reopens that leaf and re-blocks
   the final via `closure_unsupported`.
3. `amend` retires zero artifacts, extends the lineage, seeds one provisional
   question, and keeps prior reviews current.
4. `revise` still retires every active non-frame artifact and resets the lineage.
5. A one-child split, duplicate siblings, an undeclared residual, a conjunctive
   acceptance test under `strict_atomicity`, and an over-deep split are each
   rejected with an unchanged workspace revision.
6. Every success payload and every `synthesis_gate_failed` rejection carries a
   deterministic `open_items` block with exact truncation counts.
7. A standard frame with no unknowns renders byte-identically to the pre-change
   implementation.
8. `make test` passes with zero failures and zero notes.
