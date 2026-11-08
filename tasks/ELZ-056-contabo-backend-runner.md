# ELZ-056 — Admit the Contabo VPS contabo-elzoo-1 as a candidate backend runner

- Phase: P0 harness (CI; `.github/workflows/symbolic-check.yml`, `scripts/check-ci-runners.py`,
  `scripts/test-ci-runners.py`, `scripts/merge-queue.py`, `docs/development/10-symbolic-ci.md`)
- Catalogue IDs: none
- Dependencies: ELZ-040 (#69), ELZ-042 (#72), ELZ-043 (#73), ELZ-039 (#78), all merged;
  serial on CI policy files
- Review: independent review of the actual workflow and guard diff is required.

## Outcome

The owner rents a mostly idle Contabo VPS (`ratahq-ci-contabo-01`, Ubuntu 24.04, 8 cores,
23 GiB RAM) and decided on 2026-11-08 to use it for Elzoo CI. A repository-scoped runner
`contabo-elzoo-1` (runner id 24) is installed and online with labels `self-hosted`, `Linux`,
`X64`, `elzoo`, `contabo`. It had **no** `backend` label when this task opened, so no job was routed to it. This task
makes the repository accept the runner name, so a coordinator-run trial can add the label.

## Scope

- Workflow: `Verify approved backend runner` accepts `contabo-elzoo-1` and sets
  `ERL_FLAGS=+S 4:4 +SDcpu 1 +SDio 1` for it. No other workflow line changes. `runs-on` is unchanged.
- Guard: `scripts/check-ci-runners.py` pins exactly the new gate text. Add negative controls
  in `scripts/test-ci-runners.py`; no existing test is edited or weakened.
- Merge queue: `scripts/merge-queue.py` accepts `contabo-elzoo-1` as a backend runner name in
  its evidence check, with a new test in `scripts/test-merge-queue.py`. Without this the queue
  refuses a successful run from the new machine. This is the one shared change outside the
  stated workflow and guard files; it does not change any other refusal.
- Docs: `docs/development/10-symbolic-ci.md` gets a machine section (host facts, shared Docker
  daemon and the owner's decision quoted, resource mechanism with exact values, IPv4-only
  network, retired runner directory, rootless Docker as a possible follow-up only) and the CI
  machine policy now includes this user-rented VPS (owner decision 2026-11-08).
- `AGENTS.md` CI machine policy names the user-owned machines; this task records the VPS in
  `docs/development/10-symbolic-ci.md` and in the policy sentence of `AGENTS.md` only.

## Role: candidate until proven

The runner gets the `backend` label only after a trial passes. The coordinator adds the label,
dispatches `symbolic-check.yml` on the exact PR head and steers other runners so the job lands
on `contabo-elzoo-1`. The task records, before merge: run ID, job ID, runner name, duration,
cgroup memory peak, sampled CPU maximum, and `cpu.max` and `memory.max` read from inside the
job container (to show the Docker wrapper cap applies to real job containers).

## Acceptance

- [ ] `python3 scripts/check-ci-runners.py`, `scripts/test-ci-runners.py` and
      `scripts/test-merge-queue.py` pass. The old guard rejects the new workflow shape; the new
      controls pin the new shape (not all of them fail on the old guard).
- [ ] Independent review (separate agent session): identity, reviewed SHA, findings recorded on the PR.
- [ ] Trial evidence above recorded in the issue before merge.
- [ ] After the trial and before merge, a doc commit updates the status lines in
      `docs/development/10-symbolic-ci.md` (roles list and Contabo section) and `AGENTS.md`
      to the true state: backend label present or removed, trial result, no stale
      "candidate, not routed" text.
- [ ] Full `mix check` on the PR head and on the merge commit, with runner identity shown.

## Limits

Admitting a name is not proof of capacity or reliability. A passing trial is one observation.
The shared Docker daemon is not a sandbox: job containers can reach the host's other
containers. Rootless Docker is a possible follow-up, not part of this task. Runner label
assignment stays an account-level control; the guard does not prove host identity.
