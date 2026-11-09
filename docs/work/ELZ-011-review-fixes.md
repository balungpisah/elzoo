# ELZ-011 final-review fixes

> Redacted before publication (ELZ-065): the password part of local test-database URLs (`ecto://user:…@localhost`) and role commands is replaced by an ellipsis; the recorded commands are otherwise exact.

Independent reviewer: an independent review session,
head `694fda8a797fa2fe7535e6be1ca164f86483d281`, dispatch `ctx_44d327567ce3`.
[Original report](ELZ-011-final-review.md): CONDITIONAL, F1 required and F2 fix
or document; no blocking send-authority finding. This record tracks the delta,
not merged acceptance. No Contract amendment, dependency/pin change, protected
file edit or merged assertion edit is made.

## F1: streaming size negative control

The earlier 16,385-byte fixture was also rejected by JSON byte validation, so
it could not detect removal of the streaming guard. A new fixture streams
16 MiB and counts bytes accepted by the server TCP send calls. The test requires
early close below half that stream, permitting kernel/socket buffering above
the 16 KiB application limit. Removing the actual Adapter streaming guard
accepts the entire stream and fails the identical bound assertion; restoring it
passes again. Both results are receipt_invalid, deliberately showing why only
the error tag is insufficient. This is loopback streaming evidence, not an exact
wire allocation limit or whole-process memory proof.

## F2: stale refusal reconciliation

The runner now rereads the real owner once after not_dispatchable or
not_rearmable. It reuses the Cure action decision: the same action still selected
keeps the original refusal, a different actionable phase snoozes using the full
poll delay, and a terminal/unavailable phase returns its corresponding result.
There is no second dispatch/poll/rearm command in that wake, recursive retry, blind rearm,
new send authority or alteration of the owner/Cure Contract.

Two real PostgreSQL owners exercise deterministic stale dispatch and rearm
snapshots. Test-only compiled instrumentation pauses between the already-read
snapshot and action, without changing owner state, Store CAS or result replies.
The normal implementation snoozes, while reverting each refusal fix yields the
original cancel result and fails the same snooze assertion. A real Oban rescue
runs two executions from the same Intended snapshot, verifies the existing job
remains scheduled (not cancelled), then polls to Confirmed/completed with only
one physical PUT. The fixture registers the runner after instrumentation so
captured callbacks use the instrumented code; source is restored afterward.

## Lower findings

F3: direct Adapter table checks now assert all nine frozen tags across fixture
HTTP, pending, malformed, drop, timeout and explicit preflight rows. The two
reviewer-surviving tag substitutions each fail the exact expected-tag assertion.
F4/F5: README distinguishes one-second error backoff from scheduled poll delays;
pre-deadline and concurrent wake counts remain the already-approved limitations.
F6: README records transport-pool contention during authentication and the need
for a later poll or host reconciliation; no new capacity guarantee is claimed.
F7: README names HTTPS as host policy for real credentials; two new admission
cases cover missing deadline and wrong schema. Cancellation remains job count
plus unknown external outcome, and opaque kind strings remain unlogged.

All 24 previous tests/assertions are preserved byte-for-byte before the final
module end; five tests and helpers are appended. New fixture streaming support
is confined to this task's own test helper. Cure, manifests and metadata are
unchanged. A first test-development run was 27/29: nested mutation loading had
restored the original source before applying the scheduling gate, and the real
Oban runner had captured the pre-instrumentation function. The revised fixture
compiles each combined mutation once and registers after compilation; no
production assertion was weakened to resolve those fixture failures.

## Validation

Fixed source/test commit: `087c1de1618d2b4987b33058494983344a6274d9`.

`mix test pieces/core/effect/test pieces/assembly/http-job/test --seed 0`
exited 0: `Result: 29 passed`. Exact prefix for all Mix runs:

```sh
export LANG=en_US.UTF-8 LC_ALL=en_US.UTF-8
export ERL_FLAGS='+S 4:4 +SDcpu 1 +SDio 1'
export MIX_ENV=test
export ELZOO_TEST_DATABASE_URL=ecto://<test role>:…@localhost/<test database>
```

Fresh `mix setup` and full default `mix check` both exited 0 on the fixed source:
`Result: 32 passed` (Ash), `Result: 642 passed` (root), and `ELZOO CHECK PASSED`.
Completion: 2026-11-08T07:30:45Z; root stage elapsed 1000.4 seconds. Aggregate(44)
consumer test/runtime checks passed, total 261.5 seconds, as did all default
individual consumers. The updated standalone utility also exited 0: `Result: 221 passed`,
114 matching receipt hashes, `HTTP_JOB_NO_ROOT_APPLICATION` and
`HTTP_JOB_COMPILER_FREE_RUNTIME_OK`. This time the entire utility, including
its second compiler-free runtime stage, ran as one command. Independent
incremental review and PR remain. The earlier source's 32+637 and
reviewer-reproduced export216 are historical evidence.

