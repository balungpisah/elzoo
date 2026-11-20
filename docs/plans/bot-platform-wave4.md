# Wave 4 — Events in, answers out

## Status and scope

ELZ-245 is an executable fit spike with no Piece output; ELZ-246's delivery/debounce and ELZ-247's domain/trigger-binding Pieces are ready on main. Level 2 Pieces ELZ-249 (assembly/checked-command) and ELZ-250 (state/conversation), and ELZ-252's root consumer acceptance, are merged. The linked [ELZ-252 report](../research/wave4-command-conversation.md) records finite Memory/PostgreSQL composition and native RunEngine parity evidence. The first-party signed plain-text webhook remains the selected Level 3 source; ELZ-256/#585, ELZ-257/#586 and native acknowledgement repair ELZ-259/#591 are merged. [ELZ-258/#590](../../tasks/ELZ-258-signed-channel-acceptance.md) records the immediate v1 channel path. The v2 event-wait Contracts [ELZ-263](../../tasks/ELZ-263-pattern-step-v2.md), [ELZ-264](../../tasks/ELZ-264-bot-run-lifecycle-v2.md) and [ELZ-265](../../tasks/ELZ-265-run-engine-v2-event-waits.md) are merged. [ELZ-266](../../tasks/ELZ-266-fixed-two-source-root-channel.md) is merged on `main` (`PR #613`), adding finite fixed-two-source root composition evidence while preserving v1. This does not claim generic streaming, provider authentication, broker/subscriber guarantees or unexercised channel profiles; RC-06 identity-provider work remains deferred to Wave 5.

The first-level task Contracts and issues are:

- [ELZ-245 task](../../tasks/ELZ-245-command-store-fit.md) · [issue #556](https://github.com/balungpisah/elzoo/issues/556)
- [ELZ-246 task](../../tasks/ELZ-246-debounce.md) · [issue #557](https://github.com/balungpisah/elzoo/issues/557)
- [ELZ-247 task](../../tasks/ELZ-247-trigger-binding.md) · [issue #558](https://github.com/balungpisah/elzoo/issues/558)

The proposed Level 2 task Contracts are:

- [ELZ-249 task](../../tasks/ELZ-249-checked-command.md) · [issue #565](https://github.com/balungpisah/elzoo/issues/565)
- [ELZ-250 task](../../tasks/ELZ-250-conversation.md) · [issue #566](https://github.com/balungpisah/elzoo/issues/566)

The mandatory later-level root consumer acceptance is:

- [ELZ-252 task](../../tasks/ELZ-252-command-conversation-acceptance.md) · [issue #570](https://github.com/balungpisah/elzoo/issues/570)

The selected Level 3 source prerequisite Contracts are:

- [ELZ-256 task](../../tasks/ELZ-256-run-engine-result.md) · [issue #585](https://github.com/balungpisah/elzoo/issues/585) — in-place RunEngine result API, no output Piece
- [ELZ-257 task](../../tasks/ELZ-257-webhook-in.md) · [issue #586](https://github.com/balungpisah/elzoo/issues/586) — new signed first-party webhook ingress Piece

The Level 1–4 task Contracts and root consumer acceptances (`ELZ-252`, `ELZ-258`, `ELZ-266`) are all merged on `main` with a green push run (`bc957f40`). Each report establishes only its finite tested composition; broader provider authentication, multi-tenant isolation and generic broker/subscriber policies are outside Wave 4 and hand off to [bot-platform-wave5.md](bot-platform-wave5.md).

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
- [PatternStep](../../pieces/workflow/pattern-step/README.md) preserves its v1 behavior and adds the separately selected v2 `wait_event`/`outside_event` contract in ELZ-263. ELZ-264 adds the corresponding lifecycle behavior; ELZ-265 adds RunEngine activation, source reads and inspection. These v2 paths require caller-supplied verified identity, serialization and durable provider ownership; they do not create a generic provider or broker guarantee.

The five supplied research reports informed these dispositions, but they are evidence and proposals rather than final Contracts. Each future task must recheck the exact source at its base and add acceptance for the composition it actually uses. No reuse verdict below claims that all reuse cases have already been exercised.

## All 24 candidate handles

| Candidate handle | Disposition | Dependency level and boundary |
| --- | --- | --- |
| integration/http-server | Reuse upstream HTTP server primitives inside one bounded webhook adapter; no server façade Piece. | Level 3, after one source and admission boundary are selected. Listener lifecycle, TLS termination, proxy policy and supervision stay with the host. |
| integration/signature | Reuse OTP MAC/hash comparison primitives inside the webhook adapter; no generic signature wrapper. | Level 3, coupled to the chosen raw-byte webhook profile and credential Need. A valid body MAC is not human authentication or replay prevention. |
| integration/event-source | Keep provider-specific normalization with the concrete source adapter; no generic source registry yet. | Conditional Level 3: choose a source and its stable identity, cursor, rate-limit and retry contract first. |
| integration/webhook-in | Selected bounded adapter for the first-party signed plain-text source; no separate HTTP-server/signature/source façades. | Level 3: ELZ-257 defines this Piece using existing providers and host-vouched identity; no listener or other channel is added. |
| delivery/debounce | New pure trailing-edge policy, ELZ-246. | Level 1. One caller-owned partition; host owns monotonic samples, serialization and tokenized timer scheduling. |
| delivery/event-trigger | Reuse/composition over a verified source, trigger binding and checked-command host path. | Level 2 or 3 after source identity, binding revision and command result semantics are settled; do not add a new Piece without a demonstrated independent policy. |
| domain/trigger-binding | New pure declaration validation and bounded selector, ELZ-247. | Level 1. No authentication, persistence, package loading, priority or Run creation. |
| workflow/bot-routing | Reuse/composition of trigger-binding, existing person-answer routing and host Run association; no generic bot router. | Level 2 or 3 after the conversation/Run association and concurrency fence are explicit. |
| workflow/event-wait | Extend PatternStep, BotRunLifecycle and RunEngine in place; no parallel event-wait runtime Piece. | The selected v2 wait Contracts are merged in ELZ-263/264/265. ELZ-266 tests a finite fixed-source root composition; broader provider/subscriber policy remains conditional. |
| delivery/poll-trigger | Reuse schedule occurrence and a selected provider's read API; no generic poller. | Conditional Level 3, only after a concrete source/cursor contract. Empty page, expired cursor, malformed response and indeterminate commit must remain distinct. |
| state/schema-evolution | Admit only with an actual changed persisted format; no speculative generic migration framework. | Conditional on the first real format change, with old-format fixtures and a pinned reader. It is not a first-level prerequisite. |
| delivery/durable-idempotency | ELZ-245 is the fit spike, with no Piece output; do not create a Piece before its result. | Level 1 spike; a production API task may follow only if evidence supports the selected API and at least one fixed caller has a gap requiring it. Inconclusive or complementary partial fits support no recommendation. No TTL that permits re-execution. |
| delivery/pubsub | Reuse Store/outbox plus consumer-owned relay as the initial durable transport; use a broker only if a concrete provider contract warrants it. | Level 2 or 3. Do not adopt a broker merely because the handle is named pubsub; do not claim multicast cursors or durable subscriber state. |
| delivery/event-emit | Reuse Envelope and the selected Store/outbox command path; no separate event-emission façade now. | Level 2 or 3 after event identity, authorization and commit result semantics are defined. Remote effects remain outside the transaction. |
| delivery/event-subscription | Reuse/composition of outbox and relay for the fixed channel; no general subscriber or broker Piece is inferred. | ELZ-263/264/265 define the selected v2 wait behavior and ELZ-266 covers one fixed two-source composition. Other provider cursor, retention and subscriber policies remain source-specific and conditional; relay reuse alone is not a generic subscription guarantee. |
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

**Level 3 — concrete adapters and channel composition:** the selected source is the signed first-party plain-text webhook. The ELZ-256 and ELZ-257 tasks are merged prerequisites; ELZ-256 extends the existing RunEngine result API without an output Piece, while ELZ-257 defines `integration/webhook-in`. Native acknowledgement repair ELZ-259 is also merged. ELZ-258 records the bounded immediate-v1 HTTP-to-native-answer path with scoped read-only GET. ELZ-263/264/265 are merged v2 wait Contracts; ELZ-266 merged finite two-source root acceptance (`PR #613`). None of these claims streaming, provider authentication, generic broker adoption or general subscriber guarantees. Add live streaming or upload only for a demonstrated first-channel need. The Store/outbox and consumer-owned relay remain the fixed composition's durable transport option; no general broker or subscriber-cursor claim is implied.

**Level 4 — outside-event wait, in place:** ELZ-263/264/265 merged the selected v2 PatternStep, lifecycle and RunEngine wait Contracts, and ELZ-266 merged their fixed two-source root composition (`PR #613`). A timer, process-local Registry or relay poll is not by itself a durable wait; truthful callbacks, retained history, serialized writes and full provider fencing remain explicit host Needs. Broader generic event subscription, broker adoption and provider authentication remain conditional, with identity-provider work deferred to Wave 5.

**Conditional, not a level prerequisite:** state/schema-evolution follows an actual persisted-format change. The identity provider stays in Wave 5. Reuse-only handles stay visible above and are not separate task rows unless a later caller exposes an independently bounded policy gap.

## Wave 4 closure and open-defect handoff

All published Wave 4 tasks (`ELZ-245` through `ELZ-266`) are merged on `main` (`bc957f40`, push check green). No runtime blockers remain for Wave 5:

- **Resolved on `main` (close stale tracker issues with commit refs):**
  - `#509` — resolved by `ELZ-241` (`PR #553`, `4000a37c`: close child callables when a `nested_callable` slot settles).
  - `#514` — resolved by `ELZ-242` (`PR #546`, `4774685f`: observation test + host-fencing rule documented in `pieces/assembly/run-engine/README.md`).
  - `#526` — resolved by `ELZ-240` (`PR #552`, `08f470fc`: keep sent Resource actions open at recovery).
- **Open harness/flake items (non-blocking for Wave 5 start; track for CI health):** `#547` (`runtime/recipe-test` 500 ms `wall_ms` ceiling under local gate load), `#581` (copied-consumer child cleanup after ExUnit timeout), and `#584` (intermittent `assembly/http-job` confirmation timeout in hosted `root-b`).

## Provider prerequisites and open decisions

Level 1 adds no new provider or pin change for ELZ-246 or ELZ-247; ELZ-247 declares the existing cure and elixir providers required by its copied source closure. ELZ-245 uses the root Mix environment and its existing Ecto SQL 3.14.0/Postgrex 0.22.4 pins and dependency closure; it adds no provider, dependency resolution or export project. A future inbound adapter still needs one explicit server-library/version decision if the existing toolchain does not already provide a supported direct dependency. Keep that as a separate provider prerequisite before the adapter task; do not infer a production dependency from the test-only Plug.Cowboy server. No broker is admitted by the pubsub handle. Object upload reuses the existing object-store provider only if the first-channel need is selected. Full identity-provider adoption remains Wave 5.
