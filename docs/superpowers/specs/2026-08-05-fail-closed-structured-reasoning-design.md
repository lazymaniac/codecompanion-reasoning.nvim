# Fail-Closed Structured Reasoning Design

Date: 2026-08-05
Status: Approved for implementation

## Summary

Attaching the complete reasoning tool set makes the chat's final-answer path a
fail-closed protocol commitment. The model may search the project, read files,
run diagnostics, and call other external tools before framing and between
reasoning artifacts. Its first reasoning operation must still create a frame,
and it cannot finish with ordinary prose: it must advance through accepted
structured artifacts to an accepted final synthesis. Premature prose is
suppressed, out-of-order reasoning calls are rejected before mutation, and
three consecutive protocol violations pause automatic execution for user
intervention.

The accepted synthesis becomes the sole source of the user-facing answer. A
deterministic renderer projects its conclusion and cited active artifacts into
Markdown. There is no final free-form model turn.

## Problem

The current extension validates individual artifacts and final-synthesis
gates, but `next_action` is advisory. It is neither stored nor checked before
the next reasoning operation. CodeCompanion also accepts ordinary assistant
text without consulting the reasoning workspace.

A representative failure followed this sequence:

1. The model recorded frame `F1`.
2. An invalid evidence batch was rejected atomically.
3. A second evidence call referenced an ID that the rejected batch had never
   created.
4. The model attempted malformed synthesis instead of retrying evidence.
5. It explicitly abandoned the protocol and returned unstructured prose.

The validators correctly prevented invalid artifacts from being committed,
but nothing prevented the final prose bypass. The prose then included claims
that a completed review would have disproved, including the assertion that
the terminal guard lacked a cleanup call.

## Goals

1. Force completion of the structured protocol once the complete reasoning
   tool set is attached to a chat.
2. Prevent ordinary assistant prose from bypassing incomplete reasoning gates.
3. Keep private or free-form intermediate reasoning out of the visible answer.
4. Make the accepted final synthesis the only source of final user-visible
   claims.
5. Reject out-of-order reasoning tools before they can mutate workspace state.
6. Make validation failures specific enough for a capable local model to
   recover.
7. Bound automatic recovery at three consecutive protocol violations.
8. Preserve unrestricted external evidence gathering before the frame and
   between reasoning artifacts, plus manual user control.
9. Remain local, deterministic, chat-scoped, and HTTP-adapter-independent
   within the supported CodeCompanion v19.22.0 contract.

## Non-goals

- Capturing, storing, or displaying private chain-of-thought.
- Judging whether evidence is factually true or semantically sufficient.
- Forcing adapter-specific `tool_choice` parameters.
- Preventing the user from explicitly resuming, reframing, replacing, or
  closing a chat.
- Counting ordinary external-tool failures as protocol violations.
- Implementing the separate live-model control/treatment evaluation harness.
- Enforcing the protocol through ACP adapters. CodeCompanion v19.22.0 does not
  send registered client-tool schemas through ACP, so that requires a separate
  transport design or an upstream host change.
- Supporting CodeCompanion versions outside the existing v19.22.0 target.

## Selected approach

Use a per-chat lifecycle controller plus deterministic final rendering.

### Rejected: prompt and schema changes only

Prompt and schema improvements reduce malformed calls but cannot stop a model
from returning ordinary prose. This approach cannot satisfy the force
requirement.

### Rejected: adapter-level forced tool choice

Dynamic `tool_choice` could require a tool call, but it is adapter-specific and
would interfere with file reads, searches, and other evidence-gathering tools.
It also would not by itself provide deterministic final rendering.

### Selected: host lifecycle control

CodeCompanion's chat object is the common boundary for supported HTTP
adapters. A controller installed on the individual chat as soon as the
complete reasoning tool set is attached can filter intermediate output before
the first model response, bound auto-submission, and preserve external tool
access without mutating global configuration. On an ACP chat, attachment
produces one explicit unsupported-adapter notice and does not claim that the
protocol is enforced.

## Architecture

### `control.lua`

Add a focused controller module with weak-key state per chat. It owns protocol
lifecycle enforcement and preserves the original chat methods it wraps.

Controller state contains:

