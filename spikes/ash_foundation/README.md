# Ash foundation proof-of-fit

ELZ-016 also exercises [operational contracts](../../docs/operational-contracts.md)
through `Operations`, a pure `Admission` policy and a volatile GenServer host.
`test/operations_test.exs` checks revision conflicts, limit changes with active
work, pause/drain/resume, direct/tool authority, tenant routing and telemetry
redaction/observer failure. These tests do not turn the experiment into a ready
admission Piece. `:telemetry` 1.4.2 is an explicit upstream dependency for this
experiment; it is unrelated to Gleam or a frontend choice.

ELZ-015 evaluates the upstream Ash application action model; it is not a ready
source bundle and cannot be installed with `mix elzoo.take`. This directory is
a separate Mix project so no Ash dependency is imposed on existing Pieces.
The original code here is Apache-2.0. Dependencies retain their own licenses.

## Run

From the Elzoo root on Elixir 1.20.4 / OTP 29.1.2:

```sh
mix setup
mix check
```

For targeted iteration from this directory:

```sh
mix deps.get
mix format --check-formatted
mix test --warnings-as-errors
```

The lockfile records transitive versions/checksums. Direct upstream pins are
Ash 3.37.3, AshAi 1.5.0, AshStateMachine 0.3.0 and SimpleSat 0.1.4. SimpleSat
is the supported pure-Elixir SAT solver used by Ash policies; it avoids a
native build dependency in this small experiment. No solver-performance or
upstream theorem-proving claim follows from choosing it.

## Contract under evaluation

`WorkItem` records work intent with a title, tenant and pending/completed state.
It is not a Run or Attempt record. A trusted host supplies an actor with a
tenant identity and role. Authenticated tenant members may create/read their
own tenant's items; only its workers may complete pending items. The action
accepts no client-controlled state or tenant attribute. A tenant option is
selection context, not authority: resource policy independently checks the
actor's tenant. Blank titles and repeated completion of a freshly read
completed item fail. A separate authenticated-user/membership system would
have to establish those actor facts in a real application.

The domain explicitly exposes create/read/complete as AshAi tools. Tool calls
use `AshAi.Tools.execute/4` with trusted host context; model arguments never
populate the actor or tenant context. Direct and tool calls reach the same
resource action, policy and state-machine definitions. One test invokes the
tool through `Task.Supervisor` with explicit context to exercise process
placement. No LLM API call, secret, authentication server or MCP server is used.

## Evidence and limits

`test/work_test.exs` contains executable scenarios for valid direct/tool
execution, denied calls, tenant filtering, invalid inputs/transitions and
supervised background invocation. These are tests of this declared boundary,
not proofs of Ash or all possible access-control configurations. Current
execution results are recorded in `docs/work/ELZ-015.md` at the repository root.

- ETS is volatile and has no transactions. Sequential transition checks do
  not protect against stale records or simultaneous updates; production use
  needs a transactional data layer and concurrency tests. No exactly-once
  execution or idempotent billing claim is made.
- Task.Supervisor runs volatile work; it does not persist jobs, retries or
  results. Application restart loses this experiment's state.
- Host Elixir code is trusted and can bypass framework authorization. This
  is a boundary for untrusted arguments, not a sandbox against code in the VM.
- AshAi brings AshJsonApi, Phoenix and other transitive dependencies even for
  local tool execution. The source bundle dependency cost is therefore real;
  these are not dependencies of every Elzoo consumer.
- Some upstream packages emit compiler warnings on the pinned Elixir/OTP.
  Owned modules use warnings-as-errors; this does not certify dependency
  sources as warning-free. No fork or warning suppression is introduced.
- AshPostgres, AshOban, Reactor execution, money/accounting, Cedar and live
  model routing are not exercised. A new Cure decision/bridge is not needed
  for this narrow experiment and is not claimed as tested.

## Reuse observations

The spike declares two modules rather than writing an authorization evaluator,
resource store, transition engine or tool dispatcher. This is qualitative
evidence of reusable machinery; no equivalent hand-built baseline or timing
benchmark establishes a numerical productivity gain. The development cost
also includes the DSL, host identity context, configuration and dependency
graph. Foundation adoption remains conditional on durable-boundary tests.

Versioned upstream references:

- [Ash resource/actions](https://hexdocs.pm/ash/3.37.3/what-is-ash.html)
- [Ash authorization](https://hexdocs.pm/ash/3.37.3/policies.html)
- [ETS storage limits](https://hexdocs.pm/ash/3.37.3/Ash.DataLayer.Ets.html)
- [AshAi tools](https://hexdocs.pm/ash_ai/1.5.0/AshAi.Tools.html)
- [State transitions and stale records](https://hexdocs.pm/ash_state_machine/0.3.0/getting-started-with-ash-state-machine.html)

See [ADR-0005](../../docs/adr/0005-ash-foundation-and-upstream-first.md) and
the [upstream/fork policy](../../docs/development/08-upstream-and-forks.md).
