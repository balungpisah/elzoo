# Bounded signed-channel acceptance (ELZ-258)

## Need and scope

This is a finite Level 3, consumer-owned composition from a signed first-party
message to a durable answer and a scoped read. It adds no Piece or Piece
Contract. The fixed profile selects one tenant, actor, source, conversation and
native target. One host serializes command writes, approval release, native
creation/start and acknowledgement; it admits at most one committed unfinished
input. `advance/1` performs one bounded phase and returns. It does not poll,
sleep, renew the immutable profile deadline, or schedule background work.

The path is:

```text
signed HTTP POST
  -> WebhookIn verifies raw bytes and normalizes the event
  -> host admission through CheckedCommand input and durable Outbox
  -> retained input/result/resource reads and immutable input-to-Run association
  -> real RunApprovalRelease Run/Attempt and native RunEngine Unit
  -> local native work and authoritative RunEngine.result/3
  -> durable CheckedCommand assistant answer and original-key acknowledgement
  -> scoped, read-only GET through Conversation.view/2
```

Only a confirmed matching association permits native allocation. The demo uses
a fresh random HMAC key in memory and a synthetic loopback principal; the MAC
authenticates the configured source, not a human. Truthful production
authentication, authority, clock/key provisioning, storage retention, listener
lifecycle and request termination remain host Needs. The example claims no
provider/model semantics.

## Executed trace

`examples/wave4_channel.exs` owns a temporary Repo, consumer migration, fresh
random schema, real Stores and Lease/RunApprovalRelease owner, distinct Engine
and Unit Registries, supervisors, DynamicUnits, NativeBindings, command
bindings and fixed profile. It starts an ephemeral loopback listener, sends two
real signed HTTP messages and explicitly advances one phase at a time until
each original input is acknowledged. Each input traversed:

```text
observed -> associated -> run_created -> attempt_started -> engine_started
-> native_input -> result -> answered -> acknowledged
```

The subsequent GET and replay of the first message retained its original
receipt and left the read view and command head unchanged. The view contained
two completed Run summaries and four messages; the printed answers came from
the public native result path, not a locally synthesized response. Cleanup
stopped the listener, host/native processes, owners, directory/task/unit
supervisors and registries before dropping only the generated schema and
stopping the Repo.

## Contract-to-test map

