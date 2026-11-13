# ELZ-147 — Find the ai-token-count lib files in a copied consumer

- Dependencies: ELZ-138
- Allowed implementation path: `pieces/integration/ai-token-count/test/elzoo/ai_token_count_anthropic_test.exs` only.

Main Check run 43392530723 at 489feeca4459458d614e5338aa2f96212c319f51 failed its aggregate copied-consumer test (`test/export_test.exs:122`, one failure). The `no_network` test of `integration/ai-token-count` takes the directory of the Piece manifest as the root of the Piece's lib files. In this repository that directory is the Piece root. After export the manifest is under `.elzoo/pieces/` and `lib/` is at the consumer root, so the test fails with File.Error "no such file or directory". The small gate of ELZ-138 does not run the aggregate, so its pull request was green. This run is classified `defect` on issue #98. This is the one forward-repair task for that red run, which the owner approved on 2026-11-13, with at most two repair attempts. No revert, history rewrite or new Piece ID.

Reuse the rule that the source audit of `integration/ai-text` already uses (`pieces/integration/ai-text/test/elzoo/ai_text_test.exs:601`): the root of the lib files is `Path.expand("../..", __DIR__)`, which is the Piece root in this repository and the consumer root in an export. Keep reading the manifest for the list of lib files.

Change only the allowed test path, and in it only how the `no_network` test finds the root. No option, environment variable, search/glob, exporter change, manifest/README/runtime/dependency/pin edit, added or removed test or assertion, or ready Contract change. If the identical aggregate exposes a second defect, stop for the coordinator's scope decision rather than extending the repair.

## Acceptance

- The hosted full check on the exact head of the pull request passes `check-aggregate`, which runs `test/export_test.exs:122` with this Piece in the copied consumer. This is the named evidence; the small gate excludes the aggregate and is not a substitute. Record the run.
- Keep all 11 cases and their assertions unchanged. `mix test pieces/integration/ai-token-count/test` exits 0 with 11 passing cases.
- Run `mix check --piece "$(git merge-base origin/main HEAD)"` and `git diff --check` before delivery. Record exact commands, exit codes and any unavailable service without claiming an unexecuted check passed.
- Record the covering full-main result after the merge; unrelated merges and publication remain frozen until current main is green.

One worker owns the claimed branch/worktree. Keep the correction to this test-portability defect and existing facilities; ask the coordinator before expansion. Record the inspected diff and evidence in the PR. One independent review under AGENTS.md section 6.