```text
phase: dormant | armed | active | reframing | finalizing | halted | finalized
resume_phase: phase to restore after an explicit halt resume
unsupported_adapter: whether HTTP enforcement is temporarily unavailable
consecutive_violations: 0..3
fallback_lease: generation-bound obligation for at most one corrective request
submitting: synchronous submit/request-construction re-entrancy lease
construction_lease: exact epoch/generation/payload identity owed one HTTP construction
request_generation: monotonically increasing submitted-request number
completion_classified: whether the current generation has been settled
observed_call_ids: reasoning calls keyed by request generation and call ID
active_request_token: exact epoch/generation identity captured by HTTP callbacks
pending_stop_token: cancelled request awaiting anonymous host stop cleanup
call_tokens: weak formatted-call identity to epoch/generation bindings
staged_final: generation, call ID, workspace revision, candidate, and Markdown
closed: whether all late callbacks must be ignored
original_submit: preserved chat submit method
original_submit_http: preserved HTTP request-construction method
original_done: preserved chat completion method
original_add_buf_message: preserved buffer-output method
original_add_tool_output: preserved tool-result method
original_clear: preserved pre-event chat clear method
original_close: preserved pre-cancellation chat close method
original_tools_execute: preserved formatted-tool executor
registered callbacks: exact callback identities for cleanup
buffer-local resume command identity
```

`blocked` is an effective transition sentinel, not stored controller state.
`Control.phase` returns it for a complete chat whose controller is not yet
installed and for closed, unsupported, or incomplete sticky controllers. This
prevents nil lifecycle context from silently selecting standalone mutation;
nil remains reserved for controller-absent or open/dormant partial-tool
compatibility.

The extension owns one idempotent `User` autocmd group for the version-pinned
`CodeCompanionChatToolAdded`, `CodeCompanionChatAdapter`, and
`CodeCompanionChatCleared` events. Each callback resolves the chat from the
event buffer and reconciles its lifecycle. On HTTP, the controller installs synchronously
when all five tools are present in `chat.tool_registry.in_use`. Checking the
full set on each tool-added event makes the fifth addition the arming point,
including during default-tool loading before an auto-submitted first request.
It also supports users who attach the five tools individually and ACP chats
that later switch to HTTP without another tool-added event.

If an armed HTTP chat switches to ACP before host state prevents the swap, the
controller remains installed, invalidates retries, blocks submission, and
shows the unsupported-adapter notice. Switching back to HTTP with all five
tools restores the prior phase. An ACP chat is never silently treated as
protected.

`CodeCompanionChatCleared` is an explicit reset exception to sticky arming. It
invalidates retries and staged finals, removes correction guidance, cancels or
invalidates in-flight calls, deletes that chat's reasoning workspace, and moves
the installed controller to `dormant`. Dormant wrappers delegate new ordinary
chat activity unchanged while discarding callbacks from generations invalidated
by the clear. The same event removes any partial-tool legacy terminal guard,
including when no controller was installed. Reattaching all five reasoning
tools moves back to `armed`.

Installation hydrates the controller from the existing workspace, is
idempotent, and supports chat methods inherited through a metatable, following
the preservation rules of the current terminal guard. Arming is sticky for
the chat lifetime. If reasoning tools later become unavailable, submission
fails closed with a concise instruction to reattach them; detachment does not
silently restore an unstructured final-answer path.

It wraps only the chat instance. It does not replace global CodeCompanion
methods or settings.

The `_submit_http` wrapper invokes the preserved host method on a per-request
proxy whose stream, status, and completion callbacks close over an exact
controller epoch/generation token. This is required because v19.22.0 otherwise
drops the client request ID before dynamically calling `self:done`, making an
old callback indistinguishable from a new one after clear and rearm. The proxy
gates adapter response handlers before stale content, reasoning, or compaction
chunks can mutate chat-visible state. Submit construction is non-reentrant and
consumes one exact epoch/generation/payload lease, and
a transport-construction throw invalidates its token and halts without leaving
a live generation. The `done`
wrapper owns request-level completion classification and removes free-form
output before the host writes it to history. The formatted
`chat.tools.execute` wrapper preflights tool batches before any tool side
effect. The `add_tool_output` wrapper delegates to the preserved host method
only after rejecting stale exact call identities, then classifies the recorded
result with access to `tool.function_call`. This ordering prevents invalidated
asynchronous output from mutating history while preserving live host callbacks,
and guarantees that a deterministic final answer is added only after its tool
result exists in history. Instance `clear` and `close` wrappers invalidate state
before the pinned host fires its post-clear event or begins close-time
cancellation.

The controller also installs a buffer-local
`:CodeCompanionReasoningResume` command. It is the sole request origin from
`halted` or `finalized`, avoiding the false assumption that a bare
`chat.submit()` is manual.

### `render.lua`

Add a pure deterministic renderer. It accepts the active workspace and a
validated but uncommitted final synthesis candidate, then returns Markdown. It
performs no I/O, model calls, or state mutation.

### `protocol.lua`

