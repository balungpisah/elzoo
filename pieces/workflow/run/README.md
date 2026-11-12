# workflow/run — Run and Attempt lifecycle

`Elzoo.Run` is a serialized, durable owner, not an engine or scheduler. A guarded
Store stream contains related Runs, reciprocal child links, approval events and
action-to-intent bindings. Provider references never identify or complete a Run.

## Boundary

Construct the Store using `Run.fold/0` and `Run.limits/0`. Create its ready
`Elzoo.Lease`, claim the stream, and supply:

```elixir
Elzoo.Run.start_link(
  store: store,
  lease: lease,
  held: held,
  effect_intent: %{"binding-reference" => existing_effect_intent_startup_options}
)
```

`held` is the current ready lease holder, not a model-supplied owner string.
The host supplies supervision and must fence previous Run owners and outstanding
writes before starting a replacement. Pass any indeterminate append receipt as
`reconcile:`; startup calls `Lease.confirm/2` and refuses unknown confirmation.
An absent row is not proof that an outstanding write cannot commit. Host fencing
is a Need, not something a read or this process establishes.

Startup replays the complete guarded stream before accepting commands. Pruned,
damaged or unavailable history fails closed. No local checkpoint/pruning or
second retention service is introduced. Keep the whole stream through the
duplicate and reconciliation horizons, including the latest lease record (the
ready `Lease.retention_bound/2` remains an upper bound, not permission to prune
Run history). Memory is volatile; use the PostgreSQL Store for durable Runs.

`command(owner, map)` accepts exact atom-keyed maps. Every command has `kind`,
`run_id`, `expected_revision`; all except `create` have `attempt_id`.

| Kind | Other fields |
| --- | --- |
| `create` | `operation_id`, `provider_refs` (text-to-text map) |
| `begin_attempt` | none |
| `attach_child` | `child_run_id`, `child_pid` (live pid or nil; never persisted) |
| `child_result` | `child_run_id`, `child_completion_revision` |
| `complete` | `outcome`, `reason` (redacted code or nil), `evidence_ref` |
| `cancel` | none; targets exactly this execution Attempt |
| `approval_request` | ready Authorization ASK `decision` |
| `approval_evidence` | full `request_key`, `evidence`; or `revoked_evidence_key` instead of `evidence` |
| `dispatch_approved` | `request_key`, fresh trusted Approval `context`, `intent` |
| `effect_result` | `action_id`, `intent_key`, authenticated committed `evidence_ref` |

Identifiers are exact nonempty UTF-8 text without NUL, up to 200 bytes for Run
inputs; provider references have at most 64 entries. Ready Approval and
EffectIntent fields retain their own validation/bounds. An intent is
`%{identity: [tenant, account, adapter, operation, request], arguments: canonical_bytes,
binding_ref: reference, deadline: unix_ms}`. Arguments are at most 64 KiB. The
record retains all five identity fields, arguments, deadline, binding reference
and descriptor digest before admission. A changed identity, argument or binding
cannot produce a replacement key. Construction-time binding lookup is not hot
configuration or permission to reinterpret a recorded reference.

Results are `{:ok, revision, result}`, `{:unchanged, :stale | :duplicate | :terminal,
revision}`, `{:refused, reason}`, `{:error, reason}` or `{:indeterminate, receipt}`.
Stale/duplicate classification precedes revision conflict. A current revision
conflict is refused and never retried. An indeterminate append replies with the
ready Store confirmation receipt and terminates ownership. Caller timeout is
unknown, never permission to repeat. Approval refusal/error reasons are retained
as results, not replaced with approval success.

`status(owner, run_id)` returns `{:ok, snapshot}` or `{:error, :not_found}`.
Snapshots contain the guarded revision, execution Attempt history/currentness,
outcome/evidence reference, reciprocal links, pending child settlements and
approval/effect classifications. They omit approval evidence, action arguments,
raw results, pids and dispatch authority. `classify_attempt/2` is pure and returns
`:current` only for equal valid identifiers with an existing current Attempt;
otherwise `:stale`. `outcome?/1` accepts only `:completed`, `:failed`, `:cancelled`,
`:out_of_budget`, `:out_of_time`. Waiting/paused are not outcomes.

## Durability and effects

Creation is nonterminal and has no Attempt. Explicit retry records a new
execution Attempt while keeping Run, operation and provider references.
Restoration creates no Attempt and dispatches nothing. Transport attempt numbers
remain EffectIntent's separate identity. Older/unknown results and cancellation
targets do not mutate the current execution.

