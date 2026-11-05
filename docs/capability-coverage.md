# Cross-domain coverage cases

These cases test the [capability model](capability-model.md), not the current
implementation. The [Piece Ledger](../LEDGER.md) is authoritative for readiness.
Every new handle introduced by ELZ-014 is **deferred**, with no source bundle,
provider adoption or build task implied. Existing planned foundation work keeps
its task DAG. The references and candidate discovery are recorded in the
[research study](research/orchestration-references.md).

“Coverage” means we can identify the responsibilities, shared contracts and
missing evidence for a representative workflow. It does not mean the product
can already be built from ready Pieces or that all regulatory/product needs
are covered. In particular, money and identity remain unimplemented contracts.

## Representative assemblies and dangerous failures

### C1 — Invite a user to a SaaS tenant

Flow: authenticated inviter → scoped authorization → invitation → notification
→ recipient acceptance → atomic membership activation → attributable record.

Capability IDs: `domain/principal`, `domain/membership`, `domain/authorization`,
`workflow/approval` (only if the product requires separate consent),
`integration/identity`, `integration/notification`, `integration/secrets`,
`state/audit-log`, `state/outbox`, `delivery/trigger`, `delivery/idempotency`.
This can be a slice of `assembly/tenant-edge`.

The identity provider authenticates; membership states which tenant is joined;
authorization determines who may invite and which role may be assigned. An
approval is consent, not an identity or role grant. Invitation tokens need
purpose, expiry, single-use and tenant binding. Do not implement password or
cryptographic protocols merely to fill this case.

Design tests: replayed acceptance cannot create a second membership; a revoked
inviter or changed target role cannot reuse stale authority; cross-tenant token
use is refused; crash after membership commit does not silently lose its
notification. Evidence needs tenant/adversarial and transactional integration
tests, not only a signed token or a UI check.

### C2 — Meter and execute a SaaS report

Flow: principal + tenant → entitlement → authorize → reserve allocation →
enqueue run → produce artifact → settle observed usage → release unused budget.

Capability IDs: `domain/principal`, `domain/membership`, `domain/authorization`,
`domain/entitlement`, `domain/quota`, `workflow/budget`, `workflow/run`,
`state/lease`, `state/artifact`, `state/outbox`, `integration/jobs`,
`integration/object-store`, `delivery/backpressure`.
Composes `assembly/tenant-edge` with `assembly/durable-job`.

Quota is a tenant's allocation/reset policy. A run budget bounds this report's
cost. Rate limiting bounds admission over time, and queue capacity protects the
system; none substitutes for the others. A read-then-increment counter is not a
concurrency-safe reservation.

Design tests: concurrent requests cannot both spend the last reserved unit;
duplicate job delivery cannot double-meter; an expired lease cannot overwrite
a replacement's artifact; cancellation does not erase already observed usage;
an entitlement revoked while queued is re-evaluated at the chosen boundary.
Reuse storage/jobs/rate-limit mechanisms, and keep the product's billing policy
explicit. No promise of strict monetary budget enforcement without provider
usage and maximum-charge bounds.

### C3 — Approve a refund and reconcile the payment

Flow: original payment identity → validate refund amount → authorize → optional
approval → persist operation/outbox → call provider → observe or reconcile
result → update payment lifecycle and journal.

Capability IDs: `domain/money`, `domain/authorization`, `domain/payment-lifecycle`,
`domain/journal`, `workflow/approval`, `state/outbox`, `state/audit-log`,
`integration/payments`, `integration/secrets`, `integration/http`,
`delivery/idempotency`, `delivery/retry-timeout`.
A candidate slice of `assembly/ledger-checkout`.

Design tests: reject currency mismatch and over-refund; two concurrent refunds
cannot exceed the allowed amount; duplicate/out-of-order provider webhooks do
not apply a financial posting twice; a timed-out request is unknown until
reconciled; changing amount/currency/recipient invalidates an earlier approval.
A local balanced journal does not prove the external provider settled a payment.
The ready HTTP recipe is transport evidence only. Choose an actual provider
before specifying capture/refund/idempotency semantics.