Keep artifact validation and final gates in the protocol engine. Add an
authoritative transition check before dispatching a reasoning handler. Final
synthesis validation invokes the pure renderer on an uncommitted candidate;
successful rendering prepares a revision-bound finalization stage but does not
yet mutate the workspace. A small state transaction API reserves the candidate
ID and commits it only after host-result verification.

Preparing a final snapshots the workspace revision and next synthesis ID
without incrementing either. Committing succeeds only when chat, generation,
call ID, workspace identity, revision, and reserved ID still match; it then
allocates that exact artifact once. Discarding a stage consumes no artifact ID
or workspace revision. All non-final artifact mutations increment the workspace
revision through the existing state mutation boundary.

### `output.lua`

Keep serialization and CodeCompanion output integration in the output layer.
It reports tool results to the already-armed controller. A successful final
payload carries rendered Markdown in an internal-only field; `output.lua`
removes that field before JSON serialization and stages it on the controller.
The post-record
`add_tool_output` wrapper is the single classification point for accepted,
rejected, and host-rejected malformed reasoning calls. For an accepted final,
the wrapper verifies the recorded result, commits the staged candidate, and
emits its Markdown as an assistant message without another model request.

### `init.lua`

Register and maintain the tool-attachment and adapter-reconciliation autocmds
during extension setup. The autocmd group is replaced idempotently on repeated
setup so it cannot install duplicate controllers. The callbacks perform no
artifact mutation beyond installing or hydrating the chat-local controller.

### `terminal.lua`

Retain the internal one-shot terminal wrapper only for backward-compatible
partial-tool chats when the lifecycle controller is absent or dormant. A
complete controlled chat never installs it; attaching the fifth tool first
clears any legacy guard before controller method capture, so two submit
wrappers cannot interact or become order-dependent. The same unwrapping runs
on dormant fifth-tool rearm after clear, restoring the existing controller
submit wrapper.
`Terminal.install` is authorized only by the explicit absent-or-dormant
partial-tool predicate; complete, enforcing, unsupported, incomplete sticky,
and closed boundaries never install it.
Partial-tool use is outside the fail-closed guarantee.

## State machine

### Dormant

- This state exists only after an explicitly cleared, previously controlled
  chat; chats that never attached the complete tool set have no controller.
- New ordinary chat requests delegate unchanged.
- Results from generations invalidated by the clear are discarded.
- No reasoning workspace or retry state exists.

Reattaching all five reasoning tools on HTTP moves to `armed`. Closing moves to
the closed tombstone behavior described below.

### Armed

- All five reasoning tools are attached, but no accepted frame exists.
- `reasoning_frame action=start` is the authoritative first reasoning
  transition.
- Project searches, file reads, diagnostics, commands, and other external tool
  calls may run without limit before the frame.
- External-tool success or failure does not advance the protocol, reset its
  retry budget, or consume a violation.
- Free-form response and reasoning buffer messages are suppressed just as they
  are in the active phase.
- Any successful completion with no tool call—including text-only,
  reasoning-only, metadata-only, or empty output—is an attempt to abandon the
  armed protocol and consumes one violation.

An accepted start moves the controller to `active` and resets the violation
count. The next expected action is recomputed from the mutated workspace rather
than cached from the result.

### Active

- Reasoning operations must match the authoritative expected tool.
- External tools remain available without limit and do not alter protocol
  state or the retry budget.
- Free-form response and reasoning buffer messages are suppressed.
- Accepted reasoning artifacts reset the violation count to zero.
- Rejected reasoning operations increment the violation count.
- A successful zero-call model completion increments the violation count.

An accepted final candidate moves to `finalizing`. Three consecutive violations
move to `halted`.

### Finalizing

- The rendered candidate is staged but is not yet a workspace artifact.
- All submissions and additional tool execution are blocked.
- The stage is bound to request generation, tool-call ID, and workspace
  revision.
- The host tool result must be recorded before the candidate can commit.

After the post-record wrapper verifies the exact call result, it atomically
rechecks the workspace revision, commits the reserved synthesis artifact,
emits the staged Markdown, clears the stage, and enters `finalized`. A missing
or mismatched result is replaced with an internal-error tool response; the
candidate is discarded and the controller halts with `resume_phase=active`.
No accepted final artifact is stranded behind a failed emission.

### Halted

- Automatic submissions are blocked, including approval or YOLO-driven ones.
- The user sees one concise failure status containing the expected tool and
  reason, plus the exact `:CodeCompanionReasoningResume` recovery command.
- The workspace and all accepted artifacts remain intact.
- No model prose is used as fallback.

