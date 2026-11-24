# integration/mcp-server

Elzoo's bots as MCP tools (ELZ-363, Wave 9 owner answer Q4 A). A verified
caller lists the bots it may run, and each `tools/call` is one Run with a
bounded wait. Plain Elixir over the server side of the pinned `ex_mcp` 1.8.1
(`ExMCP.HttpPlug`, Streamable HTTP) and the direct `plug`. The Piece is a Plug
that the host mounts in its own router. It runs no server of its own, starts no
Run and calls no engine: Run allocation and the pinned start are the host's
composition (`state/recipe-store` `pin/4`, `workflow/version-pin`, the Run
owner's create and begin, the engine's `start` input).

## Mount

```elixir
forward "/mcp", to: Elzoo.McpServer.Plug, init_opts: {MyApp.Mcp, :server, []}
```

`Elzoo.McpServer.Plug.init/1` takes a module-function-arguments triple, which a
compile-time router can hold. `call/2` applies it on each request and takes the
`{:ok, server}` it returns. Anything else, or a raise, throw or exit, is HTTP
503 with the body `{"error":"unavailable"}`.

**HTTP server timeout.** The host's HTTP server must keep a request open longer
than `call_timeout_ms` plus 5,000 ms. Cowboy's default `idle_timeout` is 60 s,
so a `call_timeout_ms` above 55,000 needs a larger one.

## Configuration

`Elzoo.McpServer.new(opts)` returns `{:ok, server}` or `{:error, :invalid}`. It
takes exactly these keys, with no duplicates:

- `verifier`: `{:jwt, %Elzoo.TokenVerify.JwtConfig{}}` or
  `{:api_key, %Elzoo.TokenVerify.ApiKeyConfig{}}`.
- `clock`: a zero-arity trusted Need returning Unix seconds (a non-negative
  integer).
- `policy`: a `domain/authorization` policy. `authority`: a one-arity Need
  given the principal that returns `{:ok, own}`, the principal's current
  authority set.
- `bots`: a one-arity Need given the tenant that returns `{:ok, bots}`, 0..64
  maps of exactly `%{bot_id, name, description, start_schema, schema_version}`:
  `bot_id` 1..128 bytes of UTF-8; `name` matching `[a-z0-9_-]{1,64}` and
  unique; `description` 1..1,024 bytes of UTF-8; `start_schema` a decoded JSON
  Schema object; `schema_version` 1..2^31−1. A list that breaks any rule gives
  no bot at all.
- `start`: a one-arity Need given `%{tenant, principal, bot_id, call_id,
  arguments}` that starts one Run of the bot's pinned version with the
  principal as its acting principal and returns `{:ok, run_id}` (1..128 bytes)
  or `{:error, atom}`.
- `result`: a one-arity Need given `%{tenant, principal, run_id}` that returns
  what the engine's `result/3` returns for that Run: `{:ok, completion}` with a
  `payload`, `{:pending, :not_completed}`, `{:terminal, outcome}` or
  `{:error, reason}`.
- `call_timeout_ms` (1..60,000); optional `poll_interval_ms` (10..5,000,
  default 250) and `body_limit` (1,024..1,048,576, default 131,072).

The server has a redacted `Inspect`.

## Request path

1. **Token, before any MCP handling.** The Plug reads exactly one
   `authorization` header of the form `Bearer <token>` (RFC 6750 section 2.1):
   the scheme ASCII case-insensitive, one or more spaces, and a b64token of
   1..8,192 bytes. It verifies the token with `integration/token-verify` at the
   `clock` Need's time. No header, two headers, another scheme or form, a
   refused token and a clock that fails are each HTTP 401 with
   `www-authenticate: Bearer` and the body `{"error":"unauthorized"}`. The Plug
   halts before the body is read, so no MCP handler is started and no Need
   other than the clock and the verifier's own is called.
2. **No `subscriptions/listen`.** The Piece serves no subscription or
   resource, and no stream outlives its request: ex_mcp answers a modern
   request that carries `_meta.progressToken` and accepts `text/event-stream`
   with a request-scoped SSE stream, which ends with that request. A verified request with an `mcp-method` header equal to
   `subscriptions/listen` is answered by the Plug, whatever its body and its
   size: HTTP 200 with
   `{"jsonrpc":"2.0","id":null,"error":{"code":-32601,"message":"Method not found"}}`
   and no stream. The Plug reads no body (hence `"id": null`), so a host that
   parses the body upstream (a default Phoenix endpoint) keeps working. The
   header alone decides whether a listen stream can open: ex_mcp opens one only
   for a modern-era request, which must carry one `Mcp-Method` header equal to
   the body's `method`. The shapes left to ex_mcp are refused by it with no
   stream: a modern body naming the method under a header naming another is
   HTTP 400 `-32020`, and a legacy-era body naming it is `-32602`
   ("Subscription request rejected").
