# ELZ-421 — assembly/run-host: a supervised host for the engine Runs of one node

- Dependencies: ELZ-420, ELZ-422, ELZ-423

## Outcome and scope

New Piece ID `assembly/run-host`, an Assembly. Today each consumer of
`assembly/run-engine` builds its own host. The engine's test fixture
(`pieces/assembly/run-engine/test/support/run_engine_test_helper.exs`,
`fixture/0..2`, one function with defaults) and the Wave 9 root helper
(`test/support/wave9_tools_doors_models_money_helper.exs`, `tenant!/2`) each
assemble the Unit directory, the Run owner with its Lease, the evidence
Writer, AsyncWork, the effect-intent startup bindings, recovery with the same
fingerprint, and cleanup. (The fixture's Run and evidence Stores are
PostgreSQL even when a test overrides the Unit Store, so it is no full Memory
host.) This Piece owns such a host once, for one profile.

**Profile and limits.**

- Model calls are text-only calls of `integration/ai-text` (no image parts),
  so no artifact seam is needed. A request with an image part is refused
  before an intent exists (below).
- The spec's Effect bindings are the host's AI text bindings. A spec with
  another Effect binding is refused at start.
- ASK model calls are outside the profile: the host forwards no Approval
  controls, so such a call stays waiting until the Run ends.

**Start.** `start_link(opts)` starts one host per node. Required options:

- `owner_id`: this node's lease owner attribution (the Lease bound: 1..200
  bytes).
- `max_runs`: a host reservation table enforces it from reservation (in
  `start_run/3` or `wake/2`) through confirmed teardown. The dedicated Unit
  DynamicSupervisor has `max_children: max_runs` as a separate ceiling on live
  Units. Sleeping a Unit does not release its Run reservation.
- The directory settings: the host starts its own Registry and that dedicated,
  initially empty DynamicSupervisor for one `DynamicUnits` directory, with
  `idle_ms`.
- Compatible Unit, Run, evidence, EffectIntent journal and EffectIntent
  activation Store views, each with the fold and limits that its owner needs
  (the activation Store appends `intent_host` records; EffectIntent itself
  appends and checkpoints `intent` records). PostgreSQL views share the Repo
  and prefix. A Memory view cannot override the fold of its Memory process,
  so for the full Memory test the shared Memory namespace's fold and limits
  are configured to admit all required writes. The evidence Writer writes
  where the Run owner reads evidence, so a completed or failed finish passes
  the owner's evidence check.
- The Lease clock and backend that match the Store: `clock: :store` on
  PostgreSQL; on Memory one shared manual clock and one Lease backend for the
  whole host (Memory refuses a second backend for one Store).
- `clock` (the engine's trusted Unix-millisecond clock), `lease_ttl_ms`
  (1..86,400,000), and the `spec` callback
  `fn run_ref -> {:ok, spec} | {:error, reason}` that builds a Run's spec again
  from the caller's durable facts.
- Optional: `fencing_proof`, the caller's trusted callback
  `fn run_ref -> :fenced | :unproven end`, asked fresh each time a
  predecessor check needs it (Recovery, below); and the `on_terminal` and
  `on_lost` callbacks.

A spec holds the stable Run, operation, Attempt and Unit/stream identities,
`provider_refs`, the engine's trusted `context` callback and `budget_rule`,
the pattern, schemas, AI binding descriptors, gate, Budget, request cap, Run
deadline, tenant and principal, and the result reader's retention.

**Runs.**

- `start_run(host, run_ref, spec)` reserves a slot (`{:error, :capacity}` at
  `max_runs`), claims the Run's lease key (one key per Run, the Run owner's
  stream), starts the Run owner, `create`s the Run and begins its Attempt with
  the spec's stable IDs, provisions the effect-intent startup bindings, and
  starts the evidence Writer, AsyncWork and the engine (with `result_reader`).
  An interrupted start is retried by the same call with identical IDs: the
  owner answers `{:unchanged, :duplicate, _}` and no new Attempt begins. A
  retry that opens an existing Run or Unit journal passes the predecessor
  check of Recovery (below) before any engine starts. A lease that another
  owner holds gives `{:error, {:lease_refused, refusal}}`, and no engine
  starts. Starting the engine does not start the pattern: the caller sends the
  pattern's first input (for AgentLoop the typed `start`) through `input/5`.
