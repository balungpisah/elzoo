# ELZ-083 — Specify the MCP client Adapter over Streamable HTTP with inert tool discovery

- Phase: demand-led integration Adapter
- Catalogue IDs: integration/mcp-client (new row split from the `integration/sdk` family; see "RC-30 scope" and open question 1)
- Dependencies: ELZ-011, ELZ-023

## Outcome

Own an Adapter that connects to one MCP server over the Streamable HTTP transport, lists
its tools as inert data and calls one named tool only when the caller hands over an
explicit execution request, translating every result into `completed`, `refused` or
`unknown`. Adopt `ex_mcp` 1.8.1 (MIT) for the protocol, era negotiation and the HTTP
transport; Elzoo owns the transport and retry settings that keep a tool call from being
sent twice, the refusal of server-initiated requests, the bounds on discovery, the
outcome table and the binding to the ELZ-011 Effect and ELZ-023 intent boundaries.
Discovery never authorizes execution. This is the owner's first tool boundary (decision
record: `docs/plans/catalogue-dispositions.md#integration-sdk`; owner answer 3: "first
tool boundary is an MCP client (ExMCP)").

## RC-30 scope (decided by the main coordinator)

The canonical RC-30 ("One foreign consumer protocol") scopes `integration/sdk` as one
actual foreign language consuming versioned messages and results, with RC-17 (agent
runner) among its prerequisites; the owner named an MCP client first. Main's decision:
the owner's MCP client goes first as this task; the foreign-consumer-protocol scope of
RC-30 stays for a later slice and is not satisfied, narrowed or edited here. This task
therefore does not depend on RC-17 and does not claim RC-30's acceptance (cross-language
conformance fixture).

## Admission record

1. **Responsibility and caller.** Translate MCP tool discovery and one tool call per
   request to typed outcomes. Callers: C6 tool use by agents (an Assembly decides which
   proposed call runs, after `domain/authorization` and `workflow/approval`); model tool
   proposals from `integration/ai-model` remain data until that Assembly decides.
