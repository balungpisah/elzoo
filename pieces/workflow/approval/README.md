# workflow/approval

> **Ready (subset), ELZ-024 / issue #38.** Contract reviewed at `62da286`
> ([re-check 3 PASS](https://github.com/balungpisah/elzoo/issues/38#issuecomment-6694767984))
> after early review findings 1–11, N1–N6 and S1–S2/R3–R8; notes T1–T3 are
> folded in below. Grounding is in [piece.json](piece.json); the Cure source is
> [cure/elzoo/approval.cure](cure/elzoo/approval.cure).

Pure consent record for one exact proposed action. It turns an ASK decision
from [`domain/authorization`](../../domain/authorization/README.md) into an
approval request, accepts host-verified evidence for exactly that request,
and releases escrowed writes only when every release check passes against
**current** context. Approval never grants authority: Cure `release` re-runs
Cure `decide` and checks the approver's own authority.

This Piece is **not** authentication, a verifier transport, a prompt UI, a
durable approval store, a shared Run schema, a security certification or an
identity guarantee. The state owner is the caller's Run (or other trusted
owner); this Piece supplies pure transitions over a caller-held state value.

Interface deltas against #38 are listed in the
[authorization README](../../domain/authorization/README.md#interface-deltas-vs-38)
(D1–D11, D17) and below (D12–D16, D18).

## Preflight acknowledgments (docs/plans/preflight.md)

| Decision | How this Contract holds it |
| --- | --- |
| **B24.1** | The request binds the complete normalized action (with the **trusted** proposer and effect class), the exact escrowed writes, the policy identity `(id, version, content_hash)` and the requirement. Binding is compared structurally (Cure `eq_*`), never by a digest. Binding data is kept for replay. |
| **B24.2** | Evidence is a separate, host-verified record; verifier allowlist; exact request tuple; explicit Unix-ms `now`, `issued_at`, `max_age`, `expiry`; revocation; revision/supersession; once/Run/root scope; release record and once-consumption marker in one transition; replay folds without re-emitting writes. |
| **B24.3** | Current proposer identity, effect class, proposer authority, parent authority and approver authority come from trusted context at release/restore, never from the request or evidence; Cure `release` re-runs Cure `decide`; DENY or failure wins; approver must hold the exact writes and must not be the trusted proposer; failures keep the three reason classes. |

## Request identity

A request is identified by the tuple
`{run, action_id, requirement_name, requirement_version, revision}`. All text
parts are nonempty UTF-8 identities (≤ 1024 bytes) with exact equality;
`revision` is an integer `1..2^31-1`. The tuple proves no relationship between
Runs.

```elixir
%{
  key: {run, action_id, req_name, req_version, revision},
  binding: %{action: normalized_action,       # includes trusted proposer
             escrowed: [write],
             policy: %{id:, version:, content_hash:},
             requirement: %{name:, version:, scope: :once | :run | :root}},
  status: :open | :released | :superseded
}
```

## State

```elixir
%{
  requests: [request],          # every revision, including superseded and released
  consents: [consent],          # retained approved consent (run/root scope only)
  releases: [release_record],   # completion keyed by full request tuple
  consumed: [evidence_key],     # once-scope consumption markers
  revoked:  [evidence_key]
}
# evidence_key = {verifier_id, evidence_id}
# release_record = %{key, binding, writes, evidence, run, root, released_at}
#   evidence is the full evidence record used (verifier, evidence_id, reviewer,
#   request, decision, scope, issued_at, expiry), N2
#   run, root: for a fresh release, the trusted context.run.id / .root of this
#   release; for a :retained release, the consent's recorded run / root (S1)
# consent = %{evidence, binding, run, root}
#   evidence is the full evidence record (as above); run and root are the
#   trusted context.run.id and context.run.root at its first successful
#   release (F5b, S1). evidence_key is derived: {evidence.verifier,
#   evidence.evidence_id}
```

The state is a plain value held by the caller, encoded as lists for Cure.
This Piece performs no I/O and reads no clock.

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
  issued_at: 0..2^63-1,           # Unix ms
  expiry: 0..2^63-1               # Unix ms, required, > issued_at
}
```

Missing expiry, `expiry <= issued_at`, a non-integer or out-of-range time, an
unknown key, a malformed field or a bound exceeded is
`{:invalid_input, reason}`. There is no implicit unbounded consent.

## Trusted release context

```elixir
%{
  now: 0..2^63-1,                    # Unix ms, supplied by the owner
  max_age: 1..2^63-1,                # ms (Config)
  verifiers: [text],                 # allowlist (Config)
  run: %{id: text, root: text, ancestry: [text]},    # trusted caller context
  policy: policy_map,                # current trusted policy
  proposal: proposal_map,            # current action as it would dispatch now
  authority: %{proposer: text,       # trusted proposer identity (F1)
               effect_class: text,   # host-derived (F2)
               own: [write], parent: [write] | :none},
  approver: %{identity: text, authority: [write]}    # current
}
```

Missing or invalid context is `{:error, {:unavailable_context, reason}}`.
**One exception (T2):** `select_retained/3` accepts a context without the
`:approver` key and ignores it if present; every other function requires it.
`context.authority` is exactly the `authority_context` of
`Elzoo.Authorization.decide/3`.

### Finite bounds (F6)

Fixed Contract constants, checked by Elixir **before** any evaluation;
exceeding one is `{:invalid_input, {:bound_exceeded, name}}` for evidence and
events and `{:unavailable_context, {:bound_exceeded, name}}` for trusted
context. Nothing is truncated. All `domain/authorization` bounds also apply;
in particular `approver.authority` is an authority set with at most 4096
entries before coalescing, identity texts ≤ 1024 bytes and value bounds as
there (N6).

| Bound | Value |
| --- | --- |
| bytes of any identity text (verifier, evidence id, reviewer, run, root, ancestry entry, request tuple parts) | 1024 |
| `run.ancestry` entries | 64 |
| `verifiers` allowlist entries | 1..64 |
| `approver.authority` entries (before coalescing) | 4096 |
| times (`now`, `issued_at`, `expiry`) | integer `0..2^63-1` |
| `max_age` | integer `1..2^63-1` |
| revision | integer `1..2^31-1` |
| events in one `replay/1` call | 65 536 |
| entries in each state list (requests, consents, releases, consumed, revoked) | 65 536; a transition that would exceed it is refused with `{:invalid_input, {:bound_exceeded, :state}}` and no change |

## Transitions

Successful transitions return a new state and an event. The owner appends
events to its own retained log; replay folds events back into state.

```elixir
Elzoo.Approval.new() :: state

Elzoo.Approval.request(state, run, decision)
  # decision: an ASK decision from Elzoo.Authorization.decide/3
  :: {:ok, state, request, event | nil}
   | {:error, {:invalid_input, r}}
```

`request/3` looks at the **latest** revision for `(run, action_id)`:

- none → open revision 1; event `{:requested, request}`;
- latest is `:open`, same requirement and same binding → unchanged;
  returns `{:ok, state, request, nil}` (no event; idempotent);
- latest is `:open`, changed requirement **or** changed binding (payload,
  writes, policy identity) → the old request is marked `:superseded` and
  kept; a new request opens with `revision + 1`; event
  `{:superseded, old_key, new_request}`;
- latest is `:released` or `:superseded` → a new request opens with
  `latest revision + 1`; event `{:requested, request}` (F5c). A released
  request is never reopened or released twice.

A non-ASK decision is `{:invalid_input, :not_ask}`. The decision is
validated fully before evaluation with the `domain/authorization` validators
and bounds (action, escrow, policy identity, requirement); the escrow must
equal the action's writes and every list must already be normalized.
Malformed or over-bound input is `{:error, {:invalid_input, r}}`; nothing is
repaired or truncated (PR #59 review, finding 1). All eight keys of the
`decide/3` result are required and checked: `reason == {:ask, requirement}`,
`permitted == []`, and `rules` is a list of at most 1024 rule-id identities
(re-check note N1).

```elixir
Elzoo.Approval.release(state, key, evidence | :retained, context)
  :: {:released, state, writes, event}
   | {:refused, reason, state}          # state returned unchanged
   | {:error, {:invalid_input | :unavailable_context, r}, state}
```

**Before check 0 (N3).** Elixir validates and bounds the whole input first:
release context (including the current policy, proposal and authority —
the validation half of check 16), evidence and state. Any fault returns
`{:error, {:invalid_input | :unavailable_context, r}, state}` with no
writes and no state change, ahead of every check below. A current proposal
carrying an atom control key returns
`{:refused, {:deny_at_release, {:control_field, k}}, state}`; this outcome is
computed in Elixir and is **test-only** (not covered by the release laws).

Release succeeds only when **all** checks pass. The first failing check is
the reason; the order below is pinned by tests (Q5). Every failure emits no
writes, adds no release record, adds no consumption marker and leaves state
unchanged.

| # | Check | Refusal reason |
| --- | --- | --- |
| 0 | `context.run.id == key.run` (F5a) | `:run_mismatch` |
| 1 | request `key` exists | `:unknown_request` |
| 2 | no release record exists for `key` | `:already_released` (emits no writes, even with a new evidence id) |
| 3 | request status is `:open` | `:superseded` |
| 4 | fresh evidence: `evidence.request == key` exactly | `:stale_revision` (same run/action/requirement, other revision) / `:request_mismatch` |
| 5 | `verifier` in `context.verifiers` | `:verifier_not_allowed` |
| 6 | `evidence_key` not revoked (revocation wins) | `:revoked` |
| 7 | `evidence_key` not consumed | `:consumed` |
| 8 | if `evidence_key` is already known (a retained consent or a release record), its stored **binding** equals this request's binding (action, escrow, policy identity, requirement); the request key is **not** compared (F4) | `:evidence_reused` (rejected, never overwritten) |
| 9 | `decision == :approve` | `:rejected_by_reviewer` |
| 10 | `issued_at <= now` | `:issued_in_future` |
| 11 | `now - issued_at < max_age` | `:evidence_too_old` |
| 12 | `now < expiry` | `:expired` |
| 13 | scope equals the requirement's scope and admits this request (below) | `:scope_mismatch` |
| 14 | `context.approver.identity == reviewer` | `:approver_mismatch` |
| 15 | `reviewer != context.authority.proposer` (trusted identity, F1) | `:self_approval` |
| 16 | Cure `decide(current policy, current action, own, parent)` succeeds | `{:error, {:unavailable_context, {:ambiguous_requirement, list}}, state}` (R3; the only Cure-side failure after N3; `revalidate/3` returns the same without `state`) |
| 17 | current verdict is not DENY | `{:deny_at_release, reason}` |
| 18 | current policy identity == bound policy identity (a reused id/version with a changed hash fails) | `:policy_changed` |
| 19 | current normalized action == bound action, structurally (payload drift; includes trusted proposer and class) | `:payload_changed` |
| 20 | current verdict is ASK, same requirement, current escrow `eq_writes` bound escrow | `:requirement_changed` |
| 21 | current escrow ⊆ `context.approver.authority` (w.r.t. `eq_write`) | `:approver_not_authorized` |

On success, in **one** pure transition, release returns the **current
decision's escrowed writes** (F7; structurally equal to the bound escrow by
check 20). It adds the release record for `key` (binding, released writes,
the **full evidence record**, `now` as `released_at`; N2), marks the request `:released`,
retains a run/root consent `%{evidence, binding, run, root}` with the full
evidence record and the trusted `context.run.id` and `context.run.root` (F5b,
S1), and for `:once` adds the evidence key to `consumed`. A `:retained`
release puts the selected consent's full evidence record and its recorded
`run`/`root` into its release record and adds no new consent.
Event: `{:released, release_record, consent | nil}`.

Because the released writes are `escrowed_of(decide(...))`, the release
non-escalation laws follow from the `domain/authorization` laws, and DENY or
ALLOW at release releases nothing even before check 17 (`deny_empty`,
`allow_no_escrow`). Check 21 makes the approver bound explicit. If the
requirement changed, the caller calls `request/3` with the new decision to
supersede and open `revision + 1`.

### Retained consent and scope

`release(state, key, :retained, context)` is for `:run` and `:root` scope
only. The owner first calls the pure selection (S2):

```elixir
Elzoo.Approval.select_retained(state, key, context)
  :: {:ok, consent} | {:refused, reason} | {:error, {class, r}}
```

`select_retained` needs no `context.approver` (it ignores it). The owner then
loads the selected consent's reviewer (`consent.evidence.reviewer`) and that
reviewer's current authority as `context.approver`, and calls `release/4`
with `:retained`. `release/4` runs the **same** Cure `select_retained` again.
On the same state and the same context **except the approver** (T1) it
selects the same consent; the approver is ignored by selection. If anything
else changed in between (for example `now`, so the chosen consent expired),
the selection may differ; the supplied approver is then not that reviewer and
check 14 refuses with `:approver_mismatch`, failing closed. Selection order
(N5):

1. Run checks 0–3 on the request first, so their reasons are never hidden.
2. Candidates: retained consents whose binding equals the request's binding
   structurally and that pass checks 5–13 against this context
   (allowlist, revocation, consumption, binding reuse, reviewer decision,
   issue time, age, expiry, scope). Stale, expired or rejecting consents drop
   out here; check 9 fails closed even on a state forged below the Elixir
   boundary (PR #59 review, note 3).
3. If no candidate remains → `{:refused, :no_retained_consent, state}`.
4. Otherwise choose deterministically: earliest `issued_at`, then evidence key
   `(verifier, evidence_id)` in UTF-8 byte order (F5d). `release/4` then
   applies checks 9 and 14–21 to it, using the consent's evidence record. Its refusal reason is returned; no other candidate is
   tried after that (the choice is fixed before the authority checks, so the
   reviewer named in the release record does not depend on authority state).

**Fixed choice can block (T3).** Because the choice is made before checks 9
and 14–21, the deterministic first candidate can block other valid consents
when its reviewer lost authority (`:approver_not_authorized`) or the owner
cannot supply that reviewer. The owner then revokes that consent
(`revoke/2`) or obtains fresh evidence; this Piece never skips to the next
candidate.

Which request-key fields may differ from the consent's original request:

| Scope | `run` | `action_id`, requirement name/version | `revision` | Admits |
| --- | --- | --- | --- | --- |
| `:once` | equal | equal | equal | only the exact request the evidence names; never retained |
| `:run` | equal to consent `run` | equal (part of binding) | may differ | a later revision for the same `(run, action_id)` with equal binding, e.g. a new ASK after a release (F5c) |
| `:root` | `context.run.id == consent.root` or `consent.root ∈ context.run.ancestry` | equal (part of binding) | may differ | that root and Runs whose trusted ancestry contains it, with equal binding |

Revocation, expiry, age or allowlist removal of a retained consent filters it
out in step 2, so on the retained path these show as
`{:refused, :no_retained_consent, state}`, not as `:revoked` or `:expired`
(R6).

Scope never broadens the binding or grants authority. Root is the trusted
`context.run.root` recorded at the consent's first release; ancestry is
trusted caller context; identifiers alone prove no relationship.

### Restore

Two restore cases, both re-entering the reducer; the stored approval is an
input, never a bypass:

- **Release not recorded** (the owner restarted before it persisted the
  release event): call `release/4` again. For `:once`, the owner passes the
  evidence record it stored itself; `:retained` is only for run/root.
- **Release recorded, dispatch not confirmed:**
  `Elzoo.Approval.revalidate(state, key, context) :: :ok | {:refused, reason} | {:error, {class, r}}`
  reruns checks 0, 5, 6, 9, 10–21 against the **full evidence record stored in
  the release record** (N2) and current context. Check 13 uses the `run` and
  `root` stored in the release record; there is no lookup in `consents` (S1).
  No release record for `key` → `{:refused, :not_released}`. Elixir
  validation faults → `{:error, {class, r}}`. A control key in the current
  proposal → `{:refused, {:deny_at_release, {:control_field, k}}}` (R4,
  test-only). Ambiguous requirement → `{:error, {:unavailable_context,
  {:ambiguous_requirement, list}}}` (R3). It emits no writes and changes no state. The owner must not
  dispatch the recorded writes on refusal. A timeout after dispatch remains
  an unknown outcome for the owner to reconcile.

### Revocation

```elixir
Elzoo.Approval.revoke(state, evidence_key) :: {:ok, state, event}
```

Revocation is recorded (`{:revoked, evidence_key}`) and wins over any
retained consent, release and restore. It does not undo writes already
released; it stops every later release, retained use or revalidate.

### Replay

```elixir
Elzoo.Approval.replay(events) :: {:ok, state} | {:error, {:invalid_input, r}}
Elzoo.Approval.apply_event(state, event) :: {:ok, state} | {:error, {:invalid_input, r}}
```

Events: `{:requested, request}`, `{:superseded, old_key, new_request}`,
`{:released, release_record, consent | nil}`, `{:revoked, evidence_key}`.
Replay rebuilds the state the live transitions built. It returns **state
only**; it never returns or re-emits writes. Re-applying a present
`:released` event is idempotent. After replay, release of an already released
key emits nothing. A refused release produces no event.

The log is not trusted. `apply_event/2` (and so `replay/1`) validates each
event with the same validators and bounds as the live transition that
produced it, and with that transition's invariants: identities and times in
range; request status `:open` and key consistent with its binding;
supersession to exactly `revision + 1` in the same Run and action; a
release key consistent with its binding (action id, requirement name and
version) and with its recorded Run unless the evidence scope is `:root`
(`:release_key_binding`); a release only for a request already in state
with the same binding (`:release_without_request`,
`:release_of_superseded_request`, `:release_binding_mismatch`; re-check note
N2); released
writes equal to the bound escrow; release and consent evidence approving,
consent scope run/root and consent equal to its release record. Any fault is
`{:error, {:invalid_input, r}}` (PR #59 review, finding 2). Validation cannot
show that an internally consistent event was really produced by a live
transition; that origin remains the owner's assumption.

### Model text

There is no path from text to release. Only an evidence record that passes
the checks can release. A model reply `"approved"`, in a payload, tool
argument or chat turn, leaves the escrowed writes escrowed.

## Cure/Elixir split (F3)

| Function | Runs in | Grounding |
| --- | --- | --- |
| Evidence, context, event and state validation; bounds; time range | Elixir `Elzoo.Approval` | finite tests |
| Encoding of state, evidence, context (incl. current policy, proposal, authority) to Cure terms; decoding | Elixir | finite tests incl. agreement test |
| Validation of current policy/proposal/authority for check 16 (runs before check 0) | Elixir via `Elzoo.Authorization` validation | finite tests only |
| Control key in current proposal → `{:deny_at_release, {:control_field, k}}` | Elixir | test-only (N3) |
| Checks 0–15 and 17–21 (gate list `pre_gates`, `evidence_gates`, `tail_gates`) | Cure `release_check` / `run_gates` | laws below + tests |
| Retained-consent filter and selection order (`select_retained`, also exposed in Elixir) | Cure `select_retained` | tests only (R7) |
| Check 16 re-decide | Cure `release` calls Cure `Elzoo.Authorization.decide` on the encoded current policy, action, own, parent | `domain/authorization` laws |
| Success transition (record, status, consent, consumed, writes) | Cure `release` | laws below |
| `request` transition (supersede / revision + 1) | Cure `request` | finite tests |
| `revoke`, `apply_event`, replay fold | Cure `revoke`, `apply_event`; Elixir only iterates the bounded list | finite tests (state-only return is by type) |
| `revalidate` | Cure `revalidate` | finite tests; returns no writes by type |

Apart from the control-key refusal above, Elixir never computes a check
result, and it never computes a write list. If a check proves
impossible to move into Cure during implementation, it will be marked
test-only here and in `piece.json` before review, never presented as covered
by a law.

Cure source `pieces/workflow/approval/cure/elzoo/approval.cure`
(`mod Elzoo.Approval`, `use Elzoo.Authorization`; Authorization types are
module-qualified, because unqualified imported type names are read as type
variables by pinned Cure):

```cure
type ApprGate = GatePass | GateRefuse(ApprRefusal) | GateFail(AuthFailureClass, AuthFailure)
type ApprCheck = ApprApproved(ApprEvidence, ApprBinding, List(Int), List(Int))
               | ApprRefused(ApprRefusal) | ApprFailed(AuthFailureClass, AuthFailure)
type ApprSource = ApprFresh(ApprEvidence) | ApprRetained
rec ApprStep state: ApprState, writes: List(AuthWrite), result: ApprCheck, event: Option(ApprEvent)

fn run_gates(gs: List(ApprGate), final: ApprCheck) -> ApprCheck   # first blocking gate wins
fn release_check(s, k, src, ctx) -> ApprCheck                      # gates 0-21 in order
fn release_writes(ctx) -> List(AuthWrite)
  # = guard(subset(escrowed_of(current(ctx)), approver_authority), escrowed_of(current(ctx)))
fn release(s, k, src, ctx) -> ApprStep = finish_release(release_check(s, k, src, ctx), s, k, src, ctx)
fn select_retained(s, k, ctx) -> ApprSelection
fn revalidate(s, k, ctx) -> ApprCheck
fn request(s, run, binding) -> ApprRequestStep
fn apply_event(s, e) -> ApprState
```

The success state is `apply_event(s, released_event(...))`, so a live release
and the replay of its event build the state with the same function.
(`check` is a reserved word in pinned Cure, hence `release_check`.)

## Selected laws (Cure-checked)

On the production Cure `release`, with negative controls and a clean audit.
Subset is with respect to `eq_write`.

| Law | Statement |
| --- | --- |
| `refused_emits_nothing` | for all `s, k, src, ctx`: if `approved(release_check(s, k, src, ctx)) = False` then `writes_of(release(s, k, src, ctx)) = []` |
| `refused_keeps_state` | same hypothesis: `state_of(release(...)) = s` |
| `blocked_anywhere` | for all gate lists `p`, `sfx`, gates `g` with `blocks(g) = True` and every `final`: `approved(run_gates(p ++ [g \| sfx], final)) = False` (induction on `p`) |
| `release_within_approver` | for all inputs: `subset(writes_of(release(...)), approver_authority_of(ctx)) = True` |
| `release_within_own` | for all inputs: `subset(writes_of(release(...)), own_of(ctx)) = True` (from `escrowed_within_own`) |
| `release_within_parent` | for every context whose parent is `p` (`with_parent(ctx, p)`): released writes ⊆ `p` (from `escrowed_within_parent`) |
| `deny_at_release_wins` | if `verdict_of(current(ctx)) = AuthDeny`, `writes = []` for every source and gate outcome |
| `run_mismatch_refused` | if `eq_ints(run_id_of(ctx), run_of(k)) = False`, `writes = []`, fresh and retained |
| `released_twice_emits_nothing` | fresh evidence: if `has_release(releases_of(s), k) = True` (Cure lookup by `eq_key`), `writes = []` |
| `reject_evidence_refused` | fresh evidence: for every `e`, release of `with_decision(e, ApprReject)` emits nothing |
| `self_approval_refused` | fresh evidence: if `eq_ints(reviewer_of(e), proposer_of(ctx)) = True`, `writes = []` |

`self_approval_refused`, `reject_evidence_refused` and
`released_twice_emits_nothing` are stated for fresh evidence; the retained
path runs the same gate functions after selection and is covered by the
general laws (`refused_*`, `release_within_*`, `deny_at_release_wins`,
`run_mismatch_refused`) and by tests. Law types use small accessors
(`reviewer_of`, `own_of`, ...) because pinned Cure rejects field projections
inside law types (`bad_projection`).

Together these are the **escrow-only-on-approval** law for the production
release: the only transition that emits writes is a release whose check is
approved, and it emits nothing outside the current escrow, the approver's
authority or the current effective authority. Release writes are by
definition `release_writes(ctx)`, the guarded current escrow; "released writes
equal the originally bound escrow" is enforced by gate 20 in Cure and covered
by tests; it is not a selected law (it would need an `eq_write`-transfer lemma).

**Decision-split form (N4).** Pinned Cure reduces `Int` equality on literals
only; `int_eq` on symbolic values is neutral
([#36 comment 6694393314](https://github.com/balungpisah/elzoo/issues/36#issuecomment-6694393314)).
So every release law above is stated in decision-split form: it takes the
relevant stuck `Bool` or check result as a hypothesis and discharges it by
`rewrite` inside a one-line lemma, or by the inspect pattern (case on the
Boolean with its equation as an argument); none assumes that a key or value equals itself. Native
`<=`, `<` and `+` are also neutral on symbolic values (`Std.Builtin#int_le`,
same comment). Checks 10–12 and the `issued_at` selection order use them, so
no time, age or ordering law is planned; those are tests only (R5).

