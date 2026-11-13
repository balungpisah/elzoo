# ELZ-152 — Let the small gate see what the aggregate consumer sees

- Dependencies: none
- Allowed implementation path: `lib/elzoo/check_selection.ex`, `lib/mix/tasks/check.ex`, `test/export_test.exs`, `test/check_selection_test.exs`, `test/support/cure_consumer_case_test_helper.exs`, `test/test_helper.exs`, `pieces/test_helper.exs`, the sections of `AGENTS.md` and `docs/development/10-symbolic-ci.md` that describe the small gate, and the index/generated changes under AGENTS.md section 3. No change of `.github/workflows/`, of a Piece, of the exporter or of the merge queue.

A Piece-only pull request merges on the small gate (`mix check --piece`). The gate runs the per-ID consumers of the affected ready IDs, but only for the fixed inventory of `Elzoo.CheckSelection`; a new Piece is not in it, so nothing exports a new Piece before the merge. On 2026-11-13 this turned `main` red twice, each time in `check-aggregate` after a small-gate merge:

- ELZ-138 (repair ELZ-147): a test found its `lib/` files beside the manifest, which holds in the catalogue and not in a copied consumer.
- ELZ-138 with ELZ-143 (repair ELZ-148): two Pieces wrote one consumer target with different content, and `Elzoo.Export.plan!` refused it (`selected pieces disagree on target ...`).

Each fault was visible before the merge to a check that the gate does not run. Add the two checks.

**A. Plan of every ready Piece.** One test in `test/export_test.exs` plans the export of every ready Piece into one new destination (`Elzoo.Export.plan!/3`, no write, no compile, no inner test run) and fails with the exporter's own message when two Pieces disagree on a target or on a setting. It carries no aggregate or consumer tag, so the small gate and the root part that already run this file run it.

**B. A consumer for a changed Piece that has none.** In the small gate only, each changed ready Piece that has no per-ID consumer in the inventory runs its tests once in a copied consumer of its own (its dependency closure, through the existing `assert_cure_consumer` with the default limits). The full check and its five parts do not run these tests: the aggregate already holds every ready Piece. Dependants of a changed Piece get no new consumer. The report of the gate names the IDs that got one, and its LIMIT line stays true.

Contract: the five parts together still run exactly the tests of the full check (the partition test stays and passes). No existing test, time limit, marker text, job, or queue rule changes. The gate keeps refusing a change that is not Piece-only.

If B cannot be built inside `mix check --piece` without a change of the workflow, a raised limit or a second way to select tests, deliver A alone and write the exact obstacle on the issue. Do not design around it.

## Acceptance

- `plan_catches_the_conflict`: on a scratch copy of commit 7829a2c611a43fc9ba6d77b45ed95d83c9eaa924 (the red `main` before ELZ-148) the test of A fails and names `test/fixtures/openrouter-anthropic/PROVENANCE.md`; on the head it passes. Record its run time.
- `changed_piece_consumer_catches_the_layout_fault`: with the one-line fix of ELZ-147 temporarily undone in `pieces/integration/ai-token-count/test/elzoo/ai_token_count_anthropic_test.exs` (a Piece-only change), `mix check --piece` fails in the consumer of `integration/ai-token-count`; with the fix it passes. Record both and the added run time. Revert.
- A Piece-only change of a Piece that is in the inventory selects the same tests as before (compare the test arguments on one example).
- The partition test and `python3 scripts/test-ci-change-class.py`, `scripts/test-merge-queue.py` and `scripts/test-ci-skip.py` pass.
- This is not a Piece-only change: the hosted full check on the exact head of the pull request passes. Run `mix check` or the hosted run as AGENTS.md says for a shared path, and `git diff --check`. Record exact commands and exit codes.
- The two documents describe the gate as it now is, in the place where they describe it today.

One worker owns the claimed branch/worktree. One independent review under AGENTS.md section 6.