2. **Interface and invariant.** Inputs: a server binding (Need): server identity, an
   allowlisted endpoint URL, a credential reference resolved per connection (bearer
   token), network policy (loopback, private or public), protocol mode, and bounds;
   `connect/2` and `close/1` under the caller's supervision; `list_tools/2` with a page
   and total bound; `call_tool/3` with a caller-built execution request carrying the
   tool name, JSON arguments (bounded bytes), a dispatch identity (tenant, logical
   request reference, attempt), a deadline and an exact-action release reference from
   the caller's approval step (shape-checked only; see open question 2), plus the ELZ-011
   Effect declaration and the ELZ-023 intent record. Outputs: discovery returns
   `{:ok, %{server, protocol_version, tools: [descriptor], truncated}}` where each
   descriptor is data (name, description, input schema, annotations) marked untrusted,
   or a finite error; a call returns `completed{content, is_error, structured}` (the
   server's tool result, including tool-level errors, which the MCP specification
   reports inside the result), `refused{unknown_tool | invalid_arguments | too_large |
   authentication_failed | credentials_unavailable | target_refused | not_connected |
   invalid_request}` for outcomes decided locally before the request was sent, or for
   an HTTP 401 or 403 authentication rejection (a named upstream assumption that the
   server did not execute the call; dispatched, never an attested no-send), or
   `unknown{reason}` when the request may have reached the server and no completed
   result was observed (timeout, broken stream, connection loss, an input-required
   result, or any JSON-RPC error after sending, reported as `unknown{server_error}`
   with a bounded subtype), mapped to the ELZ-011 delivery result. Invariants: listing
   tools never calls a tool; a descriptor's annotations (`readOnlyHint` and others) and
   its description never change what the Adapter does; the caller-supplied bounded
   discovery snapshot may only narrow admission: absence of the named tool
   (`unknown_tool`) or failure against its snapshot input schema (`invalid_arguments`)
   is a local, pre-send refusal and claims nothing about the server's current tool set
   or schema; a tool call is sent at most once per dispatch identity, and a second
   dispatch of the same identity without a reconciliation decision is refused by the
   intent boundary; any timeout, broken stream or JSON-RPC error after sending is
   `unknown`, never `refused`; `connect/2` sends only the protocol handshake
   (`server/discover` where the mode probes the modern era, `initialize` and
   `notifications/initialized` where it settles on a legacy revision); server-initiated
   requests embedded in the response to one of the Adapter's own requests are dropped
   unanswered and disclose no host data (the Adapter opens no standalone stream);
   where a server request reaches a receiving stream, sampling, elicitation, roots and
   custom methods are refused and disclose no path, model or credential, and a
   protocol `ping` is acknowledged with an empty result only; the credential
   never appears in a result, error, inspect value, Adapter
   log or event, and the injected credential is accepted only if it is at least 24
   bytes and is not a substring of any Adapter-emitted fixed string (error texts,
   module and struct names that can appear in inspect output, protocol version
   strings; a finite list enumerated by a test from the Piece's compiled source) nor of
   the binding's configured strings (server identity, endpoint), otherwise it is
   refused before any send as `refused{credentials_unavailable}`; responses and
   discovery are bounded. Non-goals: an MCP server, stdio
   transport, OAuth flows, resources, prompts, subscriptions, tasks, ACP, deciding
   authority or approval, sandboxing what a tool does.
3. **Reuse check.** `ex_mcp` 1.8.1 (MIT) supports MCP 2026-07-28 and the legacy
   revisions with a negotiated era (package README), a Streamable HTTP client transport
   with bearer authentication, a response-size bound (`max_response_bytes`, default 8
   MiB, `lib/ex_mcp/transport/http.ex:203`) and a DNS-pinning target policy
   (`lib/ex_mcp/transport/http/target_policy.ex`), and `ExMCP.Client.list_tools/2` and
   `call_tool/4` (`lib/ex_mcp/client.ex:410-443`). Settings the Adapter must pin, each
   with a test: `http_stream_retry: :safe_only` (the default `:at_least_once` reissues a
   broken request with a new JSON-RPC id; `:safe_only` returns `:outcome_unknown`
   instead, `lib/ex_mcp/client.ex:312-324`); `retry_policy: false` (generic operation
   retries, `lib/ex_mcp/client.ex:300-344`); no client handler, or a handler that refuses
   every server request (the shipped `ExMCP.Client.DefaultHandler` exposes the current
   directory as a root by default, `lib/ex_mcp/client/default_handler.ex:13`; the
   omitted-handler path and a rejecting handler are both tested); an Elzoo-owned
   fail-closed authorization provider passed as `auth_provider`, whose `get_token/1`
   resolves the injected credential Need and whose `handle_unauthorized/3` and
   `handle_forbidden/3` return an error, never a new token (the shape of
   `ExMCP.Authorization.Provider.Static`, `lib/ex_mcp/authorization/provider/static.ex`;
   with a provider, a 401 or 403 goes to `provider_authenticate/5`, which resends only
   when the callback returns a token, `lib/ex_mcp/transport/http.ex:480,610-637`).
   Omitting OAuth configuration is not enough: without a provider, a 401 carrying a
   `WWW-Authenticate: Bearer` challenge starts the inline OAuth flow and then resends the
   original request (`lib/ex_mcp/transport/http.ex:489-510,804-863,906-918`), which
   could contact an attacker-chosen authorization server and send a second
   `tools/call`; `reconnect: false` and `health_check_interval: nil` (the client
   defaults to automatic reconnect and idle health pings, `lib/ex_mcp/client.ex:205-246,
   1135-1141`; neither re-runs a pending call, but both send protocol requests the
   Adapter does not declare; the builder confirms that `nil` disables the ping);
   `conformance_mode: false` (default; `:safe_only` is rejected under conformance mode,
   `lib/ex_mcp/client.ex:321-324`); no `retry_safe` option on any tool call. Dependency closure resolved in a scratch
   project with the repository's current pins: 11 new packages (`ex_mcp`,
   `mint_web_socket`, `castore`, `plug`, `plug_crypto`, `plug_cowboy`, `cowboy`,
   `cowboy_telemetry`, `cowlib`, `ex_json_schema`, `jose`), all MIT, Apache-2.0 or ISC;
   the server-side `plug_cowboy`/`cowboy` are required even for client use; the locked
   `ranch` 2.3.0 satisfies `cowboy`'s `>= 1.8.0 and < 3.0.0`. `phantom_mcp` (server
   only) and Anubis (copyleft) are not adopted.