| Scenario | Public API boundary | Assertion | Controlled fault/evidence |
| --- | --- | --- | --- |
| Startup binding/profile rejection | `Wave4ChannelExample.start_link/1` | `startup requires a unique compatible binding and the fixed ASCII profile`: missing, ambiguous or incompatible binding/target and a non-ASCII conversation profile return `{:error, :invalid_options}` before Run creation | Real startup validation; status redaction and no source identity in process status |
| Signed ingress, scope/header checks, identity/revision conflicts and happy path | `WebhookIn.call/2`; `admit/3`, `advance/1`, `view/2`; `CheckedCommand.result/3` | `HTTP and read guards return fixed statuses without mutation`, `retained identities reach CheckedCommand conflicts while deadline survives reopen`, and `signed loopback processes two distinct inputs and replays the first`: fixed refusals; changed bytes/resource/revision conflict; changed-resource reuse still reaches the real `CheckedCommand` identity conflict despite the host's fixed resource scope; original IDs survive; two completed Runs/four messages and replay preserves view/head | Real signed requests, duplicate/malformed header and scope controls, retained identity conflicts; no fake owner, answer or dispatcher |
| Denial, busy/capacity refusal and read-only GET failures | `admit/3`; `view/2`; `CheckedCommand.resource/3`; `Conversation.view/2` | `input gate and policy denials retain refusal without resource, outbox, or native work`, `admission callback exceptions and exits return fixed errors without writes`, `committed input reply loss stays fenced through read outage until identity confirmation`, `future capacity accounts for the association and answer before input admission`, `GET reports not_recorded only for the known pre-creation phase`, and both `GET fails closed` cases: refusals leave state unchanged; unavailable/mismatched owners return fixed unavailable; only the known pre-creation phase is `not_recorded` | Gate/policy/callback denials, an unfinished-input busy refusal, capacity boundary, unavailable Run owner and mismatched native operation; GET changes no command head or Outbox |
| Unknown association | `advance/1`; `RunApprovalRelease.status/2`; retained `CheckedCommand.result/3` | `association reply loss stays fenced with zero native allocation until confirmation`: no Run/Unit/hash before matching association confirmation; original input remains retained | Real association reply loss plus command-store read outage; pending confirmation is not treated as commit |
| ASK, stale/revoked approval evidence and release | `admit/3`, `release/4`, `advance/1`; retained `CheckedCommand.result/3` | `ASK survives reopen and releases only once with fresh command evidence` and `initial ASK reply loss recovers the same pending requirement after a read outage`: wrong request, changed policy, revoked/self/stale/expired evidence does not release; original requirement/key stays pending; valid command-purpose evidence releases once | ASK append reply loss/read outage; paused SQL RELEASE cannot be reconciled from the earlier ASK receipt, and new intake/re-release stays fenced until the writer is finished |
| Immutable release deadline and post-expiry reconciliation | `release/4`; `advance/1`; `CheckedCommand.result/3` | `release refuses an ASK at and after the immutable deadline`: exact-deadline and after-deadline refusals preserve the pending key/requirement, resource revision, command head and Outbox with no Run/Unit/task/hash; `a paused release writer cannot reconcile from the earlier ASK receipt`: a release made uncertain before expiry is confirmed after the SQL writer is released and monitored beyond expiry | Host clock control with the real ASK fixture; a real PostgreSQL RELEASE writer pause; reconciliation remains read-only and is not deadline-blocked |
| Uncertain input/answer and live-writer fencing | `advance/1`; original input/answer identity confirmation | `committed input reply loss stays fenced through read outage until identity confirmation`, `paused input writer is not treated as non-commit and stays fenced until it exits`, `committed answer reply loss reconciles without rerunning native work or replacing the answer`, and `native input append remains live and unresolved until its PostgreSQL writer is released`: unknown remains fenced until original identity confirmation; no replacement work or duplicate answer | Real append reply loss, unavailable reads and PostgreSQL writer barriers; a paused writer is positively released/observed before reopen |
| Fixed resource boundary for notification recovery and retained ASK release | `advance/1`, `admit/3`, `release/4`; public `CheckedCommand.execute/3`, `result/3`, `resource/3` | `foreign completed input notification is rejected before checked-command reads`: a same-tenant/actor/destination foreign input is fenced before any result/resource read, with both resources, command head, Outbox item and native state unchanged; `a retained foreign ASK cannot be released through a broad scope`: retained replay is reachable through public `admit/3`, but `release/4` refuses before authority or append. Same-conversation recovery remains covered by the existing cases | Real SQL fixture; foreign completion and ASK are seeded through `CheckedCommand.execute/3`; broad trusted scope contains both configured and foreign resources; a direct old-behavior control committed revision 1 |
| Run/Attempt/input/startup, reopen cuts and local restart | `advance/1`; `RunApprovalRelease.status/2`; `RunEngine.result/3` | `Run creation and Attempt reply loss retain identities without early native allocation`, `partial Engine startup is fenced and cleaned before reopening the same Attempt`, `fenced reopen recovers association, native result, and answer without replacement work`, `uncertain native input stays fenced until safe reopen and original-ID confirmation`, and `volatile local work is recorded as terminal loss after fenced reopen`: same identities survive the three cuts; no second Run/Attempt/hash; local work is `local_restart` with no answer | Real Run/Attempt append loss, native read loss and partial start; predecessor task/native trees are fenced before same-identity reopen |
| Authoritative result unavailable | `advance/1`; `RunEngine.result/3`; `view/2`; `CheckedCommand.resource/3` | `unavailable authoritative result reader cannot append an answer or acknowledge`: advance is pending, resource and Outbox remain unchanged, and GET contains no assistant message until the original result is readable | Injected evidence-store read unavailability after actual native completion |
| Original-nonce ack unknown, malformed and superseded outcomes | `advance/1`; `Outbox.ack/3`; `DurableLog.confirm_ack/2` | `ack reply loss is positively confirmed by the original canonical key and nonce`, `ack rollback remains fenced and reopens directly from the retained answer`, and `a different nonce winning the original ack key reports conflict and retains host poison`: same key/nonce confirms; rollback/read-unavailable/malformed stays `{:unknown, :ack}`; a winning different nonce returns `{:blocked, :ack_superseded}` and preserves poison/state | Real ack reply loss/rollback, `read_ack` unavailable/malformed results and a competing committed nonce |
| Ack uncertainty, stale Registry entries and reopen | `advance/1`; original-key confirmation; fixture teardown | A committed canonical ack is acknowledged after native PIDs are dead even while real Registry workers retain stale dead-PID entries; reopen keeps original Run/Attempt identities | Real Registry partition workers are suspended at a quiescent post-answer boundary and resumed in `try/after`; live owners/unavailable reads remain failures; bounded cleanup waits are outside `advance/1` |
| Controlled terminal commands | `RunApprovalRelease.command/2`; `advance/1` | `cancelled real native work produces no answer and is fenced before ack`, `out-of-budget real native work produces no answer and is fenced before ack`, and `out-of-time real native work produces no answer and is fenced before ack`: the original-key ack is retained; no assistant answer, second Run/Attempt or additional hash is produced, and the task is dead after fencing | A delegated real-hash barrier holds work after invocation; authoritative terminal commands are issued at quiescent boundaries |

