# ELZ-116 — Run and Attempt lifecycle with durable approvals

- Dependencies: ELZ-033, ELZ-010, ELZ-023, ELZ-024, ELZ-026, ELZ-028, ELZ-055, ELZ-009

## Responsibility and scope

Implement `workflow/run` for RC-50 and C2/C5/C6/C7. Own only `pieces/workflow/run/**` and its index/generated files under AGENTS.md section 3. Ready Pieces, shared runtime, dependencies, root tests and CI stay unchanged. Provider sessions are external references, never Run identity or completion evidence.

Implement only the named acceptance scenarios. Use upstream and repository facilities first; add no extra options, layers, behaviours, generic helpers or future hooks. Do not build RC-48's wait/pause policy, RC-50's engine, a scheduler or another mandatory host. Ask the coordinator before expanding scope. The independent reviewer must flag unnecessary abstractions and unrequested features for removal.

## Shared RC-12 / RC-48 boundary (identical in both tasks)

`workflow/run` owns Run identity, Attempt identity/currentness, reciprocal parent-child links, approval persistence and the sole terminal Run outcome set: `completed`, `failed`, `cancelled`, `out_of_budget`, `out_of_time`. A missing outcome means nonterminal; waiting and paused are phases, not outcomes. `completed` requires a committed completion record referencing durable evidence. `failed` may carry a reason such as retries exhausted or a refused required action; those reasons do not add Run outcomes. Action `unknown`, `late`, `expired`, `refused`, `resource_lost` and `retries_exhausted` remain action classifications, not alternate Run outcomes. In particular, an unknown external effect remains separately visible even if the Run later ends cancelled, failed or out of time; Run termination never asserts no effect occurred.

A Run keeps one current execution Attempt for its execution operation. A retry keeps the Run and operation identity and records a distinct Attempt ID before execution. Concurrent actions belong to that execution Attempt; an effect-intent's numbered transport attempt is a different identity and must not be used as the Run's Attempt. Only the serialized durable Run owner can replace the current execution Attempt. Restoration alone neither creates a new Attempt nor retries an action. A result names its originating Attempt; an older or unknown Attempt does not change the Run phase or settle a current wait. A cancel names exactly one execution Attempt; a stale or unknown target is unchanged, not a Run-wide cancel. An accepted current cancel suppresses new work and records cancellation without claiming that an already reserved external send was prevented. An indeterminate cancellation write stops the owner; recovery reconciles that write before further work. Terminal outcomes are immutable; duplicate completion and late evidence cannot reopen the Run. Independent effect reconciliation may retain late evidence without rewriting the Run outcome.

`workflow/bot-run-lifecycle` owns only phase, open waits, pause and continue. It uses `workflow/run`'s currentness classification and outcome validation rather than implementing either again. RC-50 invokes these boundaries and owns action dispatch/routing; it stores no second approval state or second restart protocol. RC-68/ELZ-114 owns action/input/outcome shapes, not Run outcomes. Approval requests and secret filling are engine work, never new pattern action kinds. Child-Run and outside-event waits remain accepted lifecycle data, but no v1 pattern action opens them. Wake has only recorded engine-read time and bypasses mid-run-message policy. A person's answer names one ask-person action and a host-verified person; no generic completed action outcome settles that ask, and text without an open ask is a new message.

## Command boundary

Expose `Elzoo.Run.start_link/1`, `command/2`, `status/2`, `classify_attempt/2` and `outcome?/1`. Startup takes Store, guarded stream, current lease holder and existing effect-intent startup bindings; replay before accepting commands. Use a serialized owner, not a registry, supervisor framework or new provider behaviour. The consumer supplies supervision and trusted inputs.

Command maps have `kind`, `run_id`, `expected_revision` (the guarded Store revision) and the fields below. IDs are exact nonempty UTF-8 text within Store/approval/intent bounds. Reject extra/malformed fields without echoing payloads. Identity/authority comes from the trusted host, never model/message text.

`provider_refs` is a map of text names to text references. `evidence_ref` identifies a committed Store record by stream and sequence; read it and check its Run/action correlation, rather than trusting a bare reference. `reason` is a redacted code or nil. Reuse ready Approval evidence/context/request-key and EffectIntent identity shapes.

