# Deep Perspective Lower Bound

Date: 2026-08-03

## Summary

Deep reasoning frames require multiple points of view, but they do not need a
special four-perspective ceiling. Remove that ceiling while keeping `deep` as
the default depth. Perspective arrays remain subject to the extension's
configured `max_array_items` safety bound, which defaults to 12.

## Motivation

The current validator accepts two to four perspectives in deep mode. A frame
with five perspectives is rejected with the instruction to add perspectives,
which is both unnecessary and directionally wrong. The rest of the protocol
only requires deep evidence and synthesis coverage from at least two distinct
perspectives; it does not require every framed perspective to be covered.

The special ceiling therefore does not protect a downstream protocol
invariant. The configurable general array bound already limits accidental
context growth.

## Behavior

- `deep` remains the default depth.
- Standard frames require at least one perspective.
- Deep frames require at least two perspectives.
- Both depths accept perspectives up to the configured `max_array_items`
  value; there is no separate perspective-specific maximum.
- Perspective names remain normalized and unique.
- Every perspective still requires a non-empty, bounded name and purpose.
- A rejected `start` remains atomic and does not create a workspace.

## Model-Facing Contract

The `reasoning_frame` schema will describe the conditional lower bound:
standard requires at least one perspective and deep requires at least two. A
portable `minItems = 1` constraint will reject an empty array before runtime;
the runtime retains the deep-specific second-perspective check.

Runtime validation will distinguish the two cardinality failures:

- Below the selected depth's lower bound: report the required and received
  counts and instruct the model to add perspectives while retaining the
  current frame action.
- Above `max_array_items`: report the configured and received counts and
  instruct the model to reduce the array. This is a general safety-limit
  failure, not a depth requirement.

No default-depth, branching, evidence, review, or synthesis behavior changes.

## Documentation

The design documentation will replace references to "two to four"
perspectives with "at least two, subject to `max_array_items`." The README's
existing statement that deep frames require at least two perspectives remains
correct.

## Testing

Regression tests will prove that:

1. A deep frame with five distinct perspectives is accepted under default
   configuration.
2. A deep frame with one perspective is rejected with an exact lower-bound
   message and corrective next action.
3. A perspective array above a configured `max_array_items` value is rejected
   with an exact safety-bound message and corrective next action.
4. The model-facing schema advertises the portable lower bound and conditional
   depth rule.
5. The complete deterministic suite still passes.

The change removes the confirmed initial blocker. It does not claim that a
local model can complete the entire deep reasoning workflow; that remains a
separate live evaluation.

## Non-Goals

- Changing `default_depth` from `deep`.
- Removing the configured general array safety bound.
- Redesigning the complete reasoning protocol.
- Claiming model-level success from deterministic tests alone.
- Implementing the planned live-model evaluation harness in this change.
