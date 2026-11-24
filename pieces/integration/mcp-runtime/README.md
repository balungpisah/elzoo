# integration/mcp-runtime

One MCP server that a tenant added at run time, admitted only through the egress
policy, with a bearer token asked per call: from an `integration/secrets` reference,
or from a tenant OAuth connection through the host's OAuth Need. One bounded Adapter
in plain Elixir over three ready Pieces, used unchanged:
[`integration/egress-policy`](../egress-policy/README.md),
[`integration/secrets`](../secrets/README.md) and the runtime endpoint mode of
[`integration/mcp-client`](../mcp-client/README.md). Streamable HTTP and a bearer
token only; no per-person lists, no OAuth flow in the Piece (the host wraps
[`integration/oauth-client`](../oauth-client/README.md) in the OAuth Need, so this
Piece does not depend on it), no stdio, no new provider.
[`integration/mcp-multi`](../mcp-multi/README.md) keeps its build-time set.

## Interface: `Elzoo.McpRuntime`

Three functions over one plain value, `%Elzoo.McpRuntime.Config{}`. Its `inspect/1`
shows the tenant and the server text only.

- `configure(opts)` returns `{:ok, config}` or `{:error, :configuration}` and calls no
  Need. Exact keys, each once (`secrets` or `oauth` by the credential form):
  - `tenant`: the tenant text that `Elzoo.McpClient.configure/1` takes;
  - `server`: the 1..128-byte server text;
  - `url`: the tenant's URL. A query is `:configuration` here, because the ready
    client refuses one; every other URL rule is the egress policy's, at `admit/1`;
  - `policy`: an `Elzoo.EgressPolicy.policy/1` value (a struct with other fields is
    `:configuration`);
  - `resolver`: the egress resolver Need (one argument);
  - `credential`: either the reference form `%{ref: binary, scope: binary}` or the
    OAuth form `%{oauth: connection_id}` (exactly that key; `connection_id` is 1..128
    bytes of printable UTF-8, as oauth-client's);
  - with the reference form, `secrets`: a one-argument function that returns the
    trusted `Elzoo.Secrets` context (`grant`, `resolver`, optional `clock`) for that
    request, with fresh authority, as in `integration/mcp-multi`;
  - with the OAuth form, `oauth`: the OAuth Need, a one-argument function given
    `%{tenant: tenant, connection_id: connection_id}` that returns `{:ok, token}` or
    `{:error, atom}`. The host wraps `Elzoo.OauthClient.access_token/3` with its own
    binding: `fn %{tenant: t, connection_id: id} -> Elzoo.OauthClient.access_token(binding, t, %{connection_id: id}) end`;
  - optionally the ready client bounds `protocol_mode`, `call_timeout_ms`,
    `handshake_timeout_ms`, `max_request_bytes`, `max_response_bytes`, `max_pages`,
    `max_tools`, `max_descriptor_bytes`, passed on unchanged with the ready ranges and
    defaults.

  A config has exactly one of `secrets` and `oauth`, the one of its credential form;
  any other combination is `:configuration`. The tenant, the server text and the
  bounds are checked by the ready `configure/1` itself, on a fixed stand-in endpoint
  that is never used.
- `admit(config)` returns `{:ok, client_config}` or `{:error, reason}`, in this order;
  nothing later runs after a refusal, and no client or socket is started:
  1. `Elzoo.EgressPolicy.resolve(url, policy, resolver)`. An error is
     `{:error, {:egress, reason}}` with egress-policy's own reason.
  2. The check before connecting, in the calling process; the value is dropped.
     Reference form: `secrets.(credential)`, then `Elzoo.Secrets.resolve/2` once.
     `{:error, :expired}` is `{:error, :credentials_expired}`; any other failure, or
     a raise, throw or exit of `secrets`, is `{:error, :credentials_unavailable}`.
     OAuth form: one call of the OAuth Need. `{:ok, token}` with a binary `token`
     passes; every other answer (`{:error, :reauthorization_required}`,
     `{:error, :revoked}`, any other error, a malformed answer, a raise, throw or
     exit) is `{:error, :credentials_unavailable}`. The check does not apply the
     ready client's 24-byte and fixed-string rule (see Limits).
  3. `Elzoo.McpClient.configure/1` with `binding: Elzoo.McpClient.RuntimeBinding` and
     `runtime: %{server: server, endpoint: url, network: :public, addresses:
     addresses}`, where `addresses` is the whole checked set. A refusal is
     `{:error, :configuration}`, for example a URL over the ready client's
     512-byte endpoint bound (egress-policy admits up to 2048 bytes).

  `client_config` is the ready `%Elzoo.McpClient.Config{}`. Its endpoint host and port
  are the egress host and port (both parse the same URL), and the ready client
  reaches only the checked addresses.
- `list_tools(config, session)` returns
  `%{{tenant, server} => {:ok, listing} | {:unavailable, reason}}`. `session` is a
  ready runtime session whose client config has this config's tenant, server text
  and URL, as the one `admit/1` gives; any other session (another tenant, server
  text or URL, or a build-time session) is a `FunctionClauseError`. The check
  before the call runs first; `reason` is `:credentials_expired`,
  `:credentials_unavailable` or the ready client's finite reason. `listing` is the
  unchanged result of the ready `list_tools/1`.

**Credential Need.** `admit/1` builds the zero-arity Need of the ready client.
Reference form: `secrets.(credential)`, then `Elzoo.Secrets.resolve/2`, giving
`{:ok, Elzoo.Secrets.reveal(credential)}` or `{:error, :credentials_unavailable}`.
OAuth form: one call of the OAuth Need, giving `{:ok, token}` or
`{:error, :credentials_unavailable}`; the token is never stored and never in an
error. Either form asks again at each call, so a token refreshed between two
requests of one session is used from the next request on, up to mcp-client's 64
distinct tokens per session, after which the host must reconnect (see Limits).

The ready client calls this Need once per HTTP request and twice more around each
listing and each tool call, to redact the token from results (measured on the
loopback server in `oauth_loopback`): `connect/2` 1 call, a three-page
`list_tools` 5 (3 + 2), one `call_tool/3` 3 (1 + 2); `admit/1` and `list_tools/2`
add the one call of the check.

**Tool calls** keep the ready path and outcome set; this Piece adds no call function
and wraps nothing. The host calls `Elzoo.McpClient.connect/2`, `admission/3` (which
returns the `ref` with the admission), `context(session, admission, recipient)` and
`call_tool/3`. A runtime session needs the context bound to its admission
(`context/3`); `context/2` and a context bound to another admission are refused by
the ready Adapter as `unknown{adapter_error}` before any send. So a session of
another runtime config, one with another tenant, server text or URL, cannot execute
an intent admitted under this one. The intent identity is the ready runtime
identity: tenant, `"mcp:runtime"`, `"mcp-client-runtime"`, `"tools/call"` and the
68-byte `"rt1:"` digest of server, endpoint and `ref`. The credential (its form,
reference or connection id), the addresses and the bounds are not in it: two configs that differ only there are the
same server under one key, so a session of a config admitted again (new addresses)
can recover an intent of the earlier one, and keeping one credential per
`{tenant, server}` is the host's duty.

**Errors** are the fixed atoms and tuples above and never echo the URL, host, token
or reference. The Piece emits no telemetry and no log of its own.

## Needs

The consumer starts `ex_mcp`'s application and handles its upstream telemetry; a
`DynamicSupervisor`; a truthful egress resolver that bounds its own time (see the
egress-policy recipe); a truthful `secrets` function and Secrets resolver, with each
scope bound to one tenant and one server, or a truthful OAuth Need bound to the
tenant's own connection; the recipient and the owner of each tool call, as the ready
client needs them.

When the OAuth Need is oauth-client's, its Consumer Needs carry over: each call holds
one database transaction (a refresh also the connection row lock) for the pool queue
wait, the row-lock wait, `exchange_timeout_ms` and the time of its Secrets, resolver,
sealing key and transport Needs, so one request of the ready client can wait that
long, and the host Repo's `:timeout` must exceed that time (oauth-client's Consumer
Needs, issue #886). Each call of that Need is one database transaction.
The ready client calls the Need before, during and after each request: during, inside
the request's bound (`call_timeout_ms` for a listing page or a tool call,
`handshake_timeout_ms` for connect); before and after, for redaction, inside
`call_tool/3`'s wait of `call_timeout_ms` plus 5,000 ms and around each listing. The
host keeps the Need's waits within those bounds. A longer wait makes a listing a
timeout and a tool call `{:unknown, :timeout}`, which after a successful response is
an unknown outcome after the tool ran (the owner's settlement stays authoritative; by
the code path, not measured).

