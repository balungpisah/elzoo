# ELZ-384 — integration/ai-text test I4 no longer names the credential failure as the only redispatched attested no-send

- Phase: repair of the ready Piece `integration/ai-text` before the first release (defect #925)
- Dependencies: ELZ-079, ELZ-364
- Release: V1B
- Output: none. A test-name repair in place of the ready Piece `integration/ai-text` (ELZ-079, image input ELZ-364), with the same Piece ID (`AGENTS.md` section 4): evidence wording only. Behaviour, Contract, README and `piece.json` do not change.
- Change class: Piece-only implementation (`scripts/ci-change-class.py`: one test file of the Piece directory)
- Owned paths: `pieces/integration/ai-text/test/elzoo/ai_text_test.exs`. No other file of the Piece (its `lib/`, `README.md` and `piece.json` stay byte for byte, so its index row and the generated files do not change), no other Piece (`integration/ai-embedding`'s I4 included, below), no root test or helper, no `mix.exs`, `mix.lock` or CI.

## Defect and boundary

Reported in #925. This publication does not settle #925; the build pull request does.

On `main` (checked at `c6fe7a8f`), the test at line 249 of `pieces/integration/ai-text/test/elzoo/ai_text_test.exs` is named "I4 retries: only the attested no-send credential failure is redispatched; throttled and overloaded are not; unknown never (RetryTimeout policy + owner)". Since ELZ-364, `Elzoo.AiText.Outcome.no_send/0` (`lib/elzoo/ai_text/outcome.ex`, line 51) is `[:credentials_unavailable, :input_unavailable]`, and the test at line 937 of the same file shows `input_unavailable` at dispatch as an attested no-send that `Elzoo.AiText.Retry.next/3` retries. Read literally, the name of I4 says that the credential failure is the only attested no-send that is redispatched, which is not true of the Piece.

The body of I4 exercises the credential failure, throttled, overloaded and the unknown and permanent tags, and its assertions are correct. Only its name is stale. The name is evidence wording (`docs/development/03-claims-and-evidence.md`). The Piece's other evidence text is already true: the name of test I6 (line 336) and the `grounding` claim of `piece.json` ("retries (credentials_unavailable retried, throttled and overloaded unresolved and not redispatched, unknown never …)") name no "only".

`integration/ai-embedding` has a test with the same name (`test/elzoo/ai_embedding_test.exs`, line 426), and that one is true: its `Outcome.no_send/0` is `[:credentials_unavailable]`. It is not part of this task.

## The change

The name of I4 becomes exactly:

    I4 retries: the attested no-send credential failure is redispatched; throttled and overloaded are not; unknown never (RetryTimeout policy + owner)

Nothing else changes: the body of I4, the `## I4 retries` comment, every other test, `lib/`, `README.md` and `piece.json`.

## Acceptance

- The name of I4 is the line above. `rg -n "only the attested no-send" pieces/integration/ai-text` prints nothing; the command and its empty output are recorded in the pull request.
- `git diff origin/main -- pieces/integration/ai-text` changes exactly one line, the name of I4.
- Every test of the Piece passes, with the same count of tests as on `main`.

## Gate, review and build

Run `mix test pieces/integration/ai-text/test`, then the small gate `mix check --piece "$(git merge-base origin/main HEAD)"` and `git diff --check`. The Piece holds credentials and an external-effect boundary, so it keeps the local small gate (`AGENTS.md` section 5) and gets the full review of the coordinator guide ("Reviewer by risk", `AGENTS.md` section 6), although the change is one test name. The hosted `check-piece` run on the exact head and the merge queue follow.

## Limits to state

- Wording only: no behaviour of the Piece is changed or newly evidenced.
