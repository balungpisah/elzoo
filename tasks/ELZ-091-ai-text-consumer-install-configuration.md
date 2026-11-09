# ELZ-091 — Prove the AI text interface in its own copied consumer and carry Piece install configuration into exports

- Phase: protected surface (class S): consumer selection and export instructions
- Catalogue IDs: none (no new Piece; strengthens the evidence of integration/ai-model and integration/ai-text)
- Dependencies: ELZ-079

## Outcome

Close the two pieces of open work that ELZ-079 (#153, PR #164) recorded instead of changing shared code inside a
dependency change:

1. a per-ID copied consumer that takes only `integration/ai-model` (the family core) and `integration/ai-text`
   (the text interface) with their dependency closure and no provider Piece, so the claim "the interface works
   without any provider" is shown in the exported layout, not only by the interface's own tests;
2. Piece install configuration: a Piece can declare configuration lines that every consumer needs (first case:
   `config :req_llm, load_dotenv: false` for `integration/ai-text-anthropic`), the exporter writes them into the
   generated install file, and a copied consumer proves the configuration reaches it.

## Admission record

1. **Responsibility and caller.** Evidence infrastructure, no runtime behaviour. Callers: ELZ-079's acceptance item
   (amendment 2 named this task) and its limit "the copier merges no configuration and the harness does not prove
   consumer configuration"; every later provider Piece of the AI model family that needs consumer configuration
   (ELZ-087, ELZ-080, ELZ-085 use req_llm and need the same line).
2. **Interface and invariant.** (a) `integration/ai-text` joins the database consumers in
   `lib/elzoo/check_selection.ex` (`@consumer_ids` and `@postgres_consumer_ids`, because its closure reaches
   `integration/sql` through `delivery/effect-intent`) and in the consumer helper
   (`test/support/cure_consumer_case_test_helper.exs`), keeping the existing equality assertions of
   `test/export_test.exs` true (amendment 1: only three consumer-count literals change, see Scope); the consumer copies exactly the closure of `integration/ai-text`, loads no provider
   module, `req_llm` or `plug`, and runs the copied Pieces' own tests. (b) An optional `piece.json` field (name
   decided in the early review, for example `install_configuration`, a list of exact Elixir config lines with a
   one-line reason each) is validated by the registry, rendered by `lib/elzoo/export.ex` into
   `.elzoo/install/<key>.md` under a fixed heading, de-duplicated across the selected Pieces, and written by the
   consumer harness into the copied consumer's `config/config.exs`; a copied consumer of
   `integration/ai-text-anthropic` proves the value is set at runtime (`Application.get_env(:req_llm, :load_dotenv)
   == false` before req_llm starts) and the ELZ-079 README section becomes a pointer to the field. Invariants:
   existing consumers and their assertions are unchanged (except the three count literals of amendment 1); a Piece without the field exports exactly as today
   (byte-equal install file); configuration lines are data, never evaluated by the exporter.
3. **Reuse check.** No new library. Mix config files and the existing exporter and harness only.
4. **Split test.** The two parts share the consumer harness and the export tests and one reviewer; one PR. They are
   split from ELZ-079 because they change protected selection and export code (map: never combine class X with S).
5. **Failure and evidence.** Dangerous paths: a selection change that silently drops or reorders an existing
   consumer; an install file that changes for Pieces without the field (breaking receipts and hashes); a config
   line that is evaluated or shell-expanded during export; the new consumer passing because a provider module
   leaked into its closure. Tests: the equality assertions of `test/export_test.exs` hold with the new ID; a
   byte-equality test of the install file for an existing Piece without the field; a registry validation test for
   a malformed field; the new per-ID consumer asserts no provider module, `ReqLLM` or `Plug` is loadable; the
   Anthropic copied consumer asserts the configuration value. Proof: none required. Upstream: Mix configuration
   loading order (named, not proved).
6. **Composition record.** Changes evidence and export metadata only; no Piece Contract changes; receipts of
   existing exports stay valid. Telemetry, Config and Control: not applicable (no runtime Piece).

## Scope

- `lib/elzoo/check_selection.ex`: add `integration/ai-text` to `@consumer_ids` and `@postgres_consumer_ids`;
- `test/support/cure_consumer_case_test_helper.exs`: the matching consumer ID; write the merged install
  configuration into copied consumers;
- amendment 1: in `test/export_test.exs`, `assert length(per_id) == 26` becomes `27` and
  `assert length(remaining) == length(tests) - 25` becomes `- 26`; in `test/check_selection_test.exs`,
  `assert length(selection.skipped) == 25` becomes `26`. Exactly these three cardinality literals, which a 27th
  per-ID consumer makes false; every identity, equality, partition and limit assertion stays unchanged;
- `lib/elzoo/export.ex` and the registry validation: the optional install-configuration field and its rendering;
- `pieces/integration/ai-text-anthropic/piece.json`: declare `config :req_llm, load_dotenv: false` with its reason;
  its README section points to the field; the ELZ-079 limit wording is updated;
- `docs/consuming.md`: one paragraph on install configuration (this file is exported; not documentation-only);
- regenerate `LEDGER.md` and the plan views; add the task copy and release-plan entry.

## Acceptance

- [ ] The per-ID `integration/ai-text` consumer runs in `check-consumers-db` and passes, with no provider module,
      `ReqLLM` or `Plug` loadable in it.
- [ ] Every existing consumer and assertion is unchanged except the three count literals of amendment 1;
      `test/export_test.exs` equality assertions hold.
- [ ] The install file of a Piece without the field is byte-equal to the file before this change.
- [ ] A copied consumer of `integration/ai-text-anthropic` has `load_dotenv: false` set from the exported install
      configuration, with a test.
- [ ] Independent review (class S) of the diff, including the measured added `check-consumers-db` time.
- [ ] The hosted full check passes at the PR head.

## Evidence and limits

Finite tests over the listed scenarios; Mix's documented configuration loading. The harness proves the exported
configuration reaches a copied consumer built by this repository's harness; it does not prove that a hand-copied
consumer kept the line (that remains the consumer's documented Need).

## Out of scope

Runtime configuration management (`runtime/faces`), secrets, any change to a Piece Contract, other providers'
configuration lines (they adopt the field in their own tasks).

## Reference

ELZ-079 (#153) amendment 2 and final-review finding F2 dispositions (PR #164); docs/development/12-change-class-flow.md
(class S, never combined with class X).
