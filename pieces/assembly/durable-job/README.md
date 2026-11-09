# assembly/durable-job

Durable tally job flow over the ELZ-009 Store and Oban 2.24.2: `Elzoo.DurableJob.submit/5`, `cancel/3`, `status/2`, an ELZ-010-owned Submitter per queue, the Relay and the worker shell. One exemplar of durable attempts over a pure computation; not a workflow engine.

## Copy and providers

Select `assembly/durable-job` with `mix elzoo.take`; the dependency-closed copy is
owned by the consuming application, without Elzoo.Application. See
[consuming](../../../docs/consuming.md). Piece dependencies: `workflow/state-machine`,
`integration/jobs`, `state/event-log`, `state/outbox`, `integration/sql`, `delivery/retry-timeout`.
Providers: `oban`, `jason`, `ecto_sql`, `postgrex`, `elixir`, `otp`; exact versions are in
[piece.json](piece.json). Configure the Store with `Elzoo.DurableJob.Run.store_fold/0` and
`Run.limits/0`; start `{Elzoo.DurableJob, queue: ..., store: ..., repo: ..., oban: ...}` under
your supervisor and add the queue to your Oban config.

## Flow

`submit` (guarded) → Submitter appends `requested` + a `jobs` outbox item on
`jobs/<queue>` → Relay writes `accepted` on `job/<queue>/<job_key>` and inserts the
unique Oban job → each execution classifies its start (`start_input/4`), records
`attempt_started{n, oban_job_id, oban_attempt}`, runs the pure handler once and
records `succeeded` / `attempt_failed` / `failed` / `exhausted` / `expired` by CAS.
Stale results and stale starts snooze; a duplicate job yields `{:cancel, :duplicate_job}`.
`cancel` also works before the relay ran (it writes `cancelled` as the first Run
record and the relay acks it without a job).

## Boundary and limits

- **Schema evolution is deferred.** Only `schema_version` 1 exists. Any other record version is refused as damaged (`{:cancel, :damaged}`, `status/2` → `{:error, :damaged}`) and any other job-args version is refused with `{:cancel, :unsupported_version}`; nothing is upcast. `state/schema-evolution` stays planned. The first format change must meet ELZ-010's R6/R9 requirements in full under a new task (golden corpora written by each version, pinned bytes, mix check failing on missing/changed/unpinned corpora, a frozen older reader, `unwritable_version`), and changed accepted inputs follow the Piece-ID evolution rule. Mixed-version rolling deploys are unsupported.
- No exactly-once execution: a Lifeline rescue can run a live attempt concurrently; its results are fenced by the Store CAS and attempt identity, and the rescue consumes Run budget (a Run can reach `exhausted` without a failed attempt).
- A stalled Run (non-terminal, provider job terminal or gone) is reported by `status/2` (`stalled: true`), never repaired; its deadline is not recorded. Deadlines use the worker node's clock and are evaluated only when a worker runs.
- Writer calls are bounded by `writer_timeout_ms` (default 35_000 = the PostgreSQL Store's 30_000 ms write timeout + 5_000 margin). A call that exits is a snooze in the worker and `{:indeterminate, info}` from `submit`/`cancel`; a write blocked longer than Lifeline's `rescue_after` gets the live execution rescued (one Oban attempt each), so repeated blocked writes can discard the job and stall the Run.
- One Run per Work Item. Submits per queue serialize through one Submitter and one CAS row; Submitter memory grows with distinct keys; streams are not retained.
- Entry points refuse with `{:error, :caller_transaction}` before any I/O only for the **configured Repo**; Store use inside a caller transaction is ELZ-032 ([#52](https://github.com/balungpisah/elzoo/issues/52)).
- The handler must be pure and deterministic (assumption); no external Effect is dispatched. An effectful step needs ELZ-023 `delivery/effect-intent` (not adopted).
- After a cancel/3 start or result timeout, a late internal reply message can remain unread in the caller's mailbox (at most two per timed-out call); the caller should tolerate unmatched messages.
- While an Assembly is stopped, Oban jobs for its queue keep snoozing without charging attempts and without recording a deadline; nothing bounds that snooze loop until the Assembly starts again.

## Evidence and operations

- `test/elzoo/durable_job_test.exs`: listed scenarios DJ1–DJ8, DJ10–DJ17, DJ19–DJ22 and DJ12b on Memory and a disposable PostgreSQL with Oban 2.24.2.
- `test/elzoo/durable_job_restart_test.exs`: DJ9, SIGKILL of a separate OS process mid-attempt and Lifeline resume at attempt 2.

- telemetry: **supported** — the `runtime/telemetry` `:job` events at the worker (`operation: :perform`) and the Relay (`operation: :relay`); see Telemetry below. Oban also emits its own job events.
- config: **supported** — Start-time queue, Store, Repo, Oban, handler, clock, slack, snooze, relay limit/interval; per-submit budget, backoff and absolute deadline fixed for the Run; no hot change.
- control: **supported** — `cancel/3` and read-only `status/2`; Submitter and Relay have OTP start/stop only (one_for_one); stop/kill releases the queue registration; no pause/drain.

`cancel/3` results (complete): `{:ok, :cancelled}`, `{:error, {:terminal, phase}}`,
`{:error, :not_found}`, `{:error, {:invalid, :requested_by}}` (UTF-8 binary of
1..200 bytes without NUL required), `{:error, :not_started}` (no live Assembly
registration for the queue), `{:error, :caller_transaction}`, `{:error, :damaged}`,
`{:error, :unavailable}` (nothing was sent, including an absent Task.Supervisor),
`{:error, :contended}`, `{:error, {:rejected, reason}}`, `{:indeterminate, info}`
(a write may have been sent, including a Writer call exit or timeout, a task start
exit other than `:noproc` or the 5 s start timeout).

Lifecycle: `Elzoo.DurableJob.Registration` (first child) owns the queue's
registration and erases it when it terminates; entry points and the worker
also require its pid to be alive. After a stop or a kill the entry points
return `{:error, :not_started}` and pending jobs snooze without running a
handler; starting the same queue again re-registers.

## Telemetry (ELZ-052)

Evolution note: observation added through `runtime/telemetry` (ELZ-052,
[#108](https://github.com/balungpisah/elzoo/issues/108)); inputs, outputs,
state, delivery and failure guarantees are unchanged; **no Contract change**,
so the Piece ID is kept. Reason: operators need consistent observations of job
execution without reading code. The added Need is the `telemetry` library
(1.4.2), already loaded by Oban.

- `[:elzoo, :job, :start | :stop | :exception]` with `operation: :perform`
  around `Elzoo.DurableJob.perform/2` (worker execution) and
  `operation: :relay` around `Elzoo.DurableJob.relay/2` (one Relay item).
  Keys and units: `pieces/runtime/telemetry/README.md`. `request_ref` is the
  SHA-256 hex of the `job_key`; the key, input and results are never emitted.
- No emission sits inside the Writer timeout or any other Adapter timer; a
  raise or throw inside an execution emits `:exception` and is re-raised
  unchanged.
- Limit: a handler's run time is elapsed time; a handler slower than the remaining deadline makes the operation expire exactly as any other delay would.
  The worker `:start` event precedes the Run deadline readings; a handler
  slower than Lifeline's `rescue_after` lets Oban rescue the live execution, as
  any other slow execution would.
- Handlers must be fast and non-blocking: offload export or any slow work to
  another process. A handler that fails is detached by `telemetry` and does
  not change a result.

See [ELZ-010](../../../docs/work/ELZ-010.md) for the Contract, result tables, scenarios and limits.
