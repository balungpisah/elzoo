# Wave 4 — Events in, answers out

## Status and scope

This plan records Level 1: ELZ-245 is an executable fit spike with no Piece output; ELZ-246's delivery/debounce and ELZ-247's domain/trigger-binding Pieces are ready on main. It proposes Level 2 Pieces ELZ-249 (assembly/checked-command) and ELZ-250 (state/conversation), plus the later-level root consumer acceptance ELZ-252. ELZ-252 may be published early with these prerequisites, but remains unready until ELZ-249 and ELZ-250 are merged; it also depends on ELZ-127. Levels 3 and 4 otherwise remain unadmitted. No Level 2 implementation begins until publication has merged and the Piece issues carry the task label; ELZ-252 cannot begin before its dependencies merge.

The first-level task Contracts and issues are:

- [ELZ-245 task](../../tasks/ELZ-245-command-store-fit.md) · [issue #556](https://github.com/balungpisah/elzoo/issues/556)
- [ELZ-246 task](../../tasks/ELZ-246-debounce.md) · [issue #557](https://github.com/balungpisah/elzoo/issues/557)
- [ELZ-247 task](../../tasks/ELZ-247-trigger-binding.md) · [issue #558](https://github.com/balungpisah/elzoo/issues/558)

The proposed Level 2 task Contracts are:

- [ELZ-249 task](../../tasks/ELZ-249-checked-command.md) · [issue #565](https://github.com/balungpisah/elzoo/issues/565)
- [ELZ-250 task](../../tasks/ELZ-250-conversation.md) · [issue #566](https://github.com/balungpisah/elzoo/issues/566)

The mandatory later-level root consumer acceptance is:

- [ELZ-252 task](../../tasks/ELZ-252-command-conversation-acceptance.md) · [issue #570](https://github.com/balungpisah/elzoo/issues/570)

The Level 1 registration does not claim Wave 4 runtime implementation. ELZ-252 has no Piece output and must pass before durable-conversation, native RunEngine parity or Wave 4 completion is claimed.

## Source boundaries checked

These are source facts used to distinguish fit from proposal; they do not prove every future composition has been exercised.

- The [Store callback](../../pieces/state/event-log/lib/elzoo/durable_log/store.ex) appends records and outbox items against one stream revision. The [PostgreSQL Store](../../pieces/integration/sql/lib/elzoo/durable_log/postgres.ex) commits its own operation and refuses writes from a caller-owned transaction; [ELZ-032 tests](../../pieces/integration/sql/test/elzoo/durable_log_postgres_test.exs) assert unchanged storage on caller-transaction refusal. [Confirmation](../../pieces/state/event-log/lib/elzoo/durable_log/confirmation.ex) separates known and uncertain outcomes. This justifies the ELZ-245 comparison, not an assumption that arbitrary domain rows can join a Store append.
- [Authorization](../../pieces/domain/authorization/lib/elzoo/authorization.ex) receives trusted context separately from the proposal. [Approval](../../pieces/workflow/approval/lib/elzoo/approval.ex) supplies reducer behavior, not durable storage. [RunEngine](../../pieces/assembly/run-engine/lib/elzoo/run_engine.ex) has Run-specific gate, approval and commit ordering; a no-Run command cannot claim those boundaries merely by reusing the reducer.
- [Envelope](../../pieces/core/envelope/lib/elzoo/envelope.ex) validates the declared versioned message shape. Its producer, correlation and idempotency fields are data, not transport authentication.
- [WindowedIdempotency](../../pieces/delivery/windowed-idempotency/lib/elzoo/windowed_idempotency.ex) is a bounded sequence-window policy, not time debounce. The [timer example](../../pieces/delivery/time/examples/elzoo/timers.exs) demonstrates scheduling and matching a tagged timer message; it does not demonstrate cancellation, a pure transition or debounce policy.
- [RecipeGraph](../../pieces/domain/recipe-graph/lib/elzoo/recipe_graph.ex) validates named graph bindings shaped as name/target. [RecipeConfig](../../pieces/domain/recipe-config/lib/elzoo/recipe_config.ex) checks caller settings against a descriptor. Neither implements tenant/source/schema trigger selection.
- The [delivery trigger README](../../pieces/delivery/trigger/README.md) explicitly scopes the ready contract to schedule occurrences, not webhook or app-event triggers. [Routing](../../pieces/delivery/routing/lib/elzoo/routing.ex) selects declared wiring edges and returns no-route or ambiguity; it does not select a bot or allocate a Run.
- The [HTTP recipe](../../pieces/integration/http/README.md) is a Req client, not an inbound server. The [crypto recipe](../../pieces/integration/crypto/README.md) uses OTP SHA-256; neither is a webhook authentication policy.
- [Outbox relay](../../pieces/integration/jobs/lib/elzoo/jobs/relay.ex) consumes an existing outbox stream; it is not a generic broadcast, subscriber-cursor or replay-barrier Contract. [Artifact](../../pieces/state/artifact/README.md) composes staged single-shot object storage and explicitly does not provide streaming upload.
- [PatternStep](../../pieces/workflow/pattern-step/README.md) v1 has no outside-event wait action. [BotRunLifecycle](../../pieces/workflow/bot-run-lifecycle/lib/elzoo/bot_run_lifecycle.ex) does not settle a generic outside event, and [RunEngine](../../pieces/assembly/run-engine/lib/elzoo/run_engine.ex) treats resource events as a separate correlated path.

The five supplied research reports informed these dispositions, but they are evidence and proposals rather than final Contracts. Each future task must recheck the exact source at its base and add acceptance for the composition it actually uses. No reuse verdict below claims that all reuse cases have already been exercised.

## All 24 candidate handles

| Candidate handle | Disposition | Dependency level and boundary |
| --- | --- | --- |
| integration/http-server | Reuse upstream HTTP server primitives inside one bounded webhook adapter; no server façade Piece. | Level 3, after one source and admission boundary are selected. Listener lifecycle, TLS termination, proxy policy and supervision stay with the host. |
| integration/signature | Reuse OTP MAC/hash comparison primitives inside the webhook adapter; no generic signature wrapper. | Level 3, coupled to the chosen raw-byte webhook profile and credential Need. A valid body MAC is not human authentication or replay prevention. |
| integration/event-source | Keep provider-specific normalization with the concrete source adapter; no generic source registry yet. | Conditional Level 3: choose a source and its stable identity, cursor, rate-limit and retry contract first. |
| integration/webhook-in | New bounded adapter candidate, not three separate HTTP-server/signature/source façades. | Level 3, after the source profile and durable-command receipt boundary are chosen; preserve original bytes, bound reads and fail closed before admission. |
| delivery/debounce | New pure trailing-edge policy, ELZ-246. | Level 1. One caller-owned partition; host owns monotonic samples, serialization and tokenized timer scheduling. |
| delivery/event-trigger | Reuse/composition over a verified source, trigger binding and checked-command host path. | Level 2 or 3 after source identity, binding revision and command result semantics are settled; do not add a new Piece without a demonstrated independent policy. |
| domain/trigger-binding | New pure declaration validation and bounded selector, ELZ-247. | Level 1. No authentication, persistence, package loading, priority or Run creation. |
| workflow/bot-routing | Reuse/composition of trigger-binding, existing person-answer routing and host Run association; no generic bot router. | Level 2 or 3 after the conversation/Run association and concurrency fence are explicit. |
| workflow/event-wait | Extend PatternStep, BotRunLifecycle and RunEngine in place; no parallel event-wait runtime Piece. | Level 4, after an event-subscription activation/replay/gap Contract. Use separate Piece-scoped tasks; do not overlap edits to one Piece. |
| delivery/poll-trigger | Reuse schedule occurrence and a selected provider's read API; no generic poller. | Conditional Level 3, only after a concrete source/cursor contract. Empty page, expired cursor, malformed response and indeterminate commit must remain distinct. |
| state/schema-evolution | Admit only with an actual changed persisted format; no speculative generic migration framework. | Conditional on the first real format change, with old-format fixtures and a pinned reader. It is not a first-level prerequisite. |
| delivery/durable-idempotency | ELZ-245 is the fit spike, with no Piece output; do not create a Piece before its result. | Level 1 spike; a production API task may follow only if evidence supports the selected API and at least one fixed caller has a gap requiring it. Inconclusive or complementary partial fits support no recommendation. No TTL that permits re-execution. |
| delivery/pubsub | Reuse Store/outbox plus consumer-owned relay as the initial durable transport; use a broker only if a concrete provider contract warrants it. | Level 2 or 3. Do not adopt a broker merely because the handle is named pubsub; do not claim multicast cursors or durable subscriber state. |
| delivery/event-emit | Reuse Envelope and the selected Store/outbox command path; no separate event-emission façade now. | Level 2 or 3 after event identity, authorization and commit result semantics are defined. Remote effects remain outside the transaction. |
| delivery/event-subscription | Reuse/composition of outbox and relay until an independent bounded subscription policy is demonstrated. | Level 3. Durable waits still need explicit activation barrier, replay, retention and gap behavior; relay reuse alone does not supply it. |
| domain/principal | No principal-authentication wrapper or delivered principal Piece. A host-vouched authenticated context is a bounded Wave 4 caller assumption/Need. | Level 2 Need, not a Level 1 Piece. RC-06 identity-provider work remains deferred to Wave 5; Wave 4 does not claim provider authentication. |
| assembly/checked-command | ELZ-249 proposes a no-Run Assembly for checked, authorized declarative writes through the existing Store. | Level 2 after ELZ-245 evidence and its listed prerequisites; requires exact authorized writes, retained identity/result, revision fencing, explicit unknown outcomes, result scope `%{tenant:, actor:}` and resource read scope `%{tenant:, actor:, resources:}`. |
| state/conversation | ELZ-250 proposes pure bounded conversation DTO/codec/policy for immutable messages and input/Run associations. | Level 2 depends only on ELZ-024 and can be implemented in parallel with ELZ-249; both Contracts define the same resource-read scope `%{tenant:, actor:, resources:}`. Its values use the existing Authorization domain: `{:text, binary}` for text, bare integers and `true`/`false`; no unfinished-module import or persistence claim. |
| domain/end-user | Reuse the host-vouched principal attribution in the first caller; no independent identity/profile service. | Level 2 Need with the first-party web conversation caller; identity resolution remains the host/provider boundary. |
| integration/channel | Non-Piece consumer composition for the bounded first-party web channel, which is the first conversation caller. | Level 3 after conversation and host-vouched context contracts; do not generalize to Slack, WhatsApp, Telegram or email adapters. |
| domain/channel-identity | Keep transport identity linkage in the host-vouched context/channel contract; no separate account-link database absent a distinct lifecycle. | Level 2 Need with principal and first-party channel decisions. |
| delivery/message-render | Reuse ordinary encoding and channel-local presentation; no universal renderer. | Level 3, with the first channel's plain text and safe artifact-reference needs only. |
| delivery/client-stream | Conditional new Piece candidate for request-scoped outbound streaming pressure, timeout and disconnect policy. | Level 3 only if the first channel requires bounded live streaming; do not wrap a normal upstream response API. |
| delivery/file-upload | Reuse state/artifact and integration/object-store staged lifecycle; no upload façade. | Level 3 if the first channel requires upload. Existing artifact upload is bounded and single-shot, not streaming or malware scanning. |

## Dependency levels

**Level 0 — existing source owners:** ELZ-009 owns the Store/outbox/SQL boundary; ELZ-010 supplies an existing durable-job composition; ELZ-024 owns authorization and approval; ELZ-027 owns schedule occurrence; ELZ-032 owns the caller-transaction refusal; ELZ-033 is the P13 plan; ELZ-114 and ELZ-124 own the current pattern-step/lifecycle protocols; ELZ-127 owns the RunEngine Assembly.

**Level 1 — source outputs:** ELZ-245 is a bounded fit spike with no output Piece; ELZ-246 and ELZ-247 are pure Pieces ready on main. Their owned paths are disjoint, and neither Piece depends on the other.

**Level 2 — only after Level 1 evidence:** ELZ-249 is a Piece-only slow-lane Assembly over the existing Store and depends on ELZ-245, ELZ-247, ELZ-024, ELZ-009, ELZ-032, ELZ-114, ELZ-115 and ELZ-127. Its result scope is `%{tenant:, actor:}` and resource read scope is `%{tenant:, actor:, resources:}`. Its real PostgreSQL tests, including controlled fault cases, stay inside the Piece; its concrete PostgreSQL binding example declares the SQL dependency/provider closure. It does not add a root test or import RunEngine. ELZ-250 defines the pure conversation DTO/codec/policy over ELZ-024 only and can be implemented in parallel; both Contracts fix their shared resource-read scope without importing an unfinished module or claiming persistence. Conversation text uses `{:text, binary}` and integers/booleans use bare values in the existing Authorization portable domain. Its immutable association allows multiple inputs to share one host-allocated stable Run ID, not proof of process start or completion. ELZ-252 is the mandatory later-level root consumer acceptance, depending on ELZ-249, ELZ-250 and ELZ-127, with no Piece output. Its early publication does not make it ready: ELZ-249 and ELZ-250 must merge first. ELZ-252 must invoke the actual public RunEngine and pass real Memory/PostgreSQL composition including retained denial/replay, CAS, duplicate-message behavior and native parity. It must pass before durable conversation, native parity or Wave 4 completion is claimed. Publication remains gated on ELZ-245 acceptance and a green current main. Event-trigger and event-emit remain host compositions over these selected boundaries. Host-vouched authenticated context is a bounded first-party caller assumption/Need, not a delivered principal Piece; RC-06 identity-provider work remains deferred to Wave 5.

**Level 3 — concrete adapters and channel composition:** select an actual event source before webhook-in or polling work. Compose the bounded first-party web channel on the conversation/host-context boundary. Add live client streaming or upload only for a demonstrated first-channel need. The Store/outbox and consumer-owned relay are the initial durable transport option; no general broker adoption or subscriber-cursor claim is implied.

**Level 4 — outside-event wait, in place:** first settle the event-subscription activation/replay/retention/gap boundary, then extend the existing PatternStep protocol, BotRunLifecycle and RunEngine in separate Piece-owned tasks. A timer, process-local Registry or relay poll is not by itself a durable wait.

**Conditional, not a level prerequisite:** state/schema-evolution follows an actual persisted-format change. The identity provider stays in Wave 5. Reuse-only handles stay visible above and are not separate task rows unless a later caller exposes an independently bounded policy gap.

The first-level task Contracts and planned Piece rows are registered by this publication. Levels 2 and later remain dependency proposals; none of those proposals is a runtime implementation or permission to start work before its own task is published and labeled.

## Provider prerequisites and open decisions

Level 1 adds no new provider or pin change for ELZ-246 or ELZ-247; ELZ-247 declares the existing cure and elixir providers required by its copied source closure. ELZ-245 uses the root Mix environment and its existing Ecto SQL 3.14.0/Postgrex 0.22.4 pins and dependency closure; it adds no provider, dependency resolution or export project. A future inbound adapter still needs one explicit server-library/version decision if the existing toolchain does not already provide a supported direct dependency. Keep that as a separate provider prerequisite before the adapter task; do not infer a production dependency from the test-only Plug.Cowboy server. No broker is admitted by the pubsub handle. Object upload reuses the existing object-store provider only if the first-channel need is selected. Full identity-provider adoption remains Wave 5.
