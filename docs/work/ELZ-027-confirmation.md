# ELZ-027 narrow confirmation

Reviewer: Orca session `orca_session_id:94a44388-93b7-46b8-800c-209e75ebbfaf`, independent of the proposal author. Reviewed `origin/task/ELZ-027` at `3b5dbd011555f5f815631beb5703608525dfa112`; comparison base `957e2f598056d038f80fff753f37ada904e6562b`. This is a narrow read-only design confirmation, not evidence that implementation, proof or tests have run.

1. **BLOCKING — addressed in design.** The consumer owner holds a map of separate receiver histories keyed by schedule ID; each history uses sender 0 with generation and scheduled instant as the remaining key fields. The design specifies volatile, unbounded per-history retention, restart loss, retirement through `forget_schedule/2`, and re-emission after retirement; invalid IDs are refused. The planned real-receiver scenario covers two different schedules with the same sender, generation and instant emitting once each, duplicate suppression, generation changes and retirement. No test has run. The older re-review table still names `idempotency_message/3`, although the round-3 table and detailed design supersede it with `consumer_dedup/3`; clean up the stale name when implementing, and explicitly exercise duplicate presentations for each of the two schedules.
2. **Addressed.** Four fenced blocks preserve A1 before, A1 after, A1-rev2 before, and A1-rev2 after with literal historic task-copy wraps. The last block is a literal substring of the live issue; the live issue equals the applied task copy byte for byte and hashes to `1d1ea7504ebc53d39bb525906103771433a485d32b8e7a50eb132e8914393c22`. Statuses identify A1 as superseded, A1-rev2 as live, and A2 as withdrawn; the misleading before/now-live label is gone.
3. **Addressed.** G6 is byte-identical to the original review gate. Its adjacent note records the main coordinator's later decision that the issue's clock-port statement stands, distinguishes shell clock reads from the recipe's timer and cancellation, and plans the actual shell/timer boundary test.
4. **Addressed.** The summary assigns identify mutations to field-law failures and separate production-placement mutations to live-identity law failures, matching the negative-control specification.

The checked-in round-3 report is byte-equal to the supplied `/tmp` report. The branch-only `origin/main...3b5dbd0` diff contains the claim marker, work documents, synchronized task copy and release-plan metadata only; no implementation is present. The existing untracked `.reticle-setup-crash.log` was left untouched. Claim cleanup and all implementation/review gates remain future work.

Commands and exit codes:

- `git fetch origin --prune`: 0.
- `git rev-parse origin/task/ELZ-027 3b5dbd0 957e2f5`, `git status --short`, `git diff --stat 957e2f5 3b5dbd0`, `git diff --name-status origin/main...3b5dbd0`: 0.
- `git diff 957e2f5 3b5dbd0`, `git diff --check 957e2f5 3b5dbd0`, `git log --oneline --all -- tasks/ELZ-027-schedule-occurrence.md`, targeted `git show` of both work documents and idempotency README: 0.
- `git show 3b5dbd0:docs/work/ELZ-027-early-rereview3.md | cmp - /tmp/elz027-early-rereview3-837af235-08b1-4ef2-a656-deb217bc09e7.md`: 0.
- Python extraction and literal comparisons of the four proposal blocks against task copies at `c2c47af^`, `c2c47af`, `c2c47af`, and `bbc0eff`, comparison of A1 after and A1-rev2 before, and exact G6 comparison to the original review: 0; all true.
- `gh issue view 44 -R balungpisah/elzoo --json body`: 0; separate invocation piped to Python checked the live issue against the `bbc0eff` task copy, the final block and SHA-256: 0; all true.
- Initial `gh issue view ... --json title,body,comments` was canceled after delay: 130; the successful body-only checks above supplied the relevant live source.
- No Mix command, branch switch, repository edit, commit, push, issue comment or label change.

CLEAR-TO-IMPLEMENT
