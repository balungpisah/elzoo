# ELZ-298 — Read-only Run transcript of the run engine

- Phase: Wave 6 Level 1
- Dependencies: ELZ-127, ELZ-256, ELZ-265, ELZ-287
- Release: V1B
- Output: none; extend the ready `assembly/run-engine` Contract in place (job handle `state/run-transcript`; no new Piece ID, under the pre-release in-place rule of 2026-11-14)
- Change class: Piece-only
- Owned paths: `pieces/assembly/run-engine/**` and that Piece's catalogue/release-plan rows and generated views only. Do not edit `runtime/recipe-test`, another Piece, root tests, shared code, dependencies, pins or CI.

## Outcome

Add `RunEngine.transcript(engine, scope, limits)`: a bounded, read-only view of one Run's committed history, in commit order, that shows what the Run did: its inputs, gate and authorization verdicts, admitted actions with their place in the callable tree, nested starts and kept finishes, settlements with their recorded times, and the terminal outcome. The engine owns the record format, so this reader lives in the engine and no new Piece decodes the records; `runtime/recipe-test` still decodes them in its test helper and stays unchanged. It is not a metric, trace exporter, audit record or cache, and it changes no persisted record, recovery fingerprint, execution Need or existing API. It emits no telemetry: Run and model metrics, if the owner asks for them later (Q8 A defers them), are a separate in-place addition to `runtime/telemetry`, `integration/observability` and the emitting Pieces, not part of this API.

## API

- Same call path and limits as `result/3` and `event_waits/3`: a call to the running engine with the 60,000 ms caller limit. Reading a Run whose engine is not running is not part of this task.
- `scope` is exactly `%{tenant: t, principal: p, run_id: r}` and must equal the engine's configured values; `limits` is exactly `%{max_records: n, max_bytes: n}` with positive integers at most 65,536 and 536,870,912. Both are validated before any Run-owner or Store read.
- It needs the same optional `result_reader: %{evidence_store: store, retention_count: positive_integer}` start configuration; without it a valid call returns `{:error, :reader_unconfigured}`.
- It works for every Run state: a running, waiting, paused or ASK Run returns its history so far.
- Result: `{:ok, %{run_id: r, entries: [entry]}}`. Errors are exactly `{:error, :scope}`, `{:error, :invalid_limits}`, `{:error, :reader_unconfigured}`, `{:error, :read_limit}`, `{:error, :history}` and `{:error, :unavailable}`, with the meanings they have for `event_waits/3`. There is no completion selection, so `:completion_mismatch` does not occur.

## Reading

Read the committed Unit rows from sequence 1, one row per Store page, with public `Elzoo.DurableLog.read/4` and row validation, fold the paired input/result rows with the reducer of `Elzoo.DurableUnit.fold/1` (as `ResultReader` does), and count the inspected rows and their canonical bytes against the limits as `event_waits/3` does; never truncate a valid history into success. Refuse pruned, gapped, damaged, version-invalid, staged or unpaired history with `:history`, an unavailable or failing Store with `:unavailable`, and recheck the Run-owner revision and stable stream heads before returning, as `event_waits/3` does.

Entries are derived from the change of the folded state that each committed record makes, together with that record, so every way a slot settles (a host or engine outcome record, a change of Attempt or the end of a Run in a `:run_view` record or a later protocol input, a root `:finish`) and every later actual (a `:nested_actual` record or a Resource cursor) is covered without a second decoder. Gate and precheck records do not settle a slot; a refusal settles later through the engine's outcome record. Only the scoped Run's entries are returned: on a Unit whose history holds earlier Runs, entries start at the record that configures the scoped `run_id`; the earlier Runs are folded, not returned. A protocol record whose `run_id` is not the scoped Run (a late input of an earlier Run) gives no entry.

The reader calls no Operator, pattern, gate, schema, binding, work, resource, source or clock callback, and does not start, drain, repair, append, acknowledge, checkpoint or mutate anything. Two reads of an unchanged history are equal.

## Entries

Every entry has `type`, `sequence` (the Unit row sequence of the input row that holds the record; its paired result row is the next sequence) and `at_ms`, the record's own time: `input["at_ms"]` of a protocol record, `at_ms` of a gate, admission, authorization, nested, finish, nested-actual, resource-cursor or event-activation record, `view.at_ms` of a `:run_view` record, `command.at_ms` of a `:lifecycle` record, and `nil` for a kind that records no time (`:configure`, `:precheck`, `:continuation`, `:resume_input`). Within one record, entries come in the type order below, then by occurrence. An `occurrence` is the engine's `{request, index}`. A `path` is the list of occurrences of the enclosing `nested_callable` actions from the root down; it is `[]` for an action of the root callable.