Reciprocal attachment is one CAS event. A child's terminal event records its
completion revision and the parent's pending settlement atomically in the same
stream. Explicit `child_result` checks that durable terminal record and current
parent Attempt. Startup applies pending current-parent settlements, recovering
lost wakeups. `DOWN` records death only, never success. Child spawning remains a
host-dispatched Effect; an unknown spawn does not permit replacement or retry.

Completion requires a committed Store record, not process success or a bare
reference. Evidence references are `%{stream: text, sequence: integer}`. The
record's canonical ETF map must correlate `run_id`, `attempt_id`, `operation_id`
and `action_id`. Other terminal outcomes allow nil evidence. Terminal outcomes
are immutable; identical completion is duplicate, conflicting completion refused.

Approval is the ready pure reducer, with its full request keys and events.
Fresh evidence is stored unchanged, then released using `Approval.release/4`.
Without fresh evidence, `select_retained/3` must select consent, and release
checks that reviewer's current authority. Scope alone invents no consent.
Release/consumption/retained-consent state is committed before intent admission.
Recorded releases use only `Approval.revalidate/3` with current trusted context;
`already_released` never grants dispatch. Replay applies events, emitting no
approval writes. Revocation uses the ready reducer and remains durable.

Existing EffectIntent startup options supply its Store, binding, clock, task
supervisor, Adapter context and snapshot-bound host activation. Read-only startup
reports `:reconciliation_required`, sends nothing, and requires a host-authorized
replacement after reconciliation. An active clean zero-attempt snapshot may
dispatch once, after approval/deadline/schema checks. Pre-reservation deadline
expiry is recorded as `:not_sent/:expired` using the trusted clock; schema refusal
uses EffectIntent's durable disarm and records `:not_sent/:schema`. Neither is a
fabricated Adapter no-send certificate. Uncertain writes remain unknown.

A reserved intent is **never dispatched or rearmed again by Run**, even after
successful revalidation or renewed approval. Crash before task launch or after
send but before outcome retention remains `:unknown`. `:dispatched` means only
scheduling; status exposes an unsettled scheduled effect as unknown. Independent
host/provider reconciliation supplies an authenticated committed evidence map
correlating `run_id`, originating `attempt_id`, `action_id`, `intent_key` and
`classification: :settled`. Run retains its reference before acknowledgement.
This late evidence may settle the effect, never reopen a terminal Run or settle
a current wait. Unknown effects remain separately visible after cancellation or
time expiry. A delayed old task can still send after cancel, refusal or death:
no-new-dispatch is not no-send. There is no release/intent/transport transaction.

## Named evidence

`mix test pieces/workflow/run/test` exercises the nine task scenario groups on
a private disposable PostgreSQL Store. Real ready Approval and EffectIntent code,
the Store's recording/fault seam, snapshot-bound activation and a counting fake
Adapter exercise release, admission, reservation-before-launch and restart
windows. The checked example only requests completion with durable evidence.
The release-before-intent scenario is also run against a temporary production
mutation that bypasses the release barrier, then restored. These are finite
tests, not universal proofs; no new Cure law is claimed.

## Operations, Needs and limits

- **Telemetry:** inherited OTP process/task diagnostics; no exporter, payload
  telemetry or generic operational layer. The consumer must redact diagnostics.
- **Config:** supported, construction-time Store/lease/binding/host/clock/task
  bindings only; no defaults or hot options.
- **Control:** supported, the named commands above, with applied, unchanged,
  refused, failed and indeterminate results. Status grants no dispatch authority.
- **Needs:** authenticated host identities, evidence and current policy/authority;
  canonical arguments; durable Store and PostgreSQL settings; trusted clocks;
  supervision; retention; old-owner/provider fencing and reconciliation of all
  outstanding writes before activation. Test host grants simulate these Needs,
  not establish real authentication or physical-send fencing.
- **Upstream:** pinned Elixir 1.20.4 / OTP 29.1.2 serialization, monitoring, safe
  canonical ETF and crypto; ready Approval, Lease, Store and EffectIntent Contracts.
- **Not claimed:** an engine, scheduler, wait/pause policy, exactly-once physical
  sends, transport cancellation, provider authentication, universal time/storage
  proofs, per-command audit, cross-stream transactions or audited-lease outbox.

The stream is host-sized and retained whole; individual events are capped at
128 KiB by the Store and requests/evidence by ready Approval bounds. There is no
claim of constant memory or bounded aggregate history. Consumer-controlled
untrusted payloads must not be used as commands or stored authentication evidence.
