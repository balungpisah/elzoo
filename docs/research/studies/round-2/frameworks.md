# Elzoo study: general agent frameworks (lux, sigil, shifts, staff_ai)

Unit: General agent frameworks. Read-only study against balungpisah/elzoo at
`bf16422dbc741de5c3ff3d86f3af9b14d7eb19ef` (main, 2026-11-06). Nothing was
executed, vendored or added as a dependency. Package observations are dated
2026-11-06 unless stated; Hex release dates come from the Hex package API.
Compared capabilities: `integration/ai-model`, `integration/agent-runner`,
`workflow/context-selection`, `core/envelope` typed signals, and the rule in
docs/capability-model.md that agent orchestration is an Assembly, not a
privileged kernel. Citations use `path:lines` at the pinned revision; where a
Hex tarball is the only reproducible source, the path is prefixed `hex:`.

## Summary table

| Package | Pinned revision | License | Last commit | Verdict | One line |
| --- | --- | --- | --- | --- | --- |
| lux 0.5.0 (Hex 2025-03-04) | Hex tarball is the source of record; no commit of Spectral-Finance/lux reproduces its `lib/` tree. Nearest: `37f05ab3b1153999a81ac002f0e284973601c567` (2025-02-27; differs only in `lib/lux/agent.ex` and `lib/lux/agent/companies/signal_handler/default_implementation.ex`, plus `lib/lux/reflection.ex` absent from the tarball). Tarball also leaks `Users/rparcus/spectrallabs/lux/README.md`. | MIT (Boltzmann Ltd, LICENSE in tarball) | repo HEAD `55e2049d` 2025-05-14; no Hex release after 0.5.0 | distill | Stale, heavy (9 mandatory deps incl. Python/Node bridges, web3, exchange prisms); its retry, parallel-join and tool-dispatch paths are useful negative design tests. |
| sigil 0.1.4 (Hex 2026-03-29) | `fa3513fdc185f1f289167db141405dd1ef67de8f` (sigilframework/sigil, `lib/` tree identical to tarball) | MIT (Adam Bouchard, 2026) | repo HEAD `9eff616b` 2026-04-04; first release 2026-03-28, 52 commits, one author | distill | Not stale but one week old at pin, single-author, web+auth+agent in one OTP app with Ecto/Postgres for durability; its context budget and checkpoint/replay design are worth distilling, mostly as what not to promise. |
| shifts 0.0.2 (Hex 2024-04-18) | Hex tarball is the only source for 0.0.2: lebrunel/shifts history starts 2024-05-16 (`c607323d`), after the release, and HEAD `44b750f3` has `lib/shifts/job*` where the tarball has `lib/shifts/shift*` (17 differing files) | Apache-2.0 (LICENSE in tarball) | `44b750f38ae383f535fd5a92a2f956390a322066` 2024-06-21; 13 commits | skip | 1.2 kLOC with `@moduledoc "TODO"` throughout; one small idea (named-operation result correlation) is folded into `delivery/aggregation` below. |
| staff_ai 0.0.4 (Hex 2024-03-16) | tag `v0.0.4` = `b549de4aff67f90fd73a4b75d18d9bf9e2f695fb` (chainyo/staff-ai; `src/staff_ai.gleam` sha256 identical to tarball) | **Conflict:** gleam.toml declares Apache-2.0, no LICENSE text in tarball or repo, and the source header says "All rights reserved" (`src/staff_ai.gleam:16`) | `7af0e829` 2024-03-21; 13 commits | skip | 163 lines of Gleam record constructors (Task/Agent/Squad), no behaviour; it is the "universal Task record" the capability model already warns against. |

Adoption verdict for the unit: no package is an adoption candidate for any
deferred/planned handle. Lux and shifts have had no release since 2025-03-04
and 2024-04-18 respectively; staff_ai since 2024-03-16; sigil is a 0.1.x
first release. None matches the Cure/Elixir boundary (pure decision in Cure,
runtime in OTP, Effects in Adapters): each couples the model call, tool
execution and loop state inside one GenServer or recursive function.

## lux 0.5.0

### Observations (dated 2026-11-06, Hex tarball unless `lib/` path given at `37f05ab`)

