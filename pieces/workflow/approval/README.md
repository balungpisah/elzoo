# workflow/approval

> **Stage 1 Contract draft (ELZ-024, issue #38).** No implementation exists yet.
> This file states the proposed Contract for early independent review. Nothing
> here is executed evidence. `piece.json` and the ledger row are added only with
> the implementation.

Pure consent record for one exact proposed action. It turns an ASK decision
from [`domain/authorization`](../../domain/authorization/README.md) into an
approval request, accepts host-verified evidence for exactly that request,
and releases the escrowed writes only when every release check passes against
**current** context. Approval never grants authority: the release
re-evaluates the authorization decision and the approver's own authority.

This Piece is **not** authentication, a verifier transport, a prompt UI, a
durable approval store, a shared Run schema, a security certification or an
identity guarantee. The state owner is the caller's Run (or other trusted
owner); this Piece supplies pure transitions over a caller-held state value.

## Preflight acknowledgments (docs/plans/preflight.md)

| Decision | How this Contract holds it |
| --- | --- |
| **B24.1** | The request binds the complete normalized action, the exact escrowed writes and the policy identity `(id, version, content_hash)`. Binding is compared structurally (`domain/authorization` equality), never by a digest. Binding data is kept for replay. |
| **B24.2** | Evidence is a separate, host-verified record; verifier allowlist; exact request tuple; explicit Unix-ms `now`, `issued_at`, `max_age`, `expiry`; revocation; revision/supersession; once/Run/root scope; release record and once-consumption marker in one transition; replay folds without re-emitting writes. |
| **B24.3** | Current proposer, approver and parent authority come from trusted context at release/restore, never from the request or evidence; release re-runs the authorization reducer; DENY or failure wins; approver must hold the exact writes and must not be the proposer; failures keep the three reason classes. |

## Request identity

A request is identified by the tuple
`{run, action_id, requirement_name, requirement_version, revision}`. All text
parts are nonempty UTF-8 with exact equality; `revision` is a positive integer.
The tuple proves no relationship between Runs.

```elixir
%{
  key: {run, action_id, req_name, req_version, revision},
  binding: %{action: normalized_action, escrowed: [write],
             policy: %{id:, version:, content_hash:}},
  requirement: %{name:, version:, scope: :once | :run | :root},
  proposer: text,
  status: :open | :released | :superseded
}
```

## State

```elixir
%{
  requests: %{key => request},                 # every revision, including superseded
  consents: %{evidence_key => consent},        # retained approved consent
  releases: %{key => release_record},          # completion keyed by full tuple
  consumed: MapSet of evidence_key,            # once-scope consumption markers
  revoked:  MapSet of evidence_key
}
# evidence_key = {verifier_id, evidence_id}
```

The state is a plain value held by the caller. This Piece performs no I/O and
reads no clock.

## Evidence record (B24.2)

Passed separately from any proposal. Only the trusted host's configured
verifier path may build it; the pure boundary cannot tell who built it.

```elixir
%{
  verifier: text,                 # configured verifier identity
  evidence_id: text,              # stable evidence identity
  reviewer: text,                 # approver identity
  request: {run, action_id, req_name, req_version, revision},
  decision: :approve | :reject,
  scope: :once | :run | :root,
  issued_at: non_neg_integer,     # Unix ms
  expiry: non_neg_integer         # Unix ms, required, > issued_at
}
```

Missing expiry, `expiry <= issued_at`, a non-integer or negative time, an
unknown key or a malformed field is `{:invalid_input, reason}`. There is no
implicit unbounded consent.

## Trusted release context

```elixir
%{
  now: non_neg_integer,              # Unix ms, supplied by the owner
  max_age: pos_integer,              # ms
  verifiers: [text],                 # allowlist (Config)
  run: %{id: text, root: text, ancestry: [text]},   # trusted caller context
  policy: policy_map,                # current trusted policy
  proposal: proposal_map,            # current action as it would dispatch now
  authority: %{own: [write], parent: [write] | :none},  # proposer, current
  approver: %{identity: text, authority: [write]}       # current
}
```

Missing or invalid context is `{:error, {:unavailable_context, reason}}`.

## Transitions

All return a new state and an event. The event is what the owner appends to
its own retained log; replay folds events back into state.

```elixir
Elzoo.Approval.new() :: state

Elzoo.Approval.request(state, run, decision)
  # decision: an ASK decision from Elzoo.Authorization.decide/3
  :: {:ok, state, request, event} | {:error, {:invalid_input, r}}
```

`request/3` opens revision 1 for `(run, action_id, requirement)`. If an open
request for the same `(run, action_id)` exists:

- same requirement and same binding → unchanged (idempotent), no event;
- changed requirement **or** changed binding (payload, writes, policy
  identity) → the old request is marked `:superseded` and kept; a new request
  opens with `revision + 1`. Superseded consent can never release the new one.

