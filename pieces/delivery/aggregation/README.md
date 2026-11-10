# delivery/aggregation

Bounded correlated join over declared branch delivery results. One join
declares the expected branch identities; each `core/envelope` DeliveryResult is
attributed to exactly one declared branch through a configured field path —
never by arrival order or position — and the pure `decision/2` transition
reports `pending`, `all`, `partial`, `failed` or `expired`.

## Use and Contract

```elixir
{:ok, join} =
  Elzoo.Aggregation.new(["charge", "receipt"],
    branch_key: {:field, ["correlation_id"]},
    deadline_unix_ms: 30_000,
    max_result_bytes: 16_384,
    max_branches: 8,
    now: fn -> System.os_time(:millisecond) end
  )

{:ok, join} = Elzoo.Aggregation.accept(join, result_map)
{:ok, %{ "charge" => %{status: :fulfilled}, "receipt" => %{status: :pending} }} =
  Elzoo.Aggregation.status(join)

{join, %{decision: :pending, branches: _}} = Elzoo.Aggregation.decision(join, now_ms)
```

`new(declared, config)` requires a nonempty proper list of unique identities
bounded by `max_branches`; duplicates, oversized or malformed declarations
return `{:error, :invalid_declaration}`. `config` is a keyword list:

- `:branch_key` — required `{:field, path}`. `path` is exactly
  `["correlation_id"]` or `["attempt_id"]`, or `["value", key, ...]`
  descending string map keys inside the result's `value`. Identity is read
  from the validated result, never positionally.
- `:deadline_unix_ms` — optional nonnegative integer or `:unbounded`
  (default `:unbounded`).
- `:max_result_bytes` — required positive integer bound on the encoded
  incoming result term (`:erlang.term_to_binary/1`).
- `:max_branches` — required positive integer cap on `declared`.
- `:now` — optional 0-arity clock port returning unix milliseconds
  (default `System.os_time(:millisecond)`). No environment reads.

`accept(join, result)` validates through `Elzoo.Envelope.validate_result/1`.
Malformed input is `{:error, :invalid_result}` and never partially merges.
A missing configured carrier is `{:error, :invalid_branch_key}`, an
undeclared identity `{:error, :unknown_branch}`, an encoded result over the
bound `{:error, :too_large}` — all without mutation. A non-integer clock
reading is `{:error, :invalid_clock}`.

`mark_lost(join, branch_id, kind)` records a first-class loss
(`:timed_out`, `:killed`, `:unavailable`) — not a synthetic Envelope result.
Other kinds are `{:error, :invalid_loss_kind}`. Because losses carry no
payload, they are not held to the deadline: a loss recorded at or after
`deadline_unix_ms` still settles an unsettled branch, while after closure
they are recorded `late` like results.

Branch records carry `status`, retained redacted result metadata
(`outcome`, `dispatch`, `error_class`, `value_schema_id`,
`value_schema_version`, `value_digest`), `loss` kind, `duplicate_count`,
`conflicted`, `late_count`, `first_seen_unix_ms` and `decided_unix_ms`.
`status/1` and `decision/2` expose the same records minus the internal
`value_digest`. Accepted results are stored **redacted**: the payload is
replaced by a SHA-256 digest used only for duplicate comparison, so join
state, `inspect` output and caller persistence never hold branch data.

## Transition rules

- First accepted input settles a branch: `completed`→`fulfilled`,
  `rejected`/`failed`→`failed`, `timed_out`→`timed_out`,
  `unknown`→`unavailable`. Loss kinds map to their own statuses.
- A result at or after `deadline_unix_ms`, or any input after the join
  closes, is recorded `late` immediately inside `accept/2` — never an error,
  never merged. `:pending` branches that see only late input become `:late`.
- Later on-time inputs for a settled branch are `duplicate` records
  (`duplicate_count`); the first accepted result stands. A differing
  outcome/value digest marks the branch `conflicted` (sticky, terminal
  non-fulfilled); consistent duplicates — including a result agreeing with
  a recorded loss kind — only increment the count.
- `decision(join, now)` is pure over the caller-read `now`:
  `:pending` while any branch is unsettled before the deadline;
  `:expired` at or after the deadline with branches still unsettled —
  `:pending` branches become `:missing` (no evidence ever arrived) and
  `:late` branches `:timed_out`, then the join closes; `:all` when every
  branch is `fulfilled`; `:partial` with at least one `fulfilled` and one
  terminal non-fulfilled; `:failed` with no `fulfilled` and at least one
  terminal. A closed join returns its stored outcome; `:pending` is never
  stored. The decision depends on branch identity and status, never on
  arrival order.
- Undeclared identities are refused rather than stored, keeping state
  bounded by the declared set; per-branch size is bounded by
  `max_result_bytes`.

The join state is a plain map (the `now` port is a function value inside
it) the caller may persist through any term-capable store and hand to
`status/1`, `decision/2`, `accept/2` and `mark_lost/3` after reload.