## Findings 0001–0003 mapping

| Finding | Implementation boundary | Regression coverage |
| --- | --- | --- |
| 0001: preflight full projected capacity | `capacity_after_input/…` checks the complete projected resource, retained fields and revision before admission mutation or native work | `future capacity accounts for the association and answer before input admission` and `full CheckedCommand resource snapshots reserve capacity before input admission` use the real fixture and assert refusal leaves the resource, command head, Outbox and native work unchanged |
| 0002: authoritative terminal reconciliation | `reconcile_input/2`, `reconcile_release/2` and the direct stale-release branch of `execute_release/…` | `retained input denial reconciles after reply loss without admitting through read outage`, `retained stale release conflict reconciles after read outage`, and `direct stale release conflict does not poison future admission` preserve uncertainty until public retained results confirm the exact original operation, then permit later valid admission |
| 0003: startup child ownership | `start_engine/1`, `start_async_work/5`, `start_native_engine/5` and the single `own_native_child/3` helper | `Engine Registry outage retains acquired children and recovers the same Attempt` verifies the acquired PIDs are owned or physically stopped, cleanup succeeds, and recovery reuses the original Run/Attempt without extra work; `accepted-but-misconfigured nil task supervisor cleans the acquired evidence Writer` exercises the distinct AsyncWork acquisition failure using a host option accepted by validation but misconfigured as `nil` |

The fixture also uses separate command-store and native-store fault controllers.
A diagnostic confirmed that the former shared controller allowed an injected
`:read_ack` fault to be consumed by a native Unit read on its different key
before the host read the original source key. The previous
`{:acknowledged, "input-1"}` result was not reproduced; its exact cause remains
unproven.

These terminal cases verify controlled authoritative commands, **not actual
budget exhaustion or deadline expiration**. The injected unavailable native
read exercises the real RunEngine lost-owner crash path; the host contains it
by fencing and reopening the same identity. No Piece code or native semantics
were changed. Physical process
liveness is distinct from asynchronous Registry/directory cleanup: a proven
dead PID is fenced, while live or unavailable ownership is blocked. No polling
was added to `advance/1`. Malformed-summary and 1 MiB branches were not
artificially reached. GET is read-only; it does not append a command or
acknowledgement.

## Runnable demo

Set `ELZOO_TEST_DATABASE_URL` to a disposable local PostgreSQL connection URL
whose host is loopback, then run:

```sh
mix run examples/wave4_channel.exs
```

The script requires no ExUnit/test-support import or opaque Application
configuration. It applies the public DurableLog SQL migration in its generated
schema, uses a per-run random key without printing it, and owns and stops its
finite runtime. A production authentication or persistent-service guarantee is
not implied.

The executed demo printed two complete phase traces, then:

```text
replay 1: original receipt retained; GET view and command head unchanged
completed Runs: 2; messages: 4
native answers: answer:5ac0c5ef9e70fc2c4fa07bb66b985d012ec1fd51ae6abadd5fb807a8090d1d09 | answer:c8bb8e37afee922c3d4f05a01ade34e604abc07bff726f225688d860e41f5b72
cleanup: listener, host/native processes, owners, supervisors, and registries stopped; generated schema dropped; Repo stopped
```