**Test-grounded, not laws, for that reason:**

- release-then-release: the record added by the first release is found by the
  second (needs `eq_key(k, k) = True`);
- replay idempotence (re-applying a present `:released` event);
- `request/3` idempotence (same requirement and binding → unchanged);
- `eq_value` reflexivity and soundness against Elixir;
- bound-escrow transfer (released writes ⊆ originally bound escrow);
- the Elixir-side outcomes before check 0 and the control-key refusal;
- check 7 (consumed) as a separate reason: public transitions add a once
  marker only together with its release record, so check 2 or 4 reports
  first; the gate stays as defence in depth.

If a production law cannot be checked in its stated form during
implementation, work stops and the exact Cure error is reported; the law is
not weakened.

## Finite tests (not proofs)

- payload drift and policy version drift invalidate an earlier approval;
  same id/version with a changed `content_hash` invalidates it;
- release-time DENY wins over recorded consent;
- stale revision changes nothing; changed requirement supersedes and opens
  `revision + 1`; old evidence cannot release the new revision;
- self-approval refused; **forged proposer**: a proposal claiming another
  proposer is rejected at decide, and a reviewer equal to the trusted
  proposer is refused at release;
- under-authorized approver refused;
- model text `"approved"` leaves escrow intact;
- verifier not in allowlist; a self-asserted verifier name in a payload has no
  effect;
