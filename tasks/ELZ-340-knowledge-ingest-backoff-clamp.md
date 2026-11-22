# ELZ-340 — assembly/knowledge-ingest: clamp the backoff without retry_after to at most 3,600 s

- Dependencies: ELZ-334

## Outcome and scope

Defect #805, found by the full review of the ELZ-334 build (#804): on
`main`, a retryable embedding outcome of `assembly/knowledge-ingest`
(`{:refused, :throttled | :overloaded | :credentials_unavailable, _}`,
`:not_dispatched` or `:completed_lost`) with no `retry_after` snoozes
5 × 2^(n−1) s after the n-th attempt (`delay/2` in
`pieces/assembly/knowledge-ingest/lib/elzoo/knowledge_ingest/steps.ex`), where
n is the batch's attempt number. Attempt numbers continue across `resubmit/3`
and are never reused, so nothing bounds this backoff, unlike `retry_after`,
which is clamped to 1..3,600 s. With `max_attempts` 5 and three resubmits, n
reaches 16: a snooze of 163,840 s (about 45 hours). At n = 34 the snooze is
about 1,361 years, and from n = 42 the scheduled time passes the end of the
PostgreSQL timestamp range (294276 AD), so the snooze cannot be stored (the
#805 estimate of n ≈ 34 was too low). A scheduled job also stays unique, so
an equal submit does not enqueue it again. The code follows the ELZ-334
Contract text, so the defect is in the Contract.

Coordinator decision: clamp the computed backoff to at most 3,600 s, the same
upper bound as `retry_after`, and change nothing else. The clamp is computed
without first building the large power of two (for example by capping the
exponent), so no attempt number can overflow, allocate a large integer or
reach the timestamp range.

This changes `assembly/knowledge-ingest` in place before the first release
(same Piece ID). The changed Contract: a retryable outcome without
`retry_after` snoozes min(5 × 2^(n−1), 3,600) s after the n-th attempt, so
5, 10, 20, 40, 80, 160, 320, 640, 1,280 and 2,560 s after attempts 1 to 10,
and 3,600 s after attempt 11 and every later attempt. The `retry_after`
clamp (1..3,600 s), the attempt budget, the attempt numbering, every other
result and every other bound are unchanged.

Owned paths: `pieces/assembly/knowledge-ingest/lib/elzoo/knowledge_ingest/steps.ex`,
`pieces/assembly/knowledge-ingest/README.md`,
`pieces/assembly/knowledge-ingest/piece.json` and
`pieces/assembly/knowledge-ingest/test/elzoo/knowledge_ingest_test.exs`; then,
in the last commit, the Piece's `docs/plans/release-plan.json` entry
(`manifest_sha256`, and `note` equal to the new `contract`) and the generated
views (`AGENTS.md` section 3). No change to the migration, the other test
files, the test helper or another Piece.

## Required behavior

1. `delay/2` in `steps.ex`: with an integer `retry_after`, unchanged
   (clamped to 1..3,600 s). Without one, min(5 × 2^(n−1), 3,600) s, computed
   with a capped exponent, so that the integer it builds is bounded for every
   attempt number n ≥ 1.
2. README, Embed step: next to "5 × 2^(n−1) s after the n-th attempt", state
   that this backoff is clamped to at most 3,600 s (3,600 s from attempt 11
   on).
3. `piece.json`: `contract` states the snooze of a new counted attempt: the
   provider's `retry_after` clamped to 1..3,600 s, else 5 × 2^(n−1) s clamped
   to at most 3,600 s. The test claim in `grounding` that names the
   5 × 2^(n-1) backoff names the clamp and the new scenario. Every other
   clause is unchanged.
4. No other result changes: the attempt budget (`max_attempts` 1..5 since
   submit or the last `resubmit/3`), the attempt numbering, the job backoff of
   5 s × the job attempt number, the step deadlines and every error atom stay
   as they are.

## Acceptance and evidence

1. One regression test in
   `pieces/assembly/knowledge-ingest/test/elzoo/knowledge_ingest_test.exs`
   through the public flow (`submit/3`, `resubmit/3` and the drained runner,
   as the existing group 3 snooze test does): a batch reaches attempt numbers
   10 and 11 through resubmits, each attempt without `retry_after`;
   - attempt 10 snoozes exactly 2,560 s (5 × 2^9, below the cap, unchanged);
   - attempt 11 snoozes exactly 3,600 s (unclamped 5 × 2^10 = 5,120 s).
   The expected values are written out by hand, not computed with the Piece's
   code.
2. Negative control, a temporary edit reverted and never committed: with the
   clamp removed from `delay/2`, the test must fail (attempt 11 snoozes
   5,120 s); record the failure in the PR body.
3. `contract` in `piece.json` names the clamp, and the release-plan entry has
   the new `manifest_sha256` of `piece.json` at the head and `note` equal to
   `contract`.
4. The Piece carries durable state and external effects, so the local small
   gate runs on the worker's own disposable PostgreSQL 16 with pgvector and
   MinIO with `ELZOO_TEST_APP_ROLE=elzoo_app`: `mix test
   pieces/assembly/knowledge-ingest/test`, `mix check --piece "$(git
   merge-base origin/main HEAD)"`, `git diff --check`, and the index step 3
   checks (`mix elzoo.ledger`, `python3 scripts/check-roadmap.py --write`,
   `python3 scripts/check-roadmap.py`).
5. One independent review scaled to this small change (`AGENTS.md` section
   6), a green exact-head hosted `check-piece`, the PR marked ready, and the
   automated reviewer's gate of `AGENTS.md` section 6. The PR closes #805 and
   this task's issue.
