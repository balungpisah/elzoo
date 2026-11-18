# ELZ-265 — RunEngine v2 activation, outside events, and inspection

- Phase: Level 4
- Dependencies: ELZ-127, ELZ-256, ELZ-259, ELZ-262, ELZ-263, ELZ-264
- Output: extension of the existing assembly/run-engine Piece; no new Piece ID.
- Owned paths: `pieces/assembly/run-engine/**`; this Piece's existing row only in
  `registry/catalogue.json` and `docs/plans/release-plan.json`; generated
  `LEDGER.md`, `docs/plans/views.md`, and `docs/plans/dependencies.mmd`.
  Update `piece.json`, README, catalogue summary as needed, and this existing
  release-plan `note`/`manifest_sha256` per AGENTS. Preserve ready status and all
  existing job/output ownership. No other Piece, root/shared runtime, dependency,
  pin, root test, or CI changes.

Start after publication and all listed dependencies merge. Run focused Piece
tests/source guards and dependency/service preflight before the selected gate.
Follow the normal review, exact-head hosted, queue, and main-push checks. A
selected Piece gate is not full acceptance.

## Changed Contract

Opt into `protocol_version: 2` explicitly. Omitted or explicit version 1 must
preserve historical v1 config bytes, fingerprint bytes, state, recovery, limits,
and behavior exactly. V2 has a distinct state/config and fingerprint containing
the event-source ID/version. Protocol is fixed per native Unit incarnation;
provide a fresh Unit identity for new v2 work. Never convert/recover a v1 Unit as
v2 or allocate a replacement Unit/Run/Attempt to escape existing uncertainty.
Keep v2 empty state exactly
`%{version: 2, control: nil, slots: %{}, requests: %{}}` and preserve v1 literal.

Thread selected version through every decoder, generated input, request/gate
frame, action cache, nested callable, lifecycle, and result reader; do not change
only ingress. Preserve the explicit RunResource-v1 boundary: public
`RunResource.read/2` returns neutral PatternStep input maps with explicit
`"version" => 1`. Validate each input through the unchanged strict v1 PatternStep
decoder before constructing and validating the equivalent v2 native envelope,
preserving all other fields.
Reject missing or unknown versions. Keep RunResource unchanged; do not infer or
relabel another version or globally replace its decoder. Test the resource
round trip.

V2 requires one fixed `event_source` descriptor exactly
`%{id: id, version: version, head: head_fun, read: read_fun}`. ID is nonempty
UTF-8/no-NUL text of 1..200 bytes; version is positive (root uses 1); `head/1`
and `read/2` arities are exact. Scope is exactly the configured native
`%{tenant:, principal:, run_id:}`. `head` returns exactly
`{:ok, %{revision: nonnegative_integer, low_water: nonnegative_integer}}`,
`{:error, :unavailable}`, or `{:error, :gap}`. `read` returns
`{:ok, %{head: head, event: event}}`, `{:error, :not_found}`,
`{:error, :unavailable}`, or `{:error, :gap}`. Event has exactly `id`,
`source_id`, `correlation_id`, `sequence`, `schema_id`, `schema_version`, and
`payload`. Validate canonical bounded payload and corroborated head/sequence.
Event IDs retain PatternStep's nonempty UTF-8 validation and the native ingress
byte bound; the descriptor's 200-byte ID cap is not an extra cap on event IDs.
In particular, a valid canonical Outbox key can be longer than its stream ID.
No callback is invoked during config or for old action kinds.

The fixed source identity/version commits to the same scope and append-only
journal and cannot be reset/replaced under that identity. Store has no
incarnation/hash-chain field; claim none. These are prompt, bounded, read-only
provider Needs; native validates returned shapes but does not authenticate or
bound an arbitrary callback. Keep provider I/O limits separate from native
inspection limits. V2 action schemas validate request payload; the selected
binding's result schema defines the expected event schema, which may differ.
Use existing wait binding admission, facts, proposal, effect class, and result.

The wait dispatches no billable work or Effect. It may reserve the normal binding
estimate, but native actual is zero and the reservation is released on settlement,
expiry, cancellation, or Attempt/Run close. Source-read failure is not an outcome
and leaves the reservation pending until a separate authorized close. For an
outside-event receipt, native supplies actual zero; caller nonzero actual or a
dispatched claim returns `{:error, :invalid_correlation}` before source read or
append. Post-event local/effect work keeps existing cost/loss rules; provider I/O
cost is outside the native work budget.