Bare `chat.submit()` is not treated as manual because CodeCompanion subscribers
and other internal paths use it. The user instead enters a nonblank message and
runs `:CodeCompanionReasoningResume`. The command verifies unsent user text with
the pinned host parser and requires a supported HTTP adapter plus all five
reasoning tools. It transactionally restores `resume_phase`, resets the
violation count, and submits that message through the preserved method. If
`on_submitted` does not confirm a constructed request, the controller rolls
back to `halted`. All other submission attempts are settled without starting a
request. Closing the chat performs cleanup.

### Finalized

- The accepted synthesis is rendered once.
- Automatic submission is blocked immediately; there is no post-final model
  turn.
- Further reasoning calls return `workspace_finalized` until an explicit frame
  revision or replacement.

The user enters a nonblank follow-up and runs
`:CodeCompanionReasoningResume`. The command moves to `reframing` before the
request starts. This preserves output suppression for the whole follow-up
request instead of reopening a prose window; ordinary `chat.submit()` remains
blocked.

### Reframing

- Free-form output remains suppressed.
- External investigation remains unrestricted and budget-neutral.
- The only permitted reasoning call is `reasoning_frame action=revise` or
  `action=replace`.
- A successful zero-call completion or other reasoning operation consumes a
  violation.

An accepted revision or replacement returns the controller to `active`, resets
the violation count, and removes stale correction guidance. The new expected
action is recomputed from the resulting workspace. Three violations halt with
`resume_phase=reframing`.

## Authoritative transitions

Expose one pure `Protocol.transition(workspace, lifecycle_phase)` function.
Both controller preflight and `Protocol.call` query it at use time; the
controller does not maintain a competing expected-tool cache. Before invoking
a reasoning handler, `Protocol.call` recomputes the transition and checks it
again so no intervening callback can mutate out of order.

- When the requested reasoning tool matches, normal validation proceeds.
- When it does not match, return `transition_invalid` before mutation.
- The error has `committed = false` and uses the authoritative tool and reason
  as `next_action`.
- Explicit `reasoning_frame` calls with `action=revise` or `action=replace`
  remain permitted from an active workspace because new user information may
  require reframing. They are the only reasoning operations permitted in the
  `reframing` phase.
- A checkpoint synthesis is permitted only when the authoritative tool is
  `reasoning_synthesis`. This resolves the former ambiguity between optional
  checkpoints and exact transition following.

Only the five reasoning tools pass through this check. File reads, searches,
commands, and other external tools do not. In the armed phase, the first such
checked transition is `reasoning_frame action=start`; external investigation
may occur before it.

Controller preflight adds lifecycle gates around that protocol transition:

- effective `blocked` permits no mutation and is never stored as controller
  state;
- `dormant` delegates all calls without reasoning enforcement;
- `armed` permits only the frame tool, whose handler requires `action=start`;
- `active` permits the pure protocol transition plus explicit reframe;
- `reframing` permits only the frame tool, whose handler requires revise or
  replace;
- `finalizing`, `halted`, and `finalized` permit no tool execution.

`action=replace` without an existing workspace is not an alias for start; it
returns `transition_invalid`. A successful revision preserves the workspace's
audit history but retires every active downstream evidence, branch, option,
review, and synthesis artifact. A replacement begins a new workspace. This
prevents material gathered under an old frame from silently supporting a new
one; evidence can be re-recorded explicitly when it remains applicable.

## Intermediate-output control

While armed, active, reframing, finalizing, or halted, the per-chat output wrapper
suppresses streamed CodeCompanion `LLM_MESSAGE` and `REASONING_MESSAGE` buffer
entries. Tool status and tool result messages remain visible, including
external investigation performed before the first frame.

The completion wrapper applies these rules:

- A response containing tool calls passes those calls to CodeCompanion.
  Accompanying free-form content and reasoning are discarded.
- A successful response containing no tool call is not added to message history
  or the visible buffer, even when it contains only reasoning, metadata, or no
  content. It is a protocol violation.
- A response containing only one or more legitimate external tool calls is not
  a violation. The expected reasoning transition and retry budget remain
  unchanged even when an external tool fails.

`on_submitted` increments `request_generation` and clears that generation's
completion marker. The `done` wrapper classifies a successful completion at
most once, even if a host error path calls `done` again. Transport errors,
stopped requests, and user cancellation never become zero-call violations;
their partial free-form stream remains suppressed and the host error or stop
state is preserved.

## Tool-call preflight

External-only batches pass through unchanged, including batches with several
external tools. A completion containing a reasoning tool must contain exactly
one tool call total. Therefore multiple reasoning calls and mixed
reasoning/external batches are rejected atomically before any tool executes.
The controller records a synthetic result for every rejected call so the host
does not retain orphaned tool calls, reports one `reasoning_batch_invalid`
violation for the completion, and leaves protocol and external state
unchanged. The model may retry external calls and the expected reasoning call
in separate completions.

