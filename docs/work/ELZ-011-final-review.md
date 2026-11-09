# ELZ-011 final independent production review

Reviewer: an independent review session.
Reviewed head: `694fda8a797fa2fe7535e6be1ca164f86483d281` on `task/ELZ-011`
(`<worktrees>/elzoo-ELZ-011`). Source, metadata and test commit: `36384d4e90cf1487f17dfbb41322a06e59766ae0`.
Diff base: `origin/main` = `a5f0e630f61e93893f1a2c706268226681ca593a` (43 files, +4813/-23).
Earlier reports: `/tmp/elz011-early-review-report-0f974e4c.md`, `/tmp/elz011-focused-rereview-report-0f974e4c.md`.
This is a review. It is not merged acceptance.
I changed no tracked file, issue, branch or pin. `git status --short` was empty after every command and HEAD stayed `694fda8`.

## Verdict

**CONDITIONAL. I found no blocking defect in send authority, identity, recovery or the owner/Oban composition.** One test must be added before the PR (F1), and one race needs a fix or a written limit (F2). Everything else is a recommendation.

- The gates G1-G9, the R1/R2/R3 amendments and the D1-D5 text are implemented and match the approved wording.
- Safety held in every adversarial run: one physical send, no second dispatch without a durable ground.
- F1 (required): the new acceptance bullet asks for a negative control on the response size bound. None exists. The bound works, but no test fails if it is removed.
- F2 (fix or document): two live executions of one job can cancel a healthy Dispatched job. It is safe but wrong, and the host loses the wake-ups.

## Evidence

| Check | Command or source | Result |
| --- | --- | --- |
| Head, tree, base | `git rev-parse HEAD`, `git status --short`, `git rev-parse origin/main` | `694fda8a…`, empty, `a5f0e630…` |
| Scope | `git diff --name-only a5f0e63 HEAD` filtered to allowed paths | no file outside `pieces/core/effect`, `pieces/assembly/http-job`, `docs/work/ELZ-011*`, `docs/plans`, `LEDGER.md`, `registry/catalogue.json`, the task file and `.claims/ELZ-011.md`. `git diff a5f0e63 HEAD -- mix.exs mix.lock .github scripts lib config` is empty. |
| Task and live issue | `wc -c`, `shasum -a 256`; `gh issue view 11 --json body` | 4391 bytes, `617508c8…a8f`, byte-equal to the live issue |
| Roadmap | `python3 scripts/check-roadmap.py`, then `--live` | both pass (139 links); manifest SHA-256 of both `piece.json` files match `release-plan.json` |
| Whitespace | `git diff --check a5f0e63 HEAD` without `docs/work/*.patch` | exit 0. The only range warnings are the historical patch context lines, as the author said. |
| Targeted tests | `mix test pieces/core/effect/test pieces/assembly/http-job/test --seed 0` (own DB, dispatched env) | exit 0, `Result: 24 passed` (`/tmp/elz011-final/targeted.log`) |
| Standalone export | `mix run docs/work/ELZ-011-export-check.exs` | exit 0, `Result: 216 passed`, `HTTP_JOB_NO_ROOT_APPLICATION`, `HTTP_JOB_COMPILER_FREE_RUNTIME_OK` (`export-check.log`). The author had run the second marker only in a separate stage; I ran the whole utility at this head. |
| Log leakage | `grep` of both logs for `fixture-secret`, `secret payload` | 0 hits |
| My race tests | `/tmp/elz011-final/race_scratch_test.exs`, `race_hold_test.exs` | F2 reproduced (below) |
| My mutation tests | `/tmp/elz011-final/mut_scratch_test.exs`, `size_scratch_test.exs` | F1 and F3 reproduced (below) |

I did not rerun the full `mix check` (the author records exit 0 at 06:57:53Z with 32 + 637 passed). I rely on that record for the full-suite result, the ledger regeneration and the aggregate (44) consumer.

## Findings (most severe first)

### F1 — MEDIUM, required before PR: no negative control for the response size bound

