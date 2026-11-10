# ELZ-091 early independent Contract review

Reviewer: independent reviewer (Codex, gpt-5.6-terra, high effort)

Reviewed SHA: `5b5f02a5d8727df899911938f4e21a2c3ad54de2`

Verdict: proceed after fixes.

## Inputs

- `git show 5b5f02a5d8727df899911938f4e21a2c3ad54de2:docs/work/ELZ-091.md`
- `git diff origin/main...5b5f02a5d8727df899911938f4e21a2c3ad54de2` (one added work-record file only)
- Live [issue #165](https://github.com/balungpisah/elzoo/issues/165), `AGENTS.md`, and `docs/development/12-change-class-flow.md` (class S)
- `docs/consuming.md`; the named baseline selection, export, registry, consumer-helper and selection/export-test sources at `origin/main`
- Merged ELZ-079 manifests and records for `integration/ai-model`, `integration/ai-text`, and `integration/ai-text-anthropic`; pending ELZ-083's root dependency resolution for the runtime `plug` pin

This is an early Contract review, not an implementation pass: the reviewed diff contains no implementation. No Mix command was run.

## Findings

1. **Blocker — live acceptance contradicts the required cardinality changes.**

   **Location:** Live issue #165, Admission record 2 and Acceptance; proposed record lines 155-162; baseline `test/export_test.exs:184,230` and `test/check_selection_test.exs:20`.

   Adding the required 27th tagged per-ID test makes all three literal assertions false. The proposed `26 -> 27`, `- 25 -> - 26`, and `25 -> 26` edits are the minimal honest mechanical change; all identity, PostgreSQL-list, partition, limit, and set-equality assertions can stay intact. But they are edits to existing assertions and the two protected test files are not in the current issue Scope, so they are not consistent with the issue's literal statement that every existing consumer and assertion is unchanged.

   **Concrete change:** before implementation, amend issue #165 to authorize exactly these three cardinality updates in `test/export_test.exs` and `test/check_selection_test.exs`, while retaining the substantive invariant: existing IDs, existing individual consumer cases, and the equality/partition/limit assertions remain unchanged. Synchronize the task copy after that decision. There is no alternative that leaves these tests untouched without either omitting the required consumer, failing the suite, or weakening/removing a count assertion.

2. **Should-fix — configuration provenance and same-line semantics are underspecified.**

   **Location:** proposed record lines 41-57 and 68-71.

   The rendered comment needs a Piece ID and reason, while the stated plan shape is only `configuration: [line]`. Exact-line de-duplication also does not state which reason survives if two Pieces declare identical text with different reasons, and the conflict rule does not say how duplicate keys in one `config/2` call are handled.

   **Concrete change:** validate each line once into retained metadata such as `{piece_id, line, reason, settings}` where `settings` is an ordered list of `{app, key, literal_value}`. On exact duplicate text, retain the first declaration in selection/declaration order (including its reason) and document that choice. Reject a repeated key within a single call. Across selected Pieces, permit repeated `{app, key, value}` values, but make `plan!/3` raise before any write for any differing literal value at the same `{app, key}`; the error must name both Pieces and values. The rendered plan may expose only lines if desired, but rendering must receive the retained provenance.

3. **Should-fix — make the pre-start proof process boundary explicit.**

   **Location:** proposed record lines 80-88 and 121-125.

   The aggregate consumer is an acceptable copied consumer for the Anthropic acceptance, but its ordinary `mix test` process starts `:consumer` and its selected runtime applications, including `:req_llm`. A later assertion in that same VM would not prove the required pre-start state.

   **Concrete change:** run the configuration assertion in a fresh copied-consumer process after the normal test process, with `mix run --no-start --no-compile` (or equivalently explicit Mix invocation). In that process, assert `Application.get_env(:req_llm, :load_dotenv) == false` and `:req_llm` is absent from `Application.started_applications/0` before any `ensure_all_started` or provider call, then emit the stated marker. Reading the parsed literal configuration in the harness is acceptable only after registry validation; the exporter must not evaluate it.

4. **Note — the per-ID closure remains insulated from a root runtime `plug` pin.**

   **Location:** baseline `test/support/cure_consumer_case_test_helper.exs:140-181,413-430`; proposed record lines 89-93.

   ELZ-083 changes root `plug` from test-only to runtime, but the consumer helper derives `roots`, `apps`, `paths`, and `extra_applications` from `plan.providers`, not from every root Mix dependency. The `integration/ai-text` closure contains neither the Anthropic Piece nor provider `req_llm` or `plug`; its paths therefore exclude `Plug` unless a selected provider transitively introduces it. The proposed assertions in both the consumer test VM and compiler-free runtime VM are the right regression evidence. Keep an explicit plan assertion that no selected Piece is `integration/ai-text-*` other than the requested interface and no selected provider package is `req_llm` or `plug`; scan the consumer ebin for `Elzoo.AiText.Provider` implementations as proposed.

5. **Note — evidence and timing are proportionate once findings 1-3 are resolved.**

   **Location:** proposed record lines 127-146.

   The two fixed no-configuration golden selections (`runtime/unit` and `integration/cure-json`) are a useful byte-for-byte regression boundary because install guidance has no receipt revision value. Keep a direct empty-section test as well, and compare static fixture bytes rather than regenerating an expected value through the changed exporter. Record the added sequential `consumers-db` consumer's `ELZOO TIMING consumer=integration/ai-text total` from the local run and the hosted PR run, alongside the job/attempt context; it is monitored behavior, not a proof or a timeout justification by itself.

## Answers to requested questions

### Q1

**Recommendation: approve the three literal updates only after an issue amendment.** They are the minimal honest updates required by a new tagged consumer. They are not, under the live wording, literally consistent with "existing consumers and their assertions are unchanged," and no evidence-preserving route keeps the tests untouched. Preserve every existing equality, partition, limit, and ID assertion; amend only the three cardinalities and the issue scope that authorizes the two protected test files.

### Q2

**Recommendation: accept the aggregate consumer, with the fresh pre-start process in finding 3.** It selects every ready Piece, including `integration/ai-text-anthropic`, so it is a valid copied-consumer witness and avoids an unrequested second PostgreSQL consumer. A separate `--no-start --no-compile` VM can observe the configuration before `:req_llm` starts only if it asserts both the value and non-started application state before any start operation; the already-completed aggregate `mix test` VM cannot supply that observation.

### Q3

**Recommendation: accept `install_configuration` and the literal-only `config/2` scope, with normalized semantic validation.** The field should be absent or a non-empty list of exactly `{line, reason}` objects; each line should parse to exactly one bare `config/2` AST with an atom app, unique keyword keys, and recursively allowed literal values only (atoms, booleans, nil, numbers, strings, and lists thereof). The app must equal a package of a direct declared provider of that Piece; parsing must never evaluate.

De-duplicate only exact line text in stable Piece/declaration order, retaining the first declaration's provenance for rendering. For each parsed `{app, key}`, identical values across Pieces are compatible; different literal values are a deterministic `plan!/3` error before preflight/write, naming the conflict. If no selected Piece has the field, the conditional rendering must contribute exactly zero bytes so the complete install file remains byte-identical; verify that with frozen baseline fixtures.

## Grounding and limits

- **Contract/scope review:** checked against the live issue and class-S rules. The issue amendment in finding 1 is required before the protected-test edits.
- **Static design review:** checked the selection and consumer helper's plan-derived provider closure. This supports the stated `plug` exclusion only for the selected `integration/ai-text` plan; executable evidence remains required.
- **No proof claimed.** The proposed parser validation, copied-consumer runs, byte fixtures, and timing observations are finite tests/monitoring. Mix configuration load order and `Code.string_to_quoted/1` non-evaluation remain named upstream contracts.

Severity counts: blocker 1; should-fix 2; note 2.