## Volatile runner

`Elzoo.Aggregation.Runner` fans out declared `{branch_id, fun}` pairs under
an injected `Task.Supervisor` for callers without durable branches:

```elixir
{:ok, sup} = Task.Supervisor.start_link(name: MyBranches)
{:ok, runner} =
  Elzoo.Aggregation.Runner.start_link(
    join: join,
    branches: [{"charge", &charge/1}, {"receipt", &receipt/1}],
    task_supervisor: sup
  )

{_join, %{decision: :all}} =
  Elzoo.Aggregation.Runner.decision(runner, System.os_time(:millisecond))
```

Each fun is a 1-arity function of its branch id returning an Envelope
result map; pairs run once with `:brutal_kill` shutdown and no retries.
Branch ids must be binaries present in the join declaration — duplicates,
undeclared ids, non-binary ids, non-functions, empty declarations, missing
supervisors and invalid join states are refused with
`{:error, :invalid_options}`. The join's `branch_key` must carry identity in
`correlation_id` or `attempt_id`: runner-synthesized failure results need a
carrier a failed branch can still mint, so a `value`-rooted key is refused.

Runner outcomes feed the same join policy: a returned result goes through
`accept/2`; a raising or exiting task becomes a synthetic
`failed`/`dispatched`/`unclassified` result; a result the join refuses as
`:invalid_result` becomes the same synthetic failure, while
`:invalid_branch_key` and `:too_large` become `mark_lost(:unavailable)` —
the branch was dispatched but its evidence could not be joined. At the join
deadline the runner records `mark_lost(:timed_out)` for every branch still
unsettled and kills the survivors; their late messages are recorded by the
join, never merged. `status/1`, `join/1`, `decision/2` and `snapshot/1`
expose the live join and volatile counters. The runner keeps no queue,
starts no process of its own and holds no durable state; durable branches
remain owned by `workflow/run`.

## Dependencies and standalone copying

Pieces: `core/envelope` (result validation), `delivery/time` (clock/deadline
vocabulary the caller wires). Providers: pinned Cure (via `core/envelope`),
Elixir/OTP. Copy this source bundle with its dependencies using
[the consumption instructions](../../../docs/consuming.md). Isolated consumer
tests compile and run without `Elzoo.Application`; the runner needs only a
caller-supplied `Task.Supervisor`. No new Hex dependency.

## Grounding and limits

- **Type/contract check:** `core/envelope`'s pinned Cure `validate_result`
  is the actual schema gate for every accepted result; branch-key paths,
  bounds and deadline values are validated at construction.
- **No `cure/` source:** the join state is a plain-map Elixir structure
  carrying an injected clock fun — not a Cure record — and the candidate
  laws (identity determinism, at-most-once-per-branch) quantify over that
  state and clock. Forcing a Cure representation would conflict with the
  plain-map persistence Contract, so the transition evidence is the
  exhaustive ExUnit scenario set below rather than a proof.
- **Tests:** named ExUnit scenarios cover construction refusal, every
  outcome mapping, all three identity carriers, refusal without mutation,
  oversize bounds, late/expired/closed transitions, duplicate/conflict and
  loss records, arrival-order independence, state round-trip, payload
  non-retention, corrupt-state refusal, and runner success/exception/
  invalid-return/deadline-kill/single-run/refusal scenarios over real
  `Task`s. These are executable scenarios, not universal proofs.
- **Upstream:** Cure 208248063d64e621782cd26dd30698ee42850a89 compiler/kernel
  (through `core/envelope`), Elixir 1.20.4, OTP 29.1.2 `Task.Supervisor`,
  `:crypto` SHA-256. No compiler soundness proof is claimed.
- **Limits:** volatile only — no durable join state, exactly-once branch
  execution, ordering across branches, workflow timers, saga semantics,
  branch retry policy, provider adoption, Reactor, ordered/streaming join,
  payload aggregation/map-reduce or cross-join queries. A timeout records
  evidence unreadable/lost; it never proves an external branch did not
  run. `:missing` means no evidence ever arrived for that branch — distinct
  from a recorded `:unavailable`/zero. Runner branch keys must be
  `correlation_id`/`attempt_id`-rooted. Telemetry is `planned`: only
  bounded decision/outcome events without payloads could ever be added.

## Operational applicability

- Telemetry: `planned`; no events supplied. `snapshot/1` is test-observed
  inspection, not monitoring; any future events carry branch ids, statuses
  and counts only — never payloads.
- Config: `supported`; construction-time `branch_key`, `deadline_unix_ms`,
  `max_result_bytes`, `max_branches` and `now` validated by `new/2` and
  fixed in state; no ambient configuration or hot reconfiguration.
- Control: `not_applicable`; no lifecycle to pause, drain or resume. OTP
  stop of the runner is not business cancellation.

Apache-2.0 covers this copied source; upstream packages retain their licenses.
Evidence concerns these recorded bytes and named claims, not downstream edits.
