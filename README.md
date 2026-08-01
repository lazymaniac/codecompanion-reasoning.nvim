# CodeCompanion Structured Reasoning

Five deterministic tools for guiding difficult analysis, diagnosis, design, decisions, and planning in [CodeCompanion.nvim](https://github.com/olimorris/codecompanion.nvim).

The extension keeps concise, inspectable reasoning artifacts and enforces structural gates between them. It is intentionally not an autonomous agent framework: it does not expose private chain-of-thought, call secondary models, inspect files, manage sessions, or claim that a well-formed argument is factually true.

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
- CodeCompanion.nvim v19.22.0 or a compatible current extension/tool API
- A tool-capable chat model

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
Frame -> Evidence <-> Options <-> Review -> Synthesis
```

Each call is atomic. An accepted or rejected call returns one deterministic `next_action`; the model should call exactly that one reasoning tool next and satisfy its reason. A successful final synthesis returns `next_action.tool = "none"`, which is a terminal signal rather than a registered tool.

The workspace is scoped to the active chat and bounded in memory. An explicit frame revision reopens an accepted final. A frame replacement deliberately discards the old workspace and starts a new one.

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

Checkpoint mode records valid progress without claiming completion. Final mode is accepted only after every applicable gate passes.

## Structural gates

Standard depth requires:

- an active, structurally valid frame;
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

- evidence from at least two framed perspectives;
- a relevant `full` adversarial review;
- cited, active support and review artifacts for the final result.

These are structural checks. They establish traceability and coverage, not factual correctness.

## Error and revision semantics

Expected failures return a stable error code, affected artifact IDs, and the corrective `next_action`. A rejected final synthesis also reports its unmet gates. Failed batches never partially mutate the workspace.

Artifacts use stable prefixes:

- `F`: frame
- `E`: evidence
- `B`: branch set
- `O`: option
- `R`: review
- `S`: synthesis

Evidence, branch sets, and synthesis checkpoints are replaced append-only: the previous artifact remains with `status = "superseded"`. Frame revision does the same while keeping the workspace; frame replacement resets it. Review may retract artifacts or open a revision requirement.

After an accepted final, automatic submission is stopped at the chat boundary, including CodeCompanion YOLO approval mode. Only an explicit `reasoning_frame` `revise` or `replace` call reopens the workspace.

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

- `auto_attach` adds the `@{reasoning}` group to every chat. The default is `false`.
- `default_depth` controls the group prompt's recommended depth; each frame still states `standard` or `deep` explicitly.
- `max_artifacts` bounds all append-oriented artifacts in one workspace.
- `max_batch_items` bounds evidence records in one call.
- `max_text_chars` bounds a single text field.
- `max_array_items` bounds a general artifact array.

All limits must be positive integers. Unknown or invalid options fail setup atomically.

The extension preserves existing CodeCompanion configuration for other tools, groups, system prompts, and display settings. It registers exactly the five tools above in the `reasoning` group and does not replace CodeCompanion's host system prompt.

## Privacy and scope

State is in memory, bounded, and weakly keyed by the active chat object. Releasing a chat makes its workspace eligible for garbage collection.

The extension performs no:

- session persistence or restoration;
- project-memory access;
- file discovery or filesystem operations;
- commands, pickers, popups, or other UI;
- secondary model calls;
- hidden capture or display of private chain-of-thought.

Use CodeCompanion's built-in tools and groups for file operations, user interaction, memory, general agent behavior, and chat/session features.

## Breaking migration

This rewrite removes `chain_of_thoughts_agent`, `tree_of_thoughts_agent`, `graph_of_thoughts_agent`, `meta_agent`, `add_tools`, `ask_user`, `reflect_on_progress`, `list_files`, `project_knowledge`, and `initialize_project_knowledge`.

It also removes the replacement system prompt, sessions, restoration, titles, commands, pickers, popup UI, project-memory files, and compatibility entry points. Existing configurations should enable the `reasoning` extension and use the `@{reasoning}` group instead.

## Development

```sh
make format
make test
```

On the first run, `make test` clones Plenary, MiniTest, and CodeCompanion v19.22.0 into `deps/`. To test another compatible checkout:

```sh
CODECOMPANION_PATH=/path/to/codecompanion.nvim make test
```

After dependency bootstrap, the deterministic suite runs locally and does not call an external model.
