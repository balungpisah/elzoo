# integration/mcp-multi

Several MCP servers for one tenant, from a build-time set, over the ready one-server
Contract of [`integration/mcp-client`](../mcp-client/README.md). Each server stays one
compiled `Elzoo.McpClient.Binding` module with its own session, its own credential Need
and its own bounds. This Piece composes the set, keys each tool list by tenant and
server, keeps one server's failure away from the others and builds each credential
Need from an [`integration/secrets`](../secrets/README.md) reference. Streamable HTTP
and a bearer token only.

## Interface: `Elzoo.McpMulti`

Five functions over two plain values, `%Elzoo.McpMulti.Config{}` and
`%Elzoo.McpMulti.Set{}`. `inspect/1` of both shows the tenant and the Binding modules
only.

- `configure(opts)` returns `{:ok, config}` or `{:error, :configuration}` and calls no
  function of the host. Exact keys:
  - `tenant`: the tenant text that `Elzoo.McpClient.configure/1` takes.
  - `secrets`: a one-argument function. For a server's request
    `%{ref: ref, scope: scope}` it returns the trusted `Elzoo.Secrets` context
    (`grant`, `resolver`, optional `clock`) with fresh authority.
  - `servers`: 1..16 keyword entries (the bound 16 is fixed), each with exactly
    `binding` (a compiled Binding module), `credential` (`%{ref: binary, scope: binary}`)
    and optionally the ready client bounds for that server alone: `protocol_mode`,
    `call_timeout_ms`, `handshake_timeout_ms`, `max_request_bytes`,
    `max_response_bytes`, `max_pages`, `max_tools`, `max_descriptor_bytes`. They go to
    `Elzoo.McpClient.configure/1` unchanged, with its ranges and defaults.

  The key of a server is the `server` text of its Binding. A repeated server text, an
  unknown key or a refusal of the ready `configure/1` for one entry refuses the whole
  set. No function adds or removes a server after `configure/1`.
- `connect(config, dynamic_supervisor)` returns `{:ok, set}`. It takes the servers in
  the declared order; for each one it first resolves the reference once in the calling
  process and drops the value (the check before the call), then calls the ready
  `connect/2`. A server that fails is recorded as `{:unavailable, reason}` and the next
  server is taken.
- `list_tools(set)` returns `%{{tenant, server} => {:ok, listing} | {:unavailable,
  reason}}` with one key per declared server. `listing` is the unchanged result of the
  ready `list_tools/1`. A server unavailable at `connect/2` keeps that reason; each
  other server gets the check before the call and is asked again, so a changed list is
  seen by the next call.
- `session(set, server)` returns `{:ok, client_config, session}` (the ready values for
  `Elzoo.McpClient.admission/3`, `context/2` and `call_tool/3`), `{:unavailable,
  reason}` as `connect/2` recorded it, or `{:error, :unknown_server}`.
- `close(set)` closes each session and returns `:ok`.

**Credential Need.** For each entry the Piece builds the zero-arity Need of the ready
client: `secrets.(request)`, then `Elzoo.Secrets.resolve(request, context)`, giving
`{:ok, Elzoo.Secrets.reveal(credential)}` or `{:error, :credentials_unavailable}`. It
resolves again at each request; nothing is stored.

**Reasons of `{:unavailable, reason}`** (a closed set):

- `:credentials_expired`: the check before the call got `{:error, :expired}`. Nothing is
  sent to that server. Expiry is named in no other case.
- `:credentials_unavailable`: the check before the call got another error, or `secrets`
  raised, threw, exited or returned no context. Nothing is sent to that server. The
  same reason passes through when the ready client gives it under its own Contract.
- The other finite reasons of the ready client, unchanged: `:authentication_failed`,
  `:target_refused`, `:connect_failed` from `connect/2`; from `list_tools/1` also
  `:not_connected`, `:server_error`, `:malformed_response`, `:timeout`,
  `:connection_lost`, `:adapter_error`.

**Tool calls** keep the ready path and outcome set; this Piece adds no call function.
The intent identity already holds the tenant and the provider account of the Binding.
A credential missing or expired when the call resolves it is
`refused{credentials_unavailable}` with nothing sent (not named expired); a credential
that the server rejects with 401 or 403 is `refused{authentication_failed}` after
dispatch.

## Needs

The application of `ex_mcp` started by the consumer, and its own telemetry handled by
the consumer; a `DynamicSupervisor`; a truthful `secrets` function and resolver, with
each scope bound to one tenant and one server; the recipient and the owner of each
tool call, as the ready client needs them.

## Grounding

- Proof: none. No Cure law is selected: the Piece is composition and Adapter
  translation.
- Test: `test/elzoo/mcp_multi_test.exs`, the eight named acceptance groups
  (`same_tool_name_two_servers`, `lists_keyed_by_tenant_and_server`, `one_server_down`,
  `missing_credential_sends_nothing`, `rejected_credential_after_dispatch`,
  `list_change_seen_by_listing_again`, `per_server_bounds`, `no_credential_in_outputs`)
  against instances of the ready client's in-process loopback server, and the checked
  example `examples/mcp_multi.exs` (construction only, no connection); finite evidence.
- Upstream: `ex_mcp` 1.8.1 at its exact pin and the ready `integration/mcp-client` and
  `integration/secrets` Contracts, used unchanged. The redaction of a token in server
  data is the ready client's, per session.
- Assumptions: a 401 or 403 means that nothing ran (the ready client's named
  assumption); the host Needs above.
- Monitored behavior: none.

## Operations

Telemetry `planned`, as the ready client: no Elzoo event and no log of its own;
ex_mcp's upstream events and debug logs reach consumer handlers. Config `supported` at
construction only (tenant, secrets function, the server set and per-server bounds; no
hot update, no server added at run time). Control `not_applicable` beyond `close/1`.

## Limits

One tenant credential for each server; lists for a credential of a person need
separate sets and are not here. Servers are taken one after another, so a call costs
at most the sum of the bounds of the servers; one server that does not answer delays
the others by its own bound and does not fail them. No reconnect: a server that is down
stays unavailable until the host connects a new value. No rename and no model-facing
alias (`workflow/tool-registry` owns it). No stdio, no OAuth, no server added at run
time. The check before the call and the Need are two samples of the resolver; a
rotation between them is possible. No claim about what a tool does.
