# Provenance of the ELZ-155 fixture

Recorded 2026-11-13. These files are a Monitored observation of one model in one call to the provider's own
endpoint. They are not a proof and not the provider's Contract.

## How the stream was recorded

- One call on 2026-11-13 at 15:38:29 UTC: `POST https://api.anthropic.com/v1/messages`, made with curl 8.18.0.
  The response came over HTTP/2.
- Request headers: `anthropic-version: 2026-10-21`, `content-type: application/json`,
  `accept: text/event-stream`, `accept-encoding: identity`, a neutral `user-agent`, and the key in `x-api-key`.
  No beta header.
- Request body: model `claude-haiku-5-5`, `max_tokens` 64, thinking disabled, `stream` true. The prompt text
  is invented.
- Response: status 200, `content-type: text/event-stream; charset=utf-8`.
- No response header and no credential is stored in any file.

## Files

- `text.upstream.json`: the request body exactly as sent (177 bytes, SHA-256
  `64326ee9e0285b49974b48e8d8e415de25487b5f81ba4c433f401d64d1ff3f11`). It has no final line feed. The owner
  test shows that the Piece sends the same bytes for the same request.
- `text.sse`: the response body exactly as received, not edited (1,408 bytes, SHA-256
  `2d76b71a857ec16d5fec8bdbc4e90998c7e85fda3544b98fb32ae314a999362a`).

## What the stream holds

- Eight events in this order: `message_start`, `content_block_start`, `ping`, `content_block_delta` (two),
  `content_block_stop`, `message_delta`, `message_stop`. One text block. `stop_reason` is `end_turn`.
  `output_tokens` is 3 in `message_start` and 13 in `message_delta`.
- Members in the message: `container`, `stop_details` and `diagnostics`, each `null`. In its `usage`:
  `cache_creation` with both lifetimes 0, `service_tier`, `inference_geo` and `speed`. In the delta of
  `message_delta`: `container` and `stop_details`. In the `usage` of `message_delta`: `input_tokens`, the two
  cache totals, `output_tokens` and `output_tokens_details` with `thinking_tokens` 0.
- Not in this stream, but in the streams recorded through OpenRouter on the same day (fixtures of
  delivery/provider-stream): `citations`, `context_management` and `server_tool_use`.
- Form: six `data:` lines have spaces before the last brace. The data of `ping` has a space after the colon.
  There is no comment line.

## Differences from a call by the Piece

1. curl made the call, not the Piece.
2. The response came over HTTP/2. The transport of the Piece is HTTP/1.1 only. The tests replay the recorded
   bytes from the loopback interface over HTTP/1.1.

## Not recorded

Another model. A second call. A tool call. Thinking. An `error` event. A cut stream. HTTP/1.1 on the live
endpoint (the transport of the Piece). An event type that the Piece does not read. A number with a fraction.