3. **ex_mcp.** A verified principal is assigned to the conn, and the request
   goes to `ExMCP.HttpPlug` with these options:

   | Option | Value |
   | --- | --- |
   | `handler` | `Elzoo.McpServer.Handler` |
   | `handler_opts` | a one-arity function that reads the server and the principal from the conn |
   | `tenant_id` | a one-arity function of the conn: the principal's `tenant` |
   | `principal_id` | a one-arity function of the conn: `"<kind>:<id>"` of the principal, such as `"human:alice"` |
   | `handler_call_timeout` | `call_timeout_ms + 5_000` |
   | `body_limit` | `body_limit` (over it HTTP 413) |
   | `server_info` | `%{name: "elzoo-mcp-server", version: "1"}` |
   | `server_capabilities` | `%{tools: %{}}` (what modern `server/discover` advertises) |
   | `legacy_http_sse` | `false` |
   | `oauth_enabled` | `false` |
   | `validate_origin` | `false` |

   `validate_origin` is off because ex_mcp's own client sends its endpoint's
   `Origin`, and the default (no allowed origins) refuses every such request
   with 403. Each request carries its own bearer token, which a browser does
   not attach by itself. A host that wants origin or host checks can put its
   own Plug in front.

   ex_mcp starts one handler process per request and stops it afterwards. The
   handler's `init/1` gets the current request's principal, so every callback
   decides on that principal only.

   **Sessions.** Sessions and their store are ex_mcp's (`ExMCP.SessionManager`,
   process-local, with its upstream defaults of 10,000 sessions and a one-hour
   TTL). A legacy-era `initialize` binds the new session to `tenant_id` and
   `principal_id`; a kind holds no `:`, so a `service` and a `human` with one
   `id` are two principals. A later request or `DELETE` that names the session
   with a token of another tenant, kind or id is refused by ex_mcp's session
   check with HTTP 404 and JSON-RPC `-32600` "Session not found", before any
   handler starts and with no Need beyond the token check. The same principal's
   requests work, also with a re-issued token, and its `DELETE` is 204. A
   modern-era request ignores session headers; with the identity set, ex_mcp
   1.8.1 scopes its cancellation to the same principal and tenant (as read in
   its code, not tested here). A session ID still grants no tool: every
   request is verified and decided on its own token.

## tools/list

The tenant is the principal's. A bot of the `bots` Need is listed when
`Elzoo.Authorization.decide(policy, proposal, context)` returns
`verdict: :allow` for:

```elixir
proposal = %{tenant: principal.tenant, resource: "mcp-server",
             action_id: "mcp.run/" <> bot_id, payload: nil,
             writes: [%{target: "bot/" <> bot_id, field: "run", value: true}]}
context = %{proposer: principal.id, effect_class: "mcp.run", own: own, parent: :none}
```

`:ask` and `:deny` are not listed. A decision that errors or raises, a start
schema whose root `"type"` is not `"object"` (MCP requires an object-rooted
`inputSchema`), or one that `core/payload-schema` does not build, leaves out
that bot only. A
failed `authority` or `bots` Need, or an invalid bot list, gives an empty list.
Tools come in `name` byte order, all on one page (no `nextCursor`). Each tool
has `name`, `description` and `inputSchema` (the start schema).

## tools/call

1. The bot is found by name and decided again, as for the list, so a list read
   earlier grants nothing. A name that is unknown, of another tenant, or not
   `:allow` for this principal is the error `unknown tool`, which ex_mcp sends
   as JSON-RPC `-32602`.
2. ex_mcp's handler mode merges the request's `_meta` into the arguments map,
   so that reserved MCP member is removed. An argument that the caller itself
   names `_meta` is removed with it, so a start schema must not rely on one. Then `Elzoo.PayloadSchema.check/3`
   checks the arguments against the start schema, built with the port
   `%{"id" => bot_id, "direction" => "input", "schema_id" => bot_id,
   "schema_version" => schema_version}`. Any refusal, including more than
   65,536 bytes of compact JSON or a depth over 32, is the tool error
   `invalid_arguments`. No Run starts and no violation is echoed.
3. One `start` call with a fresh `call_id` (16 random bytes, lowercase hex).
   An error, a malformed answer, a Run ID outside 1..128 bytes, or a raise,
   throw or exit is the tool error `start_failed`.
