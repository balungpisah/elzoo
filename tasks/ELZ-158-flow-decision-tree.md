# ELZ-158 — Choose the flow by the class of the change, and give spike-only changes their own gate

- Dependencies: none
- Allowed implementation paths: `AGENTS.md`, `CLAUDE.md`, `docs/development/13-coordinator.md`, `docs/development/10-symbolic-ci.md`, `scripts/ci-change-class.py`, `scripts/test-ci-change-class.py`, `scripts/merge-queue.py`, `scripts/test-merge-queue.py`, `.github/workflows/symbolic-check.yml`, `scripts/check-ci-runners.py` and `scripts/test-ci-runners.py` (only if the guard must accept the new job), this task file and its row in `docs/plans/release-plan.json` with the generated plan views.

Owner direction (2026-11-14): the flow of a change must follow from its class, so that a small change does not pay the ceremony of a Piece task and a risky change does not get a lighter flow. Record the rule where every agent reads it.

Observed cost (ELZ-157, a pin bump of 4 lines in 3 spike files): a new issue, a publication pull request with its own check and review, a wait for green `main`, a label, a claim, then the implementation pull request with a second review and a full hosted check of about 20 minutes, because `scripts/ci-change-class.py` treats `spikes/` as a shared path.

## Outcome

1. **Decision tree in `AGENTS.md`.** A short section near the top that an agent reads before it picks a flow. It classifies a change by its paths and by what it changes, and names for each class: the flow (publication, claim, pull requests), the local gate, the hosted check, the review, and the merge path. The classes are at least: Piece task; documents only; spike only (new); a non-Piece dependency, advisory or harness repair of shared paths; CI, workflow or merge-queue change; a new or changed Piece Contract. Each class names what it may skip and why that is safe. The tree promises only checks that CI and the queue run after this task. The existing sections stay the detailed rules; the tree points into them and does not repeat them.
2. **`CLAUDE.md`.** One line that points Claude Code agents to the decision tree in `AGENTS.md`. No copy of the rule (`CLAUDE.md` says workflow rules live in `AGENTS.md`).
3. **One-PR path for a coordinator-owned non-Piece change** (`AGENTS.md` and `docs/development/13-coordinator.md`). When the coordinator does the work itself and no other worker could claim the task (no output Piece ID, no Piece Contract change), the task file, its job row and the change may land in one pull request on `task/ELZ-###`: create the issue from the task file without the label `task`, claim the branch with the `gh api` lock, then commit the task file, the row (with the live body hash) and the change. The pull request closes the task issue and the issue that reported the problem. Every other rule stays: one independent review, exact-head hosted check, the queue.
4. **Spike-only change class.** A change is spike-only when it has at least one path below `spikes/ash_foundation/` or `spikes/gleam_ui/` and every path is such a regular file, or a path the documentation allowlist accepts (`tasks/` included) or one of the plan index/generated files (`docs/plans/release-plan.json`, `docs/plans/views.md`, `docs/plans/dependencies.mmd`). The same shape rules as the other classes: renames count both paths, no symlink or submodule, any doubt means "not spike-only". `scripts/ci-change-class.py` decides it; the workflow and the queue load the same file, as for the other classes.
   - Workflow: on a `pull_request` run of a spike-only change, `check-plan` runs its guards and `scripts/check-roadmap.py`, the five work jobs and `check-piece` are skipped, and a new job `check-spike` runs the Ash spike exactly as `mix elzoo.ash_spike` does (deps, `mix format --check-formatted`, `mix test --warnings-as-errors`, `MIX_ENV=test`) when a path below `spikes/ash_foundation/` changed, and prints one marker `ELZOO SPIKE CHECK PASSED`. The Gleam workflow already covers `spikes/gleam_ui/`. `check-hosted` accepts exactly this shape. A push run on `main` is always the full check.
   - Queue: accepts a spike run only when its own classifier says spike-only, on the exact head, hosted runners, the spike marker and no other marker; the same freeze rule and first-parent window as the small gate; the Gleam run stays required for a Gleam path.
5. **Local gate when the host lacks the services.** `AGENTS.md` section 5 states plainly that when a required local command cannot run on the host (for example no PostgreSQL 16 with pgvector, or no MinIO), the worker records the command and the reason and the hosted check is the evidence. This exists today in section 6; make it findable from the tree.

## Acceptance

- The decision tree exists in `AGENTS.md`, each class maps to checks that exist, and `CLAUDE.md` points to it.
- `python3 scripts/test-ci-change-class.py`, `python3 scripts/test-merge-queue.py`, `python3 scripts/check-ci-runners.py`, `python3 scripts/test-ci-runners.py` exit 0, with new tests: spike-only true and false cases (mixed with a Piece path, with `lib/`, with `mix.lock` at the root, rename out of `spikes/`, symlink, empty list), the workflow plan shape, and queue acceptance and refusal of a spike run (own classifier disagrees, extra marker, a work job ran, partial re-run).
- Negative control: a temporary edit that makes the classifier accept a root path as spike-only makes a new test fail; record it and revert it.
- Full `mix check` (or the recorded hosted substitution), `python3 scripts/check-roadmap.py --live`, `git diff --check`.
- The hosted check of this pull request is the full check; the first spike-only pull request after the merge records the time of `check-spike`.

## Limits

No change of runners, pins, the Piece small gate, the docs-only class or the freeze rule. The spike class skips the root tests: no root test or Piece consumes the contents of `spikes/`. Root code names spike paths only to run the spikes (`mix elzoo.ash_spike`, `scripts/benchmark-ci.py`), in cache keys, and as a path fixture of the selection test (`test/check_selection_test.exs`); this task states that in the CI guide. The root `--affected` fallback for spike paths stays unchanged.

One worker owns the claimed branch/worktree. One independent review under AGENTS.md section 6.