Because preflight rejects before `Tools:execute`, the controller performs the
minimal host settlement that would otherwise be skipped: set
`chat.tools.chat`, set error status, record one synthetic response per distinct
call ID, and invoke `chat.tools:reset({ auto_submit = false })` exactly once.
That reset reaches `on_ready`, where the controller schedules the one owed
retry. The settlement creates no orchestrator, installs no tool autocmd, and
executes no rejected call.

This rule makes each accepted protocol transition observable and guarantees
that final synthesis is the sole call in its completion. No queued external or
reasoning output can appear after the deterministic final answer.

Formatted-call preflight also rejects malformed calls before dispatch when a
known reasoning name has an argument value of the wrong host-level shape or a
duplicate call ID. Invalid JSON for a known reasoning tool is produced by the
host through `add_tool_output` and is classified there. An anonymous malformed
host envelope cannot be attributed to a reasoning or external tool and is
treated as a host error, not misreported as an external-tool failure or a
reasoning violation. Each request/call ID pair is counted at most once.
Every table-shaped formatted call receives its exact request/call marker before
batch acceptance is decided, so an atomically rejected mixed or duplicate batch
can settle all distinct IDs without executing any call.

After the host records a reasoning result, the controller compares each public
artifact and ordered artifact collection deeply with the authoritative State
objects allocated by that call. Matching IDs, kinds, and counts alone are not
enough; a same-shape `on_tool_output` rewrite is an internal integrity failure,
not accepted progress.

The controller does not claim to inspect or rewrite hidden chain-of-thought.
It prevents unstructured intermediate output from becoming protocol state or
the final user answer.

## Recovery and retry budget

The budget is three consecutive protocol violations. It is deliberately fixed
for this first implementation rather than adding configuration surface.

Counted violations are:

- a reasoning tool rejected by the protocol for model-correctable input or
  transition errors;
- a malformed reasoning tool call rejected by CodeCompanion before the
  protocol handler;
- an out-of-order reasoning tool call;
- a successful zero-call model completion after the controller is armed and before
  accepted final synthesis.

Not counted are:

- an external tool failure;
- an extension `internal_error` or `render_internal` failure;
- free-form text suppressed alongside a legitimate tool call;
- user cancellation or chat closure.

After violations one and two, the controller adds one tagged hidden corrective
system message containing the authoritative next tool, reason, and the
statement that rejected calls commit no artifacts. A later violation replaces
that message rather than accumulating guidance. Accepted reasoning progress,
explicit resume, reframe, halt, finalization, and cleanup remove it.

The controller then creates one fallback lease bound to the current request
generation. It is not general submit permission: normal host continuations
after external or accepted reasoning tools remain allowed in `armed`, `active`,
and `reframing` without a lease. The lease only records that the controller
owes a retry if the host does not provide one.

- If the host submits through its approval, YOLO, success, or error path, the
  first confirmed `on_submitted` for a later generation consumes the lease by
  compare-and-set. A no-op submit cannot spend it.
- If host configuration does not auto-submit, the controller's `on_ready`
  callback observes the still-valid lease and schedules a submission after the
  tool runtime has reset.
- The scheduled path rechecks lease generation, current request, controller
  phase, closed state, and tool runtime before submitting.

This handshake produces at most one retry for a violation under every
combination of `auto_submit_errors` and approval or YOLO state.

A verified user resume always takes precedence over a fallback lease: the
resume command invalidates the scheduled retry and removes the corrective
message before the user's request is constructed.

After violation three, the controller invalidates the lease, records the
current phase as `resume_phase`, stops workflow subscribers, and moves to
`halted`. Its `chat.submit` wrapper rejects automatic submissions. When the
attempt supplies a callback, the wrapper invokes it exactly once so the host
tool runtime resets. Without a callback, it uses the pinned host reset or
readiness path once, leaves a queued `_btw` message intact, and does not leave
the buffer locked. The explicit resume command begins a fresh three-violation
budget against the existing workspace.

Finalization uses the same settlement rules and stops workflow subscribers so
their bare `chat.submit()` calls cannot create a post-final request.

Only an accepted reasoning artifact resets the budget during automatic
execution. External-tool success does not conceal a lack of protocol progress,
and external-tool failure does not punish investigation.