A non-ASK decision is `{:invalid_input, :not_ask}`.

```elixir
Elzoo.Approval.release(state, key, evidence | :retained, context)
  :: {:released, state, writes, event}
   | {:refused, reason, state}          # state returned unchanged
   | {:error, {:invalid_input | :unavailable_context, r}, state}
```

`release` is also the **restore** path: a restored pre-dispatch "approved"
action calls `release` again; the stored approval is an input, never a bypass.

Release succeeds only when **all** checks pass (first failing check is the
reason; every failure emits no writes, adds no release record, adds no
consumption marker and does not change state):

| # | Check | Refusal reason |
| --- | --- | --- |
| 1 | request `key` exists | `:unknown_request` |
| 2 | a release record exists for `key` | `:already_released` (emits no writes, even with a new evidence id) |
| 3 | request status is `:open` | `:superseded` |
| 4 | `evidence.request == key` exactly (stale or other revision) | `:stale_revision` / `:request_mismatch` |
| 5 | `evidence.verifier` in `context.verifiers` | `:verifier_not_allowed` |
| 6 | `evidence_key` not revoked (revocation wins) | `:revoked` |
| 7 | `evidence_key` not consumed | `:consumed` |
| 8 | `evidence_key` reused with a different request or binding | `:evidence_reused` (rejected, never overwritten) |
| 9 | `evidence.decision == :approve` | `:rejected_by_reviewer` |
| 10 | `issued_at <= now` | `:issued_in_future` |
| 11 | `now - issued_at < max_age` | `:evidence_too_old` |
| 12 | `now < expiry` | `:expired` |
| 13 | `evidence.scope == requirement.scope` and the scope admits `context.run` (below) | `:scope_mismatch` |
| 14 | `context.approver.identity == evidence.reviewer` | `:approver_mismatch` |
| 15 | `evidence.reviewer != request.proposer` | `:self_approval` |
| 16 | escrowed writes ⊆ `context.approver.authority` | `:approver_not_authorized` |
| 17 | re-run `Elzoo.Authorization.decide(context.policy, context.proposal, context.authority)`; failure → that error class | — |
| 18 | current decision is not DENY | `{:deny_at_release, reason}` |
| 19 | current policy identity == bound policy identity (a reused id/version with a changed hash fails) | `:policy_changed` |
| 20 | current normalized action == bound action, structurally (payload drift) | `:payload_changed` |
| 21 | current decision is ASK with the same requirement and the same escrowed writes | `:requirement_changed` |

Check 16 together with the re-run at 17–21 means released writes are within
the approver's current authority **and** the proposer's current effective
authority (own ∩ parent). If the requirement changed, the caller calls
`request/3` with the new decision to supersede and open `revision + 1`.

On success, in **one** pure transition: the release record for `key` is
added (evidence key, bound action, released writes, reviewer, verifier,
`now`); the request becomes `:released`; the consent is retained under its
evidence key (for run/root reuse); for `:once` scope the evidence key is
added to `consumed`; the escrowed writes are returned exactly once.

### Retained consent and scope

`release(state, key, :retained, context)` looks for a retained, unrevoked,
unconsumed consent whose bound action, escrowed writes, policy identity and
requirement equal the request's binding structurally, then applies checks
5–21 to it. Scope never broadens the binding or grants authority:

- `:once` — only the exact request it was issued for; consumed by that one
  release; never retained for reuse.
- `:run` — only requests whose `run` equals the consent's request run.
- `:root` — requests whose `context.run.id` equals the consent's root, or
  whose trusted `context.run.ancestry` contains it. The ancestry list is
  trusted caller context; identifiers alone prove no relationship.

### Revocation

```elixir
Elzoo.Approval.revoke(state, evidence_key) :: {:ok, state, event}
```

Revocation is recorded and wins over any retained consent. It does not undo
writes already released (the record keeps them); it stops every later
release or restore that would use that evidence.

### Replay

```elixir
Elzoo.Approval.replay(events) :: {:ok, state} | {:error, {:invalid_input, r}}
Elzoo.Approval.apply_event(state, event) :: {:ok, state}
```

Events: `{:requested, request}`, `{:superseded, old_key, new_request}`,
`{:released, release_record}`, `{:revoked, evidence_key}`. Replay rebuilds the
state the live transitions built. It returns **state only**; it never
returns or re-emits writes. Re-applying an already present `:released` event
is idempotent. After replay, a release for an already released key emits no
writes. A refused release produces no event, so replay never sees it.

### Model text

There is no path from text to release. Only an evidence record that passes
checks 5–16 can release. A model reply `"approved"`, in a payload, tool
argument or chat turn, leaves the escrowed writes escrowed.

