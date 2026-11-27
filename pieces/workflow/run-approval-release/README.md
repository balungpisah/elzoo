# workflow/run-approval-release — Run with durable approval release

`Elzoo.RunApprovalRelease` is an explicit source variant of `Elzoo.Run`, not a
wrapper, separate approval owner or engine. A live Run stream belongs to **one**
of these owners, never both. Old `workflow/run` remains unchanged; no migration,
live substitution or ownership handoff is supplied.

## Source provenance and inherited Contract

Copied from repository baseline `2b3c3fc763eb8eef0d4d4cfbe694098ea83de217`:
`pieces/workflow/run/lib/elzoo/run.ex`, `test/elzoo/run_test.exs`,
`test/support/run_test_helper.exs` and `examples/run.exs` under that Piece.
The owner runtime last changed in `d4320d49f3a66e23c8b3adc9941df295bec748bd`;
the copied helper includes the later sibling-first SQL-helper repair. Public
owner and test namespaces are renamed. The runtime additions are
`release_approved`, with a minimal private waiting-result translation that
preserves `dispatch_approved`, `renew/2` with its `expected_revision` rule
(ELZ-422, see Lease renewal) and the `renewed_since` field of `status/2`
(ELZ-429, same section). No Cure source or ready dependency is changed.

Construct the guarded Store with this variant's `fold/0` and `limits/0`, create
its ready Lease, claim the stream, and start:

```elixir
Elzoo.RunApprovalRelease.start_link(
  store: store, lease: lease, held: held,
  effect_intent: %{}
)
```

The existing `effect_intent` reference-to-startup-options map is required but
may be empty for release-only callers. That command does not consult it.
Retained Run-owned dispatch needs its original Store/binding/clock/host/task
options. No new construction option or runtime binding lookup is introduced.

Inherited public functions are `start_link/1`, `command/2`, `status/2`, `fold/0`,
`limits/0`, `classify_attempt/2` and `outcome?/1`; `renew/2` is new (see Lease
renewal). `command/2` accepts exact atom-keyed maps with `kind`, `run_id`,
`expected_revision` and, except `create`, `attempt_id`:

| Kind | Other fields |
| --- | --- |
| `create` | `operation_id`, `provider_refs` |
| `begin_attempt` | none |
| `attach_child` | `child_run_id`, `child_pid` |
| `child_result` | `child_run_id`, `child_completion_revision` |
| `complete` | `outcome`, `reason`, `evidence_ref` |
| `cancel` | none |
| `approval_request` | ready Authorization ASK `decision` |
| `approval_evidence` | `request_key`, `evidence` or `revoked_evidence_key` |
| `dispatch_approved` | `request_key`, current trusted `context`, `intent` |
| `effect_result` | `action_id`, `intent_key`, committed `evidence_ref` |
| `release_approved` | `request_key`, current trusted `context`; **no intent** |

The inherited serialized lifecycle preserves stable Run/operation/provider
identity, explicit execution Attempts, reciprocal atomic child attachment and
durable settlement. `DOWN` is death, never completion.
`dead` is best effort: no pid is stored, so a death is not recorded when the
owner restarts before or while the child ends, or when its write is fenced or
rejected. A death whose write failed with an error is kept in the process and
written after the next command, whether that command is applied, unchanged
or refused; when the command's own write is indeterminate, the owner stops
first and the kept death is lost. `status` writes nothing.
Restoration creates no Attempt. Stale cancellation does not cancel a newer Attempt. Completion needs
authenticated committed evidence correlating Run, operation, Attempt and action.
The five immutable outcomes remain `completed`, `failed`, `cancelled`,
`out_of_budget`, `out_of_time`; waiting/paused are not outcomes.

The retained dispatch route records its exact action-to-intent binding, commits
approval before admission and never resends/rearms a reserved intent. Unknown
effects remain separate from terminal Run outcomes, including late settlement.
An intent retains all five identity fields, canonical arguments, binding
reference/digest and deadline. Changed bindings cannot replace a recorded key.
`effect_result` applies only to these existing Run-bound effects, not external
Resource effects. Status is redacted inspection, never authority to dispatch.

## Release without dispatch

```elixir
Elzoo.RunApprovalRelease.command(owner, %{
  kind: :release_approved, run_id: run_id, attempt_id: attempt_id,
  expected_revision: revision, request_key: full_request_key,
  context: fresh_trusted_approval_context
})
```