The post-record `add_tool_output` classifier counts a reasoning call ID at most
once. A decoded payload with an accepted artifact is progress; a decoded
payload with an error code is a rejection. Invalid JSON attributed to a known
reasoning call is a counted malformed-call rejection; non-JSON host error after
a valid decoded/preflighted reasoning call indicates resolver failure and is
an uncounted `internal_error`. Outputs for all other tools are ignored by the
protocol budget. `internal_error` and
`render_internal` are internal halt conditions rather than model violations:
they set an appropriate `resume_phase`, spend no violation, and never fabricate
an accepted artifact.

## Validation diagnostics

Preserve stable error codes and existing fields. Add:

```json
{
  "committed": false,
  "diagnostic": {
    "path": "items",
    "constraint": "max_items",
    "expected": 8,
    "actual": 10
  }
}
```

`actual` contains only a safe type, count, enum value, or artifact ID. It never
echoes long model-generated text.

Validation should report the first deterministic failure in schema order.
Diagnostics cover:

- missing or invalid field paths;
- configured array and text bounds;
- duplicate array values;
- expected artifact kind and active status;
- offending reference IDs;
- exact framed perspective or unknown requirements.

Every rejected call states `committed = false`. Artifact IDs mentioned by a
rejection are offenders or blockers, never newly allocated artifacts.

The error's `next_action` is state-aware. A local correction may refine its
reason, but it may not direct the model deeper into the protocol when a
prerequisite transition is still unmet.

## Tool schemas and prompt

Expose constraints that JSON Schema can express:

- `minItems` and the configured `max_batch_items` for evidence batches;
- applicable `maxItems` values;
- `uniqueItems` for arrays requiring uniqueness;
- configured text bounds where supported by the adapter schema contract.

The evidence schema must reflect the configuration active when the tool is
resolved. Tests must cover non-default `max_batch_items` so the schema cannot
silently drift from runtime validation.

Strengthen the group prompt with these rules:

1. Attaching the complete reasoning tool set commits the final answer to the
   protocol.
2. External tools may be used freely before framing and between artifacts;
   their calls and failures do not change the required reasoning transition.
3. The first reasoning operation is `reasoning_frame action=start`.
4. A direct model-written user answer is forbidden while the controller is
   armed; only the deterministic renderer emits a final answer.
5. Rejections are nonterminal retry instructions and commit no artifacts.
6. IDs from rejected calls do not exist and must never be cited.
7. New user information requires explicit frame revision or replacement.
8. Only accepted structured artifacts may support the final answer.

The prompt remains guidance layered on top of runtime enforcement; correctness
must not depend on prompt obedience.

## Deterministic final rendering

The accepted final synthesis candidate is the sole source-of-truth root. Its
permitted citation closure contains the active artifacts named directly by
`selected_option_ids`, `support_ids`, `review_ids`, and criterion
`evidence_ids`, plus the active evidence IDs cited by each selected option.
The active branch containing selected options may be read only to determine
branch type and membership. First occurrence wins when an evidence ID appears
through more than one path. Unrelated workspace artifacts are ignored; a
referenced missing, inactive, or wrong-kind member fails final validation.

Render sections in this order:

1. `Conclusion`
2. A selected-branch heading, when present
3. `Supporting evidence`
4. `Adversarial review`
5. `Success criteria`
6. `Trade-offs`
7. `Uncertainties`
8. `Blind spots`
9. `Next actions`
10. `Confidence`

The selected-branch heading maps solution to `Selected solution(s)`, hypothesis
to `Selected hypothesis/hypotheses`, and scenario to `Selected scenario(s)`,
using singular or plural according to selection count and preserving synthesis
order.

Empty optional sections are omitted. Evidence entries include artifact ID,
statement, source, and confidence. Options include ID, label, and summary.
Reviews include cited challenge, verdict, resolution, and structural-tradeoff
summaries without exposing unrestricted reasoning. Criterion entries include
status, explanation, and cited evidence IDs.

All model-provided scalar values, including the conclusion, are normalized and
escaped as Markdown text. Block headings, lists, fences, link definitions, raw
HTML, and thematic breaks in artifact text cannot create or reorder renderer
sections. Embedded newlines stay inside the owning paragraph or list item.
Artifact IDs remain visible for auditability.

The output layer first records the tool result in model history, then adds the
rendered text as the assistant's final history message. The controller emits
the corresponding buffer message through the preserved original output method,
bypassing its intermediate-output filter exactly once. The submit guard blocks
CodeCompanion's normal post-tool automatic submission.

Before emission, the wrapper verifies that the staged artifact deeply equals
the accepted tool payload and that history contains the matching tool-call result.
A mismatch or missing host record replaces any partial result with an internal
error, discards the uncommitted candidate, emits no model prose, and halts.
Successful commit and emission clear the staged value so duplicate callbacks
cannot render twice.