Targeted log: `/tmp/elz011-proposal/review-fixes-targeted.log`, SHA256 `736f8dde15431103807a4ceb53e7ec8f3c93fed35674ff538f929ddc7db87cbe`.

`/tmp/elz011-proposal/review-fixes-setup.log` SHA256 `cb70138e021907bc84d4539c492ea7c0a1e57e2b75fd34d6c0810821bdc530cb`.

`/tmp/elz011-proposal/review-fixes-full-check.log` SHA256 `4ab20aac82e0d98497ee4030f083663c450b6a431308d29c2d51e3d7ea973df6`.

`/tmp/elz011-proposal/review-fixes-export.log` SHA256 `5d50173b82d0f388b2d079bd47499295876181bba033435bce61962e5712e40b`.

Post-validation source/test/metadata bytes remain identical to `087c1de`;
only docs/work evidence is updated. Plain/live roadmap pass (139 local links),
production diff whitespace checks pass, and the original approved patch context
spaces remain the only historical range warnings. Claim removal is intentionally
deferred until review clears, before PR.

## T1 final test synchronization and L2 reproduction utility

[Incremental independent review](ELZ-011-incremental-review.md) at `877357d`
closed F1–F7 and found no blocking product defect. Its sole required item T1
was a test assertion racing ahead of the loopback server: dispatch acknowledges
task scheduling, not request arrival. The test now waits for at least one PUT
before the existing strict `== 1` assertion. Both strict PUT assertions and all
other assertions remain unchanged; no product source, law, Contract, manifest,
provider or protected file is edited by this correction.

L2 is also addressed: the export utility creates its destination with a fresh
96-bit random suffix and `File.mkdir!`, so a leftover directory cannot be
silently reused. Independent consumers remain unchanged apart from the two
added synchronization/comment lines in the copied test. L1 terminal-after-refusal
and rearm-same-action coverage gaps remain explicitly recorded non-blocking
limits; their product implementation was independently inspected, not claimed
to have new committed test coverage. The review's single unretained observation
about the tag test under heavy load remains an observation, not a resolved
failure or a timing guarantee.

Verification for this narrow delta is targeted suite, repeated rescued-job case,
and full standalone closure. The full 32+642 run remains the evidence for
unchanged production source at `087c1de`; it is not relabelled as a fresh full
run of the two-line test delta. The coordinator queue still runs full checks on
the exact PR head before merge.

T1 checks completed: targeted suite `Result: 29 passed`; ten isolated executions
of `mix test pieces/assembly/http-job/test/elzoo/http_job_test.exs:943 --seed N`
(seeds 1–10) each exit 0 with `Result: 1 passed, 26 excluded`; full standalone
export exit 0, `Result: 221 passed`, 114 matching receipt hashes and both runtime
markers. These repetitions are evidence of the synchronization correction on
this machine, not proof of all possible schedules.

`/tmp/elz011-proposal/T1-targeted.log` SHA256 `501654a3a95a66c011161548bb48deba6a705b7885b8caf0d8e5d20d9fb20646`.

`/tmp/elz011-proposal/T1-repeated.log` SHA256 `b6ed0d5f49ee100ab2995f9c56108fb816176642cd39fb4b8542d34d972d4270`.

`/tmp/elz011-proposal/T1-export.log` SHA256 `1f9b020e62a92f96af1d0de5e72b58738bce0e109fce7480d8216f0fdf68ac89`.

Before final narrow review, marker removal/test fix commit `477799b` retained
the original claim commit in history. Normal merge `f70ffa452d79dfa697ea2bedf53bb3c50aa733ad`
brings `origin/main` at `452caa1f8140d6ec1cfee6cea1119a65e1c87a11` (ELZ-056
CI-runner admission); no rebase, force push or conflict. The inherited changes
are CI policy/docs/scripts only, with no provider, runtime or Piece changes.
Relative to current main the task authors no protected-path changes.

Post-merge checks: `python3 scripts/check-roadmap.py` and `--live` exit 0
(139 links); `python3 scripts/check-claims.py` exits 0 (no tracked metadata);
`python3 scripts/check-ci-runners.py` passes; `python3 scripts/test-ci-runners.py`
passes 70 tests; `python3 scripts/test-merge-queue.py` passes 38 tests.
Production-range whitespace passes excluding the preserved historical patches.
The full Mix suite was not repeated for this inherited CI-only merge or the
test synchronization change; exact checked commits and the narrower new checks
are stated above, and the coordinator queue owns full exact-head acceptance.