## Executed evidence and limits

Historical evidence at reviewed source head
`eae355a775e6e2308d2419596ed5cb08cf95ef8d` predates findings 0001–0003 and is
not evidence for the current change set. Its focused pair reported 42 passed;
the recorded affected gate reported 2,892 passed and 85 excluded. These counts
are historical only. The demo trace above was also executed before the later
blocker-fix diff and was not rerun for this change.

For the current F3 change set, the focused command
`MIX_ENV=test mix test test/wave4_channel_test.exs test/wave4_command_conversation_test.exs`
reported `Result: 48 passed`. The ack rollback case was run once as a single
`--repeat-until-failure 5` launch; each repetition reported
`Result: 1 passed, 39 excluded`.

The final cheap checks reported:

- `mix format --check-formatted` — exit 0, no diagnostics.
- `MIX_ENV=test mix compile --test` — exit 0; `Cure sources unchanged
  (fingerprint 0f5a8b4edff6); skipping 54 modules`.
- `python3 scripts/test-ci-change-class.py AllowlistGuard.test_no_source_reads_a_documentation_file_unreviewed` — exit 0:

```text
Ran 1 test in 1.071s

OK
```

`git diff --check` is run after the final report edit. No new full/affected
gate was run for F3; the final new gate remains pending. No current hosted
check or merge is claimed.

Historical controls from the earlier source revision used the then-current
selectors `test/wave4_channel_test.exs:927` and `:1822`; those test locations
have since moved to `:942` and `:1837`. The historical original-source hash
`edab2347d551601df48a953d73f82400b296a2d1bfda7bccdb754dd6e7e203a5` below
belongs only to that earlier revision and is not the current source hash.

1. The association control made the unknown-association branch allocate a real
   Run. It failed the zero-Run assertion: `RunApprovalRelease.status/2`
   returned `{:ok, ...}` instead of `{:error, :not_found}`.
2. The result control substituted a correctly shaped `{:ok, dto}` completed
   result with matching Run/operation/Attempt/action/schema identity and an
   answer equal to the expected hash. The existing pending assertion received
   `{:result, :completed}` instead of `{:pending, _reason}`.

Three additional temporary controls ran against the blocker regressions in the
real worktree and failed at their intended assertions, not setup or compilation:

1. Removing the new release-deadline guard made `mix test
   test/wave4_channel_test.exs:2717` exit 2 (`0/1 passed, 33 excluded`): the
   exact-deadline release returned `{:committed, 1}` instead of
   `{:rejected, :conflict}`.
2. Removing notification resource equality made `mix test
   test/wave4_channel_test.exs:2849` exit 2 (`0/1 passed, 33 excluded`): the
   pre-read assertion observed `[:result]` instead of no CheckedCommand reads.
3. Removing the fixed release-resource guard and restoring the old
   request-derived scope made `mix test test/wave4_channel_test.exs:2919` exit
   2 (`0/1 passed, 33 excluded`): the public foreign-ASK route returned
   `{:committed, 1}` instead of `{:rejected, :forbidden}`. This demonstrates
   that the retained foreign ASK route is reachable with a broad trusted scope.

Each temporary mutation was backed up and restored byte-for-byte (`cmp`
succeeded), and the original targeted regressions passed after restoration.
For these newer controls the host source SHA-256 before and after restoration
was `47ac4bf57d659acee827206a48aae8068bd861812cc69d025da4d8979520ff90`; this
is distinct from the historical hash above. No control mutation was committed.
These controls show the named assertions detect the specific failures; they
are not universal guarantees.

This is the historical ELZ-258 v1 acceptance record, not a current summary of
later work. Its scope and gate counts above remain as recorded for that
revision. ELZ-263/264/265 later added the v2 wait Contracts; the distinct
ELZ-266 section below records the bounded two-source root composition and its
evidence. Neither section establishes overall Wave 4 completion.

## ELZ-266 — fixed two-source root-channel acceptance

### Contract boundary and assumptions

