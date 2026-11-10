# ELZ-092 — Find and fix the root cause of the intermittent http-job "live Oban rescue and concurrent wakeups" failure

- Phase: defect investigation (test or ready-Piece fix)
- Catalogue IDs: assembly/http-job (no Contract change intended)
- Dependencies: ELZ-011

## Outcome

`pieces/assembly/http-job/test/elzoo/http_job_test.exs`, test "live Oban rescue and concurrent wakeups still reserve
one physical send", fails intermittently: the owner never reaches phase `{:Confirmed, 1}` within the default wait
(60 s wall clock, bounded by ExUnit's 120 s per-test timeout). Occurrences: one local full check on 2026-11-10 (ELZ-079,
recorded) and one hosted run on 2026-11-10 (PR #169, run 42709005817, check-root 1012/1013); the same file had two
earlier timing repairs (ELZ-072 counted sends instead of polls; ELZ-074 made the wait wall-clock bounded). A wait of
60 s for an event that normally takes milliseconds is unlikely to be plain slowness. Find the cause and fix it at
the root, so the test is deterministic, without weakening what it proves.

## Admission record

1. **Responsibility and caller.** Restore trustworthy evidence for the ready `assembly/http-job` Contract (one
   physical send under Oban rescue and concurrent wakeups). Caller: every full check; flaky failures cost hosted
   reruns and hide real failures.
2. **Interface and invariant.** No Contract change intended. Invariant the test must keep proving: after an Oban
   rescue that runs the same job twice concurrently, exactly one provider PUT is sent and the owner reaches
   `{:Confirmed, 1}`. If the investigation shows the Adapter itself can fail to confirm (for example the losing
   execution leaves the job scheduled with an Oban backoff longer than the wait, or the winning acknowledgement is
   discarded after the rescue bumps the attempt), that is a defect of the ready Piece: fix the code under the same ID
   only if the fix restores the existing Contract; any change of guarantees stops and comes to main.
3. **Reuse check.** Oban's documented rescue, snooze and backoff behaviour; no new library.
4. **Split test.** One test, one Piece; class T if only the test changes, class P if the Adapter changes.
5. **Failure and evidence.** First reproduce: a stress loop of this test alone and under CPU load (for example 200
   iterations with `+S 1:1` and a parallel CPU burner), recording the failure rate and, on failure, the Oban job
   state, attempt, scheduled_at, errors and the owner phase at the deadline. Then name the mechanism with that
   evidence. Fix: a deterministic test (no sleep-based ordering; explicit synchronisation on the observable events),
   or the Adapter fix, plus a regression test that reproduces the mechanism deterministically. Show the stress loop
   passing at a stated iteration count after the fix. Do not raise timeouts, add retries to the test, or loosen the
   one-PUT assertion.
6. **Composition record.** No other Piece changes. Operational applicability unchanged.

## Scope

- the investigation record `docs/work/ELZ-092.md` with the reproduction, the mechanism and the evidence;
- the fix in the test and, only if the mechanism is in the Adapter, in `pieces/assembly/http-job/lib/`;
- a deterministic regression test; the merged test's intent and assertions are kept (edits of this merged test are
  approved by main for this task, with exact before/after recorded on the issue).

## Acceptance

- [ ] The mechanism is named with recorded evidence (job state and owner phase at a failing deadline).
- [ ] A deterministic regression test reproduces it before the fix and passes after.
- [ ] The stress loop passes at the recorded iteration count after the fix; before/after failure rates recorded.
- [ ] The one-PUT and `{:Confirmed, 1}` assertions are unchanged in meaning; no timeout raised.
- [ ] Independent review; the hosted full check passes at the PR head.

## Evidence and limits

A stress loop is finite evidence over a stated number of runs and loads, not a proof of the absence of races.

## Out of scope

Other http-job tests (unless the same mechanism appears there; then record and fix within this task), Oban upgrades.

## Reference

ELZ-072 (#133), ELZ-074 (#137); hosted run 42709005817 (PR #169).
