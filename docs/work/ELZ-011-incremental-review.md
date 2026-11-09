# ELZ-011 incremental independent review

> Redacted before publication (ELZ-070): local paths, session, dispatch, task and message ids, the test database name and role, and runner and machine names are replaced by placeholders or role words; hashes and byte-equality records in this file refer to the unredacted text.

Reviewer: an independent review session.
Reviewed head: `877357d72abc5a347574531b633dd955001ed3d9` on `task/ELZ-011`
(`<worktrees>/elzoo-ELZ-011`). Fix/source commit: `087c1de1618d2b4987b33058494983344a6274d9`.
Compared with: `694fda8a797fa2fe7535e6be1ca164f86483d281` (my CONDITIONAL review, F1-F7).
I carry forward my earlier reports where I say so. This is a review, not merged acceptance.
I changed no tracked file, issue, branch or pin. `git status --short` was empty after every command and HEAD stayed `877357d`.

## Verdict

**CONDITIONAL, with one test-only item (T1). I found no blocking product, authority or liveness defect.**

- F1 is closed. F2 is closed in the product code. F3-F7 are closed.
- T1 (required before the PR): the new test `live rescued Oban job retains wakeups…` has a timing race in one assertion. It failed in 3 of about 60 runs, always at the same line. A false red in `mix check` would block the PR.
- Two small coverage gaps and one utility problem are recommendations (L1, L2).

## Delta I reviewed

`git diff --stat 694fda8 HEAD`: 7 paths, +520/-11. Source commit `087c1de`: `http_job.ex`, `README.md`, the owner test file and its helper. Commit `877357d` changes docs only (`ELZ-011-production.md`, `ELZ-011-review-fixes.md`; `ELZ-011-final-review.md` is the added copy of my report).
- `cmp /tmp/elz011-final-review-report-<session id>.md docs/work/ELZ-011-final-review.md`: byte-equal. My report is preserved.
- No change to `piece.json`, Cure, `pieces/core`, `tasks`, `registry`, `LEDGER.md`, `docs/plans`, `mix.exs` or `mix.lock` (`git diff` of those paths is empty).
- The test file diff is one hunk at the end (`@@ -792,4 +792,231 @@`). All original test bytes are intact. Five tests are appended; helpers `adapter_request/2`, `with_snapshot_gate/2` and `refused_race/3` are added.

## Evidence

| Check | Command or source | Result |
| --- | --- | --- |
| Head, tree | `git rev-parse HEAD`; `git status --short` | `877357d7…`; empty |
| Targeted tests | `mix test pieces/core/effect/test pieces/assembly/http-job/test --seed 0` (own DB, dispatched env) | exit 0, `Result: 29 passed` (`/tmp/elz011-incr/targeted.log`) |
| Full http-job and effect files, 12 runs, no load | `mix test pieces/core/effect/test <http_job_test.exs> --seed N` | 11 runs `29 passed`; 1 run `28/29` (the T1 test) |
| Same files under 16 CPU burners, 5 runs | same, with 16 `yes` processes on 8 cores | 5 of 5 `27 passed` (http-job file only) |
| The four new heavy tests as a group, no load, 8 runs | `--only line:` filters | 7 pass; 1 run fails (T1 test) |
| The same group under load, 6 runs | same | 4 pass; 2 fail (both the T1 test) |
| Standalone export | `TMPDIR=/tmp/elz011-incr/tmpdir mix run docs/work/ELZ-011-export-check.exs` | exit 0, `Result: 221 passed`, `RECEIPT_HASHES=114`, `HTTP_JOB_NO_ROOT_APPLICATION`, `HTTP_JOB_COMPILER_FREE_RUNTIME_OK` (`export-check2.log`) |
| Roadmap | `python3 scripts/check-roadmap.py` and `--live` | both pass (139 links) |
| Whitespace | `git diff --check 694fda8 HEAD` | exit 0 |
| Log leakage | `grep` for `fixture-secret`, `secret payload` in the export log | 0 hits |
| Count arithmetic | author: 29 tests = 24 + 5; root 642 = 637 + 5; export 221 = 216 + 5 | consistent with my 29 and 221 |

I did not rerun the full `mix check` (the author records exit 0, 32 + 642, `ELZOO CHECK PASSED` at 2026-11-08T07:30:45Z). I rely on that record and on my 221-test export run.

## F1 — CLOSED

New test `stream size guard closes a large response early and its removal violates the bound`: a 16 MiB fixture stream, with the server counting bytes its TCP send accepted. Normal source: `bytes < 8 MiB`. In-memory mutant `<= Wire.limit(),` to `<= 1_000_000_000,`: `bytes == total` and the identical bound assertion fails. Then it restores the source and passes again.
- It passed in every run I made (targeted, 12 full-file, 5 loaded full-file, 14 group runs).
- It matches my own earlier measurement: 851,968 bytes accepted with the guard, 50,003,968 without.
- The mutant check uses a 3000 ms total in the test config, not the 250 ms default, so the timer cannot cut the mutant's read. Good.
- Limit: this is loopback socket evidence with kernel buffering. It is not an exact allocation bound, and the author says so.

## F2 — CLOSED in the product

`confirm_refusal/4` (`http_job.ex`): after `:not_dispatchable` or `:not_rearmable`, the runner reads the status once and reuses `Policy.action/2`.
- Same action selected: keep the refusal (`{:cancel, :not_dispatchable}` or `{:cancel, :exhausted}`).
- Another actionable action (`JobDispatch`, `JobPoll`, `JobRearm`): `{:snooze, c.poll_seconds}`.
- Anything else (finish, operator, exhausted, unavailable): `act(c, pid, terminal)` returns its result.
I read the code for authority. It issues one `Intent.status` read and no `advance`. The `terminal` clause cannot recurse into an owner command, because the earlier clause takes all three actionable atoms. A failed or timed-out status read returns `{:error, :owner_unavailable}`. No path creates a send, poll or rearm.

