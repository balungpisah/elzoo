# ELZ-417 — workflow/approval: prune expired evidence and retire closed request lines

- Dependencies: ELZ-415, ELZ-416

## Outcome and scope

The state of `workflow/approval` is
`%Elzoo.Approval.State{cure: {:ApprState, requests, consents, releases, consumed, revoked}}`.
No transition removes an entry. Each list holds at most 65,536 entries.
`request/3`, `revoke/2` and `apply_event/2` check state capacity first.
`release/4` checks it after validating the context, key and evidence source.
With valid operands, a full state returns
`{:error, {:invalid_input, {:bound_exceeded, :state}}}`, with the unchanged
state as a third element for `release/4`. `select_retained/3` and
`revalidate/3` do not check it. So a long-lived owner stops at the bound.
`assembly/checked-command` is such an owner: each ASK operation opens its own
request line `(run, action_id)` (the pair that `request/3` uses to find the
newest revision), and a release leaves that request `:released` with one
release record and one consumed key. A stale release appends no Approval
event and leaves the request `:open`. Expiry alone cannot free these lines:
the newest request of a line must stay, or `request/3` would restart at
revision 1.

Add two pure operations. Existing operations, events and `replay/1` do not
change. This is an improvement under the rule of ELZ-415 (same Piece ID).

    Elzoo.Approval.prune(state, now) :: {:ok, state} | {:error, {:invalid_input, reason}}
    Elzoo.Approval.retire(state, lines) :: {:ok, state} | {:error, {:invalid_input, reason}}

Both:

- Are pure, total and deterministic. They emit no event and only remove
  entries. They keep the order of the surviving entries. They do not run the
  capacity check, so they work on a full state.
- A value that is not an `Elzoo.Approval.State` gives
  `{:error, {:invalid_input, :state}}`. Malformed input changes nothing.
- Work is close to linear in the size of the state. Indexing and several
  passes are allowed. The keep or drop decision for each entry is a Cure
  function with `@total true`; it may take facts that Elixir computed from an
  index (for example "this evidence key is dead" or "this request is the
  newest of its line"). The README and `piece.json` state exactly which part a
  Cure law covers and which part only tests cover.
- Replay handoff. Neither operation emits an event. A full replay from an
  empty state therefore rebuilds the state without pruning or retirement, and
  re-applying an event from before them can fail
  (`:release_without_request`) or bring an old record back. An owner that
  prunes or retires stores the result, with its clock floor (the highest `now`
  it passed to `prune/2`), together with the exact position of the last event
  that the result covers, and replays only later events onto it.

`prune/2`:

- `now` is an integer Unix time in milliseconds, `0..2^63-1`, like the other
  times of the Piece. Otherwise `{:error, {:invalid_input, {:bound_exceeded, :now}}}`.
- An evidence key `{verifier, evidence_id}` is dead at `now` when the release
  records and consents of the state hold at least one evidence record for it,
  all of them are the same record (all eight fields), and its `expiry <= now`.
  A key whose records differ in any field is ambiguous and is never dead.
- Drop each release record and each consent whose evidence key is dead, and
  each consumed key and revoked key that is dead.
- Keep each consumed or revoked key that no release record or consent names:
  a revocation of evidence the state never saw stays.
- Keep every request entry that is `:open` or is the newest (highest
  revision) of its line. Drop any other request entry when no surviving release
  record has its key.

`retire/2`:

- `lines` is a proper list of at most 65,536 `{run, action_id}` pairs. Each
  part is validated as `request/3` validates `run`. A pair that the state does
  not hold changes nothing; duplicates are allowed.
- For each line drop every request entry of the line (every revision and
  status), every release record whose key is on the line, and every consent
  with scope `:run` whose `run` and bound action ID are the line's (only that
  line can use it). Then drop each consumed key and revoked key that a record
  dropped by this call named and no surviving record names. Keep consents with
  scope `:root`, which can serve other lines; `prune/2` drops them when they
  expire.
- The Piece cannot tell an open request that the owner will still release
  from an open request that the owner closed (the stale case above). So
  "a pending ASK line is never retired" is the owner's Need, not a refusal of
  this function.

Needs, stated in the README:

- Verifier Need, for an owner that uses either operation: the trusted
  verifier binds each evidence key permanently to one immutable evidence
  record (request, decision, scope, issue time and expiry). It never reissues
  a key and never extends an expiry. Gate 8 (reuse) compares bindings only;
  without this Need a dropped record could let a reissued key release.
- Clock Need: after `prune/2` at `now`, the owner never calls `release/4`,
  `select_retained/3`, `revalidate/3` or `prune/2` on that state with a
  smaller `now`.
- Retirement Need: the owner retires a line only after it has durably closed
  the line to every later `request/3`, `release/4`, restore and event, and
  never a line that it may still release. After retirement, `request/3` on the
  line would open revision 1 again, and once-scope evidence for an old key of
  the line could pass again.
- The replay handoff above.

Equivalence. Compare only inputs for which both states pass the existing
capacity check. Under the Needs:

