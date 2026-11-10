# ELZ-092 independent final review

Reviewer: independent Codex reviewer, role reviewer-092.
Reviewed SHA: `479d60a68d6cfe8bdd49b24614c8bb73d24440f8`.
Comparison base: `339c1edb6925afd324280f95c2dd7591ae1f96ee`.
PR: #173. Live Contract: issue #170, including the approved exact before/after
merged-test edit posted before publication.

## Verdict

Approve. No blocking findings in the reviewed diff or its scoped evidence claims.
Hosted exact-head acceptance and merge cleanup remain coordinator responsibilities.

## Findings and grounding

- The source diff changes only the http-job test, its work/task records and planning
  entry/generated views. No Adapter, dependency or ready Contract changes. The
  existing two resolved-wake assertions, rescue call, 2000 ms receives, 3000 ms
  call budget, 60000 ms wait and exactly-one-PUT assertion retain their meaning.
- `rescue_gate/1` serializes registration and opening in one Agent. A registration
  either joins the waiting list or sees the open state; opening releases registered
  tasks, while later retry resolutions return the owner. This repairs the old stub's
  permanent blocking of any execution after its first two releases.
- The regression deliberately returns an invalid owner result for the first two
  resolves. Both wakes therefore fail closed before an owner command. Its synchronous
  stop-telemetry handler snapshots the owner and fixture before Oban receives the
  attempt-2 result and can schedule a retry. It checks Intended/Fresh revision1, zero
  attempts and no requests before the retry, then Confirmed/1, completed Oban row,
  one PUT and the attempt-2 owner_unavailable error. This is a deterministic test of
  the recorded stalled state and recovery path, not a deterministic reproduction
  of OTP scheduling pressure; the work record says so explicitly.
- Read `Call.run/3`, HttpJob.perform/tick, Jobs.Worker and pinned Oban's
  acknowledgement query. The source supports the stated fail-closed translation
  and synchronous telemetry ordering. The transient capacity trigger is supported
  by recorded diagnostics and upstream task/supervisor behavior, not represented
  as a new formal proof. Earlier ELZ-072/074 records were checked for preserved
  send-count and wait semantics.
- Independently inspected retained raw stress logs: 1500 and 200 successful result
  lines respectively, every result with exactly `["PUT"]`, and no Call timeout
  diagnostic. Iterations455/1176 have 2172/2169 ms recovery durations as recorded.
  The work record preserves finite-run limits and links earlier hosted failures
  by symptom only. Before-fix regression log reports the recorded60-second failure;
  the fix does not add a test retry or weaken a timeout.
- All four recovered raw-log SHA-256 values in the work record match their retained
  artifacts, including the command-exit wrapper. Completed gate logs report affected
  exit0/root1050, Piece37 passed and52 classifier checks. These are inherited
  executable observations; this review did not rerun Mix or claim hosted acceptance.
- Reviewer checks: `git diff --check 339c1ed..479d60a` exit0;
  `python3 scripts/check-roadmap.py --live` exit0, live Contracts match and generated
  views agree. The task copy and planning pin are consistent.

## Limits

Read-only code, Contract and evidence review, plus the two stated structural checks.
No provider request, new Cure proof, new Mix suite or new stress measurement was run.
The gate does not guarantee arbitrary host scheduling fairness or universal absence
 of races; task acceptance remains conditional on the PR's own exact-head hosted run.
