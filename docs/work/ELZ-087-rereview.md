# ELZ-087 post-final-review re-review

Reviewer: independent reviewer (Codex, gpt-5.6-terra, high effort)

Reviewed range: `8cc912b3117f1b5e6a39867024e63b65527f2253..d6a254d8721e1569d646ab0b1dbd394bc9ff9c16`, restricted to `pieces/integration/ai-text-openai` and `docs/work/ELZ-087.md`. Metadata comparison: `origin/main...d6a254d` for the ELZ-087 entries in `registry/catalogue.json`, `registry/providers.json`, and `docs/plans/release-plan.json`. Contract read from live issue #157; PR #167 body and exact head `d6a254d8721e1569d646ab0b1dbd394bc9ff9c16` were inspected.

## Findings

1. **High — an oversized non-2xx response is classified from its status, rather than as sent `unknown{malformed_response}`.**

   `pieces/integration/ai-text-openai/lib/elzoo/ai_text/open_ai.ex:284-294` records no oversize marker in the exchange passed to decoding. Consequently, for an oversized 400, 429, or 503, `:343-352` takes the non-2xx status path; for example 400 becomes `provider_invalid_request`, which the interface maps to `failed/dispatched/permanent`, rather than `unknown/dispatched/unclassified` for `malformed_response`. O12 tests only an oversized 2xx (`test/elzoo/ai_text_openai_test.exs:738-742`). Preserve the oversize fact through capture, reject it before status classification, and add at least one oversized non-2xx assertion showing the dispatched unknown/malformed result and exactly one request.

2. **Medium — the response-cap contract does not identify the byte representation for compressed replies, and has no compressed-transfer evidence.**

   `open_ai.ex:271-280` calls the accumulator a “raw bound,” while the README at `:23-25` says only “body”; neither says whether Req supplies decoded or wire bytes to `into:`. O12 directly feeds chunks to `bounded/2` (`ai_text_openai_test.exs:725-736`) and sends an unencoded plug response (`:738-742`), so it does prove the exact 4 MiB / 4 MiB + 1 accumulator boundary but not the compressed-response behavior or actual transfer ordering. State the intended decoded-or-wire invariant, ground it in the pinned Req behavior, and add a content-encoded case (with a clear expected bound) before claiming this as the response-body cap.

3. **Medium — the required absent `max_output_tokens` case is not covered.**

   O12 tests 15 and 16 at `test/elzoo/ai_text_openai_test.exs:744-755`, but no scenario deletes the field. The interface currently makes the field required (`pieces/integration/ai-text/lib/elzoo/ai_text/request.ex:36-37, :125, :139`), which should refuse absence before the credential Need; that behavior is not demonstrated by this Piece's post-review evidence. Add a no-field scenario with a credential-read counter and zero requests.

4. **Medium — the exact-head public PR body violates the public-writing rule.**

   The end of PR #167's body contains a generated-by attribution with a non-provider external link. It is not Contract or evidence material. Remove it before merge; do not replace it with a comparable external badge or attribution.

## Per-item results

1. **Response bound:** The `into:` accumulator enforces the arithmetic boundary correctly: exactly 4 MiB continues and 4 MiB + 1 halts, clears the accumulated body, and the tested oversized 2xx becomes `unknown{malformed_response}` with one request. No partial body reaches the captured raw exchange in that path. The existing redaction test covers credential/prompt/output exposure in its normal stub cases, but O12 does not exercise logs or telemetry for an oversized reply. Finding 1 leaves oversized non-2xx replies on the status mapping; finding 2 leaves compressed representation/coverage unresolved.
2. **`max_output_tokens` floor:** `translate/2` applies the 16 floor before model routing, request construction, and the credential Need; the README and code cite the pinned `CreateResponse` minimum. The 15 and 16 cases are covered, but the absent case is finding 3.
3. **O10 audit:** Pass. The audit resolves exactly one manifest in either layout, reads every manifest-listed `lib/` file from the correct repository or consumer root, and `File.read!/1` makes a missing file fail rather than skip.
4. **Install configuration:** Pass. `piece.json` has exactly one `install_configuration` item, exactly `config :req_llm, load_dotenv: false`, with a one-line reason. Its declared `req_llm` provider permits that literal under main's `Registry.validate_install_configuration!/2`; the README points to the field, and the phrases the README test asserts remain true.
5. **Scope, metadata, and PR body:** The scoped post-final-review diff changes only this new Piece and its work record, with no protected path or other ready Piece edit. The ELZ-087 catalogue row and release-plan job are internally consistent with the manifest, while `registry/providers.json` correctly retains the existing pinned `req_llm` provider record. The PR body's substantive summary matches the reviewed changes, but it fails the public-writing rule (finding 4).

## Grounding and limits

This was a static Git/GitHub review only: no Mix command, live provider call, repository edit, or GitHub comment was made. The bound and outcome observations are source/test-path analysis, not execution evidence. The main-merge changes in the range (ELZ-083, ELZ-085, and ELZ-091) were not reviewed.

## Verdict

**request changes** — resolve findings 1 through 4, then re-review the changed head.