- age boundaries: `now - issued_at = max_age - 1` accepted, `= max_age`
  refused; `now = expiry - 1` accepted, `= expiry` refused; future-issued
  refused; missing expiry rejected;
- revocation wins over release and `revalidate` (`:revoked`); on the
  retained path a revoked or expired consent gives `:no_retained_consent`
  (R6);
- revalidate of a retained `:root` release in a child Run passes when the
  recorded root is in `context.run.ancestry` and is refused without it (S1);
- T1: `now` changing between `select_retained` and `release/4` fails closed
  with `:approver_mismatch`; T2: `select_retained` accepts a context without
  `:approver`, `release/4` does not;
- two retained consents from two reviewers: `select_retained` returns the
  deterministic one; `release/4` with that reviewer as approver succeeds;
  with the other reviewer it gives `:approver_mismatch` (S2);
- pinned proposal-fault order at release (control key before other faults)
  and ambiguous requirement at release and revalidate (R3, R4);
- `revalidate` of a `:once` release after its `expiry` is refused;
  `revalidate` of a key with no release record → `:not_released`;
- an invalid current proposal is reported before `:run_mismatch` and
  `:unknown_request` (Elixir validation precedes check 0); a control key in
  the current proposal → `{:deny_at_release, {:control_field, k}}`;
