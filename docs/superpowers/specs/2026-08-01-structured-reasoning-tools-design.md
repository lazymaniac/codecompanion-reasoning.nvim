# Structured Reasoning Tools Rewrite

Date: 2026-08-01

## Summary

Rewrite `codecompanion-reasoning.nvim` as a small CodeCompanion extension containing only deterministic tools for guided, structured reasoning. The extension will target difficult problems and capable local models in the Qwen3.6-27B class or stronger. It will expose five focused tools through one `@reasoning` group:

- `reasoning_frame`
- `reasoning_evidence`
- `reasoning_options`
- `reasoning_review`
- `reasoning_synthesis`

The tools will maintain bounded, chat-scoped reasoning artifacts and enforce structural quality gates. They will not request raw chain-of-thought, call another model, access files, persist data, replace CodeCompanion's main system prompt, or implement user interface behavior.

This is a deliberately breaking rewrite. The existing chain, tree, graph, meta-agent, session, memory, file-discovery, reflection, and UI APIs will be removed without compatibility aliases.

## Motivation

The current extension combines structured-reasoning experiments with unrelated responsibilities: session persistence, session UI, project memory, file discovery, dynamic tool attachment, user prompts, title generation, compaction, and a replacement system prompt. Most of the code is outside the desired reasoning scope.

The current reasoning agents also promise more than they enforce. Chain, tree, and graph tools store similar free-text categories in different shapes, while their evidence ordering, branching, comparison, and validation requirements exist only in prompt text. Their schemas disagree with their command handlers, their process-global state can cross chat boundaries, and their output handlers use CodeCompanion APIs that have since changed.

CodeCompanion v19.22.0 registers chat tools under `config.interactions.chat.tools`, resolves extension tools through path, function callback, or inline definitions, invokes function commands as `(self, args, opts)`, and invokes output handlers as `(self, stdout_or_stderr, meta)`. The rewrite will use those contracts directly rather than preserving the deprecated `strategies.*` integration.

## Goals

1. Guide capable LLMs through difficult analysis, diagnosis, decision, design, and planning problems.
2. Preserve observable reasoning artifacts: objectives, evidence, assumptions, alternatives, challenges, conclusions, uncertainty, and verification.
3. Enforce useful structure without pretending to verify semantic truth.
4. Support iteration, contradiction, revision, retraction, and reframing.
5. Keep tool schemas focused enough for reliable function calling by Qwen3.6-27B-class models.
6. Keep runtime behavior deterministic, local, bounded, and free of hidden inference costs.
7. Integrate through CodeCompanion's current extension, tool-group, command, and output APIs.
8. Provide tests for every structural invariant and an optional evaluation harness for measuring model-level benefit.

## Non-goals

- Supporting CodeCompanion versions older than v19.22.0.
- Supporting the existing public tool names or schemas.
- Optimizing the protocol for sub-8B models.
- Revealing or storing raw private chain-of-thought.
- Determining whether a claim is factually true.
- Automatically reading files, running commands, or attaching other tools.
- Asking the user questions through extension-owned UI.
- Session history, project memory, cross-chat learning, or filesystem persistence.
- Secondary LLM calls for critique, reflection, ranking, or summarization.
- Reproducing full Tree of Thoughts search, which samples and evaluates multiple model continuations.

## Design principles

### Artifacts, not thoughts

Fields use names such as `objective`, `statement`, `source`, `falsifier`, `tradeoffs`, and `conclusion`. The tools never ask for a model's hidden reasoning or an unrestricted thought transcript. Tool output exposes concise decision-relevant summaries only.

### Guidance with honest limits

The runtime can validate presence, references, ordering, coverage, status, and revision history. It cannot judge whether perspectives are genuinely independent, evidence is true, or a critique is insightful. Prompts and errors must state that limitation. Falsifiers, adversarial review, and explicit uncertainty make unsupported confidence visible without claiming formal proof.