## Grounding

- Proof: none. No Cure law is selected: the Piece is ordering and composition.
- Test: `test/elzoo/mcp_runtime_test.exs`, the named acceptance groups
  (`egress_first`, `admission`, `golden_bearer`, `credentials`, `keying`, `pairing`,
  `secrecy`, `oauth_admission`, `oauth_loopback`, `oauth_refresh`, `oauth_refusal`,
  `oauth_configure`) and the checked example `examples/mcp_runtime.exs`
  (construction of both forms and an egress refusal). `golden_bearer` was recorded
  on the base before the OAuth form. The OAuth groups use a Need double, never
  oauth-client; `oauth_loopback` and `oauth_refresh` give the OAuth credential Need to
  the ready client's loopback mode, in front of `ExMCP.HttpPlug` with a recording
  Plug that sees each request's authorization header.
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
evidence. One tenant credential per server (no per-person lists, no OAuth flow, no
token cache). The check before the call and the Need are two samples of the Secrets
resolver or of the OAuth Need; a rotation, refresh or revocation between them is
possible. The OAuth Need, its binding, its Repo and its timeouts are the host's; the
Piece decides only on what the Need answers. An OAuth token that passes the check
but breaks the client's 24-byte or fixed-string rule is admitted and then refused
before each request (`credentials_unavailable`). mcp-client's session ledger takes
at most 64 distinct tokens per session: a 65th distinct token is refused before its
request (`credentials_unavailable`), so an OAuth connection that refreshes often (for
example oauth-client with no `expires_in` and no `default_lifetime_s`, a new token at
each call) stops a session after 64 requests, and the host must reconnect (a new
`admit/1` and `connect/2`). This is mcp-client behavior, carried and not tested here;
issue #912 is the follow-up repair. `admit/1` called inside a host
transaction gets oauth-client's `:in_transaction` through the Need and refuses
`credentials_unavailable`. The pairing and the `list_tools/2` match tie tenant, server text and
URL only: configs that differ only in credential (form, reference or connection id),
addresses or bounds share
the intent identity, so one credential per `{tenant, server}` is the host's duty. The
ready client's Adapter context is not opaque: host code that edits a context's
session or key bypasses the pairing. No claim about what a tool
does.
