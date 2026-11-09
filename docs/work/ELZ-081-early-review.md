# ELZ-081 early independent Contract review

Reviewer: independent reviewer (Codex, gpt-5.6-terra, high effort)

Reviewed SHA: `ebc774a11a480d5ec858ea267bde1fa89198aba9`

## Inputs read

- Live issue #154 Contract.
- `docs/work/ELZ-081.md` and `origin/main...ebc774a11a480d5ec858ea267bde1fa89198aba9`.
- `docs/plans/catalogue-dispositions.md`, `docs/operational-contracts.md`, `docs/capability-model.md`, `docs/development/12-change-class-flow.md`, `docs/consuming.md`, `CONTEXT.md`, and `pieces/workflow/context-selection/README.md` at the reviewed SHA.
- `text_chunker` 1.0.1 source, including `lib/text_chunker.ex`, `lib/text_chunker/strategies/recursive_chunk/recursive_chunk.ex`, and its upstream property tests.

## Findings

1. **blocking — `docs/work/ELZ-081.md`, Evidence plan T9; issue #154 Acceptance.** The plan audits only the Piece's manifest-listed files. It does not plan the separately required executable check that the Piece tests pass after export into the consumer layout, where a relative repository root, root Application, or undeclared file cannot be present. Add a named exported-consumer test/fixture to the evidence plan and `piece.json` grounding: take the Piece through the exporter, compile and run its tests without the root Application, and have the source audit derive its file set solely from `piece.json`. Keep T9, but do not describe it as satisfying the exported-layout acceptance by itself.

2. **should-fix — `docs/work/ELZ-081.md`, A1 and “Invariants and how each is grounded”.** A fail-closed re-check is necessary for the stated byte-offset value, but it must itself be exception-safe. Checking `binary_part/3` before proving that every upstream result has binary `text`, integer `start_byte`/`end_byte`, and `0 <= start_byte < end_byte <= byte_size(source)` can raise on precisely the future malformed result A1 is intended to contain. State that malformed result shape, invalid bounds, empty content, a nonmatching slice, first start other than zero, or descending starts all return `{:error, :chunker_invariant}`; validate in that order before slicing, and include malformed structs/non-struct results in T7.

3. **should-fix — `docs/work/ELZ-081.md`, “Chunk-count pre-check” and Evidence plan T6 / Upstream contract.** The pre-check is a necessary-condition refusal only if the pinned recursive splitter both covers the source and keeps each returned chunk within `chunk_size` under the default grapheme measure. Version 1.0.1's source and upstream property tests support those properties, but the public `TextChunker.split/2` interface does not make source coverage the Contract relied on by the issue. Record both as named, version-pinned upstream assumptions in `piece.json` and the README, test the implication directly against the production call over the selected corpus, and retain the post-check as the sole output authority. Do not word the seeded corpus as establishing the general implication.

4. **should-fix — `docs/work/ELZ-081.md`, A2 and “Source bound”.** The code confirms the no-separator fallback is quadratic: on each recursive slice `fallback_splitter/6` calls `String.length/1`, binary-searches prefixes using `String.slice/3`, then slices the remaining suffix again. The proposal's own observations make 2 MiB an uncomfortably high synchronous ceiling: 2 MiB of ASCII is recorded at about 23.5 seconds, while 1 MiB of four-byte emoji is already about 14.3 seconds; two MiB emoji has not been measured and is plausibly worse. Reject the proposed 2 MiB hard ceiling for this version and use a 1 MiB hard ceiling/default unless the owner deliberately accepts the longer worst case with additional evidence. The default should not increase above 1 MiB.

5. **note — `docs/work/ELZ-081.md`, “Added closure”.** The provider has no custom application callback and no observed Logger calls, but its `mix.exs` declares `extra_applications: [:logger]`. Keep the purity conclusion for the Recipe, but phrase the provider note precisely and retain the normal dependency/provider review.

## Requested answers

### A1 — `chunker_invariant`

**Recommendation: accept with the shape-safe amendment in finding 2.** Runtime re-checking offsets is necessary and honest because the declared value is an exact citation to frozen bytes; tests alone would only show selected current cases. The quoted A1 “before” text is byte-exact against the live issue body, including its line wraps, and the proposed “after” changes only the error list as stated. A narrower alternative is to omit the new reason and treat an upstream violation as an unhandled exception, but that contradicts the declared exception-free finite error table and does not protect the offset Contract.

### A2 — source ceiling

**Recommendation: reject 2 MiB; use a 1 MiB hard ceiling and retain the 1 MiB default for text_chunker 1.0.1.** The quadratic claim is correct from `RecursiveChunk.fallback_splitter/6`: repeated whole-remainder length/slicing work occurs once per fallback chunk, despite the prefix-size binary search. The quoted A2 “before” text is byte-exact against the live issue body, including its line wraps. The replacement text should retain the explanation but report a 1 MiB hard ceiling, distinguish the observations from a time guarantee, and say that a later provider/version or an explicit asynchronous boundary is needed before admitting larger sources.

### Grapheme-count pre-check

**Recommendation: keep it only with finding 3's explicit upstream assumptions and post-check.** With the pinned default strategy, each returned chunk is bounded by `chunk_size` under `String.length/1`, and upstream tests assert no gaps through the source; therefore `graphemes > max_chunks * chunk_size` is a sound necessary refusal and cannot reject an input that could yield at most `max_chunks` such chunks. It cannot admit an over-bound output because the post-check rejects every actual result above `max_chunks`. The Recipe must not upgrade finite local corpus results to a proof or present coverage as an Elzoo caller guarantee.

## Additional Contract checks

- Defaults are internally consistent and align with upstream validation: 2000 graphemes, 200 overlap, and `:plaintext`/`:markdown` are accepted by text_chunker 1.0.1; the Recipe's 16 minimum, half-size overlap maximum, `max_chunks` range, and narrower format subset are legitimate Elzoo policy.
- Empty source and invalid UTF-8 are correctly identified as pre-upstream checks; invalid UTF-8 must remain before `TextChunker.split/2`, which uses String functions and can raise. Validate every positional input and the options container before calling upstream, and preserve the stated error-precedence decision in tests.
- The no-source-bytes error rule is achievable only if option validation and invariant validation return closed atoms/names without embedding inspected values or upstream exception messages.
- Telemetry `not_applicable`, per-call Config `supported`, and Control `not_applicable` fit a pure call. The manifest must attach an in-bundle test path to supported Config and state that values apply only to the current call, with no hot reconfiguration.
- The evidence categories are appropriately separated: no Cure proof or Elixir typespec proof is claimed; tests ground selected Recipe behavior; text_chunker, OTP crypto, and Elixir string behavior remain named upstream contracts. The no-separator timing is monitored/observed behavior, not an acceptance threshold or proof.
- A new `integration/text-chunking` row is within the issue's published scope and avoids changing the deferred `integration/search-data` family. Do not turn the new ID into an unreviewed broadening of any ready Piece; the final registry, roadmap, release-plan, task-copy, manifest, README, ledger, and provider changes must stay coordinated.

## Verdict

**Proceed after fixes.** Resolve findings 1 through 4 in the live Contract/record before implementation; then the proposed responsibility, defaults, operational applicability, and upstream boundary are suitable for the Piece.