- `input/5`, `control/5`, `status/2`, `deadlines/2`, `result/4` and
  `transcript/4` (each with the host and the `run_ref` before the engine's
  operands) pass through to the Run's engine, and give
  `{:error, :not_running}` for a Run that is not live on this host.
- On a terminal outcome the host stops accepting business input for that Run
  (`input/5` and `control/5` give `{:error, :terminal}`) and calls
  `on_terminal.(run_ref, outcome)`. It keeps the Run's engine with its scoped
  result reader live until `reap(host, run_ref)`. `reap/2` stops every per-Run
  process (engine, Unit, AsyncWork, intent owners, tasks), confirms that each
  is gone, releases the lease and frees the reservation. A terminal Run that
  is not reaped still counts against `max_runs`.

**AI model calls.** The host builds each AI binding itself:

- It derives the AI idempotency key, and so the intent key, from the stable
  Run and Attempt IDs and the engine's non-reused action ID, which is
  available at admission (`facts/1` receives only the action, not its
  occurrence).
- The host receives the sink messages itself, resolves the key to the exact
  Run, Attempt, action and occurrence, and then calls `RunEngine.input/4` (an
  AI sink tuple sent to the engine directly would fall into its catch-all and
  be dropped). On wake it rebuilds that route from the committed action facts
  and the stable binding configuration, not from `status/1` alone, and holds
  deliveries during startup until the route is verified.
- An `Elzoo.AiText.admission/2` refusal (`{:error, {:refused, reason}}`, for
  example `:unsupported_feature` for an image part, because the host
  configures no artifact reader, or `:too_large`) never reaches `facts/1`. The
  host records it through a path that the engine records before any intent
  exists (for example a gate denial), so the action settles refused, no intent
  starts and the provider is not called. `facts/1` returns no admission error
  and does no I/O. Intent startup bindings are provisioned at Run start, not
  per action.
- Each received outcome becomes one engine `action_outcome` input. The host
  derives the engine input ID from Run, Attempt and occurrence (a fixed-length
  digest, within the engine's 160-byte input ID bound for any 200-byte action
  ID). Under `budget_rule: :pause` the engine refuses an outcome without a
  future `pause_deadline` before settlement, so before first submitting an
  outcome the host obtains a future `pause_deadline` from the trusted context.
  It retries with the same input ID, frame and complete original context,
  including that pause operand (the engine compares the original context, so a
  recomputed operand would give `:input_id_conflict`). A duplicate delivery is
  therefore a duplicate input, never a second settlement.
- The sink sends `{:outcome, attempt_id, outcome}` or
  `{:sink_failed, attempt_id}`, before the intent owner commits its own
  settlement. The host translates outcomes actually received at the sink; a
  missing delivery does not fabricate an engine settlement. Every outcome
  input uses the binding's result schema `elzoo.ai-text.result` version 1, the
  schema AgentLoop reads. The README defines its payload forms: the completed
  view (`content`, `finish`, `tool_proposals`) and the refusal view
  (`reason`, `retry_after`, `candidate`). The translation:
  - `{:completed, body}`: outcome `"completed"`, `dispatch` `"dispatched"`,
    and `actual` from a trusted conversion of the body's usage to the spec's
    Budget unit (the README states it); no usage gives no `actual`.
  - `{:refused, reason, meta}`: outcome `"refused"`. Only the AI text reasons
    that sent nothing (`:credentials_unavailable`, `:input_unavailable`) give
    `dispatch` `"not_dispatched"` and `actual` 0; the others give
    `"dispatched"` and no `actual`.
  - `{:unknown, reason}`: outcome `"unknown"` and no `actual`, so its
    reservation stays reserved. `dispatch` is `"unknown"`, except
    `:malformed_response`, which always reached the provider. A delivered
    `:provider_error` does not prove dispatch: both a provider error and an
    adapter error deliver `{:unknown, :provider_error}`. The host never infers
    zero or a dispatch that the outcome does not establish.
  - `{:sink_failed, _}` gives no input; the host reports it, and the slot
    waits for reconciliation or the end of the Run.
  The README says that the engine's committed slot is the Run's record and
  that the intent's durable settlement is separate and can differ (for
  example after a crash right after the offer).

