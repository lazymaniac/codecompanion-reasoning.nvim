# Inquiry Tree Decomposition Design

Date: 2026-08-16
Status: Draft for review

## Summary

Add an explicit inquiry tree to the reasoning protocol so a difficult problem is
decomposed into atomic leaves, every leaf is closed by cited active evidence,
and the final synthesis is blocked until no open leaf remains. Make frame
amendment non-destructive so a leaf discovered mid-run costs one call instead of
the whole workspace. Return a bounded, deterministic frontier with every
accepted result so the model can plan the remaining work instead of discovering
one gate per round trip.

Three coupled changes:

- **B — non-destructive amend.** `reasoning_frame` gains `action=amend`, which
  adds unknowns, criteria, perspectives, and constraints without retiring a
  single downstream artifact. Frame identity becomes a lineage rather than a
  single ID.
- **A — inquiry tree.** New `question` and `closure` artifacts, one new tool
  `reasoning_question` with `action = split | answer | drop`, structural
  atomicity validation at split time, and four new final gates.
- **G — frontier.** Every success payload and the `synthesis_gate_failed`
  rejection carry an `open_items` block of IDs and counts.

No change to `control.lua` lifecycle semantics, request-token binding, retry
budget, or the deterministic final path. The controller learns one new operation
shape; everything else lands in state, protocol, guidance, and schema.

## Problem

The current protocol enforces *order* but not *coverage*. Three concrete
defects, all reachable by a compliant model:

1. **No decomposition primitive.** Artifact kinds are
   `frame | evidence | branch | option | review | synthesis`
   ([state.lua:5](../../../lua/codecompanion/_extensions/reasoning/state.lua)).
   The only stand-in for a sub-problem is `frame.data.unknowns`, a flat array of
   strings. Unknowns cannot nest, carry no state, and cannot record how they
   were resolved. "Explore every leaf" is not expressible.

2. **Unknown closure is trivially satisfiable.** In
   [guidance.lua:247](../../../lua/codecompanion/_extensions/reasoning/guidance.lua)
   and
   [protocol.lua:1917](../../../lua/codecompanion/_extensions/reasoning/protocol.lua),
   a single evidence item naming the unknown in `addresses_unknowns` clears it
   permanently — including `kind='assumption'`, `confidence='low'`, source
   `assumption: probably fine`. One line of model text closes a framed unknown.

3. **Frame revise is scorched earth.** `Protocol.frame` retires *every* active
   non-frame artifact on `action=revise`
   ([protocol.lua:341](../../../lua/codecompanion/_extensions/reasoning/protocol.lua)).
   A newly discovered unknown therefore costs the entire workspace, so the
   rational model behaviour is to never revise and to under-specify unknowns at
   framing time — exactly when it knows least. The protocol punishes the
   iterative deepening that exhaustive exploration requires.

A fourth, milder defect motivates G: `success_payload` returns `unmet_gates` plus
one `next_action`
([protocol.lua:27](../../../lua/codecompanion/_extensions/reasoning/protocol.lua)).
The model never sees the outstanding-work list, so it cannot plan for
completion and pays one round trip per discovered gate.

## Goals

1. Represent the problem as a tree of questions with an unambiguous, derivable
   open/closed state per node.
2. Make every leaf closable only by cited active evidence that meets a declared
   acceptance test, and block final synthesis while any leaf is open.
3. Make ill-formed decompositions impossible to *state*: no one-child splits, no
   duplicate siblings, no undeclared residual, no unbounded depth.
4. Make mid-run discovery cheap: adding a question, criterion, perspective, or
   constraint must retire nothing.
5. Give the model a bounded, deterministic frontier of remaining obligations
   with every accepted result.
6. Preserve every existing guarantee: fail-closed transitions, atomic
   rejections, safe diagnostics, deterministic final rendering, request-token
   isolation, bounded retries.
7. Keep all new validation pure and deterministic — no model-text echo in
   rejection payloads, no judgment of factual truth.

## Non-goals

- Deciding whether a decomposition is *semantically* correct. Correctness of a
  split is a property of the answer; this design makes bad splits harder to
  state, cheap to repair, and detectable at closure time. It does not claim to
  verify them.
