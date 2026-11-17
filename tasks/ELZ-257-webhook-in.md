# ELZ-257 — Signed first-party webhook ingress

- Phase: Level 3 prerequisite
- Dependencies: ELZ-083, ELZ-115, ELZ-127, ELZ-252
- Output: new `integration/webhook-in` Piece
- Owned paths: `pieces/integration/webhook-in/**` and its own catalogue/release-plan rows and generated views only. Do not edit root/shared code, another Piece, `mix.exs`, `mix.lock`, CI or a server/listener.

## Outcome and reuse boundary

Implement one first-party, server-to-server, plain-text source profile. Export `Elzoo.WebhookIn.init/1` and `call/2` as a Plug. Reuse the existing pinned Plug 1.20.3, Jason 1.4.5, Plug.Crypto 2.2.1 closure and OTP `:crypto`; declare the Piece provider closure without adding or changing a pin. The merged ELZ-083 and ELZ-115 manifests declare the existing Plug/Plug.Crypto/Jason provider closure and direct Jason use; do not create a new provider abstraction.

These providers do not own this application profile: Plug supplies connection/header/raw-body primitives, Jason parses JSON (including ordered objects), Plug.Crypto supplies constant-time comparison, and OTP's `:crypto.mac(:hmac, :sha256, key, data)` supplies HMAC. None defines this source's signed byte framing, freshness, duplicate-header policy, schema, authenticated grants, admission semantics or safe HTTP refusals. Implement only that narrow policy; no generic wrapper, webhook registry, OAuth/provider identity, browser secret, body-parser middleware, polling broker, listener/TLS server or other channel.

## Configuration and Needs

The `init/1` keyword list accepts exactly one each of `source_id`, `key`, `clock`, `principal` and `admit`; no missing, duplicate or extra options. Their values are respectively a `source_id` of 1..128 ASCII bytes from `[A-Za-z0-9._-]`, a zero-arity key function, a zero-arity clock function, an arity-1 principal function and an arity-2 admission function. Malformed static configuration raises `ArgumentError` with a fixed bounded message that includes no option data.

The key function returns `{:ok, secret}` where `secret` is a binary of 32..128 bytes, or `{:error, :unavailable}`. An unavailable, malformed or raising key Need returns 503 before principal/admission. The clock function returns Unix seconds as an integer in `0..9_223_372_036_854_775_807`; unavailable, malformed or raising clock Need also returns 503 before principal/admission. Sample the clock for the request's timestamp check.

The principal function receives the Plug connection and returns exactly `{:ok, %{tenant: tenant, actor: actor, resources: resources}}`, `{:error, :forbidden}` or `{:error, :unavailable}`. A malformed or raising result returns 503; `:forbidden` returns 403 and `:unavailable` returns 503, always before admission. Validate trusted scope fields with the existing CheckedCommand scope rules. The authenticated `conversation_id` must be in `resources`; a missing resource grant returns 403 without admission. Scope tests cover malformed trusted context or a missing grant, not an arbitrary different valid host-vouched actor. Only authenticated host context supplies the scope; request fields and the source MAC do not authenticate a human actor.

`admit` has arity two and its fixed Need closure captures the configured `source_id`: call it as `admit.(event, scope)`, without adding `source_id` to the event or a third argument. The host supplies listener/TLS, request lifecycle, key storage/rotation, a fresh clock and authenticated principal/read grants. No default key or principal. Key rotation is host provisioning; Needs must be prompt and bounded.

## Signed request Contract

Accept only `POST /elzoo/v1/messages` with no query, exactly one `application/json` content-type value, and no `content-encoding`. Use `Plug.Conn.get_req_header/2` to reject duplicate/coalesced security and content headers. `Content-Length` is optional; when present it must be exactly one canonical unsigned decimal value no greater than 65,536. Duplicate/coalesced or malformed values return 400; a declared length over 65,536 returns 413. Require an unread raw body; reject parsed/unavailable bodies.

Read with `Plug.Conn.read_body/2` using `length: 8192` and `read_length: 8192` on each call. Start a 15,000 ms monotonic admission/read budget immediately before the first read. Check it before and after each returned Plug read, and set the next call's `read_timeout` to no more than `min(5,000 ms, remaining budget)`. Check again before calling principal/admission; if expiry has been observed, return 408 where a response remains possible and do not invoke admission. This budget does not interrupt a blocked upstream read or promise an absolute 15-second response. The host listener/request lifecycle MUST enforce total request lifetime and terminate blocked/trickling requests; that is a host Need, not a guarantee delivered by this Plug. If the host terminates a request, this Plug makes no response guarantee. Do not add a Task/timer/process-kill wrapper. Continue `:more` while cumulative bytes fit; return 413 when a chunk crosses 65,536 bytes. A `:more` with no body progress returns 408 rather than looping. A returned read timeout or observed budget expiry returns 408; other body-read errors return 400. Plug's per-call `length` is not a total cap and may read somewhat beyond it, so enforce the cumulative cap on returned bytes. These are finite budgets for this adapter, not service-wide latency or transfer guarantees. Never log body, key or provider exception text.

Require exactly one `x-elzoo-timestamp`: canonical unsigned decimal Unix seconds, at most 19 digits and no greater than 9,223,372,036,854,775,807. Require exactly one `x-elzoo-signature`: `v1=` plus exactly 64 lowercase hex digits. Reject duplicate, coalesced and malformed values. Timestamp must be within +/-300 seconds inclusive of the clock Need.