4. **Split test.** Protocol translation and outcome classification stay together;
   authority and approval stay in `domain/authorization` and `workflow/approval`; intent
   and dedup in `delivery/effect-intent`; process boundaries for a stdio server belong to
   `runtime/os-isolation` in a later slice.
5. **Failure and evidence.** Dangerous paths: a broken stream silently reissuing a tool
   call; a discovered tool executed because a model proposed it or a descriptor said it
   was read-only; a server-initiated sampling or roots request answered with host data;
   an OAuth redirect flow started against a configured static credential; an unbounded
   tool list or response; the bearer token in a log line or error; a 401 reported as an
   unknown outcome. Proofs: none required. Tests against an in-process MCP server on
   loopback started by the test suite (an `ex_mcp` server with its HTTP plug, or a
   minimal Plug stub that speaks the documented JSON-RPC messages), so CI needs no new
   service: discovery with pagination and the page and total bounds; a descriptor with a
   prompt-injection description and `readOnlyHint` changes nothing; a successful call; a
   tool-level error result; unknown tool; invalid arguments refused before sending;
   too-large arguments refused before sending; a 401 with `WWW-Authenticate: Bearer`
   (and a 403 with `insufficient_scope`) refused with exactly one `tools/call` observed
   by the server and no request to any authorization server; no reconnect or health
   ping observed after a connection drop or idle period;
   server timeout and a stream broken mid-response reported `unknown` with exactly one
   request observed by the server; a second dispatch of the same identity refused by the
   intent boundary; server-initiated sampling, elicitation and roots requests refused;
   credential absence from results, errors, inspect values, logs and events; a non-
   allowlisted or non-loopback target refused under the loopback network policy.
   Upstream: MCP semantics, era negotiation and `ex_mcp`'s transport behavior are named,
   not proved.
6. **Composition record.** Depends on `core/effect` and `delivery/effect-intent`
   (ready). Needs: the server endpoint and its credential as an explicit injected Need
   (configuration reference resolved at connect, never read from global config by the
   Piece, never logged), following batch 1's decision while `integration/secrets` is
   deferred; the `ex_mcp` application must be started by the consumer (it starts its own
   supervisors), so the dependency is not `runtime: false`. Telemetry `planned` (no
   Elzoo event; `ex_mcp` emits upstream `[:ex_mcp, :client, ...]` events that
   consumer-installed handlers may see, which is the consumer's responsibility; not
   `inherited`, because extending the ready `runtime/telemetry` allowlist is a change to
   that Piece and is not in this scope); Config `supported` for endpoint, network policy,
   protocol mode, bounds and deadline (construction time; no hot reconfiguration);
   Control `not_applicable` beyond `close/1`, which ends the connection and reports
   in-flight calls `unknown` (no pause or drain). No delivery guarantee.

## Transport choice (recommendation)