The full ready Approval key binds normalized action, writes, policy and
requirement. The request must belong to this Run's current Attempt. Stored fresh
evidence passes ready Approval's release gates unchanged; without it,
`select_retained/3` must actually select consent. Missing consent returns
`{:ok, revision, %{approval: :waiting, request_key: key}}`, not permission.
First release commits the existing approval release/once-consumption event
before returning `{:ok, revision, %{approval: :released, request_key: key}}`.
There is no new state field, event, consent format, store or outbox.

Every existing release calls `Approval.revalidate/3` with current trusted
context. There is no cached duplicate-success path; `already_released` is never
success. A previous released reply is not a reusable permit. An expected
revision outside the accepted range (see Lease renewal) conflicts; read current
status and supply fresh context. Stale Attempt and terminal classification
precede revision conflict. Unknown/wrong-Attempt requests refuse
`unknown_request`; malformed commands retain `invalid_command`.
Ready Approval refusal/error reasons remain intact, including revocation and
authority failures. Genuine ALLOW is not an ASK request.

Result families remain `{:ok, revision, result}`, `{:unchanged, reason, revision}`,
`{:refused, reason}`, `{:error, reason}`, `{:indeterminate, receipt}`. An uncertain
append stops ownership. Host confirms/fences outstanding writes before
replacement, passing the receipt as existing `reconcile:`. Missing rows alone
cannot prove non-commit. Recovery replays events, then revalidates any existing
release; it never consumes again or dispatches. Rejected appends grant nothing.
`renew/2` has its own results, listed under Lease renewal.

Release invokes no EffectIntent startup/admission/advance/observe/rearm, host
activation, Adapter, Task.Supervisor, provider operation or send. It does not
claim that no earlier/delayed send exists. Explicit `dispatch_approved` retains
its original send behavior: trusted callers must choose the correct dispatch
owner. This is not a BEAM security boundary against invoking the wrong API.

## Lease renewal

`Elzoo.RunApprovalRelease.renew(owner, ttl_ms)` (ELZ-422) renews the held lease
inside the live owner, between two commands and never during one. The owner
calls `Elzoo.Lease.renew(lease, held.owner, [stream], ttl_ms)` with its own
Lease, owner attribution and stream; `ttl_ms` has the Lease bounds
`1..86_400_000`. Like `command/2`, the call waits at most 5,000 ms; a caller
timeout is not an outcome, and the host treats that renewal as unconfirmed.

| Lease result for the stream | Reply | Owner |
| --- | --- | --- |
| held, at the held revision + 1 | `{:ok, revision, %{until: until}}` | installs the token before it handles any later call; `until` is the token's `live.until` (lease clock, Unix microseconds) |
| held, at a later revision | `{:refused, {:fenced, %{expected: e, observed: o}}}` | another writer appended rows that the model never read; the renewal committed but its token is not installed; stops with `{:shutdown, {:fenced, %{expected: e, observed: o}}}` |
| refused, for example `:stale`, `:free`, `:not_holder`, `:ambiguous` or `:regression` | `{:refused, {:lease_lost, refusal}}` | the lease is lost; stops with `{:shutdown, {:lease_lost, refusal}}` |
| `{:indeterminate, receipt}` | the same | stops with `{:shutdown, {:indeterminate, receipt}}`, as after an uncertain command write; the host confirms the receipt (existing `reconcile:`) and fences before a replacement |
| a definite no-write error | `{:error, reason}` | keeps its token and keeps working; the lease stays as it was until its `until`, and the host may retry or stop admission |
| any other error or result, including a token without the owner's attribution, its stream, or integer `revision`, `at` and `until`, or one at or below the held revision | `{:unknown, :no_receipt}` | stops with `{:shutdown, {:unknown, :no_receipt}}` |

`e` and `o` have the meaning of the fence of `Elzoo.Lease.write/4`: `e` is the
held revision and `o` is the head that the renewal appended after (the renewed
revision - 1). The definite no-write errors are `{:invalid, _}` (for example
`ttl_ms`), `:caller_transaction`, `{:schema, _}`, `{:rejected, _}`, PostgreSQL
`:contended` and `:unavailable` (that adapter reports them only before its
first write statement) and Memory `:clock_unavailable` and `:malformed` (before
its append). No other error proves that no renewal committed: the Memory
`{:error, :unavailable}` can follow a committed append whose reply was lost, and
it carries no nonce. The owner invents no receipt; after
`{:unknown, :no_receipt}` the host confirms backend and predecessor fencing and
reads the durable head before it opens a replacement. After any stop the owner
writes nothing more.