Derive the bounded ASCII correlation ticket with the existing deterministic
native stable-ID helper and a new domain tag, from fixed tenant/principal,
Run/Attempt, occurrence, and source identity. Never accept a caller ticket. Use
the existing immutable slot deadline. Capture source head once, use its revision
as cursor, and commit activation before advertising any ticket. Activation ID
derives from occurrence, not sampled cursor/time. An event after head sampling
but before successful activation commit is eligible later. Recover the original
activation winner before resampling; only confirmed absence after required
fencing permits another head sample for that same logical activation. Preserve
cursor, ticket, source/version, and deadline across restart; never reset/rebase.

Sample activation time again after the head read. For fresh v2 `outside_event`,
sample authoritative recorded `at_ms` only after source corroboration; a
pre-I/O time cannot authorize settlement after the immutable deadline. Caller-
supplied `at_ms` is forbidden. Preserve v1 clock behavior. Original-ID
reconciliation reuses original time and verified facts, including an input
retained without its result.

Source I/O runs in native runtime, not pure Operator. Before fresh source I/O,
validate fixed scope, current Run/Attempt, occurrence/action, confirmed activation,
and correlation ticket where possible. Retain server-generated verified source
facts with the native input wrapper. Pure step rechecks those facts against the
actual wait, Attempt, event ID, and deadline after I/O; a read racing cancellation
cannot authorize stale settlement. Reject caller-provided verification fields
in neutral input/context; do not use a `verified: true` shortcut. When invoking
BotRunLifecycle v2, supply `verified_event` exactly as
`%{source_id: ..., correlation_id: ..., event_id: ...}` from corroborated facts.
Input and durable-notification paths first reconcile original identity: match
original neutral bytes, Run/Attempt, and occurrence before fresh source lookup;
a notification alone is not evidence the row exists. Resolve an unresolved
original input with retained server facts without a fresh source read; changed
bytes conflict. An already paired result replays without Operator or duplicate
work. Source loss before append is not acceptance or absence.

Map malformed provider results to unavailable, not absence. Fresh-event failures
are `{:error, :invalid_correlation}`, `{:error, :invalid_payload}`,
`{:error, :source_not_found}`, `{:error, :source_unavailable}`, or
`{:error, :source_gap}`. They append/settle nothing and do not fall through
ordinary `invalid_outcome`. Preserve source-unavailable vs confirmed gap. First
profile requires `low_water == 0` and `low_water <= revision`; event sequence is
positive, after cursor and no greater than corroborated head. Low-water
advancement, cursor beyond head, or missing required history is gap, never empty
queue or new baseline. A gap blocks event work without cursor replacement, but
does not forbid authorized cancellation. Reconcile unknown writes by original
identity; physical fencing precedes replacing engine/Unit/caller/task/owner/
connection trees. Never retry uncertain work under another ID. Waiting survives
fenced restart; no new Run, Attempt, input ID, automatic polling/retry, or renewed
deadline. Accepted event settles once and may drive direct finish or existing
AsyncWork/local_restart.

For a successful read, require `event.id` equal the requested event ID,
`source_id` equal the configured source, `correlation_id` equal the activation
ticket, schema equal the selected binding result schema, and identical canonical
bounded payload. Mismatches are correlation/payload errors, not absence.

Add bounded read-only `event_waits(engine, scope, limits)`. Validate scope before
owner/Store/source calls. Do not trust a live/private cache or read private
process state. Invoke no Operator, gate, schema, clock, binding, source callback,
dispatch, ack, repair, or mutation. Recheck owner and
stable heads. Fold complete retained Unit history with public row validation and
DurableUnit reducer. The existing `result/3` returns early for unfinished Runs;
do not delegate inspection to it. Reuse its bounded history fold and stable-head
checks beneath that policy boundary. Verify each activation's paired input/result
and each accepted receipt's first paired outside-event settlement and original
activation; a plausible later state field is insufficient. Reject forged, staged,
unpaired, pruned, corrupt, gapped, version-invalid, or changed-head history.
Require configured read support; an audited v1 Engine returns an empty wait list.