Rendering is part of final-synthesis validation, before artifact allocation.
The protocol renders the uncommitted candidate under `pcall`; only a successful
nonblank string render permits the revision-bound candidate and its Markdown to
be staged. The
controller enters `finalized` only after the host records that tool result, the
candidate commits atomically, and the preserved output path emits the staged
assistant message. An unexpected rendering failure returns `render_internal`
with `committed=false`, halts automatic execution without consuming the model's
three-violation budget, and never falls back to model prose.

## Cleanup and method preservation

For each wrapped method (`submit`, `_submit_http`, `done`, `add_buf_message`,
`add_tool_output`, `clear`, `close`, and `chat.tools.execute`), the controller
stores its target object, whether a raw field existed, and the resolved
original function. An explicit uninstall on a
live, settled chat restores the raw method when present or removes the wrapper
to reveal an inherited method. This applies to both chat methods and
`chat.tools.execute` and matches the metatable-safe behavior of the current
terminal guard. Installation and live uninstall are idempotent.

Finalization does not uninstall the controller because it must continue
blocking post-final auto-submit and permit an explicit later reframe. A chat
clear keeps dormant wrappers so invalidated late generations can still be
discarded.

Clear-time cleanup sets a clearing gate, consumes any construction lease, and
invalidates request/formatted-call tokens before cancellation; synchronous
cancellation callbacks cannot submit mid-clear. It then delegates the
preserved host clear so its final clean render wins. Close-time cleanup first
marks the controller closed, invalidates every retry
generation and request token, removes its tagged corrective message, and
cancels the active tool
orchestrator when present. It unregisters callbacks but leaves minimal closed
tombstone wrappers on the chat object: request construction, submit,
completion, streaming output, tool execution/output, clear, and close become
no-ops. The original methods remain referenced only in the weak controller
state until the closed chat is garbage-collected. Restoring
them at close would let an already-scheduled host callback mutate a deleted
buffer. This prevents an asynchronous reasoning tool, `ToolsFinished` event,
or subscriber callback from acting after closure.

## Testing

Follow test-driven development. Every production behavior begins with a
failing test that demonstrates the missing enforcement.

### Protocol tests

- Reject synthesis when evidence is authoritative next step.
- Reject options or review when another transition is authoritative.
- Permit the exact expected reasoning tool.
- Permit explicit revise and replace from active or finalized workspaces.
- Reject `replace` as the first transition and require `start`.
- Supersede every downstream artifact on revision while retaining audit
  history; start a clean workspace on replacement.
- Prove transition rejection is atomic and consumes no artifact sequence.
- Return the same pure transition to controller preflight and handler dispatch
  across armed, active, reframing, and terminal phases.
- Prepare and discard final candidates without changing revision or artifact
  sequence; commit a matching stage exactly once.
- Return state-aware recovery after malformed or invalid calls.

### Schema and diagnostic tests

- Expose default and configured evidence batch bounds.
- Identify exact invalid field paths and constraints.
- Report safe actual values and `committed = false`.
- Identify missing, inactive, and wrong-kind artifact references.
- Prove rejected batches create no referenceable IDs.

### Controller unit tests

- Arm synchronously when the fifth reasoning tool is attached, including
  default-tool loading before an auto-submitted first request.
- Remain unarmed when only a subset of reasoning tools is attached.
- Hydrate safely from an existing workspace and install idempotently.
- Reconcile HTTP-to-ACP and ACP-to-HTTP adapter events without a false claim of
  enforcement.
- Clear workspace, retries, staged final, and guidance on `ChatCleared`; remain
  dormant until the complete tool set is reattached.
- Install and clean up raw and inherited chat methods.
- Allow unlimited external tool calls before the first frame and between
  reasoning artifacts without changing the expected transition or budget.
- Ignore external-tool failures for protocol counting.
- Reject mixed or multiple-reasoning batches before any call executes and
  close every rejected host call with a synthetic result.
- Permit multi-call batches containing only external tools.
- Classify invalid JSON and duplicate reasoning call IDs once per request.
- Count a successful zero-call completion once; ignore duplicate `done`,
  transport-error, stopped, and cancelled completions.
- Suppress intermediate LLM and reasoning buffer output.
- Preserve external tool calls and visible tool results.
- Discard prose accompanying tool calls without counting a violation.
- Count zero-call abandonment and reasoning rejections.
- Reset only after accepted reasoning progress.
- Auto-continue after violations one and two.
- Keep only one generation-bound retry and one replaceable tagged correction
  across every host auto-submit configuration.
- Let host external-tool continuations proceed without a fallback lease and
  consume an owed lease only on the next confirmed request generation.
