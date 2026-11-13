# Provenance of the ELZ-143 fixtures

Recorded 2026-11-13. These files are Monitored observations of one model on one day through one
intermediary. They are not a proof and not the provider's Contract.

## How each stream was recorded

- Endpoint: OpenRouter's Anthropic-compatible Messages endpoint, `POST https://openrouter.ai/api/v1/messages`,
  routed to Anthropic. Nothing here was recorded from Anthropic's own endpoint.
- Model: the request names `claude-haiku-5-5`. The stream says `"model": "anthropic/claude-haiku-5.5"`.
- Provider pin: the request member `"provider": {"only": ["anthropic"], "allow_fallbacks": false}`.
  `message_start.message.provider` is `"Anthropic"`.
- Authentication: `Authorization: Bearer`. No request header and no credential is stored in any file.
- Other request headers sent: `anthropic-version: 2026-10-21`, `Accept: text/event-stream`,
  `Accept-Encoding: identity`, `Content-Type: application/json`, a neutral `User-Agent`. No beta header.
- Response: status 200, `Content-Type: text/event-stream`, chunked.

## Files

- `text.ai-text.json`, `tool.ai-text.json`: the ai-text request (schema `elzoo/ai-text-request` version 1).
  All prompt text is invented.
- `text.upstream.json`, `tool.upstream.json`: the request body exactly as sent. It was written by hand from
  the translation rules of the task body, because the Piece does not exist yet, with the `provider` member
  added as the first member.
- `text.sse`, `tool.sse`: the response body exactly as received, after HTTP chunk decoding, not edited.
- `text.message.json`, `tool.message.json`: the second form of the same response. It is the Message object
  that Anthropic's official TypeScript SDK (`@anthropic-ai/sdk` 1.8.0, `messages.stream(...).finalMessage()`)
  built from the recorded bytes, replayed to it afterwards from the loopback interface in pieces of 97 bytes.
  It was not built during the live call, and it is not a second answer of the provider. The SDK added the
  member `parsed_output`.
- `not-a-pair/`: one separate call with `stream: false` for each request, same day and same pin. The text,
  the tool-use id and the arguments differ from the streamed answer. It shows why two calls cannot make a
  pair. No test uses it.

## What the streams hold

- Anthropic's event types in Anthropic's order: `message_start`, `content_block_start`,
  `content_block_delta`, `content_block_stop`, `message_delta`, `message_stop`. No comment line, no `ping`
  and no `error` event occurred. OpenRouter documents that it can send comment lines such as
  `: OPENROUTER PROCESSING`.
- `text.sse`: one text block, 25 text deltas that are not empty, `stop_reason` `end_turn`.
- `tool.sse`: a text block with 4 deltas, then one `tool_use` block with 9 `input_json_delta` events that are
  not empty (no empty first delta), `stop_reason` `tool_use`.
- Members that Anthropic's streaming examples do not show: `container`, `stop_details` and `provider` in the
  message; `citations` in a text block; `caller` in a `tool_use` block; `container`, `stop_details` in the
  delta of `message_delta` and `context_management` beside it; `inference_geo`, `server_tool_use`,
  `service_tier`, `speed`, `cost`, `is_byok` and `cost_details` in `usage`. `cost` is a JSON number with a
  fraction. `provider`, `cost`, `is_byok` and `cost_details` are OpenRouter's. Anthropic's reference for the
  Message object names `container`, `stop_details`, `citations`, `inference_geo`, `server_tool_use`,
  `service_tier` and `speed`; whether Anthropic's own stream carries each of them was not recorded.

## Deliberate differences from a direct Anthropic call by the Piece

1. The endpoint and the authentication header.
2. The added `provider` member in the request body.
3. Whether OpenRouter passes `anthropic-version` on to Anthropic is not known.
4. The `model` text in the stream is OpenRouter's id, and the OpenRouter members listed above are present.
5. The `request-id` response header was OpenRouter's generation id. Response headers are not stored.

## Not recorded

A direct call to Anthropic. Another model. A provider error in the middle of a stream. A cut stream.
A slow or closed consumer. A stream with a comment line or a `ping`. Two tool calls in one answer.
A stop for `max_tokens` inside a tool call.