`limits` has exactly the two positive operands `max_records` and `max_bytes`;
reject extra keys. Return only `{:ok, %{run_id: ..., attempt_id: ..., waits: [...]}}`;
each wait has exactly `occurrence`, `action_id`, `source_id`, `correlation_id`,
`cursor`, `deadline_ms`, `status`, `outcome`, `accepted_event`. Status is
`waiting`, `settled`, or `closed`; `control.stop_pending`, terminal native state,
or committed terminal Run closes an unsettled wait with nil outcome/no receipt.
A truly settled wait keeps its real outcome/receipt. `accepted_event` is nil
unless it settled the wait, then exactly
`%{event_id: ..., input_id: ..., sequence: ...}`. Return the configured source's
event ID verbatim; in the root profile it is the original Outbox key. Omit
payload, credentials, cryptographic keys, and raw authority, not that event ID.
There can be at most `64 * request_cap` waits for the current Run: PatternStep
allows 64 actions per request and native request_cap is at most 256. Do not
truncate valid simultaneous waits to request_cap. Stored waiting is not fresh
admission permission; readonly inspection never expires a wait using the clock.
Preserve exact limits
`max_records <= 65_536`, `max_bytes <= 536_870_912`; these bound native audit
only. GET reads no clock. Return reader failures as `{:error, :scope}`,
`{:error, :invalid_limits}`, `{:error, :reader_unconfigured}`,
`{:error, :history}`, `{:error, :unavailable}`, or `{:error, :read_limit}`;
owner/identity mismatch is not an empty list.

Extend `result/3` pairing for outside_event as a completed source, direct finish
and local_work-after-event; preserve first accepted outcome, exact operation/
Run/Attempt/action/schema/scope, gap/budget, reused-Run and evidence-stream
checks. Keep all v1 result semantics, config, reader limits and error cases.

## Needs and grounding

The host supplies truthful fixed callbacks, complete retained history, trusted
scope/time, serialized admission, durable owners and physical fencing. On main
RunEngine is v1-only, with v1 empty state and existing bounded `result/3`;
ELZ-256 supplies the reader pattern, ELZ-259 original key/nonce confirmation,
and ELZ-262 SQL row-validation grounding. These are source prerequisites.

## Contract-to-test acceptance

1. Preserve v1 fixtures/config fingerprints byte-for-byte for omitted/explicit 1;
   test v2 state, source ID/version fingerprint, invalid/duplicate selector,
   missing/malformed v2 source, no version inference from a v2 retained state,
   fixed-Unit version refusal, two Runs on a v2 Unit, and fresh Unit for opt-in.
2. Exercise all v2 old kinds including nested/effect/person/resource/control,
   explicit RunResource-v1 bridge, copied consumer, request/result schema mismatch,
   and schema-map binding. Test stable ticket derivation and unchanged deadline.
3. Use disposable PostgreSQL for activation and event input/result, original-ID
   reconciliation, notification path, source loss, unknown vs confirmed absence,
   reply/commit loss, old/new Run reuse, paused/budget/cancel, and restart with
   the same immutable cursor. Include before/at deadline and the head-sample to
   activation-commit interval; never advertise before confirmed activation.
   Perform a successful public PostgreSQL checkpoint/retain before a later
   unacknowledged source row, then require source-gap refusal without cursor
   reset or invented outcome; mocked low-water faults alone are insufficient.
   Block source read, advance trusted clock to exact deadline, then release it;
   assert no post-event work without a wall-clock timing race.
4. Test source shapes, malformed/unavailable/not-found/gap, invalid correlation/
   payload, changed bytes, low-water/continuity gaps, non-event intervening rows,
   accepted replay after source loss, no fresh lookup for unresolved original
   input, and stale-read racing cancel. No source call on old action, config, or
   replay. Check reservation actual-zero/release on settlement, expiry, cancel,
   and Attempt/Run close after a normal nonzero estimate; source-read failure
   remains pending until authorized close. Test nonzero-actual/dispatched caller
   spoof refusal before read/append, zero-estimate root wait binding, and separate
   post-event work charging. Provider I/O is outside this budget.
5. Test `event_waits` normal/empty/audited-v1, scope-before-read, invalid/extra
   limits, exact/over record and byte budgets, request_cap, stop_pending/terminal
   closure, settled receipt retention, corrupt/pruned/gap/unpaired/changed-head,
   and all forbidden callbacks. Include multiple waits in a single request and
   forged activation/receipt. Bad scope makes zero owner/Store/source calls;
   ordinary inspection reads history but invokes no forbidden callbacks.
6. Test result/3 direct finish and local_work finish, exact identity pairing,
   timeout/reader errors, and preserved v1 result behavior. Temporary controls:
   premature activation, reset cursor on recovery, and fabricated paired evidence;
   named assertions must fail, then restore exact bytes.
7. Run source guards, dependency/service preflight, and focused cases before the
   selected Piece gate. Follow Piece tests and `mix check --piece
   "$(git merge-base origin/main HEAD)"`, then diff check and normal hosted/main
   checks. Record real service/fault evidence and emitted counts honestly. The
   selected gate is not full acceptance.
