# ELZ-377 — integration/mcp-server binds each MCP session to the verified principal and refuses subscriptions/listen

- Phase: in-place change of a ready Piece before the first release (Wave 9, Level 2; repairs of ELZ-363's stated limits, issues #888 and #889, wanted before the Wave 9 root acceptance relies on the server)
- Dependencies: ELZ-363
- Release: V1B
- Output: none. A Contract change in place of the ready Piece `integration/mcp-server` (ELZ-363), before the first release, with the same Piece ID (`AGENTS.md` section 4). One task for both issues, by coordinator decision at publication (2026-11-24): both change `lib/elzoo/mcp_server/plug.ex` (`http_opts/1` and `authenticate/2`), `test/elzoo/mcp_server_test.exs`, the README and the same `piece.json` limit sentence, and they meet in ex_mcp (binding a session sets ex_mcp's subscription authorization, which changes what `subscriptions/listen` does), so two tasks would collide on every owned path.
- Change class: Piece-only implementation
- Owned paths: `pieces/integration/mcp-server/**`; in `docs/plans/release-plan.json` the `manifest_sha256` and `note` of the `integration/mcp-server` row of `entries`; the generated `LEDGER.md`, `docs/plans/views.md` and `docs/plans/dependencies.mmd`. No other Piece (not `integration/token-verify`, `integration/mcp-client` or `domain/principal`), no root test or helper, no `mix.exs`, `mix.lock` or CI.

## Outcome and boundary

Two limits that ELZ-363 states become rules.

- **#888, sessions.** Today ex_mcp's sessions carry no identity (`oauth_enabled: false`, no `principal_id` or `tenant_id`), so any verified caller that holds another caller's session ID can end it with `DELETE`, and a legacy request on another principal's session reaches the handler (where the tool decision refuses it). After this task each session is bound at `initialize` to the verified principal's tenant and identity, and every later request or `DELETE` on it from another principal is refused by ex_mcp's session check before the handler.
- **#889, `subscriptions/listen`.** Today ex_mcp serves a modern `subscriptions/listen` from its own registry after the token check, and the stream stays open up to ex_mcp's default lifetime of one hour, past the token's expiry, receiving nothing from this Piece. The Piece exposes no resources or subscriptions, so it refuses the method in its Plug before ex_mcp. Bounding the stream by the token's expiry would need the expiry, which `integration/token-verify` does not return (facts below); it stays open.

The Piece takes untrusted input and decides authentication per request, so this task keeps the local small gate and gets the full review of the coordinator guide ("Reviewer by risk").

## Facts on `main` that this task builds on

Checked at `main` `b9d1c9d5` and `deps/ex_mcp` 1.8.1, by reading the code (none of the ex_mcp paths below has a test in this Piece yet). The task's first step confirms each with a test; if one differs, stop and comment on the issue with the gap.

- `Elzoo.McpServer.Plug.authenticate/2` (`lib/elzoo/mcp_server/plug.ex`, lines 44–54) reads the bearer token, verifies it, assigns `:elzoo_mcp_principal` and calls `ExMCP.HttpPlug.call(conn, ExMCP.HttpPlug.init(http_opts(server)))` on each request; else HTTP 401. It never reads the body. `http_opts/1` (lines 56–73) sets `handler`, `handler_opts` (a one-arity function of the conn), `handler_call_timeout`, `body_limit`, `server_info`, `server_capabilities: %{tools: %{}}`, `legacy_http_sse: false`, `oauth_enabled: false` and `validate_origin: false`; no `principal_id` or `tenant_id`.
- `%Elzoo.Principal{kind, id, tenant, auth_epoch, delegated_by, allowed_scopes, allowed_spaces}` (`pieces/domain/principal/lib/elzoo/principal.ex`, line 18), `kind` `:human` or `:service` (line 23); `Elzoo.TokenVerify.verify_jwt/3` returns only the principal: `exp` is checked (`pieces/integration/token-verify/lib/elzoo/token_verify.ex`, line 233) but not returned, and an API key's expiry may be `nil` (line 98).
- ex_mcp `HttpPlug`: `init/1` takes `principal_id` and `tenant_id` (`deps/ex_mcp/lib/ex_mcp/http_plug.ex`, lines 189–190), each `nil`, a binary or a function of the conn (one-, two- or three-arity) or an MFA, resolved per request by `resolve_mrtr_identity/4` (lines 1062–1112); a value that is not `nil` or a binary is `:invalid_mrtr_identity`. They go into the session metadata (lines 1838–1849). `ExMCP.SessionManager` binds `[:principal_id, :tenant_id, :issuer, :audience]` (`deps/ex_mcp/lib/ex_mcp/session_manager.ex`, line 104) and refuses a request whose identity differs from the session's (`session_identity_matches?/2`, lines 831–838; `ensure_session/…` and `ensure_initialized_session/…`, lines 458–491) as `:session_identity_mismatch`, which `HttpPlug` answers HTTP 404 with JSON-RPC `-32600` "Session not found" (lines 859–860, 2442–2450). `DELETE` runs the same identity resolution and session check (`handle_session_delete`, lines 1127–1229): a mismatch is 404 (lines 1196–1197), success 204 (line 1170). A modern-era request ignores session headers (lines 553–575), so the binding acts on legacy-era requests; the ready `integration/mcp-client` defaults to `:modern_only` (`pieces/integration/mcp-client/lib/elzoo/mcp_client.ex`, line 64), so the session cases are raw legacy POSTs, as case 4 of ELZ-363 already sends them (`test/elzoo/mcp_server_test.exs`, `raw/5`, lines 372–412).
- ex_mcp `subscriptions/listen`: `process_mcp_request/2` sends it to `open_http_subscription/2` before any handler code (`http_plug.ex`, lines 2130–2132), which requires the modern era (lines 2207–2228); its lifetime defaults to 3,600,000 ms (`deps/ex_mcp/lib/ex_mcp/server/subscriptions.ex`, line 691). With `principal_id` or `tenant_id` set, ex_mcp requires subscription filter and publication authorizers, which default to none, and rejects the listen (`subscriptions.ex`, lines 137–142, 648–672). A modern request must carry exactly one `Mcp-Method` header equal byte for byte to the body's `method` (`http_plug.ex`, lines 946–958, 2626–2638; `deps/ex_mcp/lib/ex_mcp/transport/http/request_headers.ex`, lines 59–69, 146–169). An upstream Plug may read the body and put it in `conn.assigns[:raw_body]`, which ex_mcp then uses, still bounded by `body_limit` (`http_plug.ex`, lines 970–989). A `GET` on the endpoint with the legacy SSE transport off is HTTP 404 (lines 335–340, 457–465).
- Case 4 of ELZ-363 asserts `unknown tool` for bob's `tools/call` on alice's session (`test/elzoo/mcp_server_test.exs`, line 796); no test covers `DELETE`, `GET` or `subscriptions/listen`. The README states the gaps at lines 90–96 and 201–204, and `piece.json` in one limit sentence (line 21).
- No code outside the Piece's directory calls `Elzoo.McpServer` or its Plug; inside it, `examples/mcp_server.exs` and the test router (`test/support/mcp_server_test_helper.exs`, line 23) mount it, and they keep working.

## The Contract change

- **Binding.** `http_opts/1` sets `tenant_id` to a one-arity function of the conn returning the verified principal's `tenant`, and `principal_id` to one returning `Atom.to_string(kind) <> ":" <> id` (unambiguous, since a kind holds no `:`). A legacy `initialize` creates a session bound to both; a later request or `DELETE` that names the session with a token of another tenant or another identity is HTTP 404 `-32600` "Session not found" from ex_mcp, with no handler started and no Need beyond the token check called; the same principal's requests and its `DELETE` (204) work as today. A principal whose token was re-issued (same tenant, kind and id) keeps its sessions.
- **Listen.** After the token check and before ex_mcp, the Plug refuses a request whose `mcp-method` header is `subscriptions/listen`, and a request whose body (read by the Plug within `body_limit`, then put in `assigns[:raw_body]` for ex_mcp) is a JSON-RPC request, or an array holding one, with that method. The answer is HTTP 200 with the JSON-RPC error `-32601` "Method not found", the request's `id` when it has one, and no stream. A body over `body_limit` is still HTTP 413; the token check still runs before the body is read, so a 401 reads no body.
- Everything else is today's: the token check and its 401, the tools, the handler timeout, the bounds, and the case-4 rule for a request without a foreign session (`unknown tool`).

`piece.json` (the contract, the `http_opts` list and the limit sentence) and the README (options table, session paragraph, listen paragraph) follow; the README states that sessions are ex_mcp's process-local store (its default 10,000 sessions and one-hour TTL are unchanged and upstream) and that the expiry bound of a stream is kept open.

## Kept open (owner's "no corner" rule)

- *Subscriptions bounded by the token's expiry and a declared maximum*, once `integration/token-verify` returns the expiry (its own task) or the Piece exposes resources.
- *Binding to `auth_epoch`*, so a re-issued token ends older sessions.

## Acceptance

Through the test router on `Plug.Cowboy` at `127.0.0.1` with raw legacy POSTs (as ELZ-363's case 4), raw modern POSTs and the ready client in `:loopback` mode:

1. Alice's legacy `initialize`, `tools/list` and `tools/call` on her session work as today; bob's `tools/call` and `tools/list` on alice's session, and a principal of another tenant on it, are HTTP 404 `-32600` with no handler started (a counting handler double) and no `start` call. Case 4 of ELZ-363 is amended to this.
2. Bob's `DELETE` of alice's session is 404, and alice's session still answers her next request; alice's `DELETE` is 204, and her next request on it is 404.
3. A `service` and a `human` principal with the same `id` in one tenant do not share a session.
4. A modern `subscriptions/listen` with its `Mcp-Method` header, one whose body names it with the header naming another method, and a legacy-era body naming it are each answered `-32601` with no stream (the response completes within 1 s) and no handler started; a body over `body_limit` naming it is 413; a request without a token naming it is 401.
5. A `GET` with `accept: text/event-stream` is 404.
6. Every other case of ELZ-363 passes unchanged (the ready client's lists and calls, the 401 cases, the bounds, the timeouts, 413).
7. Negative controls, one at a time, each restored before the final gates: drop `principal_id` and `tenant_id` from `http_opts/1` (case 1's foreign-session and case 2's foreign `DELETE` cases fail); drop the listen refusal (case 4 fails, or reaches ex_mcp's own rejection: the task records which).

Run the Piece tests and the small gate locally (`mix check --piece "$(git merge-base origin/main HEAD)"`), the roadmap and claims checks and the diff check. The full independent review, the exact-head hosted check and the merge queue are required.

## Limits to state

Sessions and their store are ex_mcp's; the binding is ex_mcp's session check on the identity the Piece gives. A session ID still grants no tool: every request is decided on its own token. No subscription, resource or stream is served. The upstream HTTP 500 observation of ELZ-363 after a handler timeout stays as stated.