### C4 — Post and reverse an internal transfer

Flow: validate same-currency postings → atomically post a balanced journal entry
under one operation ID → derive balances → correct through a linked reversal.

Capability IDs: `domain/money`, `domain/journal`, `integration/sql`,
`state/audit-log`, `state/schema-evolution`.
Another candidate slice of `assembly/ledger-checkout`, with no required payment
provider. A journal account is not a user account or tenant membership.

Design tests: total postings balance within each currency; duplicates do not
post twice; a crash cannot commit only one side; concurrent balance constraints
hold at the selected database isolation boundary; rounding/allocation residuals
are explicit; corrections preserve history. Pure arithmetic may support selected
proofs, while database atomicity/recovery needs provider and integration evidence.
Do not split debit and credit into independent public effectful Pieces.

### C5 — Coordinate human and automated tasks

Flow: create work item with acceptance criterion → resolve prerequisites →
assign/claim → run human or automated work → review result → accept completion
→ notify dependants.

Capability IDs: `workflow/work-item`, `workflow/dependency-graph`, `workflow/run`,
`workflow/approval`, `state/lease`, `state/artifact`, `state/outbox`,
`integration/notification`, `delivery/aggregation`.
Candidate Assembly: `assembly/task-workflow`.

Design tests: reject cycles where the contract requires a DAG; a worker that
lost its lease cannot complete the new owner's attempt; duplicated completion
notices do not reopen or double-complete work; failed prerequisites follow an
explicit block/skip/fail policy; cancelling an attempt does not automatically
cancel the business request. Human acceptance and program exit status are not
the same fact. Products choose status names and completion rules.

### C6 — Delegate, review and publish with agents

Flow: work item → capability/authority check → bounded child runs → provider
sessions → collect results/artifacts → independent acceptance → approve the
specific publication when required → explicit publish Effect.

Capability IDs: `workflow/work-item`, `workflow/run`, `workflow/dependency-graph`,
`workflow/budget`, `workflow/approval`, `workflow/context-selection`,
`domain/principal`, `domain/authorization`, `state/lease`, `state/artifact`,
`state/audit-log`, `state/outbox`, `integration/ai-model`,
`integration/agent-runner`, `integration/secrets`, `runtime/os-isolation`,
`delivery/request-reply`, `delivery/aggregation`, `delivery/retry-timeout`.
Candidate Assembly: `assembly/agent-product`.

Design tests: bounded fan-out/depth/cost; no authority escalation through
children or generated tool arguments; parent result/wakeup survives restart;
late output from a cancelled attempt is ignored or explicitly reconciled;
unsupported resume capability fails explicitly; unknown publish outcome is
reconciled before rerun; model text saying “done” is not accepted as a test or
execution receipt. Tool discovery never itself authorizes execution.

The shared mechanism may also coordinate people or deterministic workers.
Provider context, model judgment and business acceptance stay separate. A
second agent's opinion is review evidence, not a mathematical proof or a
substitute for executable acceptance checks.

### C7 — Run scheduled research and deliver a digest

Flow: schedule/webhook → deduplicated run → scoped context retrieval → bounded
model/tool calls → incremental output → retained result → notification.

Capability IDs: `delivery/trigger`, `delivery/time`, `state/scheduler`,
`workflow/run`, `workflow/dependency-graph`, `workflow/budget`, `domain/quota`,
`workflow/context-selection`, `state/artifact`, `state/outbox`,
`integration/ai-model`, `integration/agent-runner`, `integration/search-data`,
`integration/secrets`, `integration/notification`, `delivery/idempotency`,
`delivery/data-stream`.
Uses `assembly/durable-job` and the proposed `assembly/agent-product`.