Streamable HTTP first. Reasons: (a) `ex_mcp`'s stdio transport spawns the server itself
through `Port.open` and its own reaper (`lib/ex_mcp/transport/stdio.ex:230`,
`lib/ex_mcp/transport/stdio/reaper.ex:548`), so using it would bypass the ready
`runtime/os-isolation` boundary (erlexec) and create a second process manager; routing
stdio through `runtime/os-isolation` instead needs an Elzoo-owned `ex_mcp` transport over
erlexec's stdio and a Contract review of a long-lived server session against
os-isolation's deadline-bounded child, which is a slice of its own; (b) HTTP needs no OS
process and is testable against an in-process loopback server, so CI needs no new
service; (c) the HTTP transport already has a response bound, a target policy and bearer
authentication. Cost: the duplicate-call risks of stream reissue and of the inline
OAuth challenge, and the server-request
handler default must be pinned (item 3). The stdio slice through `runtime/os-isolation`
is listed as a later slice.

## Scope

- add `pieces/integration/mcp-client/` with the Adapter, outcome schema, README,
  `piece.json`, tests and the in-process loopback test server under the Piece's own
  `test/support`; source audits read only the Piece's own listed files;
- add `ex_mcp` 1.8.1 and its closure at pinned versions, recorded in
  `registry/providers.json` with licenses; `mix.exs`/`mix.lock` change, so one local
  full `mix setup && mix check` runs at the head (class X rule);
- add the catalogue row and a distinct release-plan job and entry owning the ID main
  selects (RC-30 keeps `integration/sdk` and its scope unchanged), regenerate
  `LEDGER.md` and the roadmap views.

## Acceptance

- [ ] Discovery, call, tool-error, unknown-tool, invalid-arguments, too-large, 401,
      timeout, broken-stream, duplicate-dispatch and server-request scenarios pass
      against the in-process loopback MCP server.
- [ ] A broken stream after sending is `unknown` with exactly one request observed by
      the server; listing tools never sends `tools/call`.
- [ ] A 401 with a `Bearer` challenge is refused with exactly one `tools/call` observed and
      no authorization-server request; the pinned `auth_provider`, `reconnect: false`,
      `health_check_interval: nil`, `http_stream_retry: :safe_only` and
      `retry_policy: false` settings are each covered by a test.
- [ ] No credential appears in results, errors, inspect values, logs or Adapter events,
      with a test; upstream `ex_mcp` telemetry seen by consumer handlers is a stated
      limit.
- [ ] The Piece's tests pass in the exported consumer layout.
- [ ] Operational applicability is declared per docs/operational-contracts.md.
- [ ] Full `mix setup` and `mix check` pass at the PR head on the pinned toolchain.

## Evidence and limits

Finite tests against an in-process loopback server; upstream contracts for MCP and
`ex_mcp` 1.8.1; no proof is claimed. One transport; no stdio, OAuth, resources, prompts,
subscriptions or tasks; no claim about what a tool does on its server; no TLS or public
endpoint in the evidence.

## Out of scope

MCP server, stdio transport, OAuth, resources, prompts, sampling, elicitation, roots,
ACP, the RC-30 foreign consumer protocol, authority and approval decisions, agent loops.

## Reference

Decision record `integration/sdk` (ADOPT; owner answer 3; conditions "One transport
first; stdio transport needs the OS boundary; copyleft Anubis excluded"); disagreement
note on the RC-30 scope (decided by main as above); `runtime/os-isolation` (later stdio
slice); disagreement note on the `integration/secrets` prerequisite.

## Open questions (none blocks a builder)

1. Catalogue ID: a new row `integration/mcp-client` split from the `integration/sdk`
   family (recommended, so RC-30 keeps `integration/sdk` for the foreign consumer
   protocol) versus `integration/sdk` itself. Main decides at publication.
2. Release reference: the Adapter requires a caller-supplied exact-action release
   reference (shape-checked, recorded in the Effect declaration, never verified by the
   Adapter) so that no code path turns discovery or a model proposal into a call without
   the caller's approval step (recommended), versus leaving the gate entirely to the
   Assembly.
3. Which MCP server the owner connects first (affects only the example and the README,
   not the Contract).
