# ELZ-282 — Let the MCP client take one endpoint at configure time, connecting only to addresses the host checked

- Phase: Wave 5 Level 3 (sub-level 3a)
- Dependencies: ELZ-033, ELZ-083
- Release: V1B
- Output: in-place extension of the ready `integration/mcp-client` Piece (same Piece ID, pre-release rule of `AGENTS.md` section 4); no new Piece ID
- Change class: Piece-only
- Owned paths: `pieces/integration/mcp-client/**` and its own catalogue/release-plan rows and generated views only. Do not edit root/shared code, another Piece (`integration/mcp-multi`, `integration/egress-policy`, `delivery/effect-intent`), `mix.exs`, `mix.lock` or CI.

## Changed Contract

Today an endpoint is fixed at build time by `use Elzoo.McpClient.Binding, id:, server:, endpoint:, network:, recovery_grace_ms:`, and the transport never passes ex_mcp's `:dns_resolver`. Level 3 `integration/mcp-runtime` (ELZ-283) needs one server that a tenant adds at run time, behind `integration/egress-policy` (ELZ-271). The host there checks the URL and resolves its addresses once, and the client must then connect only to those addresses. This task adds that mode. The build-time path, its outcomes, intent identities and tests stay unchanged, so `integration/mcp-multi` keeps its build-time bindings (RC-59 decision).

Observed at the locked ex_mcp 1.8.1 (`deps/ex_mcp`, `@moduledoc false` modules, an upstream risk held by drift tests as the Piece already does for `make_request/5`):

- `ExMCP.Transport.HTTP.TargetPolicy.resolve/2` takes a `:dns_resolver` arity-2 function, `resolver.(host, timeout)`. It treats `{:ok, [address]}` (non-empty, valid tuples) as the answer, passes `{:error, :dns_timeout}` through as `:dns_timeout`, and gives `:dns_failed` for anything else. It de-duplicates the answer and refuses the whole of it unless every address passes its check for the host's network. It then connects to the smallest remaining address in term order (`Enum.sort |> hd`).
- The MCP POST goes through `ExMCP.Transport.HTTP.BoundedClient`, which uses `Mint.HTTP1` to connect to the pinned address. Mint never follows a redirect, so a 3xx is not followed. The `autoredirect: false` option is set only on the httpc and stream request options, not on this path.

## Interface added

- The Piece ships one compiled binding module, `Elzoo.McpClient.RuntimeBinding`. Its EffectIntent descriptor has its own `id` and the provider account `"mcp:runtime"`, and fixes no endpoint. Its failure table and no-send attestations equal the build-time ones.
- `Elzoo.McpClient.configure/1` accepts one new key, `runtime`, only together with `binding: Elzoo.McpClient.RuntimeBinding`. Either one without the other is `{:error, :configuration}`. `runtime` is exactly `%{server: text, endpoint: url, network: :public | :loopback, addresses: list}`:
  - `server`: the existing 1..128-byte server text rule;
  - `endpoint`: the existing `Wire.endpoint/2` rule for that network (`:public` requires `https` and a non-loopback host; `:loopback` exists only so this Piece's loopback evidence server can serve the mode);
  - `addresses`: 1..32 distinct `:inet` 4- or 8-tuples.

  All other keys and their ranges are unchanged. The credential Need is still not called here.
- With `runtime`, the transport passes ex_mcp a `:dns_resolver` that answers `{:ok, addresses}` for the endpoint host (compared after ASCII lowercasing) and `{:error, :nxdomain}` for any other host. It never consults DNS. The `:public` option list otherwise equals the build-time `:public` list.
- Intent identity keeps the five elements that `delivery/effect-intent` requires: exactly five texts of 1..256 bytes (`Elzoo.EffectIntent.Model.valid_identity?/1`), where elements 2, 3 and 4 must equal the compiled descriptor's `provider_account`, `id` and `operation`. With `runtime` the identity is `[tenant, "mcp:runtime", RuntimeBinding id, "tools/call", digest]`. `digest` is `"rt1:"` followed by the 64 lowercase hex characters of SHA-256 over the length-framed concatenation `<<byte_size(server)::32, server, byte_size(endpoint)::32, endpoint, byte_size(ref)::32, ref>>`, so it is always 68 bytes. An endpoint can be 512 bytes, which is why it is not used raw. So two runtime servers, or one server at two endpoints, never share an intent key. Build-time identity stays `[tenant, provider_account, id, operation, ref]`, unchanged.
- The credential rule's configured strings (`Elzoo.McpClient.Credential.configured/1`) also cover the runtime `server`, the endpoint URL and the endpoint host, so a credential equal to a substring of any of them is `refused{credentials_unavailable}` before any send.
- `list_tools/1` reports the runtime `server`. Every outcome row of the README table keeps its meaning. A pinned answer that ex_mcp refuses is `refused{target_refused}` before any byte.

## Acceptance

1. All existing tests of this Piece and of `integration/mcp-multi` pass unchanged.
2. Runtime mode on the loopback evidence server (`network: :loopback`, `addresses: [{127,0,0,1}]`): connect, list tools, and one `tools/call` that completes through the EffectIntent owner, each with the same outcome table as the build-time path. Two runtime configs that differ only in `server`, and two that differ only in `endpoint`, give different intent keys for one `ref`. The runtime identity has five elements whose fifth is 68 bytes, also for a 512-byte endpoint and a 256-byte `ref`, and the EffectIntent owner accepts it.
3. Pinning: the evidence server binds `{127,0,0,1}` only. A runtime config for `http://localhost:<port>` with `addresses: [{127,0,0,2}]` cannot connect (the connect fails with the server's request counter at zero), although the system resolver would answer `127.0.0.1` for `localhost`, so the pinned list was used. With `addresses: [{127,0,0,1}]` it connects. A `:public` runtime config whose addresses include `{10,0,0,1}` or `{127,0,0,1}` is `refused{target_refused}` before any byte. The resolver closure answers `:nxdomain` for another host.
4. Configure: `runtime` without `RuntimeBinding` and the reverse; an extra or missing `runtime` key; a `:public` `http` endpoint; a loopback host under `:public`; 0 and 33 addresses; a duplicate address; a 5-tuple and an octet 256. Each is `{:error, :configuration}`. A credential that is a substring of the runtime server text, of the endpoint URL or of its host is `refused{credentials_unavailable}` with the server's request counter at zero.
5. Drift tests, calling ex_mcp 1.8.1 directly: `TargetPolicy.resolve/2` with an injected resolver returns the smallest pinned address of a duplicated answer, refuses a mixed public/private answer and passes `{:error, :dns_timeout}` through as `:dns_timeout`; the loopback evidence server answering 302 to the MCP POST, which goes through `BoundedClient` (Mint), is not followed (the redirect target's counter stays zero).
6. Negative controls, one at a time: pass no `:dns_resolver` in runtime mode, so the system resolver answers; leave `server` and `endpoint` out of the runtime identity digest; leave the runtime strings out of the credential rule; accept `runtime` with a build-time binding. Each must make a case of groups 2–4 fail. Restore before the final gates.

Limits to state: addresses are as fresh as the host's check, and a reconnect needs new ones. The `:loopback` runtime network is evidence support, not an egress policy. No OAuth (Wave 9), no stdio, no run-time change of a configured endpoint. The ex_mcp facts above are pinned observations of `@moduledoc false` code. Run the Piece tests and the small gate (the dependent `integration/mcp-multi` tests run in it), the roadmap and claims checks and the diff check. One independent review, the exact-head hosted check and the merge queue are required.