- Universal review coverage, option elimination, prediction testing, and
  saturation gates (proposals C, D, E, H from the assessment). They compose with
  this design and are deliberately deferred.
- Running the decomposition itself through `reasoning_options` as a competing-
  axes decision. Deferred; noted in Open questions.
- Any change to `control.lua` phase machinery, HTTP callback binding, or the
  final staging transaction.
- Backfilling trees into workspaces created before the upgrade.

## Selected approach

### Rejected: extend `unknowns` in place

Turning `frame.unknowns` from `string[]` into an object array with parent links
and acceptance tests keeps the artifact count low but breaks the frame schema
shape, every existing frame test, and the `addresses_unknowns` matching rule.
It also leaves closure state living inside a frame artifact that is superseded
on every revision — the state would have to be copied forward on each frame
change, which is precisely the fragile behaviour B exists to remove.

### Rejected: mutate question nodes in place

Closing a leaf by flipping `question.data.state = 'answered'` is the smallest
diff, but it breaks two invariants the codebase relies on. Artifact `status` is
today one of `active | superseded | retracted`, and dozens of call sites treat
`status == 'active'` as "counts". Adding a fourth state, or mutating `data`
after allocation, also defeats the controller's acceptance check, which verifies
that an accepted call allocated exactly the artifacts it reported
([control.lua:1049](../../../lua/codecompanion/_extensions/reasoning/control.lua)).

### Selected: append-only tree with derived state

Two new artifact kinds, both append-only:

- `question` (`Q1…`) — a node. Created by `split`, never mutated.
- `closure` (`C1…`) — the record that closes one leaf. Created by `answer` or
  `drop`, never mutated.

Node state is *derived*, not stored:

```text
children(Q)   = active questions whose data.parent_id == Q.id
closure(Q)    = active closure whose data.question_id == Q.id
open leaf     = active Q with no active children and no valid active closure
closed        = valid closure, or ≥1 child and every child closed
```

Every state change is therefore an allocation or a `State.retire`/`State.supersede`
call, both already revision-tracked. Rollback, the controller's
newly-allocated-artifact check, and the existing audit story all keep working
untouched.

## Architecture

### `constants.lua`

Add `reasoning_question` to `tool_names`, `operation_by_tool`
(`reasoning_question = 'question'`), and the derived inverse map. Tool order in
`tool_names` is stable and append-at-end so group prompts and registries keep a
deterministic sequence.

### `state.lua`

- `prefixes` gains `question = 'Q'` and `closure = 'C'`.
- `new_workspace` gains:
  - `frame_lineage = {}` — ordered list of frame IDs in the current lineage.
  - `root_split = nil` — `{ axis, composition, residual, residual_disposition, child_ids }`.
- New revision-touching setters, each following the existing `touch(workspace)`
  contract: `M.set_root_split(workspace, record)`,
  `M.extend_lineage(workspace, frame_id)`, `M.reset_lineage(workspace, frame_id)`.
- New pure reader `M.in_lineage(workspace, frame_id)` — no revision touch.
- `M.clear`, `prepare_final`, `commit_final`, `rollback_final` are unchanged;
  `rollback_final` already snapshots by revision and last-ID identity, and the
  new fields are not mutated by synthesis.

### `protocol.lua`

- New handler `M.question(chat, args)` with the three actions below.
- `M.frame` gains `action='amend'`.
- `M.evidence` items gain `addresses_questions` (array of `Q` IDs).
- `M.final_gates` gains four gates and consumes lineage instead of a single
  `frame_id` for review currency.
- New pure helpers, all reusable by `guidance.lua`:
  `tree_children`, `tree_closure`, `open_leaves`, `closure_valid`,
  `tree_depth`, `frontier`.

To avoid a require cycle (`guidance` is required by `protocol`), the tree
helpers live in a new module `tree.lua` required by both. `tree.lua` is pure:
workspace in, tables out, no config reads except bounds passed by the caller.

### `guidance.lua`

`M.next` gains one block, placed after the frame-shape checks and *before* the
existing perspective/unknown checks (which become subsumed — see Interaction
below):

