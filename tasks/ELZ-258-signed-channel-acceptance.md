# ELZ-258 — Bounded signed event-to-answer acceptance

This is a coordinator-owned non-Piece one-PR task under AGENTS section 1.

- Phase: Level 3 integration acceptance
- Release: V1B
- Change class: shared root consumer acceptance; full/affected gate
- Dependencies: ELZ-247, ELZ-249, ELZ-250, ELZ-252, ELZ-256, ELZ-257, ELZ-259
- Output: none (no Piece ID or Piece Contract change)
- Owned paths: `examples/wave4_channel.exs`, `examples/support/wave4_channel.ex`,
  `test/wave4_channel_test.exs`, `test/support/wave4_channel_helper.exs`,
  `docs/research/wave4-channel-acceptance.md`,
  `tasks/ELZ-258-signed-channel-acceptance.md`, its job row in
  `docs/plans/release-plan.json`, and `docs/plans/bot-platform-wave4.md` plus
  normally generated views.
  No dependency, pin, Piece runtime, CI, or shared harness changes.

## Outcome

Implement one bounded consumer-owned host example and executable acceptance:
actual signed loopback HTTP -> WebhookIn -> CheckedCommand/Conversation ->
immutable input-to-Run association -> actual native RunEngine local work ->
authoritative RunEngine.result -> durable assistant message -> scoped HTTP GET.
No fake Run owner, copied private dispatcher, private DU/command-record decoder,
input echo, synthesized answer, generic channel framework, broker, subscription
service or model/provider call. Use pinned existing providers directly.

The fixed profile owns one tenant, actor, ASCII conversation ID, source and
native bot target. One serialized host owns all command writes, approval release,
native creation/start and acknowledgement. At most one committed unfinished input
is admitted at a time. A retained ASK has not appended an input. The host must
physically fence predecessor caller/connection/task/owner trees before replacing
them; absence alone after uncertainty is not non-commit. Store/history retention,
truthful authentication, authority, clocks and provisioning remain explicit Needs.

## Consumer interface and construction

The support module is `Elzoo.Wave4ChannelExample`, with `start_link/1`,
`admit/3` (host, normalized event, trusted scope), `advance/1`, `release/4`
(host, original normalized event, trusted scope, command-purpose evidence), and
`view/2` (host, trusted scope). These are example APIs, not new catalogue exports.
`advance` performs one bounded processing phase and returns; no polling loop,
sleep, automatic replacement ID, automatic new Attempt or background scheduler.

Construction supplies the fixed profile, ready command handles/store and fresh
authority/policy supplier, plus real native owner/Store/DynamicUnits/AsyncWork/
evidence bindings. The actual example and tests must construct those ready APIs;
an injected fake native path is not integration evidence. Input, association and
answer use separate fixed CheckedCommand descriptors. Only input emits the
declared source-work outbox destination; association and answer emit none. Their
prepare functions use public Conversation.prepare. Facts and tenant/actor remain
host-derived; source request fields cannot supply authority, mode or Run identity.

Use actual TriggerBinding.select against the fixed source scope and v1 message
schema at startup. Require one exact target matching the configured native
implementation; reject no-match, ambiguity or incompatible target before intake.
The snapshot/target and native configuration remain immutable across recovery.
Selection is not a package loader. Keep the profile's absolute native deadline,
caps and schema identities fixed across recovery; do not renew a deadline because
a process restarted. The profile is a bounded operating period, not a continuously
renewed service. Refuse new input after that deadline before mutation; continue
resolving already committed inputs. Conversation has no stored timestamp field,
so do not invent one or derive a new deadline from restart time.

An empty RunApprovalRelease owner/Lease and empty infrastructure may be open
before intake. Actual Run create, begin_attempt, Engine/Unit configuration,
Budget allocation and work admission follow the committed association only.
Use RunApprovalRelease, which is the owner variant consumed by RunEngine.

## Input, identity and processing

