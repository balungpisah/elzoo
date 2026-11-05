# Orchestration references and reuse candidates

Reviewed 2026-11-05 for ELZ-014. This is a bounded source/document study, not
an upstream security audit, benchmark, test run or endorsement. No reference
application or install script was executed; no source was copied into Elzoo.
Observations below motivate contracts to test, not already available Elzoo
behavior. These repositories can change quickly, so links use exact revisions.

## Snapshots and scope

- OpenMausBot: `e7317a7fd23495ce6cb159279aa0ef9b8f086b06`.
  Read the runtime public types, admission/restart/report paths, store interface,
  invariants/scenario tests, provider capability and approval-level policies,
  README and licensing. Desktop/browser/enterprise integrations were not audited.
- iii: `e3aa823e7eadc38e0161de1344b77de29a7d5e86`.
  Read function/trigger registry types, queue message representation, observer
  event-source handling and namespace authorization structures; channel/sandbox
  documentation and licenses. No Rust engine or distributed deployment was run.
- iii workers: `c8daa5406030b36b3a28a3e9c5dacd5bfa1aa287`.
  Followed the main repository's link to its separate worker catalogue. Read
  harness, approval-gate, queue and cron READMEs. These are documented contracts,
  not implementation or durability verification. The main repo's current
  [orchestration-loop tutorial](https://github.com/iii-hq/iii/blob/e3aa823e7eadc38e0161de1344b77de29a7d5e86/docs/tutorials/build-an-agent/orchestration-loop.mdx)
  is a placeholder at this revision; it was not treated as implementation evidence.

- Raxol: `c1085f4b8bd4c426268fd6321c462de0df254aa9` (2026-11-02; Hex `raxol`
  2.7.0 observed 2026-11-05). Reviewed 2026-11-06 for ELZ-021 as a design
  reference for agent-harness safety boundaries. Read the harness
  architecture/doctrine docs, the agentic-commerce, agent-framework, MCP and
  gateway feature docs, and the moduledocs of the spend gate, payments ledger
  and checkpoint, authorization engine and blast-radius gate, projection and
  recovery, journal reader and hash chain, event boundary, command decoder,
  steer, interrupt, stall detector, stream cadence, pairing and the golden-corpus
  CI script. Nothing was executed or vendored. Terminal/LiveView renderers,
  crypto payment protocols, swarm, memory and self-improvement subsystems were
  read only far enough to classify them as out of scope.

## OpenMausBot: responsibilities worth separating

| Observed source | What it exposes | Elzoo design implication |
| --- | --- | --- |
| [runtime/types.ts](https://github.com/milind-soni/OpenMausBot/blob/e7317a7fd23495ce6cb159279aa0ef9b8f086b06/server/runtime/types.ts#L1) | Assignment origin, requester/assignee, parent/root/depth, lifecycle status, typed outcomes, executions, evidence, inbox and limits | Separate work identity, execution lifecycle, result delivery and capability policy; do not copy the entire Assignment record as a universal Task |
| [runtime.ts admission](https://github.com/milind-soni/OpenMausBot/blob/e7317a7fd23495ce6cb159279aa0ef9b8f086b06/server/runtime/runtime.ts#L175) | Requires a running parent, detects repeated requests under a parent, rejects ancestor delegation, enforces depth/request budgets | `workflow/run`, `workflow/dependency-graph`, `workflow/budget`; declare request identity and graph rules explicitly rather than deduplicate arbitrary natural-language requests by resemblance |
| [store interface](https://github.com/milind-soni/OpenMausBot/blob/e7317a7fd23495ce6cb159279aa0ef9b8f086b06/server/runtime/store.ts#L90) and [invariants](https://github.com/milind-soni/OpenMausBot/blob/e7317a7fd23495ce6cb159279aa0ef9b8f086b06/server/runtime/invariants.ts#L1) | Transactional assignment/event/inbox operations; checks for terminal outcomes, replay agreement, report/wake counts and parent consistency | State transition and durable result publication need an atomic boundary; use existing transactional storage plus outbox semantics |
| [runtime restart paths](https://github.com/milind-soni/OpenMausBot/blob/e7317a7fd23495ce6cb159279aa0ef9b8f086b06/server/runtime/runtime.ts#L50) and [scenario tests](https://github.com/milind-soni/OpenMausBot/blob/e7317a7fd23495ce6cb159279aa0ef9b8f086b06/server/runtime/scenarios.test.ts#L1775) | Recovery distinguishes interrupted work and recorded outward actions; scenario tests cover restarting, continuations and stalled loops | Effect recovery must account for unknown outcomes. A missing/erroring outward-action signal is not sufficient evidence to safely retry a payment or publish operation |
| [capabilities](https://github.com/milind-soni/OpenMausBot/blob/e7317a7fd23495ce6cb159279aa0ef9b8f086b06/server/runtime/capabilities.ts#L1) and [level policy](https://github.com/milind-soni/OpenMausBot/blob/e7317a7fd23495ce6cb159279aa0ef9b8f086b06/server/runtime/level.ts#L1) | Provider-specific resume/approval capabilities and a policy for inherited levels | Represent capabilities explicitly. Authorization/delegation limits belong in a contract; do not silently upgrade a less capable provider or inherit another product's permission policy |
| [clock and limits](https://github.com/milind-soni/OpenMausBot/blob/e7317a7fd23495ce6cb159279aa0ef9b8f086b06/server/runtime/types.ts#L319) and [fake-runner scenarios](https://github.com/milind-soni/OpenMausBot/blob/e7317a7fd23495ce6cb159279aa0ef9b8f086b06/server/runtime/scenarios.test.ts#L1) | Injected wall/monotonic time, bounded work/wakes and a fake runner for lifecycle scenarios | Time is an input to policy; use deterministic simulations for cancellation, late results, restart and budget exhaustion |

The useful reuse is functional: bounded execution, correlated results, explicit
consent, recovery and evidence. OpenMausBot's chat UI, roles such as Chief of
Staff, provider preferences and specific restart/permission policies are product
choices. A finite invariant-checking test suite is not a universal proof.

## iii: uniform discovery without erased semantics

| Observed source | What it exposes | Elzoo design implication |
| --- | --- | --- |
| [README primitives](https://github.com/iii-hq/iii/blob/e3aa823e7eadc38e0161de1344b77de29a7d5e86/README.md#three-primitives) and [Function](https://github.com/iii-hq/iii/blob/e3aa823e7eadc38e0161de1344b77de29a7d5e86/engine/src/function.rs#L20) | Workers register named functions with request/response formats and metadata | Explicit interfaces and capability metadata improve composition; static source selection does not require a live global registry |
| [TriggerRegistry](https://github.com/iii-hq/iii/blob/e3aa823e7eadc38e0161de1344b77de29a7d5e86/engine/src/trigger.rs#L20) | Different trigger providers, namespaced registration and deferred bindings | Trigger sources can share a normalized invocation boundary while retaining distinct readiness, delivery and lifecycle contracts |
| [QueueMessage](https://github.com/iii-hq/iii/blob/e3aa823e7eadc38e0161de1344b77de29a7d5e86/engine/src/workers/queue/message.rs#L10) | Delivery tag, function/payload, attempt, message identity, trace context and target namespace | Preserve identity, tenant scope and tracing through adapters; a common payload shape alone does not define ack/retry behavior |
| [event-source functions](https://github.com/iii-hq/iii/blob/e3aa823e7eadc38e0161de1344b77de29a7d5e86/engine/src/observer/events.rs#L10) | Engine-owned event sources cannot be invoked as ordinary business functions | A notification and a command carry different authority and meaning even if both are messages |
| [channel documentation](https://github.com/iii-hq/iii/blob/e3aa823e7eadc38e0161de1344b77de29a7d5e86/docs/understanding-iii/channels.mdx) | References coordinate streaming bytes separately from JSON invocation payloads; ownership/disconnect and backpressure rules are documented | Keep `delivery/data-stream` and `state/artifact` separate from control messages and Enum/Stream transformations |
| [authorization structure](https://github.com/iii-hq/iii/blob/e3aa823e7eadc38e0161de1344b77de29a7d5e86/engine/src/workers/worker/rbac_session.rs#L30) | Namespace grants, allowed/forbidden function sets and registration permissions | Catalogue discovery is not permission to call; define scoped authority and revocation. This study does not certify enforcement across every route |
| [sandbox documentation](https://github.com/iii-hq/iii/blob/e3aa823e7eadc38e0161de1344b77de29a7d5e86/docs/creating-workers/sandboxes.mdx) | VM lifecycle, allowlisted image names, exec limits and cleanup | Isolation is an explicit provider capability. A BEAM process is not an untrusted-code sandbox |
| [worker harness README](https://github.com/iii-hq/workers/blob/c8daa5406030b36b3a28a3e9c5dacd5bfa1aa287/harness/README.md) | Documents session/context/model workers, resumable turns, per-session queueing and controlled tool invocation | Compose orchestration from context, execution, approval, provider and storage responsibilities; verify the recovery claims if adopting any implementation |
| [approval-gate README](https://github.com/iii-hq/workers/blob/c8daa5406030b36b3a28a3e9c5dacd5bfa1aa287/approval-gate/README.md) | Continue/deny/hold; ephemeral pending index; events documented as at-most-once and unordered; reconciliation after gaps | Approval state, authorization and notification are distinct. A financial approval may require a different retained decision contract; a UI event cannot be its source of truth |
| [queue README](https://github.com/iii-hq/workers/blob/c8daa5406030b36b3a28a3e9c5dacd5bfa1aa287/queue/README.md) versus [cron README](https://github.com/iii-hq/workers/blob/c8daa5406030b36b3a28a3e9c5dacd5bfa1aa287/cron/README.md) | Queue documents ack/retry/DLQ; cron documents scheduled and actual fire times | A shared call/observer surface must preserve each source's different delivery and timing semantics |

Elzoo can aim for smaller consumer dependencies and more explicit claim-level
grounding. It cannot claim to outperform either project without implementing
and measuring comparable assemblies. We do not import iii's engine into the
composition core or automatically permit agents to install runtime capabilities.

## Raxol: safety boundaries of an agent harness

Raxol is a multi-surface TEA/OTP runtime with an agent harness, chat gateways
and crypto payment rails. It sits on a different layer from Ash (ADR-0005) and
is not adopted: at 2.7.0 the umbrella declared 38 dependencies and the
repository showed one dominant contributor (Hex and GitHub metadata, observed
2026-11-05). The transferable material is its set of safety and consistency
boundaries, which Elzoo expresses as Contracts and design tests, not as code.

| Observed source | What it exposes | Elzoo design implication |
| --- | --- | --- |
| [spend gate](https://github.com/DROOdotFOO/raxol/blob/c1085f4b8bd4c426268fd6321c462de0df254aa9/packages/raxol_agent/lib/raxol/agent/spend_gate.ex) and [ledger](https://github.com/DROOdotFOO/raxol/blob/c1085f4b8bd4c426268fd6321c462de0df254aa9/packages/raxol_payments/lib/raxol/payments/ledger.ex) | Every spend-bearing call journals reserve → call → settle under one `cost_ref`; cap check and reservation are one step; the refund is derived from the (reservation, actual) pair; no reserve, no call; a missing policy fails closed in a release | `workflow/budget` admission record in ELZ-022: one-step check-and-reserve behind one interface, idempotent settle/release per reference, unit-tagged cost that is not money settlement. Answers the C2/C9 concurrent-reservation design tests |
| [payments checkpoint](https://github.com/DROOdotFOO/raxol/blob/c1085f4b8bd4c426268fd6321c462de0df254aa9/packages/raxol_payments/lib/raxol/payments/checkpoint.ex) and [agentic commerce doc](https://github.com/DROOdotFOO/raxol/blob/c1085f4b8bd4c426268fd6321c462de0df254aa9/docs/features/AGENTIC_COMMERCE.md) | Persist the dispatched intent under a key derived from the logical request before signing/sending; on resume find and poll the existing intent instead of re-executing; a poll that never terminates is an explicit `stranded` outcome; a missing store is a hard error in production | New deferred handle `delivery/effect-intent` with its admission record in ELZ-023: only a definite failure re-arms dispatch; timeout is unknown and reconciled. It is the mechanism behind the C3/C6/C9 unknown-outcome design tests |
| [authorization engine](https://github.com/DROOdotFOO/raxol/blob/c1085f4b8bd4c426268fd6321c462de0df254aa9/packages/raxol_agent/lib/raxol/agent/authorization/engine.ex) and [blast-radius gate](https://github.com/DROOdotFOO/raxol/blob/c1085f4b8bd4c426268fd6321c462de0df254aa9/packages/raxol_agent/lib/raxol/agent/authorization/blast_radius_gate.ex) | A pure fold over ordered policies yields ALLOW, ASK or DENY; DENY short-circuits, ALLOW merges permitted writes, ASK escrows writes and accumulates a prompt; approval is remembered within a scope (once, session, root) and live state rebuilds from decision events; write/destructive tools are locked by default and the doc warns a string denylist is incomplete | ELZ-024 keeps `domain/authorization` (reducer) and `workflow/approval` (consent bound to actor, resource, exact payload and policy version) as two Pieces; Ash policies cover direct allow/deny, so only the ASK/escrow/scope remainder is authored. Gate on typed effect class, not on text |
| [projection](https://github.com/DROOdotFOO/raxol/blob/c1085f4b8bd4c426268fd6321c462de0df254aa9/lib/raxol/harness/projection.ex) and [recovery](https://github.com/DROOdotFOO/raxol/blob/c1085f4b8bd4c426268fd6321c462de0df254aa9/lib/raxol/harness/projection/recovery.ex) | The journal is the only truth and every surface is a disposable fold; seek-to-offset is a refold of a prefix; duplicate and out-of-order ids are dropped; a forward gap keeps survivors but marks the model damaged and emits telemetry; durable events are journaled before any surface sees them and the one ephemeral event must be reconstructable from its durable completion | ELZ-009 `state/event-log` Contract text and design tests: deterministic prefix refold, explicit duplicate/gap policy, distinct durable and reconstructable-ephemeral tiers. Replay and time-travel need no extra Piece |
| [journal reader](https://github.com/DROOdotFOO/raxol/blob/c1085f4b8bd4c426268fd6321c462de0df254aa9/packages/raxol_agent/lib/raxol/agent/journal/file_store/reader.ex) and [hash chain](https://github.com/DROOdotFOO/raxol/blob/c1085f4b8bd4c426268fd6321c462de0df254aa9/packages/raxol_agent/lib/raxol/agent/journal/chain.ex) | A parse failure on the final record is a torn tail: tolerated in memory, repaired only by the owning writer at boot; a failure anywhere else is damaged with the longest valid prefix and nothing deleted; readers never truncate a live journal; an optional per-record hash chain is defined over canonical JSON so any decoder can recompute it | ELZ-009 design tests: torn tail versus interior corruption, reads never write, longest valid prefix. Integrity chaining is a recorded decision for `state/audit-log`, not a default implementation or a new file format |
| [event boundary](https://github.com/DROOdotFOO/raxol/blob/c1085f4b8bd4c426268fd6321c462de0df254aa9/lib/raxol/harness/event_boundary.ex) and [command decoder](https://github.com/DROOdotFOO/raxol/blob/c1085f4b8bd4c426268fd6321c462de0df254aa9/packages/raxol_agent/lib/raxol/agent/command.ex) | Anything crossing an uncontrolled process boundary is untrusted input: no atom minted from a wire string, unknown fields dropped, ambiguous provenance collapses to tainted, a field deciding durability is rejected rather than guessed; unknown kinds render as opaque instead of failing the surface | ELZ-011 Adapter design tests for `runtime/adapter` and `core/envelope` consumers: total, idempotent normalization that never raises trust. Concrete form of "model output is an untrusted proposal" |
| [golden-corpus check](https://github.com/DROOdotFOO/raxol/blob/c1085f4b8bd4c426268fd6321c462de0df254aa9/scripts/check_journal_goldens.exs) | Each journal schema version freezes a corpus written while it was current; CI fails when the current version has no frozen corpus, a pinned corpus changed byte-for-byte or an unpinned corpus exists; snapshot bytes depend on content only | ELZ-010 `state/schema-evolution` evidence rule: upcasters are tested against corpora an older writer actually wrote, never against fixtures regenerated by the current writer |
| [steer](https://github.com/DROOdotFOO/raxol/blob/c1085f4b8bd4c426268fd6321c462de0df254aa9/packages/raxol_agent/lib/raxol/agent/steer.ex), [interrupt](https://github.com/DROOdotFOO/raxol/blob/c1085f4b8bd4c426268fd6321c462de0df254aa9/packages/raxol_agent/lib/raxol/agent/interrupt.ex) and [stall detector](https://github.com/DROOdotFOO/raxol/blob/c1085f4b8bd4c426268fd6321c462de0df254aa9/lib/raxol/harness/stall_detector.ex) | Steer is a pure decision on an expected turn id plus a client message id, with caller serialization named as an obligation; interrupt escalates cooperative signal → bounded wait → OS process-group kill, each stage a journaled event with OS-level death confirmation; the stall detector takes observations in and verdicts out, owns no clock, keeps its escalation budget separate from transport retries and never auto-recovers | `workflow/run` cancellation and `integration/agent-runner` design tests: a redirect names the attempt it targets and a stale target changes nothing; cancellation stages are observable records; liveness verdicts are pure and distinct from retry policy. Shell work, no Cure proof demanded |
| [stream cadence](https://github.com/DROOdotFOO/raxol/blob/c1085f4b8bd4c426268fd6321c462de0df254aa9/lib/raxol/harness/stream_cadence.ex) | Render cadence sheds newest-wins deltas above a watermark instead of pushing backpressure to the network reader; documented as sound only because deltas are reconstructable from the durable completion event | ELZ-006 `delivery/backpressure`: shedding is an admissible policy only where the Contract shows the dropped items are reconstructable; otherwise it is silent loss |
| [pairing](https://github.com/DROOdotFOO/raxol/blob/c1085f4b8bd4c426268fd6321c462de0df254aa9/packages/raxol_gateway/lib/raxol/gateway/pairing.ex) and [session router](https://github.com/DROOdotFOO/raxol/blob/c1085f4b8bd4c426268fd6321c462de0df254aa9/packages/raxol_gateway/lib/raxol/gateway/session_router.ex) | Pairing admits by user-id string across platforms and documents that platform id namespaces are unrelated; handoff rebinds a conversation to another route while history follows the conversation id | Negative example for `domain/principal` (a chat platform id and an email are not one principal) and a positive one for `delivery/routing`: conversation identity is not the delivery route |

Not taken: the component-tree-to-MCP-tool projection and focus lens (UI-bound;
AshAi already exposes actions as tools in the ELZ-015 spike, and tool
discovery never itself authorizes execution), the x402/MPP/Permit2/Xochi
payment protocols, ZKSAR tiers and mandate envelopes (protocol-specific), the
libcluster/CRDT swarm (`state/crdt` stays deferred; take an upstream CRDT
library when an Assembly needs one), memory and self-improvement (product-level
model behaviour), recording/replay and time-travel debugging (consequences of
the pure fold above) and the terminal, LiveView, SSH, speech and Telegram
surfaces. Raxol's own split of a payments ledger from an agent spend gate is a
reason to carry one budget Piece with unit tags rather than two copies.

## License boundaries

OpenMausBot's [LICENSING.md](https://github.com/milind-soni/OpenMausBot/blob/e7317a7fd23495ce6cb159279aa0ef9b8f086b06/LICENSING.md) says its ordinary code is
Apache-2.0, with an enterprise/ carve-out and separately licensed third-party
material. The inspected server/runtime files are outside enterprise/.
The iii [license table](https://github.com/iii-hq/iii/blob/e3aa823e7eadc38e0161de1344b77de29a7d5e86/README.md#license) and [engine license](https://github.com/iii-hq/iii/blob/e3aa823e7eadc38e0161de1344b77de29a7d5e86/engine/LICENSE)
distinguish the Elastic License 2.0 engine/CLI from Apache-2.0 SDK/docs.
The workers READMEs identify Apache-2.0 for the referenced packages.
Raxol's [LICENSE.md](https://github.com/DROOdotFOO/raxol/blob/c1085f4b8bd4c426268fd6321c462de0df254aa9/LICENSE.md) and mix.exs declare MIT at the
pinned revision; only prose observations were taken.
These are design references; none has been vendored or relicensed as Elzoo code.
Any future adoption must check the exact package/file licenses and notices.

## Elixir candidate discovery

The following metadata was read from the Hex package API on 2026-11-05;
version-specific release endpoints were also checked and are linked below.
Package descriptions and metadata are dated observations, not immutable source
snapshots like the Git revisions above.
Versions are observed stable releases, **not** selected dependency pins.
No package below is added by ELZ-014. Metadata establishes existence and stated
purpose; API suitability, maintenance, version compatibility, license scope
and the required failure behavior still need checking during adoption.

| Candidate / observed stable version | Candidate scope | What Elzoo must still decide/test |
| --- | --- | --- |
| [decimal 3.2.0](https://hex.pm/api/packages/decimal/releases/3.2.0) | Decimal arithmetic | Rounding, scale and conversion boundaries; arithmetic is not a journal or payment system |
| [ex_money 6.3.0](https://hex.pm/api/packages/ex_money/releases/6.3.0) | Currency amounts and monetary operations | Currency mismatch, allocation residuals and rounding policy; exact units survive persistence and adapters |
| [ecto_sql 3.14.0](https://hex.pm/api/packages/ecto_sql/releases/3.14.0) | SQL adapters, migrations and transactions | Atomic state/outbox or journal writes, isolation, contention and rollback; not an automatic audit or ledger contract |
| [oban 2.24.2](https://hex.pm/api/packages/oban/releases/2.24.2) | Persistent jobs and retries | Crash/redelivery/cancel/uniqueness behavior with the selected backend; job retry does not prove idempotent business effects |
| [ash_authentication 4.15.1](https://hex.pm/api/packages/ash_authentication/releases/4.15.1) | Authentication when the consumer already chooses Ash | Resource/framework dependency cost, session/revocation/account-linking behavior; not authorization policy |
| [bodyguard 2.4.3](https://hex.pm/api/packages/bodyguard/releases/2.4.3) | Application authorization callbacks | Tenant/resource scoping, deny precedence and revocation; identity and policy remain application responsibilities |
| [hammer 7.5.1](https://hex.pm/api/packages/hammer/releases/7.5.1) | Rate limiting | Time window, backend consistency and concurrent admission; not a monthly quota or a financial balance |
| [libgraph 0.17.1](https://hex.pm/api/packages/libgraph/releases/0.17.1) | Graph representation and algorithms | Cycle rejection/readiness semantics; graph utilities do not execute durable workflows |
| [req_llm 1.30.0](https://hex.pm/api/packages/req_llm/releases/1.30.0) | LLM provider integration built on Req/Finch | Structured output validation, timeout, partial streaming, usage reporting and tool-call translation |
| [jido 2.4.0](https://hex.pm/api/packages/jido/releases/2.4.0) | Existing Elixir actor/agent framework | Compare its action/directive/runtime contracts with our needs before building overlapping orchestration; do not adopt a second mandatory host merely for a few helpers |
| [swoosh 1.29.3](https://hex.pm/api/packages/swoosh/releases/1.29.3) | Email composition and provider delivery | Provider errors, duplicates, notification preferences and separation of acceptance from actual delivery |

Jason, Req, selected OTP APIs and Enum/Stream already have narrow executable
Recipes in the current ledger. Their existing evidence does not automatically
cover new identity, payment, durable workflow or agent-runner behavior. Use
provider candidates in this study as research leads, not as “library-backed”
completion badges.