Authenticate the exact raw body before JSON parsing or either principal/admission Need. HMAC-SHA256 input is exactly:

```text
elzoo-webhook-v1\n{source_id}\nPOST\n/elzoo/v1/messages\n{timestamp-header-bytes}\n{raw-body}
```

Each displayed `\n` denotes exactly one LF byte (`0x0A`); the final LF separates the timestamp bytes from the raw body, and no LF is appended after the body.

The configured source ID is the only source identity. Decode the 32-byte signature and compare with `Plug.Crypto.secure_compare/2`. No algorithm choice, key ID, tenant, actor, Run, policy or authority field comes from the request.

Decode only after MAC verification with `Jason.decode(..., objects: :ordered_objects)`, recursively reject duplicate keys, then require exactly one flat object with fields `version` (=1), `event_id`, `conversation_id`, `input_id`, `expected_revision` and `text`. Reject unknown/duplicate keys, nested values, floats and extra/control fields; no tenant, actor, Run, policy or authority field is accepted. IDs are 1..128 ASCII bytes from `[A-Za-z0-9._-]`; this ingress profile is intentionally stricter than Conversation's valid UTF-8 IDs. `expected_revision` is an integer 0..9,223,372,036,854,775,806. `text` is nonempty valid UTF-8, at most 4,096 bytes, and contains no NUL; preserve it byte-for-byte, including ordinary LF and TAB. Preserve the signed expected revision on retries; timestamp/MAC are transport data, not immutable command facts.

## Admission and response

After all transport, MAC, JSON and trusted-scope checks, call `admit.(event, scope)` exactly once per HTTP request. `event` contains only the six normalized fields above; the fixed admission Need captures `source_id`, never obtains it from request data. Accept only:

- `{:committed, revision}` — actual durable commit confirmation; `revision` must be an integer exactly equal to `event.expected_revision + 1` and within `1..9_223_372_036_854_775_807`.
- `{:pending, :approval}` — retained approval request, with no input mutation.
- `{:rejected, :forbidden | :conflict | :invalid}`, `:unknown`, or `{:error, :unavailable}`.

Shape-check returns and sanitize failures. A mismatched/malformed committed revision, callback exception or malformed return after entry is `unknown`, never safe rejection; return 503 and do not retry or invoke the callback again within that request. Unknown must be resolved by the host under original-identity fencing before another append. The adapter never generates replacement IDs. A resubmission is a new request: pass the original event IDs and expected revision unchanged, invoke admission once for that request, and leave duplicate/idempotency resolution to the host Need.

Return bounded JSON. Before MAC and full JSON/schema validation establish a valid authenticated event, include status only; never parse early to obtain `event_id`. Once that event exists, include its `event_id` and status; include revision only for a valid committed result. Map committed to 202, approval pending to 202 (not an accepted input/Run), forbidden to 403, conflict to 409, invalid to 400, and unknown/unavailable to 503. Wrong route 404; wrong method 405; encoding/media 415; malformed header/body/JSON 400; failed MAC/freshness 401; body overflow 413; body-read timeout/no-progress/deadline 408; key/clock/principal unavailable or malformed 503. Halt every sent response. ACK is not a claim that a Run started or completed. Do not expose exception text, credentials, policy internals or payload.

## Acceptance and evidence

Test exact init-option keys/value arities and bounded `ArgumentError` for missing, duplicate, extra or malformed static config. Test key/clock unavailable, malformed and exception paths and malformed/exception principal results; none may reach admission. Test actual Plug.Conn body/header behavior; an independently computed known HMAC vector; LF/body-byte, method/path/timestamp framing; inclusive freshness edges; optional Content-Length absent/at/over the cap and duplicate/coalesced/malformed values; duplicate/coalesced security headers; overlong timestamp/signature; `length`/`read_length` 8192, read-timeout cap, and a controlled delayed/trickling adapter that returns across the 15,000 ms admission/read budget; assert refusal before principal/admission and do not claim this proves interruption of a blocked read. Also test no-progress, returned timeout, other read error and cumulative overflow; already-consumed body; duplicate JSON keys at every depth; exact/over-limit fields, control fields, LF/TAB text and NUL; missing resource grant; and every admission response including committed-revision mismatch as unknown. Do not test refusal of an arbitrary different valid host-vouched actor.

Assert early failures contain no `event_id`, while every response after a valid authenticated event includes it. On success and resubmission, assert caller-supplied IDs and expected revision are unchanged, admission is invoked once per request and the adapter allocates no IDs; a duplicate committed response is host-Need idempotency, not adapter state. A callback exception after simulated commit returns unknown after exactly one invocation, with no internal retry or replacement ID. Assert no principal/admission call before authentication and no admission call before all scope checks. Assert response status/body bounds and that every response is halted. Need fixtures do not establish durable commit/authentication guarantees.

Negative controls that remove MAC/body binding and cumulative-size enforcement must each fail at their intended assertion and be restored byte-for-byte. State provider and host assumptions honestly; claim only the finite listed observations. Run Piece tests and the new-Piece small gate, including generated export and copied consumer with declared providers; require one independent review, exact-head hosted checks and the merge queue.
