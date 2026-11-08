# ELZ-011 owner decision packet after early review

Status: awaiting root decision; no Contract amendment or production implementation.
The independent review at `0716e36865782847a9a786aa9d4ac28c7b1c5766` is
**NOT CLEAR as written**, not implementation permission. Reviewer session
`0f974e4c-75e1-4daf-9a19-7720ad2b1633`, dispatch `ctx_4a3fb5dd7ad9`.
Full findings/evidence/limits: [review](ELZ-011-early-review.md).

## Exact Contract decision

Recommend D1, D2 and D5 as reviewed and D3 option A (thin declaration over an
Envelope command); option B would defer core/effect and is not the proposed
patch. The complete proposed after body is [here](ELZ-011-contract-proposed.md);
the exact before/after diff is [here](ELZ-011-contract-proposed.patch).
The task and live issue remain unchanged. If approved, post that exact diff on
#11 before editing its body, then synchronize task/body and the scoped roadmap
hash. No implementation until the focused reviewer clears the amended proposal.

D1 adds ELZ-013 and ELZ-023 dependencies; D2 selects the bounded publication and
makes excluded grounds, cancellation and recovery explicit; D3 adds only the
three declaration fields, reusing Envelope; D5 appends four acceptance bullets.
The assembly must consume the declaration at admission, deriving its identity
and arguments from it; it cannot remain an unused catalogue wrapper.

## D4 recommended freeze for root approval

The following tables are the reviewer's proposed replacement for the proposal's
incomplete tables. Adopt H1-H4 and M1-M8 as production gates, subject to the
explicit clarifications below. These are recommendations awaiting approval;
they do not silently amend the original proposal or certify feasibility.

### Binding failure map


| Tag | Result triple (outcome, dispatch, class) | Attested no-send | Owner event |
| --- | --- | --- | --- |
| `:preflight_unavailable` | timed_out, not_dispatched, unavailable | yes | NoSend, then rearm allowed |
| `:request_rejected` | rejected, not_dispatched, permanent | yes | PermanentNoSend, disarmed |
| `:http_4xx` | failed, dispatched, permanent | no | Failed, then poll |
| `:http_5xx` | failed, dispatched, retryable | no | Failed, then poll |
| `:http_redirect` | failed, dispatched, unclassified | no | Failed, then poll |
| `:not_acknowledged` (2xx, `ack=false`) | unknown, dispatched, unclassified | no | Lost, then poll |
| `:receipt_invalid` (2xx, bad bytes/encoding/oversize) | unknown, dispatched, unclassified | no | Lost, then poll |
| `:transport_timeout` | timed_out, unknown, retryable | no | TimedOut, then poll |
| `:transport_error` (reset, refused, inner task killed) | unknown, unknown, unavailable | no | Lost, then poll |

A valid 2xx receipt with `ack=true` returns the completed Envelope. A receipt with a wrong key or digest, or a bad MAC, also returns an Envelope; `validate_result/authenticate` refuse it and the owner retains a bounded `Refused` summary. Poll results: 2xx `ack=true` is a completed Envelope; `ack=false` is `{:pending, _}`; 404, 5xx and transport errors are `{:unavailable, _}`.

## Proposed frozen job table (runner `perform/1`)

Pre-step on every wake-up: resolve owner; check `status.key` equals the job key; check `status.active`; call `advance(:expire)`; reread status.

| Condition | Action | Oban return |
| --- | --- | --- |
| Resolver error, exit, key mismatch, `active: false` (read-only or halted) | no send | `{:error, :owner_unavailable}` (uses an attempt and `backoff/1`, so it is bounded) |
| Phase Intended | `advance(:dispatch)`: `{:ok, :dispatched}` | `{:snooze, first_poll_delay}` (at least total + 1 s) |
| Phase Intended and `{:error, :not_dispatchable}` | none | `{:cancel, :not_dispatchable}` |
| Phase Dispatched | `advance(:poll)`: `{:ok, :polling}` | `{:snooze, poll_delay}` |
| Phase Dispatched and `{:error, :task_start}` | none | `{:snooze, poll_delay}` |
| Phase Definite, `flags.disarmed` or `quarantined` | none | `{:cancel, :operator_required}` |
| Phase Definite, persisted attempts below host maximum | `advance(:rearm)`: `{:ok, :Stop}` | `{:snooze, 1}` |
| Phase Definite and `{:error, :not_rearmable}`, or attempts at maximum | none | `{:cancel, :exhausted}` |
| Phase Confirmed | none | `:ok` |
| Phase Stranded | none | `{:cancel, :operator_required}` |
| Any other control error or timeout | none, never a send | `{:error, tag}` |

