# ELZ-023 early-review decision packet

ELZ-023: early review **CONDITIONAL**, not implementation clearance.
Branch/PR: `task/ELZ-023`; no PR; reviewed proposal
`c90a7385baafa1eadc4da30945dcf0312c521ec9`.
Checks: pinned setup exit 0; full unchanged-baseline check exit 0 with
`Result: 32 passed`, `Result: 564 passed`, `ELZOO CHECK PASSED`; proposal
probe and independent reproduction exit 0, `Result: 8 passed`.
Grounding: four reduced Cure laws/audit, finite proposal scenarios and existing
Store/Envelope probes; independent mutation findings, not a production proof.
Limits: the current probe does **not** establish the headline rearm invariant;
no implementation, amended live Contract, PR or merge acceptance exists.
Open work: root decisions R-A–R-F, exact issue/task amendment, revised proposal
and provenance-carrying probe, focused independent re-review, then production.

Prepared 2026-11-08 WIB by the pieces coordinator. The complete independent
[review](ELZ-023-early-review.md) is preserved verbatim. Reviewer:
`orca_session_id:0f974e4c-75e1-4daf-9a19-7720ad2b1633`, dispatch
`ctx_91ee2fe4f81f`. The review inspected the actual three-file proposal diff,
the live issue and all comments, and the accepted dependency sources.

**Nothing below is adopted.** These are concrete recommendations for root
decision, not permission to implement. The additional numerical scheme and
restart treatment below are coordinator recommendations following the review;
they have not themselves received focused review. Do not call them cleared.
Root can amend or reject any recommendation. Before/after quotations below
identify the live text being replaced or supplemented; after decisions, produce
one exact complete diff and synchronize the task copy and live issue bytewise.

## R-A — use three recorded grounds; keep the unconditional law

Recommendation: approve D1, with the reviewer conditions below, and approve D2
as a correction to the exact accepted Envelope matrix.

Before (Admission 2): "`rejected/not_dispatched` and `timed_out/not_dispatched`
return to `intended`"; "`failed_definite` is the only state out of `dispatched`
that re-arms dispatch, and it is reached on exactly two grounds".

After: "A correlated `rejected/not_dispatched` or `timed_out/not_dispatched`
after a dispatch reservation records `failed_definite(adapter_no_send)` before
any rearm. A permanent rejection additionally disarms it until a permitted
argument/schema revision. Every path from `dispatched` to a subsequent dispatch
passes through a durable `failed_definite` carrying exactly one of
`adapter_no_send`, `provider_no_effect` or `provider_replay_safe`. The binding
attests, per mapped failure variant, that `adapter_no_send` means no request
bytes were handed to the transport; its truth is an upstream Need, not a proof.
Argument/schema failure before the dispatch reservation creates no attempt and
leaves `intended` disarmed. Capacity refusal before a send disarms the current
intended/failed_definite state; it never authorizes a send."

Before (Admission 5): "`failed_definite` is reachable only on one of its two
recorded grounds". After: "`failed_definite` is reachable only on one of the
three defined grounds; the rearm provenance and attempt identity are carried
in the state consumed by the policy."

Before (Admission 2): "`timed_out` or `unknown` with `dispatch` one of
`not_dispatched`, `dispatched`, `unknown`". After: "`timed_out` with dispatch
`not_dispatched`, `dispatched` or `unknown`; `unknown` with dispatch `dispatched`
or `unknown`. Require attempt_id matching a recorded attempt and matching
request/correlation identity at this Piece's observation boundary. The more
general ready Envelope Contract remains unchanged."

Acceptance addition: "Check the eight valid Envelope result pairs and reject
missing/mismatched attempt identity. Test pre-reservation disarm, post-reservation
adapter_no_send through failed_definite, permanent disarm, and a successful
first dispatch. A permanent error on a possibly-dispatched result still polls;
do not reuse RetryTimeout.classify's permanent-first rule for this policy."

## R-B — choose replay breadth explicitly

Recommendation: choose **narrow**, matching the proposal's conservative reading;
availability can be lower when an idempotent provider cannot answer its poll.
Root may instead choose broad; that needs a revised transition table/probe.