- retained selection: a stale earliest candidate does not hide a valid later
  one; checks 0–3 are reported before `:no_retained_consent`;
- once scope consumed by one release; a second release of the same key emits
  nothing even with a new evidence id; reuse of an evidence id with a
  different binding rejected; reuse with an equal binding under run/root
  accepted;
- run scope: a new ASK after release opens `latest + 1` and a retained run
  consent releases it; another Run refused; `context.run.id != key.run`
  refused;
- root scope admits root and Runs whose ancestry includes the recorded root,
  refuses others;
- deterministic retained-consent choice (earliest `issued_at`, then evidence
  key byte order) recorded in the release record;
- every bound at limit and limit + 1;
- **pinned refusal order**: one test per adjacent pair of checks shows the
  documented first reason (Q5);
- replay of recorded events rebuilds the live state and emits no writes;
  restore after replay re-enters the reducer;
- unavailable context fails closed with no writes, distinct from DENY and
  invalid input;
- Elixir↔Cure agreement for encoded state and evidence.

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
- **Config:** `supported`, per call, no default, no hot reconfiguration:
  - `verifiers` — list of identity texts, 1..64 entries, exact match;
  - `max_age` — integer milliseconds, `1..2^63-1`, no default; compared as
    `now - issued_at < max_age`;
  - `policy` — as in `domain/authorization`, for re-decide.
