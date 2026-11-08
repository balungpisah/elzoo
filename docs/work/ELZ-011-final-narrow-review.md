# ELZ-011 final narrow review (T1 and L2)

Reviewer: Orca session 0f974e4c-75e1-4daf-9a19-7720ad2b1633 (task_a610214fa2be, dispatch ctx_0cf6e61580e8).
Reviewed head: `094eff10b05ec9a60756f73f0faf77c3bec0fe3a` on `task/ELZ-011`
(`/Users/laptopdp/orca/workspaces/elzoo/elzoo-ELZ-011`). Local HEAD equals `origin/task/ELZ-011`.
Compared with my reviewed head `877357d72abc5a347574531b633dd955001ed3d9`. Current `origin/main` is `452caa1f8140d6ec1cfee6cea1119a65e1c87a11`.
Earlier reports: early (`0716e36`), focused (`7766446`), final (`694fda8`, CONDITIONAL) and incremental (`877357d`, CONDITIONAL on T1).
`docs/work/ELZ-011-incremental-review.md` is byte-equal to `/tmp/elz011-incremental-review-report-0f974e4c.md` (`cmp` exit 0).
I changed no tracked file, issue, branch or pin. `git status --short` was empty after every command and HEAD stayed `094eff1`.

## Verdict

**CLEAR. I have no blocking findings.** This is a review verdict. It is not merged acceptance; the root queue still runs the full check on the exact PR head.

I carry forward my product, authority and liveness clearance for F1-F7, G1-G9, R1-R3 and D1-D5 from the incremental review at `877357d`. The product source, Cure, manifests, README, helper, plan files and Contract text are byte-identical to that head.

## What changed since 877357d

Task-authored commit `477799b` (6 paths):
- `pieces/assembly/http-job/test/elzoo/http_job_test.exs`: two inserted lines (T1).
- `docs/work/ELZ-011-export-check.exs`: 4 changed lines (L2).
- `.claims/ELZ-011.md`: deleted (the claim commit stays in history).
- Three docs: `ELZ-011-incremental-review.md` (my report), `ELZ-011-production.md`, `ELZ-011-review-fixes.md`.

Normal merge `f70ffa4` (parents `477799b` and `452caa1`, no conflict) brings `origin/main` (ELZ-056 CI runner admission). Docs-only commit `094eff1` records the evidence.

Inherited from main, not task-authored: `.github/workflows/symbolic-check.yml`, `AGENTS.md`, `docs/development/10-symbolic-ci.md`, `scripts/check-ci-runners.py`, `scripts/merge-queue.py`, `scripts/test-ci-runners.py`, `scripts/test-merge-queue.py`, `tasks/ELZ-056-contabo-backend-runner.md`.
- `git diff --stat origin/main HEAD -- .github scripts tasks/ELZ-056-contabo-backend-runner.md docs/development` is empty: they equal main.
- `git diff --name-only origin/main HEAD` filtered to the allowed ELZ-011 paths is empty: the PR diff against main has no out-of-scope path.

## T1 — CLOSED

The added lines, in the rescued-Oban test:
```
# Dispatch acknowledges task scheduling; the loopback request arrives later.
wait(fn -> Enum.count(Fixture.calls(c.f), fn {m, _, _} -> m == "PUT" end) >= 1 end)
assert Enum.count(Fixture.calls(c.f), fn {m, _, _} -> m == "PUT" end) == 1
```
- The strict `== 1` assertion stays right after the wait. The later strict `== 1` assertion after Confirmed is untouched. No existing assertion changed; `git diff 877357d 477799b` of the test file shows only the two `+` lines.
- The one-PUT invariant is not weakened. The wait only removes the race I found (`left: 0` before the server logged the request). If a second PUT arrived, the strict assertion and the final one would still fail. The wait is bounded (`wait/2` ends after 300 tries and then asserts).
- My results (own DB, dispatched env):

| Check | Result |
| --- | --- |
| `mix test pieces/core/effect/test pieces/assembly/http-job/test --seed 0` | exit 0, `Result: 29 passed` |
| rescued test alone, seeds 1-10 | 10 of 10 pass |
| the four heavy new tests as a group, no load, seeds 1-10 | 10 of 10 pass (before: 1 of 8 failed) |
| same group under 16 CPU burners on 8 cores, seeds 1-10 | 10 of 10 pass (before: 2 of 6 failed) |

I removed the burners afterwards (0 left). These counts show the race is gone on this machine; they are not proof for every schedule.

## L2 — CLOSED

New code: `suffix = Base.url_encode64(:crypto.strong_rand_bytes(12), padding: false)`, then `dir = …/elz011-http-consumer-#{suffix}` and `File.mkdir!(dir)`.
- 12 random bytes are 96 bits. `File.mkdir!` raises if the directory exists, so a leftover can never be reused silently. This fixes the collision I hit.
- The URL-safe characters (`-`, `_`) are valid in a directory name. Nothing downstream parses the name.
- Two consecutive runs with the default temporary folder, with old leftover directories present: both exit 0, `Result: 221 passed`, `RECEIPT_HASHES=114`, `HTTP_JOB_NO_ROOT_APPLICATION` and `HTTP_JOB_COMPILER_FREE_RUNTIME_OK` each once. The consumers were `/tmp/elz011-http-consumer-51xXIokvz0snGbT3` and `…-g9hxcKsPyM1luq5h`.

## Other checks

| Check | Result |
| --- | --- |
| `python3 scripts/check-roadmap.py` and `--live` | both pass (139 links) |
| `python3 scripts/check-claims.py` | exit 0, "No tracked claim metadata"; `git ls-files .claims` is empty |
| `python3 scripts/check-ci-runners.py` | passes ("no hosted fallback") |
| `python3 scripts/test-ci-runners.py` | `Ran 70 tests … OK` |
| `python3 scripts/test-merge-queue.py` | `Ran 38 tests … OK` |
| `git diff --check origin/main HEAD` without `docs/work/*.patch` | exit 0 |
| Documentation claims (`ELZ-011-review-fixes.md`, `ELZ-011-production.md`) | match what I measured: 29, 221, 114, ten reruns; the full 32 + 642 is stated as the record for source `087c1de` and not relabelled as a rerun |

## Remaining limits

- I did not rerun `mix setup`, the full `mix check` or the aggregate (44) consumer. The full run is the author's record at source `087c1de` (32 + 642, `ELZOO CHECK PASSED`). The merge brings CI policy, script and documentation changes only; none touches Pieces, Cure or providers. The root queue runs the exact-head full check before merge.
- Optional L1 gaps remain open and non-blocking: no committed test for the terminal result after a stale refusal, and none for the rearm same-action cancel through the runner. The author discloses both.
- One unretained observation stays open: the `HTTP failure tags…` test failed once under 16 CPU burners in my earlier campaign (250 ms total timer for seven requests) and passed in all later loaded runs, including today's 10.
- F5 (polling before a far-future deadline) and the loopback-only evidence (no TLS, DNS, proxy or real provider; fixture HMAC) remain accepted limits, as in the earlier reports.
- Scratch files: `/tmp/elz011-narrow/`, `/tmp/elz011-incr/`, `/tmp/elz011-final/`, `/tmp/elz011-rereview/`, `/tmp/elz011-review-probes/`, and the export consumers `/tmp/elz011-http-consumer-*` and `/tmp/elz011-incr/tmpdir/`. I left them for root; remove them after reading.