My independent results:
- My earlier reproduction A (two concurrent executions): was `[snooze, cancel: :not_dispatchable]` 3 of 3; now `[snooze: 2, snooze: 2]` 3 of 3 (`race_scratch_test.exs`).
- My earlier reproduction B (real Oban rescue, held send): was job `cancelled` in 3 of 4 runs; now the job is never cancelled in 4 of 4. A 12-second trace shows `scheduled`, then `executing` and `retryable` only because my scratch `resolve_intent` blocks on later wakes (my fixture, not the product). One PUT in every run (`race_hold_long.exs`).
- Author's tests: deterministic stale dispatch and rearm on PostgreSQL; the two refusal mutants each return `{:cancel, …}` and fail the same `{:snooze, 2}` assertion.
- Instrumentation review: `with_snapshot_gate/2` compiles one combined source (gate + optional mutant) and registers the Oban runner after compilation. The gate sits before `Policy.action`, after the status read, and only blocks the runner process. It does not touch the owner, Store, replies or `confirm_refusal`. It cannot hide the fix and it invents no owner state. The source is restored in `after`.

Authority, liveness and count/copy: no regression found. Safety is unchanged (one PUT in every run). Liveness improves: a duplicate execution no longer ends the job. README text for the refusal rule matches the code. The frozen table rows stay the same in the stable case; the change is "cancel only if the reread still selects the same action". I recommend root note it as a refinement of the frozen row; no task or Contract text changed.

## Findings

### T1 — MEDIUM, test-only, required before PR: race in the Oban rescue test

Test `live rescued Oban job retains wakeups after stale dispatch and then confirms` (`http_job_test.exs`, assertion at line 961):
```
wait(fn -> Elzoo.Jobs.state_by_id(name, id) == {:ok, {id, "scheduled"}} end)
assert Enum.count(Fixture.calls(c.f), fn {m, _, _} -> m == "PUT" end) == 1
```
`advance(:dispatch)` returns when the task is scheduled, not when the request has reached the fixture server. The assertion can run before the server logs the request: `left: 0, right: 1`.
- Observed: 1 of 12 full-file runs (no load), 1 of 8 group runs (no load), 2 of 6 group runs (16 CPU burners). Always `left: 0` at line 961; never seen when the test ran alone (25 of 25 pass) or in 20 later idle group runs.
- Not a product defect: the same run later expects one PUT and `Confirmed`, and every passing run has exactly one.
- Fix: add `wait(fn -> Enum.count(…"PUT"…) >= 1 end)` before the strict `== 1` assertion, and keep the strict `== 1` checks (also the one at the end). My copy with that line passed 25 of 25 and 20 of 20, but the sample is too small to prove the race is gone.
- A second load-sensitive case: `HTTP failure tags preserve the frozen rows…` failed once in my first loaded run (`match (=) failed`, log not kept) and passed in 14 further loaded runs. It uses the 250 ms total timer for seven requests. I record it as an observation only.

### L1 — LOW: two refusal branches have no committed test

- Terminal result after a stale refusal. README says "a terminal phase returns its terminal result". My scratch test (`/tmp/elz011-incr/scratch_extra_test.exs`) shows the real code returns `:ok` when the other execution already confirmed. A mutant `terminal -> {:snooze, c.poll_seconds}` returns `{:snooze, 2}`, and no committed test fails on it.
- Rearm same-action cancel (`{:cancel, :exhausted}` after a refusal that still selects `JobRearm`) is exercised only through a replaced `confirm_refusal` call, not through the runner with a real owner. The dispatch same-action branch is covered by the existing `{:cancel, :not_dispatchable}` expiry test.
Recommend adding the terminal case (my `terminal_race` is a sketch) and a rearm same-action case.

### L2 — LOW: export utility is not rerunnable

`docs/work/ELZ-011-export-check.exs` names its directory `elz011-http-consumer-<System.unique_integer>`. The number is small and repeats in each VM. A directory left by an earlier run made my second run fail at once (`ArgumentError: refusing to overwrite modified/conflicting file`, exit 1, 5 seconds). Setting `TMPDIR` to a clean folder avoided it. Suggest adding the OS time or process id to the name. This file is documentation tooling, not production source.

### Carried forward

- F3 closed: nine tags asserted directly (seven fixture rows plus the two preflight tags); both of my tag mutants fail the exact-tag assertion. I ran the test file; the test passes in all my runs.
- F4, F5, F6, F7 closed in README and admission tests (missing deadline, wrong schema). F5 stays an accepted residual.
- Still before the PR: `.claims/ELZ-011.md` is tracked and `scripts/check-claims.py` fails on it by design. The author defers removal until this review clears.

## Limits

- Not rerun by me: full `mix check`, aggregate (44) consumer, ledger regeneration, `mix setup`.
- Flake rates come from about 60 runs on one machine; they are indications, not rates.
- Load tests used 16 `yes` processes on 8 cores. I removed them (`pkill yes`, 0 left).
- Mutants and races run in scratch copies and in memory; repository files were not edited.
- Loopback only: no TLS, DNS, proxy or real provider. The authenticator is the fixture HMAC.
- Scratch files: `/tmp/elz011-incr/` (includes a consumer copy in `tmpdir/`), `/tmp/elz011-final/`, `/tmp/elz011-rereview/`, `/tmp/elz011-review-probes/`, and an older `elz011-http-consumer-*` directory under the system temp folder from my first export run. Remove them after root reads this report.