A renewal moves the head between a caller's `status/2` and its next command.
A command that reaches write admission (after the duplicate, stale-Attempt and
terminal classifications) accepts an `expected_revision` from the floor up to
the held revision. The floor is the held revision at startup and after every
successful Run append, including child, death and recovery writes, so only a
revision separated from the current one solely by renewals that this live
owner installed is accepted. Nothing is normalized across another writer or an
owner restart. Replies carry the current held revision, which `status/2`
reports. A renewal does not write kept deaths; they wait for the next command.

A renewal changes the held revision that `status/2` reports without any Run
transition. So `status/2` also reports `renewed_since` (ELZ-429): the revision of
the latest committed record of the stream, as this owner holds it, whose kind is
not `lease_renewed` (a Run record, or a `lease_claimed`, `lease_released` or
`lease_seized` record). Every revision after it, up to `revision`, is a renewal;
with no renewal since the last other record it equals `revision`. The owner
rebuilds it from the whole stream at startup, so a replacement started on the
token that renewals left reports the record before them, not its own floor; every
successful Run append (each append that moves the floor) moves it to the new
revision, and a renewal leaves it as it was. Like `revision` it belongs to the
whole stream: every Run of the owner reports the same value, a command of any of
them moves it, and it says nothing about rows that another writer appended. A
caller that last took revision `r` has seen only renewals since when
`renewed_since <= r < revision`; `assembly/run-engine` journals no Run view for
such an interval (ELZ-429).

## Resource caller and checked example

Before release, the host durably correlates the full ASK/action to the exact
Resource/EffectIntent descriptor, gate and budget facts. Admit the action using
RunResource; queued uses wait. Immediately before dispatch, serialize current
Run/Attempt/cancellation checks and call `release_approved` with fresh context.
Only a current released result proceeds to Resource's existing
`{:dispatch, identity, exact_effect_owner}` command. Resource renews, rechecks
FIFO/pause/deadline/closing and commits its reservation before advancing the
host-activated EffectIntent. Read-only stays read-only. Never also invoke Run's
`dispatch_approved` for that resource action. Resource is a test/example
dependency, not an import or dispatcher in the owner runtime.

`examples/run_approval_release.exs` executes this call sequence without a real
provider. Correlation, cancellation serialization and activation are host Needs,
not supplied by the example. No atomic release-and-resource transaction exists.
After a crash before dispatch, revalidate before a permitted first dispatch.
After reservation/send, reconcile Resource/EffectIntent; approval never permits
a second send. Host retains authenticated external outcomes independently of
Run termination; no approval is minted after terminal Run state for cleanup.
ALLOW-only Effects remain outside this ASK command.

## Named evidence and limits

`mix test pieces/workflow/run-approval-release/test` runs the nine copied Run
groups (31 baseline cases) plus six new groups: **Release without dispatch**,
**Waiting and retained consent**, **Release restart windows**, **Currentness and
authority change**, **Resource-owned send**, **Isolation, copy and checked
example**. They use disposable PostgreSQL, real ready Authorization/Approval,
Lease/Store, RunResource and EffectIntent, existing SQL fault seams and a counting
fake Adapter. Resource opening is a trusted-host fixture observation; the use
send and authenticated completion exercise the real intent owner. Process-call
tracing instruments real startup/activation/advance/observe/task/Adapter calls
for release-only commands; SQL replay checks persistence independently of replies.
Copy validation uses the existing consumer helper with this ID alone and with
both Run IDs selected. When old Run is co-installed, the isolation case operates
both owners on separate streams; it is not a dependency of a standalone copy.
Baseline source preservation is checked by diff, not a source-hash test.