4. The `result` Need is called at once, then every `poll_interval_ms` until
   `call_timeout_ms` after the start. Each text below is canonical JSON (keys
   in byte order, no whitespace) in one text content:

   | Result read | MCP result |
   | --- | --- |
   | `{:ok, completion}` | `{"payload": …, "run_id": …}`, not an error |
   | `{:terminal, outcome}` (`:failed`, `:cancelled`, `:out_of_budget`, `:out_of_time`) | tool error `{"outcome": …, "run_id": …}` |
   | `{:pending, :not_completed}` at the bound | tool error `{"run_id": …, "state": "running"}`; the Run goes on |
   | `{:error, _}`, any other shape, or a raise, throw or exit | tool error `{"run_id": …, "state": "unknown"}` |
   | a completion over 65,536 bytes | tool error `{"run_id": …, "state": "result_too_large"}` |

   Every result and error is at most 65,536 bytes and holds no token.

**Each call is a new Run.** MCP gives no idempotency key, so a retried call
starts a second Run with another `call_id`. A Run still open at the bound goes
on; the host reads its result, not MCP.

**Pinned Runs.** Every call pins a recipe version. `state/recipe-store` bounds
the live state at 5,000 records of a carry, and a Run that never unpins holds a
place in every carry. So the host must unpin finished Runs, or new pins are
refused.

## Example

`examples/mcp_server.exs` configures a server with a JWT verifier, one allowed
bot and stand-in Run Needs. It mounts the Plug under `forward` and shows that a
request without a token is HTTP 401.

## Grounding

- Test: `mix test pieces/integration/mcp-server/test`. The Plug runs in a host
  router on `Plug.Cowboy` at `127.0.0.1` with an ephemeral port. The ready
  `integration/mcp-client` in `:loopback` evidence mode, configured directly,
  lists and calls tools, as do raw JSON-RPC POSTs through Req where that client
  refuses locally before sending. Tokens are JWTs signed with a test key,
  `start` and `result` are scripted Needs, and the listed scenarios pass (see
  `piece.json`). Negative controls: skipping the authorization decision,
  skipping the schema check and starting the handler before the token check
  each make the tests fail; so do dropping `tenant_id` and `principal_id`
  (each alone, or the kind from `principal_id`, fails its own case) and
  dropping the listen refusal (ex_mcp then answers `-32602`
  `subscription_filter_authorizer_required` instead of the Plug's `-32601`).
- Upstream: `ex_mcp` 1.8.1 `ExMCP.HttpPlug` and handler-mode behaviour, and
  Plug 1.20.3 `forward`, as read at the pinned versions.

## Limits

- The verifier configuration, the clock, the policy, the authority Need, the
  bot list and the `start` and `result` Needs are the host's. The Piece decides
  only on what they give.
- The bounded wait polls. A `start`, `result`, `authority` or `bots` Need that
  blocks is bounded only by ex_mcp's handler timeout (`call_timeout_ms +
  5_000`, JSON-RPC `-32603` `handler_timeout`). The `clock` Need and the
  verifier's own Needs (`subject`, `lookup`, `digest_key`) run in the Plug
  before ex_mcp, so only the host's HTTP server bounds them.
- Upstream observation at ex_mcp 1.8.1 on OTP 29.1.2: after a handler timeout,
  ex_mcp stops the handler with a 1,000 ms timeout and catches only exits. If
  the handler ends within about a millisecond of that timeout,
  `proc_lib:stop/3` raises `timeout_value`, and the request ends as HTTP 500
  with an empty body instead of `-32603`.
- The evidence is the ready client and raw HTTP against the Plug on a loopback
  socket with scripted Run Needs. No live MCP host, TLS, public endpoint or
  engine is exercised; the Wave 9 root acceptance composes them.
- ex_mcp's own debug logs and telemetry are upstream.
- Before a modern-era `tools/call`, ex_mcp calls `tools/list` itself to check
  header annotations, so the `authority` and `bots` Needs run twice for that
  call, each under its own handler timeout.
- The session binding is ex_mcp's session check on the identity that the
  Piece gives, and with it (as read upstream, not tested) the principal scope
  of modern-era cancellation. It binds tenant, kind and id, not `auth_epoch`:
  a re-issued token keeps the principal's sessions (kept open).
- The listen refusal is by header; a body naming the method is left to ex_mcp's
  own rejections. Bounding a stream by the token's expiry is kept open:
  `integration/token-verify` does not return the expiry, and no stream of the
  Piece outlives its request.
- Not supplied: resources, prompts, progress notifications, an idempotency key
  in `_meta`, the MCP authorization flow (protected-resource metadata and an
  authorization server) and stdio.

Copied source is Apache-2.0. External packages keep their own licenses. See
[consuming](../../../docs/consuming.md).
