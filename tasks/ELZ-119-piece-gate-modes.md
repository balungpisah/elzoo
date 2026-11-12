# ELZ-119 — Reject removed tracked special files in the local Piece gate

- Dependencies: none
- Issue: #221.
- Allowed implementation paths: `lib/elzoo/check_selection.ex`, `test/check_selection_test.exs` only.

The local Piece gate's `piece_changes/3` checks filenames and the current filesystem with `File.lstat/1`. A deleted tracked symlink, or one replaced by a regular file, is accepted locally even though the hosted classifier checks old and new Git modes and requires the full check. This is selection disagreement, not a hosted merge-gate bypass or a Piece Contract change.

Inspect old and new tracked Git modes across the existing comparison from base commit to current working tree before accepting `piece_changes/3`. Refuse changed symlinks (`120000`) and gitlinks (`160000`) on either side, including removed entries. Preserve the filesystem check for untracked entries, path classifier, return shape and fail-closed behavior. Ordinary regular-file deletions remain eligible.

Reuse existing Git facilities and the disposable Git fixture. Do not change affected-mode selection, the Python classifier, workflows, queue, dependencies or toolchain. Add no configuration, generic parser framework or abstraction layer. Ask the coordinator before expanding scope.

## Acceptance

- Through `Selection.piece_changes`, a deleted tracked symlink, a tracked symlink replaced by a regular file, and a removed tracked gitlink each return an error; an ordinary tracked regular-file deletion under a Piece returns that Piece ID.
- Fixtures have the special mode in their base tree. Exercise committed and staged/working-tree changes without changing the comparison's meaning. Retain untracked-symlink and invalid-base coverage. Git failures and malformed mode data do not grant admission.
- Run `mix test test/check_selection_test.exs`. Demonstrate the new special-file regressions fail with the old admission logic in a disposable local worktree, then restore the fix. Run `mix check --affected origin/main` and `git diff --check`; record failures or unavailable services. No production test writes or live dispatch claim.
