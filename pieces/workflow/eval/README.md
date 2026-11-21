# workflow/eval

A recipe author scores a recipe in ExUnit against a versioned dataset of scripted cases.
`Elzoo.Eval.load/4` reads the dataset bytes from `state/artifact`, with their hash verified, and
decodes them. `Elzoo.Eval.run/2` runs each case once through `Elzoo.RecipeTest.run/1` of
`runtime/recipe-test`, with scripted models only, and scores the record with a closed set of
checks. The report is a plain value. There is no live model, no network, no judge and no
storage of the report; the host may store the report as an artifact itself.

A case holds what varies per case: its input, its script and its checks. A recipe-test spec
also holds modules, Adapters, a gate function and a sandbox path, which JSON cannot carry, so
the host gives the rest of the spec once per run (`base_spec`). A changed recipe package is a
changed `base_spec` over the same dataset.

Everything is in the test helper `test/support/eval_helper.exs`, loaded with
`Code.require_file`, as `runtime/recipe-test` is. It loads the helper of `runtime/recipe-test`
(a sibling in a copied consumer, `../../../../runtime/recipe-test/test/support/` from
`test/support/` in the repository). No module is compiled.

## Use

    Code.require_file("../support/eval_helper.exs", __DIR__)

    # in a test module that starts what runtime/recipe-test needs (see its README)
    test "my recipe passes its dataset" do
      {:ok, dataset} = Elzoo.Eval.load(artifact, caller, "my-dataset", :head)
      report = Elzoo.Eval.run(dataset, base_spec)
      assert report.failed == 0 and report.errored == 0
    end

`base_spec` is a recipe-test spec without `input`, `script` and `restart_after`: `package`,
`facts`, `sources`, `agents`, `decisions`, `effects`, `adapters`, `tools`, `executable`, `skills`
and `gate`, as the README of `runtime/recipe-test` says.

## Dataset format, version 1

UTF-8 JSON of at most 16,777,216 bytes, decoded with `Jason.decode/2` and
`objects: :ordered_objects`, so that a repeated key in any object is refused. The root is
exactly:

| Member | Value |
| --- | --- |
| `format_version` | `1` |
| `dataset_id` | 1..128 bytes of UTF-8 without a C0 or C1 control character |
| `version` | an integer 1..2,147,483,647: the author's version of this dataset |
| `cases` | 1..256 cases |

A case is exactly `{case_id, input, script, restart_after, checks}`:

- `case_id`: the rule of `dataset_id`, unique in the dataset;
- `input`: the recipe-test `input`, an object or non-empty text;
- `restart_after`: `null` or a positive integer, the recipe-test member;
- `script`: a list of 0..256 `{key, results}`. `key` is exactly `{"model": text}` or
  `{"tool": text}`, each key at most once. `results` is a list of 1..256 entries, each exactly
  `{"class": "completed", "value": json}` or `{"class": "failed" | "refused" | "unknown",
  "reason": text}`, with `reason` matching `[a-z0-9_]{1,64}`. The script decodes to the
  recipe-test script `%{{:model, m} => [{:completed, v} | {class, reason}]}`;
- `checks`: 1..16 checks, each an object with exactly a `kind` and its members:

| `kind` | Members | Passes when | Failure reason |
| --- | --- | --- | --- |
| `outcome_is` | `outcome`: `completed`, `failed`, `cancelled`, `out_of_budget` or `out_of_time` | the record's `outcome` is that atom | `outcome` |
| `final_text_equals` | `text`: 1..65,536 bytes | the final text equals `text` by bytes | `text` |
| `final_text_contains` | `text`: 1..65,536 bytes | the final text contains `text` by bytes | `text` |
| `structured_matches` | `schema`: a JSON Schema object | the root finish payload passes `Elzoo.PayloadSchema.check/3` | `schema` |
| `tool_called` | `alias`: text; `at_least`: 1..256 | at least `at_least` admitted `tool_call` actions have payload `"alias"` equal to `alias` | `tool_count` |
| `tool_not_called` | `alias`: text | no admitted `tool_call` action has that `"alias"` | `tool_called` |
| `max_steps` | `steps`: 1..65,536 | the record has at most `steps` `:action` steps | `steps` |

The schema of `structured_matches` is built once, at decode, by `Elzoo.PayloadSchema.build/2`
for the port `%{"id" => "elzoo.eval.structured", "direction" => "output", "schema_id" =>
"elzoo.eval.structured", "schema_version" => 1}`.

