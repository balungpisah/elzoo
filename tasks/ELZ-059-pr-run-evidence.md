# ELZ-059 — The pull request run is the merge evidence; freeze rule; Gleam gate for Gleam paths; roadmap check in CI (part A)

- Phase: P0 harness (CI; `.github/workflows/symbolic-check.yml`, `scripts/ci-skip-decision.py`,
  `scripts/run-ci-check.sh`, `scripts/check-ci-runners.py`, `scripts/test-ci-runners.py`, `scripts/merge-queue.py`,
  `scripts/test-merge-queue.py`, `docs/development/10-symbolic-ci.md`, the acceptance wording of `AGENTS.md`)
- Catalogue IDs: none
- Dependencies: ELZ-049 (#89), ELZ-057 (#95), ELZ-058 (#96) and ELZ-066 (#115) merged. Designed for the hosted lane only
  (`check-hosted`, `gleam-hosted`); the self-hosted jobs are being removed by the cleanup change, so this task adds nothing
  to them. ELZ-044 (#76) comes after and is not a dependency.
- Review: independent review of the actual workflow, guard, queue and `mix check` diff is required.

## Outcome

A merge needs one full run of the exact head. Owner decision 2026-11-08 ("go"), rescoped by the coordinator on 2026-11-09 after the move to GitHub-hosted runners (minutes are free for a public repository): the full `pull_request` run on the exact head is the merge evidence, so the queue adopts it instead of dispatching a second run; `main` stops merging when it is red; the Gleam gate runs only when Gleam paths change; a stale generated roadmap view fails CI. **Dropped:** the hourly staggered run of `main`, the `decide` job, the light pull request mode, the `green/main` marker and the `contents: write` trust-model change.

**Split (coordinator decision, 2026-11-09).** This task is part A. The documentation-only fast path is part B and is a separate task, **ELZ-071** (a new trust decision: a marker that the queue accepts without the full run); ELZ-071 starts after this task is merged. After part A is merged, **the coordinator re-enables branch protection** requiring `check-hosted` and `gleam-hosted` (a coordinator step, not part of the diff; this PR records the settings read back from the API).

**Current state this task ends (since between 03:49 and 03:56 WIB on 2026-11-09; the coordinator reported about 04:05 WIB):** branch protection on `main` has no required checks. The queue cancelled the duplicate `pull_request` run and relied on a `workflow_dispatch` exact-head run, which GitHub does not count as a pull request status, so PR #122 was refused with "the base branch policy prohibits the merge". `main` keeps no force pushes and no deletions (administrators not enforced). This task is the path back to required `check-hosted` and `gleam-hosted`.

## Measured basis (hosted lane, 2026-11-09 WIB; ELZ-066 rehearsal and queue traffic)

Full hosted job: 33 min cold, 18 min 38 s warm (run 42520133125, job 128851610565). `mix check` 17 min 28 s warm; root suite 932.0 s to 1139.0 s (280 to 360 s async, 650 to 780 s sync). Pull request checks in affected mode: PR #123, run 42518583815, 22 min 19 s; PR #122, job 128851866050, 22 min 25 s (`mix check` 21 min 7 s). The root suite runs in full in affected mode, so the full pull request run costs about the same as the affected one. The figures of PR #117 (run 42522189688) are added to the issue when that run ends.

## Scope (part A)

1. **The `pull_request` run is the evidence.**
   - The `pull_request` `check-hosted` job runs in full mode on the exact head: the workflow no longer calls the affected mode of `scripts/run-ci-check.sh` for pull requests, so the run prints `ELZOO CHECK PASSED` and never the affected marker.
   - `scripts/merge-queue.py` adopts a green `pull_request` `check-hosted` run on the exact head (same evidence rules as today: exactly one job, hosted runner identity, green identity and `Run mix check` steps, full marker, run unchanged while read) instead of dispatching. If no run exists for that head, the queue waits for it.
   - After `Updating PR by merging main` the queue waits for the new head's `pull_request` run. It never cancels that run.
   - `workflow_dispatch` stays only as a fallback when no `pull_request` run exists for that head after a bounded wait (for example when GitHub did not start a run); the queue says why it dispatches. A dispatch run stays valid evidence for the merge, but it does not satisfy branch protection.
   - ELZ-058's duplicate-cancel rule (the queue cancelling the duplicate `pull_request` run) is retired by this item, together with its tests; the `concurrency` group that cancels an outdated head's run on a new push stays.
2. **The merge gate** is the exact-head full run before every merge (now the `pull_request` run). Local full `mix check` before the pull request stays required (AGENTS.md).
3. **Freeze rule** in `scripts/merge-queue.py`: if the latest completed run of the push workflow on `main` is red and not yet classified, the queue refuses to merge, with a clear message. Red means `failure` or `timed_out`; `cancelled` is its own class and also freezes until classified. Classification is an issue comment on tracking issue #98 in a fixed format naming the run ID and one class (`infrastructure` rerun, `defect` fix-forward task, `conflict` fix-forward task); the comment author must be the authenticated login that runs the queue. A later green push run of `main` unfreezes. No revert churn, no force-push. Any API failure fails closed.
4. **Gleam gate only for Gleam paths.** `scripts/merge-queue.py` requires a green `pull_request` run of `gleam-hosted` on the exact head only when the pull request changes `spikes/gleam_ui/**`, `.github/workflows/symbolic-gleam.yml`, `scripts/check-ci-runners.py` or `scripts/test-ci-runners.py` (the guard cannot be split by content). The path list comes from Git (`git diff --name-only <main>...<head>` on the fetched refs, rename-aware); an empty, failed or malformed list fails closed to "Gleam run required". `gleam-hosted` itself gets no job-level `if:`: it always reports, so branch protection can require both checks; the queue rule is the gate.
5. **The push skip decision accepts the new evidence.** `scripts/ci-skip-decision.py` looks for the evidence run of the merged pull request head: it now accepts the latest completed `pull_request` run of `symbolic-check.yml` on that head (and, as before, a `workflow_dispatch` run) under the same rules (exactly one job, hosted identity, green identity and `Run mix check` steps, full marker). Without this, every push after a queue merge would stop skipping.
6. **`check-hosted` runs `python3 scripts/check-roadmap.py` (plain, offline) after `mix check`**, so a stale generated view fails CI (the views were stale on `main` for hours without any run noticing).
7. **Guard and tests** accept exactly the new shape (full pull request step, the roadmap step with its condition). `scripts/test-merge-queue.py` covers the adoption of a `pull_request` run (right head, wrong head, red, in progress, rerun during reading, cancelled by a new push, missing run with the dispatch fallback and its message), the retired duplicate-cancel, the freeze rule (red unclassified blocks; cancelled blocks; classified infrastructure or a later green run unblocks; wrong author, wrong run ID, malformed comment, API failure each fail closed) and the Gleam path rule (each Gleam path, a rename into or out of one, a failing Git command). `scripts/test-ci-skip.py` covers the `pull_request` evidence run. Existing tests are not weakened; edits to merged tests are listed in the PR for the owner's approval.
8. **Docs.** `AGENTS.md` acceptance wording; `docs/development/10-symbolic-ci.md`: the evidence rule, the freeze procedure, the branch protection settings; `docs/consuming.md`: consumers take the latest green push run of `main` (no `green/main` marker).
9. **Measure over the next ten pull requests:** check minutes per pull request, queue wait, merges per hour and any freeze with its classification. Record the table in the issue.

**Not in this task:** the documentation-only fast path (ELZ-071); branch protection (the coordinator, after merge).

## Acceptance

- [ ] The queue merges a pull request on its own green `pull_request` `check-hosted` run (observed once, no dispatch), waits for the new head's run after `Updating PR by merging main`, and never cancels a `pull_request` run.
- [ ] The dispatch fallback is observed or tested once, with its reason in the queue output.
- [ ] After the merge, the coordinator re-enables branch protection requiring `check-hosted` and `gleam-hosted`, and a merge through the queue is accepted by GitHub (observed once; coordinator step).
- [ ] A pull request that changes no Gleam path merges on the backend run alone (observed once); one that changes a Gleam path is still blocked without a green Gleam run.
- [ ] Freeze rule tested and observed once with a red unclassified run blocking the queue.
- [ ] A stale generated roadmap view fails the `check-hosted` job (negative control on a scratch branch or in the guard tests).
- [ ] Guard and tests pass with new negative controls; merged-test edits listed and approved.
- [ ] Independent review of the actual diff (separate agent session, reviewed SHA on the PR).
- [ ] Full `mix check` on the PR head and on the merge commit; the ten-PR measurement in the issue.

## Limits

A `pull_request` run tests the merge of the head with the base at the time the run started (`refs/pull/N/merge`), not the head alone; if `main` moves afterwards the queue merges `main` into the branch first, as today, and waits for the new run. A conflict between two separately tested merges is detected when the push run finishes (18 to 33 minutes after the merge); the freeze rule stops further merges but does not undo the merge. Without the dropped hourly run, a `main` that nobody pushes to is not re-checked. The queue's evidence still rests on a run of the workflow file of the pull request head: required review of workflow changes stays.
