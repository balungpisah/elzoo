"""Render the research-only ranking and validate coverage/dependency direction."""
import json
from pathlib import Path
ROOT=Path('docs/work/research')
# Each row: catalogue ID, disposition, candidate/remaining scope, size, earlier-entry dependencies, limits/gate.
ROWS=[
('core/effect','CLEAN-ROOM','Existing ELZ-011 data-shaped Effect/Adapter Contract; no replacement framework','M',[],'Existing task; live Contract owns acceptance.'),
('delivery/effect-intent','CLEAN-ROOM','Existing ELZ-023 over ready Store/outbox; preserve unknown outcomes','M',[],'Existing task; coordinate core/effect for dispatch, not a new prerequisite claim.'),
('runtime/telemetry','ADOPT','telemetry 1.4.2; telemetry_metrics 1.2.0 only if needed','S',[],'One bounded redacted event family; synchronous handlers, no durable audit.'),
('runtime/faces','WRAP','nimble_options 1.2.0 plus existing operational conventions','S',[],'Config validation only; no implicit hot reload/drain/control engine.'),
('integration/secrets','WRAP','Compare aws 1.0.15 service client with ExAws; own scoped references/redaction','M',['core/effect'],'Hush/ExAws Hackney conflict unresolved; boot config is not per-call authority.'),
('domain/money','ADOPT','Existing ELZ-031: ex_money 6.3.0 / decimal 3.2.0 comparison; AshMoney only for Ash','M',[],'Existing task; do not start another money representation.'),
('state/lease','WRAP','Existing ELZ-028: transactional provider/ready SQL plus explicit revision fence','M',[],'Existing task; no distributed-lock or Raft adoption inferred.'),
('runtime/os-isolation','ADOPT','Existing ELZ-029 selected OS/process provider and OTP Port boundary','M',['core/effect'],'Provider pin belongs to live task; process libraries not freshly rechecked in these reports.'),
('integration/identity','ADOPT','AshAuthentication 4.15.1 in Ash, or oidcc 3.9.2/Assent as a direct boundary','M',['integration/secrets'],'Choose provider/session scope; AshAuthentication cannot pair with latest Assent 0.4.0.'),
('domain/principal','WRAP','Chosen authentication facts plus explicit scoped identity/linking translation','S',['integration/identity'],'Stable human/service/agent mapping, not token bytes or model identity.'),
('integration/auth-policy','WRAP','Ash policies or let_me 3.0.4 translated to ready authorization inputs','M',['domain/principal'],'Fresh authority and tenant context; ready domain/authorization remains unchanged.'),
('domain/membership','WRAP','Ash 3.37.3 resource actions / ash_state_machine 0.3.0','M',['domain/principal','integration/auth-policy'],'Own invitation, tenant binding and revocation; exercise transaction/concurrency.'),
('domain/entitlement','CLEAN-ROOM','Ash resources and optional fun_with_flags 1.13.0 rollout input; missing entitlement policy','M',['domain/membership'],'Flags are not subscription/grace/revocation authority; exact fit still needs search.'),
('domain/policy-rules','WRAP','Ash/LetMe for a finite resource-policy subset; general rule engine not selected','M',['integration/auth-policy'],'Caller must specify finite rule schema and conflicts; no universal evaluator admitted.'),
('state/audit-log','ADOPT','carbonite 0.17.0 versus ash_paper_trail 0.8.1 for the selected mutation owner','M',['domain/principal'],'Consumer transaction/Repo; TRUNCATE, exclusions, denied/no-mutation events and retention explicit.'),
('integration/ai-model','ADOPT','req_llm 1.30.0 + llm_db 2026.11.0; InstructorLite only if extraction earns it','M',['core/effect','delivery/effect-intent','integration/secrets'],'Select one provider/model; proposals as data, usage provenance and bounded retries.'),
('delivery/data-stream','ADOPT','gen_stage 1.3.2 / selected provider stream; Membrane only for media','M',['core/effect'],'Ready backpressure reused; no general engine for Enum/Stream work.'),
('integration/object-store','ADOPT','Recommend req_s3 0.2.5; ExAws S3 2.5.9 for larger operations; VFS 1.0.1 conditional','M',['core/effect','delivery/effect-intent','integration/secrets'],'Owner chooses A S3-only or B explicit local/S3 Need; backing store never hidden.'),
('state/artifact','WRAP','Selected object store + ready crypto/Store; owned references, integrity and retention','M',['integration/object-store'],'Storage does not supply content ownership; explicit versions, authority and expiry.'),
('integration/notification','ADOPT','swoosh 1.29.3 + selected provider/Req; Bamboo alternative, Pigeon for push','M',['core/effect','delivery/effect-intent','integration/secrets'],'Provider acceptance is not delivery; choose one email provider first.'),
('delivery/trigger','WRAP','Existing ELZ-027: crontab 1.2.1/Oban mechanisms plus occurrence Contract','M',[],'Existing schedule slice; other webhook/event slices separately admitted.'),
('state/scheduler','ADOPT','Existing Oban 2.24.2 staging/cron; no second Quantum runtime by default','M',['delivery/trigger'],'Coordinate occurrence identity; ready jobs currently do not promise recurring schedules.'),
('delivery/pubsub','ADOPT','phoenix_pubsub 2.4.1 or direct OTP pg for the required scope','S',[],'Volatile broadcast only; no all-subscriber consumption/durable replay claim.'),
('delivery/circuit-breaker','ADOPT','fuse 2.5.0 behind explicit permit/error boundary','M',[],'2021 last observed commit; exercise OTP 29 and preserve ready retry/backpressure policies.'),
('integration/observability','ADOPT','OpenTelemetry API/SDK/exporter 1.5.0/1.7.0/1.11.0; PromEx or LoggerJSON as needed','M',['runtime/telemetry'],'Choose exporter; bound cardinality, redaction, sampling and drops.'),
('workflow/work-item','WRAP','Ash resources + ash_state_machine 0.3.0, optional AshOban 0.10.3','M',['domain/principal','integration/auth-policy'],'Acceptance differs from job success; use state/lease only if the chosen authority model needs it.'),
('workflow/run','WRAP','Compare ready Oban/job lifecycle with Reactor 1.0.7 and Jizoku 0.4.0 before new machinery','L',['core/effect','delivery/effect-intent'],'Split attempts, child settlement, cancellation; work-item/lease dependencies conditional on caller.'),
('delivery/aggregation','WRAP','OTP Task.Supervisor/async_stream or Reactor for the selected fan-in','M',[],'Correlate branches, partial results and deadlines; workflow/run only for durable branches.'),
('delivery/resequence','CLEAN-ROOM','No exact fit identified; ready envelope/windowed dedup plus scoped sequence policy','M',[],'Targeted reuse search and gap/timeout/retention Contract before implementation.'),
('domain/metering','WRAP','Provider usage facts + ready Store/idempotency; retain units/provenance/corrections','M',['integration/ai-model'],'AI usage is one source, not universal prerequisite; telemetry alone is insufficient.'),
('domain/quota','WRAP','Ready workflow/budget plus retained allocation; Hammer 7.5.1 only for rate limits','M',['domain/membership','domain/entitlement','domain/metering'],'Define reset/release/reconciliation; time-window counters are not monthly quota.'),
('domain/pricing','CLEAN-ROOM','ExMoney arithmetic plus versioned tariff policy; llm_db estimates only as inputs','M',['domain/money','domain/metering'],'No exact tariff engine established; currency/rounding and immutable versions required.'),
('domain/journal','ADOPT','ash_double_entry 1.1.1 + compatible AshMoney/data-layer graph','M',['domain/money','state/audit-log'],'Test atomic balanced posting/reversal and retries; multi-line journals may exceed pair transfers.'),
('integration/payments','ADOPT','stripity_stripe 3.3.3 for a Stripe caller; exact provider otherwise','M',['core/effect','delivery/effect-intent','integration/secrets','domain/money'],'BSD notices; API version/webhooks/idempotency; no fork proposed.'),
('domain/payment-lifecycle','WRAP','Selected payment provider + Ash transitions/Reactor; pure owned reconciliation policy','M',['integration/payments','delivery/effect-intent'],'Separate authorize/capture/refund/unknown; journal required only for the selected settlement scope.'),
('delivery/model-routing','WRAP','llm_db 2026.11.0 metadata with ready selection/budget and explicit eligibility','M',['integration/ai-model'],'Quota/pricing depend on selected policy; no silent fallback across authority/region constraints.'),
('integration/sdk','ADOPT','ex_mcp 1.8.1 for client/protocol; PhantomMCP 0.8.0 or Ash AI for server-only scope','M',['core/effect','delivery/effect-intent','integration/secrets'],'Choose protocol/transport; stdio needs OS boundary. Copyleft Anubis excluded.'),
('integration/agent-runner','ADOPT','ExMCP 1.8.1 ACP boundary plus one acceptable provider CLI/runtime','M',['runtime/os-isolation','workflow/run','integration/sdk'],'Exact CLI/adapter license and lifecycle still gated; ClaudeCode SDK blocked by Anubis dependency.'),
('integration/search-data','ADOPT','Split TextChunker 1.0.1, pgvector 0.4.2, Floki 0.38.5, Explorer 0.13.0 by caller','L',[],'P2 chunking is S, vector Adapter M; retained references need artifact, embeddings need selected model.'),
('state/schema-evolution','CLEAN-ROOM','Current version refusal + specific upcast/migration; compare Commanded ideas','M',[],'Only a real format change earns work; frozen old reader/golden corpora, no CQRS kernel.'),
('workflow/build-graph','WRAP','Reactor graph execution / Flow with ready dependency readiness and artifact storage','L',['state/artifact','workflow/run'],'Caller fixes rebuild/cache/trace semantics; a DAG alone is not a build system.'),
('integration/message-broker','ADOPT','Broadway 1.3.1 + broadway_rabbitmq 0.8.2/amqp 4.3.0 for one broker','M',['core/effect'],'Select provider; reuse ready admission/dedup/DLQ, test crash/ack/redelivery. Other brokers separately checked.'),
('ui/component','ADOPT','phoenix_live_view 1.2.13 for Phoenix, or prior Lustre experiment','M',[],'Owner chooses host; no UI dependency imposed on other Pieces. Lustre pin not freshly rechecked.'),
('core/grounding','WRAP','Existing ELZ-033 evidence index + project checks/ledger','S',[],'Index-only resolution already recorded; no new badge/proof/evaluation runtime task.'),
('domain/value-types','WRAP','Index existing domain/money and separately admitted value recipes','S',['domain/money'],'Index-only, not a second executable money/value abstraction.'),
('domain/saas-controls','WRAP','Index membership/authorization/entitlement/quota and observation capabilities','S',['domain/membership','domain/entitlement','domain/quota'],'Index-only; dependencies describe links, not a new SaaS engine or readiness claim.'),
('assembly/http-job','WRAP','Existing ELZ-011 over ready Req/JSON/jobs and explicit Effects','M',['core/effect','delivery/effect-intent'],'Existing task, not a new Assembly proposal; live Contract governs actual dependencies.'),
('assembly/task-workflow','CLEAN-ROOM','Ash work resources + Oban + Swoosh + existing approval/readiness','L',['workflow/work-item','workflow/run','integration/notification','state/audit-log'],'Later Assembly wave; acceptance/current authority, not successful attempt alone.'),
('assembly/agent-product','CLEAN-ROOM','Selected model/runner/tool Adapters + ready authority/approval/budget/context/readiness','L',['integration/ai-model','workflow/run','integration/agent-runner'],'Later Assembly wave; no privileged agent kernel or universal hierarchy.'),
('assembly/tenant-edge','CLEAN-ROOM','Identity/membership/entitlement/quota/metering/pricing composition','L',['integration/identity','domain/membership','domain/entitlement','domain/quota','domain/pricing'],'Later Assembly wave; tenant authority and billing meaning explicit.'),
('assembly/ledger-checkout','CLEAN-ROOM','AshDoubleEntry + payment Adapter/lifecycle + optional Reactor','L',['domain/journal','integration/payments','domain/payment-lifecycle'],'Later Assembly wave; external payment and atomic journal are separate settlement facts.'),
('assembly/data-pipeline','CLEAN-ROOM','Explorer/Flow/Broadway with explicit storage and optional rebuild graph','L',['delivery/data-stream','state/artifact','integration/search-data'],'Later Assembly wave; build-graph only if workload requires rebuild/cache semantics.'),
('assembly/device-ingest','CLEAN-ROOM','Selected broker + ready dedup/window/backpressure + device principal mapping','L',['integration/message-broker','domain/principal'],'Later Assembly wave; no implicit new MQTT/device control kernel.'),
('assembly/consent-records','CLEAN-ROOM','Selected identity/authority/audit/artifact mechanisms; FHIR provider still unverified','L',['integration/identity','integration/auth-policy','state/audit-log','state/artifact'],'Classified-record caller, consent/retention rules and exact FHIR boundary required before admission.'),
('state/crdt','ADOPT','delta_crdt 0.6.5 / horde 0.10.0 for a selected replication/registry caller','L',[],'Conditional research tier; partition/convergence and maintenance evidence first, no writer-lease claim.'),
('state/replication','ADOPT','ra 3.2.0 or khepri 0.19.3 under Apache-2.0 option and recorded full license closure','L',[],'Conditional research tier; real caller and owner batch selection, no Ra/Khepri forks.')
]
ids=[r[0] for r in ROWS];assert len(ids)==len(set(ids))==56
catalogue=json.load(open('registry/catalogue.json'))['entries'];expected={e['id'] for e in catalogue if e.get('status') in ['planned','deferred']};assert set(ids)==expected,(set(ids)-expected,expected-set(ids))
order={x:i+1 for i,x in enumerate(ids)}
for ident,_,_,_,deps,_ in ROWS:
 for dep in deps:assert order[dep]<order[ident],(ident,dep)
lines=['| Rank | Catalogue entry | Disposition | Candidate / bounded remaining responsibility | Size | Dependency order | Gate / limit |','| --- | --- | --- | --- | --- | --- | --- |']
for ident,disposition,candidate,size,deps,gate in ROWS:
 deptext=', '.join('R%02d'%order[d] for d in deps) or 'Ready foundations / no new-entry prerequisite'
 lines.append(f'| R{order[ident]:02d} | `{ident}` | {disposition} | {candidate} | {size} | {deptext} | {gate} |')
(ROOT/'ecosystem-ranking-table-2026-11-08.json').write_text(json.dumps([{'rank':order[r[0]],'id':r[0],'disposition':r[1],'candidate':r[2],'size':r[3],'dependencies':r[4],'gate':r[5]} for r in ROWS],indent=2)+'\n')
print('\n'.join(lines))
