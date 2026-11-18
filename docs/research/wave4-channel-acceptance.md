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
| Signed ingress, scope/header checks, identity/revision conflicts and happy path | `WebhookIn.call/2`; `admit/3`, `advance/1`, `view/2`; `CheckedCommand.result/3` | `HTTP and read guards return fixed statuses without mutation`, `retained identities reach CheckedCommand conflicts while deadline survives reopen`, and `signed loopback processes two distinct inputs and replays the first`: fixed refusals; changed bytes/resource/revision conflict; original IDs survive; two completed Runs/four messages and replay preserves view/head | Real signed requests, duplicate/malformed header and scope controls, retained identity conflicts; no fake owner, answer or dispatcher |
| Denial, busy/capacity refusal and read-only GET failures | `admit/3`; `view/2`; `CheckedCommand.resource/3`; `Conversation.view/2` | `input gate and policy denials retain refusal without resource, outbox, or native work`, `admission callback exceptions and exits return fixed errors without writes`, `committed input reply loss stays fenced through read outage until identity confirmation`, `future capacity accounts for the association and answer before input admission`, `GET reports not_recorded only for the known pre-creation phase`, and both `GET fails closed` cases: refusals leave state unchanged; unavailable/mismatched owners return fixed unavailable; only the known pre-creation phase is `not_recorded` | Gate/policy/callback denials, an unfinished-input busy refusal, capacity boundary, unavailable Run owner and mismatched native operation; GET changes no command head or Outbox |
| Unknown association | `advance/1`; `RunApprovalRelease.status/2`; retained `CheckedCommand.result/3` | `association reply loss stays fenced with zero native allocation until confirmation`: no Run/Unit/hash before matching association confirmation; original input remains retained | Real association reply loss plus command-store read outage; pending confirmation is not treated as commit |
| ASK, stale/revoked approval evidence and release | `admit/3`, `release/4`, `advance/1`; retained `CheckedCommand.result/3` | `ASK survives reopen and releases only once with fresh command evidence` and `initial ASK reply loss recovers the same pending requirement after a read outage`: wrong request, changed policy, revoked/self/stale/expired evidence does not release; original requirement/key stays pending; valid command-purpose evidence releases once | ASK append reply loss/read outage; paused SQL RELEASE cannot be reconciled from the earlier ASK receipt, and new intake/re-release stays fenced until the writer is finished |
| Uncertain input/answer and live-writer fencing | `advance/1`; original input/answer identity confirmation | `committed input reply loss stays fenced through read outage until identity confirmation`, `paused input writer is not treated as non-commit and stays fenced until it exits`, `committed answer reply loss reconciles without rerunning native work or replacing the answer`, and `native input append remains live and unresolved until its PostgreSQL writer is released`: unknown remains fenced until original identity confirmation; no replacement work or duplicate answer | Real append reply loss, unavailable reads and PostgreSQL writer barriers; a paused writer is positively released/observed before reopen |
| Run/Attempt/input/startup, reopen cuts and local restart | `advance/1`; `RunApprovalRelease.status/2`; `RunEngine.result/3` | `Run creation and Attempt reply loss retain identities without early native allocation`, `partial Engine startup is fenced and cleaned before reopening the same Attempt`, `fenced reopen recovers association, native result, and answer without replacement work`, `uncertain native input stays fenced until safe reopen and original-ID confirmation`, and `volatile local work is recorded as terminal loss after fenced reopen`: same identities survive the three cuts; no second Run/Attempt/hash; local work is `local_restart` with no answer | Real Run/Attempt append loss, native read loss and partial start; predecessor task/native trees are fenced before same-identity reopen |
| Authoritative result unavailable | `advance/1`; `RunEngine.result/3`; `view/2`; `CheckedCommand.resource/3` | `unavailable authoritative result reader cannot append an answer or acknowledge`: advance is pending, resource and Outbox remain unchanged, and GET contains no assistant message until the original result is readable | Injected evidence-store read unavailability after actual native completion |
| Original-nonce ack unknown, malformed and superseded outcomes | `advance/1`; `Outbox.ack/3`; `DurableLog.confirm_ack/2` | `ack reply loss is positively confirmed by the original canonical key and nonce`, `ack rollback remains fenced and reopens directly from the retained answer`, and `a different nonce winning the original ack key reports conflict and retains host poison`: same key/nonce confirms; rollback/read-unavailable/malformed stays `{:unknown, :ack}`; a winning different nonce returns `{:blocked, :ack_superseded}` and preserves poison/state | Real ack reply loss/rollback, `read_ack` unavailable/malformed results and a competing committed nonce |
| Ack uncertainty, stale Registry entries and reopen | `advance/1`; original-key confirmation; fixture teardown | A committed canonical ack is acknowledged after native PIDs are dead even while real Registry workers retain stale dead-PID entries; reopen keeps original Run/Attempt identities | Real Registry partition workers are suspended at a quiescent post-answer boundary and resumed in `try/after`; live owners/unavailable reads remain failures; bounded cleanup waits are outside `advance/1` |
| Controlled terminal commands | `RunApprovalRelease.command/2`; `advance/1` | `cancelled real native work produces no answer and is fenced before ack`, `out-of-budget real native work produces no answer and is fenced before ack`, and `out-of-time real native work produces no answer and is fenced before ack`: the original-key ack is retained; no assistant answer, second Run/Attempt or additional hash is produced, and the task is dead after fencing | A delegated real-hash barrier holds work after invocation; authoritative terminal commands are issued at quiescent boundaries |

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

The focused acceptance command was
`mix test test/wave4_channel_test.exs test/wave4_command_conversation_test.exs`:
**31 channel + 8 companion tests = 39 passed**, with no excluded or skipped
tests in that run. The changed-file format check, `MIX_ENV=test mix compile
--test` and `git diff --check` exited 0; compile reported that Cure sources
were unchanged and skipped 54 modules. The finite demo exited 0 with the
cleanup trace above.

The existing source-read allowlist guard
`python3 scripts/test-ci-change-class.py AllowlistGuard.test_no_source_reads_a_documentation_file_unreviewed`
also exited 0:

```text
Ran 1 test in 1.050s

OK
```

Both intended temporary negative controls ran in the real worktree and failed
at their existing assertions, not at setup or compilation:

1. The association control made the unknown-association branch allocate a real
   Run. `mix test test/wave4_channel_test.exs:927` exited 2 (`0/1 passed,
   30 excluded`): the zero-Run assertion received `{:ok, ...}` from
   `RunApprovalRelease.status/2` instead of `{:error, :not_found}`.
2. The result control substituted a correctly shaped `{:ok, dto}` completed
   result with matching Run/operation/Attempt/action/schema identity and an
   answer equal to the expected hash. `mix test
   test/wave4_channel_test.exs:1822` exited 2 (`0/1 passed, 30 excluded`): the
   existing `assert {:pending, _reason} = advance(host)` received
   `{:result, :completed}`.

Each temporary source mutation was restored byte-for-byte (`cmp` succeeded).
The original host source hash before and after restoration was
`edab2347d551601df48a953d73f82400b296a2d1bfda7bccdb754dd6e7e203a5`; neither
mutation was committed. These controls show the named assertions detect those
specific failures; they are not universal guarantees.

This report covers the bounded ELZ-258 acceptance only. Level 4
activation/replay/retention/gap Contract work remains unpublished. No streaming,
provider-authentication, broker, subscriber-cursor or overall Wave 4 completion
claim is made. The full/affected gate and hosted results are not recorded here.