The HTTP POST directly uses WebhookIn and captures configured source_id in admit.
Human principal authentication is a distinct host Need. Preserve event.input_id
as Conversation message_id, all original identities and expected_revision.
Derive command identity from a domain-separated unambiguous encoding of source
and source event ID, excluding resource, so reuse for another conversation
conflicts. Derive stable association/answer operations and Run/Attempt/Unit/
Budget/start-input identities from tenant, actor, retained operation/input and
selected target. Runtime identities must not collide across tenant/actor scopes.
The native operation ID must be reconstructible from the retained Run ID and
fixed profile, so read-only summaries can check the owner's matching identity
without a private journal or the original source event ID.
Deriving names is not permission to allocate a Run.

Input returns only WebhookIn's recognized admission outcomes. Replay goes through
real CheckedCommand identity matching, including changed bytes/resource/revision;
never ACK merely because an operation ID was found. A new identity while work is
unfinished returns unavailable before mutation. Existing terminal/pending receipts
may replay. Reserve enough Conversation capacity for the association and bounded
answer before accepting a new input, using pure preparation with the profile's
fixed maximum answer shape; never launch work for an unsatisfiable conversation.

Read input notifications with the documented CheckedCommand tenant-stream
derivation and public Outbox.pending. Validate notification scope/destination and
exact fields. Read CheckedCommand.result for that identity, validate its retained
message_id/revision, then read CheckedCommand.resource and Conversation.view to
recover the immutable input. Outbox metadata does not contain original text or
raw source event ID. No private command-record decoding or outbox extension.
The notification's resource revision is not its global Store sequence. Association
uses that original input revision, and answer uses that revision plus one; retries
never substitute the latest revision. Ack commitment targets the item's Store
sequence. Exercise earlier retained refusals so these numbers differ in tests.

Commit associate_run with the fixed derived Run ID. Only a confirmed matching
association permits native allocation. Recover existing Runs/Attempts/Units with
their same identities; a different association/Attempt is not permission to replace
one. Use real RunApprovalRelease commands and RunEngine.input with stable ID.
The native pattern emits bounded local_work, then finish referencing that completed
action. The example answer is a fixed ASCII prefix plus SHA-256 of the retained
input text (71 bytes for `answer:` plus lowercase hex), observably different from
input. This demonstrates routing/execution/persistence, not semantic AI answering.

For a completed Run, consume public RunEngine.result with bounded explicit limits
and correct tenant/principal/Run scope. Match returned identity/schema and the
bounded payload; rely on the reader's documented pairing/evidence validation,
not a second private provenance reader. Then append_answer through CheckedCommand.
Do not recompute an answer in the host. Pending, reader unavailable/limited/pruned/unpaired, wrong
scope and noncompleted terminal results produce no assistant answer. A recorded
noncompleted terminal outcome may finish source processing without a success
answer. Native local-work loss on restart stays loss; it must not be rerun or
reported completed. A stable deadline-derived public wake may close an overdue Run.

Acknowledge the original notification only after confirmed answer receipt for
completion, or confirmed noncompleted terminal processing. Reopening after answer
commit but before ack must use retained state and not allocate/reinvoke work.
Use original idempotency key and nonce for acknowledgement. For an indeterminate
ack, retain its receipt and key, remove the diagnostic cause and add the key as
`extra`, then call public DurableLog.confirm_ack/2. This validates the actual
canonical ack receipt and row. Unknown/absent/pending is not non-commit; superseded
is a fence/conflict to report, not own success. Do not infer acknowledgement from
pending-list absence while an ack receipt remains unresolved in this owner.

## Approval, unknown and reads

Release is a serialized host-only entry point, not a new public HTTP approval
endpoint. It releases input-command approval; this fixed example does not add a
generic approval workflow for every native/internal phase. Configure internal
association/answer and native compute for the declared fixed host policy. An
unsupported pending phase stays explicitly blocked rather than being approved
implicitly. Require the original event to match the retained pending request and
use actual CheckedCommand.release with fresh policy/authority and genuine
command-purpose evidence. A release cannot bypass the unfinished-input guard.
Pending/denied/stale/unknown release does not create a Run.

An unknown command/native/ack write blocks further mutations until its original
identity is positively confirmed or the host physically fences outstanding work
and reopens safely. Read failure/absent receipt is not safe non-commit; no retry
timer, replacement operation, incremented expected revision or new Attempt evades
uncertainty. Source clients retain the original event for retry. Read-only views
never clear/repair a poison state. A caller timeout does not cancel the host call.
Reconciliation is phase-specific: a pending receipt can confirm an initial ASK
commit, but the pending receipt that preceded an unknown release cannot confirm
that release. Likewise an existing Run/Attempt does not prove that an uncertain
start input committed. Lost native owners require fencing/reopen unless the
specific original operation has authoritative positive confirmation.