### Iteration instead of a waterfall

The normal flow is:

`Frame -> Evidence <-> Options <-> Review -> Synthesis`

Review can demand new evidence, revise options, or trigger reframing. A checkpoint is available at any time. Only final synthesis is gated.

### Bounded context

Every call accepts bounded batches and returns only newly accepted artifacts, compact progress counts, unmet gates, and one recommended next action. The complete workspace is not repeated after every call.

### Explicit activation

The extension registers an `@reasoning` group but does not attach it to every chat by default. This avoids ceremony on easy tasks. Once attached, deep guidance is the default.

## Architecture

The implementation has seven responsibilities:

1. **Extension registration** adds the five tools and the `reasoning` group to `config.interactions.chat.tools`.
2. **Configuration** validates extension options and provides immutable defaults.
3. **State store** owns one append-oriented workspace per chat object in a weak-key table.
4. **Protocol engine** validates artifacts, relationships, transitions, and final-synthesis gates.
5. **Guidance engine** chooses one deterministic next action from the current unmet requirements.
6. **Tool adapters** expose focused schemas and translate accepted results into CodeCompanion tool output.
7. **Terminal boundary** stops host auto-submission after an accepted final, including YOLO approval mode, until an explicit frame revision or replacement reopens the workspace.

No state value retains its chat key. When CodeCompanion releases a chat, the weak-key entry becomes collectable. A replacement frame explicitly discards the active workspace and starts a new workspace ID.

### Proposed module layout

```text
lua/codecompanion/_extensions/reasoning/
  init.lua
  config.lua
  state.lua
  protocol.lua
  guidance.lua
  output.lua
  terminal.lua
  tools/
    frame.lua
    evidence.lua
    options.lua
    review.lua
    synthesis.lua
```

Tests mirror these modules and include an integration suite using the current CodeCompanion runtime.

## Configuration

The extension accepts these options:

```lua
{
  auto_attach = false,
  default_depth = "deep",
  limits = {
    max_artifacts = 192,
    max_batch_items = 8,
    max_text_chars = 2000,
    max_array_items = 12,
  },
}
```

- `auto_attach = true` appends the `reasoning` group to `config.interactions.chat.tools.opts.default_tools` if it is not already present.
- `default_depth` accepts `standard` or `deep`. It sets the default named in the group prompt and schema metadata; strict tool calls still provide `depth` explicitly.
- Limits must be positive integers. Invalid configuration fails extension setup with a clear error rather than silently changing values.

The defaults are chosen for long, difficult tasks while bounding accidental context growth. Users can raise them explicitly.

## State model

Each chat has zero or one active workspace:

```text
Workspace
  id
  frame
  artifacts_by_id
  artifact_order
  counts_by_kind
  next_sequence
```

Artifact IDs are deterministic within a workspace:

- Frames: `F1`, `F2`
- Evidence and assumptions: `E1`, `E2`
- Branch sets: `B1`, `B2`
- Options and hypotheses: `O1`, `O2`
- Reviews: `R1`, `R2`
- Syntheses: `S1`, `S2`

Artifacts have a `status` of `active`, `superseded`, or `retracted`. Revisions are append-oriented: the appropriate frame, evidence, options, or synthesis tool creates the replacement and adds a `supersedes` relation. Review records the required correction but does not create a weakly typed replacement itself. Retraction changes the target status and is recorded in the review that caused it.

Supported relations are:

- `supports`
- `contradicts`
- `qualifies`
- `depends_on`
- `tests`
- `supersedes`

Every referenced ID must exist in the active workspace. An active conclusion cannot use a retracted artifact as support. Contradicted support remains visible but blocks final synthesis until a review resolves or qualifies the contradiction.

## Public tools

All schemas set `additionalProperties = false`. Fields needed for portable strict function calling are required; empty arrays represent an intentional absence. Runtime validation applies conditional rules that JSON Schema cannot express consistently across adapters.

