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
owner and test namespaces are renamed. The only runtime addition is
`release_approved`, with a minimal private waiting-result translation that
preserves `dispatch_approved`. No Cure source or ready dependency is changed.

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
`limits/0`, `classify_attempt/2` and `outcome?/1`. `command/2` accepts exact
atom-keyed maps with `kind`, `run_id`, `expected_revision` and, except `create`,
`attempt_id`:

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
durable settlement. `DOWN` is death, never completion. Restoration creates no
Attempt. Stale cancellation does not cancel a newer Attempt. Completion needs
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
success. A previous released reply is not a reusable permit. An old expected
revision conflicts; read current status and supply fresh context. Stale Attempt
and terminal classification precede revision conflict. Unknown/wrong-Attempt
requests refuse `unknown_request`; malformed commands retain `invalid_command`.
Ready Approval refusal/error reasons remain intact, including revocation and
authority failures. Genuine ALLOW is not an ASK request.

Result families remain `{:ok, revision, result}`, `{:unchanged, reason, revision}`,
`{:refused, reason}`, `{:error, reason}`, `{:indeterminate, receipt}`. An uncertain
append stops ownership. Host confirms/fences outstanding writes before
replacement, passing the receipt as existing `reconcile:`. Missing rows alone
cannot prove non-commit. Recovery replays events, then revalidates any existing
release; it never consumes again or dispatches. Rejected appends grant nothing.

Release invokes no EffectIntent startup/admission/advance/observe/rearm, host
activation, Adapter, Task.Supervisor, provider operation or send. It does not
claim that no earlier/delayed send exists. Explicit `dispatch_approved` retains
its original send behavior: trusted callers must choose the correct dispatch
owner. This is not a BEAM security boundary against invoking the wrong API.

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
authority cases must fail before restoration. These finite scenarios are tests,
not universal no-send/durability/cancellation proofs or production monitoring.
Approval owns its unchanged pure laws; no new law is claimed here.

- **Needs:** authenticated caller/approver evidence and fresh policy/authority;
  canonical arguments and exact descriptor binding; host serialization of
  cancellation/admission/dispatch; exclusive owners, trusted clocks, supervision,
  durable PostgreSQL settings, full history retention, confirmation and physical
  fencing of old owners/outstanding writes/providers; authenticated settlement.
- **Telemetry:** inherited OTP diagnostics; consumer redacts, no exporter or
  payload telemetry. **Config:** retained construction-only bindings, no new
  options/hot changes. **Control:** inherited commands plus release-only, with
  the precise commit/no-send meaning above.
- **Upstream:** pinned Elixir 1.20.4 / OTP 29.1.2 serialization, monitoring,
  deterministic safe ETF and crypto; unchanged ready dependency Contracts.
- **Bounds:** individual events at most 128 KiB; Run identifiers at most 200 UTF-8
  bytes without NUL, provider refs at most 64; retained intent arguments at most
  64 KiB; ready Approval/EffectIntent bounds unchanged. Complete guarded history
  is retained, with no aggregate history/memory bound. Memory remains volatile.
- **Not supplied:** an engine, scheduler, provider authentication, physical
  cancellation, exactly-once send, generic dispatcher, audit/outbox composition,
  universal proofs, cross-stream transaction or transferable authorization.
