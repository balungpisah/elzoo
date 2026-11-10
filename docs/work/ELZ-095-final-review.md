# ELZ-095 independent narrow test-repair review

Reviewer: independent Codex reviewer, role reviewer-095.
Reviewed SHA: `4cf9d0ba43a015448708f6fcbffbc582a9b2eee0`.
Comparison base: `5fd1779c38becf693c256c9b63056f99f4954496`.
Live Contract: issue #177.

## Verdict

Approve. No blocking findings in the scoped test repair or its recorded evidence.
Affected gate and full exact-head hosted acceptance remain pending; this approval
is not a pass claim for either.

## Findings and grounding

- Independently read the failed check-consumers-db log for run42777290506,
  job129698944203. LS28 reaches wait_until's strict boolean or with nil; the
  stack names contender_waits_on_lock?(timed_backend_pid). This is consistent
  with the admitted nullable test-observation defect. No SearchData assertion
  appears in that failure; this does not establish a production lease defect.
- The existing helper changes exactly the approved SQL literal, wrapping
  wait_event_type='Lock' in COALESCE(...,FALSE). SQL true remains true, false
  remains false, and NULL becomes false before Postgrex decoding. The helper's
  existing missing-backend-row behavior is not broadened or silently repaired.
- The added regression uses TestRepo.checkout/1 so obtaining pg_backend_pid,
  observing that same active backend's NULL wait_event_type and invoking the
  actual helper all use the same connection. It asserts the raw NULL first and
  the helper result exactly false second. This reproduces the nullable observation
  without racing a separate contender or substituting a mock SQL result.
- Independently reconstructed the baseline file in memory by removing only the
  new regression and reverting only the SQL literal. The result is byte-equal to
  the base test file. LS28, every existing assertion and timeout, wait_until/2,
  production runtime code, Piece manifests and dependency/configuration/toolchain
  files are unchanged. The formatting-only delta from c4e749a is confined to
  the new regression's SQL-call line wrapping.
- Independently checked all three retained raw-log hashes against the work record:
  old-SQL regression: 932c4fae43debcdca17d81f7bfe62f8cee3f1cc54f1c4e9beb356c95b638514f;
  corrected regression/Piece suite: ba36d9d9f896008d40c8c1f01726f22081b7e20f811c451d5a6b7abaccde023d;
  serial setup: e9eb0c4eaae525aaf6866aa88c21b518765afef9db91e33b254866219abc7451.
  The old regression fails nil===false (exit2,0/1 passed,14 excluded); the
  corrected regression passes (exit0,1 passed,14 excluded); the Piece suite
  reports40 passed, including unchanged LS28. Serial setup exits0. These are
  retained writer executions inspected by the reviewer, not newly rerun tests.
- The record preserves earlier setup failures and classifies concurrent build
  state as an inference, not an established Cure source defect. It also records
  the first affected attempt's formatting-stage exit1 without calling it green.
  No moving Cure ref was introduced; the existing pinned commit remains unchanged.
- Planning adds only this admitted repair, its ELZ-028 dependency, task copy and
  generated views. Reviewer structural checks: `git diff --check 5fd1779..4cf9d0b`
  exit0; `python3 scripts/check-roadmap.py --live` exit0,93 jobs, live Contracts
  match and generated views agree.

## Limits

Read-only code, Contract, failed hosted log and retained local evidence review,
plus the stated structural checks. No Mix suite, database effect or new Cure
proof was run by this reviewer. PostgreSQL NULL/COALESCE semantics and checked-out
connection behavior are upstream contracts; the real-PostgreSQL regression is
finite test evidence. No universal race-freedom, SearchData acceptance or changed
production lease guarantee is claimed. The coordinator still owns exact-head
hosted evidence, automated findings, merge and cleanup.