Before (Admission 2): "a provider idempotency contract under which a re-send
with the same key is harmless even if a partial effect happened" alongside
"a bare `failed/dispatched` result satisfies neither".

After, narrow: "`provider_replay_safe` is reached only from a poll or reconcile
answer `unknown_to_provider` under a valid binding-declared replay capability.
Failed/dispatched, timeout, unknown, pending or unavailable observations alone
never create that ground, even when the binding supports replay."

Alternative after, broad (not recommended here): "A non-confirmed dispatched
observation `timed_out`, `failed`, `unknown` or poll `unknown_to_provider` may
create provider_replay_safe only when the binding's valid replay contract makes
another send with the same operation key and arguments harmless; the observation
without that capability never suffices."

Add under either choice: "unknown_to_provider is never a no-effect certificate.
Without valid replay capability it is stranded. A provider_no_effect certificate
is authenticated and bound to the exact operation/attempt and rules out delayed
future processing of that attempt. Capability names provider/account scope,
same-key/same-argument semantics, clock and validity horizon anchored at the
earliest possibly-sent attempt's dispatched record. A new send is admissible
only when its maximum in-flight lifetime plus clock allowance fits within that
horizon; lacking a usable bound refuses replay."

Add to identity/revision Needs (D4/F9): "A binding declares how its provider
handles same-key changed arguments; cached-result semantics refuse argument
revision. Revision also requires all earlier attempts to be certified never
sent. The consumer retains the intent/tombstone through both the provider-key
horizon and the business duplicate-request horizon; deletion is not permission
to execute a previously admitted operation again."

Acceptance addition: "Exercise pending/unavailable/timeout/failed observations
under both capability modes according to the selected breadth, partial effect,
capability expiry, late arrival beyond the horizon, changed-payload revision and
duplicate admission after terminal completion."

## R-C — old attempts, contradictory completion and operator resolution

Recommendation: accept an authenticated older completion as the same operation
only when its intervening rearm history is entirely replay-safe and key/payload/
binding match; a completion contradicting any no-send/no-effect ground freezes
rearm and requires operator reconciliation. This deliberately changes the live
"only while dispatched" sentence where stated below.

Before (Scope): "accept a late result at most once and only while `dispatched`;
the first of a late result or a reconciliation wins, a refused late result is
retained as evidence, and a late result whose store write is unavailable is unknown".

After: "Pending, timeout and unknown are observations, not winning settlements.
One decisive settlement wins by durable CAS per attempt. An authenticated
completion for a recorded older attempt with the same operation key, arguments
and binding may confirm a nonterminal intent when every intervening rearm used
provider_replay_safe; this includes intended-after-rearm and failed_definite,
as well as a later dispatched attempt. A completion contradicting an
adapter_no_send or provider_no_effect ground records a contradiction and blocks
all further dispatch/rearm pending operator reconciliation. It does not silently
become an ordinary stale result. Confirmed/stranded remain terminal for dispatch;
later evidence is recorded under the bounded-evidence rule without reopening
them. Unavailable or indeterminate evidence writes are unknown and halt active
ownership; inability to retain a contradiction must not leave local rearm enabled."

Additional restart rule recommended for explicit review: "After an owner halt
with uncertain writes or unretained decisive/contradictory evidence, restarting
from a prior snapshot alone does not restore dispatch authority. Recovery is
read-only until host/operator reconciliation re-establishes an authoritative
operation outcome and valid ground; the host must preserve/deliver that recovery
obligation across restart. An in-memory flag is not durable quarantine."

This last sentence adds an explicit host Need; the focused re-review must check
its realizability and exact interface before implementation. There is no claim
that a failed Store write can durably record its own failure.

Operator path addition: "Stranded never rearms. An operator verifies the outcome
at the provider and records the business resolution in the host; optional bounded
operator evidence may be appended without changing the terminal phase. Only a
verified no-effect resolution permits a separately authorized new logical
request. Inventing a new key for an unverified stranded operation risks a
duplicate effect and is not recovery supplied by this Piece."

