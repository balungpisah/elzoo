# ELZ-266 — fixed two-source root-channel acceptance

- Phase: Level 4
- Dependencies: ELZ-258, ELZ-265
- Output: extension of the existing ELZ-258 root consumer; no Piece.
- Owned paths: `examples/wave4_channel.exs`,
  `examples/support/wave4_channel.ex`, `test/wave4_channel_test.exs`,
  `test/support/wave4_channel_helper.exs`,
  `test/wave4_command_conversation_test.exs`,
  `docs/research/wave4-channel-acceptance.md`,
  `docs/plans/bot-platform-wave4.md`, this task file, and this task's row
  in `docs/plans/release-plan.json`; generated `LEDGER.md`,
  `docs/plans/views.md`, `docs/plans/dependencies.mmd`. No other shared helper,
  Piece, runtime, dependency, pin, CI, or job/output ownership changes.

Start after publication and ELZ-258/ELZ-265 merge. Preserve the existing
immediate profile and its tests while adding the fixed outside-event profile.
Run focused tests and the real demo, then the required shared-root
`mix check --affected origin/main` and `git diff --check`. Follow normal hosted,
review, queue, and main-push checks. The affected gate is not full acceptance.

## Changed Contract

Keep the existing six-key immediate profile shape, exact declared target,
default behavior, source identity, IDs, fixed deadline, replay, evidence, and
hash of primary text. Add a bounded profile with exactly one `reply_source_id`
distinct from `source_id`, its own WebhookIn configuration/key/admission closure,
and the fixed `NativeBindings.reply_target/0`. The two declared target shapes
select the two profiles; add no mode/routing option. Reject arbitrary targets
even when profile and selected binding equal each other. An equal copy of the
actual declared constant is valid. Keep `CommandBindings` in the existing
`examples/support/wave4_channel.ex`.

Add `admit_reply/3`, `release_reply/4`, and fixed callable `wait_then_hash`.
After corroborated reply, pass retained reply text through existing
`NativeWork.hash/1`; answer is `answer:` plus 64 lowercase SHA-256 hex characters.
The immediate profile continues hashing primary text. Reply source payload is
exactly `%{"text" => text}`. No semantic AI answer or production-auth claim.
The fixed root wait binding estimates zero; native supplies actual zero for the
wait. Provider I/O cost is outside the native work budget.

Preserve exact bounds: signed WebhookIn six-field event and raw body at most
65,536 bytes; Conversation text at most 4,096 bytes; complete stored CheckedCommand
resource at most 65,536 bytes; GET response at most 1,048,576 bytes without
truncation. CheckedCommand provider limits are separate: 1,024 retained
operations, 4,096 stream rows, and 1,048,576 bytes per row. Native result-reader
limits do not bound provider I/O.

Keep primary/reply command identities, source bytes, ASK evidence, association
revision, and fixed scope. Retain reply ASK under its original command identity;
only one unresolved reply while primary waits and one outstanding correlated
reply per primary Run. Reply cannot start a primary Run. Reply `input_id` is the
advertised correlation ticket, not conversation_id. Check fixed scope, active
ticket, both immutable deadlines, and current authority before fresh append.
Reconcile committed/uncertain release by original identity after expiry, but
never admit expired native work.

Use actual WebhookIn, CheckedCommand, Conversation, RunApprovalRelease, RunEngine
v2, event source, DurableUnit, and Store public APIs. Webhook event ID binds its
CheckedCommand operation. Native event ID is the original canonical Outbox item
key from `Outbox.parse_id/1`, never webhook ID, sequence, payload field, or a
generated ID. `Outbox.pending/3` is stream-scoped, not destination-filtered:
select both destinations only in its bounded returned set and fail closed on
insufficient evidence. The reply-input descriptor has its own destination;
association and answer descriptors emit no source-work notices. `pending/3` is
discovery only; after a key is known, recover its original item/nonce with
`read_ack`. Validate fixed stream, destination, position, sequence, and notice
scope before any checked read; notices contain no raw source text or event ID.
`CheckedCommand.result` corroborates completed reply-message identity; public
resource and `Conversation.view/2` supply exact text and same-Run association.
Never use private command decode or mutable host state.

Source closures bind immutable profile, Store, and checked handles, verify the
fixed native scope before mapping to CheckedCommand scope, and never widen from a
notice/request resource or call the host GenServer. Bind reply source to the
original source key; event source schema remains fixed. Commit and positively
confirm immutable reply association to existing Run before native delivery or
post-event work. Preserve resource revision for command CAS; it is not global
Store sequence. Old committed reply replays its receipt and cannot wake a newer
wait; closed/foreign ticket refuses before mutation.

Capacity uses the complete projected resource snapshot (retained fields and
revision), not Conversation bytes. Reserve bounded primary/reply/answer messages
and associations before primary intake, sizing unknown reply at maximum ID/text;
recheck actual reply, association, and answer projections before reply mutation
and post-event work. Test Conversation-fit/resource-overflow and slot limits.

