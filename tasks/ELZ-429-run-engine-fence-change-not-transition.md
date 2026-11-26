# ELZ-429 — assembly/run-engine: a lease renewal of the Run owner is not a Run transition

- Dependencies: ELZ-420, ELZ-422, ELZ-423

## Outcome and scope

`Elzoo.RunApprovalRelease.renew/2` (ELZ-422) appends one lease record to the
Run stream and moves the held revision that `status/2` reports, without a Run
record. `RunEngine.sync_run/1` compares only the view's `revision` with the
engine's recorded `control.run_revision`; any difference commits a
`:run_view` journal record, and a committed record settles what is due at its
time. So a renewal adds a journal record that the engine's documented
settlement does not expect. In the group
`retained_slot_closes_after_its_deadline (one step)` of
`run_engine_test.exs`, a renewal before the child's result at 15,000 ms makes
the parent close before the result is folded, and a separate `:nested_actual`
record follows instead of the single-step settlement that the test pins. The
independent review of ELZ-422 found this; it is fixed in place under the same
ID (the rule of ELZ-415).

- Suppress `:run_view` only when the owner's durable history establishes that
  every revision after the engine's recorded `run_revision` is a lease
  renewal. Preserve the existing journal behavior when the interval includes
  a Run record, including Approval requests and evidence, which advance the
  revision without changing `id`, `operation_id`, `current_attempt` or
  `outcome` (the publication fixture of `run_engine_test.exs` expects their
  `:run_view` records). The proof must survive an owner restart; the live
  owner's revision floor alone is not sufficient. `RunApprovalRelease`
  exposes it, derived from its durable stream (for example the revision of
  its newest Run record in `status/2`), as an additive change with a
  `## Changes` entry in its own README.
- For a renewal-only interval the engine commits no journal record and
  settles nothing because of it, and its next owner command applies (the
  owner accepts a revision from before its own renewals while it lives,
  ELZ-422). The README states how the engine learns the fenced revision and
  what it journals for it.
- A view whose interval includes a Run record is a Run transition exactly as
  today. Histories without renewals keep their journal, transcripts, frozen
  fixtures and cold-recovery results unchanged.
- The README `## Changes` entry names the change; a changed `piece.json` gets
  a new `manifest_sha256` in its `entries` row, with `note` equal to a changed
  `contract`.

Paths: `pieces/assembly/run-engine/**`, `pieces/workflow/run-approval-release/**`
(only for the durable proof above), the `entries` rows of both Pieces in
`docs/plans/release-plan.json`, and the generated `LEDGER.md` and
`docs/plans/views.md`. New external dependencies: none.

## Acceptance

- The `retained_slot_closes_after_its_deadline (one step)` case with a
  renewal through `RunApprovalRelease.renew/2` before the child's result: the
  same single-step settlement as without it, no `:nested_actual` record, and
  no journal record for the renewal.
- Several renewals between commands of a live Run: no journal record per
  renewal, and every command applies.
- An Approval request or evidence write interleaved with renewals: its
  `:run_view` record is journaled as today, and the renewals around it add
  none.
- After renewals, stop the owner and start a replacement using the current
  held token. Reopen the engine against the replacement owner and the
  existing Unit journal. Startup adds no renewal-only record, and a new owner
  command using a freshly read revision applies. Explicit stale-revision
  commands stay subject to the existing conflict rule.
- A real transition (a new Attempt, an outcome) after renewals is journaled
  with today's effects.
- A negative control: committing a `:run_view` for a fence-only change makes
  the first case fail (recorded and reverted).
- The frozen-row and cold-recovery tests pass unchanged.
- `mix check --piece "$(git merge-base origin/main HEAD)"` and
  `git diff --check` exit 0, or the pull request records the exact reason a
  command cannot run on the host. The hosted check is green on the exact head.
- One independent review by the strongest available reviewer of another model
  family (the Piece keeps durable state), and the exact-head automated review
  with its threads answered and resolved, or the authorized replacement
  review under `AGENTS.md` section 6.
