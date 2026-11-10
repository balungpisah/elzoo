Reviewer: independent reviewer (Codex, gpt-5.6-terra, high effort)

Reviewed SHA: `b1487c53f4764803311294c83f113c705df44257` (PR #168 head; issue #159).

Inputs: the SHA-pinned `origin/main...b1487c53f4764803311294c83f113c705df44257` diff and stat; PR #168 body; live #159 and its approved amendment comment; the task-copy and release-plan pins; the two manifests, source, tests, fixture, README files, work/probe records and pinned working-tree dependency metadata. Review was read-only: no Mix command or provider call was made.

## Findings

1. **BLOCKING — the required 529 overload response is classified as `provider_error`, not as retryable `overloaded`.**
   - `pieces/integration/ai-embedding-openai/lib/elzoo/ai_embedding/openai.ex:234-241` maps 503 to `:overloaded` but has no 529 clause, so 529 reaches the catch-all `:provider_error`. That produces `unknown` / `dispatched` / `unclassified`, contrary to the review Contract's required 429/529 `failed` / `dispatched` / `retryable` rule and its no-default-redispatch consequence.
   - `pieces/integration/ai-embedding-openai/test/elzoo/ai_embedding_openai_test.exs:330-365` covers 503 but not 529, so the claimed failure-table evidence would not catch this regression.
   - Concrete change: add `def classify_failure(%{status: 529}), do: :overloaded`, add a documented-format 529 stub to E4 that asserts the refused overload outcome, one observed request, and retry-table result, and update the provider README/manifest wording if 529 is intentionally supported in addition to 503. If “529” in the review Contract was intended to mean 503, correct that Contract wording explicitly before acceptance rather than silently treating the two as interchangeable.

## What was checked and found sound

- The live #159 body and `tasks/ELZ-080-ai-embedding-openai.md` hash to the approved `23d483c9abce814a58d198a5b0dec8613a13dae2bc80542c9ddb7ae4a93fc874`; the release-plan job carries that pin. The two release-plan manifest hashes equal the reviewed manifest bytes, and the catalogue, ledger and generated views contain both rows.
- The interface admits canonical request arguments and checks the 65,536-byte canonical-payload bound before intent construction, Need access and provider transport. Its I2 test names the 65,536/65,537 boundaries, escaping and whitespace cases.
- Adapter response handling validates count, the exact sorted index set, dimensions, float32 range, served-model equality, and all-or-nothing malformed outcomes. It computes the fixed `1.0e-3` norm classification and exposes descriptor equality across provider, model, dimensions, dtype and normalization for ELZ-082.
- The OpenAI translation sends an array input with injected `api_key`, `max_retries: 0`, and response/error halting steps. Its test suite covers documented request/response stubs, one-request timeout/redirect cases, input-type refusals, usage’s non-empty unknown cache-write record, ambient-key/redaction controls, and the README install-configuration statement.
- Both manifests enumerate their source and test support, declare the Cure/ReqLLM/Plug dependency providers as applicable, and the tests are written to operate in either repository or copied-consumer layouts. The OpenAPI fixture carries recorded provenance and the MIT notice. No local `docs/` or `tasks/` reference was found in executable Piece sources; fixture URLs are copied OpenAPI text.
- `git diff --check` reported no whitespace errors. PR check-plan and gleam-hosted were successful at review time; the three Mix check jobs were still in progress, so no local or hosted full-check pass is claimed here.

## Verdict

**Request changes.** Counts: 1 blocking, 0 should-fix, 0 notes. Re-review the corrected failure mapping and its 529 regression evidence at the new SHA; hosted acceptance remains pending separately.

## Disposition (worker)

| Finding | Disposition |
| --- | --- |
| 1 BLOCKING 529 classified `provider_error` | Fixed: `classify_failure(%{status: 529})` is `:overloaded` (family rule, ELZ-079 amendment 1; 503 stays `overloaded` as OpenAI documents it for this path, so no Contract wording changes). E4 adds a documented-format 529 stub to the status table and a dedicated case: one request, `refused{overloaded}` with `retry_after`, delivery `failed/dispatched/retryable`, `Retry.next` `:unresolved`, owner refuses `:rearm` and `:dispatch`. README, manifest contract, grounding and assumption updated; release-plan manifest hash and note, and `LEDGER.md` regenerated. |