The host Plug routes `GET /elzoo/v1/conversations/{configured_conversation_id}`
without a query, with fresh trusted principal/read grants. Accept the published
CheckedCommand scope shape, including repeated valid resource grants; require
the configured tenant/actor and conversation grant. Validate scope before
Store/owner reads. `view` uses public
CheckedCommand.resource, Conversation.view and the already-open Run owner only.
It never starts/recovers an Engine, invokes work, calls a mutating status helper,
acknowledges or writes. Return bounded conversation data plus only associated
Run/outcome summaries, not native policy/evidence internals. Missing/unavailable
owners fail closed; a known not-yet-created Run can be shown as not recorded.
GET returns 200 with the bounded view, 403 for a well-formed scope without the
configured identity/grant, and 503 for malformed/unavailable Needs or authorized
read/encoding failure. Wrong routes and methods receive fixed 404/405 responses.
Check each native summary's Run and reconstructed operation identity. GET exposes
only stable IDs and fixed outcome classifications in Run summaries;
no raw error, policy or evidence payload. GET JSON has a fixed 1 MiB response cap
and no truncation. Errors are fixed tags;
redact OTP status/error state so callback errors do not dump input or credentials.

## Evidence

Use a disposable PostgreSQL database for durable command/native evidence and real
loopback HTTP through the already pinned listener. Tests may use Memory for pure
or early-refusal checks, without durability claims. Listener/authentication fixtures
do not establish production TLS, authentication or database crash/failover safety.

Require a trace from signed input through the authoritative native answer and GET,
with exact identities/revisions and separate work/Run/Attempt/Budget/write counts.
Continue through a second distinct input and native Run on the same durable
profile, then replay the first event and GET both answers with no additional work.
Cover replay and changed bytes/resource, scope/MAC/header refusals, no-match/ambiguous
binding, gate/policy denial, genuine ASK/release including stale/revoked evidence,
busy intake, capacity, unavailable reads, unknown writes and original-key recovery.
In particular, association denial or uncertainty must leave zero native
Run/Attempt/Budget/work allocations; a committed input alone is insufficient.
Reopen caller, database connections and native owner bindings at actual cut points:
input commit, association commit, native allocation/start, durable completion,
answer commit and ack. Confirm no second work/Run/Attempt/Budget/answer after replay.
Treat a cut during volatile local work according to native loss semantics; never
label it successful replay. Exercise noncompleted terminal outcomes with real
authoritative Run commands at controlled quiescent host boundaries, not fabricated
result maps or direct SQL replacement of outcome rows.

At quiescent boundaries compare exact resource, receipt, native state and outbox
contents/counts before and after repeated GETs and restarts. Use controlled real
Store faults for loss-after-commit/read outage; an absent-unknown test must keep an
outstanding writer fenced until actual termination before retry. Document the
finite fault assumptions and do not generalize them into arbitrary crash recovery.

Temporary negative controls: launch before association confirmation; and fabricate
a result instead of reading RunEngine.result. The first must fail the no-allocation
assertion; the second must fail a result-unavailable/read-limit case that forbids
answer mutation even if a fabricated payload happens to equal the expected hash.
Restore edits byte-for-byte. Run focused acceptance and the required full/affected
gate, roadmap/live/claims/diff checks, independent review, exact-head hosted checks
and queue merge. Record evidence in the named report and update the Wave 4 plan
without claiming Level 4 or overall Wave 4 completion.

The capacity reservation uses public Conversation.prepare for hypothetical input,
association and a 71-byte placeholder answer, updating hypothetical snapshots only.
The actual answer still comes exclusively from RunEngine.result. Sole-writer and
unfinished-input guards preserve that capacity between the committed stages.
Only an otherwise valid new input needs that future-capacity check. Preserve
CheckedCommand's real retained stale/domain refusals and original-identity replay;
do not let a preflight replace those outcomes or reject a retained successful replay.
