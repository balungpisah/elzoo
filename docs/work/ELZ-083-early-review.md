# ELZ-083 early independent Contract review

Reviewer: independent reviewer (Codex, gpt-5.6-terra, high effort)

Reviewed SHA: `71bb6b4dd2419ac82cb364e3cb980510eacdc2ce`

Inputs read: live issue #155 Contract; `docs/work/ELZ-083.md`; its diff from
`origin/main`; `docs/plans/catalogue-dispositions.md`; `AGENTS.md` and the
named capability, operations, change-class, consumption, and ready-Piece
Contracts; and ex_mcp 1.8.1 source.

## Findings

1. **blocking — server JSON-RPC errors are not evidence of pre-execution refusal.**
   Location: `docs/work/ELZ-083.md:144-155, 278, 287, 306-307, 330-336`; ex_mcp
   `lib/ex_mcp/client.ex:1040-1055, 1065-1075`. The proposed rows 10 and 11
   call wire replies `refused`, while the pinned client's own delivery contract
   says that every JSON-RPC error proves delivery but not that no action ran,
   and returns `:unknown`. The record itself correctly labels the non-execution
   claim as unverified. Map `-32602`, `-32600`, `-32601`, `-32700`, `-32020`,
   and server-defined errors to `unknown{server_error}` (with a bounded reason
   subtype if useful), `unknown/dispatched/unclassified`, and no attestation.
   Change T5 and T14 to assert that mapping. This preserves the intent
   boundary's no-rearm behavior and does not make a server's assertion into
   an effect-safety proof.