## Final independent clearance

[Final narrow review](ELZ-011-final-narrow-review.md), reviewer session
`0f974e4c-75e1-4daf-9a19-7720ad2b1633`, dispatch `ctx_0cf6e61580e8`, at
`094eff10b05ec9a60756f73f0faf77c3bec0fe3a`: **CLEAR, no blocking findings**.
T1/L2 closed; product/G1–G9/R1–R3/D1–D5 clearance carries forward. Reviewer
reproduced targeted 29, rescued case 10/10, heavy group 10/10 idle and 10/10
under load, and two successive exports with 221 tests, 114 hashes and both
runtime markers. Optional L1 coverage gaps remain non-blocking and disclosed.
The report was copied byte-for-byte; this post-review commit changes only
review/evidence documents. Queue exact-head CI, merge, main acceptance and
cleanup remain with the coordinator/author handoff.


## PR CI stream mutation timing correction (2026-11-08)

PR run 42462993434, job 128676111874 on the first fast runner, failed the stream-size
negative control: it expected `{:error, :receipt_invalid, :schema}` but the
unguarded mutant reached `{:error, :transport_timeout, :unknown}` first. The
same test failed in the root suite and aggregate copied consumer. The coordinator
stopped the queue and cancelled obsolete exact-head run 42463178216. This is a
test isolation defect, not evidence that the guarded size limit failed.

Only this branch's unmerged size test and its stream fixture change. The direct
Adapter fixture supplies `:infinity` for total, receive and connect clocks, and
the size-only server uses an infinite send timeout. A new assertion confirms
that public `configure/1` rejects these values. Production configuration and
transport deadlines are unchanged; the separate deadline/slow-drip tests remain
timed. ExUnit's watchdog still bounds the test (120 seconds at root and in the
standalone export; copied consumers use their configured/default watchdog). All original strict
assertions remain: guarded traffic closes before 8 MiB of the 16 MiB response;
removing the actual size guard reads all 16 MiB and violates that same early-close
assertion; restoring the source passes again. The mutant still must reach schema
refusal: transport timeout is not accepted as an alternative.

Local before/after environment: `LANG=en_US.UTF-8 LC_ALL=en_US.UTF-8`,
`ERL_FLAGS='+S 4:4 +SDcpu 1 +SDio 1'`, `MIX_ENV=test`, own database
`ELZOO_TEST_DATABASE_URL=ecto://<test role>:…@localhost/<test database>`.
Load consisted of four owned `nice -n 15 yes` processes and concurrent
`mix test pieces/assembly/request-route-retry/test`; every concurrent suite exited
0 and every load process was stopped after its run.

- Before: `mix test pieces/core/effect/test pieces/assembly/http-job/test --seed 0`
  passed 29 tests in 22.1 seconds under load. Natural CI timing did not reproduce
  on this host; this pass is not presented as a reproduction.
- Controlled before: a scratch copy adds a 50 ms sleep per streaming callback
  only to the size-guard-removal mutant. `mix test
  /tmp/elz011-size-clock/before-slow_test.exs --only controlled_size_reproduction`
  under the same load exits 2 with the exact CI schema-versus-timeout mismatch
  (0 passed, 1 failed, 26 excluded; 4.3 seconds).
- After: the same full targeted command under load passes 29 in 21.8 seconds.
- Controlled after: the equivalent scratch copy of the corrected test, with
  the identical 50 ms callback delay and same load, runs via `mix test
  /tmp/elz011-size-clock/after-slow_test.exs --only controlled_size_reproduction`
  and exits 0 (1 passed, 26 excluded; 48.1 seconds). It reaches schema refusal
  beyond the old three-second deadline and preserves every size assertion.

These are finite local observations, not a guarantee for every host schedule.
The controlled delay is a scratch reproduction instrument, not a product edit.
Incremental independent review and fresh setup/full check are pending; historical
CLEAR verdicts above do not cover this delta. No production source, Cure law,
Contract, manifest, protected file or merged test changes in this correction.

Evidence SHA256 (local logs and reproducible scratch inputs):