**Recovery.** `wake(host, run_refs)` returns one explicit disposition per
Run: `:woken` or `{:error, reason}` (the README lists each reason, including
`:incompatible_recovery`, `{:lease_refused, _}`, `:capacity`,
`:fencing_unproven` and a Run with no current Attempt).

- It opens only Runs that already have a current Attempt.
- It rebuilds the spec through the `spec` callback and starts the engine on
  its journal. A spec with another fingerprint (for example another gate
  version or request cap) gives `{:error, :incompatible_recovery}` for that
  Run; the engine may already have started its Unit, so the host confirms that
  Unit's cleanup. The other Runs of the batch still wake.
- Predecessor fencing: a replacement lease is necessary but not sufficient to
  grant recovery. Taking over the Run lease fences the compare-and-set writes
  on the Run stream; it does not fence the old Unit, an EffectIntent stream,
  or a task already between its durable arm and the provider send, and an old
  process can resume after the takeover. Engine startup itself recovers
  intents and drains work before it returns, so the check comes before the
  engine starts. It applies to both `wake/2` and a `start_run/3` retry that
  opens an existing Run or Unit journal. After obtaining the lease and before
  starting an engine, the host requires confirmed teardown (of the processes
  it tracked from their start; the engine starts intent owners unlinked, so
  they outlive the engine) or a fresh `:fenced` attestation from
  `fencing_proof` covering every predecessor that could still act or write,
  also on a different node. It never reuses a cached attestation keyed only by
  `run_ref`. Absent, invalid or unproven evidence returns
  `{:error, :fencing_unproven}`, starts no engine and grants neither a fresh
  nor a recovered activation (the effect-intent host's `authorize` reply
  `:fresh` or `{:recovered, generation}`).
- An active recovered intent with a recorded attempt settles `unknown`
  (`lost_outcome`) and is never sent again; a read-only recovered intent leaves
  its slot in reconciliation (README).

**Time.** The host reads `RunEngine.deadlines/1` (ELZ-423) and keeps one
correlated wake timer per Run. While paused it schedules
`min(run_deadline, pause_deadline)`, because a paused Run can reach its Run
deadline first; otherwise it schedules `run_deadline`. It re-reads the
committed deadlines before firing, and refreshes them after a start, a wake,
and each host or sink input and control. If the profile lets asynchronous
engine inputs bypass the host (for example a local-work outcome), it resamples
the deadlines and the terminal phase while the Run is live. At or after the
deadline it sends one `wake` input (a digest ID over Run, Attempt and that
deadline) with the context that the engine requires; under
`budget_rule: :pause` that is a future `pause_deadline` from the spec's
trusted context. A replaced timer produces no input.

**Leases.** The host renews each Run's lease through the live owner with
`Elzoo.RunApprovalRelease.renew/2` (ELZ-422). Lease `until` uses the lease
clock's Unix microseconds, not the engine clock's milliseconds: the host
schedules renewal in the lease clock domain, at a margin that the README
states, and stops admission by the last confirmed expiry if a renewal is not
confirmed. The host stops admission for that Run (`{:error, :lease_lost}`)
and fences its processes on `{:refused, {:lease_lost, refusal}}`,
`{:refused, {:fenced, facts}}`, `{:indeterminate, receipt}` or
`{:unknown, :no_receipt}` (each of these stops the owner), and calls
`on_lost.(run_ref, reason)`. Only the indeterminate result supplies a receipt
for `reconcile:` at a later start. A host that tries to start or wake a Run
whose lease another live owner holds is refused and starts no engine.

Paths: `pieces/assembly/run-host/**` (new). Before the claim the coordinator
publishes its `planned` `registry/catalogue.json` row (phase P13) and its
`docs/plans/release-plan.json` `entries` row with `job: ELZ-421`; this new
Piece is the job's one primary output. In the last commit: those rows (ready,
manifest, `manifest_sha256`, `note` equal to the `contract`) and the generated
files, regenerated from current `main` and never hand-merged. No other Piece
changes. The manifest declares the Pieces that the copied tests need:
`assembly/run-engine`, `workflow/run-approval-release`, `workflow/agent-loop`,
`integration/ai-text`, `integration/ai-text-anthropic` (its Req stub test
support), `integration/sql` and the rest of their closure.