Acceptance addition: "Race late completion and reconciliation in both orders;
old replay-safe completion before/after the next reservation; completion that
contradicts no-send/no-effect; unavailable contradiction write and restart;
pause-after-reservation of owner A while B recovers/reconciles/rearms, then A
sends late. CAS controls reservation; replay safety/final certificates and host
ownership assumptions, not a bare CAS claim, cover the delayed-send boundary."

## R-D — admit a bounded evidence promise and numeric budgets

This is a real **weakening of the unconditional retention wording** and needs
explicit root approval. Recommendation: admit priority retention and honest
overflow reporting; do not silently claim every observation is retained.

Before (Scope): "a refused late result is retained as evidence". The task
contains no numeric limits; the proposal supplied 256 attempt/revision changes,
1024 evidence records, 64 KiB arguments and a 1 MiB checkpoint without full
accounting.

Proposed after: "The initial subset bounds identity fields to 256 UTF-8 bytes,
encoded arguments to 64 KiB, combined attempts/revisions to 256, retained
redacted evidence records to 1024 and committed event records to 4096. Each
redacted evidence payload is at most 512 encoded bytes; it records fixed tags,
identities and a canonical digest/reference, not arbitrary provider payload.
Reserve three evidence slots (1536 payload bytes) per admitted attempt for its
decisive settlement, first contradictory completion and first refused result,
plus the actual canonical framing, event and checkpoint seen-index growth.
Validate these reservations before dispatch; routine repeated pending/unavailable
observations use bounded counters and may not consume priority slots. Further
duplicates/observations that cannot be retained return explicit host-visible
not-retained status. A contradictory or decisive observation that cannot be
committed halts active ownership under the recovery rule; it is never reported
as retained."

"The 1 MiB ceiling is **per encoded checkpoint**, including model, cursor,
identity witnesses and framing, not total disk use. Before committing a
reservation, encode/check the projected append and both required checkpoint
barriers including reserved evidence. Bound append records to 128 KiB and
require Store limits at start of at least 128 KiB max_record_bytes, 1 MiB
max_checkpoint_bytes and max_batch_size 1, with no Store auto-pruning outside
the retention Need. At most one checkpoint per committed event is created;
4096 immutable snapshots can occupy up to 4 GiB plus bounded log/index overhead.
This is a loose worst-case ceiling, not preallocation or a storage-availability
guarantee. Refuse an inadmissible initial state or reservation; never discover
known insufficient checkpoint capacity only after reserving a send."

These are concrete **unreviewed proposed numbers**, not a claim that the codec
currently satisfies the budget. Recommendation is conditional on a focused
encoding/reservation probe proving the arithmetic and checking whether smaller
ceilings suffice; no implementation starts on an untested capacity assertion.
Root may choose different limits or reject the bounded-retention change.

Acceptance addition: "Prove by executable encoding checks that worst-case
identities/arguments/reserved evidence and cursor witnesses fit before send;
exercise every bound at limit and limit+1, undersized Store startup, event-count
exhaustion, routine-poll saturation, priority evidence, a refused evidence append,
and immutable-checkpoint disk-growth accounting."

## R-E — separate admission expiry from optional recovery expiry

Recommendation: fixed trusted binding `recovery_grace_ms: :none | nonnegative`
with default `:none`. Do not implicitly strand at the request admission deadline.

Before (Admission 2): "and the deadline" and "a crash or deadline by itself
never re-arms". The proposal additionally used an undefined recovery deadline.

After: "The request's deadline_unix_ms prevents new dispatch/rearm when now is
at or beyond it. The trusted binding may separately set recovery_grace_ms,
default none; a finite grace derives an absolute recovery deadline by checked
addition to the request deadline, rejecting signed-bigint overflow. While
dispatched, reaching this recovery deadline makes the intent stranded; none
allows continued host-driven polling within the other bounds. Neither expiry
creates a rearm ground. Time is trusted host input under the named clock/skew
assumptions. A late completion after stranded follows the operator-evidence
path and never automatically reopens the intent."

Acceptance addition: "Dispatch just before admission expiry, no new send at
expiry, continued recovery with none, finite grace boundary, overflow rejection,
and completion after stranded."

## R-F — confirm reuse and literal checkpoint barriers

