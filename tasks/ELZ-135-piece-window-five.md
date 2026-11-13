# ELZ-135 — Widen the outstanding Piece merge window to five

- Dependencies: ELZ-129
- Allowed implementation paths: `scripts/merge-queue.py`, `scripts/test-merge-queue.py`, `AGENTS.md`, `CLAUDE.md`, `docs/development/10-symbolic-ci.md`, `docs/development/13-coordinator.md` only.

After ELZ-129 merges and current main is green, change the existing small-gate window from `count < 3` to `count < 5`. The count is the number of **all first-parent commits** already outstanding after the nearest qualifying successful covering main push, before the candidate merge; it is not a count of Piece merges alone. Counts 0–4 permit the candidate, including 4 producing a resulting count of 5; count 5 or greater refuses until a newer qualifying covering push reopens the window. Do not use `count <= 5` or `count < 4`.

Update only the matching window descriptions in the allowed guidance, including the coordinator Levels limit, to agree with the actual conservative first-parent counting. Preserve latest-covering-run, ancestry, hosted identity, exact head/current base, green parent, red-main freeze and repair guards. Each merge still gets a full main run; selected Piece evidence must never substitute for it. No workflow, skip logic, dependency or pin changes, new options, framework or unrelated guidance changes.

## Acceptance

- Exercise existing outstanding counts 3 and 4 as allowed and 5 as refused; demonstrate that a newer qualifying covering push reopens the exhausted window. Keep the second-parent, missing, failed, pending, partial/unreadable provenance, red-main freeze and immediately-before-merge recheck scenarios effective under the new boundary.
- Run `python3 scripts/test-merge-queue.py`, the applicable shared-path local gate `mix check --affected origin/main` and `git diff --check`; record results and exact-head hosted evidence under AGENTS.md. Do not weaken a guard or claim a selected check is full evidence.
- In the closing report identify ELZ-135 and state post-change red-main frequency only for an explicitly identified observed window, with its actual observation and denominator. If no post-change window has been observed, say so; do not speculate.

Owner decision: the separate independent review requirement is waived for this ELZ-135 publication and implementation only. Queue tests, normal guards, hosted evidence and all other requirements remain; do not claim an unperformed review. This waiver does not apply to other repairs.
