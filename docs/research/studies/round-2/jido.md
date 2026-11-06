# Elzoo adopt-or-distill study: Jido 3.0 beta and jido_action

Study date: 2026-11-06. Read-only source study of two Hex pre-releases against
the Elzoo capability gaps named in the brief. Nothing was executed, vendored or
copied; file:line links point at the pinned commits. Observations are dated
facts about the packages; Proposals are Elzoo text that Elzoo would author.
Elzoo context read at `balungpisah/elzoo` `bf16422d` (2026-11-06).

## Summary table

| Package | Pinned SHA | License | Last commit (tag) | Verdict | One line |
| --- | --- | --- | --- | --- | --- |
| jido 3.0.0-beta.2 | [`eb5f5818`](https://github.com/agentjido/jido/tree/eb5f5818cc920a936da31ad5acf05a36a84c643e) (tag `v3.0.0-beta.2`; Hex release 2026-10-19, tarball `lib/` byte-identical to the tag) | Apache-2.0 ([LICENSE](https://github.com/agentjido/jido/blob/eb5f5818cc920a936da31ad5acf05a36a84c643e/LICENSE), Hex metadata `Apache-2.0`) | 2026-10-19 | **distill** | Commit-before-dispatch Turn, CAS persistence with a three-way write classification, durable schedule occurrences and child-spawn uncertainty are worth Contract text; the framework itself is a pre-release host with 13 Hex requirements (two sibling betas, one alpha) and a 4,466-line `AgentServer`, so not an adoption candidate |
| jido_action 3.0.0-beta.22 | [`9fe61b13`](https://github.com/agentjido/jido_action/tree/9fe61b13f6300e017d37940778e8c5cd189098e6) (tag `v3.0.0-beta.22`; Hex release 2026-10-22, tarball `lib/` byte-identical to the tag) | Apache-2.0 ([LICENSE](https://github.com/agentjido/jido_action/blob/9fe61b13f6300e017d37940778e8c5cd189098e6/LICENSE), Hex metadata `Apache-2.0`) | 2026-10-22 | **distill** | Retry-eligibility-by-classification, uncertain-outcome-as-terminal, portability of durable data, registry-only target resolution and a cycle diagnostic are reusable as design tests; execution is delegated to `runic 0.1.0-alpha.12`, so no boundary can be adopted without adopting an alpha engine |

License: both packages declare Apache-2.0 at the pinned revisions, compatible
with Elzoo-owned Apache-2.0 source. No conflict. Transitive licenses of
`runic` (0.1.0-alpha.12) and `multigraph` (0.16.1-mg.5, a libgraph-derived
package name) were **not** checked; they would need checking before any
adoption. No source was copied, so no notice obligation arises from this study.

## Pins and dependency weight

- jido `eb5f5818`: `mix.exs` deps ([L373-L395](https://github.com/agentjido/jido/blob/eb5f5818cc920a936da31ad5acf05a36a84c643e/mix.exs#L373-L395)) — `jido_action ~> 3.0.0-beta.21`, `jido_signal ~> 3.0.0-beta.5`, `runic ~> 0.1.0-alpha.12`, `zoi`, `spark`, `splode`, `telemetry`, `telemetry_metrics`, `sched_ex`; optional `opentelemetry_api`, `bedrock`, `bedrock_raft`, `ecto_sql`. Hex API lists the same 13 requirements. `git shortlog` at the tag: 904 of ~961 non-bot commits by one author. The tag sits on `release/v3`, not `main` (`main` head `d0bf7c56`, 2026-10-17). [docs/release-beta.2.md](https://github.com/agentjido/jido/blob/eb5f5818cc920a936da31ad5acf05a36a84c643e/docs/release-beta.2.md) still says "Jido beta.2 is not published" while Hex has the release; the same file reports `mix quality` and `mix test.all` passing on Elixir 1.20.4 / OTP 29.1 (upstream claim, not verified here). The [CAS guide](https://github.com/agentjido/jido/blob/eb5f5818cc920a936da31ad5acf05a36a84c643e/guides/compare-and-swap-hibernate-and-thaw.md) documents that `WriteAuthority` and instance-based keys were removed between betas, so the persistence API is still moving.
- jido_action `9fe61b13`: deps ([L286-L294](https://github.com/agentjido/jido_action/blob/9fe61b13f6300e017d37940778e8c5cd189098e6/mix.exs#L286-L294)) — `telemetry`, `zoi`, `jason`, `multigraph ~> 0.16.1-mg.5`, `runic ~> 0.1.0-alpha.12`, `splode`, `spark ~> 2.7.3`. 657 of ~670 non-bot commits by one author. Repo `main` had moved to `96a18aab` (2026-10-27) at study time.
- Elixir/Cure boundary fit: both are Elixir-only and process-oriented. Elzoo's pure decisions live in Cure; the only parts of these packages that are pure data/decision shapes (retry classification, occurrence identity, write-result classification, cycle diagnostic) are small enough to restate as Contracts rather than import.

## jido_action 3.0.0-beta.22

### Observations (dated 2026-11-06, at `9fe61b13`)

| # | Observed source | What it does | Elzoo handle / task it touches |
| --- | --- | --- | --- |
| A1 | [jido_action.ex L196-L215](https://github.com/agentjido/jido_action/blob/9fe61b13f6300e017d37940778e8c5cd189098e6/lib/jido_action.ex#L196-L215); [guides/execution.md "Results And Errors"](https://github.com/agentjido/jido_action/blob/9fe61b13f6300e017d37940778e8c5cd189098e6/guides/execution.md) | `run/2` returns `{:ok, value}`, `{:ok, value, effects}`, `{:error, reason}` or `{:error, reason, discarded_effects}`; effects are opaque deferred requests that `Jido.Exec` never dispatches; a Flow returns one effect batch only after complete success | core/operator, core/effect (planned) |
| A2 | [error.ex L234-L246](https://github.com/agentjido/jido_action/blob/9fe61b13f6300e017d37940778e8c5cd189098e6/lib/jido_action/error.ex#L234-L246) | `retryable?/1`: all errors non-retryable by default; `details.retry: true` opts in; validation, configuration, timeout and process exit are never retried | delivery/retry-timeout (ELZ-006) |
| A3 | [jido_exec.ex L396-L412](https://github.com/agentjido/jido_action/blob/9fe61b13f6300e017d37940778e8c5cd189098e6/lib/jido_exec.ex#L396-L412), [L450-L455](https://github.com/agentjido/jido_action/blob/9fe61b13f6300e017d37940778e8c5cd189098e6/lib/jido_exec.ex#L450-L455) | A Runic `ExecutionUncertain` event is projected as a distinct terminal result (`outcome: :uncertain`, `retry: false`), not as failure or success | core/envelope delivery result (ready); delivery/effect-intent (ELZ-023) |
| A4 | [portable.ex L8-L22](https://github.com/agentjido/jido_action/blob/9fe61b13f6300e017d37940778e8c5cd189098e6/lib/jido_exec/portable.ex#L8-L22) | Managed (resumable) execution rejects any pid, port, reference or function anywhere in params/context/output with `:non_portable_durable_value`, `retry: false` | state/checkpoint (ELZ-009), workflow/run |
| A5 | [jido_exec.ex L61-L71](https://github.com/agentjido/jido_action/blob/9fe61b13f6300e017d37940778e8c5cd189098e6/lib/jido_exec.ex#L61-L71) | `effect_id/4` = content digest of `{execution_id, activation_id, output_id, index}` offered as a host deduplication key; [security.md](https://github.com/agentjido/jido_action/blob/9fe61b13f6300e017d37940778e8c5cd189098e6/guides/security.md) states it does not create exactly-once | delivery/effect-intent (ELZ-023), delivery/idempotency |
| A6 | [graph_validation.ex L9-L30](https://github.com/agentjido/jido_action/blob/9fe61b13f6300e017d37940778e8c5cd189098e6/lib/jido_flow/graph_validation.ex#L9-L30) | Three distinct issue kinds at definition time: duplicate component name, unknown dependency, cycle (names the components left `remaining` after topological analysis); graph mechanics come from `multigraph` | workflow/dependency-graph (C5) |
| A7 | [registry.ex L9-L10](https://github.com/agentjido/jido_action/blob/9fe61b13f6300e017d37940778e8c5cd189098e6/lib/jido_authoring/registry.ex#L9-L10), [L132-L142](https://github.com/agentjido/jido_action/blob/9fe61b13f6300e017d37940778e8c5cd189098e6/lib/jido_authoring/registry.ex#L132-L142); [security.md](https://github.com/agentjido/jido_action/blob/9fe61b13f6300e017d37940778e8c5cd189098e6/guides/security.md) | Stored/AI-authored flow data can only select `{stable_id, vsn}` entries from a host-owned registry capped at 10,000; no atom is minted from data; the guide says "a schema is not authorization" and that dispatch targets named by input or a model must resolve through an allowlist | integration/ai-model, integration/agent-runner, ELZ-024 (typed gate), ELZ-011 Adapter |
| A8 | [dispatch.ex L157-L159](https://github.com/agentjido/jido_action/blob/9fe61b13f6300e017d37940778e8c5cd189098e6/lib/jido_exec/node/dispatch.ex#L157-L159); [waits.ex L1-L45](https://github.com/agentjido/jido_action/blob/9fe61b13f6300e017d37940778e8c5cd189098e6/lib/jido_exec/waits.ex#L1-L45) | A terminal Dispatch may return `{:handoff, successor_instruction, effects}` that the host must admit as new work; Waits take a host-supplied clock and host-ordered accepted events, own no timer | workflow/run (bounded loops, C6 depth), delivery/time |
| A9 | [managed-execution.md "Retry Recovery Limits"](https://github.com/agentjido/jido_action/blob/9fe61b13f6300e017d37940778e8c5cd189098e6/guides/managed-execution.md) | With `runic 0.1.0-alpha.12` a checkpoint cannot save a retry budget or deadline; restore can grant a fresh budget; "Hosts must not advertise durable retry budgets" | delivery/retry-timeout, assembly/durable-job (ELZ-010) |

Overlap check: A1 and A3 are already Elzoo Contract: `CONTEXT.md` defines
Effect as an explicit request and `pieces/core/envelope/README.md` L48-L50
fixes `outcome × dispatch` including `timed_out/not_dispatched` and `unknown`.
A5 restates ELZ-023 step 2 ("the key is a function of the logical request").
A7 restates the Raxol command-decoder row and the ELZ-015 spike rule that
model arguments never populate actor/tenant. Reuse as-is is not possible for
any of these: every executable path goes through `Runic.Workflow`, an alpha
engine, and `Jido.Exec.run/4` runs in an unlinked task under a package-owned
supervisor ([execution.md "Process Behavior"](https://github.com/agentjido/jido_action/blob/9fe61b13f6300e017d37940778e8c5cd189098e6/guides/execution.md)), which is a Host decision Elzoo leaves to consumers.

### Proposals

1. **delivery/retry-timeout (ELZ-006), C3/C6 — Contract sentence.** "Retry
   eligibility is a property of the classified failure, not of the attempt
   count: the default class is not retryable; a `timed_out`, `unknown` or
   process-exit result is never retry-eligible by classification alone and must
   pass through delivery/effect-intent (ELZ-023) before any re-dispatch."
   Design test: a `timed_out/dispatched` result with `max_attempts: 3` produces
   zero further dispatches (from A2, A3).
2. **state/checkpoint (ELZ-009), C6 "parent result/wakeup survives restart" —
   design test.** "A checkpoint whose payload contains a pid, port, reference,
   function or other process-local value is rejected at write time with a
   named path; the rejection is not retryable." (A4.) Keep as a test over the
   ELZ-009 codec boundary, not a Cure law.
3. **workflow/dependency-graph, C5 "reject cycles" — Contract text.**
   "Definition validation reports three distinct, non-collapsing issue kinds:
   duplicate node name, dependency on an unknown node, cycle; a cycle report
   names every node that is not topologically placeable, not just one edge."
   Reuse direction unchanged: libgraph (already in orchestration-references)
   for mechanics; Elzoo owns the issue vocabulary and readiness policy. (A6.)
4. **integration/ai-model tool-call translation and integration/agent-runner,
   C6 "no authority escalation through generated tool arguments" — Contract
   sentence.** "A tool or action name arriving from model output resolves only
   through a host-owned registry keyed by `{stable id, version}`; an unknown
   or unversioned name is rejected before any argument validation; successful
   resolution grants no authority and is followed by domain/authorization
   (ELZ-024)." Design test: a tool name that is a valid module string but not
   registered yields `rejected/not_dispatched`, never `String.to_atom`. (A7.)
5. **workflow/run, C6 "bounded fan-out/depth" — Contract sentence.** "A step
   that ends by naming a successor piece of work ends the current Run or
   Attempt; the successor is admitted as new work under the same budget and
   depth accounting, never executed as a continuation of the finished one."
   (A8.) Complements the existing Raxol steer row.
6. **delivery/retry-timeout + assembly/durable-job (ELZ-010) — dangerous
   failure case.** "A retry budget that is not part of the persisted Run state
   is reset by restart; the Contract must either persist attempt count and
   absolute deadline with the Run or state that bounded attempts hold only
   within one process lifetime." (A9.) Add to ELZ-010 acceptance as a listed
   restart scenario.

## jido 3.0.0-beta.2

### Observations (dated 2026-11-06, at `eb5f5818`)

| # | Observed source | What it does | Elzoo handle / task it touches |
| --- | --- | --- | --- |
| B1 | [agent.ex L204-L215](https://github.com/agentjido/jido/blob/eb5f5818cc920a936da31ad5acf05a36a84c643e/lib/jido/agent.ex#L204-L215); [turns-commit-and-effects.md](https://github.com/agentjido/jido/blob/eb5f5818cc920a936da31ad5acf05a36a84c643e/guides/turns-commit-and-effects.md); [agent_server.ex L3555-L3563](https://github.com/agentjido/jido/blob/eb5f5818cc920a936da31ad5acf05a36a84c643e/lib/jido/agent_server.ex#L3555-L3563) | `Agent.cmd/3` is a pure candidate + directives; the server stage order is admission → routing → execution → finalization → commit (CAS save at `state_version + 1`, `expected_revision: state_version`) → notification → directive dispatch → settlement; directives run after commit, the first failure stops the rest, the commit remains; `last_outcome` and `last_effect_outcome` are separate | core/operator, core/effect, workflow/run, state/outbox |
| B2 | [recoverable-effects.md](https://github.com/agentjido/jido/blob/eb5f5818cc920a936da31ad5acf05a36a84c643e/guides/recoverable-effects.md) | "Jido core does not provide a universal outbox or an exactly-once external-effect guarantee"; directives are transient, durable intent must be state; recommended protocol: stable op id → commit pending → execute with id as idempotency key → ack signal clears; restore "can see the pending item and issue the work again"; outcome classes not started / started-unknown / confirmed / failed-safe / permanently-failed | delivery/effect-intent (ELZ-023), state/outbox |
| B3 | [persistence.ex L121-L131](https://github.com/agentjido/jido/blob/eb5f5818cc920a936da31ad5acf05a36a84c643e/lib/jido/persistence.ex#L121-L131), [L366-L405](https://github.com/agentjido/jido/blob/eb5f5818cc920a936da31ad5acf05a36a84c643e/lib/jido/persistence.ex#L366-L405); [compare-and-swap guide "Write failures"](https://github.com/agentjido/jido/blob/eb5f5818cc920a936da31ad5acf05a36a84c643e/guides/compare-and-swap-hibernate-and-thaw.md) | Revisioned record + exact-byte CAS; `{:error, :conflict}` is confirmed stale, `{:rejected, reason}` is a confirmed preflight limit, **every other error is indeterminate** and stops the activation; "compare-and-swap is not a writer lease"; tombstones keep the revision barrier; a restore read is not a lease | state/checkpoint and state/event-log (ELZ-009), state/lease |
| B4 | [scheduler/durable.ex L24-L30](https://github.com/agentjido/jido/blob/eb5f5818cc920a936da31ad5acf05a36a84c643e/lib/jido/plugin/scheduler/durable.ex#L24-L30), [L32-L47](https://github.com/agentjido/jido/blob/eb5f5818cc920a936da31ad5acf05a36a84c643e/lib/jido/plugin/scheduler/durable.ex#L32-L47), [L51-L66](https://github.com/agentjido/jido/blob/eb5f5818cc920a936da31ad5acf05a36a84c643e/lib/jido/plugin/scheduler/durable.ex#L51-L66), [L71-L79](https://github.com/agentjido/jido/blob/eb5f5818cc920a936da31ad5acf05a36a84c643e/lib/jido/plugin/scheduler/durable.ex#L71-L79); [durable-schedule-occurrences.md](https://github.com/agentjido/jido/blob/eb5f5818cc920a936da31ad5acf05a36a84c643e/guides/durable-schedule-occurrences.md) | Occurrence identity = job id + generation + scheduled UTC instant (excludes arrival time, node, pid, signal id); replacing a schedule needs a strictly greater generation else `:schedule_generation_conflict`; at most one pending occurrence per job, later slots skipped while pending, missed offline slots not replayed; delivery admitted only if the pending occurrence's payload matches exactly | delivery/trigger, state/scheduler (C7) |
| B5 | [agent_server.ex L847-L856](https://github.com/agentjido/jido/blob/eb5f5818cc920a936da31ad5acf05a36a84c643e/lib/jido/agent_server.ex#L847-L856); [admission-cancellation-and-timeouts.md](https://github.com/agentjido/jido/blob/eb5f5818cc920a936da31ad5acf05a36a84c643e/guides/admission-cancellation-and-timeouts.md) | `cancel_turn/3` acts only if the supplied turn id still matches; cancellation does not undo I/O, commit or dispatched directives; a failed or timed-out cancellation is indeterminate and **stops the server**; a caller timeout is not a cancellation; seven distinct timeout scopes are tabulated | workflow/run cancellation, delivery/retry-timeout (ELZ-006) |
| B6 | [ownership-orphans-and-remote-children.md](https://github.com/agentjido/jido/blob/eb5f5818cc920a936da31ad5acf05a36a84c643e/guides/ownership-orphans-and-remote-children.md) | Child spawn happens after the parent commit under a parent-owned tag; parent-death policy is explicit (`:stop`/`:continue`/`:emit_orphan`); a remote spawn timeout "does not prove the child never started": retry only the identical directive, do not reuse the tag while unknown, `:spawn_request_closed` clears; "a process exit alone is not a business completion record"; emit-to-child success means queued, not committed | workflow/run parent/child settlement (C6), delivery/effect-intent |
| B7 | [agent_server.ex L3435-L3438](https://github.com/agentjido/jido/blob/eb5f5818cc920a936da31ad5acf05a36a84c643e/lib/jido/agent_server.ex#L3435-L3438) | `max_postponed_signals` (default 1,000) rejects with `{:overloaded, %{limit, postponed}}`; the guide states this bounds postponed work only, not the mailbox, and casts are best-effort | delivery/backpressure (ELZ-006) |
| B8 | [plugin/audit.ex L1-L12](https://github.com/agentjido/jido/blob/eb5f5818cc920a936da31ad5acf05a36a84c643e/lib/jido/plugin/audit.ex#L1-L12); [audit-records.md](https://github.com/agentjido/jido/blob/eb5f5818cc920a936da31ad5acf05a36a84c643e/guides/audit-records.md) | Bounded audit records are committed with the domain state in the same Turn; a failed Turn cannot add one; failed-Turn audit goes to the error-policy summary; telemetry is a different owner/retention | state/audit-log |
| B9 | [discovery.ex L2-L18](https://github.com/agentjido/jido/blob/eb5f5818cc920a936da31ad5acf05a36a84c643e/lib/jido/discovery.ex#L2-L18) | "Discovery is an inventory service. It does not grant permission to run an Action" | integration/agent-runner (C6 "tool discovery never itself authorizes") |

Overlap check: B1 and B9 confirm existing Elzoo text (Operator/Effect split;
`docs/capability-coverage.md` C6 "Tool discovery never itself authorizes").
B2 is weaker than ELZ-023: Jido records *pending intent* then relies on the
receiver's idempotency when restore re-issues the work; ELZ-023 writes
`dispatched` before the send and forbids re-dispatch from `dispatched` without
a definite failure. Nothing in B2 changes ELZ-023; it does supply a negative
design test (below). B3, B4, B6 and B8 touch handles where Elzoo has no text
yet (`state/lease`, `delivery/trigger`, `state/audit-log`) or only the ELZ-009
outline. Reuse as-is: no — persistence, scheduler and child ownership are
plugins of `Jido.AgentServer`, the mandatory host, and the Scheduler depends on
`sched_ex`; adopting any of them adopts the host.

### Proposals

1. **state/checkpoint + state/event-log (ELZ-009), C4/C5 — Contract text and
   dangerous failure.** "A durable write returns one of three classified
   results: `conflict` (confirmed stale expected revision; nothing replaced),
   `rejected{reason}` (confirmed preflight limit; nothing written) or
   `indeterminate` (any exception, exit, timeout or malformed adapter reply;
   storage may hold either record). An `indeterminate` result terminates the
   writer; recovery is a fresh activation that reads the authoritative record
   before deciding whether the transition committed." Design test: an adapter
   double that raises after persisting must produce `indeterminate`, and the
   recovered owner must observe the committed revision without re-applying the
   transition. (B3.) Add to the ELZ-009 acceptance list.
2. **state/lease (deferred), C5 "a worker that lost its lease cannot complete
   the new owner's attempt" — Contract sentence.** "A revision compare-and-swap
   fences a stale writer at the moment of its write; it is not a lease and
   cannot tell a live owner from a dead one before that write. A lease Piece
   must add expiry and renewal, and the CAS remains the last line of defence."
   (B3.)
3. **delivery/trigger (deferred) — admission record for a schedule-occurrence
   Piece (C7).** Drafted below. (B4.)
4. **delivery/effect-intent (ELZ-023) — negative design test.** "A recovery
   path that finds a pending intent and re-issues the send *because the
   receiver is idempotent* is admissible only when the provider idempotency
   contract is recorded on the intent (ELZ-023 ground 2); with no such
   contract the same record must `poll`, and a test double receiver that is
   not idempotent must observe exactly one send across crash/restart." (B2.)
5. **state/outbox (ELZ-009), C1/C3 — Contract sentence.** "The output batch of
   a transition is transient. Durable intent is state committed with the
   transition; the next Effect is derived from that state after commit. A
   failure during dispatch leaves the commit in place and is reported as a
   separate post-commit outcome." (B1, B2.)
6. **workflow/run, C6 — Contract sentences.** (a) "Cancellation names the
   Attempt it targets; a stale id changes nothing. A cancellation whose own
   result is unknown is `indeterminate` and terminates the owner rather than
   continuing with ambiguous liveness." (B5.) (b) "Starting a child Run is an
   Effect: under timeout its outcome is unknown; retry only the identical
   request under the same tag; the tag is not reusable while the outcome is
   unknown; the child's process exit is never its acceptance result." (B6.)
   (c) "Parent-death policy is a declared per-child choice, not a default."
7. **state/audit-log (deferred), C3/C6 — design tests.** "An audit record of a
   decision commits atomically with the decision; a failed transition leaves
   no record of success; audit of failed transitions uses a separate sink.
   A bounded in-state record list is a recovery convenience, not the retained
   audit trail; regulated histories hold an external record id in state."
   (B8.)
8. **delivery/backpressure (ELZ-006) — scope caveat.** "A postponed-work bound
   is not a mailbox bound; the Contract must name which queue it limits."
   (B7.)

### Draft admission record: delivery/trigger schedule occurrence (from B4)

1. **Responsibility and caller.** Decide whether a due schedule slot becomes
   one admissible occurrence, give it a stable identity, and decide what
   happens to further slots while that occurrence is unsettled. Callers: C7
   scheduled research digest; C1 invitation expiry sweep challenges
   generality (a one-shot schedule).
2. **Interface and invariant.** Inputs: schedule definition `{schedule id,
   generation, expression, overlap policy ∈ {skip, queue(n), replace}}`,
   current UTC instant from a clock port, settlement events
   `{acknowledged | released, occurrence id}`. Outputs: `occurrence{id = f(schedule id, generation, scheduled instant)}`,
   `skipped{slot}`, `replaced{old occurrence id}`, `rejected{stale_generation}`.
   Identity excludes arrival time, node, process, delivery id. Invariants: at
   most `n` unsettled occurrences per schedule under `queue(n)`, exactly one
   under `skip`/`replace`; a redefinition needs a strictly greater generation;
   a delivery is admitted only when its occurrence id and payload match an
   unsettled occurrence; missed slots while offline are not replayed unless
   the policy says `queue`. Non-goals: cron parsing (upstream), delivery
   transport, job execution.
3. **Reuse check.** Oban cron / `sched_ex` / `quantum` compute due instants;
   none exposes generation-scoped identity or an explicit overlap policy as a
   value Elzoo can test. Elzoo owns the identity function and the overlap
   decision; the due-instant computation stays upstream.
4. **Split test.** Identity and overlap policy share the "one unsettled
   occurrence" invariant and stay together. Clock, transport and the job that
   consumes the occurrence are separate choices.
5. **Failure and evidence.** Dangerous paths: two activations both enqueue the
   same slot (identity collision must dedupe); a redefined schedule with the
   same generation silently replacing pending work; a stale delivery of a
   settled occurrence re-admitted; offline catch-up flooding under `queue`.
   Proofs: identity determinism and the per-policy bound over the pure
   transition (Cure). Tests: restart with an unsettled occurrence, generation
   conflict, stale delivery. Upstream: clock and cron library contracts named.
6. **Composition record.** Depends on delivery/time (clock port), core/envelope
   result schema, delivery/idempotency for the consumer side; durability via
   ELZ-009 once available (volatile until then). Data classification: schedule
   metadata only.

## Skipped mechanisms and why (dated 2026-11-06)

- `Jido.AgentServer` as a host, Plugins, Topology/Controller, Sensors, Signal
  bus, Pods, Instances/namespaces: a mandatory process host and framework;
  AGENTS.md forbids adopting a second mandatory host, and the brief's own rule
  is that agent orchestration is an Assembly, not a kernel.
- Persistence adapters (ETS, file, Mnesia, Redis, S3, Ecto, Bedrock): adapters
  behind Jido's record format 3; Elzoo evaluates AshPostgres/Oban at its own
  ELZ-009/010 boundary (ADR-0005).
- `Jido.Flow` DSL, `Jido.Expr`, `Jido.Authoring` document codecs, inline
  actions: a workflow language bound to Runic; Elzoo's Wiring/Assembly already
  declare composition and Cure owns pure decisions.
- `Jido.Exec` managed execution, step/resume: entirely delegated to
  `runic 0.1.0-alpha.12` (guide states it keeps no checkpoint of its own).
- Telemetry/OpenTelemetry modules, Discovery catalog, `sched_ex` scheduling
  runtime, worker pools, multi-tenancy guide: operational wiring or product
  policy; Elzoo's runtime/telemetry task owns redaction first.
- The existing jido 2.4.0 row in `docs/research/orchestration-references.md`
  remains accurate as a candidate note; this study does not upgrade it to an
  adoption. A 3.0 row could replace it with the pins above once the research
  file is next amended (ELZ-021 style), but that is a documentation decision,
  not a build task.

## Open questions

1. Is `Jido.Exec.effect_id/4` stable across resume? It includes a Runic
   `activation_id`; whether an activation keeps its id after restore is a
   Runic property not verified here. If it changes, the key is not "a function
   of the logical request" in ELZ-023's sense.
2. Licenses of `runic` 0.1.0-alpha.12 and `multigraph` 0.16.1-mg.5 were not
   checked; irrelevant for distillation, required before any adoption.
3. `pending_child_spawns` / `:spawn_request_closed` (B6) were read from the
   guide; the implementing code was not located in `agent_server.ex` within
   this study's budget, so B6 is a documented contract, not a code citation.
4. Upstream test claims (1,733 tests, 93.7% coverage in `docs/release-beta.2.md`)
   were not reproduced; no Elixir toolchain was run for this study.
5. Whether ELZ-009's acceptance list should absorb proposal B-1 (three-way
   write classification) or whether it belongs to a new `state/checkpoint`
   sub-Piece is a coordinator decision; the text is written so either works.