ELZ-263, ELZ-264 and ELZ-265 are the merged v2 Contracts for PatternStep,
BotRunLifecycle and RunEngine event waits. ELZ-266 composes those Contracts in
the existing root-channel consumer; it adds no Piece and preserves the ELZ-258
immediate v1 path. This is finite consumer acceptance, not a generic event
subscription, broker or provider guarantee.

The v2 profile has fixed primary and reply targets and two separately signed
loopback listeners with distinct source IDs, keys and admission closures. Both
targets must be valid; an identical copy of the fixed target is accepted, but
an arbitrary matched target is not. Requests use the literal
`POST /elzoo/v1/messages` route. A MAC identifies the configured source; it does
not authenticate a human. The host supplies trusted tenant/actor context,
authority, clock, key provisioning, truthful public callbacks and retained
history.

The source and writer remain explicit Needs: callbacks must truthfully expose
the public Store view, required event/outbox receipts must remain retained,
and appends/ACKs must be serialized. Host-process shutdown alone does not fence
an in-flight provider append. An uncertain same-host write remains blocked;
replacement work starts only after the original provider writer has exited and
the full `fence_and_reopen!/2` owner replacement is supplied. No new Engine or
Unit is treated as proof of provider fencing.

### Public protocol and evidence map

| Boundary | Public path and evidence |
| --- | --- |
| Preserve v1 | `examples/wave4_channel.exs` runs the original immediate v1 flow first. It remains version 1 with no reply source; its trace completes two Runs and four messages. The historical ELZ-258 section above preserves its separate evidence. |
| Fixed v2 source and identity | `test "startup requires a unique compatible binding and the fixed ASCII profile"` and `test "fixed reply source reads checked primary and reply evidence from PostgreSQL"` cover fixed targets, copied equal targets, rejected arbitrary matched targets, maximum IDs, canonical Outbox keys, two-source pairing and the checked evidence stream. A public `:read` fault makes `CheckedCommand.result/3` return `{:unknown, :unresolved}` and `ReplySource.read` return `{:error, :unavailable}`, not `:gap`; positive low-water evidence is a gap. Source shape, continuity, identity and receipt failures fail closed. |
| Activation and reply | `test "reply profile activates a primary wait and keeps GET and reply intake read-only"` and `test "one signed reply wakes the primary, hashes retained text, acknowledges in order, and leaves a read-only final GET"` exercise the original wait/ticket, two signed sources, accepted native reply and retained reply-text hash. The native result is authoritative; the answer is not synthesized from primary text. |
| ASK receipt transition | `test "v2 primary and reply ASK release the saved identities through ordered acknowledgements"` preserves the initial `pending_approval` receipt. Release returns `{:committed, revision}`; the public `CheckedCommand.result/3` is completed at that revision, and later signed replays retain the committed receipt. The pending receipt is not mislabeled as the terminal receipt. |
| Recovery and ACK ordering | `test "fenced v2 recovery restores original wait, reply, ordered acknowledgements, and latest reader"`, `test "active v2 wait reopened after deadline reuses its original expiry wake"`, and `test "v2 superseded reply acknowledgement stays fenced before primary acknowledgement"` cover original Run/Attempt/ticket/occurrence, expiry, answer uncertainty, ACK uncertainty and nonce identity. Public `:read_ack` checks the original reply key and nonce; the reply ACK precedes the primary ACK. |
| Read-only GET and encoding limit | Final GETs through both listeners return the same unchanged view. `test "GET encodes exactly one MiB and refuses one byte over from a controlled event-wait reader"` injects a test-only reader with a valid wait DTO and labeled padding: exactly 1,048,576 encoded bytes returns 200 and 1,048,577 returns 503. This tests the encoding guard only; it does not claim truthful fixed-service data can reach 1 MiB. |

The runnable demo uses `advance/1`, `view/2` and `release_reply/4`. For a
reply ASK it reads the public resource with `CheckedCommand.resource/3`,
prepares authority with `prepare_reply_input/3`, and supplies one
single-use approval envelope for the reviewer role. The v2 internal gates
remain `:allow`. The ASK regression retains the exact `reply_revision == 3`
assertion.

The demo completes two v2 reply rounds with distinct Run/Attempt/ticket
identities: two completed Runs, six messages and resource revision 10. ASK rows
use a separate stream and do not advance the resource CAS revision. During the
second wait, replayed primary/reply requests return their retained receipts
without changing the wait, Run or head and without additional native work. The
final GET through both listeners is read-only and identical. Reply ACK precedes
primary ACK in each round.

