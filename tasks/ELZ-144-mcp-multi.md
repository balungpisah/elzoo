# ELZ-144 — Several MCP servers per tenant, from a build-time set

## Scope and reuse

- Dependencies: ELZ-033, ELZ-083, ELZ-105
- Output: `integration/mcp-multi` (new Piece ID); release V1B; bot-platform level 1.
- Owned paths: `pieces/integration/mcp-multi/**` and its index/generated changes under AGENTS.md section 3.

Several MCP servers for one tenant behind the ready one-server Contract of `integration/mcp-client`. Each server stays one compiled `Elzoo.McpClient.Binding` module with its own session, its own credential Need and its own bounds. This Piece composes the set, keys each tool list by tenant and server, keeps one server's failure away from the others and builds each credential Need from an `integration/secrets` reference. Streamable HTTP and a bearer token only.

Implement only the eight acceptance groups below. Add no options, layers, behaviours, generic helpers or future hooks: no cache, no process of its own, no reconnect, no push or subscription, no tool alias, no macro. Change no ready Piece, shared path, `mix.exs`, `mix.lock`, `registry/providers.json` or CI file: `ex_mcp` stays at its pin and no provider is added. The independent reviewer flags extra features for removal.

Reuse, checked on main. The Piece dependencies are `integration/mcp-client` and `integration/secrets`:

- `Elzoo.McpClient.configure/1`, `connect/2`, `list_tools/1` and `close/1` do the work for one server. `configure/1` takes no endpoint; the endpoint, the server identity and the network policy are fixed in the Binding module and `Elzoo.McpClient.Binding.load/1` reads them. Call these functions; do not write their rules a second time.
- A tool call stays the ready path: `Elzoo.McpClient.admission/3`, `context/2` and `call_tool/3` with a `delivery/effect-intent` owner. This Piece adds no call function. The intent identity already holds the tenant and the provider account of the Binding (server and endpoint).
- `Elzoo.Secrets.resolve/2` and `reveal/1` give the token. The README of `integration/secrets` shows the form of a zero-arity Need.
- The ready client has no OAuth, no `list_changed` subscription and no standalone stream. A 401 or 403 is `authentication_failed`.

## Interface: `Elzoo.McpMulti`

Five public functions over two plain values. `inspect/1` of both values shows the tenant and the Binding modules only.

`configure(opts)` returns `{:ok, config}` or `{:error, :configuration}`. It calls no function of the host. Exact keys:

- `tenant`: the tenant text that `Elzoo.McpClient.configure/1` takes.
- `secrets`: a one-argument function. For a server's request `%{ref: ref, scope: scope}` it returns the trusted `Elzoo.Secrets` context (`grant`, `resolver`, optional `clock`) with fresh authority.
- `servers`: a list of 1..16 entries. The bound 16 is fixed. Each entry is a keyword list with exactly `binding` (one compiled Binding module), `credential` (an exact `%{ref: binary, scope: binary}` map, the `Elzoo.Secrets` request) and, optionally, the bounds of the ready client for that server alone: `protocol_mode`, `call_timeout_ms`, `handshake_timeout_ms`, `max_request_bytes`, `max_response_bytes`, `max_pages`, `max_tools`, `max_descriptor_bytes`. They go to `Elzoo.McpClient.configure/1` unchanged, with its ranges and defaults.

The build-time set is this `servers` list, written by trusted host code. Each entry names a compiled module, so no tenant data can set a server identity, an endpoint or a network policy. This Piece compiles and loads no module and has no function that adds or removes a server after `configure/1`. The key of a server is the `server` text of its Binding. Two entries with the same server text, an unknown key, or a refusal of the ready `configure/1` for one entry give `{:error, :configuration}` for the whole set.

For each entry the Piece builds the zero-arity credential Need of the ready client: it calls `secrets.(request)`, then `Elzoo.Secrets.resolve(request, context)`, and returns `{:ok, Elzoo.Secrets.reveal(credential)}` or `{:error, :credentials_unavailable}`. The Need resolves again at each request; nothing is stored.

`connect(config, dynamic_supervisor)` returns `{:ok, multi}`. It takes the servers in the declared order. For each one it first resolves the reference once in the calling process and drops the value (the check before the call), then calls the ready `connect/2`. A server that fails is recorded as `{:unavailable, reason}` and the next server is taken.

`list_tools(multi)` returns a map with one key `{tenant, server}` for each declared server. The value is `{:ok, listing}`, where `listing` is the unchanged result map of the ready `list_tools/1` (`server`, `protocol_version`, `tools`, `truncated`; tool names and the five descriptor fields untouched), or `{:unavailable, reason}`. A server that was unavailable at `connect/2` keeps that reason. For each other server the Piece makes the check before the call and then asks the server again. Each call asks again: a changed list is seen by the next call.

`session(multi, server)` returns `{:ok, client_config, session}` (the ready values, for `admission/3`, `context/2` and `call_tool/3`), `{:unavailable, reason}` as `connect/2` recorded it, or `{:error, :unknown_server}`.

`close(multi)` closes each session and returns `:ok`.

Reasons of `{:unavailable, reason}`, a closed set:

- `:credentials_expired`: the check before the call got `{:error, :expired}` from `Elzoo.Secrets`. Nothing is sent to that server. Expiry is named in no other case.
- `:credentials_unavailable`: the check before the call got another error, or `secrets` raised, threw, exited or returned no context. Nothing is sent to that server. The same reason passes through when the ready client gives it under its own Contract, for example for a token outside its credential rule.
- The other finite reasons of the ready client, unchanged: `:authentication_failed`, `:target_refused`, `:connect_failed` from `connect/2`; and from `list_tools/1` also `:not_connected`, `:server_error`, `:malformed_response`, `:timeout`, `:connection_lost`, `:adapter_error`.