### `reasoning_frame`

Creates or changes the active problem frame.

Inputs:

- `action`: `start`, `revise`, or `replace`.
- `objective`: concise statement of the problem to resolve.
- `problem_type`: `analysis`, `decision`, `diagnosis`, `design`, or `planning`.
- `depth`: `standard` or `deep`; the configured `default_depth` is used only as schema and prompt guidance because strict calls provide this field explicitly.
- `constraints`: known boundaries that proposed conclusions must respect.
- `success_criteria`: observable conditions for a satisfactory result.
- `unknowns`: unresolved questions that matter to the outcome.
- `perspectives`: objects containing a unique `name` and `purpose`; deep mode requires at least two and standard mode at least one, subject only to the configured `max_array_items` safety bound.
- `temporal_required`: whether the problem explicitly requires reasoning across transitions or evolution over time.
- `branching_required`: whether competing options, hypotheses, or scenarios must be developed.
- `branching_rationale`: why branching is or is not appropriate.

Default branching behavior is required for decision, diagnosis, design, and planning problems. An analysis frame may disable it with a non-empty rationale. `start` fails when a workspace already exists, `revise` fails without one, and `replace` creates a fresh workspace after explicit intent. A revision cannot remove or rename a perspective, or remove an unknown, referenced by active evidence; the caller must replace or retract those artifacts first.

The perspectives incorporate Prism's domain discovery and dynamic-lens ideas without generating a separate long prompt. Each perspective names what it is intended to reveal.

### `reasoning_evidence`

Records up to `max_batch_items` observations, claims, or assumptions.

Each item contains:

- `kind`: `observation`, `claim`, or `assumption`.
- `statement`: concise, externally meaningful content.
- `source`: file, test, tool output, user statement, derivation, or explicit basis.
- `confidence`: `low`, `medium`, or `high`.
- `falsifier`: evidence or result that would overturn or materially revise the item.
- `perspective`: a perspective name from the active frame.
- `addresses_unknowns`: exact unknown strings from the active frame that this item helps resolve; an empty array when it addresses none.
- `supports`, `contradicts`, and `qualifies`: arrays of artifact IDs.
- `supersedes_id`: an evidence artifact being revised, or an empty string for a new item.

Observations require a concrete source. Assumptions must be labelled as assumptions and cannot use a source implying direct observation. Duplicate normalized statements are rejected with the existing ID unless the new item explicitly supersedes it. A superseding item may change kind, which permits an assumption to become an observed claim without erasing its history. High confidence does not bypass falsification requirements.

This tool embodies evidence-before-conclusion and Prism's falsifiable-claim pattern.

### `reasoning_options`

Creates a branch set containing competing solutions, hypotheses, or scenarios.

Inputs:

- `question`: the decision or uncertainty the branches address.
- `branch_type`: `solution`, `hypothesis`, or `scenario`.
- `criteria`: one to eight qualitative or measurable evaluation criteria.
- `options`: two to six alternatives.
- `supersedes_branch_id`: a branch set being revised, or an empty string for a new set.

Each option contains:

- `label` and concise `summary`.
- `evidence_ids`.
- `assumptions`.
- `predictions` that distinguish the option from competitors.
- `benefits`, `costs`, and `risks`.
- `reversibility`: `easy`, `moderate`, or `hard`.

The tool creates one branch-set artifact and an artifact for each option. Labels must be unique within the branch set. Referenced evidence must exist and be active. Revising one option creates a complete replacement branch set so criteria and comparisons remain coherent; the old set is marked superseded. Numeric scoring is not part of the API; measurable numeric criteria can be recorded as evidence. Selection happens during synthesis after review, not in the same call that invents alternatives.

Only one branch set may be active. A subsequent call must name the active branch in `supersedes_branch_id`, preventing older active options from silently disappearing from guidance and final gates. Individual options cannot be retracted independently; review either requests a complete branch-set replacement or retracts the branch and all of its option members together.

