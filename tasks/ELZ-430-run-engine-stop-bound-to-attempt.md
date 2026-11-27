# ELZ-430 — assembly/run-engine: a pending stop is bound to its Attempt

- Dependencies: ELZ-420, ELZ-423, ELZ-429

## Outcome and scope

A defect found while fixing ELZ-420's review. ELZ-420 binds a pending root
failure, its evidence row and the owner command to the finish slot's own
Attempt, so a restart after the host began a new Attempt drops the stale
failure instead of failing the new Attempt. The other pending stops still
have that race: a completed Run (`stop_pending: :completed`) and the
lifecycle stops (`:cancelled`, `:out_of_time`, `:out_of_budget`). If the
engine dies before its owner command and the host begins a new Attempt before
restart, the engine can terminalize the new Attempt without running it. For
`:completed`, it uses the older Attempt's source and `result/3` can return
`{:error, :completion_mismatch}`. For `:cancelled`, `:out_of_time` and
`:out_of_budget`, no evidence row is written and `result/3` returns
`{:terminal, outcome}`. It is fixed in place under the same ID (the rule of
ELZ-415).

- Every pending stop, its evidence row (where one is written) and the owner
  command carry the Attempt that produced the stop. If the owner has moved to
  a newer Attempt, its stale answer makes the engine sync the new Run view,
  and a change of Attempt drops the stale stop, as ELZ-420 does for a root
  failure. The new Attempt can generate work when the existing Run-wide
  deadline, Budget and request cap permit it; an Attempt change resets none of
  them.
- During a retained-history read in v1 or v2, when a stop is pending, any
  record that ends it or changes the Attempt must replay to exactly its
  recorded state. A selected completion or root failure must belong to the
  owner's current Attempt. Plain lifecycle results remain authoritative owner
  outcomes.
- A pending stop is never replaced by a later lifecycle stop: the first
  pending stop wins, as the input gate already requires for new work.
  ELZ-420 keeps a pending root failure. The other pending stops can still be
  replaced. After a crash before the owner command and a restart past the Run
  deadline with a local action running, `recover_local` lets the lifecycle's
  deadline check replace a pending `:completed` with `:out_of_time` through
  `install_lifecycle/3`. The owner records `:out_of_time` and `result/3`
  returns `{:terminal, :out_of_time}`. A later lifecycle request can replace
  an earlier lifecycle stop, such as `:cancelled`, through the same function.
- A stop that this fold sets records its Attempt and the stop in the Run's
  recorded control state, as the key `stop_attempt` with the value
  `{attempt_id, stop}`, from the step that sets the stop to the step that
  clears it. This fold never replaces a pending stop (the first stop wins,
  above); a value that is not the current Attempt and the pending stop
  counts as no mark. Admission keeps room for a stop: while no stop is
  pending, admitted work leaves free a constant number of bytes that the
  README states, the largest mark (for the longest valid Attempt ID) plus
  the largest growth of a step that sets a stop. So the step that sets a
  stop marks it and never fails the state bound after its input commits.
  Work that the earlier revision admitted at the bound can now be refused;
  the README `## Changes` entry states this and how to move. A state that
  an earlier revision recorded without that room takes its stop unmarked,
  and that stop follows the rule for a stop that the earlier fold set (a
  README limit).
- The mark adds to the stored format; the README `## Changes` entry states
  it. Apart from that key, histories without a stale pending stop, and
  without a later lifecycle request that would replace a pending stop, keep
  their journal, transcripts, frozen fixtures and cold-recovery results
  unchanged, except for the refusal of a stop that the earlier fold set,
  below.
- Rollback Need (README `## Changes` and Limits, `piece.json` limits): no
  earlier revision runs on a journal that this revision wrote. Where the
  mark's key is not an existing atom (a fresh VM of the earlier revision),
  its safe term decoder refuses each row or snapshot that holds the mark, so
  its Unit does not open. Where the atom exists, it can run, and can deliver
  a stale stop (the defect that this change fixes); a stop that it replaces,
  or keeps across a change of Attempt, no longer matches its mark, so this
  revision, taken again, decides it by the rule for an unmarked stop.