- **Data, not Config:** proposal, authority context, approver, run context,
  `now`, evidence, state, events.
- **Control:** `not_applicable`. Revocation is a domain transition on the
  caller's state, not a lifecycle Control.

## Needs, assumptions and unspecified behavior

Needs: authentication and a verifier transport that builds evidence only
from a configured verifier; trusted proposer identity and host-derived effect
class; a trusted clock translated to Unix ms (skew is the owner's
assumption); trusted Run/root/ancestry; durable retention of events if
approvals must survive restart; serialization of transitions per state value
(the owner serializes; there is no internal lock); integrity of the owner's
event log beyond the structural and invariant validation of `apply_event/2`
(a consistent, approving event that was never produced live cannot be
detected).

Not claimed: durable storage, cross-owner or exactly-once dispatch of the
released writes (the caller dispatches; a timeout after dispatch is an
unknown outcome), concurrent release safety without owner serialization,
UI prompting, and the meaning of a reviewer's identity.

## Dependencies

Pieces: `domain/authorization`. Consumes `core/envelope`/`core/port`
unchanged only when a consumer carries events in an opaque payload behind its
own schema id. Providers: pinned Cure, Elixir 1.20.4, OTP 29.1.2.

## Limits

- **Single approver per request (Q1):** one requirement, one approving
  evidence. Multi-approver needs a new Piece ID.