This tool captures tree-style branching, hypothesis testing, construction of alternatives, and explicit trade-offs without exposing separate chain, tree, and graph APIs.

### `reasoning_review`

Challenges existing artifacts and records corrections.

Inputs:

- `mode`: `falsification`, `assumptions`, `temporal`, `cross_perspective`, or `full`.
- `target_ids`: active artifacts being reviewed.
- `defense`: strongest surviving case, with evidence IDs.
- `challenges`: counterexamples, missing evidence, hidden assumptions, temporal failures, overclaims, or underclaims.
- `blind_spots`: relevant angles the current analysis did not cover.
- `stress_tests`: scenarios, predicted behavior, and observable failure signals.
- `verdicts`: `keep`, `revise`, or `retract` for every target, plus a non-empty `revision_instruction` for `revise`.
- `contradiction_resolutions`: explicit records naming both contradictory artifact IDs, a bounded resolution or qualification, and active evidence IDs supporting that resolution; the array may be empty.
- `structural_tradeoffs`: trade-off claims with evidence IDs and a falsifier; the array may be empty.

`full` mode requires a defense, at least one disconfirming challenge, at least one shared or hidden-assumption challenge, a blind-spot entry, and a verdict for every target. Temporal stress tests are required only for `temporal` mode or when the frame sets `temporal_required`. A contradiction is resolved only by a cited, active `contradiction_resolutions` record for an actual active contradiction whose endpoints are both reviewed and kept; its supporting evidence is revalidated at final synthesis, and targeting both endpoints with unrelated keep verdicts is insufficient. A `revise` verdict creates an unresolved revision requirement. The relevant typed tool must supersede the target before final synthesis can pass.

Structural trade-offs are optional. They are never presented as universal conservation laws unless evidence and a falsifier support that wording. This retains Prism's search for invariants while avoiding forced pseudo-profundity.

The review tool incorporates Prism's defend/attack/shared-assumption roles, temporal simulation, adversarial self-correction, overclaim and underclaim checks, and constraint transparency. It deliberately omits Prism history persistence.

### `reasoning_synthesis`

Creates a checkpoint or attempts final synthesis.

Inputs:

- `mode`: `checkpoint` or `final`.
- `conclusion`: concise current or final result.
- `selected_option_ids`: selected solutions, hypotheses, or scenarios.
- `support_ids`: active supporting evidence and claims.
- `review_ids`: relevant adversarial reviews.
- `criterion_results`: one record per success criterion with `passed`, `failed`, `pending`, or `not_applicable`, supporting IDs, and explanation.
- `tradeoffs`: what the conclusion optimizes and sacrifices.
- `uncertainties`: unresolved uncertainty that could change the result.
- `blind_spots`: relevant areas not analyzed.
- `next_actions`: concrete actions after the synthesis.
- `confidence`: `low`, `medium`, or `high`.

Checkpoint mode records progress regardless of unmet gates and returns the highest-priority next action. Final mode succeeds only when all final gates pass. A conceptual task may mark a criterion `not_applicable` only with a non-empty explanation. A final synthesis cannot contain `failed` or `pending` criteria.

The required trade-offs, blind spots, and uncertainties incorporate Prism's constraint-transparency and cross-operation synthesis patterns.

## Protocol profiles and quality gates

### Standard depth

Standard depth requires:

- An active frame.
- At least one active evidence or assumption artifact.
- A branch set when `branching_required` is true.
- A review when a branch set exists or active evidence is contradicted.
- A stress-tested review when `temporal_required` is true.
- Evidence cited by the conclusion for every unknown named in the active frame.
- No unresolved `revise` verdict affecting the active frame, the selected branch or option, cited support, or criterion evidence.
- Criterion coverage and no failed or pending criterion for final synthesis.

### Deep depth