Design tests: overlapping schedules follow an explicit skip/queue/replace
policy; retries preserve occurrence identity; partial model output is marked
partial; removed access excludes a document from later context; token estimates
and observed provider usage are not conflated; restart recovers the result and
notification decision. Memory is retained information with provenance and
access rules, not a guarantee that the model remembers or tells the truth.

### C8 — Upload and transform an artifact

Flow: entitlement/authorization → bounded byte transfer → content validation →
store reference → background transform → result artifact → download authorization.

Capability IDs: `domain/entitlement`, `domain/authorization`, `state/artifact`,
`delivery/data-stream`, `delivery/backpressure`, `integration/object-store`,
`integration/jobs`, `workflow/run`, `state/outbox`.
A slice of `assembly/data-pipeline`.

Design tests: bounded buffering, producer/consumer disconnects, incomplete-upload
cleanup, integrity mismatch, stale signed URL/access revocation, duplicate job
completion and retention expiry. A content hash is an integrity identifier, not
permission to read; the ready SHA-256 recipe alone does not implement this case.

## Reuse map and limits

| Responsibility | Shared cases | Existing usable subset | Missing contract / reuse direction |
| --- | --- | --- | --- |
| Pure composition and duplicate decisions | C1–C8 as needed | core/operator; volatile exact-key delivery/idempotency | Durable operation/attempt identities and replay policy; no universal exactly-once claim |
| Process lifecycle and local primitives | C2/C5/C6/C7/C8 | runtime/unit, runtime/supervision, runtime/registry, delivery/time | Durable scheduling/lease semantics and bounded admission; evaluate OTP + job/storage providers |
| Provider transport and representation | C1/C3/C6/C7/C8 | integration/http, integration/json; optional integration/cure-json | Authentication/payment/runner/notification translation and failure contracts |
| Actor, scope and authority | C1/C2/C3/C6/C8 | None | domain/principal, membership, authorization; reuse identity/policy implementations |
| Resource accounting | C2/C6/C7 | None | domain/quota and workflow/budget; preserve distinct units/reset/consistency |
| Money and balanced posting | C3/C4 | None | domain/money, domain/journal; evaluate Decimal/ex_money and transactional/provider storage |
| Work, execution and dependency readiness | C2/C5/C6/C7/C8 | Only a small synchronous example Assembly | workflow/work-item, run, dependency-graph and state/lease; evaluate Oban/Jido/libgraph where their contracts fit |
| Exact-action approval | C1/C3/C5/C6 | None | workflow/approval plus current authorization and durable decision evidence |
| Data, recovery and attribution | C1–C8 as needed | JSON and SHA-256 helpers only | artifacts, byte streams, audit, outbox and selected store; no implicit durability from helpers |
| Model/agent-specific boundaries | C6/C7 | None | integration/ai-model, integration/agent-runner, workflow/context-selection; compare existing ecosystem libraries first |

The ready Enum/Stream recipe remains useful for ordinary transformations, but
is neither a durable scheduler nor a network byte stream. No ready bundle was
upgraded by this study, and none of these complete workflows is claimed ready.
The umbrella handles domain/value-types, domain/saas-controls and
integration/auth-policy retain their existing IDs; they group or translate the
narrower contracts rather than authorizing duplicate engines.

## Choosing the next build slice

First finish the existing composition/port/wiring contracts, using these cases
to expose assumptions rather than adding every field to one universal record.
Then choose the smallest useful assembly and publish its concrete task with
only its actual prerequisites. A candidate sequence to evaluate is a durable
work item plus approval, first with a deterministic worker and then with an
agent adapter. This can test shared mechanisms before introducing model failure.
It is a recommendation, not an automatic replacement of the current task DAG.

The P0–P3 tasks remain committed foundation work; demand-led inventory rows have
no promised implementation order. Money, identity and agent-specific tasks must
state their own acceptance and provider choices before an agent starts them.
Do not dispatch “implement the catalogue” or use row counts as completion.