- Halt and block normal and YOLO auto-submit after violation three.
- Reject bare internal `submit()` while halted, validate the explicit resume
  command's unsent input, and stop subscriber auto-submission while halted or
  finalized.
- Settle blocked callbacks and queued `_btw` state without leaving tools or the
  chat buffer locked.
- Let the explicit resume command restore the intact workspace transactionally
  and roll back if no request is constructed.
- Require revise or replace, with continued output suppression, after a
  post-final resume command.
- Block all post-final auto-submit.
- Strip internal rendered Markdown from the tool payload, require a matching
  recorded call ID, commit the staged candidate, and emit each final exactly
  once.
- Roll back a finalizing candidate and rewrite the tool result on record or
  commit mismatch.
- Mark close before cancellation, retain tombstone wrappers, and ignore late
  asynchronous tool or subscriber activity.

### Renderer tests

- Render every populated section in deterministic order.
- Omit empty optional sections.
- Include only artifacts cited by the accepted synthesis.
- Include selected options' transitive active evidence exactly once and ignore
  unrelated active artifacts.
- Reject referenced inactive, missing, or wrong-kind material defensively.
- Map solution, hypothesis, and scenario headings with stable plurality.
- Escape multiline Markdown and HTML so artifact text cannot forge sections.
- Prove a render failure commits neither synthesis nor finalized state.

### Runtime integration tests

- Attach the reasoning group, investigate with searches and file reads before
  framing, and verify the first reasoning call must still be the frame.
- Verify text-only, reasoning-only, and empty successful completions immediately
  after attachment are suppressed and retried even though no frame exists yet.
- Verify an ACP attachment reports unsupported enforcement rather than claiming
  a protected reasoning run.
- Switch adapters before the first tool call and verify enforcement is blocked
  on ACP and restored on HTTP.
- Clear request A, rearm and complete request B, and verify A's late stream,
  status, completion, and reused-ID tool callbacks cannot leak into B or the
  fresh workspace even after B's handle reports success.
- Reproduce frame, rejected evidence, nonexistent evidence reference,
  out-of-order synthesis, and attempted prose abandonment.
- Verify no premature prose reaches history or the visible buffer.
- Verify the third consecutive violation pauses without another request.
- Verify the explicit resume command submits unsent user input against the same
  workspace while ordinary `submit()` remains blocked.
- Verify a post-final resume remains suppressed until revise or replace is
  accepted, while ordinary submit remains blocked.
- Close during an asynchronous reasoning tool and verify no late mutation or
  final rendering.
- Execute a complete deep protocol and verify one deterministic final message
  with no post-final model submission.
- Verify explicit reframe reopens a finalized workspace.

## Documentation changes

Update the README workflow, error contract, terminal behavior, configuration
notes, and examples. Update the original structured-reasoning design's known
limitations so it no longer implies that prompt-level transition guidance is
runtime enforcement.

The separate live-model evaluation plan remains unchanged and may be executed
after deterministic enforcement is complete.

## Acceptance criteria

1. Once all five reasoning tools are attached, no ordinary assistant prose can
   complete the chat before an accepted final synthesis, including before the
   first frame.
2. Only the authoritative reasoning operation can mutate the workspace, apart
   from explicit frame revision or replacement.
3. Every rejection reports no commit and a precise, state-aware recovery.
4. Three consecutive protocol violations pause automatic execution in normal
   and YOLO modes.
5. The explicit user resume command submits unsent input against the same
   workspace with a fresh budget; bare internal submissions remain blocked.
6. Intermediate response and reasoning blocks do not become visible protocol
   output.
7. An accepted final is rendered deterministically from cited active artifacts
   and causes no additional LLM request.
8. Existing external tools continue to work without limit before framing and
   between artifacts; their successes and failures neither advance nor consume
   the reasoning retry budget.
9. A reasoning call is the sole call in its completion; invalid mixed or
   multi-reasoning batches have no tool side effects.
10. A post-final resume remains fail-closed until an explicit revision or
    replacement is accepted; ordinary submit remains blocked.
11. Transport errors, stopped requests, duplicate completion callbacks, and
    late post-close callbacks do not consume violations or mutate reasoning
    state.
12. Clearing a chat removes its reasoning state and requires full reattachment;
    switching to ACP blocks rather than silently weakening enforcement.
13. Final synthesis remains uncommitted until its matching tool result is
    recorded, then commits and renders exactly once.
14. Per-chat wrappers preserve host methods and clean up safely.
15. HTTP-adapter unit and CodeCompanion v19.22.0 integration suites pass with
    no regressions; ACP is reported as unsupported for this enforcement path.