- **Exact scope match (Q4):** evidence scope must equal the requirement
  scope. Accepting narrower scope later needs a new Piece ID.
- **Exact-value authority (Q3):** approver authority, like proposer
  authority, holds exact writes.
- Refusal order is fixed and pinned by tests (Q5); it changes only the
  reported reason, never whether writes are emitted.
- Subset laws hold with respect to `eq_write`.

## Interface deltas vs #38 (approval)

| # | #38 text | This Contract | Reason |
| --- | --- | --- | --- |
| D12 | "rejected when the approver … is the proposer of the ASK" | compared against the **trusted** proposer identity in release context | F1 |
| D13 | request id `(Run, action id, requirement name, requirement version, revision)` | plus run check 0; a new ASK after release opens `latest revision + 1` | F5a/F5c |
| D14 | "scope (once, run, root)" | binding-only reuse check; per-scope key-field table; root recorded from trusted context; deterministic retained choice | F4/F5b/F5d |
| D15 | "a restored pre-dispatch 'approved' action re-enters the reducer" | two restore paths: re-`release` (once: owner-stored evidence) and `revalidate/3` for recorded releases | F11 |
| D16 | "within its declared maximum age" | `max_age` per-call Config, ms, no default; all approval inputs bounded | F6/F10 |
| D18 | restore re-enters the reducer | release record stores the full evidence record; `revalidate/3 :: :ok \| {:refused, reason} \| {:error, {class, r}}`, `:not_released` for a missing record | N2 |
