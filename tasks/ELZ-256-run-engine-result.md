# ELZ-256 — Read an authoritative completed Run result

- Phase: Level 3 prerequisite
- Dependencies: ELZ-127, ELZ-172, ELZ-252
- Output: none; extend the ready `assembly/run-engine` Contract in place
- Owned paths: `pieces/assembly/run-engine/**` and that Piece's catalogue/release-plan rows and generated views only. Do not edit another Piece, root tests, shared code, dependencies, pins or CI.

## Outcome

Add a bounded, read-only result API to the existing RunEngine. It returns payload only when the existing Run owner confirms completion and the payload is the exact first accepted settlement that completed that same Run/Attempt. This is not a Run limit, result cache, new Store, or new Piece.

## API and Needs

Add `RunEngine.result(engine, scope, limits)` using the existing 60,000 ms GenServer-call bound. `scope` is exactly `%{tenant: text, principal: text, run_id: text}`, with the existing Engine text bounds, and must equal its trusted configured values. It is host-vouched scope, not authentication. Reject malformed or mismatched scope before any Run-owner or Store read. `limits` is exactly `%{max_records: n, max_bytes: n}`; each is a positive integer, with maxima 65,536 records and 536,870,912 canonical-record bytes. Reject extra keys and invalid values before reading.

Add optional start configuration `result_reader: %{evidence_store: store, retention_count: positive_integer}` with exactly those keys. A malformed configured value returns `{:stop, :invalid_options_or_recovery}` from `RunEngine.init/1` before `DynamicUnits.start/2` creates a Unit. Preserve existing callers without the option; their result call returns `{:error, :reader_unconfigured}`. The host must supply the actual completion-evidence Store and a retention count matching its Unit directory; store identity, retention agreement, page-size enforcement, truthful committed-head/capability reports and backend fairness are host/provider Needs, not declarations the API can verify. Do not change persisted records, recovery fingerprints, or execution Needs. Read the evidence stream from the existing configured `evidence.stream`, never from a request or pattern.

Return `{:ok, %{run_id: ..., attempt_id: ..., operation_id: ..., action_id: ..., schema_id: ..., schema_version: ..., payload: ..., evidence_ref: ...}}` only for an authoritative completed Run and its actual completion source. If the Run is nonterminal, return exactly `{:pending, :not_completed}`; this includes paused and ASK Runs. For terminal `:failed`, `:cancelled`, `:out_of_budget` or `:out_of_time`, return `{:terminal, outcome}`. Neither refusal includes payload or evidence data.

Bounded errors are `:scope`, `:invalid_limits`, `:reader_unconfigured`, `:read_limit`, `:unavailable`, `:history` and `:completion_mismatch`. Read failures, unavailable sources and provider exceptions fail closed without payload. A legitimate history over either configured budget returns `:read_limit`; never truncate it into success. Keep the existing 16,777,216-byte per-record limit and document the reader budgets separately from Run limits. A timed-out call does not promise to cancel the read.

## Selection and refusal rules

Read `Run.status` and its authoritative `completion_revision`/`evidence_ref`, plus the configured native Unit journal, using public `Elzoo.DurableLog.read/4`, `validate_row/3`, `canonical_bytes/1` and the reducer from `Elzoo.DurableUnit.fold/1` (with the Engine operator's `@empty` initial state and matching retention). Inspect and validate rows incrementally; `replay/3` is not required if it prevents incremental pair inspection. Do not substitute `Operator.step`, a private checkpoint or a custom reducer for the public fold. Read at most one row per Store page, count canonical bytes, and enforce the selected record/byte budgets before accepting a row. Honor append-visibility capability and committed head. Sample/recheck owner revision and relevant head/low-water; refuse a concurrent change.

Require full history from sequence 1: contiguous committed sequences, valid stream/kind/version/digest, paired input/result IDs, no pending tail, no pruned prefix, and no staged row used as a result. Select the first accepted paired transition that settles the exact source occurrence completed in the same Run/Attempt. Validly recorded wrong-scope/schema inputs and later duplicate/late inputs are not candidates and must not displace or invalidate that earlier accepted payload. For nested work, use the accepted parent outcome carrying the first admitted child finish, not arbitrary child content. The final completion source, settled slot and authoritative evidence record must agree on Run, Attempt, operation and action; the evidence stream/sequence must equal the Run owner's reference. Missing or changed IDs/schema/evidence for the selected occurrence, corrupt/gapped/version-invalid history, or unpaired evidence fail closed without payload.

This API is strictly read-only: it must not invoke pattern, gate, schema or clock callbacks; start/restart a Unit; drain; append, acknowledge, repair or checkpoint; dispatch work; or alter control. Preserve the existing payload-free status API. Repeated reads are equal and leave records, outbox, work and control unchanged.

## Acceptance scenarios

- Real local-work and nested-completion Runs return the exact retained payload, schema/version, Run/Attempt/operation/action and authoritative evidence reference.
- Pending, paused and ASK Runs return exactly `{:pending, :not_completed}` without payload. Each existing noncompleted terminal outcome discloses no payload. A mismatched API scope performs no owner/Store read. Missing reader, malformed limits, exact/over-budget histories, unknown/read outage and mismatched completion evidence are covered.
- Include a history with an earlier accepted payload followed by valid wrong-scope/schema, duplicate and late inputs; return the earlier payload. Separately refuse pruned, gapped, corrupt, version-invalid, staged, unpaired-tail and wrong-stream/digest history without returning any payload.
- Use disposable PostgreSQL for durable-owner evidence and Memory where appropriate. Negative controls that bypass API-scope enforcement or select a later duplicate/late result must fail at the intended assertion and be restored byte-for-byte. Include restart and repeated-read checks with unchanged history/outbox/work counts. Report only these finite observations; do not claim general recovery or Wave 4 completion.

## Gate

Run the `assembly/run-engine` Piece tests and the small Piece gate, including dependent Piece tests selected by the gate. Require one independent review, exact-head hosted checks and the merge queue. No full-consumer or Wave 4 completion claim is implied.
