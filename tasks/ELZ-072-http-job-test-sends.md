# ELZ-072 — http-job: the job-control test counts provider sends, not polls

- Phase: P0 harness (test-only fix-forward)
- Catalogue IDs: none (the `assembly/http-job` Piece is ready and unchanged)
- Dependencies: none
- Review: one narrow independent review of the merged-test edit; Devin Review findings dispositioned in the PR.

## Outcome

The merged test `real Oban job completion and cancellation are job control, not provider rollback` in `pieces/assembly/http-job/test/elzoo/http_job_test.exs` asserts that the fixture recorded exactly one call. The fixture records every request, both the `PUT` that sends the publication and the `GET` that polls it. Under CPU starvation the `PUT` exceeds the Adapter's 250 ms total budget, the Adapter reports an unknown dispatch, and the owner resolves it with one `GET` poll before the job completes. The property the test names is one send to the provider; a poll is a permitted observation after a slow `PUT`. The assertion therefore counts `PUT` calls only. No Adapter, owner or Oban code changes.

Evidence of the timing dependence: the first GitHub-hosted full run of `main` (job 128842174590) and the exact-head queue run of PR #120 (run 42537494430, attempt 1) each failed only this assertion with two recorded calls; a local reproduction under reduced schedulers and CPU load failed 3 of 6 runs with the recorded methods `PUT` then `GET`, and 0 of 2 at baseline.

The owner approved the merged-test change on 2026-11-09 at 09:36 WIB ("resolve the http problem"); the main coordinator relayed the approval the same day.

## Scope

- `pieces/assembly/http-job/test/elzoo/http_job_test.exs`, line 485 only. Before: `assert length(Fixture.calls(c.f)) == 1`. After: `assert Enum.count(Fixture.calls(c.f), &match?({"PUT", _, _}, &1)) == 1`. The fixture records calls as `{method, path, bytes}` tuples (`test/support/http_job_test_helper.exs`).
- `docs/work/ELZ-072.md`: the reason and the evidence runs.
- `tasks/ELZ-072-http-job-test-sends.md`: this body.

## Acceptance

- [ ] The http-job Piece tests pass locally at the PR head (`mix test pieces/assembly/http-job`).
- [ ] The hosted pull-request run is green at the PR head (test-only change: no local full check).
- [ ] One narrow independent review confirms the edit is exactly the stated line and that the test still asserts one provider send.
- [ ] Devin Review findings dispositioned; the PR names the merged-test edit and quotes the owner's approval with its date.

## Limits

The budget values of the Adapter (250 ms total, 100 ms connect, 100 ms receive) are unchanged; other scenarios keep exercising them. The change removes a timing assumption from one assertion; it does not make the test immune to a runner so slow that the job misses its 6 s completion wait.
