# ELZ-074 — http-job: the shared wait helper is wall-clock bounded

- Phase: P0 harness (test-only fix-forward)
- Catalogue IDs: none (the `assembly/http-job` Piece is ready and unchanged)
- Dependencies: ELZ-072 (#133) merged
- Review: one narrow independent review of the merged-test helper edit; Devin Review findings dispositioned in the PR.

## Outcome

The merged test `live Oban rescue and concurrent wakeups still reserve one physical send` in `pieces/assembly/http-job/test/elzoo/http_job_test.exs` (declared at line 555) failed on a 4-core GitHub-hosted runner at its final wait (line 582). The investigation (report SHA-256 `8db3c20e3274e5bb84d38027f4d4bcd6fa917b3e282fc47a345ad1f082cdef20`) found the mechanism: the owner had made exactly one durable reservation and no `PUT` had started; the asynchronous send task was starved of scheduler time under CPU load; the shared helper `wait/2` is 300 iterations of a 10 ms sleep, which is about 3 s nominal but not a wall-clock bound (22.8 s elapsed in the instrumented failure). Neither the Adapter nor the owner misbehaved. The strict assertions stay: the owner reaches `{:Confirmed, 1}` and exactly one `PUT` is recorded. The helper becomes a monotonic wall-clock deadline of 60 s with 10 ms polls and reports the elapsed time in its failure message, so a slow but progressing runner passes and a stalled one still fails.

The owner delegated the choice between the investigator's weaker assertion and this strict-assertion option to the main coordinator on 2026-11-09 at 13:20 WIB ("Pick which one u think is best"); the main coordinator chose this option.

## Scope

- `pieces/assembly/http-job/test/elzoo/http_job_test.exs`: the `wait/2` helper (lines 154–166) becomes a monotonic wall-clock deadline (default 60 000 ms, 10 ms sleep between polls, the same assertion on the final poll with the elapsed time added to the message). The two callers that passed an explicit `600` (twice the old default) use the default too, because ExUnit's per-test timeout is 120 s (`test/test_helper.exs`) and a longer wait could not reach its final assertion; every caller keeps the default. No assertion changes; lines 582–583 are unchanged.
- `docs/work/ELZ-074.md`: the mechanism, the investigator's report hash, why the strict assertions stay, the owner's delegation, and the evidence runs.
- `tasks/ELZ-074-http-job-wait-wall-clock.md`: this body.

## Acceptance

- [ ] The http-job Piece tests pass locally at the PR head (`mix test pieces/assembly/http-job`).
- [ ] 20 runs of the tests at lines 472 and 555 pass at baseline and 20 runs pass under a moderate load (`ERL_FLAGS="+S 4:4"` with four CPU busy loops); one run under eight busy loops is recorded as information, pass or fail.
- [ ] The hosted pull-request run is green at the PR head (test-only change: no local full check).
- [ ] One narrow independent review confirms the helper edit, that every caller keeps its meaning, and that the strict assertions at lines 582–583 are unchanged.
- [ ] Devin Review findings dispositioned; the PR names the merged-test edit and quotes the delegation with its date.

## Limits

The helper bounds the wait by wall clock; it does not make a starved BEAM deliver promptly. A runner that cannot schedule the send task within 60 s still fails this test, which is the intended signal. Adapter budgets and the owner are unchanged.
