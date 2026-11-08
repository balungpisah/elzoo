# Owner decisions on the ecosystem ranking — 2026-11-08

Recorded by the coordinator session from the owner's answers on 2026-11-08 (WIB). The owner
accepted the coordinator's recommended defaults: "i follow ur recommendations on the decisions."
Earlier the same day the owner set the admission rule quoted on issues #44, #45, #46 and #48:
every planned and deferred catalogue entry is open for development; "demand-led" admission
applies only to gaps outside the catalogue found during consumer work; prefer a maintained
Elixir library ("take the codes or the ideas") and build only what does not exist.

## Answers to the six open questions in ecosystem-ranking-2026-11-08.md

1. Next admitted batch: Telemetry (R03), object store (R18), notification (R20), audit log
   (R15), in that order. Then the first ReqLLM model boundary (R16), then the MCP client,
   text chunking and pgvector slices (R37, R39).
2. Storage boundary: option A, an S3-only caller behind an Adapter, req_s3 first; ExAws S3
   only if multipart or large operations require it. Jido VFS is not adopted now.
3. AI and protocol provider: the first model Adapter exercises Anthropic over the hosted API.
   The first tool boundary is an MCP client (ex_mcp). No agent-runner CLI is selected yet.
4. Identity and notifications: no identity provider is selected; identity, principal,
   auth-policy and membership wait for a product decision. The first email provider is a
   plain SMTP provider through Swoosh.
5. Retained records: the first audited mutation is the effect-intent decision record from
   ELZ-023 (pieces/delivery/effect-intent); its PostgreSQL store owns the transaction.
   Artifact integrity, access and expiry are specified separately when state/artifact is admitted.
6. Specialized demand: replication, CRDT, FHIR, media and the UI host have no current caller
   and stay conditional comparisons.

## Limits

These are admission decisions, not implementation authorization for any single task. Each task
still needs its published issue, Contract review, evidence and merge under AGENTS.md. The
license decision for "Apache-2.0 OR MPL-2.0" packages (Apache option, full closure recorded) was
taken by the coordinator session on 2026-11-08 and is recorded in the ranking document.

## Product facts for the catalogue tail (owner, 2026-11-08 afternoon WIB)

The owner accepted the coordinator's defaults ("agreed"), with one correction from the owner:
TensorZero is archived upstream and is not used. Decisions:

| # | Decision | Value | Reason |
| --- | --- | --- | --- |
| 1 | Object store provider | MinIO through the S3 API, S3-only caller (option A), req_s3 first | Runs on the owner's host; ExAws S3 only if multipart requires it |
| 2 | First model provider | ReqLLM (req_llm) calling Anthropic directly; provider key as a Need; no gateway process | TensorZero archived; the gateway's functions are catalogue Pieces (see below) |
| 3 | Identity provider | AshAuthentication in the application; OIDC strategy later | Ash is the foundation (ADR-0005); no vendor chosen |
| 4 | Agent runner | Claude Code CLI and Codex CLI as OS processes through the ELZ-029 boundary; no Elixir SDK dependency | The SDK route has a copyleft dependency |
| 5 | Payments provider | Deferred until the owner names one | Stripe is the library default; the owner's market may need Xendit or Midtrans |
| 6 | Message broker | Deferred; no caller | Broadway covers RabbitMQ, SQS and Kafka when a caller appears |
| 7 | Metering source | ReqLLM per-call usage records, stored through the ready Store | One real source before a general meter |
| 8 | Time-series and observability sink | TimescaleDB on the owner's host; OpenTelemetry export later | Already present |
| 9 | Replication, CRDT, FHIR, media | Conditional; no caller | No product needs them |
| 10 | UI host | Phoenix LiveView; the Lustre experiment stays optional | Mainstream choice |

### The model gateway is built as Pieces, not run as a service

Provider calls: integration/ai-model (ADOPT ReqLLM behind an Adapter). Model selection under
policy: delivery/model-routing (WRAP llm_db metadata with ready selection and budget). Usage:
domain/metering. Spend limits: workflow/budget (ready). Allocation: domain/quota. Tariffs:
domain/pricing. Streaming: delivery/data-stream. Retries and dead letters: ready Pieces. Provider
churn stays inside the one Adapter Piece and ReqLLM; no copy of ReqLLM is made.

### Copy, clean-room or adopt: the rule

Adopt a maintained library as a pinned dependency by default. Copy (a fork under balungpisah with
notices, docs/development/08) only for a concrete reason: the upstream is stale or archived, a
Contract change the upstream will not take, or small stable code inside heavy framework coupling.
Clean-room (take the idea, write our own) when the license forbids copying or the idea matters
more than the code. Jido, module by module: Action schema and instructions, clean-room into
core/effect and workflow/run; Signal, ideas only (overlaps ready core/envelope and
delivery/routing); Sensor, clean-room into delivery/trigger; Workflow and runner, ideas into
workflow/run and workflow/work-item over the ready durable Store; Agent server, rejected as a
kernel; VFS, not now. Jido's Zoi version conflict with ReqLLM is the coupling reason. A literal
copy of a named Jido module needs the owner to name it.

### Decision-ready documentation (owner requirement)

"docs must be decision ready when pieces builder wants to build those." Every planned and
deferred catalogue entry must carry, before a builder claims it: disposition with reason,
chosen library and version or clean-room source of ideas, the owner decision it rests on (this
file), dependencies on other entries, the caller and invariant it serves, and the open questions
that remain (payments provider, broker). This is the scope of the ELZ-050 documentation task.