The new acceptance bullet says "the total request time, response size bound and slow-drip stall are executable with negative controls". Time and slow-drip have one (the `Call` timer mutant). The size bound has none.
- Reproduction: `/tmp/elz011-final/mut_scratch_test.exs`, test `MUTANT: streaming response-size guard removed…`. I replaced `<= Wire.limit(),` with `<= 1_000_000_000,` in `adapter.ex`, in memory, and ran the author's `:oversize` scenario. It still passes. The 16385-byte body is also refused later by `Wire.json`, so the test cannot see the streaming guard.
- The guard itself works. `/tmp/elz011-final/size_scratch_test.exs` serves a 50 MB body: unmutated, the server could write only 851,968 bytes (19 ms); with the guard removed it wrote 50,003,968 bytes (55 ms). The result tag was `receipt_invalid` in both runs.
- Required: add a test that streams a large body and asserts that the server's accepted byte count stays far below the stream size, plus a source mutant that removes the guard and fails the same assertion. My scratch test is a working sketch.

### F2 — MEDIUM, fix or document: concurrent executions cancel a healthy job

Two live executions of the same job (a Lifeline rescue of a running job, or any duplicate wake) can both read `Intended`. The loser's `advance(:dispatch)` returns `{:error, :not_dispatchable}`, and the frozen table turns that into `{:cancel, :not_dispatchable}`. The same pattern exists for rearm (`:not_rearmable` becomes `{:cancel, :exhausted}`).
- Reproduction A: two `perform/2` calls with the owner suspended, then resumed. Result in 3 of 3 runs: `[snooze: 2, cancel: :not_dispatchable]`; 1 wire request; intent `Confirmed`.
- Reproduction B: real Oban, `Oban.Engine.rescue_jobs` while a call is blocked, send held. In 3 of 4 runs the job row ended `cancelled` while the intent was `{:Dispatched, :Fresh, 1}`; 1 wire request. No more polls are scheduled for that job.
- Impact: send safety is intact. The job is mislabelled, and liveness depends on the host calling expiry. The README already says the host must continue expiry after a job is cancelled while Dispatched, but it does not say that a benign race can cause this.
- Recommended fix, within the approved table: when dispatch or rearm returns `:not_dispatchable` or `:not_rearmable`, reread the status once and cancel only if the phase is still Intended (or Definite). Otherwise act on the new phase. The existing duplicate-wake test (`live Oban rescue…`) should also assert the final job state.
- If root prefers to keep the code, the README must name this race.

### F3 — LOW: failure tags are not asserted per row

`send_effect/1` is never called directly for each status. My mutants that map 5xx to `transport_error` and redirect to `http_4xx` pass every test (`mut_scratch_test.exs`, second test). The labels have no effect through the owner, so this is not a safety defect. The new acceptance bullet "every HTTP and transport outcome maps to a frozen … row" is better served by a direct table test against the fixture modes.

### F4 — LOW: error retries can precede a send task

`{:error, :owner_unavailable}` uses Oban backoff, which starts at 1 s. R3 sets at least `ceil(total_ms/1000)+1` s for scheduled polls only. A retry after a failed control call can therefore poll while the send task still runs and cost one counted `Lost` event (`:task_start`). The README sentence "every scheduled poll delay" is accurate; just do not read it as covering retries.

### F5 — LOW, accepted residual: polling before the deadline is not bounded

`deadline_unix_ms` can be up to the 64-bit maximum. A Dispatched intent is polled every `poll_seconds` until `deadline + grace`. The `ceil(grace/poll) <= 512` check does not cap this. Root accepted this (R3 text), and the README states it. The optional admission-window cap would remove it.

### F6 — LOW: authentication uses the transport pool

`Adapter.authenticate/2` runs inside the owner and borrows `transport_supervisor`. If a poll task holds the only slot, a valid completion can be refused (a retained refusal, not a confirmation). This fails closed and a later poll recovers it. It is not exercised by a test.

### F7 — INFO

- `origin?/1` accepts `http`. Credentials can then travel in clear text if the host chooses it. The README names TLS as a host Need; one sentence on `https` would help.
- `Elzoo.HttpJob.cancel/3` returns `%{cancelled_jobs: n, external_outcome: :unknown}`, not an Envelope DeliveryResult as the first proposal said. Clarification 7 is met.
- Admission tests cover most refusals but not a missing `deadline_unix_ms` or a wrong `schema_id`. The code refuses both by inspection.
- Receipt `kind` may contain bidirectional format characters (controls are refused). It is never logged.

### Before the PR

`.claims/ELZ-011.md` is still tracked, so `python3 scripts/check-claims.py` exits 1 ("Remove tracked claim metadata"). The author states this is intended. Remove it in a later commit and keep the claim commit in history.

## Disposition of the gates and amendments