**Root finish and final text.** The root finish is the last `:action` step of kind `finish` of a
record whose `outcome` is `:completed`. The final text is the `content` of the completed
model-call outcome (an `:input` step of kind `action_outcome`) whose `action_id` is the
`action_id` of a root finish whose payload has `"status": "answered"`, the finish form of
`workflow/agent-loop`. Any other root, such as a graph root, has no final text, and the two
text checks fail with `no_final_text`. The text checks and `structured_matches` fail with
`no_root_finish` when the record has no root finish.

**Extension.** The check kinds and the root members are closed sets. A later in-place version may
add a check kind, or an optional root member such as a `mode` for live-model scoring whose
default is scripted, without changing a version 1 dataset or its report. An unknown key, kind or
`format_version` is refused today.

## Interface

`Elzoo.Eval.decode(bytes)` returns `{:ok, %{identity: identity, cases: cases}}` or
`{:error, {:dataset, path, reason}}`. `identity` is `%{dataset_id, version, sha256}`, with
`sha256` the lowercase hex SHA-256 of the bytes. `cases` are the decoded cases, in dataset order,
with atom keys `case_id`, `input`, `script`, `restart_after` and `checks`. `path` is the list of
object keys and list indexes to the first fault, and `reason` one of:

| Reason | When |
| --- | --- |
| `:json` | not JSON (path `[]`) |
| `:too_large` | over 16,777,216 bytes (path `[]`) |
| `:format_version` | a `format_version` other than `1`; checked before any other member |
| `:duplicate_key` | a repeated key, at the second one |
| `:unknown_key` / `:missing_key` | a member that the object does not have / lacks |
| `:type` | a value of another JSON type |
| `:bounds` | a count, length, integer, text or enumerated value out of its range or set (an unknown result `class` included) |
| `:duplicate_case` / `:duplicate_script_key` | a repeated `case_id` / script key, at the second one |
| `:unknown_kind` | a check `kind` that is not in the table, at `kind` |
| `:schema` | a `structured_matches` schema that `build/2` refuses, at `schema` |

The walk is in document order. A list's length is checked before its items. A missing member is
reported after the members that are present, in the order of the tables above. In a check or a
result entry, `kind` or `class` decides which other members the object may have.

`Elzoo.Eval.load(artifact, caller, artifact_id, version)` reads the bytes with
`Elzoo.Artifact.get/4` and decodes them. `{:error, {:integrity_mismatch, _}}` of the artifact is
`{:error, :integrity_mismatch}`; any other artifact error is `{:error, :artifact_unavailable}`.
No bytes are decoded in either case.

`Elzoo.Eval.score(record, checks)` is pure. For one recipe-test record and the decoded checks of
a case it returns `%{status: :passed | :failed, checks: [%{kind, status, reason}]}` in check
order: `reason` is `nil` for a pass and the reason of the table for a failure.

`Elzoo.Eval.run(dataset, base_spec)` merges each case's `input`, `script` and `restart_after`
into `base_spec` and calls `Elzoo.RecipeTest.run/1` once per case, in dataset order. It returns

    %{dataset: identity, package: package_identity, passed: n, failed: n, errored: n, cases: [case]}

with `package` the `"identity"` of `base_spec.package` and each case
`%{case_id, status: :passed | :failed | :error, checks, error}`. A recipe-test `{:error, reason}`,
such as `{:unscripted_call, key, record}`, or a raise or exit in the harness is a case with
status `:error`, `checks: []` and `error` the reason when it is an atom, else the first element
of the reason tuple, or `:harness` for a raise or exit. `run/2` does not crash for one case. The
report holds no time, PID, reference or record.

The report, the case and check maps and the reason sets may gain keys and members in a later
in-place version; a caller matches on the ones it uses.

## Needs

- What `runtime/recipe-test` needs: PostgreSQL through `ELZOO_TEST_DATABASE_URL` and a test
  module that starts the repository and the two Registries of the engine helper.
- For `load/4`: a `state/artifact` handle and a caller that may read the artifact.

## Limits

- Scripted results are written by the author, so a passing report shows that the recipe handles
  those results, not that a provider would give them. No live model, judge, statistics or storage
  of the report.
- Test-time only, with the limits of `runtime/recipe-test`: a clock that does not move, one
  restart, no network. A record whose Run did not end `:completed`, such as an agent that stopped,
  has no root finish.
- The same dataset gives the same report: observed in the tests, not proven.
