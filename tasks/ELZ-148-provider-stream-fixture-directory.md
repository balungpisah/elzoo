# ELZ-148 — Give the provider-stream fixtures a directory of their own

- Dependencies: ELZ-143, ELZ-138
- Allowed implementation path: `pieces/delivery/provider-stream/**` only, and its index/generated changes under AGENTS.md section 3.

Main Check runs 43410460097 at d66ccc1e37039e9e3eb6091d6bdd029296089fa7 and 43411158095 at 7829a2c611a43fc9ba6d77b45ed95d83c9eaa924 failed the aggregate copied-consumer test (`test/export_test.exs:122`). The export of all ready Pieces into one consumer stops with `selected pieces disagree on target test/fixtures/openrouter-anthropic/PROVENANCE.md`. `integration/ai-token-count` (ELZ-138) and `delivery/provider-stream` (ELZ-143) each hold a different file at that path, because both task bodies named the directory `test/fixtures/openrouter-anthropic/`. Each Piece passed its own consumer on the small gate; only the aggregate holds both. It is the only target on `main` that two Pieces write with different content. The first run is classified `conflict` on issue #98. This is the one forward-repair task for that conflict, under the owner's approval of 2026-11-13, with at most two repair attempts. No revert, history rewrite or new Piece ID.

Move the thirteen fixture files of `delivery/provider-stream` from `test/fixtures/openrouter-anthropic/` to `test/fixtures/openrouter-anthropic-stream/`, each file byte for byte (a rename, no edit of a recorded file or of `PROVENANCE.md`). Change the paths that name the directory: the `files` list and the evidence entry of `piece.json`, the one directory line of the test helper, and the one line of the README. Then the index rows that hold the manifest hash, as AGENTS.md section 3 says.

Change nothing else. No change of `lib/`, of a test case or an assertion, of `integration/ai-token-count`, of the exporter or of a shared path; no option, search/glob or second copy of a fixture. The Contract of the Piece (its public functions, shapes and refusals) does not change. If the identical aggregate exposes a second defect, stop for the coordinator's scope decision rather than extending the repair.

## Acceptance

- The hosted full check on the exact head of the pull request passes `check-aggregate`, which runs `test/export_test.exs:122` with every ready Piece in one copied consumer. This is the named evidence; the small gate excludes the aggregate and is not a substitute. Record the run.
- No target path is written by two ready Pieces with different content. Record how this was checked.
- Keep all 22 cases and their assertions unchanged. `mix test pieces/delivery/provider-stream/test` exits 0 with 22 passing cases.
- Run `mix check --piece "$(git merge-base origin/main HEAD)"` and `git diff --check` before delivery. Record exact commands, exit codes and any unavailable service without claiming an unexecuted check passed.
- Record the covering full-main result after the merge; unrelated merges and publication remain frozen until current main is green.

One worker owns the claimed branch/worktree. Keep the correction to this conflict and existing facilities; ask the coordinator before expansion. Record the inspected diff and evidence in the PR. One independent review under AGENTS.md section 6.