Declared mandatory dependencies (metadata.config): bandit, req, venomous
(Python bridge), crontab, ex_json_schema, nodejs, ethers, ex_secp256k1,
yaml_elixir; Elixir `~> 1.18`. The package ships exchange and chain prisms
(`lib/lux/prisms/hyperliquid/*`, `lib/lux/web3/*`).

1. Typed signals. `Lux.Signal` is a struct with free-text `sender`/`recipient`,
   an open `metadata` map and `schema_id` as a module
   ([signal.ex:7-23](https://github.com/Spectral-Finance/lux/blob/37f05ab3b1153999a81ac002f0e284973601c567/lib/lux/signal.ex#L7-L23)).
   `use Lux.Signal, schema_id:` validates the payload with ex_json_schema at
   construction ([signal.ex:39-52](https://github.com/Spectral-Finance/lux/blob/37f05ab3b1153999a81ac002f0e284973601c567/lib/lux/signal.ex#L39-L52),
   [signal_schema.ex:138-143](https://github.com/Spectral-Finance/lux/blob/37f05ab3b1153999a81ac002f0e284973601c567/lib/lux/signal_schema.ex#L138-L143)),
   but `Lux.Signal.validate/2` returns `:ok` unconditionally
   ([signal.ex:77-79](https://github.com/Spectral-Finance/lux/blob/37f05ab3b1153999a81ac002f0e284973601c567/lib/lux/signal.ex#L77-L79)).
   The schema's `id` is `UUID.generate()` evaluated at compile time
   ([signal_schema.ex:87-96](https://github.com/Spectral-Finance/lux/blob/37f05ab3b1153999a81ac002f0e284973601c567/lib/lux/signal_schema.ex#L87-L96)),
   so schema identity changes per build. `compatibility: :full | :backward |
   :forward | :none` and `status` are declared fields
   ([signal_schema.ex:14-16](https://github.com/Spectral-Finance/lux/blob/37f05ab3b1153999a81ac002f0e284973601c567/lib/lux/signal_schema.ex#L14-L16))
   that nothing in the package reads.
2. Handler dispatch by schema. An agent finds a handler by `schema_id` and
   executes it: prism, beam, lens, `{module, function}` or `{:python, code}`
   (`hex:lib/lux/agent.ex:148-181`). The match is the only check.
3. Beam step retry and parallel join. `execute_step` wraps the handler in
   `try/rescue`; any `{:error, _}` or exception goes to `handle_step_error`,
   which sleeps `retry_backoff` and re-invokes the same handler while
   `retries > 0`, with no error class, attempt identity or dispatch state
   ([beam/runner.ex:123-193](https://github.com/Spectral-Finance/lux/blob/37f05ab3b1153999a81ac002f0e284973601c567/lib/lux/beam/runner.ex#L123-L193)).
   Parallel steps run under `Task.async_stream(..., on_timeout: :kill_task)`
   and a killed branch is dropped from the accumulated contexts
   (`{:exit, _}, acc -> {:cont, acc}`,
   [beam/runner.ex:50-71](https://github.com/Spectral-Finance/lux/blob/37f05ab3b1153999a81ac002f0e284973601c567/lib/lux/beam/runner.ex#L50-L71)).
4. Tool execution inside the provider adapter. The OpenAI adapter executes
   tool calls named by the model before returning
   ([llm/open_ai.ex:228-234](https://github.com/Spectral-Finance/lux/blob/37f05ab3b1153999a81ac002f0e284973601c567/lib/lux/llm/open_ai.ex#L228-L234)):
   the model-supplied tool name is turned into a module with
   `String.replace("_", ".") |> Module.concat() |> Code.ensure_loaded()` and
   its `handler/2` is called with `ctx = nil`
   ([llm/open_ai.ex:291-319](https://github.com/Spectral-Finance/lux/blob/37f05ab3b1153999a81ac002f0e284973601c567/lib/lux/llm/open_ai.ex#L291-L319)).
5. Scheduled actions. `__handle_info__({:run_scheduled_action, ...})` starts
   the action under `Task.Supervisor.async_nolink` with a timeout, re-arms the
   interval immediately and discards the task result and `:DOWN`
   (`hex:lib/lux/agent.ex:396-445`). Overlap of a slow action with the next
   interval has no policy.
6. Company task tracker. In-memory GenServer with
   `:pending | :assigned | :in_progress | :completed | :failed` and transition
   validation ([task_tracker.ex:18, 150-255](https://github.com/Spectral-Finance/lux/blob/37f05ab3b1153999a81ac002f0e284973601c567/lib/lux/company/execution_engine/task_tracker.ex#L150-L255)).
   `complete_task/3` takes no agent or attempt identity
   ([task_tracker.ex:185-200](https://github.com/Spectral-Finance/lux/blob/37f05ab3b1153999a81ac002f0e284973601c567/lib/lux/company/execution_engine/task_tracker.ex#L185-L200)),
   so any caller can complete another worker's task. `AgentHub` status is
   self-reported `:available | :busy | :offline`
   ([agent_hub.ex:24, 90](https://github.com/Spectral-Finance/lux/blob/37f05ab3b1153999a81ac002f0e284973601c567/lib/lux/agent_hub.ex#L24)).
7. Memory as context. `build_llm_config` prepends the N most recent memory
   entries to the message list with no access recheck or provenance
   (`hex:lib/lux/agent.ex:316-335`).

### Overlap check

| Mechanism | Elzoo handle / task | Already covered? | Upstream reuse? | Gap it exposes |
| --- | --- | --- | --- | --- |
| 1 typed signals | `core/envelope` (ready), `integration/json` | Yes: envelope requires exact string keys, nonempty `schema_id` text + positive `schema_version`, no metadata bag, opaque payload with a separate codec (pieces/core/envelope/README.md "Envelope Contract") | No: struct-plus-JSON-Schema is a product codec; ex_json_schema would be a new dependency | A declared compatibility level without a checker |
| 2 dispatch by schema | `delivery/routing` (ready), ELZ-024 `domain/authorization` | Envelope README: "Kind is only a tag, not permission to execute control commands"; C6: "Tool discovery never itself authorizes execution" | No | Routing match treated as execution authority |
| 3 retry / join | ELZ-006 `delivery/retry-timeout`, ELZ-023 `delivery/effect-intent`, `delivery/aggregation` (planned) | Envelope README: "even `retryable` never authorizes blind retries of an unknown external outcome"; ELZ-023 invariant | No | Join completeness: a timed-out branch silently vanishes |
| 4 tool execution in adapter | `integration/ai-model` (deferred), ELZ-011 Adapter rules | capability-model table "Model provider / agent runner / orchestration" keeps them distinct; Raxol row in orchestration-references.md: "no atom minted from a wire string" | No | No Contract sentence yet says the provider Adapter returns tool calls as data |
| 5 scheduled actions | `delivery/trigger`, `state/scheduler` (deferred/planned) | C7 design test "overlapping schedules follow an explicit skip/queue/replace policy" | No | Concrete failure shape for that test |
| 6 task tracker | `workflow/work-item`, `state/lease` (deferred) | C5: "a worker that lost its lease cannot complete the new owner's attempt" | No | Completion without lease/attempt identity |
| 7 memory as context | `workflow/context-selection` (deferred) | C7: "removed access excludes a document from later context" | No | Negative example only |

### Proposals

- `integration/ai-model` Contract sentence (C6, C7, C9): "The provider
  Adapter translates a response into data: text, structured output and
  tool-call proposals `{name, arguments, provider_call_id}`. It never resolves
  a tool name to code, loads a module, mints an atom from a wire string or
  executes anything. Tool dispatch belongs to the owning Run after
  `domain/authorization`."
  Design test: a response naming an unregistered or unauthorized tool yields a
  rejected proposal visible to the Run; no `Code.ensure_loaded`, no call.
- `delivery/aggregation` design test (C5, C6): "A fan-out join carries exactly
  one delivery result per declared branch. A branch that was killed or timed
  out is recorded as `timed_out`/`unknown` with `dispatch` per the
  `core/envelope` result matrix; omitting a branch from the aggregate is a
  Contract violation." Tie to ELZ-006 timeouts and the envelope result schema.
- ELZ-006 / ELZ-023 dangerous-failure case: "A step retry policy keyed on
  exceptions or `{:error, _}` alone re-sends a possibly dispatched Effect
  (Lux retries an exchange order prism on any error). Retry must consult the
  intent state; `failed/dispatched` does not re-arm."
- ELZ-024 design test (C6): "A route or schema match selects a handler port;
  it never substitutes for the ALLOW/ASK/DENY reduction. A handler reachable
  by schema with no authorization input is a test failure."
- `delivery/trigger` / `state/scheduler` design test (C7): "A recurring
  trigger whose previous occurrence is still running applies the declared
  skip/queue/replace policy and records the decision; silent overlap is not
  admissible. Each occurrence has its own identity preserved across retries."
- `workflow/work-item` + `state/lease` design test (C5): "`complete` names the
  attempt and lease holder; a completion from a non-holder is rejected, not
  recorded." Lux's tracker is the counterexample.

## sigil 0.1.4

### Observations (dated 2026-11-06, at `fa3513fd`)

Mandatory dependencies: req, jason, telemetry. Optional: ecto_sql, postgrex,
pgvector, bandit, websock_adapter, plug, bcrypt_elixir, file_system. Event
store and checkpoints are no-ops without a configured Repo
([event_store.ex:78-84](https://github.com/sigilframework/sigil/blob/fa3513fdc185f1f289167db141405dd1ef67de8f/lib/sigil/agent/event_store.ex#L78-L84),
[checkpoint.ex:56-59](https://github.com/sigilframework/sigil/blob/fa3513fdc185f1f289167db141405dd1ef67de8f/lib/sigil/agent/checkpoint.ex#L56-L59)).

1. Context-window budget. `Sigil.Memory.Budget` reserves tokens per category
   (`:system`, `:tools`, `:response`, history gets the remainder) against a
   model context window with a 2% safety margin
   ([budget.ex:31-66, 99-135](https://github.com/sigilframework/sigil/blob/fa3513fdc185f1f289167db141405dd1ef67de8f/lib/sigil/memory/budget.ex#L31-L66)).
   Window sizes are a hard-coded table with prefix matching
   ([budget.ex:48-62, 163-175](https://github.com/sigilframework/sigil/blob/fa3513fdc185f1f289167db141405dd1ef67de8f/lib/sigil/memory/budget.ex#L163-L175));
   counts are heuristic with per-provider multipliers unless the Anthropic
   count API is called
   ([tokenizer.ex:30-50](https://github.com/sigilframework/sigil/blob/fa3513fdc185f1f289167db141405dd1ef67de8f/lib/sigil/memory/tokenizer.ex#L30-L50)).
   Compaction strategies: sliding window, summarize oldest, progressive,
   drop tool results
   ([context.ex:11-16](https://github.com/sigilframework/sigil/blob/fa3513fdc185f1f289167db141405dd1ef67de8f/lib/sigil/memory/context.ex#L11-L16)).
2. Event log, checkpoint and resume. `EventStore.append/4` is asynchronous and
   batched ("Use `append_sync/4` if you need guaranteed writes",
   [event_store.ex:73-100](https://github.com/sigilframework/sigil/blob/fa3513fdc185f1f289167db141405dd1ef67de8f/lib/sigil/agent/event_store.ex#L73-L100));
   the agent uses the async path for every event and derives `sequence` from an
   in-memory counter ([agent.ex:725-745](https://github.com/sigilframework/sigil/blob/fa3513fdc185f1f289167db141405dd1ef67de8f/lib/sigil/agent/agent.ex#L725-L745)).
   The generated migration indexes `(run_id, sequence)` without uniqueness
   ([priv/templates/sigil.new/priv/repo/migrations/20260328000000_init_schema.exs:83-90](https://github.com/sigilframework/sigil/blob/fa3513fdc185f1f289167db141405dd1ef67de8f/priv/templates/sigil.new/priv/repo/migrations/20260328000000_init_schema.exs#L83-L90)).
   `Checkpoint.save` inserts the snapshot synchronously, then appends a
   `checkpoint_created` event asynchronously at `sequence + 1`
   ([checkpoint.ex:56-90](https://github.com/sigilframework/sigil/blob/fa3513fdc185f1f289167db141405dd1ef67de8f/lib/sigil/agent/checkpoint.ex#L56-L90)).
   `resume/2` loads the latest checkpoint and replays from `sequence + 1`, but
   the refold only rebuilds `user_message` content; `llm_response`,
   `tool_result` and others only advance the counter
   ([agent.ex:162-212](https://github.com/sigilframework/sigil/blob/fa3513fdc185f1f289167db141405dd1ef67de8f/lib/sigil/agent/agent.ex#L162-L212),
   [agent.ex:777-795](https://github.com/sigilframework/sigil/blob/fa3513fdc185f1f289167db141405dd1ef67de8f/lib/sigil/agent/agent.ex#L777-L795)).
3. Run lifecycle. `handle_cast({:stream, ...})` runs the think/act/observe
   loop in an unlinked `Task.start`, sets `status: :running`, and only a
   success message (`:sigil_state_sync`) returns the GenServer to `:ready`;
   the error branch notifies the caller and leaves `:running`
   ([agent.ex:335-360, 383-391](https://github.com/sigilframework/sigil/blob/fa3513fdc185f1f289167db141405dd1ef67de8f/lib/sigil/agent/agent.ex#L335-L360)).
   The loop is bounded by `max_turns` (default 10,
   [agent.ex:403, 542-545](https://github.com/sigilframework/sigil/blob/fa3513fdc185f1f289167db141405dd1ef67de8f/lib/sigil/agent/agent.ex#L542-L545)).
4. Tool permission and timeout. Permission is a static property of the tool
   module (`:auto | :human_approval | :disabled`,
   [tool.ex:49, 91-102](https://github.com/sigilframework/sigil/blob/fa3513fdc185f1f289167db141405dd1ef67de8f/lib/sigil/tool/tool.ex#L91-L102)).
   `:human_approval` returns `{:approval_required, tool, params}`; the agent
   records an `approval_requested` event and feeds the model a tool_result
   string "[Awaiting human approval ...]" and continues the loop
   ([agent.ex:656-678](https://github.com/sigilframework/sigil/blob/fa3513fdc185f1f289167db141405dd1ef67de8f/lib/sigil/agent/agent.ex#L656-L678));
   no approval record, grant path or payload binding exists in 0.1.4 (the only
   occurrences of "approv" in agent.ex are those lines). Tool execution is
   `Task.async` + `Task.yield(timeout) || Task.shutdown`, and a timeout is
   returned as `{:error, :timeout}`
   ([tool.ex:104-128](https://github.com/sigilframework/sigil/blob/fa3513fdc185f1f289167db141405dd1ef67de8f/lib/sigil/tool/tool.ex#L104-L128)),
   which the loop renders to the model as "Error: :timeout"
   ([agent.ex:680-700](https://github.com/sigilframework/sigil/blob/fa3513fdc185f1f289167db141405dd1ef67de8f/lib/sigil/agent/agent.ex#L680-L700)).
5. Input guard. `Guard.check_injection/1` is a lower-cased substring denylist
   ([guard.ex:47-67](https://github.com/sigilframework/sigil/blob/fa3513fdc185f1f289167db141405dd1ef67de8f/lib/sigil/agent/guard.ex#L47-L67)),
   described by its own moduledoc as "a basic heuristic check".
6. Team shared memory. One ETS table readable and writable by every agent in
   the team; no owner, provenance or scope
   ([team.ex:64-115, 171-204](https://github.com/sigilframework/sigil/blob/fa3513fdc185f1f289167db141405dd1ef67de8f/lib/sigil/agent/team.ex#L171-L204)).

### Overlap check

| Mechanism | Elzoo handle / task | Already covered? | Upstream reuse? | Gap it exposes |
| --- | --- | --- | --- | --- |
| 1 context budget + compaction | `workflow/context-selection` (deferred, no admission record); not ELZ-022 `workflow/budget` (spend) | capability-model: "context/token budgeting is not money settlement"; C7: estimates vs observed usage not conflated; no Contract text yet | No: coupled to Sigil's message shape and model table; a tokenizer/provider count library would be chosen at adoption | The only handle in the compared set without an admission record; Sigil's reservation shape is a usable starting interface |
| 2 event log / checkpoint / resume | ELZ-009 `state/event-log`, `state/checkpoint` | ELZ-009 already carries the Raxol rules (journal is the only truth, deterministic prefix refold, durable before surfaces) | No | Checkpoint that references an unacknowledged tail; non-unique sequence; partial refold |
| 3 run lifecycle | `workflow/run` (deferred) | Raxol row: interrupt stages with OS-level death confirmation; nothing yet about observing attempt death | No | Status owner relies on a success message instead of a monitor |
| 4 static tool permission, ASK as text, timeout as error | ELZ-024 `workflow/approval`, ELZ-023 `delivery/effect-intent`, `core/envelope` result matrix | ELZ-024 binds approval to actor + resource + exact payload + policy version; envelope: `timed_out/dispatched` is an unknown external outcome | No | Shows how an ASK degrades into model-visible text, and a dispatched timeout into a plain error |
| 5 substring guard | ELZ-011 / Raxol event boundary | Already recorded: "a string denylist is incomplete"; gate on typed effect class | No | None new |
| 6 team ETS | `state/artifact`, C6 authority | C6: "no authority escalation through children"; artifacts have ownership and integrity | No | Negative example only |

### Proposals

- ELZ-009 `state/event-log` / `state/checkpoint` design tests (C5, C6, C7):
  "A checkpoint may reference only a sequence at or below the durably
  acknowledged tail; a checkpoint written ahead of an asynchronous event
  buffer is rejected by the Contract." "`(stream identity, sequence)` is
  unique at the store; the writer's in-memory counter is not the source of
  sequence truth after a restart." "Replay is total over event kinds: an
  event kind the refold does not apply must be declared non-state-bearing in
  the Contract, otherwise resume is a silent divergence (Sigil rebuilds only
  `user_message`)."
- `workflow/run` design test (C5, C6): "The Run's status owner observes
  attempt termination through a monitor or link, never only through a
  completion message from the attempt; an attempt that crashes or is killed
  leaves the Run in an explicit failed/unknown state, not `:running`."
- ELZ-024 design tests (C3, C6): "A tool-level static permission is an
  authorization input, not the decision: the reduction still binds the exact
  payload, actor and policy version." "An ASK halts the attempt's Effect and
  escrows the payload; a message rendered to the model is a product choice and
  no later model turn can resolve the ASK. Test: the model replies 'approved'
  or 'done' and the escrowed write stays escrowed."
- ELZ-023 / `integration/agent-runner` design test (C6): "A tool execution
  that exceeds its deadline after dispatch is reported as `timed_out` with
  `dispatch: dispatched` (or `unknown`), never as a generic error string fed
  back to the model; the Run decides poll/reconcile, and the model is told the
  outcome is unknown."
- `workflow/context-selection` Contract sentences (C6, C7): "Selection takes a
  declared window, fixed reservations (instructions, tool declarations,
  response reserve) and candidate items with identity, version, source and an
  access-check result; it returns the selected ordered set, the dropped set
  with a reason per item, and a size total tagged `estimate` with its
  estimator identity." "A derived item (summary) references the item
  identities it replaces and is tagged derived; it is model output and
  therefore an untrusted proposal, not retained fact." "An unknown model or
  provider has no default window; selection fails explicitly." Admission
  record draft below.

### Admission record draft: `workflow/context-selection` (demand-led, not in the P0–P3 chain)

1. **Responsibility and caller.** Decide which permitted, versioned items
   enter one model call under a declared size window, and record what was
   dropped and why. Callers: C6 (bounded child runs with artifacts as
   context) and C7 (scheduled research with scoped retrieval). A human review
   queue that assembles a bounded brief from permitted documents challenges
   generality without a model.
2. **Interface and invariant.** Inputs: `window{size, unit, estimator_id}`,
   `reservations{name => size}`, ordered candidates
   `{item_id, version, source, access{principal, checked_at, result},
   estimate, priority}`, and the policy (recency, priority, derived-item
   allowance). Outputs: `selected` (ordered), `dropped{item_id, reason}` with
   reasons `access_denied | stale_access_check | over_window | superseded |
   policy`, `total_estimate` tagged with `estimator_id`. State owner: none;
   pure decision owned by the calling Run. Invariant: `sum(selected.estimate)
   + sum(reservations) <= window.size`; every selected item has
   `access.result = allowed` and `checked_at` within the policy's freshness;
   a derived item is selected only when every source it references is itself
   permitted; selection is deterministic for equal inputs; an item whose
   `version` is superseded by another candidate is dropped as `superseded`.
   Non-goals: tokenization, retrieval, summarization, truth or memory claims.
3. **Reuse check.** Provider count APIs and tokenizer libraries supply
   estimates (req_llm is the listed provider-integration candidate); Sigil's
   per-category reservation and compaction strategies are policy inputs, not
   a dependency; summarization is an `integration/ai-model` Effect producing a
   derived candidate, not part of this Piece. Remaining policy (access
   freshness, drop reasons, derived-item provenance) is Elzoo's.
4. **Split test.** Window arithmetic and the access/provenance filter share
   one invariant (nothing selected may violate either) and stay behind one
   interface. Estimator choice, retrieval and summarization are separate
   Adapters.
5. **Failure and evidence.** Dangerous paths: an item whose access was revoked
   after retrieval still selected (C7); a summary replacing items whose
   sources were denied; estimate undercount causing provider rejection, which
   must surface as a provider result, not silent truncation; an unknown model
   given a default window. Proofs: window law and access law over the pure
   selection in Cure (finite lists, total function). Tests: revocation between
   retrieval and selection, superseded versions, derived-item provenance,
   deterministic ordering. Upstream: estimator accuracy and provider limits
   are named contracts, never proven here.
6. **Composition record.** Depends on `core/envelope` for item references,
   `domain/authorization` for the access check result, `integration/ai-model`
   for estimates/derived items and `domain/metering` for reconciling observed
   usage against the estimate. Data classification: context may carry
   secrets by accident; `integration/secrets` rules apply (secrets are not
   ordinary model context). No delivery guarantee implied.

## shifts 0.0.2

### Observations (dated 2026-11-06, `hex:` tarball)

Dependencies: anthropix ~> 0.2, ex_mustache ~> 0.2, jason ~> 1.4,
nimble_options ~> 1.1, ollama ~> 0.5. Nearly every moduledoc is `TODO`.

1. Named operations and result correlation. `Shift.add_operation/3` rejects
   duplicate operation names (`hex:lib/shifts/shift.ex:136-142`); the runner
   folds operations into `ShiftResult.chats` keyed by name and
   `ShiftResult.to_outputs/1` exposes prior outputs by name to later steps
   (`hex:lib/shifts/shift/runner.ex:18-32`, `hex:lib/shifts/shift_result.ex:23-41`).
2. Fan-out. `each_async` runs children with `Task.async` and
   `Task.await_many(:infinity)` (`hex:lib/shifts/shift/runner.ex:68-72`): no
   deadline, a crashed child takes the parent down.
3. Tool loop. `Chat.handle_tool_use/2` recurses `tool → generate → tool` with
   no turn bound; an unknown tool is logged and ignored ("Just ignore it and
   hope for the best"), a raising tool is unhandled (`todo`), and the real
   shift is not passed (`%Shift{}` placeholder) (`hex:lib/shifts/chat.ex:81-110`,
   `hex:lib/shifts/chore.ex:84`).
4. Provider metrics discarded. The LLM behaviour declares `get_metrics/1`
   (`hex:lib/shifts/llm.ex:16-26`) but the chat never merges it
   (`hex:lib/shifts/chat.ex:70-71`).

### Overlap check and proposals

| Mechanism | Elzoo handle | Covered? | Reuse? | Proposal |
| --- | --- | --- | --- | --- |
| 1 named outputs | `delivery/aggregation` (planned), `core/envelope` `correlation_id` | Envelope has correlation; aggregation is planned with "correlation/retention policy" | No | Contract sentence: "Fan-out branches are identified by declared branch identity carried in `correlation_id`/`attempt_id`; the join exposes results by that identity, and duplicate branch identities are rejected at Wiring time." |
| 2 unbounded join | `delivery/aggregation`, ELZ-006 | C6 "bounded fan-out/depth/cost" | No | Covered by the Lux join design test above (deadline + per-branch result) |
| 3 unbounded tool loop, ignored unknown tool | `assembly/agent-product`, `integration/ai-model`, ELZ-022 | C6 bounded depth; ELZ-022 unit-tagged budget | No | Design test (C6): "A tool call naming an unknown tool is returned to the Run as a typed rejected proposal and counted against the turn budget; it is never dropped silently. Turns are a `workflow/budget` unit." |
| 4 metrics dropped | `integration/ai-model`, `domain/metering` | C9: "missing usage is unknown rather than zero" | No | Contract sentence: "The provider result carries `usage` with a source tag `provider_reported | estimated | unknown`; an Adapter may not omit the field or report zero for unknown." |

Verdict: skip for adoption (release 2024-04-18, repo dormant since
2024-06-21, source of record not reproducible from Git). License is
Apache-2.0, compatible, which does not change the verdict.

## staff_ai 0.0.4

### Observations (dated 2026-11-06, at `b549de4a`)

`src/staff_ai.gleam` defines `TaskStatus` (Ready/InProgress/Completed/
Cancelled/Failed), `Task` with `assigned_agent` and one timestamp per terminal
status ([staff_ai.gleam:27-70](https://github.com/chainyo/staff-ai/blob/b549de4aff67f90fd73a4b75d18d9bf9e2f695fb/src/staff_ai.gleam#L27-L70)),
`Agent` ([101-127](https://github.com/chainyo/staff-ai/blob/b549de4aff67f90fd73a4b75d18d9bf9e2f695fb/src/staff_ai.gleam#L101-L127))
and `Squad` ([134-163](https://github.com/chainyo/staff-ai/blob/b549de4aff67f90fd73a4b75d18d9bf9e2f695fb/src/staff_ai.gleam#L134-L163)),
each with a constructor that generates a UUID. No transition function, no
behaviour, 49 lines of constructor tests. Dependencies: gleam_stdlib, ids,
birl. The repo's last commit is 2024-03-21 (Groq inference added after the
0.0.4 tag).

### Verdict and proposals

Skip. Reasons, dated: last release 2024-03-16; license status unclear
(declared Apache-2.0, no license text, "All rights reserved" header at
`src/staff_ai.gleam:16`), so not adoptable under
docs/development/08-upstream-and-forks.md until upstream clarifies; ELZ-017
already states no Gleam dependency is implied by backend Pieces. No proposal:
the one lesson (a single Task record carrying assignee, status and attempt
timestamps conflates Work Item, Run and Attempt) is already written in
docs/capability-model.md ("Avoid a universal `Account`, `Task`, `Status` or
`Event` record").

## Skipped mechanisms and why

- Lux Python/Node bridges (`venomous`, `nodejs`), web3 contracts, Hyperliquid
  and Etherscan prisms, Telegram/Discord integrations, company DSL and role
  templates: product and protocol surface, outside the compared capabilities.
- Lux execution log (`beam/runner.ex:299-330`): a per-step map with inputs and
  results is a product trace; `state/audit-log` and telemetry remain distinct
  (capability-model "State log / audit record / telemetry").
- Lux `AgentHub` capability registry: runtime discovery is a separate
  capability and never authorization (capability-model "Dynamic capability
  discovery").
- Sigil web layer (Plug/Bandit/WebSocket live views), auth, CSRF, pgvector
  memory store, Postgres session store: out of scope and covered by Ash/Phoenix
  candidates elsewhere.
- Sigil `Guard` denylist and `Team` shared ETS: already covered as negative
  examples by the Raxol rows and C6.
- Sigil summarizer internals: model-output caching is product behaviour; only
  the provenance rule above is taken.
- Shifts mustache prompt templates, Ollama/Anthropic adapters: product
  prompting and provider SDK work; req_llm remains the listed candidate.
- staff_ai entirely, beyond the license flag.

## Open questions

1. Lux 0.5.0's Hex tarball does not correspond to any commit of the public
   repository (nearest `37f05ab` differs in two files and the tarball leaks a
   local path). Should Elzoo's reference rule require a Git-reproducible
   source for anything cited, or is a Hex checksum sufficient for a
   negative-example citation? This report cites the tarball with `hex:` paths
   for the two differing files.
2. Shifts 0.0.2 has the same problem (release predates the repository's
   history). Same question.
3. `workflow/context-selection` is the only compared handle without an
   admission record; the draft above is offered for an ELZ task body, but its
   access-check input depends on `domain/authorization`'s shape from ELZ-024,
   which is still a proposal.
4. Whether turns should be a `workflow/budget` unit (ELZ-022) or a separate
   `workflow/run` bound; this report assumes the former because ELZ-022
   already carries abstract unit tags.
5. The staff_ai license conflict is reported, not resolved; no contact with
   upstream was made (external messages require session authorization).
