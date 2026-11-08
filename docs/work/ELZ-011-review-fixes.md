# ELZ-011 final-review fixes

Independent reviewer: Orca session `0f974e4c-75e1-4daf-9a19-7720ad2b1633`,
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
export ELZOO_TEST_DATABASE_URL=ecto://elzoo_elz024:elzoo_elz024@localhost/elzoo_pieces_test
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