- `/tmp/elz011-size-clock/before-pieces.log`: `1f0d7fbd9d639a400528eb36fca1a341ebff6682d3663260488c89bc51df242e`.
- `/tmp/elz011-size-clock/before-concurrent.log`: `f284fa732664302621743b365dba0b0b409a9a9134824a7d81de73c8cee181f7`.
- `/tmp/elz011-size-clock/before-controlled.log`: `856a6cb9f1c5852bb72127e9200599907f5262ac5c8efdb5c572d5fff5acb4c2`.
- `/tmp/elz011-size-clock/before-controlled-concurrent.log`: `b7fbe73cdb40a66c47267cd7157e6d78222c683720f98733c5970e19fec7359e`.
- `/tmp/elz011-size-clock/before-slow-source.txt`: `9674fa9c6eec00e3419fcfaf2cbff0e8bbf91db6014e90eabce49d06de0f11fd`.
- `/tmp/elz011-size-clock/before-slow_test.exs`: `f76298cfd95ce20835dccc3d8099e488c8ac2dd8bd4eadb43369d93acdb43f1b`.
- `/tmp/elz011-size-clock/after-pieces.log`: `a1ec4743d2f4777558ca615b9953c900095ef34346298358d61372ab286b9072`.
- `/tmp/elz011-size-clock/after-concurrent.log`: `ce327e30fe9d0a9be941a06fd8ee58f59bf5f0ff82eb0f83dec73c3be131c14f`.
- `/tmp/elz011-size-clock/after-controlled.log`: `ca4c7d2ef1e59cd175660905ba5550d5b6d4383a822dee037939f3af68bc0662`.
- `/tmp/elz011-size-clock/after-controlled-concurrent.log`: `4a50aa802d460e39244c37c5e4961abc017055f9d6c0ecd6e1356ab86a57308e`.
- `/tmp/elz011-size-clock/after-slow-source.txt`: `40af3deaa267fc2e459213ce0ce1507b103604774d4e99c83f18d60cd487484a`.
- `/tmp/elz011-size-clock/after-slow_test.exs`: `9006e95a7f0712a046a98352ed94428f9b3907fd950f03907cf85c998b9e9961`.


### Independent review of the clock isolation

[Incremental report](ELZ-011-size-clock-review.md), reviewer session
`0f974e4c-75e1-4daf-9a19-7720ad2b1633`, dispatch `ctx_d9bf408190cc`, reviewed
`a3d3b540d4dcadc74ac855c6dc9c8eb73c407288`: **CLEAR, no blocking findings**.
The reviewer independently reproduced the original mismatch with a different
20 ms callback stall (exit 2, 4.9 seconds), then passed the fixed version with
the same stall (exit 0, 21.6 seconds). Targeted 29 passed idle and under 16
nice-15 burners; the size test passed 8/8 under load; standalone copied-consumer
export passed 221 with 114 receipt hashes and both runtime markers. The reviewer
checked each infinite clock is separately rejected by public configuration and
all 12 author evidence hashes match. The report is copied without editing.

Limits remain: the negative control detects removal, not arbitrary loosening
below the asserted 8 MiB threshold; other short-timer tests retain their own
load sensitivity; finite observations do not prove all schedules. Fresh full
validation is now running; the reviewer did not run it or PR CI. No merged
acceptance is claimed.


### Fresh full validation after review

On reviewed code/test head `a3d3b540d4dcadc74ac855c6dc9c8eb73c407288`, fresh
`mix setup` exited 0 (2026-11-08 09:28:45Z–09:28:48Z), then full default
`mix check` exited 0 (09:28:48Z–09:43:49Z): **32 Ash + 642 root tests,
ELZOO CHECK PASSED**. All default individual consumers and aggregate(44)
passed; aggregate test/runtime took 249.1 seconds and the root suite 883.0
seconds. This is a new complete run of the corrected test, not a relabelled
historical pass. The command environment is the UTF-8 locale, scheduler limits,
MIX_ENV=test and own PostgreSQL URL listed above. Checked pins: dependency HEAD
`208248063d64e621782cd26dd30698ee42850a89`, Elixir 1.20.4, OTP 29.1.2.
Only review/evidence documents changed during validation; production/test bytes
remain those inspected at `a3d3b54`.

`python3 scripts/check-roadmap.py`, `python3 scripts/check-roadmap.py --live`,
`python3 scripts/check-claims.py` and `git diff --check` also pass (139 local
links, live Contracts match, no tracked claim metadata). The incremental
reviewer's standalone export221/114 receipt hashes and runtime markers above
supply additional copied-consumer evidence; it was not redundantly rerun here.

- `/tmp/elz011-size-clock/fresh-setup.log` SHA256 `10b310b700739779d4660b6a27ba264caadea8845c1b7cb0421a45e9f46cf56b`.
- `/tmp/elz011-size-clock/fresh-check.log` SHA256 `17f3974d255d99d9ebb915447cc9b4df42a1eda218c49842d59bc8c9fb8e2b9d`.
- `/tmp/elz011-size-clock/fresh-results.json` SHA256 `ab5905f18ddcb54550999ebe8d0c37f9f5ce35110162fe575901d0e7ee0be0e9`.

PR CI on the pushed head and the coordinator queue/merge are still required.