- A start, and a replacement Unit, decide a pending stop before any engine
  write (a new input, an evidence row or an owner command), from the owner's
  committed Run view:
  - When that view is terminal, or names an Attempt newer than the engine's,
    the engine takes it: its fold ends the Run, or drops the stop at the
    change of Attempt.
  - Otherwise a stop with a matching mark is delivered as committed, with no
    new reading of the clock, Budget or request cap.
  - A stop with no matching mark (the fold before this change set it, or
    replaced a marked stop) is delivered as committed only when the owner
    has never had an Attempt other than the engine's. This includes a stop
    that the earlier fold set in place of another stop of the same Attempt
    (a README limit).
    Otherwise the start returns `{:error, :stop_origin_unknown}`, and a
    replacement Unit halts the engine with that reason, with no engine
    write. The host ends the Run, or begins a new Attempt, on the owner and
    starts the engine again; the first rule then applies. This is the
    README's migration step; the README never tells a host to deliver such a
    stop under the earlier revision.
  - The Unit completes an input committed before the start
    (`finish_pending/1`) with this revision's fold, before the decision.
    That fold never replaces a pending stop: a Run view that changes the
    Attempt drops it, and a terminal Run view ends the Run.
- Every path that can drain the engine (an outbox offer, a control, an
  input) runs the replacement check of a new Unit first. A replacement Unit
  takes the decision above, then the Run view, then the local losses: the
  start's order.
- A `cancel` control cancels the tasks of only the local work that its
  committed cancel closed. No caller context can ask for a task's
  cancellation.
- History reads compare each replayed step exactly (`===`) with the step of
  this fold or of the fold before this change, the mark included: the close
  markers of an event wait and the terminal-view comparisons check the
  mark's presence and value. The close of a terminal Run view as revisions
  before ELZ-215 recorded it (the local work closed, a waiting ask left
  open) is no longer accepted: while a stop is pending, such a step is
  `{:error, :history}`, in v1 and v2. Those revisions all precede the
  release commit; the README `## Changes` entry gives the migration step
  (read such a Run's retained history with the revision that wrote it before
  taking this one).
- The README `## Changes` entry names the change; a changed `piece.json` gets
  a new `manifest_sha256` in its `entries` row, with `note` equal to a changed
  `contract`.

Paths: `pieces/assembly/run-engine/**`, its `entries` row in
`docs/plans/release-plan.json`, and the generated `LEDGER.md` and
`docs/plans/views.md`. New external dependencies: none.

## Acceptance

- For each stop, exercise two crash cuts after the pending stop and any
  evidence are committed. First, kill the engine before forwarding
  `:complete`, then begin the new Attempt and restart. Second, begin the new
  Attempt before the engine samples the revision for `:complete`, forward the
  command with the stop's original Attempt, and assert the real owner returns
  `{:unchanged, :stale, revision}`. Deliver that reply, then kill the engine
  at the ensuing status call before it journals the new Run view. Repeat the
  second case without killing the engine to verify that the stale reply
  itself triggers sync and clears the stop. In each case no stale stop is
  pending, no extra evidence row is written and the owner has no terminal
  record of the old stop.
- A current-Attempt wake reaches the root after completion, cancellation, and
  expiry of an old pause deadline while the Run deadline is still in the
  future. After Run-deadline or budget exhaustion, a fresh wake requests a
  stop for the new Attempt under the unchanged limit; separately, under
  `budget_rule: :finish`, after the request cap is reached with deadline and
  Budget still available, a fresh wake in the new Attempt requests a stop
  (`:out_of_budget`) under the unchanged cap.