Two temporary mutations of this new production owner bypass respectively the
release-event commit and existing-release revalidation; the named release and
authority cases must fail before restoration. Repair groups
`missing_evidence_is_refused`, `failed_death_write_is_kept` and `death_is_best_effort`
add finite cases; the Store fault seam gives only an indeterminate write, so a write
that fails with an error is made by a temporary change of the log table shape. Two
temporary mutations (the stored evidence condition and the kept deaths) fail their
groups, then are restored. These finite scenarios are tests,
not universal no-send/durability/cancellation proofs or production monitoring.
Approval owns its unchanged pure laws; no new law is claimed here.

Group `lease_renewal` (ELZ-422) adds thirteen finite cases: writes after a
renewal; the floor across renewals and Run, child and death writes; another
writer; an owner restart; a lease lost to another claimant and to expiry; a
renewal outside the owner; an indeterminate renewal after commit with its
receipt; a malformed renewal reply (a token without `until`, or none) after the
renewal committed; definite no-write errors (invalid `ttl_ms`, a changed table
shape, a PostgreSQL lock timeout); and commands after `status/2` reads while
another process renews, one of them with a renewal coordinated between its read
and its command. One case runs on the Memory Lease double: Memory clock and head
faults keep the token, then a renewal's Store append commits while its backend
is suspended, and the backend is killed before it replies. A temporary mutation
that keeps the old token after a renewal fails the write-after-renewal case
with `{:refused, :conflict}`; mutations of the floor reset, of the floor's
lower bound, of the next-revision check, of the Memory error classification
and of the token check each fail their case. All are restored.

Group `renewed_since` (ELZ-429) adds two finite cases on PostgreSQL: `status/2`
reports the revision of the latest record that is not a renewal, kept across
renewals and moved by a Run write on a revision from before them, by a child
attachment and by a death write, the same for every Run of the owner; and a new
owner reads it from the stream: after renewals a replacement reports the record
before them, after a release and a claim the claim (also after a later renewal and
a restart), and after a seize the seize. A temporary mutation that sets it from the
startup floor fails the second case, and one that counts Run records only fails it
at the claim; both are restored.

- **Needs:** authenticated caller/approver evidence and fresh policy/authority;
  canonical arguments and exact descriptor binding; host serialization of
  cancellation/admission/dispatch; exclusive owners, renewal through `renew/2`
  before the lease `until`, trusted clocks, supervision, durable PostgreSQL
  settings, full history retention, confirmation and physical fencing of old
  owners/outstanding writes/providers; authenticated settlement.
- **Telemetry:** inherited OTP diagnostics; consumer redacts, no exporter or
  payload telemetry. **Config:** retained construction-only bindings, no new
  options/hot changes. **Control:** inherited commands plus release-only, with
  the precise commit/no-send meaning above, `renew/2` and the `renewed_since` of
  `status/2` (Lease renewal).
- **Upstream:** pinned Elixir 1.20.4 / OTP 29.1.2 serialization, monitoring,
  deterministic safe ETF and crypto; unchanged ready dependency Contracts.
- **Bounds:** individual events at most 128 KiB; Run identifiers at most 200 UTF-8
  bytes without NUL, provider refs at most 64; retained intent arguments at most
  64 KiB; ready Approval/EffectIntent bounds unchanged. Complete guarded history
  is retained, with no aggregate history/memory bound. Memory remains volatile.
- **Not supplied:** an engine, scheduler, provider authentication, physical
  cancellation, exactly-once send, generic dispatcher, audit/outbox composition,
  universal proofs, cross-stream transaction or transferable authorization.

## Changes

- ELZ-422: new `renew/2` renews the held lease inside the live owner (Lease
  renewal); before it, a host could renew only outside the owner, which moved
  the head so that the owner's next write failed with `{:refused, :conflict}`.
  New `expected_revision` rule: a command that reaches write admission accepts
  the current held revision or one separated from it solely by renewals that
  this live owner installed since its startup or its last successful Run
  append; every other revision is still `{:refused, :conflict}`. Nothing
  breaks: without `renew/2` the floor is always the held revision, so every
  existing call behaves as before. No event, fold or stored format changes.
- ELZ-429: `status/2` also reports `renewed_since`, the revision of the latest
  committed record of the stream whose kind is not `lease_renewed`, rebuilt from
  the stream at startup and moved by every successful Run append (Lease renewal),
  so that a caller can tell renewals from Run transitions. Additive: every other
  field, command, result, event, fold and stored format is unchanged, and the
  owner reads no other rows than before. How to move: nothing, unless a caller
  matches the whole status map exactly; it then adds the key.