### Capacity, source and recovery limits

The finite headroom matrix is:

| Operation | Exact allowed head | One-over refusal head |
| --- | ---: | ---: |
| Fresh primary | 1017 | 1018 |
| Primary ASK release | 1018 | 1019 |
| Fresh reply | 1020 | 1021 |
| Reply ASK release | 1021 | 1022 |

The exact cases finish the full permitted flow at head 1024; one-over cases
refuse before append, release or native work. Identity replay remains allowed
at the cap. `test "full CheckedCommand resource snapshots reserve capacity
before input admission"` uses public checked operations and metadata-aware
projections: Conversation representations fit, but the complete retained
CheckedCommand snapshot, metadata and CAS revision exceed 65,536 bytes, so a
real signed primary is refused before append. The runtime slot proof permits
64 messages and two associations and refuses the 65th message. Association
capacity is coupled to message capacity because each association references a
message; this is not an independent 64-messages-plus-one-association proof.

The signed raw-body boundary accepts 65,536 bytes and rejects 65,537;
4,096-byte reply text is allowed and 4,097 is refused. A real unrelated
CheckedCommand resource mutation after association blocks native delivery and
hashing while preserving the original Run/Attempt. Oversized source head 4,097
and row 1,048,577 fail closed before event delivery. The source-fault matrix
uses the public `:read` callback, not `:read_at`, to distinguish unavailable
evidence from a confirmed gap.

The native-recovery cuts preserve original identities and never retry
accepted work after uncertain input. Full restart after active-wait expiry
preserves the occurrence and emits one stable expiry wake with no hash. The
answer-uncertainty test now reads the primary ACK while the answer is still
unconfirmed; an actual early primary ACK is observable as `:acked` and fails
that pending-source assertion.

### Executed evidence and remaining gates

The disposable target preflight reported PostgreSQL 16.15 and vector 0.8.7.
The demo passed and cleaned up: the v1 trace completed two Runs/four messages;
the v2 trace completed two Runs/six messages at revision 10 with two reply
rounds, ordered ACKs and read-only replay/GET checks.

The final root pair, `MIX_ENV=test mix test test/wave4_channel_test.exs
test/wave4_command_conversation_test.exs --seed 0`, reported 76 passed in
431.2 seconds at checkpoint `200d0de3`. That run preceded the added control-7
pending-ACK assertion; the strengthened recovery test then passed alone
(`1 passed, 67 excluded`). The root pair was not repeated after this
test-only assertion.

Seven temporary worktree controls failed their intended assertions with exit
2. Every restore matched the same source SHA-256
`584f3b269c49c805972cb2dab1d1df127c5653f797e6be4f08d00ebf6734c869`, and each
restored focused test passed (`1 passed, 67 excluded`).

| Control | Intended failure evidence |
| --- | --- |
| Premature hash on wait wake | The durable waiting-view assertion received `{:error, :unavailable}` instead of a waiting view. This failed before the explicit hash-call assertion; it demonstrates lost durable waiting, not a separately observed hash-counter failure. |
| Reset reply cursor | `wait.cursor == head_before.revision` failed (0 versus 2). |
| Fabricated pairing | A mismatched association handle returned an event instead of `{:error, :unavailable}`. |
| Fabricated accepted-event key | Native reply was refused as `{:unknown, :native_reply}` instead of applied. |
| Primary ACK before reply ACK | The primary disappeared from the pending outbox before the reply ACK. This control occurs after answer creation; control 7 covers the earlier answer boundary. |
| Synthesized answer | The final answer failed the retained-reply-hash assertion. Two malformed draft mutations (unresolved helper reference; delimiter error) were excluded and not counted. |
| Primary ACK at answer entry | An actual `Outbox.ack` at `append_answer/1` entry made public `:read_ack` report `:acked` where the new pre-confirmation assertion requires `:pending`. |

These are finite controls, not universal guarantees. No affected/full gate,
independent review, exact-head hosted check, merge-queue result or main-branch
outcome is recorded here. Those release gates remain required; no future gate
counts are predicted. This evidence does not claim overall Wave 4 completion.