- After `prune(s, now)`, for every input at `now' >= now`: `release/4`
  releases on one state exactly when it releases on the other, with the same
  writes; `select_retained/3` selects the same consent on both, or none on
  both; `revalidate/3` returns `:ok` on both or on neither; `request/3` returns
  the same request.
- After `retire/2`, the same for every input whose key or line is not
  retired.
- Only refusal reasons can change. The reachable changes: a dropped superseded
  request gives `:unknown_request` instead of `:superseded`; a dropped
  non-newest released request gives `:unknown_request` instead of
  `:already_released`; a restore whose release record was dropped gives
  `:not_released` instead of the refusal it reached before (for example
  `:expired`); on a retired line `release/4` and `select_retained/3` give
  `:unknown_request` and `revalidate/3` gives `:not_released`. For evidence
  that keeps the Verifier Need, `:consumed` and `:evidence_reused` are not
  reachable as changed reasons: gates 1 to 4 refuse first.
- Capacity is outside this comparison: a full state refuses, and the pruned
  or retired state admits the same otherwise valid transition.

Update the README (operations, the four Needs, the Cure/Elixir split, laws,
finite tests, and a new `## Changes` section with the entry of this task: the
two operations, the opt-in Needs, the changed refusals after prune and
retirement, and the replay handoff) and `piece.json` (contract, limits,
grounding). In the last commit, update the Piece's `entries` row in
`docs/plans/release-plan.json` (`manifest_sha256`, and `note` equal to the new
`contract`; keep its primary `job`, since this task is a secondary
contribution) and regenerate the generated files from current `main`
(`mix elzoo.ledger`, `python3 scripts/check-roadmap.py --write`), never
hand-merged. Only `pieces/workflow/approval/**` changes outside the index
files. `assembly/checked-command` calls both operations in ELZ-418.

## Acceptance

- Cure: laws in the decision-split form that the Piece's laws use, at least:
  an `:open` request is kept; the newest request of a line is kept; a release
  record, consent, consumed key or revoked key whose key is dead is dropped; a
  consumed or revoked key that no record names is kept; `retire/2` drops each
  request entry of a retired line and keeps an entry of another line. The
  existing clean audit test and the test that every Cure function is marked
  `@total` still pass.
- Same-time idempotence on the production functions: `prune(prune(s, t), t)`
  equals `prune(s, t)`, and retiring the same lines twice equals retiring them
  once.
- An equivalence harness, run only on public-API histories that satisfy the
  Needs: open, released, superseded and non-newest released requests;
  `:once`, `:run` and `:root` evidence; live and expired evidence; revoked
  keys seen and unseen; consumed keys. It checks the equivalence above for
  `prune/2` at `now' >= now` and for `retire/2` on the lines it keeps.
- Separately, an ambiguous key: release two distinct `:run` evidence records
  with the same verifier and evidence ID on successive revisions of an equal
  binding, then revoke the key. At a time between their expiries, prune keeps
  both records and the revocation; this fixture has no consumed marker. Test
  the preservation of a consumed marker separately with a live `:once`
  release.
- Each reachable changed refusal above is its own test, with the earlier
  checks passing.
- A case at `now' < now`: a consent that the unpruned state selects at `now'`
  is gone after the prune. This shows why the Clock Need exists.
- Boundaries: `expiry == now` is dropped and `expiry == now + 1` is kept; a
  revocation of evidence that the state never saw is kept; a consumed key
  whose release record is live is kept (the live `:once` release above);
  after a prune, `request/3` on a released line opens the newest revision
  plus one; retiring an absent line, or the same line twice, changes nothing;
  `request/3` on a retired line opens revision 1 (this shows the Retirement
  Need); `lines` with 65,536 and 65,537 entries; a malformed `now` and a
  malformed pair.
- Capacity recovery, each with the state term built directly when the public
  API is too slow: (1) a request list of 65,536 entries, all but the newest
  being superseded revisions of one line: a `request/3` that adds an entry is
  refused with `{:error, {:invalid_input, {:bound_exceeded, :state}}}`, and the
  same call succeeds after `prune/2`; (2) 65,536 distinct released lines, each
  with one request, one release record with live evidence and one consumed
  key: `request/3` for a new line is refused; after retiring all of them the
  request, release and consumed lists are empty and the same call succeeds.
  The existing 65,537-event case covers only the `replay/1` bound.
- Many distinct lines: retire 10,000 distinct released lines in one call and
  in batches; every other line, its records and the order of all surviving
  entries stay unchanged.
- Negative controls in the style of the existing ones (temporary edits, never
  committed): a prune that drops an open request, the newest request of a
  line or a live consent fails a named law or an equivalence test; one that
  drops a record of the ambiguous key fails the ambiguous-key test; a retire
  that drops an entry of another line fails an equivalence test.
- `mix test pieces/workflow/approval/test`,
  `mix check --piece "$(git merge-base origin/main HEAD)"` and
  `git diff --check` exit 0. The hosted check is green on the exact head.
- One independent review by the strongest available model of another family
  (the Piece keeps durable decision state), and the exact-head automated
  review with its threads answered and resolved, or the authorized replacement
  review under `AGENTS.md` section 6.
