# ELZ-302 — Versioned datasets of scripted recipe cases, scored into a deterministic report

- Phase: Wave 6 Level 1
- Dependencies: ELZ-033, ELZ-096, ELZ-115, ELZ-181, ELZ-183
- Release: V1B
- Output: new `workflow/eval` Piece (it absorbs the `state/eval-dataset` handle: the dataset format belongs to eval, and its bytes live in ready `state/artifact`)
- Change class: Piece-only
- Owned paths: `pieces/workflow/eval/**` and its own catalogue/release-plan rows and generated views only. Do not edit `runtime/recipe-test`, another Piece, root/shared code, `mix.exs`, `mix.lock` or CI.

## Outcome and boundary

A test-time Piece, like `runtime/recipe-test` (ELZ-181, ELZ-183), for owner Q7 A (2026-11-21): a versioned JSON dataset of recipe cases with checks, read through `state/artifact` (ELZ-096) with its hash verified, run case by case through `Elzoo.RecipeTest.run/1` with scripted models only, and scored into a report that is a plain value. No live model, network, model-graded judge, storage of the report or new dependency. The host may store the report as an artifact itself.

A dataset case cannot hold a whole recipe-test spec: the spec holds modules, an Adapter list, a gate function and a sandbox path, which JSON cannot carry. So a case holds the data that varies per case (its input, its script and its checks), and the host supplies the rest of the spec (package, facts, sources, agents, decisions, effects, adapters, tools, executable, skills, gate) once per run. A changed recipe package is therefore a changed host spec over the same dataset.

## Dataset format, version 1

UTF-8 JSON, decoded with `Jason.decode/2` and `objects: :ordered_objects` so that a duplicate key in any object is refused. At most 16,777,216 bytes. The root is exactly:

- `format_version`: `1`;
- `dataset_id`: 1..128 bytes of valid UTF-8 without a C0 or C1 control character;
- `version`: an integer 1..2^31−1, the author's version of this dataset;
- `cases`: 1..256 cases, each exactly `{case_id, input, script, restart_after, checks}`. `case_id` follows the `dataset_id` rule and is unique in the dataset. `input` is the recipe-test `input` (an object or non-empty text). `restart_after` is `null` or a positive integer. `script` is a list of 0..256 `{key, results}`: `key` is exactly `{"model": text}` or `{"tool": text}`, each key at most once, and `results` a list of 1..256 entries, each exactly `{"class": "completed", "value": json}` or `{"class": "failed" | "refused" | "unknown", "reason": text}` with `reason` matching `[a-z0-9_]{1,64}`. They decode to the recipe-test script `%{{:model, m} => [{:completed, v} | {class, reason}]}`.
- `checks`: 1..16 per case, each an object with exactly a `kind` and its members:

| `kind` | Members | Passes when |
| --- | --- | --- |
| `outcome_is` | `outcome`: `"completed"`, `"failed"`, `"cancelled"`, `"out_of_budget"` or `"out_of_time"` | the record's `outcome` is that atom |
| `final_text_equals`, `final_text_contains` | `text`: 1..65,536 bytes | the final text (below) equals, or contains, `text` by bytes |
| `structured_matches` | `schema`: a JSON Schema object | the root finish payload (below) passes `Elzoo.PayloadSchema.check/3` with the schema built by `build/2` for the port `%{"id" => "elzoo.eval.structured", "direction" => "output", "schema_id" => "elzoo.eval.structured", "schema_version" => 1}` |
| `tool_called` | `alias`: text; `at_least`: 1..256 | at least `at_least` admitted `tool_call` actions have payload `"alias"` equal to `alias` |
| `tool_not_called` | `alias`: text | no admitted `tool_call` action has that `"alias"` |
| `max_steps` | `steps`: 1..65,536 | the record has at most `steps` `:action` steps |

The root finish is the last `:action` step of kind `finish` of a completed record. The final text is the `content` of the completed model-call outcome (an `:input` step of kind `action_outcome`) whose `action_id` is the `action_id` of a root finish whose payload has `"status": "answered"` (the `workflow/agent-loop` finish form); any other root has no final text, and the text checks fail with reason `no_final_text`. A check that has no root finish fails with `no_root_finish`.