| `type` | Further fields |
| --- | --- |
| `:input` | `input_id`, `kind` (the neutral input's `kind`), for each committed protocol record of the scoped Run |
| `:gate` | `occurrence`, `verdict` (`:allow` or `:deny`), `reason`, `gate_id`, `gate_version` |
| `:action` | `occurrence`, `path`, `attempt_id`, `kind`, `action_id`, `schema_id`, `schema_version`, `payload`, when the slot is admitted |
| `:authorization` | `occurrence`, `verdict` (`:allow`, `:ask`, `:deny`, or `:refused` when the engine recorded no decision), `policy` (`%{id, version, content_hash}` of the decision, or `nil`) |
| `:nested_start` | `occurrence` of the `nested_callable` action, `schema_id`, `schema_version`, `payload` of the start |
| `:nested_finish` | `occurrence` of the `nested_callable` action, `schema_id`, `schema_version`, `payload` of the child's first admitted finish that the engine keeps for the parent |
| `:settlement` | `occurrence`, `path`, `action_id`, `outcome` (the outcome class of the settled slot), `by` (the kind of the record that settled it, for example `:protocol`, `:run_view` or `:finish`), `reason` (the `reason` member of the payload when the settling record is a protocol outcome under the refusal schema `elzoo.run-engine.refusal` whose `correlation.occurrence` and input `action_id` name this slot, else `nil`, because one record can also settle other slots in the same fold step, for example by expiry or `run_closed`; settlements that the engine makes inside a fold step, such as `attempt_closed`, `run_closed` and `local_closed`, record no reason, so `by` tells them apart), `actual` (the slot's recorded actual; `0` for a `finish` action settled by its `:finish` record, whose Budget entry settles at 0; `:unknown` when none is recorded) |
| `:actual` | `occurrence`, `actual`: a settled slot whose recorded actual changes later from none to an integer (for example by `:nested_actual`) |
| `:terminal` | `outcome`, when the Run becomes terminal |

A span of an action is its `:action` entry to its `:settlement` entry in recorded time; the reader reads no clock. The entry types, their fields and the `by` kinds may gain members and keys in a later in-place version; a caller matches on the ones it uses. The payload of a host-supplied outcome is not an entry: `result/3` gives the completion payload, and `event_waits/3` gives wait cursors and receipts.

## Acceptance

Use the existing test helper and Stores of the Piece. Root tests and `runtime/recipe-test` load `test/support/run_engine_test_helper.exs`: change it only by adding functions, and keep every existing function and its behavior.

1. A completed Run with a nested graph (a root `nested_callable` whose child starts its own `nested_callable`) gives the expected tree: each action's `path`, the `:nested_start` and `:nested_finish` entries, each settlement with its `by`, the root finish's `actual: 0` and the `:terminal` entry, in commit order, with the expected `at_ms` of the test clock.
2. An ASK-paused Run returns its entries so far: the `:ask` authorization with its policy identity and no settlement for that action.
3. An Effect made `unknown` by a restart shows a settlement with `outcome` `unknown` and `actual: :unknown`; an Attempt change shows its closed slots with `by: :run_view` and `reason: nil`.
4. A native v2 outside-event wait shows the `wait_event` action, the outside-event input and its settlement.
5. A gate denial shows the `:deny` verdict and the refusal settlement with the refusal `reason`, with no `:action` entry for that occurrence. An engine refusal of slot X committed after the deadline of another open slot Y settles both in one record: X has its refusal `reason`, Y has `reason: nil`.
6. A Unit whose history holds an earlier Run returns only the scoped Run's entries, also when a late input of the earlier Run is committed after the new Run is configured.
7. Wrong tenant, principal or Run is `:scope` with no Run-owner or Store read; malformed limits are `:invalid_limits`; no reader is `:reader_unconfigured`.
8. With `max_records` and `max_bytes` set exactly to the history the call inspects the read succeeds; one record or one byte less is `:read_limit`. Pruned history is `:history`; an unavailable Store is `:unavailable`.
9. Read-only: Unit, Run-owner and evidence stream heads are unchanged and every callback counter stays at zero across the reads; two reads are equal.
10. Negative controls, one at a time, each restored byte for byte before the final gates: drop the parent-occurrence link from `path` (case 1 must fail); emit entries from sequence 1 regardless of the configured Run (case 6 must fail).

Update the README, `piece.json` (contract, grounding, files) and the Piece's `release-plan.json` entry (`note` and `manifest_sha256`) in the last commit. Run the Piece tests and the small gate, which reruns the ready dependants it selects (`runtime/recipe-test` and the per-ID consumers of `assembly/run-engine`), the roadmap and claims checks and the diff check. `assembly/run-engine` keeps durable state, so the full review of the coordinator guide ("Reviewer by risk") applies; the exact-head hosted check and the merge queue are required.

## Limits to state

A transcript is the committed history of a running engine, not an audit record, metric or trace export; it emits no telemetry. Outcome payloads other than admitted action payloads are not shown. The host must supply full retained history; a pruned history is refused, not summarized.
