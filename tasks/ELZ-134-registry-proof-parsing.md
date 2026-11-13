# ELZ-134 — Remove repeated proof-source parsing from Registry validation

- Dependencies: none
- Allowed implementation paths: `lib/elzoo/registry.ex`, `test/registry_test.exs` only.

Contract: unchanged. Within each current `Registry.load!`/Piece validation, parse each proof source once using the existing pinned Cure lexer/parser and check every claimed symbol against that source's actual equality declarations. Preserve fresh-load semantics and every metadata, source-path/symlink, malformed-source, comment/string, provider and dependency check. Reuse is local to that validation only; no persistent/process/global cache, framework or options. Do not move work outside the timed consumer, omit nested tests/compilation or provenance checks, or change harness, selectors, timeouts, dependencies or pins.

## Acceptance

- Public `Registry.load!` fixtures accept multiple actual equality symbols from one source and reject an invalid later claim while an earlier claim remains valid. Reloading the same root after a source edit rejects missing/non-equality declarations, with no stale reuse. Existing rejection scenarios remain unchanged; a temporary first-symbol-only production negative fails.
- Run `mix test test/registry_test.exs`; run unchanged `mix test test/export_test.exs --only consumer_id:integration/ai-text` twice sequentially with private native disposable PostgreSQL and fresh copied-consumer destinations, retaining 120000 ms and all copied/source-copy/provider-isolation/compiler-free-runtime assertions; run `mix check --affected origin/main`, `git diff --check`, independent review and exact-head hosted evidence under AGENTS.md. Keep original timeout evidence; benchmark equivalence alone is not ai-text closure.
- The corrected consumer must actually pass both runs and all gates. If insufficient, report a blocker rather than expand scope or declare closure.

Admission evidence on main `35ef86d287c86a99e78a1473bbdd1b9a257eae5d`: 273 proof claims across 21 sources. A read-only same-run comparison using the pinned parser and AST filter measured per-claim 28.778538 s versus per-source 1.893295 s; all 273 symbol results were identical and true, and malformed/comment negatives were rejected. A prior comparison measured 28.687485 s versus 2.058573 s. The actual ai-text consumer still timed out at 120000 ms before repair. These measurements are not a passing consumer gate. Investigation: #272.
