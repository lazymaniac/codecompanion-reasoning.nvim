# CodeCompanion Structured Reasoning

Six deterministic tools for guiding difficult analysis, diagnosis, design,
decisions, and planning in
[CodeCompanion.nvim](https://github.com/olimorris/codecompanion.nvim).

Attaching all six tools to a supported HTTP chat synchronously arms a
chat-local, fail-closed protocol. Free-form model output can no longer bypass
the structure: accepted artifacts are the only source of a final answer, and
the extension renders that answer deterministically after the matching host
tool result is recorded.

The model still has room to investigate. CodeCompanion project searches, file
reads, commands, diagnostics, and other external tools remain unrestricted
before the frame and between reasoning artifacts. Their success or failure is
neutral to the protocol's recovery budget.

## When it helps

Use the `@{reasoning}` group when a problem benefits from explicit evidence, competing alternatives, adversarial review, and verification against stated success criteria. Typical examples include:

- diagnosing a failure with several plausible causes;
- comparing architectural or operational designs;
- making a consequential decision under uncertainty;
- planning a change whose risks unfold over time;
- auditing an argument for unsupported claims or hidden assumptions.

Routine questions and mechanical edits usually do not justify the extra tool calls.

### Model fit

The protocol is designed to be useful for both Qwen3.6-27B-class models and stronger models:

- Constrained schemas, one-step transitions, stable error codes, and bounded artifacts help a capable 27B model stay oriented through a long problem.
- Larger models still gain an auditable evidence trail, explicit alternatives, and gates that resist premature synthesis.
- No protocol can manufacture missing knowledge or judgment. Source quality, genuine independence of perspectives, and external verification remain the model's or user's responsibility.

The practical tradeoff is latency and tokens. Use `standard` depth for moderately difficult work and `deep` when the cost of a shallow answer is higher than the cost of additional calls.

## Requirements

- Neovim supported by CodeCompanion
- CodeCompanion.nvim v19.22.0; the lifecycle integration is pinned to this host
  contract
- A tool-capable HTTP adapter
- A tool-capable chat model

ACP is explicitly unsupported for fail-closed enforcement because
CodeCompanion v19.22.0 does not transmit registered client-tool schemas through
that transport. Attaching on ACP reports the limitation without claiming that
the chat is protected. Switching an armed chat from HTTP to ACP blocks
submission until it returns to a supported HTTP adapter.

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

Add `@{reasoning}` to a chat when needed. To attach it to every chat, set `auto_attach = true`.

## Workflow

```text
Frame -> Question(split) -> Evidence <-> Question(close) -> Options <-> Review -> Synthesis
```

Once all six reasoning tools are attached to an HTTP chat:

1. External project tools may run before framing and between artifacts without
   a count or retry limit from this extension.
2. The first reasoning call must be `reasoning_frame` with `action = "start"`.
   A deep frame, or any frame that declares unknowns, must then be decomposed
   with `reasoning_question` before evidence is gathered. Every leaf must be
   closed by cited active evidence, or explicitly dropped, before a final
   synthesis is accepted.
3. Every later reasoning call must be the sole call in its completion and must
   match the authoritative transition returned by the protocol. External-only
   completions remain allowed.
4. Model prose and private reasoning blocks are suppressed. A completion with
   no tool call, a mixed reasoning batch, or an out-of-order reasoning call is
   a protocol violation rather than an alternate answer path.
5. A final synthesis is staged, recorded by CodeCompanion as a tool result,
   committed atomically, and rendered once. It starts no post-final model
   request.

Each reasoning call is atomic. Accepted and rejected results carry one
deterministic `next_action`; rejected batches do not partially mutate the
workspace. The workspace is scoped to the active chat and bounded in memory.

Attaching fewer than all six tools is outside the fail-closed guarantee. That
partial/individual-tool path retains the legacy one-shot terminal behavior for
compatibility. A configuration that lists the pre-tree five tool names by hand
now attaches an incomplete set: the controller stays dormant and the legacy
guard applies, so add `reasoning_question` to keep enforcement. The legacy submit wrapper is never installed on a controlled
complete-tool chat, so the two lifecycle mechanisms cannot stack.

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
    {
      "name": "correctness",
      "purpose": "Find recovery failures"
    },
    {
      "name": "operations",
      "purpose": "Find lifecycle failures"
    }
  ],
  "temporal_required": false,
  "branching_required": true,
  "branching_rationale": "Several storage strategies are viable"
}
```

`problem_type` accepts `analysis`, `decision`, `diagnosis`, `design`, or `planning`. Decision, diagnosis, design, and planning frames require branching. Deep frames require at least two perspectives.

`action` also accepts `amend`, which adds unknowns, success criteria,
perspectives, and constraints to the active frame without retiring any existing
artifact. Amend may not change the objective, problem type, or depth, and may
not remove anything; those remain `revise` and `replace`, which still retire
downstream work. Each newly framed unknown is seeded as a provisional
sub-question. Reviews, branches, and checkpoints recorded under an earlier frame
in the same amend lineage stay current.

### `reasoning_question`

Decomposes the problem into atomic sub-questions and closes each leaf.

```json
{
  "action": "split",
  "parent_id": "F1",
  "axis": "component",
  "composition": "all_of",
  "residual": "",
  "residual_disposition": "none",
  "residual_covered_by": "",
  "child_questions": [
    {
      "text": "Does replay restore committed writes?",
      "kind": "sub_problem",
      "acceptance_test": "Observe a replayed commit after restart",
      "resolution_kind": "observation"
    },
    {
      "text": "Does compaction bound retained entries?",
      "kind": "sub_problem",
      "acceptance_test": "Observe retained entries after compaction",
      "resolution_kind": "observation"
    }
  ],
  "question_id": "",
  "answer": "",
  "justification": "",
  "drop_reason": "none",
  "evidence_ids": [],
  "acceptance_test": "",
  "resolution_kind": "none",
  "confidence": "none"
}
```

A split needs two or more children with distinct text and distinct acceptance
tests, a declared axis, a composition compatible with the parent, and a
residual that is either empty or dispositioned as `covered_elsewhere` or
`out_of_scope` against an active frame constraint. Under `strict_atomicity`, an
acceptance test naming more than one observable is rejected as non-atomic.
Depth, child count, and total sub-questions are bounded by configuration.

`action = "answer"` closes one leaf with cited active evidence;
`action = "drop"` closes it with a classified justification. A closure only
counts while its cited evidence stays active, so retracting that evidence
reopens the leaf and blocks the final again. Sub-question state is derived, not
stored: a leaf is open when it has no active children and no valid closure.

### `reasoning_evidence`

Records observations, claims, and explicitly labelled assumptions. Every item needs an explicit source or basis, confidence, a falsifier, and an exact perspective from the active frame. Observations require a concrete source.

```json
{
  "items": [
    {
      "kind": "observation",
      "statement": "Replay restores committed entries and safely truncates every tested torn suffix",
      "source": "tests/recovery.lua:10",
      "confidence": "high",
      "falsifier": "A generated partial suffix loses a committed entry or prevents recovery",
      "perspective": "correctness",
      "addresses_unknowns": [],
      "supports": [],
      "contradicts": [],
      "qualifies": [],
      "supersedes_id": ""
    },
    {
      "kind": "observation",
      "statement": "At the measured write rate, compaction keeps retained journal entries bounded",
      "source": "bench/cache_write_rate.lua:24",
      "confidence": "medium",
      "falsifier": "Retained entries grow after compaction at the measured rate",
      "perspective": "operations",
      "addresses_unknowns": ["Expected write rate"],
      "supports": [],
      "contradicts": [],
      "qualifies": [],
      "supersedes_id": ""
    },
    {
      "kind": "observation",
      "statement": "Atomic snapshot tests restore the latest complete snapshot after restart",
      "source": "tests/snapshot_recovery.lua:18",
      "confidence": "high",
      "falsifier": "Restart loads an incomplete or older committed snapshot",
      "perspective": "correctness",
      "addresses_unknowns": [],
      "supports": [],
      "contradicts": [],
      "qualifies": [],
      "supersedes_id": ""
    }
  ]
}
```

Assumption sources must begin with `assumption:` so provisional inputs cannot be mistaken for observations. Relations reference active artifact IDs. Replacing evidence uses `supersedes_id` and preserves provenance.

### `reasoning_options`

Creates two to six genuinely competing solutions, hypotheses, or scenarios as one coherent branch set. Every option must cite active evidence and state at least one observable prediction.

```json
{
  "question": "Which cache architecture satisfies the frame?",
  "branch_type": "solution",
  "criteria": ["Durability", "Bounded memory"],
  "supersedes_branch_id": "",
  "options": [
    {
      "label": "journal",
      "summary": "Append mutations to a checksummed journal with truncation recovery",
      "evidence_ids": ["E1", "E2"],
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
      "evidence_ids": ["E3"],
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

Replacing alternatives uses `supersedes_branch_id` and replaces the complete branch set; options are not edited individually.

### `reasoning_review`

Defends the strongest current case, attacks it with falsifiable challenges, records blind spots, and gives every target exactly one `keep`, `revise`, or `retract` verdict.

```json
{
  "mode": "full",
  "target_ids": ["O1", "E1"],
  "defense": {
    "summary": "Restart evidence supports the journal",
    "evidence_ids": ["E1"]
  },
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
      "target_ids": ["E1"],
      "falsifier": "The target filesystem guarantees the operation"
    }
  ],
  "blind_spots": ["Disk exhaustion"],
  "stress_tests": [],
  "verdicts": [
    {
      "target_id": "O1",
      "status": "keep",
      "revision_instruction": ""
    },
    {
      "target_id": "E1",
      "status": "keep",
      "revision_instruction": ""
    }
  ],
  "contradiction_resolutions": [],
  "structural_tradeoffs": []
}
```

Modes are `falsification`, `assumptions`, `temporal`, `cross_perspective`, and `full`. A `revise` verdict opens a typed correction that must be satisfied by the tool owning the target. A `retract` verdict deactivates the target. Contradictions remain blocking until a supported review explicitly resolves them.

### `reasoning_synthesis`

Records an optional checkpoint or attempts a gated final result.

```json
{
  "mode": "final",
  "conclusion": "Use a checksummed journal with truncation recovery",
  "selected_option_ids": ["O1"],
  "support_ids": ["E1", "E2"],
  "review_ids": ["R1"],
  "criterion_results": [
    {
      "criterion": "Survives restart",
      "status": "passed",
      "evidence_ids": ["E1"],
      "explanation": "Replay tests cover complete and partial records"
    },
    {
      "criterion": "Keeps memory bounded",
      "status": "passed",
      "evidence_ids": ["E2"],
      "explanation": "Compaction tests bound retained entries"
    }
  ],
  "tradeoffs": ["Higher write amplification"],
  "uncertainties": ["Disk-full behavior needs platform testing"],
  "blind_spots": ["Network filesystems were not evaluated"],
  "next_actions": ["Implement behind the cache interface"],
  "confidence": "medium"
}
```

Checkpoint mode records valid progress without claiming completion and is
permitted only when the authoritative `next_action` is
`reasoning_synthesis`. Final mode is accepted only after every applicable gate
passes.

## Frontier

Every accepted result, and every final blocked by the gates, carries
`open_items`: the open leaves in pre-order with their depth and provisional
flag, unsupported closures, open revisions, unresolved contradictions, and a
tree summary. Lists are bounded by `frontier_items`, and anything dropped is
reported in `truncated` rather than silently omitted.

## Structural gates

Standard depth requires:

- an active, structurally valid frame;
- a root decomposition when the frame declares unknowns;
- a valid closure for every open leaf, and no closure whose cited evidence went
  inactive;
- an active sub-question for every residual declared `covered_elsewhere`;
- active evidence from at least one framed perspective;
- cited evidence for every framed unknown;
- competing branches when the frame requires them;
- active evidence and predictions for every relevant option;
- a relevant adversarial review when branches or contradictions exist;
- a stress-tested review for temporal frames;
- no unresolved relevant contradiction or required revision;
- an active selected option when branching is required;
- exactly one supported `passed` or explained `not_applicable` result for every success criterion.

Deep depth additionally requires:

- a root decomposition, whether or not the frame declares unknowns;
- evidence from at least two framed perspectives;
- a relevant `full` adversarial review;
- cited, active support and review artifacts for the final result.

These are structural checks. They establish traceability and coverage, not factual correctness.

## Error and revision semantics

Expected failures return a stable error code, `committed = false`, affected
artifact IDs, a safe field-level diagnostic, and the corrective `next_action`.
A rejected final synthesis also reports its unmet gates. Failed batches never
partially mutate the workspace, and IDs from rejected artifacts never exist.

For example:

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

Each of consecutive violations one and two receives one bounded corrective
request. The third halts automatic execution without starting a fourth
request. To recover, enter nonblank unsent text in the chat buffer and run the
buffer-local `:CodeCompanionReasoningResume` command. A bare `chat.submit()`
remains blocked because host subscribers and approval modes also use it.

Artifacts use stable prefixes:

- `F`: frame
- `E`: evidence
- `B`: branch set
- `O`: option
- `R`: review
- `S`: synthesis

Evidence, branch sets, and synthesis checkpoints are replaced append-only: the
previous artifact remains with `status = "superseded"`. Frame revision does
the same while keeping the workspace; frame replacement resets it. Review may
retract artifacts or open a revision requirement.

After an accepted final, ordinary and automatic submission remain blocked,
including CodeCompanion YOLO approval mode. Running
`:CodeCompanionReasoningResume` with nonblank unsent input enters reframing;
only `reasoning_frame` with `action = "revise"` or `action = "replace"` can
return the chat to active reasoning. External investigation may continue while
reframing, but prose and other reasoning operations remain fail-closed.

## Deterministic final output

Final synthesis is validated and staged without allocating its artifact. Only
after CodeCompanion records the matching host tool result does the extension
commit the artifact and append one assistant message. No second model request
can elaborate or replace it.

The renderer orders the conclusion, selected branch, supporting evidence,
adversarial review, success criteria, optional reflection sections, and
confidence. Its Markdown has this shape:

```markdown
## Conclusion

Use a checksummed journal with truncation recovery

## Selected solution

- **O1 — journal:** Append mutations to a checksummed journal

## Supporting evidence

- **E1:** Replay restores committed entries _(source: tests/recovery\.lua:10; confidence: high)_

## Adversarial review

- **R1**
  - Challenge (counterexample; targets: O1): Torn records can break replay
  - Verdict (O1): keep

## Success criteria

- **Survives restart** — passed: Partial\-record recovery is covered _(evidence: E1)_

## Trade-offs

- Higher write amplification

## Uncertainties

- Disk\-full behavior still needs platform testing

## Blind spots

- Network filesystems were not evaluated

## Next actions

- Implement behind the cache interface

## Confidence

medium
```

The four reflection sections are omitted when empty. Model-supplied
Markdown-significant characters and HTML metacharacters are escaped before
rendering.

## Configuration

```lua
opts = {
  auto_attach = false,
  default_depth = 'deep',
  strict_atomicity = true,
  require_observation_for_closure = true,
  judgment_requires_review = true,
  limits = {
    max_artifacts = 320,
    max_batch_items = 8,
    max_text_chars = 2000,
    max_array_items = 12,
    max_children = 6,
    max_questions = 64,
    max_tree_depth = 4,
    frontier_items = 12,
  },
}
```

- `auto_attach` adds the `@{reasoning}` group to every chat. The default is `false`.
- `default_depth` controls the group prompt's recommended depth; each frame still states `standard` or `deep` explicitly.
- `max_artifacts` bounds all append-oriented artifacts in one workspace.
- `max_batch_items` bounds evidence records in one call.
- `max_text_chars` bounds a single text field.
- `max_array_items` bounds a general artifact array.
- `max_children` bounds one split; `max_questions` bounds all active
  sub-questions; `max_tree_depth` bounds how deep a split may nest.
- `frontier_items` bounds each `open_items` list; dropped entries are counted in
  `truncated`.
- `strict_atomicity` rejects an acceptance test that names more than one
  observable.
- `require_observation_for_closure` requires at least one `observation` item
  behind a leaf resolved by observation.
- `judgment_requires_review` requires an adversarial review before a leaf
  resolved by judgment can close.

All limits must be positive integers. Unknown or invalid options fail setup atomically.

The automatic recovery budget is fixed at three consecutive violations. It is
intentionally not configurable, so the documented fail-closed boundary cannot
be weakened by local options.

The extension preserves existing CodeCompanion configuration for other tools, groups, system prompts, and display settings. It registers exactly the six tools above in the `reasoning` group and does not replace CodeCompanion's host system prompt.

## Privacy and scope

State is in memory, bounded, and weakly keyed by the active chat object. Releasing a chat makes its workspace eligible for garbage collection.

The extension performs no:

- session persistence or restoration;
- project-memory access;
- file discovery or filesystem operations;
- pickers, popups, or other UI beyond its buffer-local resume command;
- secondary model calls;
- hidden capture or display of private chain-of-thought.

`:CodeCompanionReasoningResume` is the extension's sole UI command. Use
CodeCompanion's built-in tools and groups for project search, file reads,
commands, diagnostics, user interaction, memory, general agent behavior, and
chat/session features. The controller does not restrict those external tools.

## Breaking migration

This rewrite removes `chain_of_thoughts_agent`, `tree_of_thoughts_agent`, `graph_of_thoughts_agent`, `meta_agent`, `add_tools`, `ask_user`, `reflect_on_progress`, `list_files`, `project_knowledge`, and `initialize_project_knowledge`.

It also removes the replacement system prompt, sessions, restoration, titles,
legacy commands, pickers, popup UI, project-memory files, and compatibility
entry points. Existing configurations should enable the `reasoning` extension
and use the `@{reasoning}` group instead. The only new command is the
buffer-local fail-closed recovery command described above.

## Development

```sh
make format
make test
```

On the first run, `make test` clones Plenary, MiniTest, and CodeCompanion
v19.22.0 into `deps/`. To investigate compatibility with a local CodeCompanion
checkout while keeping v19.22.0 as the supported target:

```sh
CODECOMPANION_PATH=/path/to/codecompanion.nvim make test
```

After dependency bootstrap, the deterministic suite runs locally and does not call an external model.