Host re-wake after reconciliation uses the existing job (for example `Oban.retry_job/2`). I did not verify which Oban states `retry_job` accepts. The implementer must test it with real Oban, because the unique rule blocks a second insert of the same key.


### Clarifications and implementation gates

1. Delete the proposal sentence permitting final authenticated no-effect poll
   evidence. `authenticate/2` rejects `:no_effect` and `:unknown_to_provider`;
   404 is unavailable, never ProviderUnknown or a no-effect ground. All other
   unsuccessful poll status/schema/transport cases become unavailable or a
   refused completed observation, never a new ground. A 202 requires the same
   valid authenticated completed receipt as other 2xx; otherwise it is pending
   or invalid by the table. 401/403/409/422/429 use http_4xx. Unsupported content
   encoding is invalid. Wrong key/digest/MAC reaches owner refusal only through
   a structurally valid completed Envelope; malformed bytes use receipt_invalid.
2. Make the runner table exhaustive over validated snapshots and all replies:
   check quarantined before any dispatch/rearm, enforce the persisted maximum
   in Intended as well as Definite, and cancel disarmed states. Every status,
   expiry and action call is bounded and catches exits; unknown replies fail
   closed using a fixed error tag. The pre-step handles expire error/timeout
   before continuing. No private deadline/state inspection. A timed-out call
   may still complete in the owner: never interpret caller-task shutdown as
   cancellation of that operation. Subsequent wake-ups reread the owner.
3. First scheduled poll delay is at least ceil(total_ms/1000)+1 seconds;
   task_start is a wait and never a ground. Require finite recovery grace and
   ceil(recovery_grace_ms/poll_delay_ms) <=512. This arithmetic alone does NOT
   cap concurrent/rescued wakes or the interval before admission deadline;
   prove the actual bound in composition probes or keep saturation and host
   scheduling limits explicit. Do not claim grace/delay alone proves capacity.
   The host must continue expiry/reconciliation if a job exhausts or is
   cancelled while the intent remains Dispatched. Test real Oban re-wake of
   the existing unique job, including allowed states; do not fabricate a new
   operation or silently delete uniqueness history.
4. Req runs in an inner supervised caller with Task.yield and shutdown at an
   explicit total bound; request lifetime, control-call bound and observer
   bound are separate. Bound child capacity and cleanup on success/error/kill;
   a killed HTTP task does not retract network transmission. A timeout or
   exit after entering Req is always unknown, never preflight no-send. Test
   slow-drip and removal of the actual timer, including hung authenticator or
   request preparation where included in the claimed total lifetime.
5. No-send tags are only truthful typed returns before Req invocation;
   unexpected exceptions/exits remain unknown. Fixed origin identity belongs
   in provider_account and remains stable across recovery; use only the
   owner-derived 64-hex key in the URL and Oban key. The host authenticator
   is trusted configuration; fixture HMAC binds key/digest/status. Test forged
   MACs. DNS/TLS/provider behavior remain Needs, not loopback proof.
6. Validate raw bytes before normalizing: pre-decode byte cap, string keys,
   explicit duplicate-key rejection, numeric/schema/depth/node bounds and
   content encoding checks. Prove duplicate rejection against the selected
   JSON API before choosing an implementation; do not implement a new general
   JSON parser. Mutate real normalization functions for atomization, trust,
   retention and ack guessing; hand-built wrong maps are not mutation tests.
7. Invoke observer only from job caller, catch exceptions; bound a hanging
   observer or name its liveness Need explicitly. Cancellation reports the
   actual upstream count, including zero, and unknown external outcome.
8. Reproduce the reviewer probes against the actual pinned source, then add
   reduced probes for remaining public API/Oban/timeout seams before production.
   Frozen tables are requirements, not proof that every row already works.
   Verify proposed triples against Envelope's valid matrix and Binding checker.

## Evidence status

Reviewer reproduced 14 probe tests, verified hashes and kept the worktree clean.
Their owner probe used Memory, not PostgreSQL; Oban state claims were from docs
and need pinned-source plus real-DB verification. No full mix check or production
Cure proof exists for this proposal. All high/medium findings remain tracked
until the revised proposal/probes receive explicit focused clearance. Root's
ELZ-023 main CI retry and cleanup remain independent pending work.