Recommendation: approve both scope readings explicitly, retaining the stricter
append-and-checkpoint rule and capacity preflight.

Before (Scope): "define the store behaviour and a test double; bind to the
ELZ-009 provider". After: "Reuse the accepted Elzoo.DurableLog.Store behavior
and Memory test double; define the intent-specific codec/fold/binding and
conformance fixtures over them and the existing integration/sql provider.
Do not author a parallel CAS/uncertainty behavior or storage engine."

Before (Outcome/Admission): "its intent is checkpointed" and "intended is
written before any send; the owner writes dispatched before the Adapter sends".
After: "Both the intended and dispatched barriers require acknowledged append
and checkpoint before the first local send. Preflight projected checkpoint
capacity before append; a rejected/uncertain checkpoint never authorizes sending.
Recovery of dispatched polls, including the committed-append/failed-checkpoint
gap. No fresh-nonce rollback shortcut is included in this initial subset."

Additional Needs/limits to record (F8/F11): if an Adapter wraps the ready retry
Runner, configure one attempt and redispatch_forbidden; no transparent retry or
redirect may hide a physical send. Memory is volatile and must not be accepted
silently as deployed durability. Keep the per-key owner ephemeral, not a new
registry service. Consumer owns storage access control and classification for
persisted arguments. Telemetry/config/control applicability must be explicit
in the eventual manifest. These are implementation gates, not new evidence.

## Mandatory evidence correction before re-review

Three silent-return mutants (Pending/Expired/Resume → Intended) survived all
four committed laws and current tests. Intended has no history, so first
dispatch and post-return redispatch are indistinguishable. The reviewer also
found a groundless-rearm mutant surviving. Preserve these as negative controls;
do not describe the existing probe as the no-rearm law.

The reviewer explored `Intended(Fresh | After(ground))` with independent step
label predicates (`dispatch_only_after_arm`, `fresh_only_from_empty`,
`after_only_from_definite`); scratch Cure checking/audit passed and six mutants
were rejected. This is independent feasibility evidence, not production proof.
Next authorized probe must carry the production-relevant attempt/provenance
state, cover silent-return mutations, assert the initial-state condition and
positive dispatch, and keep deadline/disarm/capability guards in the actual
pure policy. Do not infer an arbitrary-history theorem from the earlier table.

After root decides: post exact before/after amendment on #37, update issue and
task copy identically, update roadmap issue-body hash as scoped coordinator
metadata, revise the proposal and probe, then obtain focused independent
clearance. All production, full final validation, PR and merge gates remain.

## Exact executed commands and report time

Decision packet prepared 2026-11-08 08:45:43 WIB.

Cure `208248063d64e621782cd26dd30698ee42850a89`, Elixir 1.20.4, OTP 29.1.2.

```sh
env LANG=en_US.UTF-8 LC_ALL=en_US.UTF-8 ERL_FLAGS='+S 4:4 +SDcpu 1 +SDio 1' ELZOO_TEST_DATABASE_URL=ecto://elzoo_elz024:elzoo_elz024@localhost/elzoo_pieces_test mix setup
env LANG=en_US.UTF-8 LC_ALL=en_US.UTF-8 ERL_FLAGS='+S 4:4 +SDcpu 1 +SDio 1' ELZOO_TEST_DATABASE_URL=ecto://elzoo_elz024:elzoo_elz024@localhost/elzoo_pieces_test mix check
env LANG=en_US.UTF-8 LC_ALL=en_US.UTF-8 ERL_FLAGS='+S 4:4 +SDcpu 1 +SDio 1' MIX_ENV=test ELZOO_TEST_DATABASE_URL=ecto://elzoo_elz024:elzoo_elz024@localhost/elzoo_pieces_test mix run --no-start docs/work/ELZ-023-probes/probe.exs
python3 scripts/check-roadmap.py --live
git diff --check
```

All exited 0; setup 08:12:14–08:18:20 WIB; baseline full check 08:20:07–08:32:54 WIB (32 + 564 passed); proposal probe 8 passed. Independent reviewer reran the probe, not the full check. Later decision/review-record additions are documentation only.