## Concrete API location

- Elixir: `pieces/workflow/approval/lib/elzoo/approval.ex` (`Elzoo.Approval`)
  validates evidence/context, calls `Elzoo.Authorization` for re-evaluation
  and encodes into Cure.
- Cure: `pieces/workflow/approval/cure/elzoo/approval.cure`
  (`mod Elzoo.Approval`, `use Elzoo.Authorization`) holds `check`, `release`,
  `apply_event` over Int-encoded state, with the same `Write`/`Action` types.

## Selected laws (Cure-checked)

Checked on the production `release` / `check` functions by pinned Cure, with
negative controls and a clean audit:

| Law | Statement |
| --- | --- |
| `refused_emits_nothing` | for all state, request, evidence, context: if `check(...) = Refused(r)` then `writes(release(...)) = []` and `state(release(...)) = state` |
| `release_within_escrow` | `subset(writes(release(...)), request.escrowed) = True` |
| `release_within_approver` | `subset(writes(release(...)), approver_authority) = True` |
| `release_within_effective` | `subset(writes(release(...)), own) = True` and `... parent) = True` |
| `deny_at_release_wins` | if the current reducer verdict is `Deny`, `writes = []` |
| `self_approval_refused` | if reviewer equals proposer, `writes = []` |
| `reject_evidence_refused` | if `evidence.decision = Reject`, `writes = []` |
| `released_twice_emits_nothing` | if a release record exists for the key, `writes = []` |

Together these are the **escrow-only-on-approval** law: the only transition
that emits escrowed writes is a release whose every check passed, and it
emits nothing outside the request's escrow, the approver's authority or the
current effective authority.

## Finite tests (not proofs)

Each acceptance scenario of #38 plus B24.2 behavior:

- payload drift and policy version drift invalidate an earlier approval;
  same id/version with a changed `content_hash` invalidates it;
- release-time DENY wins over recorded consent;
- stale revision changes nothing; changed requirement supersedes and opens
  `revision + 1`; old evidence cannot release the new revision;
- self-approval and under-authorized approver refused;
- model text `"approved"` leaves escrow intact;
- verifier not in allowlist; a self-asserted verifier name in a payload has no
  effect;
- age boundaries: `now - issued_at = max_age - 1` accepted, `= max_age`
  refused; `now = expiry - 1` accepted, `= expiry` refused; future-issued
  refused; missing expiry rejected;
- revocation wins over retained consent and over restore;
- once scope consumed by one release; a second release of the same key emits
  nothing even with a new evidence id; reuse of an evidence id with a
  different binding rejected;
- run scope refuses another Run; root scope admits root and Runs whose
  ancestry includes it, refuses others;
- replay of recorded events rebuilds the live state and emits no writes;
  restore after replay re-enters the reducer;
- unavailable context fails closed with no writes, distinct from DENY and
  invalid input.

Trusted fixtures stand in for verifier output and principals. They do not
establish authentication.

## Ash reuse division

Ash (ELZ-015 spike) has no ASK verdict, escrow or payload-bound consent
memory. This Piece adds that remainder only. An Ash consumer may call it from
a generic action in its own Adapter. No Ash dependency in this bundle.

## Operational applicability

- **Telemetry:** `not_applicable`. Pure; the owning Unit/Assembly
  instruments. Approval decisions and release records are retained records
  owned by the caller, not telemetry samples.
- **Config:** `supported` (per call). Verifier allowlist and `max_age` are
  trusted per-call inputs in the release context; no hot reconfiguration.
- **Control:** `not_applicable`. Revocation is a domain transition on the
  caller's state, not a lifecycle Control.

## Needs, assumptions and unspecified behavior

Needs: authentication and a verifier transport that builds evidence only
from a configured verifier; a trusted clock translated to Unix ms (skew is
the owner's assumption); trusted Run/root/ancestry; durable retention of
events if approvals must survive restart; serialization of transitions per
state value (the owner serializes; there is no internal lock).

Not claimed: durable storage, cross-owner or exactly-once dispatch of the
released writes (the caller dispatches; a timeout after dispatch is an
unknown outcome), concurrent release safety without owner serialization,
UI prompting, and the meaning of a reviewer's identity.

## Dependencies

Pieces: `domain/authorization`. Consumes `core/envelope`/`core/port`
unchanged only when a consumer carries events in an opaque payload behind its
own schema id. Providers: pinned Cure, Elixir 1.20.4, OTP 29.1.2.

## Open questions for review

- **Q4.** Evidence carries its own `scope` and must equal the requirement's
  scope. Alternative: the requirement lists allowed scopes and the reviewer
  picks one. Exact match is simpler.
- **Q5.** Check order is fixed for reasons. A different order changes only
  which reason is reported, never whether writes are emitted.