An unknown key, kind or `format_version` is refused. The check kinds and the root members form closed sets that a later in-place version may extend: a new check kind, or a new optional root member such as a `mode` for live-model scoring with the default meaning scripted (owner Q7 B, deferred), is added without changing a version 1 dataset or its report.

## Interface

- `Elzoo.Eval.decode(bytes)` returns `{:ok, dataset}` or `{:error, {:dataset, path, reason}}`, where `path` is the list of object keys and list indexes to the first fault in document order and `reason` a fixed atom (`:json`, `:too_large`, `:duplicate_key`, `:unknown_key`, `:missing_key`, `:type`, `:bounds`, `:duplicate_case`, `:duplicate_script_key`, `:unknown_kind`, `:format_version`, `:schema`). A `structured_matches` schema that `build/2` refuses is `:schema` at its path. The dataset identity is `%{dataset_id, version, sha256}` with `sha256` the lowercase hex SHA-256 of the bytes.
- `Elzoo.Eval.load(artifact, caller, artifact_id, version)` reads the bytes with `Elzoo.Artifact.get/4` and decodes them. An `{:error, {:integrity_mismatch, _}}` of the artifact is `{:error, :integrity_mismatch}`; any other artifact error is `{:error, :artifact_unavailable}`; no bytes are decoded in either case.
- `Elzoo.Eval.score(record, checks)` is pure: for one recipe-test record and a case's decoded checks it returns `%{status: :passed | :failed, checks: [%{kind, status: :passed | :failed, reason}]}` in check order; `reason` is `nil` for a pass and a fixed atom for a failure (`:outcome`, `:text`, `:no_final_text`, `:no_root_finish`, `:schema`, `:tool_count`, `:tool_called`, `:steps`).
- `Elzoo.Eval.run(dataset, base_spec)`, in the test helper `test/support/eval_helper.exs` (loaded with `Code.require_file`, as `runtime/recipe-test` is), merges each case's `input`, decoded `script` and `restart_after` into `base_spec` (every other recipe-test spec key) and calls `Elzoo.RecipeTest.run/1` once per case in dataset order. The calling test module starts what recipe-test needs, as its README says. It returns the report `%{dataset: identity, package: identity, passed, failed, errored, cases}`: `package` is the `"identity"` of `base_spec.package`; each case is `%{case_id, status: :passed | :failed | :error, checks, error}`. A recipe-test `{:error, reason}` (for example `{:unscripted_call, key, record}`) or a raise in the harness is a case with status `:error`, `checks: []` and `error` the first element of the reason tuple (or `:harness`), never a crash of `run/2`. The report has no time, PID or reference.

The report, the case and check maps, and the reason sets may gain keys and members in a later in-place version; a caller matches on the ones it uses. `piece.json` declares telemetry, config and control `not_applicable` and lists `runtime/recipe-test`, `state/artifact` and `core/payload-schema` as Piece dependencies.

## Acceptance

1. A passing dataset of at least three cases over an agent root and a graph root, loaded from an artifact (the Memory Store and fake object store of the `state/artifact` test helper may serve; no live object store), gives a report with every case `:passed`.
2. One failing case per check kind, each with its fixed reason; `no_final_text` for a graph root.
3. A malformed dataset refused at its path: a duplicate key in a nested object, an unknown check kind, 257 cases, a duplicate `case_id`, a `results` entry with a bad `reason`, and an invalid schema, each with the expected path and reason.
4. An artifact whose stored bytes were changed is `:integrity_mismatch`.
5. A case whose script lacks a key the recipe calls is a case `:error` with `error: :unscripted_call`, and the other cases still run.
6. The same dataset run twice gives equal reports (observed, not proven).
7. A changed recipe package in `base_spec` over the same dataset flips the expected case from passed to failed, and the report's `package` identity changes.

Risk is low (author data, test-time, no durable state of its own), so one light review applies, and the hosted `check-piece` on the exact head may serve as the small gate, recorded as `Local gate: hosted check-piece <run ID>`, with the Piece tests and `git diff --check` run locally. Run the roadmap and claims checks. The merge queue is required.

## Limits to state

Scripted results are written by the author, so a passing report shows that the recipe handles those results, not that a provider would give them. No live model, judge, statistics or storage of the report. Test-time only, with the limits of `runtime/recipe-test` (fixed clock, one restart, no network).
