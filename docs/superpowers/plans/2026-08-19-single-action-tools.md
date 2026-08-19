# Single-Action Reasoning Tools Implementation Plan

**Goal:** One tool per protocol action, with only the fields that action needs,
without changing which reasoning paths the protocol explores or enforces.

**Design:** [2026-08-19-single-action-tools-design.md](../specs/2026-08-19-single-action-tools-design.md).

**Status:** Implemented on 2026-08-19. `make format` clean, `make test` at 385
cases with zero failures and zero notes.

---

## Tasks

- [x] **Constants and families.** Fourteen tool names, one-to-one
      `operation_by_tool` / `tool_by_operation`, `family_by_operation`,
      `family_by_tool`, `tools_by_family`, `reframe_operations`.
- [x] **Canonical arguments.** `canonical_args` in `protocol.lua` expands each
      tool's narrow arguments into the family record; `M.call` dispatches by
      family and rejects an unknown operation. Amend merges against the active
      frame; `options_replace` and `resolve_contradiction` validate their own
      fields with their own paths before the handler runs.
- [x] **Transitions.** `Transition.allowed` compares families;
      `Transition.next` names `reasoning_start` while armed and
      `reasoning_revise` while reframing.
- [x] **Guidance.** Every recommendation names the precise tool, including
      `reasoning_options_replace` for immutable option repair and
      `reasoning_resolve_contradiction` for a blocking contradiction.
- [x] **Tool modules.** Fourteen modules plus `tools/shared.lua` for the frame,
      branch, and synthesis field groups; `frame.lua`, `question.lua`, and
      `synthesis.lua` deleted.
- [x] **Schema resolution.** Path maps rebuilt per tool name; `reasoning_split`
      takes the configured child bound; `reasoning_evidence` keeps the batch
      bound.
- [x] **Lifecycle.** `accepted_shape` keyed by operation, frame-family clean
      workspace detection, `final` as the only staged-final operation,
      `output.lua` deriving its known tools from `Constants`.
- [x] **Registration.** `init.lua` registers the fourteen tools and rewrites the
      group system prompt around them.
- [x] **Tests.** Existing suites migrated to the new operations; new coverage for
      the additive amend, the no-op amend rejection, dropping a seeded leaf, the
      resolution tool, `options_replace` without a target, checkpoint's reduced
      surface, family-level transition acceptance, and a per-tool field contract
      in `schema_test.lua`.
- [x] **Docs.** README tools section, workflow, error semantics, and a migration
      table from the removed multiplexed calls.
