# integration/mcp-runtime

One MCP server that a tenant added at run time, admitted only through the egress
policy, with a bearer token released per call. One bounded Adapter in plain Elixir
over three ready Pieces, used unchanged:
[`integration/egress-policy`](../egress-policy/README.md),
[`integration/secrets`](../secrets/README.md) and the runtime endpoint mode of
[`integration/mcp-client`](../mcp-client/README.md). Streamable HTTP and a bearer
token only; no OAuth (Wave 9 `integration/oauth-client`), no stdio, no new provider.
[`integration/mcp-multi`](../mcp-multi/README.md) keeps its build-time set.

## Interface: `Elzoo.McpRuntime`

Three functions over one plain value, `%Elzoo.McpRuntime.Config{}`. Its `inspect/1`
shows the tenant and the server text only.

- `configure(opts)` returns `{:ok, config}` or `{:error, :configuration}` and calls no
  Need. Exact keys, each once:
  - `tenant`: the tenant text that `Elzoo.McpClient.configure/1` takes;
  - `server`: the 1..128-byte server text;
  - `url`: the tenant's URL. A query is `:configuration` here, because the ready
    client refuses one; every other URL rule is the egress policy's, at `admit/1`;
  - `policy`: an `Elzoo.EgressPolicy.policy/1` value;
  - `resolver`: the egress resolver Need (one argument);
  - `credential`: `%{ref: binary, scope: binary}`;
  - `secrets`: a one-argument function that returns the trusted `Elzoo.Secrets`
    context (`grant`, `resolver`, optional `clock`) for that request, with fresh
    authority, as in `integration/mcp-multi`;
  - optionally the ready client bounds `protocol_mode`, `call_timeout_ms`,
    `handshake_timeout_ms`, `max_request_bytes`, `max_response_bytes`, `max_pages`,
    `max_tools`, `max_descriptor_bytes`, passed on unchanged with the ready ranges and
    defaults.

  The tenant, the server text and the bounds are checked by the ready
  `configure/1` itself, on a fixed stand-in endpoint that is never used.
- `admit(config)` returns `{:ok, client_config}` or `{:error, reason}`, in this order;
  nothing later runs after a refusal, and no client or socket is started:
  1. `Elzoo.EgressPolicy.resolve(url, policy, resolver)`. An error is
     `{:error, {:egress, reason}}` with egress-policy's own reason.
  2. The check before connecting: `secrets.(credential)`, then
     `Elzoo.Secrets.resolve/2` once; the value is dropped. `{:error, :expired}` is
     `{:error, :credentials_expired}`; any other failure, or a raise, throw or exit
     of `secrets`, is `{:error, :credentials_unavailable}`.
  3. `Elzoo.McpClient.configure/1` with `binding: Elzoo.McpClient.RuntimeBinding` and
     `runtime: %{server: server, endpoint: url, network: :public, addresses:
     addresses}`, where `addresses` is the whole checked set. A refusal is
     `{:error, :configuration}`.

  `client_config` is the ready `%Elzoo.McpClient.Config{}`. Its endpoint host and port
  are the egress host and port (both parse the same URL), and the ready client
  reaches only the checked addresses.
- `list_tools(config, session)` returns
  `%{{tenant, server} => {:ok, listing} | {:unavailable, reason}}`. `session` is a
  ready session of a client config that `admit/1` gave for this config (same tenant,
  server text and URL); any other session is a `FunctionClauseError`. The check
  before the call runs first; `reason` is `:credentials_expired`,
  `:credentials_unavailable` or the ready client's finite reason. `listing` is the
  unchanged result of the ready `list_tools/1`.

**Credential Need.** `admit/1` builds the zero-arity Need of the ready client:
`secrets.(credential)`, then `Elzoo.Secrets.resolve/2`, giving
`{:ok, Elzoo.Secrets.reveal(credential)}` or `{:error, :credentials_unavailable}`. It
resolves the reference again at each request; nothing is stored.

**Tool calls** keep the ready path and outcome set; this Piece adds no call function
and wraps nothing. The host calls `Elzoo.McpClient.connect/2`, `admission/3` (which
returns the `ref` with the admission), `context(session, admission, recipient)` and
`call_tool/3`. A runtime session needs the context bound to its admission
(`context/3`); `context/2` and a context bound to another admission are refused by
the ready Adapter as `unknown{adapter_error}` before any send. So a session of
another runtime config cannot execute an intent admitted under this one. The intent
identity is the ready runtime identity: tenant, `"mcp:runtime"`,
`"mcp-client-runtime"`, `"tools/call"` and the 68-byte `"rt1:"` digest of server,
endpoint and `ref`.

**Errors** are the fixed atoms and tuples above and never echo the URL, host, token
or reference. The Piece emits no telemetry and no log of its own.

## Needs

The consumer starts `ex_mcp`'s application and handles its upstream telemetry; a
`DynamicSupervisor`; a truthful egress resolver that bounds its own time (see the
egress-policy recipe); a truthful `secrets` function and Secrets resolver, with each
scope bound to one tenant and one server; the recipient and the owner of each tool
call, as the ready client needs them.

## Grounding

- Proof: none. No Cure law is selected: the Piece is ordering and composition.
- Test: `test/elzoo/mcp_runtime_test.exs`, the named acceptance groups
  (`egress_first`, `admission`, `credentials`, `keying`, `pairing`, `secrecy`) and the
  checked example `examples/mcp_runtime.exs` (construction and an egress refusal).
  Admitted configs are public by design, so their sessions in the tests carry no
  client process; the live sessions are the ready client's in-process loopback
  server, configured directly with the ready client (the other runtime config of
  `pairing`, and the transport of one `keying` listing). Finite evidence.
- Transport evidence: the ELZ-282 loopback runtime tests of `integration/mcp-client`
  (pinned addresses, target refusal of a non-public answer, the redirect and
  TargetPolicy drift tests). This Piece cannot reach a loopback server through
  egress-policy, by design; a successful public connect is not exercised.
- Upstream: `ex_mcp` 1.8.1 at its exact pin and the ready `integration/mcp-client`,
  `integration/egress-policy` and `integration/secrets` Contracts, used unchanged.
- Assumptions: the host Needs above; the ready client's named assumptions (a 401 or
  403 means that nothing ran).
- Monitored behavior: none.

## Operations

Telemetry `planned`, as the ready client: no Elzoo event and no log of its own.
Config `supported` at construction only (the keys above; no hot update; a changed
URL, policy or credential is a new config). Control `not_applicable`: the host owns
the session (`Elzoo.McpClient.close/1`).

## Limits

Addresses are as fresh as the admission; after a disconnect the host admits again
(a new `admit/1`). Redirect refusal and the response cap are ex_mcp and mcp-client
duties, held by ELZ-282's drift tests. There is no live public endpoint in the
evidence. One tenant credential per server (no per-person lists). The check before
the call and the Need are two samples of the Secrets resolver; a rotation between
them is possible. The ready client's Adapter context is not opaque: host code that
edits a context's session or key bypasses the pairing. No claim about what a tool
does.
