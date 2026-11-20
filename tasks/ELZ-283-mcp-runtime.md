# ELZ-283 — Admit a tenant-added MCP server only through the egress policy, with a bearer token per call

- Phase: Wave 5 Level 3 (sub-level 3b)
- Dependencies: ELZ-033, ELZ-105, ELZ-271, ELZ-282
- Release: V1B
- Output: new `integration/mcp-runtime` Piece (the RC-59 Wave 5 commitment)
- Change class: Piece-only
- Owned paths: `pieces/integration/mcp-runtime/**` and its own catalogue/release-plan rows and generated views only. Do not edit root/shared code, another Piece (`integration/mcp-client`, `integration/mcp-multi`, `integration/egress-policy`, `integration/secrets`), `mix.exs`, `mix.lock` or CI.

## Outcome and reuse boundary

One bounded Adapter, plain Elixir; no new provider, no OAuth (Wave 9 `integration/oauth-client`), no stdio. It turns one MCP server that a tenant added at run time into a ready client config. It does this only after three steps:

1. The ready `integration/egress-policy` (ELZ-271) admits the URL and every resolved address is public.
2. The ready `integration/secrets` (ELZ-105) releases the bearer token once, as the check before connecting.
3. The ready `integration/mcp-client` runtime mode (ELZ-282) is configured with exactly the egress host, port and address set.

The host then calls the unchanged `Elzoo.McpClient.connect/2`, `admission/3`, `context/2` and `call_tool/3`. This Piece does not wrap them. Tool lists are keyed by `{tenant, server}` (RC-59: one tenant credential per server). `integration/mcp-multi` keeps its build-time set and is not edited.

## Interface

- `Elzoo.McpRuntime.configure(opts)` returns `{:ok, config}` or `{:error, :configuration}` and calls no Need. It takes exactly these keys:
  - `tenant`: the `Elzoo.McpClient.configure/1` tenant text;
  - `server`: 1..128-byte text;
  - `url`: the tenant's URL. It must have no query, because `integration/mcp-client` refuses one; a query is `:configuration` here;
  - `policy`: an `Elzoo.EgressPolicy.policy/1` value;
  - `resolver`: the egress resolver Need;
  - `credential`: `%{ref: binary, scope: binary}`;
  - `secrets`: an arity-1 function that returns the trusted `Elzoo.Secrets` context for that request, as in `integration/mcp-multi`;
  - optionally the ready client bounds (`protocol_mode`, `call_timeout_ms`, `handshake_timeout_ms`, `max_request_bytes`, `max_response_bytes`, `max_pages`, `max_tools`, `max_descriptor_bytes`), passed on unchanged.

  `config` has a redacted `Inspect`.
- `Elzoo.McpRuntime.admit(config)` returns `{:ok, client_config}` or `{:error, reason}`. Order:
  1. `Elzoo.EgressPolicy.resolve(url, policy, resolver)`; an error is `{:error, {:egress, reason}}` with egress-policy's own reason. Nothing later runs.
  2. `secrets.(credential)` and then `Elzoo.Secrets.resolve/2` once, dropping the value: `{:error, :expired}` is `{:error, :credentials_expired}`. Any other failure, or a raise, throw or exit of `secrets`, is `{:error, :credentials_unavailable}`.
  3. `Elzoo.McpClient.configure/1` with `binding: Elzoo.McpClient.RuntimeBinding` and `runtime: %{server: server, endpoint: url, network: :public, addresses: addresses}`. The credential Need resolves the reference again at each request, as in `integration/mcp-multi`, and gives `{:ok, Elzoo.Secrets.reveal(credential)}` or `{:error, :credentials_unavailable}`. A refusal is `{:error, :configuration}`.
- `Elzoo.McpRuntime.list_tools(config, session)` returns `%{{tenant, server} => {:ok, listing} | {:unavailable, reason}}`. It repeats step 2 before the call; `reason` is `:credentials_expired`, `:credentials_unavailable` or the ready client's finite reason. `listing` is the unchanged ready `list_tools/1` result.

Errors are fixed atoms or the tuples above and never echo the URL, host, token or reference. The Piece emits no telemetry and no log of its own.

## Acceptance

1. Egress first: for `http://`, an IP-literal host, a non-allowlisted host, a wrong port, an `:nxdomain` answer, a resolver raise, an answer of `[{10,0,0,1}]`, `[{169,254,169,254}]`, `[{127,0,0,1}]` and the mixed `[{8,8,8,8}, {192,168,1,1}]`, `admit/1` returns `{:error, {:egress, reason}}` with egress-policy's reason. Neither `secrets` nor the Secrets resolver is called, and no client or socket is started (count the calls; no `ExMCP.Client` process exists).
2. Admission: with an allowlisted `https` URL and a resolver answering two public addresses, the returned `%Elzoo.McpClient.Config{}` holds exactly the egress host, port and sorted addresses, network `:public` and server text. Its credential Need resolves the reference again on each call (counted) and returns the token. A query in `url` is `:configuration`.
3. Credentials: `:expired` gives `:credentials_expired`; `:denied`, `:missing`, `:unavailable`, a raise, a throw and an exit of `secrets` give `:credentials_unavailable`. Each happens after egress passes and before any client starts.
4. Keying: two runtime servers of one tenant and one server text in two tenants give distinct `{tenant, server}` keys and distinct intent identities for one `ref`. The ready `admission/3` builds the identities and the test compares them.
5. Composition evidence: the ELZ-282 loopback runtime tests are the transport evidence. This Piece cannot reach a loopback server through egress-policy, by design. Record that a successful public connect is not exercised.
6. Secrecy: the URL, host, token and reference bytes appear in no result, raised message, inspected value or captured log.
7. Negative controls, one at a time: resolve the credential before the egress check; hand mcp-client only the first egress address instead of the whole checked set; key lists by server only. Each must make a case of groups 1, 2 or 4 fail. Restore before the final gates.

Limits to state: addresses are as fresh as the admission; after a disconnect the host admits again. Redirect refusal and the response cap are ex_mcp and mcp-client duties, held by ELZ-282's drift tests. There is no live public endpoint in the evidence. One tenant credential per server (no per-person lists). No claim about what a tool does. Run the Piece tests and the new-Piece small gate (including the copied consumer), the roadmap and claims checks and the diff check. One independent review, the exact-head hosted check and the merge queue are required.