A tool call keeps the ready outcome set. A credential that is missing or expired when the call resolves it is `refused{credentials_unavailable}` with nothing sent, and is not named expired. A credential that the server rejects with 401 or 403, for any cause, is `refused{authentication_failed}` after dispatch.

## Host Needs and Limits

Needs: the application of `ex_mcp` started by the consumer, and its own telemetry handled by the consumer; a `DynamicSupervisor`; a truthful `secrets` function and resolver, with each scope bound to one tenant and one server; the recipient and the owner of each tool call, as the ready client needs them.

Limits: one tenant credential for each server. Lists for a credential of a person need separate lists and are not here. Servers are taken one after another, so a call costs at most the sum of the bounds of the servers; one server that does not answer delays the others by its own bound and does not fail them. No reconnect: a server that is down stays unavailable until the host connects a new value. No rename and no model-facing alias: `workflow/tool-registry` owns it. No stdio, no OAuth, no server added at run time. The check before the call and the Need are two samples of the resolver; a rotation between them is possible. No claim about what a tool does. Declare Telemetry as the ready client does (no Elzoo event), Config as supported at construction with no hot update, Control as not applicable beyond `close/1`.

## Named acceptance groups

No real MCP server and no provider credential is used. Require the helper of the ready client, `pieces/integration/mcp-client/test/support/mcp_client_test_helper.exs`, as `pieces/workflow/run/test/support/run_test_helper.exs` requires the SQL helper (a local copy first, then the relative path). Do not edit it. It gives the in-process loopback server `Elzoo.McpClientTest.Server` (`start/1`, `mode/2`, `stop/1`, and `binding/3` for a test Binding). Each server instance has the tools `echo`, `fail`, `strict` and `structured`. Start each instance with its own parent process, because the request record `{:mcp_request, method_or_path, authorization_present?, body}` does not name its server. Dispatch a tool call through a real `Elzoo.EffectIntent` owner on the volatile Memory store, as test T3 of the ready client does. The resolver is a test function that records its calls.

1. **`same_tool_name_two_servers`**: two servers both list `echo`. The result has two keys with the same tenant and two server texts. A call of `echo` through `session/2` of one server reaches only that server, and the two admissions have different intent keys.
2. **`lists_keyed_by_tenant_and_server`**: two tenants, with one server in both sets. Each `list_tools/1` returns only keys of its own tenant and resolves only references of its own tenant. The two values share no session and no process.
3. **`one_server_down`**: one server stopped before `connect/2`, and in a second run stopped after it. Its key is `{:unavailable, reason}` with a reason of the closed set. The other server lists its tools and completes a call.
4. **`missing_credential_sends_nothing`**: the resolver gives `{:error, :missing}` for one server. `connect/2` and `list_tools/1` give `{:unavailable, :credentials_unavailable}` for it, its request record is empty, and the other server works. A credential that goes missing after `connect/2` gives the same reason at `list_tools/1` with no new request, and `{:refused, :credentials_unavailable}` at a tool call with no `tools/call` request.
5. **`rejected_credential_after_dispatch`**: the server answers 401, then 403 (`mode/2` with `:auth401` and `:auth403`). The call is `{:refused, :authentication_failed}` with exactly one `tools/call` request, and no returned value names expiry. With a clock at or past the expiry of the reference, `connect/2` and `list_tools/1` give `{:unavailable, :credentials_expired}` and the request record is empty.
6. **`list_change_seen_by_listing_again`**: `mode/2` with `{:echo_list, ""}` changes the list of one server between two `list_tools/1` calls. The second result differs for that key only. The request record holds `tools/list` requests only: no stream is opened and nothing is pushed.
7. **`per_server_bounds`**: one server with `max_tools: 2` gives two tools and `truncated: true`; the other server in the same set gives all four. 17 entries, two entries with one server text, and a bound outside the range of the ready client give `{:error, :configuration}`, and no function of the host is called.
8. **`no_credential_in_outputs`**: each reference has its own token of at least 24 bytes. Across the groups above, with a server that echoes its header (`:echo_auth` and `{:echo_list, _}`), no token is in any returned value, `inspect/1` of the two values, or log captured at `:debug`. This Piece emits no event.

## Evidence

Tests only. No Cure law is selected: the Piece is composition and Adapter translation.

- Test: the eight groups against the in-process loopback server; finite evidence. One small checked example builds a config for two Bindings and opens no connection. Two negative controls. Key the result by server text alone for a moment: `lists_keyed_by_tenant_and_server` must fail. Let the first unavailable server end `list_tools/1` for a moment: `one_server_down` must fail. Revert both.
- Upstream: `ex_mcp` 1.8.1 at its exact pin and the ready `integration/mcp-client` and `integration/secrets` Contracts, used unchanged. The redaction of a token in server data is the ready client's, per session.
- Assumption: a 401 or 403 means that nothing ran (the named assumption of the ready client); the host Needs above. Proof and monitored behavior: none.

Run the Piece tests, then `mix check --piece "$(git merge-base origin/main HEAD)"` and `git diff --check`. Record commands, exit codes, scenarios and limits separately. One independent review checks this body and the exact diff, including features that nobody asked for.
