# Provenance of the ELZ-156 fixtures

Recorded 2026-11-13. These files are a Monitored observation of one model on one day, from one call to
Anthropic's own endpoint. They are not a proof and not the provider's Contract.

## How the stream was recorded

- Endpoint: Anthropic's own Messages endpoint, `POST https://api.anthropic.com/v1/messages`, with no
  intermediary. One call on 2026-11-13 at 15:38:29 UTC, made with curl 8.18.0. The response came over
  HTTP/2.
- Model: the request names `claude-haiku-5-5`. The stream says `"model":"claude-haiku-5-5"`.
- Authentication: the key in `x-api-key`. No request header, no response header and no credential is stored
  in any file.
- Other request headers sent: `anthropic-version: 2026-10-21`, `content-type: application/json`,
  `accept: text/event-stream`, `accept-encoding: identity`, a neutral `user-agent`. No beta header.
- Response: status 200, `content-type: text/event-stream; charset=utf-8`.

## Files

- `text.upstream.json`: the request body exactly as sent: model `claude-haiku-5-5`, `max_tokens` 64,
  thinking disabled, `stream` true. The prompt text is invented. The Piece did not build this body: its user
  message holds the prompt as a string, and the Piece writes a list with one text block. The file has no
  final newline.
- `text.sse`: the response body exactly as received, not edited.

There is no ai-text request file and no second form of the response. The test group `direct_recording`
writes its own ai-text request with the model, the token limit and the prompt of `text.upstream.json`. It
does not compare the POST body of the Piece with that file.

## What the stream holds

- Eight events in this order: `message_start`, `content_block_start`, `ping`, two `content_block_delta`,
  `content_block_stop`, `message_delta`, `message_stop`. No comment line and no `error` event occurred.
- One text block with two text deltas that are not empty, `stop_reason` `end_turn`. `output_tokens` is 3 in
  `message_start` and 13 in `message_delta`.
- Members in the message: `container`, `stop_details` and `diagnostics`, each `null`. In its `usage`:
  `cache_creation` with both lifetimes 0, `service_tier`, `inference_geo` and `speed`. In the delta of
  `message_delta`: `container` and `stop_details`. In the `usage` of `message_delta`: `input_tokens`, the
  two cache totals, `output_tokens` and `output_tokens_details` with `thinking_tokens` 0.
- Not in this stream, but in the streams recorded through OpenRouter on the same day
  (`../openrouter-anthropic-stream/`): `citations`, `context_management` and `server_tool_use`.
- Form: six `data:` lines have spaces before the last brace. The data of `ping` has a space after the
  colon.

## Differences from a call by the Piece

1. The request body, as said under `text.upstream.json`.
2. The live response came over HTTP/2. The transport of the Piece is HTTP/1, and the test replays the bytes
   over HTTP/1.1 from the loopback interface.
3. Response headers are not stored. In the test, the loopback peer sends its own: `content-type:
   text/event-stream` with no `charset`, and its own `request-id`.

## Not recorded

Another model. A second call. A tool call. Thinking. An `error` event. A cut stream. HTTP/1.1 on the live
endpoint, which is the transport of the Piece.
