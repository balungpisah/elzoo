# ELZ-288 — Restore the found Logger level, and run empty-log tests synchronously

- Dependencies: ELZ-079, ELZ-080, ELZ-087, ELZ-105, ELZ-271, ELZ-273

## Outcome and scope

Repair the two test-isolation defects reported in issue #639, in the tests of
six Pieces. Each Piece's Contract, library code, README, `piece.json`, Piece
ID and catalogue/ready entry stay unchanged. This is a coordinator one-PR
repair: publication and implementation share one `task/ELZ-288` pull request.

Owned implementation paths:

- `pieces/integration/ai-text-openai/test/elzoo/ai_text_openai_test.exs`
- `pieces/integration/ai-text-anthropic/test/elzoo/ai_text_anthropic_test.exs`
- `pieces/integration/ai-embedding-openai/test/elzoo/ai_embedding_openai_test.exs`
- `pieces/integration/encryption/test/elzoo/encryption_test.exs`
- `pieces/integration/secrets/test/elzoo/secrets_test.exs`
- `pieces/integration/egress-policy/test/elzoo/egress_policy_test.exs`

Publication owns this task file, its no-output job row in
`docs/plans/release-plan.json`, and the generated `LEDGER.md`,
`docs/plans/views.md` and `docs/plans/dependencies.mmd`. The change touches
no shared path, manifest, README, dependency, pin, timeout or budget.

## Observed defects

1. Some tests set the global Logger level and then set it back to a
   hard-coded `:warning` instead of the level they found. The places are
   `ai_text_openai_test.exs:822,945`, `ai_text_anthropic_test.exs:511` and
   `ai_embedding_openai_test.exs:524`. In the fixed-seed full check, every
   later test then runs at `:warning`. That is how main run 44778242170 lost
   the `:info` control entry of the tenant-isolation log test, which ELZ-275
   repaired in that test only.
2. `Elzoo.EncryptionTest`, `Elzoo.SecretsTest` and `Elzoo.EgressPolicyTest`
   are `async: true` and assert an empty `capture_log`. ExUnit documents that
   `capture_log` in an async module can capture other tests' messages. That
   is the cause ELZ-276 repaired in token-verify.

## Required behavior

1. Each of the four places reads `Logger.level()` before the change and
   restores that value in `on_exit`, as
   `pieces/integration/notification/test/elzoo/notification_test.exs:355-356`
   already does.
2. The three modules run `async: false`, so `capture_log` sees only their own
   tests' logs.

Keep every assertion, including the empty-log checks. Add no skip, tag,
retry, sleep or log filter.

## Acceptance and evidence

1. Reproduce: with the global level set to `:info` before the AI tests run,
   the unchanged tests leave it at `:warning`. The fixed tests leave `:info`.
   Show this with a temporary probe test run after them under a fixed seed.
2. Reproduce: a temporary async module that logs errors while one of the
   three modules runs makes the unchanged module fail its empty-log check.
   The fixed module passes in the same pairing.
3. Negative control: a temporary log line in one library's checked path
   makes its fixed empty-log test fail.
4. Each changed Piece's tests, the small gate (`mix check --piece`),
   `git diff --check`, `scripts/ci-change-class.py` and the index step 3
   checks.
5. One independent review, a green exact-head hosted check, and the PR
   marked ready. The coordinator merges on a green `main`, and the PR closes
   #639.
