# delivery/request-reply

`Elzoo.RequestReply` is a pure, stateless boundary over `core/envelope` maps.
It depends only on that Piece and the pinned Cure provider. Decisions execute
in `Cure.Elzoo.RequestReply`; Elixir translates maps to the existing erased
EnvelopeMessage, DeliveryResult and ReplyEndpoint tuples. No new record tags.

## Contract and API

- `reply_endpoint(request)` returns `{:ok, %{"unit_id" => text, "port_id" => text}}`
  or `{:error, {:request, reason}}` / `{:error, {:correlation, :missing_reply_to}}`.
- `expected_correlation(request)` returns `{:ok, text}` after request validation:
  the request correlation ID when present, otherwise its message ID.
- `correlate(request, result)` returns `{:ok, result}` unchanged. Errors are
  `{:error, {phase, reason}}`: request decoding, result decoding, then
  `:correlation` checks in order: `:message_mismatch`, `:correlation_mismatch`,
  `:attempt_mismatch`, `:deadline_mismatch`. Message ID must equal the request
  ID; attempt and deadline use exact Option equality (absence differs from presence).
- `accept_reply(request, reply, arrival_endpoint)` returns the unchanged payload
  result after checking: request; exact nonempty UTF-8 named endpoint shape
  (`{:arrival, :invalid_shape}`); reply Envelope decoding (`:reply` phase);
  then `:reply` checks `:invalid_reply_kind` (reply or error),
  `:invalid_reply_schema` (elzoo/delivery-result v1), `:missing_reply_to` or
  `:endpoint_mismatch`, required reply correlation (`:correlation_mismatch`),
  optional causation equal to request ID (`:causation_mismatch`); finally payload
  through `correlate/2`. Kind need not agree with outcome. Endpoint is never a pid.

Envelope decode reasons are inherited unchanged, tagged by phase. Errors never
echo payload or metadata values; declaration identifiers and indices may appear
in errors for other ELZ-007 Pieces, but request-reply uses only fixed atoms.
Deadlines are echoed data, never evaluated. Every valid
outcome passes unchanged, including all timed_out dispatch variants and unknown;
unknown never means no effect. There is no classification, scheduling, dispatch,
clock read, ID generation, table, process, I/O or duplicate/completed tracking.
Repeating an identical result succeeds again. Multi-attempt tracking belongs to
ELZ-006/008 policy; no durability or exactly-once guarantee is made.

Telemetry, Config and Control are not_applicable: no lifecycle or observations,
and intrinsic message data is not configuration. The caller owns instrumentation,
truthful identities/observations, payload validation and runtime effects.

## Grounding and copying

Pinned Cure compilation is type evidence; the bundled tests cover named finite
scenarios and source audits, not a quantified proof. Shared examples are reused
from core/envelope. `test/export_test.exs` exercises copied sources in a fresh
consumer without Elzoo.Application or a runtime Cure compiler. Select this Piece
through `mix elzoo.take`; its dependency and compiler tooling are copied too.