1. Root split missing while required → `reasoning_question` ("Split the frame
   into atomic sub-questions").
2. Otherwise select the target leaf: pre-order traversal from the root split's
   `child_ids`, ties broken by `artifact_order` position. First open leaf wins.
3. If the target leaf has ≥1 active evidence citing it in `addresses_questions`
   → `reasoning_question` ("Close leaf `Qn` with its cited evidence").
4. Otherwise → `reasoning_evidence` ("Gather evidence for leaf `Qn`").
5. If a closure exists whose cited evidence has gone inactive →
   `reasoning_question` ("Re-close leaf `Qn`; its evidence is no longer active").

Reasons name the target leaf ID so `next_action.reason` is actionable. Leaf IDs
are safe strings by construction (`^[A-Z]+%d+$`), so this echoes no model text.

### `schema.lua`

Add the new tool's array paths to `unique_arrays` and `artifact_id_paths`:

```text
reasoning_question.child_questions.acceptance_test      -- text, bounded
reasoning_question.child_questions                      -- unique by text
reasoning_question.parent_id                            -- artifact ID path
reasoning_question.question_id                          -- artifact ID path
reasoning_question.evidence_ids                         -- artifact ID path, unique
reasoning_question.residual_covered_by                  -- artifact ID path
reasoning_evidence.items.addresses_questions            -- artifact ID path, unique
```

`M.resolve` gains a `reasoning_question` branch bounding `child_questions` to
`[2, limits.max_children]`, mirroring the existing `reasoning_evidence` batch
bound.

### `output.lua`

`known_actions` must gain `reasoning_question`. Without it, every payload whose
`next_action.tool` is the new tool fails `next_action_valid` and is rewritten
into an `internal_error` — a silent, total protocol failure. This is the single
highest-risk one-line change in the design and gets its own test.

`public_payload` strips only `_reasoning_final`, so `open_items` passes through
unchanged.

### `init.lua`

- `paths` and `descriptions` gain `reasoning_question`.
- The group system prompt gains three rules (9–11):
  9. Split the problem into atomic sub-questions before gathering evidence; a
     sub-question is atomic when one observation closes it.
  10. Every leaf must be closed by `reasoning_question` with cited active
      evidence, or explicitly dropped with justification, before any final
      synthesis.
  11. New information discovered mid-run uses `reasoning_frame` with
      `action=amend`; amend keeps all existing artifacts.

  Rule 7 changes from "New user information requires revise or replace" to
  "New *user* information requires revise or replace; newly *discovered* work
  uses amend."

### `control.lua`

Two localized changes.

`accepted_shape` becomes action-aware for the new operation only:

```lua
question = {
  by_action = {
    split = { primary = 'question', collection = 'question', collection_required = true },
    answer = { primary = 'closure' },
    drop = { primary = 'closure' },
  },
},
```

`accepted_payload` resolves `shape` through `by_action[marker.action]` when
present, falling back to the flat table. `marker.action` is already captured for
the frame-replace case, so no new marker field is needed.

`clean_workspace` stays exactly as it is: only `frame` with a nil marker
workspace or `action='replace'` allocates a fresh workspace. `amend` reuses the
existing workspace and allocates one new frame artifact, which is the same shape
`revise` already produces — no controller change for B.

## Tool schema: `reasoning_question`

```lua
{
  action = { enum = { 'split', 'answer', 'drop' } },

  -- split
  parent_id = 'Frame ID for the root split, an active Q for a sub-split, or an empty string.',
  axis = { enum = { 'component', 'phase', 'failure_mode', 'actor', 'constraint', 'data_flow' } },
  composition = { enum = { 'all_of', 'one_of', 'ordered' } },
  residual = 'The part of the parent these children do not cover; empty string when fully covered.',
  residual_disposition = { enum = { 'none', 'covered_elsewhere', 'out_of_scope' } },
  residual_covered_by = 'Active Q covering the residual, or an empty string.',
  child_questions = {                       -- 2..max_children
    text = 'The sub-question.',
    kind = { enum = { 'unknown', 'sub_problem', 'option_test', 'assumption_check' } },
    acceptance_test = 'The single observable that closes this question.',
    resolution_kind = { enum = { 'observation', 'computation', 'judgment' } },
  },

  -- answer / drop
  question_id = 'Active leaf Q being closed, or an empty string.',
  answer = 'What the evidence establishes; empty string for drop.',
  justification = 'Why the leaf does not need an answer; empty string for answer.',
  drop_reason = { enum = { 'none', 'out_of_scope', 'answered_elsewhere', 'not_material' } },
  evidence_ids = 'Active E artifacts establishing the answer or the drop.',
  acceptance_test = 'Required when closing a provisional seeded leaf; empty string otherwise.',
  resolution_kind = { enum = { 'observation', 'computation', 'judgment', 'none' } },
  confidence = { enum = { 'low', 'medium', 'high' } },
}
```

All fields required, `additionalProperties = false`, `strict = true`, matching
the existing five tools. Unused-for-this-action fields take the empty string or
the `none` enum member, exactly as `supersedes_id` does today in
[evidence.lua:50](../../../lua/codecompanion/_extensions/reasoning/tools/evidence.lua).

`reasoning_evidence` items gain one field:

```lua
addresses_questions = 'Active leaf Q artifacts this item helps close; empty when it addresses none.'
```

## Split validation

Ordered early returns, in this exact field order, each returning
`failure(code, message, artifact_ids, next_action, diagnostic)` with a safe
diagnostic and `committed = false`:

| # | Rule | Code | Diagnostic constraint |
|---|---|---|---|
| 1 | `parent_id` is the active frame (root) or an active `Q` in this workspace | `invalid_reference` | `artifact_exists` / `artifact_kind` |
| 2 | Root split may occur once per lineage; re-splitting the root requires the repair path | `split_exists` | `workspace_state` |
| 3 | Parent has no active children (no double split) | `split_exists` | `workspace_state` |
| 4 | Parent has no valid active closure | `question_closed` | `workspace_state` |
| 5 | `2 <= #child_questions <= max_children` | `question_invalid` | `min_items` / `max_items` |
| 6 | Tree depth of the deepest child ≤ `max_tree_depth` | `tree_depth_exceeded` | `max_depth` |
| 7 | Active question count + children ≤ `max_questions` | `limit_exceeded` | `max_items` |
| 8 | Child text non-empty, ≤ `max_text_chars`, normalized-distinct from parent text | `question_invalid` | `distinct_from_parent` |
| 9 | Sibling `text` and `acceptance_test` normalized-unique | `question_invalid` | `unique_items` |
| 10 | `acceptance_test` states one observable when `strict_atomicity` (no ` and `, ` also `, `;`, or two `?`) | `question_not_atomic` | `single_observable` |
| 11 | `composition` compatible with parent kind: `one_of` is illegal under an `unknown` parent | `question_invalid` | `composition_kind` |
| 12 | `residual` empty ⇒ `residual_disposition='none'`; non-empty ⇒ disposition is `covered_elsewhere` with an active `residual_covered_by`, or `out_of_scope` naming an exact active-frame constraint | `residual_unresolved` | `residual_disposition` |

Rule 10's lexical guard is a heuristic and is the only rule a user can disable
(`strict_atomicity = false`). Every other rule is structural. `unknown_value` is
reported for enum and constraint mismatches; no rule echoes model text, per the
existing `Validation` contract.

On success: allocate one `question` artifact per child in order, each with
`data = { parent_id, text, kind, acceptance_test, resolution_kind, provisional = false, frame_id = <current lineage head> }`
and `relations.depends_on = { parent_id }`. For a root split, also
`State.set_root_split(workspace, record)`. Return `success_payload` with
`artifact` = last child and `artifacts` = all children, matching the
`options`/`evidence` collection shape the controller already verifies.

## Closure validation

`answer` and `drop` share this order:

| # | Rule | Code |
|---|---|---|
| 1 | `question_id` is an active `Q` in this workspace and in the current lineage | `invalid_reference` |
| 2 | Target is a leaf (no active children) | `question_not_leaf` |
| 3 | Target has no valid active closure | `question_closed` |
| 4 | `evidence_ids` are active `E` artifacts | `invalid_reference` |
| 5 | `answer`: `#evidence_ids >= 1`; `answer` text non-empty; `justification` empty | `closure_invalid` |
| 6 | `drop`: `justification` non-empty; `drop_reason ~= 'none'`; `out_of_scope` names an exact active-frame constraint; other reasons need `#evidence_ids >= 1` | `closure_invalid` |
| 7 | Provisional target ⇒ `acceptance_test` non-empty and `resolution_kind ~= 'none'` | `closure_invalid` |
| 8 | `require_observation_for_closure` and effective `resolution_kind == 'observation'` ⇒ ≥1 cited evidence with `kind == 'observation'` | `closure_unsupported` |
| 9 | `judgment_requires_review` and effective `resolution_kind == 'judgment'` ⇒ ≥1 active, lineage-current review whose `target_ids` include the leaf or one of its cited evidence IDs | `closure_unreviewed` |

On success: allocate one `closure` artifact with
`data = { question_id, action, answer, justification, drop_reason, acceptance_test, resolution_kind, confidence, frame_id }`,
`relations.depends_on = { question_id }`, `relations.supports = evidence_ids`.

`closure_valid(workspace, closure)` re-checks rules 1, 4, 8, and 9 at gate time,
so retracting the evidence under a closed leaf reopens that leaf instead of
leaving a stale closure standing.

## Seeded questions and `addresses_unknowns`

`frame.unknowns` remains a string array and remains the ergonomic entry point.
On `action = start`, `revise`, `replace`, and on `amend` for newly added
unknowns, each unknown string allocates a `question` artifact with
`parent_id = <frame id>`, `kind = 'unknown'`, `acceptance_test = ''`,
`resolution_kind = 'none'`, `provisional = true`. Seeded nodes participate in
the tree like any other node: they may be split, or closed by a closure that
supplies the missing `acceptance_test` and `resolution_kind` (closure rule 7).

`addresses_unknowns` stays in the evidence schema and is mapped internally to
seeded question IDs by exact normalized text match. It no longer closes
anything: coverage is now the tree's job. This keeps every existing evidence
test valid while removing the "one assumption closes an unknown" defect.

## Frame amend (B)

`action = amend` is accepted only when a workspace exists and the phase permits
mutation. It may **add** to `unknowns`, `success_criteria`, `perspectives`, and
`constraints`, and may flip `temporal_required` or `branching_required` from
false to true. It may not change `objective`, `problem_type`, or `depth`, and it
may not remove any element — those are `revise`/`replace`.

Validation returns `amend_invalid` with diagnostic
`{ path = 'unknowns', constraint = 'append_only', expected = 'superset', actual = 'removed_item' }`
for a violation. Adds are computed by normalized set difference against the
current frame.

Effects:

1. Allocate the new frame artifact and `State.supersede` the previous frame, as
   `revise` does — the audit trail stays append-only.
2. `State.extend_lineage(workspace, frame.id)` instead of resetting it.
3. Seed a provisional `question` for every newly added unknown.
4. **Retire nothing.**

Lineage is what makes step 4 safe. Every current-frame comparison switches from
`artifact.data.frame_id == frame.id` to
`State.in_lineage(workspace, artifact.data.frame_id)`, at these call sites:

- `guidance.lua`: `review_sound`, `resolution_review`, the `latest(...)`
  predicates for `synthesis` and `branch`.
- `protocol.lua`: `review_current_and_sound` and the `latest_active` predicates
  inside `final_gates`.

`revise` and `replace` call `State.reset_lineage(workspace, frame.id)`, so their
existing scorched-earth semantics are unchanged and reviews from a discarded
lineage stay stale. `Transition.allowed` gains `amend` to the set permitted in
the `active` phase; `Protocol.call`'s `explicit_reframe` set stays
`{ revise, replace }`, so `amend` remains correctly blocked on a finalized
workspace until an explicit user resume.

## New gates

Inserted into `gate_order` between `unknown_coverage_missing` and
`branches_missing`, so a decomposition failure is reported before branch and
criterion failures:

| Gate | Fails when | Blocker IDs |
|---|---|---|
| `decomposition_missing` | Required root split absent | `{}` |
| `open_questions` | Any active leaf has no valid closure | Open leaf IDs, tree order |
| `closure_unsupported` | A closure exists but `closure_valid` now fails | Closure + leaf IDs |
| `residual_unresolved` | A split's `residual_covered_by` target is inactive | Split parent + target IDs |

The root split is required when `frame.data.depth == 'deep'` or
`#frame.data.unknowns > 0`. A `standard` frame with no unknowns keeps working
exactly as it does today, which keeps the existing test corpus meaningful.

## Interaction with existing gates

`unknown_coverage_missing` stays, but becomes structurally redundant once every
unknown is a seeded question: a workspace with an unclosed unknown now fails
`open_questions` first. It is retained rather than deleted because it also
guards the synthesis-relevance path (`relevant[artifact.id]`), which the tree
does not model. Both gates must agree in the finalized fixture used by
`transition_test.lua`.

`perspective_coverage_missing` is unchanged and orthogonal: perspectives
constrain *who looks*, leaves constrain *what gets looked at*.

## Frontier (G)

`success_payload` and the `synthesis_gate_failed` rejection gain:

```lua
open_items = {
  questions = { { id = 'Q3', parent_id = 'Q1', depth = 2, provisional = false, text = <≤160 chars> }, ... },
  unsupported_closures = { 'C2' },
  open_revisions = { 'E4' },
  unresolved_contradictions = { { 'E2', 'E7' } },
  tree = { total = 9, closed = 6, open = 3, max_depth = 3, root_split = true },
  truncated = { questions = 0 },
}
```

Rules:

- Deterministic order: questions in pre-order, everything else in
  `artifact_order` position.
- Every list is capped at `limits.frontier_items` with the dropped count
  reported in `truncated`; a silent cap would read as "nothing left to do".
- IDs only, except `question.text`, which is model-authored text already
  present in the returned artifact and is trimmed, whitespace-collapsed, and cut
  to 160 characters. No escaping — escaping belongs to `render.lua`.
- Computed by one pure `Tree.frontier(workspace, limits)` call, so success and
  rejection paths cannot disagree.
- Adding fields to the rejection envelope is safe: the controller compares only
  `payload.next_action` against `Protocol.transition` and checks
  `payload.committed == false`
  ([control.lua:1805](../../../lua/codecompanion/_extensions/reasoning/control.lua)).
  A test pins this.

## Rendering

`render.lua` gains one optional section, `## Resolved sub-questions`, listing
each closed leaf as `- Qn — <text>: <answer or justification> [E…]`, in
pre-order, escaped by the existing `scalar`. It is omitted when the workspace
has no root split, so the current rendered output for tree-less workspaces is
byte-identical. Dropped leaves render under a `## Dropped sub-questions`
subsection with their `drop_reason`; a final answer that silently omits what was
dropped would misrepresent coverage.

## Configuration

```lua
limits = {
  max_artifacts = 320,          -- was 192; two new kinds share the budget
  max_batch_items = 8,
  max_text_chars = 2000,
  max_array_items = 12,
  max_children = 6,             -- new
  max_questions = 64,           -- new
  max_tree_depth = 4,           -- new
  frontier_items = 12,          -- new
},
strict_atomicity = true,               -- new
require_observation_for_closure = true, -- new
judgment_requires_review = true,        -- new
```

`validate` gains: each new limit a positive integer, `max_children >= 2`,
`max_tree_depth >= 1`, `frontier_items >= 1`, and the three booleans typed.
Rejection preserves the previous valid configuration, matching the existing
`max_array_items` boundary behaviour.

## Compatibility

- **Six-tool completeness.** `complete_tool_set` requires every name in
  `Constants.tool_names` to be in use
  ([control.lua:138](../../../lua/codecompanion/_extensions/reasoning/control.lua)).
  After the upgrade, the `reasoning` group registers six tools, so ordinary
  users are unaffected. A user whose own config lists the five tool names
  explicitly now attaches an *incomplete* set: the controller stays dormant and
  the legacy one-shot terminal guard applies. This is the documented
  partial-tool path, not a regression, and it must be called out in the README.
- **Live chats.** Controller state is weak-keyed per chat; a chat attached
  before the upgrade keeps its five-tool state until cleared or closed.
- **Existing workspaces** have no `root_split` and no questions. Every new gate
  is inert for a `standard` frame with no unknowns.

## Testing

New files:

- `tests/codecompanion/_extensions/reasoning/tree_test.lua` — pure helpers:
  children, closure, open leaves, pre-order, depth, `closure_valid` under
  retracted evidence, frontier ordering and truncation.
- `tests/codecompanion/_extensions/reasoning/tools/question_test.lua` — all
  twelve split rules and all nine closure rules, each asserting `committed=false`,
  the exact diagnostic, and an unchanged `revision`/`artifact_order`/`next_sequence`.

Extended:

- `state_test.lua` — Q/C prefixes and sequences, lineage setters, `root_split`
  revision accounting, `rollback_final` unaffected by the new fields.
- `tools/frame_test.lua` — amend adds and retires nothing; amend rejects
  removals and objective/type/depth changes; revise still retires everything;
  amend seeds provisional questions for new unknowns only.
- `guidance_test.lua` — root-split-first, leaf selection order, evidence-then-
  close alternation, reopen after evidence retraction.
- `tools/synthesis_test.lua` — each new gate fires with the right blocker IDs
  and gate order; a full tree passes.
- `schema_test.lua` — question bounds track config; `child_questions` unique.
- `output_test.lua` — `reasoning_question` accepted in `known_actions`; a
  payload carrying `open_items` round-trips; the missing-name case produces the
  `internal_error` this guards against.
- `render_test.lua` — tree-less output unchanged byte-for-byte; resolved and
  dropped sections escaped and ordered.
- `control_test.lua` — `accepted_shape.by_action` for split/answer/drop;
  a split reporting the wrong child set is not accepted.
- `runtime_integration_test.lua` — one end-to-end enforced run: frame start →
  root split → evidence → close leaves → amend adding a discovered unknown
  (asserting zero retirements) → close it → gated final. Plus one run where a
  premature final is rejected with `open_questions` and the frontier names the
  exact open leaves.

`make format` before each commit; full `make test` at task boundaries. Baseline
today is zero failures and zero notes; that is the bar.

## Acceptance criteria

1. A final synthesis is rejected with `open_questions` while any active leaf
   lacks a valid closure, and the rejection's `open_items.questions` names
   exactly those leaves in pre-order.
2. Closing a leaf whose only cited evidence is later retracted reopens that leaf
   and re-blocks the final via `closure_unsupported`.
3. `action=amend` adding one unknown retires zero artifacts, extends the
   lineage, seeds one provisional question, and leaves every prior review and
   evidence item current.
4. `action=revise` still retires every active non-frame artifact and resets the
   lineage.
5. A one-child split, duplicate siblings, an undeclared residual, a
   conjunctive acceptance test under `strict_atomicity`, and an over-deep split
   are each rejected with `committed=false`, a specific diagnostic, and an
   unchanged workspace revision.
6. Every accepted result and every `synthesis_gate_failed` rejection carries a
   deterministic `open_items` block whose truncation counts are exact.
7. A `standard` frame with no unknowns produces byte-identical rendered output
   to the pre-change implementation.
8. `make test` passes with zero failures and zero notes.

## Open questions

1. **Decomposition as a reviewed decision.** Should a `deep` frame require the
   root split to come from `reasoning_options` with `branch_type='decomposition'`
   and explicit elimination of rejected axes? It is the strongest available
   check on split quality and reuses existing machinery, but it adds a
   mandatory branch set before any evidence exists. Proposed: defer, revisit
   after proposals C and D land.
2. **Repairing the root split.** This design allows one root split per lineage;
   repairing it currently requires `revise`. A cheaper `split` targeting the root
   with explicit supersession of the old child set would preserve subtrees whose
   axis did not change. Proposed: defer until the closure-time defect detectors
   from §4 of the assessment are specified.
3. **Cross-leaf contradiction as a decomposition defect.** When closing leaf L
   produces evidence contradicting closed sibling M, the split axis was wrong.
   Today that surfaces as an ordinary contradiction gate. Worth a distinct
   `decomposition_defect` gate that forces a re-split? Proposed: yes, but as
   part of the detector work, not here.
4. **Artifact budget.** A depth-4 tree with 6 children per split can exhaust
   `max_questions` before evidence exists. Is 64 questions / 320 artifacts the
   right pair of defaults, or should `max_questions` scale with `depth`?