Deep depth requires all standard gates plus:

- At least two perspectives in the frame, subject to the configured `max_array_items` safety bound.
- Active evidence, claims, or assumptions covering at least two perspectives.
- At least two options or hypotheses when branching is required.
- At least one `full` review targeting the selected option, a major supporting claim, or the most recent checkpoint.
- A falsification attempt recorded in that review.
- Explicit trade-offs, uncertainties, and blind spots, even when any list is intentionally empty.
- Support for every selected option and passed criterion.
- No selected or supporting artifact with `retracted` status.
- No unresolved `revise` verdict anywhere in that final-result relevance closure.
- Resolution through review of every active contradiction affecting selected support.

The engine enforces only these structural facts. It does not claim that list entries are substantively adequate.

## Deterministic guidance

After every accepted call, the guidance engine returns exactly one next action using this priority order:

1. Create a frame when none exists.
2. Correct invalid or uncovered frame requirements.
3. Gather evidence for uncovered perspectives or consequential unknowns.
4. Create branches when required and absent.
5. Replace the complete branch set when an immutable option lacks active evidence citations or testable predictions.
6. Review contradictions or unreviewed high-impact artifacts.
7. Apply revisions or replacements required by the latest review.
8. Complete success-criterion verification.
9. Produce final synthesis when all gates pass.

The response includes the recommended tool name and a short reason. It does not generate artifact content for the model.

## Error model

Expected validation failures return normal tool errors with this logical shape:

```text
code: stable machine-readable code
message: concise explanation
artifact_ids: relevant IDs
next_action.tool: exact corrective tool
next_action.reason: concise corrective requirement
```

Stable error categories include:

- `workspace_missing`
- `workspace_exists`
- `limit_exceeded`
- `invalid_reference`
- `inactive_reference`
- `duplicate_artifact`
- `frame_incomplete`
- `branching_required`
- `evidence_invalid`
- `options_invalid`
- `perspective_unknown`
- `branch_count_insufficient`
- `review_incomplete`
- `synthesis_invalid`
- `synthesis_gate_failed`

Programmer errors are logged through `codecompanion.utils.log` and returned without a Lua traceback in chat. The extension never silently converts an internal failure into a successful result.

## CodeCompanion integration

Extension setup mutates only `config.interactions.chat.tools`:

- Each tool uses `path = "_extensions.reasoning.tools.<module>"`.
- The `reasoning` group lists the five registered tool keys and provides a concise system prompt describing the iterative protocol.
- `auto_attach` appends the group name to `tools.opts.default_tools` without duplicating existing entries.
- The extension does not alter `config.interactions.chat.opts.system_prompt` or disable CodeCompanion's tool prompt.

Tool commands use `(self, args, opts)` and return synchronous `{ status, data }` results. Output handlers use `(self, stdout_or_stderr, meta)` and send bounded text through `meta.tools.chat:add_tool_output`. The user-visible output is a short status line; the LLM receives the accepted artifact details and guidance.

Clarification is delegated to CodeCompanion's built-in `ask_questions` tool when the user's active tool group provides it. The extension neither registers nor dynamically attaches that tool.

## Removal and migration

The rewrite removes:

- `chain_of_thoughts_agent`
- `tree_of_thoughts_agent`
- `graph_of_thoughts_agent`
- `meta_agent`
- `add_tools`
- `ask_user`
- `reflect_on_progress`
- `list_files`
- `project_knowledge`
- `initialize_project_knowledge`
- The replacement main system prompt and tool catalog.
- Session storage, restoration, optimization, title generation, chat hooks, commands, pickers, popup UI, and session UI.
- Top-level session APIs and project-knowledge files.

The README will be replaced with focused installation, configuration, tool, protocol, and migration documentation. It will state that the release is breaking and that CodeCompanion supplies general agent, file, memory, clarification, and session capabilities.

## Testing strategy

### Unit tests

Tests cover:

- Configuration validation and immutability.
- Workspace creation, replacement, isolation, bounds, and weak-key storage behavior.
- Deterministic IDs and append-oriented revisions.
- Branch-set replacement and unresolved revision requirements.
- Every relation and invalid-reference path.
- Frame rules by problem type, depth, temporal requirement, and referenced unknowns.
- Evidence source, falsifier, perspective, unknown coverage, duplication, and batch validation.
- Option counts, unique labels, criteria, evidence references, and reversibility.
- Every review mode, complete verdict coverage, revisions, retractions, and structural trade-off validation.
- Standard and deep synthesis gates.
- Contradiction blocking, explicit supported resolution, citation, and revalidation.
- Deterministic next-action priority.
- Bounded LLM and user output.

### CodeCompanion integration tests

Integration tests use the sibling CodeCompanion v19.22.0 source and its actual modules rather than fake `strategies.*` stubs. They verify:

- Extension loading through `codecompanion.setup`.
- Tool registration under `config.interactions.chat.tools`.
- Group resolution and optional default attachment.
- Schema resolution through `CodeCompanion.Tools.resolve`.
- Commands through the current runner contract.
- Success and error output through the current output-handler contract.
- Post-final submission suppression through the current chat and YOLO approval contracts.
- Two chat objects cannot observe each other's workspaces.

Tests perform no network requests and do not require an LLM.

### Optional model evaluation

An opt-in evaluation harness compares a control CodeCompanion chat with an `@reasoning` chat on fixed scenarios:

- Architectural decision with conflicting constraints.
- Diagnosis with a plausible but misleading first hypothesis.
- Design problem requiring temporal stress testing.
- Claim analysis containing contradictory evidence.

The harness accepts an explicitly configured adapter and model. It never runs during CI. Reports include:

- Scenario outcome correctness.
- Valid tool-call rate and recovery from rejected calls.
- Evidence grounding and unsupported-claim counts.
- Required gate completion.
- Token use, tool-call count, and wall-clock latency.
- Whether adversarial review changed an initially preferred conclusion.

The initial comparison targets Qwen3.6-27B or a similar 20-30B capable model and at least one frontier model. Documentation will describe results as model- and scenario-specific, not proof of universal benefit.

## Acceptance criteria

The rewrite is complete when:

1. Only the five reasoning tools are registered by the extension.
2. No runtime module implements sessions, UI, project memory, file access, dynamic tool loading, or secondary inference.
3. The extension loads against CodeCompanion v19.22.0 through its current APIs.
4. The `reasoning` group is manually attachable and honors `auto_attach` without replacing the main system prompt.
5. Standard and deep protocols enforce the documented gates and return recoverable errors.
6. State is isolated per chat, bounded, and not persisted.
7. Revisions, contradictions, supersession, and retraction are tested.
8. Final synthesis cannot bypass required evidence, branching, review, verification, or terminal submission behavior.
9. The complete deterministic test suite passes after formatting.
10. The README accurately documents the breaking surface and contains no claims that exceed implemented enforcement.
11. The opt-in model evaluation harness can run against an explicitly configured adapter without participating in CI.

## Known limitations

- Structure can improve discipline but cannot make a model understand evidence it lacks the capacity to interpret.
- A model can satisfy fields with shallow content; adversarial review reduces but cannot eliminate this failure.
- Repeated tool calls add latency and tokens, so the group is intended for difficult problems rather than routine requests.
- The tools do not implement multi-sample search, independent critic models, formal proof checking, or durable memory.
- Benefit must be evaluated per model and task. The optional harness measures this instead of assuming it.
- The fail-closed lifecycle, bounded recovery, deterministic rendering, and
  authoritative transition enforcement are provided only for supported HTTP
  chats by the superseding 2026-08-05 design. Prompt sequencing is guidance,
  not the enforcement boundary, and ACP remains unsupported by this controller.