## Acceptance

Tests of this Piece. The README names which scenarios run on PostgreSQL and
which on Memory; a full Memory scenario configures the shared Memory
namespace's fold and limits for every required write, and uses one shared
manual-clock Lease backend and EffectIntent's explicit
`allow_volatile: true`.

- End to end: an AgentLoop Run with the scripted stub of
  `integration/ai-text-anthropic`: `start_run/3`, then the typed AgentLoop
  `start` through `input/5`, gives an answer; `result/4` returns the completed
  record before `reap/2` and `{:error, :not_running}` after it.
- A model call that does not complete ends the Run `:failed` (ELZ-420) with
  no host cancel; `result/4` returns `{:failed, record}` before reap and
  `{:error, :not_running}` after it.
- Crash and wake: block the stub after it records entering the call and
  before the sink delivery. Test same-node confirmed teardown, and a remote
  expired-lease takeover with independently demonstrated predecessor fencing:
  in each, the stub is called exactly once in total, the slot settles
  `unknown` once (`lost_outcome`, not resent), and the Run is readable as
  `:failed` (`model_call_not_completed`). Also test lease expiry alone, with
  no proof: `{:error, :fencing_unproven}`, no grant and no new send. Test the
  same predecessor check on an interrupted `start_run/3` retry that opens an
  existing journal: with no proof it is `{:error, :fencing_unproven}` and no
  engine starts.
- Routing: for startup routing, use an untried intent first dispatched
  during wake. Deliver its outcome before route verification, then prove that
  it is buffered and settles exactly once after verification. The
  recorded-attempt crash case above stays separate: it settles `lost_outcome`
  and is not resent.
- Admission refusal: a request with an image part is settled refused, with no
  intent and no stub call.
- A duplicate sink delivery gives one settlement. A timeout gives `dispatch`
  `"unknown"` and no `actual`. A `{:sink_failed, _}` gives no input, and no
  delivery gives no settlement. Under `budget_rule: :pause`, the first sink
  outcome settles, and its duplicate is recognized even after the trusted
  context would supply a different pause deadline.
- Capacity: with `max_runs` Runs held (one terminal and not reaped, one with a
  sleeping Unit), one more start is `{:error, :capacity}`. After `reap/2` no
  process of that Run remains (count them before and after), its lease is
  released, and a start succeeds.
- Lease fencing: two hosts with distinct owner IDs on the same PostgreSQL
  lease key (on separate nodes if one host per node is enforced by
  registration): the second `start_run/3` or `wake/2` is refused with the
  lease refusal and starts no engine. On Memory: one shared Lease backend, and
  the actual lease refusal, not a duplicate-backend error.
- Renewal: a Run that lives through several TTLs keeps writing, with renewal
  scheduled on the lease clock; a lost renewal stops admission for that Run
  and fences it.
- Deadlines: an idle Run past its deadline ends `:out_of_time` through the
  host's own wake. While paused, both orderings: the Run deadline before the
  pause deadline, and the pause deadline first (for example one set inside
  the engine by a Budget exhaustion under `budget_rule: :pause`); each ends
  the Run at the earlier one. A `continue` that replaces the Run deadline
  moves the timer, and the replaced timer produces no input.
- Fingerprint: a `spec` callback that changes the gate version or the request
  cap at wake gives `{:error, :incompatible_recovery}` for that Run, its Unit is
  confirmed stopped, and another Run in the same batch wakes.
- Wake dispositions: a batch with a Run that has no current Attempt and a Run
  whose lease another owner holds gives one disposition for each Run, starts
  no engine for those two, and leaves no process of them behind.
- The small gate, including the run of this new Piece alone in its own copied
  consumer (its tests must fit that run's 300 s limit):
  `mix check --piece "$(git merge-base origin/main HEAD)"` and
  `git diff --check` exit 0. The hosted check is green on the exact head.
- One independent review by the strongest available model of another family
  (the Piece holds leases, recovery and external effects), and the exact-head
  automated review with its threads answered and resolved, or the authorized
  replacement review under `AGENTS.md` section 6.
