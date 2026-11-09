# integration/mcp-client

One MCP server over the Streamable HTTP transport, through `ex_mcp` 1.8.1 (MIT), as a
`delivery/effect-intent` Adapter admitted from a `core/effect` declaration. Tool
discovery is inert, bounded, untrusted data; a tool is called only when the caller
hands over an execution request with its exact-action release reference, and at most
once per dispatch identity. The owner's first real MCP server is not named yet; the
evidence peer is an in-process loopback server (a README update will name the first
real server).

## Interface

- `use Elzoo.McpClient.Binding, id:, server:, endpoint:, network:, recovery_grace_ms:`
  fixes the server identity, the one allowlisted endpoint URL and its network policy
  (`:loopback` accepts only `127.0.0.1`, `localhost` and `::1`; `:private` and
  `:public` require `https`). All enter the intent key.
- `Elzoo.McpClient.configure/1` — `binding`, `tenant`, `credentials` (the credential
  Need: a zero-arity function returning `{:ok, bearer_token}`), `protocol_mode`
  (`:modern_only`, `:legacy_only`, `:prefer_modern`), `call_timeout_ms`,
  `handshake_timeout_ms`, `max_request_bytes`, `max_response_bytes`, `max_pages`,
  `max_tools`, `max_descriptor_bytes`. Nothing else is accepted; no hot update.
- `connect(config, dynamic_supervisor)` / `close(session)` — the `ExMCP.Client` runs
  under the caller's supervisor as `:temporary`.
- `list_tools(session)` — `{:ok, %{server, protocol_version, tools, truncated}}`; each
  descriptor is `%{"trust" => "untrusted", "name", "description", "input_schema",
  "annotations"}`. Annotations (`readOnlyHint` and others) and descriptions are
  carried, never read.
- `admission(config, declaration, snapshot)` — a `core/effect` declaration
  (untrusted; capability `integration/mcp-client`; operation `tools/call`; schema
  `elzoo/mcp-tool-call` v1; `idempotency_key`; `deadline_unix_ms`) whose payload is
  exactly `{"version": 1, "tool", "arguments", "release"}`. The release reference is
  shape-checked (1..256 of `[A-Za-z0-9._:/@-]`) and recorded in the declaration, never
  verified here. The caller's discovery snapshot may only narrow admission.
- `context(session, recipient)` — the EffectIntent Adapter context;
  `call_tool(session, admission, owner)` dispatches through the owner and returns the
  outcome.

## Outcomes

| Outcome | When | Envelope outcome / dispatch / error class | Attested no-send |
| --- | --- | --- | --- |
| `completed{content, is_error, structured}` | the server's tool result, including a tool-level error (`isError`) | `completed` / `dispatched` | — |
| `refused{unknown_tool}` | the tool is absent from the caller's discovery snapshot (local, possibly stale) | `rejected` / `not_dispatched` / `permanent` | yes |
| `refused{invalid_arguments}` | arguments are not an object or fail the snapshot input schema (local) | `rejected` / `not_dispatched` / `permanent` | yes |
| `refused{too_large}` | request over `max_request_bytes`, or refused by the transport before sending | `rejected` / `not_dispatched` / `permanent` | yes |
| `refused{target_refused}` | ex_mcp's target policy or credential-origin guard refused before sending | `rejected` / `not_dispatched` / `permanent` | yes |
| `refused{credentials_unavailable}` | the credential Need fails, raises, throws, exits or returns another shape | `timed_out` / `not_dispatched` / `unavailable` | yes |
| `refused{not_connected}` | the session is closed or the connection failed before a byte | `timed_out` / `not_dispatched` / `unavailable` | yes |
| `refused{invalid_request}` | at admission only: malformed declaration payload or release reference; no intent | — | — |
| `refused{authentication_failed}` | HTTP 401 or 403 (named upstream assumption that nothing ran) | `failed` / `dispatched` / `permanent` | no |
| `unknown{{server_error, subtype}}` | any JSON-RPC error or HTTP error status after sending; subtype `invalid_arguments`, `invalid_request`, `protocol_error` or `other` | `unknown` / `dispatched` / `unclassified` | no |
| `unknown{input_required}` | an MCP 2026-07-28 `input_required` result (never continued) | `unknown` / `dispatched` / `unclassified` | no |
| `unknown{malformed_response}` | unparseable, incomplete or oversize response | `unknown` / `dispatched` / `unclassified` | no |
| `unknown{timeout}` | no answer within `call_timeout_ms` | `timed_out` / `unknown` / `retryable` | no |
| `unknown{connection_lost}` | broken connection or stream after sending, or the client stopped during the call | `unknown` / `unknown` / `unavailable` | no |
| `unknown{adapter_error}` | anything else, including an unattested pre-send failure | `unknown` / `unknown` / `unclassified` | no |

The Adapter returns `{:error, tag, :mcp}` to the owner; `Elzoo.McpClient.outcome(tag)`
gives the Contract outcome. No server text, argument or exception leaves the Adapter.
`poll/1` is `{:unavailable, :mcp_has_no_status}`: an `unknown` outcome stays unknown
until host/operator reconciliation through the EffectIntent owner.

