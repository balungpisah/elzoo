# Telemetry, Config and Control

Every ready Piece declares the applicability of these three concerns. Their
presence in the catalogue does not create a process, expose an endpoint or
require a UI. A pure Operator can declare them not applicable; a runtime Unit
or Assembly can supply them or inherit a precisely named upstream contract.
Gleam and frontend library selection are independent decisions.

**Telemetry** observes execution through declared events, measurements and
traces. **Config** describes the settings governing behavior and their allowed
changes. **Control** describes commands that change lifecycle or operational
state. Config holds values; Control requests actions. Applying Config is an
authorized operation, not arbitrary mutation of a module's internals.

## Applicability in the Piece Ledger

Each ready `piece.json` has an `operations` object with exactly `telemetry`,
`config` and `control`. Each has `status` and a nonempty `contract`:

- `supported`: the current scoped bundle supplies the described behavior;
  `evidence` is a nonempty list of in-bundle `_test.exs` paths also present in
  test grounding. Those tests exercise the described setting/control/event.
- `inherited`: supplied through a named direct provider or Piece dependency;
  `from` identifies it and `contract` narrows what is actually inherited.
- `not_applicable`: explain why this scoped Piece has no such responsibility.
- `planned`: needed or intended, but not supplied by the ready subset.

The validator rejects omissions, unknown statuses, undeclared inheritance and
unsupported/missing test references for `supported`. A reference is structural
evidence linkage, not proof that a test covers every sentence.
It cannot prove the prose: reviewers must check it against implementation and
existing grounding. A ready Piece can have planned operational behavior only
when its current usable Contract explicitly excludes that behavior. No record
may turn a planned drain/recovery guarantee into a supported one.

The ledger shows applicability; the manifest carries its detail. Copied
manifests preserve that detail. Config arguments at construction or per call
can be supported without supporting hot reconfiguration. Say which one.

### Per-call Config versus data

Classify the **scoped recipe/interface**, not every option the upstream library
could accept. Payloads and intrinsic operands (JSON values, bytes to hash,
operator input/state) are data, not Config. An exposed choice controlling how
work is performed (HTTP retry/timeout, timer scheduling/cancellation policy,
registry mode or Unit construction) is Config even when passed per call.
Declare supported only for the exposed, tested choice; an upstream option not
used by this recipe does not make its Config supported. State construction,
per-call or hot-update timing explicitly. The current JSON recipe uses default
encoding/decoding and crypto fixes SHA-256, so both are not_applicable; adding
selectable behavior requires the ready-Contract evolution rule.

## Config contract

Declare types, units, defaults, bounds and cross-setting rules. State which
settings are fixed, restart-only, changeable after draining, or changeable
between operations. Separate desired configuration from effective configuration
when applying it is asynchronous. Declare when a change affects already
admitted work and when it applies only to future work.

A configuration write names the expected revision and is validated against
the latest state at its commit point. Two writers cannot silently overwrite
each other. The implementation must specify its serialization/transaction
mechanism; a read-check-write on non-transactional storage is not enough.

Restoring an older value is another validated change with a new revision.
It does not undo completed Effects or automatically reverse a state migration.
Secrets are references to a separate secret capability, not values exposed
in configuration inspection, audit metadata or tool descriptions.

When a selected law depends on configuration, quantify over the admissible
range or identify the configurations covered by the evidence. A stateful
change may require migration, clamping or draining even when both old and new
values are individually valid. Proofs about fixed settings do not silently
establish the safety of arbitrary runtime changes.

## Control contract

Expose named domain/lifecycle commands with argument/result schemas,
preconditions, authority and a precise application point. Specify operation
identity, duplicate/retry behavior, cancellation and unknown outcomes where
relevant. Distinguish rejected, accepted/pending, applied and failed results.
An acknowledgement of a pending command is not evidence that it took effect.

Pause stops the declared admissions; it need not cancel running work. Drain
stops new work and waits for specified obligations to finish. Cancellation
cannot erase an already dispatched external Effect. Dynamic rewiring,
snapshot restore and upgrades require their own Contracts; they are not
automatically included by exposing a Control interface.

Humans, CLIs and LLM tools use the same action boundary. A trusted host derives
identity, tenant and permissions from authentication; arguments cannot grant
authority. Re-evaluate authority at dispatch, including for a previously
discovered tool. Bind any required approval to the exact action payload,
target and applicable policy version. Inspectability does not grant execution.

No Piece is externally reachable by default. A product chooses exposed
actions through its edge/control interface, scoped per tenant and resource.
Ash resource/action declarations can supply schemas and policy integration;
additional operational metadata should describe missing semantics, not
duplicate another authoritative schema. OpenAPI/MCP descriptions do not
enforce the Contract by themselves.

## Telemetry contract

Declare event names, units, bounded labels, data classification and useful
correlation identifiers. Instrument effectful execution boundaries; pure
Operators remain free of logging/export effects. Redact payloads and secrets
before emission. A failed/dropped optional observation is different from a
failed business action. Specify observer latency and failure behavior.

Observations must not rely exclusively on the business storage path they are
supposed to diagnose. Exporter queues need their own bounded/drop policy.
Elixir `:telemetry` handlers run synchronously: moving export work out of the
handler is an implementation responsibility, not a property of calling the API.

Health is a current readiness/liveness judgment; stale metrics alone are not
a health guarantee. Audit records, control receipts and billable usage have
their own retention, durability and reconciliation requirements. They must not
be reduced to optional telemetry samples.

## Concrete experiment and limits

ELZ-016 extends `spikes/ash_foundation` with an admission experiment. A pure
Elixir policy returns next state/results; a GenServer serializes it and emits
redacted `:telemetry` summaries; Ash generic actions authorize direct/tool
calls. This policy is experimental and test-grounded, not a ready Piece or a
Cure proof. It models permits and does not execute jobs.

- Limit is 1..64. Lowering it preserves existing admissions and prevents new
  admissions until active count is below the effective limit. Desired and
  effective settings coincide after successful synchronous application.
- Config and explicit lifecycle writes check the expected policy revision.
  Automatic completion of a drain also advances it; ordinary admit/finish
  count changes do not. The revision is not a version of every observation.
- Work IDs are nonempty strings of at most 64 bytes, unique only while active.
  Duplicate active admission and unknown/double finish fail. This is not a
  durable deduplication history or exactly-once external execution.
- Drain reaches paused when active work reaches zero; pause/resume cannot
  bypass an unfinished drain. Missing finishes can leave it draining forever.
  No timing guarantee or forced-cancellation action is provided.
- Responses are synchronous applied snapshots or errors. There is no durable
  receipt store; a call timeout after dispatch is an unknown outcome requiring
  inspection/reconciliation. Restart loses permits/configuration and cannot
  establish what happened to external work.
- Trusted actor fixtures are not authentication. Calling internal BEAM modules
  bypasses the public Ash boundary; this is not a hostile-code sandbox.
- Telemetry contains only counts/revision plus bounded action/outcome/mode
  tags. A throwing handler is detached by the upstream library; a slow handler
  can still delay a response. No exporter or audit-log guarantee is supplied.

Useful future Cure laws include range preservation and rejection preserving
state. Any such proof must cover the actual consumed policy, not a disconnected
model. An automatic LLM governor needs separate change budgets, cooldowns,
approval policy, observation freshness and rollout/recovery checks. It is not
implemented by this experiment.
