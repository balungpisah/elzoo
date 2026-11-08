> DRAFT INPUT — 2026-11-08. Copied unchanged below from the prior survey; its verification labels are the original author’s claims, not fresh verification by this research worker. Recommendations and batches are not admitted tasks.

# Elzoo catalogue library-first survey (planned and deferred entries)

Date: 2026-11-08. Read-only survey; no repository file was changed.

Sources used: AGENTS.md (Mission and boundaries; Before expanding the catalogue), docs/capability-model.md (admission/split rules, agent-orchestration decomposition), docs/development/08-upstream-and-forks.md, docs/adr/0005-ash-foundation-and-upstream-first.md, docs/research/ecosystem-round-2.md and docs/research/orchestration-references.md (prior ELZ-014/ELZ-025 studies), registry/catalogue.json (16 planned and 40 deferred entries; 56 total), registry/providers.json, pieces/integration/jobs/piece.json, tasks/ELZ-0*.md "Catalogue IDs" lines, and the live GitHub issue list and branch list of balungpisah/elzoo.

Verification method: every package version, release date and license in the reference table below was read from the Hex package API (https://hex.pm/api/packages/NAME) on 2026-11-08; "push" date, open-issue count and stars were read from the GitHub repository API the same day. Rows are marked **verified** on that basis. Oban's OSS cron plugin was additionally checked against the Oban docs via Context7. Fit statements (what a library does or does not guarantee against an Elzoo boundary) are my reading of package descriptions and prior Elzoo studies, not exercised boundaries; per the capability model, no candidate is "ready" until its exact boundary is exercised in a task. Anything not checked is marked unverified.

Owner rule applied: every entry is part of the build; first look for a maintained Elixir/Erlang library, ADOPT behind an Adapter when it fits, BUILD only when nothing fits, forks only under docs/development/08.

## 1. Verified candidate reference (Hex + GitHub, 2026-11-08)

Signal = last push / open issues / Hex owners. Recent = Hex recent downloads (90 days).

| Package | Latest | Released | License | Signal | Recent dl | Note |
| --- | --- | --- | --- | --- | --- | --- |
| oban (provider) | 2.24.2 | 2026-10-14 | Apache-2.0 | already pinned | — | OSS `cron:` plugin (Context7-checked) |
| ash | 3.37.3 | 2026-11-05 | MIT | 2026-11-07 / 109 / 1 | 559k | ADR-0005 preferred foundation candidate |
| ash_authentication | 4.15.1 | 2026-11-03 | MIT | 2026-11-07 / 8 / 3 | 293k | |
| ash_double_entry | 1.1.1 | 2026-10-22 | MIT | 2026-11-01 / 0 / 1 | 41k | needs ash + ash_money |
| ash_money | 0.2.7 | 2026-10-25 | MIT | 2026-11-01 / 0 / 1 | 81k | wraps ex_money |
| ash_paper_trail | 0.8.1 | 2026-10-19 | MIT | 2026-11-01 / 18 / 1 | 125k | |
| ash_state_machine | 0.3.0 | 2026-10-25 | MIT | 2026-11-01 / 1 / 1 | 181k | |
| ash_oban | 0.10.3 | 2026-10-25 | MIT | 2026-11-05 / 1 / 1 | 220k | |
| ash_postgres | 2.15.2 | 2026-10-25 | MIT | 2026-11-05 / 26 / 1 | 428k | |
| ash_rate_limiter | 2.0.1 | 2026-08-17 | MIT | 2026-11-01 / 0 / 1 | 62k | over hammer |
| ash_cloak | 0.5.0 | 2026-10-25 | MIT | 2026-11-01 / 0 / 1 | 130k | field encryption |
| ash_ai | 1.5.1 | 2026-11-07 | MIT | (repo not queried) | 140k | partially verified |
| reactor | 1.0.7 | 2026-09-16 | MIT | 2026-11-06 / 4 / 2 | 512k | saga/graph executor |
| decimal | 3.2.0 | 2026-10-10 | Apache-2.0 | 2026-11-02 / 0 / 2 | 7.8M | |
| ex_money | 6.3.0 | 2026-10-29 | Apache-2.0 | 2026-10-29 / 0 / 1 | 287k | CLDR-backed |
| money | 1.15.0 | 2026-05-18 | MIT | 2026-11-02 / 12 / 3 | 397k | integer minor units |
| ex_cldr | 2.47.5 | 2026-06-28 | Apache-2.0 | 2026-11-07 / 0 / 1 | 508k | |
| ex_cldr_units | 3.20.5 | 2026-06-28 | Apache-2.0 | 2026-11-08 / 0 / 1 | 95k | |
| ex_cldr_calendars | 2.4.4 | 2026-06-26 | Apache-2.0 | 2026-11-08 / 0 / 1 | 213k | |
| unicode_string | 2.4.2 | 2026-11-03 | Apache-2.0 | 2026-11-03 / 0 / 1 | 47k | |
| tz | 0.28.4 | 2026-09-15 | Apache-2.0 | 2026-10-17 / 11 / 1 | 953k | |
| tzdata | 1.2.2 | 2026-09-26 | MIT | 2026-11-05 / 19 / 1 | 2.2M | |
| crontab | 1.2.1 | 2026-10-09 | MIT | 2026-11-03 / 3 / 1 | 852k | cron expression parse/next-run |
| quantum | 3.5.3 | 2024-02-29 | Apache-2.0 | 2026-10-30 / 9 / 2 | 375k | node-local cron; no release since 2024 |
| hammer | 7.5.1 | 2026-10-27 | MIT | 2026-11-05 / 0 / 1 | 1.06M | rate limiting |
| fun_with_flags | 1.13.0 | 2025-03-23 | MIT | 2025-09-21 / 13 / 1 | 443k | feature flags |
| unleash_fresha | 6.1.0 | 2026-11-03 | MIT | (repo not queried) | 70k | Unleash client fork; partially verified |
| fuse | 2.5.0 | 2021-07-01 | MIT | 2022-02-15 / 8 / 1 | 518k | Erlang breaker; dormant but stable |
| external_service | 3.2.3 | 2026-09-01 | Apache-2.0 | 2026-09-01 / 4 / 1 | 43k | fuse + retry wrapper |
| breaker_box | 0.5.1 | 2026-08-13 | MIT | 2026-08-13 / 1 / 1 | 3k | low adoption |
| req_fuse | 0.3.2 | 2025-03-21 | CC-BY-NC-ND-4.0 | — | 26k | not adoptable (license) |
| phoenix_pubsub | 2.4.1 | 2026-10-08 | MIT | 2026-10-08 / 14 / 3 | 6.3M | |
| syn | 3.4.2 | 2026-06-22 | MIT | 2026-10-18 / 3 / 1 | 90k | global registry/groups |
| horde | 0.10.0 | 2025-11-03 | MIT | 2026-10-05 / 8 / 2 | 277k | delta-CRDT registry/supervisor |
| delta_crdt | 0.6.5 | 2024-04-16 | MIT | 2024-05-28 / 13 / 1 | 340k | quiet since 2024 |
| ra | 3.2.0 | 2026-09-01 | Apache-2.0, MPL-2.0 | 2026-10-22 / 46 / 5 | 585k | Raft (RabbitMQ) |
| khepri | 0.19.3 | 2026-09-29 | Apache-2.0, MPL-2.0 | 2026-11-08 / 9 / 5 | 541k | Raft tree store, pre-1.0 |
| portunus | 0.14.0 | 2026-08-01 | Apache-2.0, MPL-2.0 | unverified | 4k | Raft lock server; low adoption |
| gen_stage | 1.3.2 | 2025-07-15 | Apache-2.0 | 2026-08-05 / 2 / 1 | 2.5M | |
| broadway | 1.3.1 | 2026-11-04 | Apache-2.0 | 2026-11-06 / 4 / 1 | 943k | |
| broadway_kafka | 0.7.1 | 2026-10-15 | Apache-2.0 | 2026-11-04 / 6 / 2 | 167k | |
| broadway_rabbitmq | 0.8.2 | 2024-11-12 | Apache-2.0 | 2026-08-10 / 4 / 1 | 254k | |
| broadway_sqs | 1.0.1 | 2026-10-09 | Apache-2.0 | 2026-10-29 / 6 / 1 | 301k | |
| brod | 4.7.0 | 2026-09-25 | Apache-2.0 | 2026-09-25 / 39 / 6 | 714k | Kafka |
| amqp | 4.3.0 | 2026-10-06 | MIT | 2026-10-06 / 0 / 2 | 674k | RabbitMQ |
| gnat | 1.19.1 | 2026-11-06 | MIT | 2026-11-06 / 15 / 2 | 161k | NATS (nats-io org) |
| tortoise311 | 0.12.3 | 2026-09-10 | Apache-2.0 | 2026-09-10 / 9 / 1 | 30k | MQTT 3.1.1 |
| emqtt | 1.16.1 | 2026-09-10 | Apache-2.0 | 2026-09-10 / 37 / 3 | 55k | MQTT 5 (EMQX) |
| flow | 1.2.4 | 2023-03-21 | Apache-2.0 | 2026-09-25 / 1 / 1 | 1.1M | stable, no recent release |
| explorer | 0.13.0 | 2026-09-28 | MIT | 2026-09-28 / 52 / 3 | 1.1M | dataframes (Polars NIF) |
| cachex | 4.1.1 | 2025-06-30 | MIT | 2026-02-10 / 14 / 1 | 1.2M | |
| mint | 1.11.0 | 2026-09-28 | Apache-2.0 | 2026-10-25 / 15 / 2 | 6.8M | |
| plug | 1.20.3 | 2026-07-09 | Apache-2.0 | 2026-11-04 / 5 / 4 | 7.2M | |
| bandit | 1.14.1 | 2026-10-28 | MIT | 2026-11-07 / 3 / 2 | 4.6M | |
| libgraph | 0.17.1 | 2026-11-03 | MIT | 2026-11-03 / 15 / 1 | 378k | |
| req_llm | 1.30.0 | 2026-11-03 | Apache-2.0 | 2026-11-08 / 1 / 1 | 495k | Req-based LLM providers |
| langchain | 0.15.8 | 2026-11-02 | Apache-2.0 | 2026-11-02 / 33 / 1 | 229k | |
| instructor | 0.1.0 | 2025-02-09 | MIT | 2025-06-07 / 41 / 1 | 60k | stale |
| jido | 2.4.0 | 2026-10-08 | Apache-2.0 | 2026-11-02 / 4 / 1 | 166k | 3.0 betas exist (ELZ-025) |
| claude_code | 0.36.5 | 2026-05-28 | MIT | 2026-06-05 / 2 / 1 | 13k | Claude Code CLI SDK; single author |
| anubis_mcp | 2.2.0 | 2026-10-19 | LGPL-3.0 | 2026-11-05 / 8 / 1 | 229k | license needs review |
| hermes_mcp | 0.14.1 | 2025-08-14 | MIT | repo 404 | 45k | superseded by anubis_mcp (unverified) |
| ex_mcp | 1.8.1 | 2026-10-31 | MIT | (repo not queried) | 25k | partially verified |
| phantom_mcp | 0.8.0 | 2026-11-05 | MIT | (repo not queried) | 30k | partially verified |
| pythonx | 0.4.11 | 2026-10-24 | Apache-2.0 | 2026-10-24 / 4 / 1 | 35k | embedded CPython (livebook-dev) |
| rustler | 0.38.0 | 2026-05-25 | MIT, Apache-2.0 | 2026-10-23 / 56 / 4 | 1.1M | |
| erlport | 0.11.0 | 2023-07-28 | BSD-3-Clause | 2024-01-24 / 7 / 3 | 103k | quiet |
| erlexec | 2.6.0 | 2026-10-29 | BSD-2-Clause | 2026-10-29 / 0 / 1 | 168k | process groups, kill escalation |
| muontrap | 2.0.1 | 2026-10-06 | Apache-2.0 | 2026-10-11 / 1 / 1 | 165k | cgroups, guaranteed cleanup |
| exile | 0.15.0 | 2026-09-14 | Apache-2.0 | 2026-09-14 / 1 / 1 | 30k | backpressured stdio |
| bodyguard | 2.4.3 | 2024-03-16 | MIT | 2024-05-24 / 1 / 1 | 152k | quiet |
| let_me | 3.0.4 | 2026-09-09 | MIT | 2026-11-02 / 0 / 1 | 103k | rule DSL authorization |
| ex_cedar | 0.1.2 | 2026-06-30 | Apache-2.0 | unverified | 824 | Cedar via Rust NIF; very low adoption |
| assent | 0.4.0 | 2026-11-07 | MIT | 2026-11-07 / 3 / 1 | 497k | OAuth2/OIDC strategies |
| ueberauth | 0.11.0 | 2026-10-11 | MIT | 2026-10-28 / 48 / 1 | 704k | |
| oidcc | 3.9.2 | 2026-11-03 | Apache-2.0 | 2026-11-08 / 14 / 2 | 197k | ErlEF, OpenID-certified (certification unverified) |
| guardian | 2.5.0 | 2026-08-17 | MIT | 2026-08-18 / 1 / 1 | 717k | JWT sessions |
| joken | 2.7.0 | 2026-08-28 | Apache-2.0 | 2026-11-01 / 11 / 2 | 2.4M | JWT |
| swoosh | 1.29.3 | 2026-10-28 | MIT | 2026-11-03 / 15 / 2 | 2.6M | email |
| pigeon | 2.1.0 | 2026-09-08 | MIT | 2026-09-08 / 30 / 1 | 163k | APNS/FCM push |
| ex_aws + ex_aws_s3 | 2.7.0 / 2.5.9 | 2026-05-06 / 2025-12-09 | MIT | s3: 2026-02-02 / 28 / 2 | 2.0M | |
| req_s3 | 0.2.5 | 2026-07-31 | Apache-2.0 | 2026-08-10 / 8 / 1 | 88k | fits the pinned Req provider |
| waffle | 2.0.0 | 2026-08-24 | Apache-2.0 | 2026-11-05 / 29 / 1 | 229k | upload/attachments |
| telemetry | 1.4.2 | 2026-05-11 | Apache-2.0 | 2026-09-30 / 6 / 3 | 9.1M | |
| telemetry_metrics | 1.2.0 | 2026-08-25 | Apache-2.0 | 2026-10-12 / 5 / 2 | 5.0M | |
| telemetry_poller | 1.3.0 | 2025-07-09 | Apache-2.0 | 2025-10-17 / 0 / 2 | 4.6M | |
| opentelemetry / _api / _exporter | 1.7.0 / 1.5.0 / 1.11.0 | 2025-10-17 / 2025-10-17 / 2026-09-16 | Apache-2.0 | 2026-11-07 / 157 / 1 | 2.4–3.0M | |
| prom_ex | 1.12.0 | 2026-06-19 | MIT | 2026-06-19 / 59 / 1 | 714k | |
| logger_json | 7.0.4 | 2025-07-14 | MIT | 2026-08-05 / 3 / 1 | 1.4M | |
| sentry | 14.0.1 | 2026-10-28 | MIT | 2026-11-05 / 16 / 3 | 1.9M | exception tracking (hosted service) |
| stripity_stripe | 3.3.3 | 2026-10-29 | BSD-3-Clause | 2026-11-02 / 2 / 1 | 409k | |
| carbonite | 0.17.0 | 2026-09-11 | Apache-2.0 | 2026-09-11 / 2 / 2 | 114k | Postgres trigger audit trail |
| paper_trail | 1.1.2 | 2024-08-30 | MIT | 2026-01-21 / 19 / 1 | 44k | Ecto versioning |
| cloak | 1.1.4 | 2024-04-06 | MIT | 2026-11-05 / 19 / 1 | 1.05M | encryption at rest |
| libvault | 0.2.4 | 2022-08-10 | MIT | unverified | 12k | HashiCorp Vault client; stale |
| commanded | 1.4.11 | 2026-07-27 | MIT | 2026-07-27 / 20 / 2 | 189k | CQRS/ES framework with upcasters |
| lustre (Gleam) | 5.7.1 | 2026-07-13 | MIT | 2026-10-30 / 18 / 1 | 73k | studied in ELZ-017 |
| phoenix_live_view | 1.2.13 | 2026-10-20 | MIT | 2026-11-05 / 30 / 3 | 5.0M | |
| fhir (Gleam) / fhir_ex | 0.9.0 / 0.4.1 | 2026-06-06 / 2026-08-21 | MIT | 3 stars / repo 404 | ~230 each | immature |
| meilisearch (Elixir) | 0.20.0 | 2021-09-03 | MIT | repo archived | 543 | not usable |
| tesseract_ocr | 0.1.5 | 2020-10-25 | MIT | 2022-06-06 / 1 / 1 | 13k | stale |
| spek | 0.5.0 | 2026-08-26 | MIT | unverified | 61k | boolean rule expressions; partially verified |

Not found on Hex (404): elixir_ledger, double_entry (as a ledger), cedar, opa, elixir_opa, req_fhir, ex_aws_secrets_manager. No maintained resequencer, metering, quota-allocation, lease-with-fencing or payment-lifecycle package was found by Hex search.

License flags for adoption: anubis_mcp (LGPL-3.0), stripity_stripe (BSD-3), erlexec (BSD-2), ra/khepri/portunus (Apache-2.0 plus MPL-2.0) each need their own terms recorded; req_fuse (CC-BY-NC-ND) and quant (CC-BY-NC, from ELZ-025) are not adoptable.

## 2. Per-entry survey

Columns: candidates (from table 1), fit against the entry boundary, disposition, dependencies (R = ready, P = planned, D = deferred), size (S one task; M one task plus Contract review; L needs SPLIT).

### assembly (8)

| id | summary | candidates and fit | disposition | depends on | size |
| --- | --- | --- | --- | --- | --- |
| assembly/agent-product | LLM/tool/approval/budgeted loop | jido 2.4.0 (mandatory host; ELZ-025 distilled, did not adopt), langchain 0.15.8, ash_ai 1.5.1. All bundle their own loop/runtime; the capability model says agent orchestration is an Assembly of Pieces, not a privileged kernel. Libraries feed the Adapters (integration/ai-model), not the Assembly. | BUILD (Assembly over ready/adopted Pieces) | work-item D, run D, dependency-graph R, budget R, approval R, authorization R, context-selection R, ai-model D, agent-runner D, artifact D, audit-log D, effect-intent D | L (compose after parts; split by C6 vs C7 product aim) |
| assembly/consent-records | Consent, classified records, FHIR | fhir (Gleam) 0.9.0 and fhir_ex 0.4.1 are immature (hundreds of downloads). No maintained Elixir consent library found. | SPLIT: consent record (BUILD over audit-log), record classification/redaction policy (BUILD), FHIR Adapter (ADOPT later only if a maintained client appears; otherwise Req + JSON schema) | audit-log D, authorization R, secrets D, schema-evolution P | L |
| assembly/data-pipeline | Build graph, content cache, dataframe | explorer 0.13.0 (dataframe), cachex 4.1.1 (cache), flow 1.2.4 / broadway 1.3.1 (staged processing). Good library coverage; no product workload yet. | ADOPT parts; Assembly BUILD when a workload exists | build-graph D, artifact D, search-data D, data-stream D | M |
| assembly/device-ingest | IoT dedup/window/alerts/rollout | emqtt 1.16.1 or tortoise311 0.12.3 (MQTT), broadway for ingest. Dedup/window are ready Elzoo pieces. | BUILD Assembly over ADOPTed broker Adapter | message-broker P, windowed-idempotency R, backpressure R, principal D (device identity), pubsub P | M |
| assembly/http-job | Edge request to durable job | plug 1.20.3 + bandit 1.14.1 (server edge), req (provider), jason (provider), oban (provider). ELZ-011 (issue #11, open) carries core/effect, runtime/adapter, integration/http, integration/json and the assembly/http-job boundary. | ADOPT (plug/bandit) + BUILD composition | core/effect P, integration/jobs R, durable-job R, integration/http (no status), observability P | M |
| assembly/ledger-checkout | Ledger, checkout saga, inventory/payment | ash_double_entry 1.1.1 + ash_money (ledger), reactor 1.0.7 (saga with compensation), stripity_stripe 3.3.3 (one provider). | BUILD Assembly; ADOPT ledger/saga parts | money D, journal D, payment-lifecycle D, payments D, effect-intent D, audit-log D | L |
| assembly/task-workflow | Human and automated task coordination | ash + ash_state_machine 0.3.0 + ash_oban 0.10.3 cover resource lifecycle and background actions; ELZ-015 already evaluated part of this. | BUILD Assembly over Ash-backed Pieces | work-item D, run D, lease D, dependency-graph R, notification D, approval R | L |
| assembly/tenant-edge | Tenant tag/auth/quota/metering/billing | ash multitenancy (attribute/schema), ash_authentication, hammer/ash_rate_limiter. triplex 1.3.0 is stale (2019). | BUILD Assembly; parts ADOPT | principal D, membership D, authorization R, entitlement D, quota D, metering D, identity D | L |

### core (2)

| id | summary | candidates and fit | disposition | depends on | size |
| --- | --- | --- | --- | --- | --- |
| core/effect | Data-shaped external request/result boundary | None; this is an Elzoo-owned typed boundary (`T,X`). Being specified in ELZ-011 (open). | BUILD (Cure types + Elixir) | envelope (no status), adapter (no status) | M |
| core/grounding | Claim/evidence record and present-versus-target status | None; owned by `mix check`/ledger tooling (ELZ-001/012/033 touch it). | BUILD (tooling) | none | S |

### delivery (8)

| id | summary | candidates and fit | disposition | depends on | size |
| --- | --- | --- | --- | --- | --- |
| delivery/aggregation | Aggregator, scatter-gather, completion/timeout | OTP Task.async_stream / Task.Supervisor cover concurrency; no library supplies per-branch identity with recorded timeout/kill results (ELZ-025 skipped shifts, lux). ELZ-036/037 already touch aggregate timeouts. | BUILD (Cure reducer + OTP) | envelope, request-reply, retry-timeout R | M |
| delivery/circuit-breaker | Circuit breaker and bulkhead | fuse 2.5.0 (stable, dormant since 2022), external_service 3.2.3 (fuse + retry), breaker_box 0.5.1 (low adoption). Catalogue reason already says reuse OTP and own only remaining permit policy. | ADOPT fuse behind Adapter for breaker state; BUILD bulkhead permits on backpressure R | backpressure R, retry-timeout R, telemetry P | M |
| delivery/data-stream | Incremental byte/result transfer | gen_stage 1.3.2 (demand), mint 1.11.0 (HTTP streaming), Req streaming (provider). Transport is covered; the completeness marker and cancellation flush are Elzoo policy. | BUILD contract; ADOPT gen_stage/Req for transport | backpressure R, core/effect P | M |
| delivery/effect-intent | Dispatched effect intent, unknown-outcome recovery | None found; Oban gives at-least-once retry, not unknown-outcome reconciliation. ELZ-023 (issue #37, open; branch task/ELZ-023 exists, so claimed). | BUILD | checkpoint R, outbox R, core/effect P, integration/jobs R | M |
| delivery/model-routing | Select eligible model providers under policy | req_llm 1.30.0 and langchain expose multiple providers and fallbacks (routing policy detail unverified); neither enforces authority/region/budget eligibility. | BUILD pure selection; providers via ai-model | ai-model D, budget R, selection (no status), metering D | M |
| delivery/pubsub | Publish-subscribe, gen_event, process groups | phoenix_pubsub 2.4.1 (pg/Redis adapters), OTP `pg` (platform), syn 3.4.2. Loss/replay semantics remain to be tested. | ADOPT phoenix_pubsub or OTP pg behind Adapter | registry (no status), envelope | S |
| delivery/resequence | Resequencer, ordered joins | None found on Hex. | BUILD (Cure law: release order) | envelope, windowed-idempotency R | M |
| delivery/trigger | Normalize externally initiated work | Oban OSS cron plugin (provider, Context7-checked), crontab 1.2.1 (expression math), quantum 3.5.3 (no release since 2024). ELZ-027 (issue #44, open) carries the schedule-occurrence slice. Webhook ingress via plug/bandit. | SPLIT: schedule occurrence (ELZ-027, BUILD identity/overlap; ADOPT crontab or Oban cron), webhook trigger (BUILD on plug + crypto HMAC), app-event trigger (BUILD on outbox) | scheduler P, idempotency, outbox R, integration/http, integration/crypto | L |

### domain (12)

| id | summary | candidates and fit | disposition | depends on | size |
| --- | --- | --- | --- | --- | --- |
| domain/entitlement | Feature/access entitlement decisions | fun_with_flags 1.13.0 (flags, last release 2025-03), unleash_fresha 6.1.0 (Unleash client). These are rollout flags, not subscription entitlements with grace/revocation. | BUILD decision; ADOPT fun_with_flags only for rollout flags | principal D, membership D, quota D | M |
| domain/journal | Atomic balanced posting and reversal | ash_double_entry 1.1.1 (balanced transfers, balances; requires Ash + ash_money + ash_postgres). Otherwise ecto_sql transaction (provider). | ADOPT ash_double_entry if the Ash foundation is accepted for this Assembly; else BUILD on integration/sql | money D, integration/sql R, audit-log D | M |
| domain/membership | Tenant membership and invitation lifecycle | ash + ash_authentication (resources, tokens); no standalone invitation library found. | BUILD policy on Ash resources | principal D, identity D, authorization R | M |
| domain/metering | Unit-tagged observed usage with provenance | None found. telemetry is observation, not retained usage. | BUILD | idempotency, event-log R, ai-model D (usage source) | M |
| domain/money | Currency amount and rounding | ex_money 6.3.0 (CLDR currencies, allocation), decimal 3.2.0, money 1.15.0 (integer minor units), ash_money. ELZ-031 (issue #48, open) names the ex_money/Decimal boundary. | ADOPT ex_money + decimal behind the ELZ-031 registry Contract | none | M |
| domain/payment-lifecycle | Payment intent and reconciliation policy | None found (stripity_stripe is provider translation only). | BUILD (Cure state machine) | money D, effect-intent D, payments D | M |
| domain/policy-rules | Decision tables, business rules | spek 0.5.0 (boolean expressions; partially verified), let_me (authorization DSL, not rules). No maintained decision-table engine found. | BUILD after a product supplies a finite rule schema | authorization R, audit-log D | M |
| domain/pricing | Versioned usage-to-price rules | None fits (ELZ-025 skipped `pricing` 0.6.9). ex_money supplies arithmetic. | BUILD on money | money D, metering D, schema-evolution P | M |
| domain/principal | Stable actor identity mapping | ash_authentication (user resources), guardian/joken (tokens). Mapping human/service/agent identities to scoped principals is Elzoo policy. | BUILD mapping; identity via integration/identity | identity D | M |
| domain/quota | Scoped usage allocation and admission | hammer 7.5.1 and ash_rate_limiter 2.0.1 cover time-window rate limits only (the ELZ-014 note says not a monthly quota). workflow/budget (ready, ELZ-022) shares unit arithmetic. | BUILD on workflow/budget; ADOPT hammer only for rate-limit slice | budget R, metering D, membership D | M |
| domain/saas-controls | Tenant isolation, quota, metering, rollout, billing, SLO | Catalogue already defines it as an Assembly family. | SPLIT into existing handles: membership, authorization (R), entitlement, quota, metering, pricing, observability; no own Piece | those handles | L |
| domain/value-types | Decimal/money, date-time, units, Unicode text | decimal, ex_money, tz 0.28.4 or tzdata 1.2.2, ex_cldr_calendars 2.4.4, ex_cldr_units 3.20.5, unicode_string 2.4.2. Reason text forbids a second generic implementation. | SPLIT and ADOPT: money (= domain/money), time zone recipe (tz), units (ex_cldr_units), text segmentation (unicode_string); each a thin tested recipe, not a wrapper | money D | L |

### integration (12)

| id | summary | candidates and fit | disposition | depends on | size |
| --- | --- | --- | --- | --- | --- |
| integration/agent-runner | External agent-session execution adapter | claude_code 0.36.5 (single author, last push 2026-06), jido 2.4.0, MCP SDKs: anubis_mcp 2.2.0 (LGPL-3.0), ex_mcp 1.8.1, phantom_mcp 0.8.0. CLI agents can also be driven through runtime/os-isolation. | ADOPT per runner (one runner first), behind the os-isolation Adapter; MCP via ex_mcp after license/maintenance check | os-isolation P, run D, approval R, secrets D | M |
| integration/ai-model | LLM provider request/stream/usage translation | req_llm 1.30.0 (on Req, the pinned provider; very active), langchain 0.15.8, instructor 0.1.0 (stale). | ADOPT req_llm behind Adapter (tool calls returned as data, usage source-tagged) | core/effect P, metering D, integration/json | M |
| integration/auth-policy | Cedar/RBAC/ABAC, tokens, IdP, consent | Ash policies (ADR-0005), let_me 3.0.4, bodyguard 2.4.3 (quiet since 2024), ex_cedar 0.1.2 (824 downloads; immature). | ADOPT Ash policies or let_me as provider for domain/authorization; Cedar deferred until ex_cedar matures | authorization R, principal D | M |
| integration/identity | OAuth/OIDC, secrets vault, email/SMS/push/payments | oidcc 3.9.2 (ErlEF), assent 0.4.0, ueberauth 0.11.0, ash_authentication 4.15.1, guardian/joken. Summary bundles unrelated providers. | SPLIT: identity/oidc (ADOPT oidcc or assent), sessions/tokens (ADOPT ash_authentication or guardian); move vault to integration/secrets, email/push to notification, payments to integration/payments | principal D, secrets D, crypto | L |
| integration/message-broker | Kafka/NATS/RabbitMQ/MQTT/cloud queues | broadway + broadway_kafka/rabbitmq/sqs, brod 4.7.0, amqp 4.3.0, gnat 1.19.1, emqtt/tortoise311. | SPLIT per broker, ADOPT each (Broadway producers first); Elzoo owns envelope-class translation and ack semantics | envelope, backpressure R, dead-letter R, idempotency | L |
| integration/notification | Notification-provider translation | swoosh 1.29.3 (email), pigeon 2.1.0 (APNS/FCM; 30 open issues). | ADOPT swoosh first; pigeon as second slice | effect-intent D, jobs R, principal D | S |
| integration/object-store | Claim check, S3, large payload | req_s3 0.2.5 (on pinned Req), ex_aws_s3 2.5.9, waffle 2.0.0 (uploads). | ADOPT req_s3 behind Adapter | core/effect P, secrets D, crypto | S |
| integration/observability | Telemetry exporter, tracing, logs, SLO/alerts | opentelemetry 1.7.0 / exporter 1.11.0, prom_ex 1.12.0, logger_json 7.0.4, sentry 14.0.1. | ADOPT opentelemetry (+ logger_json); redaction and sampling remain Elzoo Contract | runtime/telemetry P, secrets D (redaction) | M |
| integration/payments | Payment-provider request/result translation | stripity_stripe 3.3.3 (BSD-3, active). Req is HTTP only. | ADOPT stripity_stripe for the first provider, or Req directly if dependency cost is too high | payment-lifecycle D, effect-intent D, money D, secrets D, crypto (webhook verification) | M |
| integration/sdk | Foreign-unit SDKs and MCP | pythonx 0.4.11, rustler 0.38.0, erlport 0.11.0 (quiet), MCP SDKs above. | DEFER-then-ADOPT per foreign language when an actual cross-process Assembly exists; no build | os-isolation P, adapter | L (per-language split) |
| integration/search-data | Search, dataframe, OCR/media/speech | explorer 0.13.0 (dataframe). Search: no maintained Elixir Meilisearch client (archived); use Req or ash_postgres full text. OCR: tesseract_ocr stale. | SPLIT per product adapter; ADOPT explorer; other slices Req-based Adapters when demanded | object-store P, data-stream D | L |
| integration/secrets | Scoped credential access | cloak 1.1.4 / ash_cloak (encryption at rest, not a secret store), libvault 0.2.4 (stale 2022). Cloud secret managers reachable via Req/ex_aws (unverified per service). | BUILD the secret-reference/redaction Contract; ADOPT a provider client per backend (Req-based) | crypto, telemetry P (redaction) | M |

### runtime (3)

| id | summary | candidates and fit | disposition | depends on | size |
| --- | --- | --- | --- | --- | --- |
| runtime/faces | Lean config/control/health/errors/state conventions | nimble_options 1.2.0 (option validation) covers config validation only. | BUILD conventions (docs + checks) | operational-contracts doc | S |
| runtime/os-isolation | Foreign unit/host/process boundary | erlexec 2.6.0 (process groups, kill escalation; BSD-2), muontrap 2.0.1 (cgroups, guaranteed cleanup), exile 0.15.0 (backpressured stdio). ELZ-029 (issue #46, open). | ADOPT erlexec or muontrap behind the ELZ-029 Adapter; compare both against the reaper and term/kill invariants | core/effect P, supervision | M |
| runtime/telemetry | Metrics, traces, history, exception tracking, audit logging | telemetry 1.4.2, telemetry_metrics 1.2.0, telemetry_poller 1.3.0, opentelemetry_api 1.5.0. Audit logging belongs to state/audit-log, not here. | ADOPT telemetry (+ telemetry_metrics); BUILD redaction contract first | secrets D (redaction rules) | S |

### state (7)

| id | summary | candidates and fit | disposition | depends on | size |
| --- | --- | --- | --- | --- | --- |
| state/artifact | Owned content references and retention | None for the content-identity contract; storage via object-store. Hashing via OTP :crypto. | BUILD on object-store | object-store P, crypto, schema-evolution P | M |
| state/audit-log | Attributable retained decision history | carbonite 0.17.0 (Postgres trigger-based, transaction-scoped), ash_paper_trail 0.8.1, paper_trail 1.1.2 (last release 2024). Carbonite fits "commits atomically with the decision" via the same transaction. | ADOPT carbonite (or ash_paper_trail under Ash) behind Adapter; BUILD actor/action/outcome record shape | integration/sql R, principal D | M |
| state/crdt | Counters, sets, registers, offline sync | delta_crdt 0.6.5 (quiet since 2024), horde 0.10.0, Gleam lattice_* 2.0.0 (excluded by gleam-libraries policy unless reviewed). | ADOPT delta_crdt only when replication is demanded; possible fork case if it stays dormant | replication D | M |
| state/lease | Expiring ownership with fencing | No Hex package provides revision-fenced leases; portunus (Raft lock) and redis_mutex/redlock lack fencing by record revision. ELZ-010 found Oban's ownership insufficient. ELZ-028 (issue #45, open). | BUILD on integration/sql | integration/sql R, event-log R | M |
| state/replication | Leader/follower, quorum, replicated log | ra 3.2.0 (Raft, RabbitMQ team), khepri 0.19.3 (pre-1.0). | ADOPT ra (or khepri) only when a product needs it | none | L |
| state/scheduler | Delayed/recurring jobs and workflow timers | Oban OSS cron plugin and scheduled_at (provider, Context7-checked), crontab 1.2.1, quantum 3.5.3. | ADOPT Oban cron through integration/jobs; BUILD only the workflow-timer Contract | integration/jobs R, trigger D (ELZ-027), delivery/time | M |
| state/schema-evolution | Upcasters, format indicator, migration | commanded 1.4.11 has event upcasting but is a whole CQRS framework; no standalone upcaster library found. | BUILD | event-log R, durable-job R | M |

### ui (1)

| id | summary | candidates and fit | disposition | depends on | size |
| --- | --- | --- | --- | --- | --- |
| ui/component | Embeddable browser component with DOM interface | lustre 5.7.1 (Gleam; ELZ-017 tested), phoenix_live_view 1.2.13. | ADOPT lustre per ELZ-017 findings, or LiveView component if the consumer is Phoenix | none | M |

### workflow (3)

| id | summary | candidates and fit | disposition | depends on | size |
| --- | --- | --- | --- | --- | --- |
| workflow/build-graph | Build scheduler/rebuilder, trace store, dry run | libgraph 0.17.1 (graph algorithms); dependency-graph is ready. | BUILD only for a product build system | dependency-graph R, artifact D, checkpoint R | L |
| workflow/run | Execution and attempt lifecycle | Oban (provider) for attempts, reactor 1.0.7 (step compensation), jido (distilled only). None gives reciprocal parent/child settlement with late-result handling. | BUILD on integration/jobs + state-machine R | state-machine R, jobs R, effect-intent D, lease D | L (split: attempt lifecycle; parent/child settlement; cancellation) |
| workflow/work-item | Durable work intent and acceptance | ash + ash_state_machine (ELZ-015 evaluated Ash resource actions). | ADOPT Ash resource actions; BUILD acceptance/completion policy | lease D, principal D, authorization R | M |

### Disposition totals

ADOPT (library behind an Adapter, possibly with a small owned Contract): data-pipeline parts, circuit-breaker, pubsub, journal (conditional on Ash), money, agent-runner, ai-model, auth-policy, notification, object-store, observability, payments, sdk (later), os-isolation, telemetry, audit-log, crdt, replication, scheduler, ui/component, work-item.
BUILD: assemblies agent-product, device-ingest, http-job, ledger-checkout, task-workflow, tenant-edge; core/effect, core/grounding, aggregation, data-stream, effect-intent, model-routing, resequence, entitlement, membership, metering, payment-lifecycle, policy-rules, pricing, principal, quota, secrets, faces, artifact, lease, schema-evolution, build-graph, run.
SPLIT: consent-records, delivery/trigger, domain/saas-controls, domain/value-types, integration/identity, integration/message-broker, integration/search-data.
ALREADY-COVERED: none outright. Partial overlaps: domain/quota shares unit arithmetic with ready workflow/budget; state/scheduler's delayed-retry slice is already inside ready integration/jobs; domain/saas-controls is fully covered by other handles once they exist.

These lists overlap where an entry is "BUILD contract + ADOPT transport"; the table cell is authoritative.

## 3. Existing task issues for these entries

| Task | Issue | State on 2026-11-08 | Catalogue id |
| --- | --- | --- | --- |
| ELZ-011 | #11 | open | core/effect, assembly/http-job boundary (with runtime/adapter, integration/http, integration/json) |
| ELZ-023 | #37 | open; branch task/ELZ-023 exists (claimed) | delivery/effect-intent |
| ELZ-027 | #44 | open | delivery/trigger (schedule-occurrence slice) |
| ELZ-028 | #45 | open | state/lease |
| ELZ-029 | #46 | open | runtime/os-isolation |
| ELZ-031 | #48 | open | domain/money |

ELZ-022 (domain/quota arithmetic via workflow/budget), ELZ-024, ELZ-026 and ELZ-030 are closed and target ready pieces; other task bodies mention planned/deferred ids only as references, not as their Catalogue IDs.

## 4. Proposed build sequence (batches of four)

Ordering rule: unblock the most dependents first; within a tier, prefer ADOPT entries (cheap) and entries that already have an issue. Dependencies listed are the ones inferred above.

**Batch 1 — boundaries everything else crosses.** core/effect (ELZ-011), domain/money (ELZ-031, ADOPT ex_money/decimal), runtime/telemetry (ADOPT telemetry), state/scheduler (ADOPT Oban cron). Reason: core/effect gates every Adapter; money gates journal, pricing, payments, payment-lifecycle, value-types; telemetry gates observability and circuit-breaker; scheduler is a cheap adopt that ELZ-027 builds on.

**Batch 2 — durability primitives with open issues.** delivery/effect-intent (ELZ-023, in progress), state/lease (ELZ-028), delivery/trigger schedule slice (ELZ-027), runtime/os-isolation (ELZ-029, ADOPT erlexec or muontrap). Reason: effect-intent and lease gate run, work-item, payment-lifecycle and every external-effect Assembly; os-isolation gates agent-runner and sdk.

**Batch 3 — cheap adopts that extend the edge.** integration/ai-model (ADOPT req_llm), integration/object-store (ADOPT req_s3), integration/notification (ADOPT swoosh), delivery/pubsub (ADOPT phoenix_pubsub or pg). Reason: all four sit on the pinned Req/OTP stack, have few dependencies, and unblock metering, artifact, model-routing and task-workflow.

**Batch 4 — retained-record and storage contracts.** state/audit-log (ADOPT carbonite), state/schema-evolution (BUILD), integration/secrets (BUILD contract + provider client), state/artifact (BUILD on object-store). Reason: audit-log and secrets are prerequisites for consent, payments, identity and agent work; schema-evolution is needed before any format change in artifact, pricing or durable-job.

**Batch 5 — identity and tenancy base.** integration/identity OIDC slice (ADOPT oidcc or assent), domain/principal (BUILD), integration/auth-policy (ADOPT Ash policies or let_me), domain/membership (BUILD on Ash). Reason: principal and membership gate entitlement, quota, work-item and tenant-edge.

**Batch 6 — execution lifecycle.** workflow/run (attempt-lifecycle slice first), workflow/work-item (ADOPT Ash resources), delivery/aggregation (BUILD), delivery/circuit-breaker (ADOPT fuse). Reason: needs effect-intent and lease from batch 2 and principal from batch 5; unblocks task-workflow and agent-product.

**Batch 7 — usage and money flow.** domain/metering, domain/quota, domain/journal (ADOPT ash_double_entry or BUILD on sql), integration/observability (ADOPT opentelemetry). Reason: metering needs ai-model usage (batch 3); quota builds on budget plus metering; journal needs money and audit-log.

**Batch 8 — commerce and selection policy.** domain/pricing, domain/payment-lifecycle, integration/payments (ADOPT stripity_stripe), delivery/model-routing. Reason: each needs money, metering, effect-intent or ai-model from earlier batches.

**Batch 9 — remaining owned pieces.** domain/entitlement, delivery/resequence, delivery/data-stream, runtime/faces. Reason: independent of most others but with fewer dependents; faces could move earlier if operational-contract checks need it (it is size S).

**Batch 10 — agent and product Assemblies.** integration/agent-runner (ADOPT one runner), assembly/http-job (completes after ELZ-011), assembly/task-workflow, assembly/agent-product. Reason: compose the earlier pieces into the C5/C6/C7 aims.

**Batch 11 — broker and SaaS composition.** integration/message-broker (first broker), assembly/tenant-edge, assembly/ledger-checkout, domain/saas-controls (family record only). Reason: needs identity, quota, metering, journal and payments.

**Batch 12 — demand-only and splits.** domain/value-types sub-recipes, domain/policy-rules, ui/component, integration/search-data first slice. Reason: each waits on a product to fix its rule schema, UI host or data workload.

**Batch 13 — replication and specialised Assemblies.** state/replication (ADOPT ra), state/crdt (ADOPT delta_crdt), assembly/device-ingest, assembly/data-pipeline. Then the tail: integration/sdk, workflow/build-graph, assembly/consent-records. Reason: these need replication, broker or healthcare review and have no current dependents.

## 5. Limits

- Versions, dates, licenses and repository activity are verified as of 2026-11-08 from Hex and GitHub APIs; fit claims are unexercised readings and must be tested per the admission rules before any entry leaves planned/deferred.
- Rows marked "repo not queried", "partially verified" or "unverified" (ash_ai, unleash_fresha, ex_mcp, phantom_mcp, portunus, ex_cedar repo activity, libvault repo activity, spek, oidcc certification, req_llm routing features, cloud secret-manager clients) were not checked beyond Hex search metadata.
- Dependencies between entries are inferred from catalogue summaries/reasons and the capability model; they are not recorded in registry metadata.
- Batch order is a proposal; the product-led roadmap and its canonical manifest still decide selection.
