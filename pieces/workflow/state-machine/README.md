# workflow/state-machine

Job-Run lifecycle decision `Elzoo.JobRun` (Cure `:"Cure.Elzoo.JobRun"` plus a validating Elixir projection): a total `step/4` over phase, attempt-identity input, supplied expiry and the unchanged ELZ-006 `RetryDecision`. Subset only: no statecharts, gen_statem framework, process manager, saga or compensation.

## Copy and providers

Select `workflow/state-machine` with `mix elzoo.take`; the dependency-closed copy is
owned by the consuming application, without Elzoo.Application. See
[consuming](../../../docs/consuming.md). Piece dependencies: `delivery/retry-timeout`.
Providers: `cure`, `elixir`, `otp`; exact versions, source lists and claim-level
grounding are in [piece.json](piece.json). Cure is a build-time compiler; the
compiled decision runs without Cure.Compiler.

## Interface

- `start_input(bound_job, job, recorded_oban_attempt, job_attempt)` →
  `{:ok, :start | :duplicate_start | :stale_start}`: a start is `:start` only
  when the Run is unbound or the job is the bound job **and** `job_attempt >=`
  the Oban attempt recorded by the latest `attempt_started`.
- `result_input(completed?, attempt, last_attempt)` →
  `{:ok, :current_completed | :current_failed | :stale_completed | :stale_failed}`.
- `step(phase, input, expired?, retry)` → `{:ok, {phase, action}}`; inputs are
  validated (`:invalid_phase`, `:invalid_input`, `:invalid_expired`, `:invalid_retry`).
- `retry_decision(policy, attempts_made, :retryable | :permanent)` delegates to
  `Elzoo.RetryTimeout.decide/3`.

## Boundary and limits

- Selected laws L1–L29 are table-level facts about `step/4`, proved by reduction over supplied inputs: terminal phases absorb every input; stale results and stale or duplicate starts never change the phase or begin; cancel wins from every non-terminal phase; an expired start never begins; exhausted never begins; a late success expires; a permanent failure is not retried.
- Identity classification uses integer comparisons and is test-grounded; deadline, budget, folds, CAS and providers are outside the laws.
- Six negative controls (a false law and five production mutations) must fail compilation.

## Evidence and operations

- `test/elzoo/job_run_test.exs`: law audit, six negative controls, an exhaustive 640-row comparison of `step/4` with an independent reference table, identity classification and validation.

- telemetry: **not_applicable** — Pure decision; no execution to observe.
- config: **not_applicable** — No settings; decisions are supplied data.
- control: **not_applicable** — No process or lifecycle.

See [ELZ-010](../../../docs/work/ELZ-010.md) for the decision table and the
evidence boundary. Proofs, finite tests and upstream contracts are distinct.
