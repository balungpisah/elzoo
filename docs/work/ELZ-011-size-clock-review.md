# ELZ-011 review of the stream-size test correction

> Redacted before publication (ELZ-070): local paths, session, dispatch, task and message ids, the test database name and role, and runner and machine names are replaced by placeholders or role words; hashes and byte-equality records in this file refer to the unredacted text.

Reviewer: an independent review session.
Reviewed head: `a3d3b540d4dcadc74ac855c6dc9c8eb73c407288` on `task/ELZ-011`, one local commit on top of `e452b7fadc4c9cf7f6e24a1cf6b9380bbefa03cc` (`origin/task/ELZ-011`, not pushed).
Worktree: `<worktrees>/elzoo-ELZ-011`. I changed no tracked file. `git status --short` was empty after every command and HEAD stayed `a3d3b54`.
Earlier clearance: final narrow review at `094eff1` (CLEAR). It carries forward for the product source, which this commit does not touch.

## Verdict

**CLEAR. I have no blocking findings.** The correction isolates the size oracle from the transport clocks, and it keeps every guarded and mutant assertion. This is a review of the test correction only. The fresh full `mix setup`, `mix check` and green PR CI that root requires are still pending; I did not run them.

## The delta (4 paths, +81/-2)

- `pieces/assembly/http-job/test/elzoo/http_job_test.exs` (+6/-1): in the stream-size test, the config line `cfg = %{c.cfg | total_ms: 3000, receive_ms: 1000, poll_seconds: 4}` becomes
  - `clocks = [total_ms: :infinity, receive_ms: :infinity, connect_ms: :infinity]`,
  - `assert {:error, :configuration} = H.configure(Keyword.merge(c.opts, clocks))`,
  - `cfg = struct(c.cfg, clocks)`.
- `pieces/assembly/http-job/test/support/http_job_test_helper.exs` (+3/-1): the stream-only server sets `send_timeout: :infinity` (was `2000`).
- `docs/work/ELZ-011-production.md`, `docs/work/ELZ-011-review-fixes.md`: status note and evidence section.
- No production source, Cure, manifest, README, plan file or other test file changes (`git diff --name-only e452b7f HEAD` lists only these four).

## Does it isolate the oracle without weakening it?

Yes. Reasons, with my evidence:
- **Cause confirmed.** With the old test, a guard-removed mutant that reads 16 MiB slowly hits the 3000 ms outer timer. The old test then fails on `{:error, :transport_timeout, :unknown}` instead of `{:error, :receipt_invalid, :schema}`. I reproduced the exact CI mismatch: my scratch copies add `Process.sleep(20)` per streaming callback in the mutant only (`/tmp/elz011-sizeclock-rev/old_slow_test.exs`, old helper, no load): exit 2, 4.9 s, `left: {:error, :receipt_invalid, :schema}`, `right: {:error, :transport_timeout, :unknown}`.
- **Fixed.** The same delay with the new test and helper passes (`new_slow_test.exs`, exit 0, `Result: 1 passed`, 21.6 s). The mutant now runs to schema refusal, past the old 3 s limit.
- **Assertions intact.** The test body after the config lines is unchanged: guarded run returns `{:error, :receipt_invalid, :schema}` and the server accepted `< div(total, 2)` bytes; the mutant run needs the same tag, `bytes == total`, and the same bound assertion must raise; then the restored source passes again. Transport timeout is not accepted as an alternative.
- **The guard is the only early-close mechanism.** With no total, receive or connect clock, nothing else can end the guarded run early. The guarded run passes only when the client closes the connection, because the server's send has no timeout and so returns only on a closed peer. I read this as a stronger oracle than before: the old 2000 ms server timeout could also end a send without a close.
- **Public configuration still rejects the values.** I checked each clock alone: `H.configure(Keyword.put(c.opts, key, :infinity))` returns `{:error, :configuration}` for `total_ms`, `receive_ms` and `connect_ms` (`new_extra_test.exs`, `RESULT all three infinite clocks individually rejected`). The new assertion in the test therefore guards a real contract, and `c.opts` is valid (`{:ok, _}`).
- **Other timed tests unchanged.** The separate slow-drip and total-time tests still use the timed config (`total_ms: 250`) and still pass.
- **Server side.** The stream mode is used by this one test only (`grep` of `{:stream`). The change cannot affect other fixture modes.

## Commands and results (own DB, dispatched environment)

| Check | Result |
| --- | --- |
| `mix test pieces/core/effect/test pieces/assembly/http-job/test --seed 0` | exit 0, `Result: 29 passed` |
| same, under 16 `nice -n 15 yes` burners on 8 cores | exit 0, `Result: 29 passed` |
| stream test alone, 8 seeds, under the same burners | 8 of 8 pass |
| old test + old helper vs delayed mutant (my scratch) | fails with the CI mismatch (above) |
| new test + new helper vs delayed mutant (my scratch) | passes |
| `mix run docs/work/ELZ-011-export-check.exs` (copied consumer, default temp folder) | exit 0, `Result: 221 passed`, `RECEIPT_HASHES=114`, `HTTP_JOB_NO_ROOT_APPLICATION` and `HTTP_JOB_COMPILER_FREE_RUNTIME_OK` once each |
| copied consumer files vs repo | the stream test body and the helper are byte-identical (diff exit 0, `cmp` exit 0) |
| `python3 scripts/check-roadmap.py`; `scripts/check-claims.py`; `git diff --check e452b7f HEAD` | pass; "No tracked claim metadata"; exit 0 |
| SHA-256 of the 12 evidence files named in `ELZ-011-review-fixes.md` | all 12 match |
| Burner processes after each run | 0 left |

The root and aggregate copies run the same test file, so the fix applies to them. I could not run the aggregate (44) consumer or the PR CI here.

## Limits and notes

- **Watchdog.** The doc says "ExUnit's 120-second watchdog". That is true for the root suite (`test/test_helper.exs`: `timeout: 120_000`) and for the export utility. Other consumers set their own value (the aggregate consumer uses the ELZ-037 rule; ExUnit's default is 60 s). In every case a hang ends in a test timeout, not a silent block. Normal run time is a few seconds.
- **What the oracle detects.** It detects removal of the streaming guard (full 16 MiB read). It does not detect a guard that is merely loosened to a value below 8 MiB. This limit existed before and is unchanged.
- **Residual load sensitivity.** Other tests still use short timers (the shared setup has `total_ms: 250`); the earlier unretained observation about the `HTTP failure tags…` test under heavy load stands. Nothing in this commit changes them.
- **Finite evidence.** The controlled delay is a scratch instrument on this host. The runs show the isolation works; they do not prove every schedule.
- **Still pending, as root states:** fresh `mix setup`, full `mix check`, push, and green PR CI on the exact head. This report is not merged acceptance.
- Scratch files: `/tmp/elz011-sizeclock-rev/` (mine), plus older `/tmp/elz011-narrow/`, `/tmp/elz011-incr/`, `/tmp/elz011-final/`, `/tmp/elz011-rereview/`, `/tmp/elz011-review-probes/` and export consumers `/tmp/elz011-http-consumer-*`. I left them for root to remove after reading.
