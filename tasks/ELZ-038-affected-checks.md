# ELZ-038 — Run only affected checks on PRs; keep the full aggregate consumer on main

- Phase: P0 harness (CI time; shared `test/export_test.exs`, `mix check`, symbolic workflows)
- Catalogue IDs: none (no Piece or Contract change)
- Dependencies: ELZ-036, ELZ-037

## Outcome

PR CI time grows with every ready Piece. Measured total test time on symbolic `check`:
840 s after #58, 972 s after #57, 1230–1346 s on PR #59. Each Piece's tests run three
times per PR: in the root suite, in its per-ID consumer, and again in the aggregate consumer
(`test/export_test.exs:112`), where Cure reads every copied source root. ELZ-036 and ELZ-037
only raised time limits. The `check` job limit is 45 min.

Make PR CI scale with the change, not with the catalogue, without reducing what main proves.

## Scope

- On PRs, run per-ID consumer checks only for Pieces whose files, dependencies or shared
  harness changed, plus their dependants (from piece.json dependencies). A change to shared
  harness, toolchain pins, mix.exs/mix.lock, registry or workflows selects everything.
- Run the full aggregate consumer and all per-ID consumers on every push to main. Merge
  acceptance already requires merge-commit CI (AGENTS.md "Review, merge and cleanup" step 3).
- Make the selection explicit and testable: a named selector with its own tests and a
  printed list of selected IDs in the CI log. Unknown or unmapped paths select everything.
- Keep `mix check` locally able to run the full set (default) and the PR subset (opt-in).
- Symbolic self-hosted runners only; no hosted fallback; do not disturb ELZ-034.
- Add this task's source body at `tasks/ELZ-038-affected-checks.md`.

## Acceptance

- [ ] Selector tests cover: a single Piece change, a dependency change selecting dependants,
      a shared-harness change selecting all, an unknown path selecting all.
- [ ] Main push runs the full aggregate and all per-ID consumers; shown on the merge commit.
- [ ] A PR touching one Piece shows a shorter `check` time; record before/after.
- [ ] No assertion removed or weakened; every existing check still runs on main.
- [ ] Full `mix check` passes; symbolic CI passes on the PR head and on the merge commit.
- [ ] Independent review of the actual diff (CI and evidence scope).

## Evidence and limits

A PR subset is not evidence for unselected Pieces; main's full run is. A failure found only on
main after merge is a real regression and must be fixed forward. Cure compile cost itself is
out of scope.

## Out of scope

Cure compiler performance; new runners (ELZ-034); flaky tests (ELZ-035).


## Coordinator clarification (2026-11-07)

The published issue above retains its historical measurement premise. The
[investigation](https://github.com/balungpisah/elzoo/issues/68#issuecomment-6703555113)
and [coordinator consumer-list/order note](https://github.com/balungpisah/elzoo/issues/68#issuecomment-6704718287)
correct it: there are 26 fixed per-ID consumers, an aggregate over the 40
currently ready IDs, and a separate OTP-only consumer. It is not the case that
every Piece runs three times. The backend job limit is now 90 minutes.

ELZ-043 / PR #75 merged as `63179941f45fbcb51b015a9b42caa90f58f3c6d1` before
this task's claim. Preserve all root tests and the OTP-only consumer on every
run. Shared or unknown changes select every fixed per-ID consumer and the
aggregate in PR mode. The main and local-default full run retain everything.

After the independent review, the coordinator tightened the approved plan:
if any affected ready ID is outside the selected fixed consumers' dependency
closures, also run the full aggregate. IDs without standalone consumers must
not lose their PR copying evidence. Shared/unknown comparisons retain the
aggregate too, because the affected IDs cannot safely be narrowed. This
supersedes the earlier main-only-aggregate plan. This implementation PR changes
the shared harness and therefore selects all 26 fixed consumers **and** the
aggregate. A genuine covered one-Piece PR is a separate acceptance observation after integration;
merge-commit full CI and independent review remain the coordinator's gates.
No selector test or subset result establishes the unselected consumer checks'
behavior or an omitted aggregate. Compiler scans, registry parse reuse, incremental compilation and
test partitioning are separate follow-ups, not this task's implementation.