- With the new Attempt open, first assert `transcript/3` succeeds. Then change
  only the Run-view input to name the old Attempt, recompute its row digest,
  and leave its paired state unchanged. Assert `transcript/3` returns
  `{:error, :history}` in v1 and v2; disabling the pending-stop replay check
  must make the v1 case fail.
- First stop wins, in v1 and v2. For a pending `:completed`: crash before the
  owner command, then restart the same Attempt past the Run deadline with a
  local action running. The owner records `:completed`, not `:out_of_time`,
  and `result/3` returns the completion. Separately, from that crashed state,
  step a wake past the deadline, a cancel and a wake at the request cap; each
  leaves `:completed` pending. For a pending `:cancelled` (the cancel settles
  running local work in the same step): from the post-cancel crash state,
  step a wake past the deadline and a wake at the request cap; each leaves
  `:cancelled` pending, and the restart past the deadline records
  `:cancelled`.
- Negative controls (each recorded and reverted): the Run-view fold keeps the
  stale stop; the owner command uses the owner's current Attempt; the reader
  accepts an older Attempt's stop; `install_lifecycle/3` replaces a pending
  stop.
- Stops that the fold before this change set (journals that the earlier fold
  built from the producing step on, never a current-fold step with its mark
  removed, in v1 and v2):
  - in a Run whose owner has only had the engine's Attempt, a pending
    completion, a cancel, a limit stop, and a stop that replaced another stop
    of that Attempt are each delivered as committed;
  - in a Run whose owner has had two Attempts, with the engine at the newer
    one, each is refused with `{:error, :stop_origin_unknown}` and no new
    input, evidence row or owner command, also after owner changes that are
    neither a new Attempt nor an outcome (a lease renewal). After the host
    ends the Run on the owner, the next start takes the terminal view; after
    it begins a new Attempt, the next start is open in that Attempt;
  - from a replacement Unit, the same refusal halts the engine, also when
    the first call after the replacement is an outbox offer;
  - a committed but unpaired wake after such a stop: the start completes the
    wake, the stop stays pending, and the start is refused with no engine
    write.
- Room for a stop: with an Attempt ID of the longest valid length and a
  state at the admission limit, a deadline wake and, separately, a cancel
  each commit, the stop is marked and the Unit reopens. A state at the bound
  as an earlier revision recorded it takes the same wake unmarked; the Unit
  reopens and the start follows the rule for an unmarked stop.
- Rollback, then this revision again: this revision sets a completion in
  Attempt B; the earlier fold, keeping the mark, replaces it with
  `:out_of_time`. With one owner Attempt the start delivers that stop; with
  two it is `{:error, :stop_origin_unknown}` with no engine write.
- In v1 and v2, a protocol cancel whose paired result's mark alone names
  another Attempt (row digest recomputed) is `{:error, :history}`, also while
  the stop stays pending.
- A terminal Run view recorded with the close before ELZ-215 while a stop is
  pending is `{:error, :history}` in v1 and v2. An `input/4` whose context
  carries a cancel flag, past a running slot's deadline, cancels no task.
- Further negative controls (each recorded and reverted): an earlier-fold
  stop delivered in a two-Attempt Run; an outbox offer that drains without
  the replacement check; a replacement that records local losses before it
  takes the Run view; task cancellation read from caller context; a mark of
  another Attempt or another stop counted as a mark; a history read that
  checks only the mark's presence; admission with no room for the mark.
- The frozen-row tests pass unchanged. A cold-recovery capture changes only
  where its history holds a pending stop, and only by the `stop_attempt`
  key; the pull request records, once, that removing that key from the
  recorded states gives the old capture. The other captures are unchanged.
- `mix check --piece "$(git merge-base origin/main HEAD)"` and
  `git diff --check` exit 0, or the pull request records the exact reason a
  command cannot run on the host. The hosted check is green on the exact head.
- One independent review by the strongest available reviewer of another model
  family (the Piece keeps durable state), and the exact-head automated review
  with its threads answered and resolved, or the authorized replacement
  review under `AGENTS.md` section 6.