| Item | Status | Evidence |
| --- | --- | --- |
| G1 chronology, bounded transport | CLEAR | `adapter.ex`: typed no-send only from the pre-checks and the explicit credentials return, before `Req`. Every timer expiry is `transport_timeout`. Tests: hung credentials stay Dispatched with no wire entry; slow-drip bounded by the real timer; timer mutant fails. Inner task uses a different pool; `configure` rejects equal transport and caller pools. |
| G2 origin binding | CLEAR | `configure` and every send compare origin with `provider_account` and the binding digest; changed-origin test gives a permanent refusal with no wire entry. |
| G3 admission mapping | CLEAR | `http_job.ex admission/2`: kind `command`, host tenant, `idempotency_key` as fifth field (not `message_id`), explicit deadline, payload bytes unchanged, capability, operation, schema, trusted refused, overflow refused. Minor test gaps in F7. |
| G4 raw bytes | CLEAR | `wire.ex`: ordered-object duplicate rejection, size, depth, node, key length, strict `version` and `ack`, controls, no atom creation. Same checks on request and response. Jason 1.4.5 edge cases from my earlier probe still apply. |
| G5 authenticated Confirmed | CLEAR | PostgreSQL tests: real HMAC loopback to Confirmed; wrong key, digest and MAC retained as refusals; duplicate completion; late contradictory completion quarantines. |
| G6 rescue and Lifeline | CLEAR with F2 | Lifeline frees an orphan `executing` row that `retry_job` ignores; live rescue gives one wire request. Final job state not asserted (F2). |
| G7 caller capacity and unknowns | CLEAR | Caller-pool saturation returns `owner_unavailable`; suspended owner then retry gives one wire request; observer throw and hang are contained. |
| G8 actual-source mutants | CLEAR except F1, F3 | Normalizer (retention, trust, ack, atoms), retry, redirect, request path, bypass of the intent and the timer all fail as stated. Size guard and tag labels are not covered. |
| G9 validation and export | CLEAR | Author's full check record; my 24-test run and my full export-check run (216 passed, both markers). Independent diff review is this report. |
| R1 wrapper wording | CLEAR | Task Scope uses "wraps an unchanged, separately validated Envelope command"; `Elzoo.Effect` adds only three fields and delegates to `Elzoo.Envelope.decode/1`. |
| R2 quarantine | CLEAR | `http_job.cure`: quarantined Intended or Dispatched gives `JobOperator`, checked before any dispatch, poll or rearm. Test: no new wire entry after the cancel. |
| R3 every poll delay | CLEAR | `valid_limits?` requires `poll_seconds` from `ceil(total/1000)+1` to 30 (my scratch run was rejected with 2 s at total 2000 ms). See F4 for retries. |
| D1-D5 | CLEAR | Task diff equals the approved patch; live issue equals the task; dependencies in plan files. |

## Challenge areas

- **core/effect placement.** The wrapper is exactly the approved R1 B wording. No duplicate Envelope field; `trusted` is accepted as data and refused at admission; the assembly consumes the declaration. The Cure part is a small `valid` and `declared` pair. The claim is type and source audit only, and README says so.
- **Job table.** The Cure `decide` function matches the frozen table including R2. Unknown replies fall to `{:error, :owner_unavailable}`. Only F2 and F4 are open.
- **Real Oban.** Pinned 2.24.2 behavior used as documented. Unique-job re-wake through `retry_job` is exercised; duplicate enqueue returns the original ID.
- **Finite pools.** Finite size is a documented host Need; `configure` cannot read `max_children`. Saturation fails closed in the tests I ran.
- **No root Application or Cure compiler at runtime.** Confirmed by my full export-check run.
- **Evidence claims.** README and `ELZ-011-production.md` match what the tests show, except the size-bound negative control (F1) and the untested per-row labels (F3).

## Limits of this review

- I did not rerun the full `mix check` or the aggregate (44) consumer, and did not regenerate the ledger.
- Race outcomes in F2 depend on timing; reproduction B gave `cancelled` in 3 of 4 runs.
- My mutation and race tests are scratch copies in `/tmp/elz011-final/`; they compile mutants in memory and the repository files were never edited.
- Loopback only: no TLS, DNS, proxy or real provider. The authenticator is the fixture HMAC.
- The export check left a consumer directory under the system temp folder (`elz011-http-consumer-*`). Remove it and `/tmp/elz011-final`, `/tmp/elz011-rereview`, `/tmp/elz011-review-probes` when root has read this report.
