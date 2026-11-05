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

## License boundaries

OpenMausBot's [LICENSING.md](https://github.com/milind-soni/OpenMausBot/blob/e7317a7fd23495ce6cb159279aa0ef9b8f086b06/LICENSING.md) says its ordinary code is
Apache-2.0, with an enterprise/ carve-out and separately licensed third-party
material. The inspected server/runtime files are outside enterprise/.
The iii [license table](https://github.com/iii-hq/iii/blob/e3aa823e7eadc38e0161de1344b77de29a7d5e86/README.md#license) and [engine license](https://github.com/iii-hq/iii/blob/e3aa823e7eadc38e0161de1344b77de29a7d5e86/engine/LICENSE)
distinguish the Elastic License 2.0 engine/CLI from Apache-2.0 SDK/docs.
The workers READMEs identify Apache-2.0 for the referenced packages.
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