Command headroom is separate from resource bytes. CheckedCommand caps retained
operations at 1,024, rows at 4,096, and each row at 1,048,576 bytes; public
`result/resource` does not reveal remaining operation count. Under the fixed
serialized-host assumption, use stable public stream head as conservative row
upper bound, with no private decoder. Two internal association descriptors and
the answer descriptor always permit for this bound. The path needs at most five
fresh operations and seven retained rows. These cover primary ASK/release and
association, reply ASK/release and association, and answer. For fresh primary
intake require head <= `1024 - 7`; reconcile existing identities before refusal.
Recheck all four fresh boundaries: fresh primary (7 rows/5 ops), pending primary
ASK release (6/4), fresh reply (4/3), pending reply ASK release (3/2). This is a
preflight, not a global reservation against independent writers. Test exact and
one-over thresholds with unrelated historical refusals. Existing public release
paths add at most one successful or stale-revision terminal row to an original
ASK; evidence, gate, and domain refusals append none. Audit the fixed descriptors
against these bounds. Preserve existing v1 association-denial tests. The fixed
v2 internal association gates always permit; test rejected/unknown v2 association
via actual revision or storage boundary, not an internal ASK configuration.

Source classification: CheckedCommand `{:unknown, :unresolved}` is not a
confirmed gap. Positive low_water advancement from public `Store.read(:head, ...)`
is a gap. If classifying missing/empty ranges, use bounded public `Store.read`
and stable before/after heads. Intermediate association/approval/non-event
records are not gaps. Ambiguous checked reads stay unavailable/fenced. The
original Outbox item and nonce are recoverable by public
`Store.read(store, :read_ack, [key])` even after ack; never infer ack from
pending absence or synthesize receipt.

Retain both source notifications until authoritative native result and durable
answer or documented terminal outcome. Ack reply first and primary last, each
with original key/nonce in its own bounded advance phase. Recover inter-ack cut
from pending primary, retained native accepted-event key, and read_ack result.
Unknown ack requires original-identity reconciliation or physical fencing; no
replacement key/nonce. Fence predecessor callers, tasks, owners, and connection
trees before replacement.

GET stays read-only: validate scope before reads; 200 is the bounded view, 403
is a well-formed scope without configured identity/grant, 503 is malformed or
unavailable Needs or authorized read/encoding failure, and wrong route/method
returns fixed 404/405. Enforce the 1,048,576-byte cap. GET reads no clock, never
starts/reopens/recovers/repairs Engine, and fails closed if reader is unavailable
after host loss. Recovery is explicit `advance/1`. Keep authorized conversation
text as before; new wait metadata excludes raw native/event payload and
cryptographic secrets. Finite demo uses actual two-source HTTP, native wait, one
reply, local hash after acceptance, authoritative result, durable answer, second
primary/reply round, old-event replay, and GET without extra work.

## Needs and grounding

The host supplies fixed source authentication, authority, Store retention,
serialized writes, complete fencing, and bounded truthful callbacks. Current
source has `NativeBindings.target/0`, `NativeWork.hash/1`, public CheckedCommand
`result/resource`, Conversation views, stream-scoped Outbox, and Store `read_ack`;
`reply_target/0`, reply APIs, and `wait_then_hash` are new. Preserve Level 3
association denials, identity/revision rules, and existing 71-byte answer.

## Contract-to-test acceptance

1. Keep all existing ELZ-258 tests/demo behavior unchanged, including its
   association-denial cases; test both target constants, arbitrary matched
   profile/binding rejection, and equal copy of the declared constant acceptance.
   Immediate profile needs no reply source.
2. Real disposable PostgreSQL + loopback HTTP: signed primary, confirmed native
   activation, early guessed-ticket refusal, reply ASK/release, exact reply text
   corroboration, native event/result, `wait_then_hash`, durable answer, scoped
   GET. Test bad HMAC, revoked/expired release, source/resource/ticket/schema
   refusal, scope-before-read, association unknown, and no pre-event work.
   Include maximum valid source/profile identities and the resulting canonical
   Outbox key; do not mistakenly apply the stream/source-ID cap to that key.
3. Test `{:unknown, :unresolved}` vs positive low-water gap, continuity across
   bounded public reads/stable heads, non-event records, missing/empty/unavailable
   faults, and actual PostgreSQL checkpoint+retain followed by refusal. Test
   controlled empty/gap/unavailable faults too, not as a substitute for retain.
4. Test byte/message limits, full resource projection, all four operation-head
   thresholds exact/one-over, unrelated historical refusals, ASK row allowances,
   reply association confirmation before post-event work. Unknown reply must keep
   original primary Run/Attempt and add zero work, not assert zero existing Runs.
5. Test reply-first/primary-last ack cuts before/after commit, activation, event
   input/result, completion, answer, each ack; original keys/nonces, already-acked
   read_ack, lost ack replies, unresolved/superseded cases, and fencing. No pending
   absence inference or replacement receipt.
6. Test two successful primary/reply rounds, replay old events, both GET views
   without new work/Run/Attempt/Budget/answer/ack. Test unavailable native owner
   GET fail-closed and separate explicit advance recovery. Preserve authorized
   conversation text only; repeated GET causes no writes/callbacks.
7. Temporary controls across native/root: premature activation, reset cursor,
   fabricated paired/accepted evidence, primary-before-reply/answer ack, and
   synthesized answer. Named assertions must fail; restore exact bytes and
   record finite fault assumptions.
8. Update named demo, support, tests/helper, report, plan and generated views;
   do not edit Piece manifests. Run focused tests/demo first, then required affected
   gate and diff check. Record counts as emitted; affected and selected checks
   are not full acceptance. Required hosted/main checks remain.