| kind | Additional input and result meaning |
| --- | --- |
| `create` | `operation_id`, `provider_refs`; nonterminal, no Attempt. Identical creation is duplicate; conflicting identity refused. |
| `begin_attempt` | `attempt_id`; record before work, keeping operation/provider references. Current ID is duplicate, older ID stale. |
| `attach_child` | parent `attempt_id`, `child_run_id`, host-supplied `child_pid` (or nil if unavailable); record both sides atomically. Monitor a live pid without persisting it. Conflicting attachment is refused, identical attachment duplicate. |
| `child_result` | parent `attempt_id`, `child_run_id`, `child_completion_revision`; check attachment and durable child terminal record; settle once. |
| `complete` | `attempt_id`, `outcome`, `reason`, `evidence_ref`; shared terminal set only. Completed requires committed evidence; others allow nil. No inferred effect settlement. |
| `cancel` | `attempt_id`; records cancellation only for the current execution Attempt. No implicit cancel-all or transport-cancel API. |
| `approval_request` | `attempt_id`, existing Authorization ASK `decision`; calls ready `Approval.request/3`, retaining its event and full request key. |
| `approval_evidence` | `attempt_id`, `request_key`, `evidence`; stores the host-verified fresh evidence unchanged. Revocation uses the same command with `revoked_evidence_key` instead of `evidence`, calls ready `Approval.revoke/2` and persists its event. |
| `dispatch_approved` | `attempt_id`, `request_key`, fresh trusted Approval `context`, `intent` (five identity fields, canonical arguments, binding reference, admission deadline). Recovery must match recorded fields, not regenerate them. |
| `effect_result` | originating `attempt_id`, `action_id`, `intent_key`, authenticated `evidence_ref`; retain the correlated settlement supplied by the trusted host. Late evidence may update effect settlement, never a terminal Run outcome or current wait. |

Results: `{:ok, revision, result}` with identity/approval key/dispatch classification; `{:unchanged, :stale | :duplicate | :terminal, revision}` without writes; `{:refused, reason}`; `{:error, reason}`; or `{:indeterminate, info}` with ready Store confirmation information. Classify stale/duplicate first; a current command's revision mismatch is `{:refused, :conflict}`, never retried. Terminal Runs admit only separate effect evidence: identical completion is duplicate, conflicting completion refused.

Dispatch classifications: `waiting_approval`, `dispatched`, `not_sent`, `unknown`, `reconciliation_required`, `settled`, carrying action/intent references and reason/evidence reference. Scheduling is not completion; settled requires durable evidence. These are not Run outcomes or pattern kinds. Preserve approval refusal/error reasons. Indeterminate writes halt mutation; caller timeout is unknown, not repeat permission.

`status(owner, run_id)` returns `{:ok, snapshot}` or `{:error, reason}` (`not_found` included): revision, current Attempt, outcome/evidence reference, links, pending child settlements and approval/effect classifications; no secrets/raw results or dispatch permission. Pure `classify_attempt(current_id, supplied_id)` returns current only for equal valid IDs with a current Attempt, otherwise stale. `outcome?/1` accepts the five shared names.

## Persistence and restart protocol

Related lifecycle records share one guarded stream: reciprocal attachment and child-completion/pending-parent-settlement use one CAS append, not cross-stream transactions. DOWN records death, not success. Notifications are hints; replay pending settlements after lost wakeups. Spawn uses stable effect identity and a fake Adapter for the named scenario, not a scheduler; unknown never permits replacement.

Persist Run/Attempt/link/completion/cancel records, approval requests/evidence/revocations/releases and action-to-intent binding. Record all five intent identity fields, arguments and binding reference before admission. Replay emits no approval writes. Retain through duplicate/reconciliation horizons and respect lease retention bounds; no closures or new serialization/retention service.

1. **No release:** missing evidence/selected consent stays waiting. Stored fresh evidence goes to `Approval.release/4` for once/run/root. `:retained` requires `select_retained/3` and that reviewer's current authority; scope alone does not establish consent. Filtered retained evidence gives `no_retained_consent`, not fresh-evidence expiry/revocation reasons.
2. **Release barrier:** persist release, consumption and retained-consent state before intent admission. Uncertain append halts for confirmation/replay; absence never proves that a write did not commit. Recorded releases use only `Approval.revalidate/3` with fresh context. `already_released` grants nothing; refusal/error starts no new dispatch; `:ok` proves nothing about prior sends.
3. **Activation:** `EffectIntent.start_link/1` requires host snapshot-bound activation. Read-only reports `reconciliation_required`, sends nothing and needs host-started replacement after reconciliation. RC-12 cannot grant or activate in place; blocked is not not-sent.
4. **Zero attempts:** clean snapshot plus host fencing of old owners/pending writes, valid approval/deadline/schema permit one first dispatch. Pre-reservation expiry/schema refusal records `not_sent` (RC-50 maps to `expired`/`refused`). Inspection-only zero count is neither authority nor durable no-send evidence. Uncertain writes/history/scheduling mean unknown; no forged Adapter certificate.
5. **Reserved:** never redispatch/rearm, including after revalidation `:ok`. Crash before task launch or after send before outcome retention remains unknown. Reconcile through effect-intent, never a replacement action/key/retry. Expose confirmed evidence or unknown separately, with the same action/intent references for pattern and approver; renewed approval grants no resend.
6. **Settlement:** retain authenticated evidence before acknowledgement. Effect-intent has no result payload/notifications; host supplies evidence, RC-50 routes its sink. Scheduled old tasks can send after refusal/timeout/cancel/death: no-new-dispatch is not no-send. Host/provider fencing remains a Need; no atomic release/intent/transport transaction.