2. **should-fix — snapshot-based preflight contradicts the present discovery invariant.**
   Location: live issue #155, admission record item 2; `docs/work/ELZ-083.md:137-138,
   208-213, 278-280, 337-340`. The issue says a descriptor and its annotations
   and description never change what the Adapter does, but checking descriptor
   presence and its input schema changes the Adapter's behavior by refusing a
   call. The proposed behavior is reasonable only as a local, stale,
   fail-closed admission filter; it must not be described as a fact about the
   server's current tool set or schema. Amend the Contract before implementation
   and call the reasons `unknown_in_discovery_snapshot` and
   `invalid_against_discovery_snapshot`, or retain the shorter public tags but
   define them with that exact snapshot-qualified meaning. A server-side change
   after discovery remains a wire outcome and is `unknown`, not a fresh local
   refusal.

3. **should-fix — server-request wording omits two outbound protocol paths.**
   Location: live issue #155, admission record item 2; `docs/work/ELZ-083.md:77,
   253-256, 283, 290`. A no-handler client rejects roots, sampling, elicitation,
   and custom requests, but it always successfully answers server `ping` with
   `{}`: ex_mcp `lib/ex_mcp/client/request_handler.ex:1433-1475, 2027-2057`.
   Moreover, `connect/2` sends `server/discover` when applicable, `initialize`,
   and `notifications/initialized`: `lib/ex_mcp/client/era_probe.ex:97-113` and
   `lib/ex_mcp/client/connection_manager.ex:1015-1039, 1255-1271`. Declare those
   connect handshake messages, narrow the refusal invariant to data-bearing
   server-initiated methods, state the empty ping acknowledgement, and add
   request-count assertions for them. The existing no-handler plus empty
   capabilities pin prevents roots, sampling, elicitation, or custom-handler
   execution and prevents host-data disclosure.

4. **should-fix — in-memory result delivery needs a loss boundary, not a delivery claim.**
   Location: `docs/work/ELZ-083.md:164-171, 276, 341-342`. A send to a supplied
   process only attempts mailbox delivery; after that process exits the intent
   can settle with only a digest and the complete content is unavailable. Keep
   full tool content out of the effect-intent store, but make the recipient a
   trusted, local, monitored Adapter-context Need; specify that the message is
   best-effort and content loss after recipient exit does not turn completion
   into `unknown`. Add tests for a live recipient, a recipient that exits
   before result delivery, and redaction from owner status/evidence. A consumer
   requiring durable content must retain it after receipt or select a separate
   durable artifact boundary.

5. **note — the release-reference decision is implemented faithfully in the
   proposal.** Location: `docs/work/ELZ-083.md:22-24, 208-213, 281`. It is
   caller-supplied, shape-checked, included in canonical admission payload,
   recorded through the declaration/intent path, and never adapter-verified.
   Keep the missing and malformed-reference test as pre-admission, zero-send
   evidence.

6. **note — scope, operational declarations, and evidence categories are
   aligned.** Location: `docs/work/ELZ-083.md:5-30, 235-243, 261-311, 313-323`.
   The separate `integration/mcp-client` row and job preserve RC-30's
   `integration/sdk` scope; class X, one PR, loopback exercise, application
   startup, source-local audits, and non-`runtime: false` dependency are
   correctly recorded. Proof, type/contract check, tests, monitored behavior,
   upstream contracts, and assumptions are separated. `Telemetry: planned`,
   `Config: supported`, and `Control: not_applicable` are appropriate subject
   to recording actual in-bundle test paths in `piece.json`.

## Answers and upstream checks

### Finding 1 / Q1: header-mismatch retry

Confirmed. `ExMCP.Client.call_tool/4` delegates to
`Operations.Tools.call_tool/4`; that function calls `make_request/5`, then
unconditionally invokes `maybe_retry_header_mismatch/5`. On `-32020` it calls
`tools/list` and a second `make_request` for `tools/call`;
`lib/ex_mcp/client/operations/tools.ex:94-120, 233-259`. There is no option
that disables this path.

Recommendation: use the pinned, `@doc false` `ExMCP.Client.make_request/5`
directly. It is an acceptable, explicitly recorded upstream-contract reliance
at 1.8.1, not a stable public API promise. No supported public alternative
avoids the retry: the exposed `call_tool/4` and `call/4` take that path, and
their options provide no bypass. Do not replace it with direct GenServer or
transport calls.

Drift tests must run against the loopback server and show: a `-32020` response
causes exactly one `tools/call` and zero refresh `tools/list`; broken response
stream causes one `tools/call`; retryable transport failure causes one
`tools/call`; `input_required` causes one `tools/call`; and a provider-denied
401/403 causes one `tools/call`. Retain exact ex_mcp pin/lock evidence and a
compile-time call to the five-argument function. Those tests detect both API
removal and the behavioral drift that a successful compile would miss.

### Finding 2: MRTR

Confirmed. `max_mrtr_rounds: 0` is a real per-operation option. The default is
8, and `continue_mrtr/8` returns the round-limit protocol error before input
fulfillment or resend when `round >= maximum`;
`lib/ex_mcp/client.ex:76, 3409-3455`. `unknown{input_required}` is the honest
classification: the server already received and answered the first tool call,
and no completion or absence of partial work is established. Pass this option
on every direct `make_request/5` tool call, including any future call path.

### Finding 3: `http_stream_retry`

Confirmed. It is read from the options passed to `make_request/5`, defaults to
`:at_least_once`, and is not retained in client state:
`lib/ex_mcp/client.ex:3258-3277, 3578-3639`. `:safe_only` still retries
intrinsically safe `tools/list`, but not `tools/call` unless `retry_safe: true`
is also passed. The Adapter must build an operation option list for every
`list_tools` and direct `tools/call` invocation containing
`retry_policy: false` and `http_stream_retry: :safe_only`, and must omit
`retry_safe`; construction options cannot substitute for this. The call path
also needs `max_mrtr_rounds: 0` on every `tools/call`.

### Q2: JSON-RPC mapping

Recommend all rows 10-12 become `unknown{server_error}`. Preserve bounded
diagnostic reasons such as `server_invalid_arguments`,
`server_invalid_request`, and `server_protocol_error`, but do not map any to
`refused`. This follows the pinned library's documented `delivery_outcome/1`
semantics and the effect-intent requirement that only an attested no-send
failure establishes adapter no-send.

The 401/403 row is separately specified as an authentication rejection. If it
remains `refused{authentication_failed}`, identify HTTP authentication rejection
as the relied-on upstream pre-execution contract and test only its listed
scenario; it is not an attested no-send result and must never authorize rearm.

### Q3: discovery snapshot admission

Recommend it only after the amendment in finding 2. The snapshot is untrusted,
bounded data that can narrow local admission but never grant authority,
override the release reference, or justify execution. Its staleness means a
later server error is unknown; a locally refused call has not been sent.

### Q4: result delivery

Recommend best-effort in-memory delivery with the explicit loss boundary in
finding 4. The Adapter should not durably store unbounded or potentially
sensitive tool content merely to make this notification reliable. The caller
that needs retention owns a distinct durable-content decision after receipt.

## Additional ex_mcp paths

The following are relevant paths besides the public `call_tool/4` header retry.
They must remain either pinned out, declared, or unavailable through this
Adapter's interface.

| Path | Source | Required Adapter treatment |
| --- | --- | --- |
| Generic retry policy can rerun an operation. | `lib/ex_mcp/client.ex:3524-3537, 3701-3710` | Pass `retry_policy: false` per operation. |
| Broken HTTP response stream can reissue the request. | `lib/ex_mcp/client.ex:3578-3639` | Pass `http_stream_retry: :safe_only`; omit `retry_safe`. |
| MRTR can fulfill input and resend `tools/call`. | `lib/ex_mcp/client.ex:3409-3455` | Pass `max_mrtr_rounds: 0`; classify initial input-required result as unknown. |
| Auth provider can resend after either challenge callback returns a token. | `lib/ex_mcp/transport/http.ex:610-655`; `lib/ex_mcp/transport/http/modern_stream_client.ex:425-489` | Use only the fail-closed provider whose challenge callbacks return error, never token. |
| No provider can launch inline OAuth and resend. | `lib/ex_mcp/transport/http.ex:491-510, 679-691, 804-863, 906-918` | Always configure the fail-closed provider; test raw-client negative control separately. |
| Reconnect establishes a new session; idle health check sends ping. | `lib/ex_mcp/client.ex:3060-3169` | Pin `reconnect: false`, `health_check_interval: nil`; test no post-connect reconnect/ping. |
| Legacy SSE opens or reconnects a long-lived GET stream. | `lib/ex_mcp/transport/http.ex:1426-1430, 1910-1975`; `lib/ex_mcp/client/connection_manager.ex:1274-1279` | Pin `use_sse: false`; test request-owned POST stream behavior separately. |
| Connection negotiation sends discovery, initialize, and initialized notification; fallback may try more negotiation exchanges. | `lib/ex_mcp/client/era_probe.ex:97-113`; `lib/ex_mcp/client/connection_manager.ex:1015-1052, 1255-1271` | Declare these as `connect/2` protocol traffic and bound/test them for each permitted protocol mode. |
| Server roots, sampling, elicitation, and custom requests can invoke a configured handler; default handler roots expose the current directory. | `lib/ex_mcp/client/default_handler.ex:34-53, 132-139`; `lib/ex_mcp/client/request_handler.ex:1433-1605, 1685-1729` | Supply no handler and empty capabilities, or a rejecting handler; assert no data-bearing response. |
| Server ping is acknowledged with empty success even without a handler. | `lib/ex_mcp/client/request_handler.ex:1457-1475, 2027-2057` | Declare and test empty acknowledgement; it is not a refusal and discloses no host data. |
| Explicit public APIs can create subscriptions, batch requests, resource reads, prompts, or execute other methods. | `lib/ex_mcp/client.ex:447-488, 512-696, 917-930`; `lib/ex_mcp/client/request_handler.ex:121-152` | Do not expose or call these APIs. No automatic path reaches them under the fixed interface. |

No automatic ex_mcp path found executes a server tool absent a client `tools/call`.
The principal host-data risk is a configured/default client handler; the
no-handler/empty-capabilities construction avoids it apart from the empty ping
acknowledgement.

## Required live Contract amendment

Post and decide this exact amendment before implementation; it resolves the
discovery contradiction and makes wire-error outcomes conservative.

Before:

> Discovery never authorizes execution. A tool call is sent at most once per
> dispatch identity, and a second dispatch of the same identity without a
> reconciliation decision is refused by the intent boundary; a timeout or broken
> stream after sending is `unknown`, never `refused`; server-initiated requests
> (sampling, elicitation, roots, custom methods) are refused and disclose no
> path, model or credential.

After:

> Discovery never authorizes execution. The caller-supplied bounded discovery
> snapshot may only narrow admission: absence of the named tool or failure
> against its snapshot schema is a local, pre-send refusal and does not claim
> the server's current tool set or schema. A tool call is sent at most once per
> dispatch identity, and a second dispatch of the same identity without a
> reconciliation decision is refused by the intent boundary; any timeout,
> broken stream, or JSON-RPC error after sending is `unknown`, never `refused`.
> Server-initiated sampling, elicitation, roots, and custom methods are refused
> and disclose no path, model, or credential; protocol ping is acknowledged
> with an empty result only.

Also change the output list by removing server-origin
`invalid_arguments`, `invalid_request`, and `protocol_error` from `refused`,
and describe them as bounded reasons within `unknown{server_error}`. If the
existing 401/403 `refused{authentication_failed}` row remains, add its named
HTTP authentication-rejection upstream assumption and retain its
non-attested/dispatched mapping.

## Verdict

**Proceed after fixes.** The selected MCP-client-first scope, release-reference
gate, fixed client settings, loopback evidence plan, and operational framing are
sound. Resolve the JSON-RPC outcome overclaim and amend the discovery/server-
request Contract wording before code begins.