**Result delivery.** The intent store keeps only a sealed digest (HMAC under a
process-local key; integrity of our own result, not server authentication). The full
outcome goes to the context's recipient Need by best-effort mailbox delivery. That
message is sent **before** the owner commits the settlement, so it is not a settlement:
a recipient other than `call_tool/3` must confirm through the owner
(`Elzoo.EffectIntent.status/1`) before treating a completion as settled.
`call_tool/3` returns `{:completed, _}` only after observing the owner's confirmed
phase; otherwise (within a bounded wait) `{:unknown, :settlement_unconfirmed}`. If the
recipient has exited, the content is lost and the settlement is unchanged; a consumer
that needs durable content retains it after receipt.

**Credential redaction.** The credential never appears in a result: every occurrence
of the exact credential bytes (resolved through the Need before and after the call) in
any string of a tool result or a discovery descriptor, map keys included, is replaced
by `[redacted]` before delivery and before the digest. Other encodings of the
credential (base64, split or escaped forms) are not detected.

## No resend (ex_mcp 1.8.1 settings, each tested)

- Client: the Elzoo fail-closed `auth_provider` (its 401/403 callbacks always refuse,
  so ex_mcp neither resends nor starts its inline OAuth flow, which it otherwise does
  on a `WWW-Authenticate: Bearer` challenge), `reconnect: false`,
  `health_check_interval: nil`, `use_sse: false` (no standalone GET stream; server
  requests inside a response are dropped unanswered), no `:handler`, no
  `:capabilities`, no client `:retry_policy`, never `conformance_mode`.
- Every `tools/list`: `retry_policy: false, http_stream_retry: :safe_only`.
- Every `tools/call`: the same plus `max_mrtr_rounds: 0`, never `retry_safe`, sent
  through `ExMCP.Client.make_request/5`. **Upstream risk:** `make_request/5` is
  `@doc false` at 1.8.1; it is used because `ExMCP.Client.call_tool/4` resends
  `tools/call` after a `-32020` header-mismatch error and no option disables that.
  `ex_mcp` is pinned exactly (`== 1.8.1`), and drift tests (exactly one `tools/call`
  for `-32020`, a killed connection, a 503, a stall, `input_required` and a refused
  401/403; a broken request-owned stream under `:safe_only`) fail loudly on an upgrade
  that changes this.

**Protocol traffic.** `connect/2` sends only the handshake: `server/discover` when the
mode probes the modern era; `initialize` and `notifications/initialized` on a legacy
revision. Afterwards only `tools/list` and `tools/call`; after a legacy timeout ex_mcp
may send `notifications/cancelled`; `close/1` on a legacy session sends the session
`DELETE`. **Server-initiated requests** embedded in the response to one of the
Adapter's own requests (with `use_sse: false`, the only way one can arrive) are
dropped unanswered by ex_mcp, `ping` included, and disclose no host data. Only where a
server request reaches a receiving stream (which the Adapter never opens) are
`roots/list`, `sampling/createMessage`, `elicitation/create` and custom methods
refused (no handler, no capabilities) without disclosing any path, model or
credential, and a `ping` acknowledged with `{}`.

## Needs

- **Credential Need** (bearer token): called before each request, inside ex_mcp's
  client process; never stored by this Piece, never logged; `integration/secrets` is
  deferred, so the host supplies it.
- **Recipient Need**: a trusted local process for tool results.
- **Application**: the consumer starts `ex_mcp`'s application (it starts its own
  supervisors, and needs `plug_cowboy`/`cowboy` even for client use).

## Grounding

- Proof: none.
- Type/contract check: pinned Cure compiles `cure/elzoo/mcp_client_outcome.cure`;
  `Elzoo.EffectIntent.Binding.compile!/1` checks the failure table and attestation set.
- Test: `test/elzoo/mcp_client_test.exs`, named scenarios against the in-process
  loopback server (ex_mcp's own server behind a recording Plug); finite evidence.
- Monitored behavior: none.
- Upstream contract: ex_mcp 1.8.1 as read at the pin; MCP 2025-11-25 and 2026-07-28
  semantics named, not proved; OTP `crypto`.
- Assumptions: an HTTP 401/403 means nothing ran; ex_mcp's `:not_sent` attestation
  holds for the reasons it lists; the host keeps its Needs truthful.

## Operations

Telemetry `planned` (no Elzoo events; ex_mcp's upstream `[:ex_mcp, ...]` events and
debug logs reach consumer handlers, the consumer's responsibility). Config `supported`
(build-time binding and construction options; no hot update). Control `not_applicable`
beyond `close/1` (in-flight calls end `unknown`; no pause or drain).

## Limits

One transport; no stdio (that slice belongs with `runtime/os-isolation`), OAuth,
resources, prompts, subscriptions, tasks or sampling; no claim about what a tool does;
no TLS or public endpoint in the evidence; content is not durably retained.