Reuse approval checks and effect-intent reservations/reconciliation unchanged. Source boundaries under `pieces/`: JobRun's unqualified cancel/late success differs (`workflow/state-machine/cure/elzoo/job_run.cure:8,70,106–110`); intent admission has zero attempts (`delivery/effect-intent/lib/elzoo/effect_intent/model.ex:82–108`), reservation precedes launch (`delivery/effect-intent/lib/elzoo/effect_intent.ex:180–186`) and task-start failure is unknown (`:275–278`).

Attribution is evidence/binding in the release append. Audit is session-only (`pieces/state/audit-log/README.md:35–41`); lease completion has no outbox (`pieces/state/lease/README.md:98–106`). Use pending settlement records for lost wakeups. No atomic release-plus-intent, per-command audit or outer Ecto transaction around Store/lease calls. Broader audited-lease composition needs coordinator admission.

## Named acceptance

1. **Restart/identity:** restore Run/Attempt/provider references; explicit retry changes only Attempt. Stale results/cancels and duplicate completion write nothing. Indeterminate cancellation stops ownership and is reconciled/reported unknown before work.
2. **Children:** atomic reciprocal attachment, monitored death without success, current durable completion applied once, old-parent-Attempt result ignored, lost wakeup recovered from log, unknown spawn/cancel without replacement or retry.
3. **Open approval:** restart without evidence remains waiting for every scope; replay emits no writes and invents no retained consent.
4. **Before release commit:** crash with stored fresh once/run/root evidence; release again, including expired/too-old refusal cases. Existing retained selection and indeterminate-append reconciliation follow protocol steps 1–2.
5. **Release before intent:** crash after release durability; revalidate, one intent/send, Store release precedes intent. Changed current provider/Adapter configuration creates no second key; recorded identity/arguments/binding survive.
6. **Zero attempts:** crash after admission; one first dispatch with valid approval/deadline/schema and fenced activation; expired/schema-refused paths record not-sent without reservation. Read-only startup sends nothing, reports reconciliation-required and continues only through a host-granted replacement. Exercise real reservation-before-launch code.
7. **Reserved/send windows:** crash before task launch after reservation, and after send before outcome retention; no second intent/send even with revalidation `:ok`. Reconcile or retain unknown without replacement. A delayed old task demonstrates no-new-dispatch is not no-send.
8. **Bypass matrix:** recorded release plus each of `policy_changed`, `requirement_changed`, `payload_changed`, `deny_at_release`, `approver_not_authorized`, `expired`, `evidence_too_old`, `revoked`, unavailable context, or erroneous repeat release returning `already_released`: no new dispatch. Test these reasons individually.
9. **Outcomes/example:** all five outcomes; process success without durable evidence cannot complete; unknown effects survive cancel/time expiry; late evidence never reopens Run. One checked example, no engine.

Scenarios 3–8 call real ready approval/effect-intent code with a recording Store, valid current context, host activation and a counting fake Adapter. Exercise restart/atomic append on a private disposable PostgreSQL Store; Memory remains volatile. Temporarily bypass release-before-intent and show its named scenario fails, then restore it. Pure currentness/terminal laws may use Cure; storage, native time comparisons, authentication, fencing and physical sends remain tested/upstream/Needs, not universal proofs.

## Delivery

Document Needs: authenticated identities/evidence/current context, host activation and old-owner fencing, durable Store, clocks, supervision and retention. Record Telemetry/Config/Control truthfully: inherited OTP diagnostics; construction-time bindings without hot options; named commands with applied/refused/failed/indeterminate results. No exporter or generic control layer.

Run Piece tests, `mix check --piece "$(git merge-base origin/main HEAD)"` and `git diff --check`; record commands/exits, scenarios, negative control and limits separately. One independent review checks task and diff. Coordinator merges serially: no other small-gate merge before RC-68's six-point proof; max three between covering green main runs. ELZ-116 may build alongside ELZ-114 after admission.
