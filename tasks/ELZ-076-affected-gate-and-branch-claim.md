# ELZ-076 — Refined flow: the affected run is the worker gate; the pushed branch is the claim

- Phase: P0 harness (`AGENTS.md`, `docs/development/01-workflow.md`, `docs/development/11-coordination-rules.md`, this task copy)
- Catalogue IDs: none
- Dependencies: ELZ-059 (#99) merged (the pull request's hosted run is a full `mix check` and the merge evidence); ELZ-071 (#131) merged; ELZ-075 (#140, PR #141) merges before this PR, because this task updates the audit rows that #141 adds.
- Review: one independent review of the diff (the acceptance rule of `AGENTS.md` changes; "evidence claims" are a protected surface). Automated review findings dispositioned in the PR.

## Outcome

Owner decision 2026-11-09 (16:10 WIB): implement the refined flow now; `AGENTS.md` is open for the edit. Two of the three pending decisions of the redundancy audit (ELZ-075) are taken: (1) the local gate before a push is the affected run plus the changed Piece's own tests, and CI owns the full run; (2) the atomic creation of the task branch is the claim, with no marker commit and no removal commit. The third (the task copy as the source of the issue body) stays pending because `scripts/check-roadmap.py --live` and the pins depend on the issue body.

## Scope

1. **`AGENTS.md`, "Verify the actual claim".** Replace "Targeted mix test commands are iteration feedback; report full mix check before review" with the gate: before every push, run `mix check --affected <base>` (the same selection code the hosted check used before ELZ-059) and the changed Piece's own tests (`mix test pieces/<family>/<name>/test`); CI owns the full run, which is the pull request's hosted `check-hosted` run on the exact head (a full `mix check`; a documentation-only change gets the short check of ELZ-071) and the queue's evidence. A local full `mix check` is still required after a dependency, configuration or toolchain change (`mix.exs`, `mix.lock`, `config/`, the Cure, Elixir or OTP pins) and when the affected selection cannot be computed; it is never a substitute for the hosted run. The PR body records which local command ran, with its exit code, and names the hosted run.
2. **`AGENTS.md`, "Claim: the Git push is the lock".** The atomic creation of the remote branch is the claim: `gh api -X POST repos/<owner>/<repo>/git/refs -f ref=refs/heads/task/ELZ-001 -f sha=<origin/main>`; HTTP 422 "Reference already exists" means another worker won. A plain `git push` is not used for the claim: the independent review of this task reproduced that a second push from the same base is a silent no-op and a later fast-forward push moves the winner's branch. No `.claims/` marker, no removal commit. The winner comments on the issue with the branch, the base SHA and the role-based agent identifier. `scripts/check-claims.py` stays as the guard that no `.claims/` file ever reaches a PR. `docs/development/05-stale-claims.md` and `06-toolchain.md` are updated for the same two rules.
3. **`docs/development/01-workflow.md`.** The local check paragraph says the same gate; the full `mix check` paragraph stays as the form used by CI and after dependency changes.
4. **`docs/development/11-coordination-rules.md`.** Section 1 (worker caps): the one-full-check-at-a-time cap applies only to the rare local full check; the host full-check slot is retired. Section 9 table: rows 1, 5 and 6 move from "pending owner decision" to "decided 2026-11-09 (ELZ-076)".
5. **Task copy** `tasks/ELZ-076-affected-gate-and-branch-claim.md`, byte-equal to the live issue body.

## Acceptance

- [ ] The three documents say the gate and the claim rule as above, with no contradiction left (grep for "full mix check before review", ".claims" procedure steps, "slot").
- [ ] `scripts/check-claims.py`, `scripts/check-roadmap.py` exit 0; `git diff --check` clean.
- [ ] Hosted pull request run green (full run: `AGENTS.md` is not in the documentation-only allowlist); merged through the queue on that run.
- [ ] One independent review of the diff recorded (agent identity, reviewed SHA); automated review findings dispositioned.

## Limits

Words only: no script or workflow changes. A change whose affected selection misses a dependency fails first in the hosted run (about 20 minutes), not locally; the selection runs the root suite in full when a shared path changes, so this is rare and the hosted run is free. The affected run narrows little for a Piece PR whose final step also touches `tasks/`, `LEDGER.md` or the registry (any path outside `pieces/<family>/<name>/` selects everything); the gain is on the pushes before that final step. The claim rule depends on the reference API refusing to create an existing branch (HTTP 422); a plain push would not refuse it.
