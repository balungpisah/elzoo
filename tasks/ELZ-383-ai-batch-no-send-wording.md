# ELZ-383 — integration/ai-batch names the text interface's attested no-send set, of which the batch path reaches only credentials_unavailable

- Phase: repair of the ready Piece `integration/ai-batch` before the first release (defect #882)
- Dependencies: ELZ-085, ELZ-364
- Release: V1B
- Output: none. A text repair in place of the ready Piece `integration/ai-batch` (ELZ-085), with the same Piece ID (`AGENTS.md` section 4): its Contract text is made true again. Behaviour does not change.
- Change class: Piece-only implementation (`scripts/ci-change-class.py`: the Piece directory, its index row and generated files)
- Owned paths: `pieces/integration/ai-batch/**`; the `manifest_sha256` and `note` of its `entries` row in `docs/plans/release-plan.json` and the generated `LEDGER.md`, `docs/plans/views.md` and `docs/plans/dependencies.mmd` (`AGENTS.md` section 3). No other Piece, no root test or helper, no `mix.exs`, `mix.lock` or CI.

## Defect and boundary

Reported in #882. This publication does not settle #882; the build pull request does.

ELZ-364 added `input_unavailable` to `Elzoo.AiText.Outcome.no_send()`, which is now `[:credentials_unavailable, :input_unavailable]`. The batch Bindings compile with `no_send_attestations: Outcome.no_send()` (`lib/elzoo/ai_batch/binding.ex`, line 39), so they attest both. Nine places still say that only `credentials_unavailable` is attested no-send, or that the failure table attests no-send only for credentials, which is false:

1. the `@moduledoc` of `lib/elzoo/ai_batch/binding.ex` (lines 8–10);
2. `README.md`, "Failure table and retries" (line 97);
3. `piece.json` `contract` ("only credentials_unavailable attested no-send");
4. `piece.json` `limits`, the staged-body item ("because the reused failure table attests no-send only for credentials");
5. `piece.json` `grounding`, the scenarios claim ("credential failure the only no-send");
6. `README.md`, the staged-body paragraph (about line 67, "the failure table attests no-send only for credentials");
7. the `@moduledoc` of `Elzoo.AiBatch.SubmitAdapter` in `lib/elzoo/ai_batch/adapter.ex` (about lines 124–125, "a failure is the only attested no-send, `credentials_unavailable`");
8. the code comment above `local_failure/1` in the same file (about line 205, "because the reused failure table attests no-send only for credentials");
9. the `@moduledoc` of `Elzoo.AiBatch.CancelAdapter` in the same file (about line 288, "a failure is the only attested no-send").

The batch path cannot reach `input_unavailable`: a provider tag passes `provider_tag/1` (`lib/elzoo/ai_batch/adapter.ex`, line 19) only when it is in `Outcome.provider_tags()`, which excludes it, and the batch's text Config has no artifact Need, so `Elzoo.AiText.check/2` refuses image parts `unsupported_feature`. So behaviour is unchanged; only the text is wrong.

## The change

Each of the nine places says instead that the Bindings attest the text interface's no-send set (`Elzoo.AiText.Outcome.no_send/0`, today `credentials_unavailable` and `input_unavailable`), of which the batch path reaches only `credentials_unavailable`, the one result retried after `:rearm`; the staged-body limit, its README twin and the code comment keep their result (a missing, substituted or failed staged body is reported unknown, `provider_error`) with the reason that the batch Adapter has no no-send tag for it. Nothing else changes: no executable code (only the three moduledocs and one comment of `lib/`), no test, no bound or outcome. The `note` and `manifest_sha256` of the index row follow `piece.json`.

The upgrade note of the issue's comment (adding `input_unavailable` to the table changed the compiled Binding digest, so an intent persisted under an older copy meets a binding mismatch when reopened under the new one) is not part of this task.

## Acceptance

- The nine places say what "The change" says, and no other text of the Piece names `credentials_unavailable` as the only attested no-send result (`rg -n "credentials_unavailable" pieces/integration/ai-batch` is read and recorded in the pull request).
- Every test of the Piece passes unchanged; `mix compile --warnings-as-errors` is clean.

## Gate, review and build

Run `mix test pieces/integration/ai-batch/test`, then the small gate `mix check --piece "$(git merge-base origin/main HEAD)"` and `git diff --check`. The Piece carries credentials and an external-effect boundary, so it keeps the local small gate and gets the full review of the coordinator guide ("Reviewer by risk", `AGENTS.md` section 6), although the change touches no executable code (moduledocs and one comment only): the text it corrects is the Piece's failure Contract. The hosted `check-piece` run on the exact head and the merge queue follow.

## Limits to state

- Text only: no behaviour of the batch path is changed or newly evidenced.
