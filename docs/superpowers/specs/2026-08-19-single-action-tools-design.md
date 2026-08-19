# Single-Action Reasoning Tools Design

Date: 2026-08-19
Status: Implemented

## Summary

Split the six multiplexed reasoning tools into fourteen tools, one per protocol
transition, so that every call carries only the fields its own action needs. The
protocol, artifacts, gates, and the fail-closed final path are unchanged. This is
a surface change aimed at the model's working memory, not at what the protocol
enforces.

| Family | Tools |
| --- | --- |
| Frame | `reasoning_start`, `reasoning_amend`, `reasoning_revise`, `reasoning_replace` |
| Question | `reasoning_split`, `reasoning_answer`, `reasoning_drop` |
| Evidence | `reasoning_evidence` |
| Options | `reasoning_options`, `reasoning_options_replace` |
| Review | `reasoning_review`, `reasoning_resolve_contradiction` |
| Synthesis | `reasoning_checkpoint`, `reasoning_final` |

## Problem

Every tool used OpenAI-style `strict` schemas, where each declared property is
also required. Combined with an `action`/`mode` selector, that made the model
send every field of every action on every call:

1. **Placeholder fields.** A split had to send `question_id = ""`,
   `answer = ""`, `justification = ""`, `drop_reason = "none"`,
   `evidence_ids = []`, `acceptance_test = ""`, `resolution_kind = "none"`, and
   `confidence = "none"` — 8 of 16 required fields carried no information.
2. **Conditional descriptions.** Field docs read `Split only: …`,
   `empty for drop`, `none outside a closure`. The model had to reconstruct the
   active subset of the schema before it could fill it in.
3. **Unreachable enum values.** `axis` and `composition` advertised `none`,
   which the protocol rejected in every case that could reach it.
4. **Restatement.** `action=amend` required resending the objective, problem
   type, depth, and every existing constraint, criterion, and perspective
   verbatim, because the handler validated the amendment as a superset.
5. **Mode-dependent gates.** One `reasoning_synthesis` schema covered a
   progress record and a gated publication with different accepted fields.

## Design

### One operation per tool

`Constants` now maps tool ↔ operation one-to-one and groups operations into the
five artifact *families*. Families are what the lifecycle cares about; tool
names are what the model sees.

`Protocol.call(operation, …)` expands the narrow arguments into the canonical
record the family handler already validates (`canonical_args` in `protocol.lua`),
so `M.frame`, `M.question`, `M.options`, `M.review`, and `M.synthesis` keep one
audited shape per artifact. Placeholder values are supplied by the extension
rather than by the model.

### Transitions name a tool, families accept it

`Guidance.next` now returns the precise tool (`reasoning_split`,
`reasoning_answer`, `reasoning_options_replace`, `reasoning_resolve_contradiction`,
`reasoning_final`, …). `Transition.allowed` compares *families*, which preserves
the previous permissiveness exactly: where the old protocol accepted any
`reasoning_question` call, the new one accepts `split`, `answer`, or `drop`; a
checkpoint is still accepted where a final is ready.

### Additive amend

`reasoning_amend` takes `add_constraints`, `add_success_criteria`,
`add_unknowns`, `add_perspectives`, `require_temporal`, `require_branching`, and
an optional `branching_rationale`. The canonicalizer merges them into the active
frame, so the append-only rule holds by construction and a removal cannot be
expressed. A perspective name that already exists is kept as framed. An
amendment that adds nothing is rejected as `amend_invalid` rather than recorded
as a duplicate frame revision.

### Contradiction resolution as its own tool

`reasoning_resolve_contradiction` takes the pair, what they disagree about, the
qualification, its supporting evidence, and a falsifier. It records a
`falsification` review with keep verdicts on both endpoints and one
counterexample challenge, which is exactly what the review handler required
before. `contradiction_resolutions` is gone from `reasoning_review`.

## Deliberate protocol relaxations

Two rules were relaxed because the split made them unreachable or unjustified.
Both are narrow, and neither weakens a final gate.

1. **A drop needs no acceptance test.** `closure()` required a provisional
   (seeded) leaf to state its acceptance test and resolution kind before
   closing. That is meaningful for an answer, which claims an observation
   satisfies the test, and meaningless for a drop, which declares the question
   needs no observation. `Tree.closure_valid` never reads either field for a
   drop. The requirement now applies to `action == 'answer'` only.
2. **A resolution review carries no stress test.** Every review of a frame with
   `temporal_required` had to include a stress test. A resolution-only review
   now does not, because `reasoning_review` no longer accepts contradiction
   records and the rule would otherwise deadlock a temporal frame with a
   contradiction. The `temporal_review_missing` gate is unchanged: a final on a
   temporal frame still needs a cited, stress-tested review, which a resolution
   cannot supply.

## Consequences

- The tool list is longer. Each schema is smaller, and the group collapses in
  the chat buffer as before.
- Some work costs one more call: replacing a branch set and resolving a
  contradiction are now separate tools rather than fields on an existing call.
- Configurations that named the six tools by hand must be updated; attaching the
  `reasoning` group needs no change.
- `control.lua` learns the new operation names (`accepted_shape` keyed per
  operation, `final` instead of `synthesis` for the staged final) and reuses
  `Protocol.canonical_args` when it revalidates a recorded synthesis payload.
