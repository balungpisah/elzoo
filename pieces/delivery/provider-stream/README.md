# delivery/provider-stream

The partial output of one Anthropic Messages call, partial tool-call arguments
included, offered to one local sink one acknowledged frame at a time, with one
result assembled inside a declared byte bound. Namespace `Elzoo.ProviderStream`.
The complete Contract is [ELZ-143](https://github.com/balungpisah/elzoo/issues/307).
Ready `delivery/data-stream` stays text-only, with its ID and Contract unchanged.

## Use

```elixir
Elzoo.ProviderStream.run(payload, sink, settings)
```

`run/3` makes at most one POST and returns when the call has ended. It blocks
the calling process. The HTTP exchange and each sink call run in workers linked
to that process; both are dead before it returns.

**Settings**, a keyword list; an unknown, missing or duplicate key, or a sink
that is not a function of one argument, gives `{:error, :configuration}` and
sends nothing:

| Key | Meaning |
| --- | --- |
| `credentials` | required; a zero-arity function returning `{:ok, key}`, 1..1,024 printable ASCII bytes, sent only as `x-api-key` |
| `models` | required; 1..16 distinct model texts the host allows; each must accept `thinking: disabled` |
| `max_result_bytes` | required, 1..1,048,576, no default |
| `total_timeout_ms` | 1..300,000, default 60,000: the whole call |
| `receive_timeout_ms` | 1..min(30,000, total), default 5,000: socket inactivity |
| `ack_timeout_ms` | 1..min(10,000, total), default 1,000: one sink answer |

These are construction settings of one call; there is no hot update. The
endpoint is fixed (`https://api.anthropic.com/v1/messages`, HTTP/1, no retry,
no redirect) through the reused `Transport` of `delivery/data-stream`. A
private four-argument entry adds a loopback origin for tests only.

**Request.** `payload` is the bytes of one `elzoo/ai-text-request` version 1,
decoded with `Elzoo.AiText.Request.decode/1`. Refused before the credential is
read: the decoder's `:invalid_request`, `:too_large` and `:unsupported_feature`;
`:unsupported_feature` for an output schema, sampling, a reasoning level other
than none, a cache hint, stop sequences, provider options, or a system message
after a message of another role; `:invalid_request` for a model outside
`models` and for an assistant message with empty text and no tool call. The
POST body carries `model`, `max_tokens`, `stream: true`,
`thinking: {"type": "disabled"}`, `system` text blocks, `messages` (a run of
tool results becomes one user message of `tool_result` blocks) and, with tools,
`tools` and `tool_choice`.

**Sink.** `sink` is called with one `%Elzoo.ProviderStream.Frame{callback_ref,
seq, chunk}` at a time and returns `{:ack, frame.callback_ref, frame.seq}`,
`{:cancel, :caller_cancelled}` or `{:error, :disconnected}`. Each other return
or an exception is `:sink_failed`. `seq` starts at 0 and advances on offer.
`chunk` is `%{seq, kind, payload}`:

- `:text_delta`, payload a text, and `:tool_delta`, payload `%{index, delta}`
  with a delta that is not empty: valid `Elzoo.AiModel.StreamChunk` values.
- `:tool_start`, payload `%{index, id, name}`: a shape this Piece owns,
  checked by `Elzoo.ProviderStream.Chunk.validate/1`. `StreamChunk` is unchanged
  and does not accept it. The start of a call is acknowledged before its first
  delta is offered.

A frame is partial output and data only. A tool call is usable only from a
complete result.

## Result

```elixir
{:complete, %{content: text, tool_calls: [%{id: id, name: name, arguments_json: json}],
              finish: finish, usage: usage, provenance: provenance}}
{:incomplete, reason}
{:refused, reason}
```

`:complete` needs a valid `message_stop`, an HTTP worker that ended normally
with it, and an acknowledgement of each frame. `arguments_json` is the deltas
joined, or `{}` when there were none, and decodes to a JSON object. `finish`
is the mapping of `Elzoo.AiText.Anthropic`. `usage` is an `Elzoo.AiModel.Usage`
(`input_includes_cached: false`, `:provider_reported`; the last report naming a
counter counts, an unnamed counter is `:unknown`). `provenance` is an
`Elzoo.AiModel.Provenance` with `provider_piece: "delivery/provider-stream"`.

The byte bound: the bytes of `content` plus the `id`, `name` and
`arguments_json` of each call stay at most `max_result_bytes`. It is checked
when a delta is accepted, before its frame is offered. A delta that would pass
it is not offered: the HTTP worker is killed and the result is
`{:incomplete, :result_limit}`. The Piece refuses to hold the result; the
provider did the work.

`:incomplete` means sent or possibly sent: output partial, charges unknown, no
tool call. Reasons: `:missing_completion`, `:transport`, `:timeout`,
`:provider_timeout`, `:provider_error`, `:stream_error`, `:malformed_response`,
`:unsupported_response`, `:receive_limit`, `:block_limit`, `:event_limit`,
`:result_limit`, `:sink_timeout`, `:sink_failed`, `:caller_cancelled`,
`:disconnected`, `:adapter_error`. `:refused` means not sent (the request
reasons, `:credentials_unavailable`) or answered with one of nine statuses
(400, 401, 402, 403, 404, 409, 413, 429, 529). Each reason is a fixed atom.

## Protocol and flow

Each raw block from the reused `Framer` (at most 65,536 bytes, at most 65,536
blocks; total received at most 4,194,304 bytes plus one chunk) holds at most
one event. It is parsed with `ServerSentEvents.Parser.parse/1` and its data
decoded with Jason. The Piece reads only the members of the Contract, checks
their types and ignores each other member, each other event type and comment
blocks: Anthropic's "API versions" page says that values may be added to the
output and new streaming event types may appear. A missing or mistyped member
or an event out of order is `:malformed_response`; another block or delta type
is `:unsupported_response`; an `error` event after status 200 is
`:stream_error`.

At most one frame is unacknowledged. While it is, the HTTP worker waits inside
its body callback: nothing more is read from the socket or decoded. When
`ack_timeout_ms` passes, the workers are killed, the local HTTP request closes
and the result is `{:incomplete, :sink_timeout}`. A sink that cancels,
disconnects or fails closes the request the same way, and so does the end of
`total_timeout_ms`. No remote cancellation is claimed: provider work and
charges after the close are unknown.

## Needs

The caller holds the `delivery/effect-intent` custody of the call; `run/3` is
the one send of one admitted attempt. This Piece keeps no intent, call or
outcome record and cannot stop a caller that calls it twice; for that caller an
`:incomplete` result is an unknown outcome with no automatic retry. Other
Needs: a workspace API key from the injected `credentials`, TLS and network
egress, a host-chosen model that accepts `thinking: disabled`, and a trusted
sink. The host keeps the result and the usage.

Direct Pieces: `delivery/data-stream` (its private `Framer` and
`Transport.request/5`, `headers/2`, `endpoint/1`, unchanged),
`integration/ai-text` (`Request.decode/1`), `integration/ai-model`. Direct
providers: Req 0.7.5, Jason, server_sent_events 1.1.0, Elixir, OTP.

## Evidence

- Test: `test/elzoo/provider_stream_test.exs`, the seven groups `text_only`,
  `tool_call_split`, `cut_in_tool_call`, `slow_consumer`, `result_over_bound`,
  `provider_error_mid_stream` and `equals_non_stream`, plus a table of protocol
  order and type rules. Finite loopback scenarios over real HTTP/1.1 on the
  recorded files and on bytes the test cuts or adds. The `error` event is
  hand-built in the documented format and labelled so.
- Monitored: the two recorded streams in `test/fixtures/openrouter-anthropic/`
  were recorded on 2026-11-13 through OpenRouter's Anthropic-compatible
  endpoint, routed to Anthropic, for the model `claude-haiku-5-5`. They are
  observations of one model on one day, not a proof and not the provider's
  Contract. `PROVENANCE.md` there lists how the route was pinned, the members
  that Anthropic's streaming examples do not show, and each difference from a
  direct call. The `.message.json` files are the Message that Anthropic's
  TypeScript SDK built afterwards from those same bytes, not a second
  observation. `not-a-pair/` holds separate calls; no test uses it.
- Upstream: Req 0.7.5 through the reused `Transport`; server_sent_events 1.1.0
  on each raw block; Anthropic's
  [Streaming messages](https://platform.claude.com/docs/en/build-with-claude/streaming),
  [Claude API errors](https://platform.claude.com/docs/en/api/errors) and
  [API versions](https://platform.claude.com/docs/en/api/versioning) pages,
  read 2026-11-13.
- Cure law: none; tests only.

## Telemetry, Config, Control

Telemetry is planned: no Elzoo event. Req and Finch emit their own upstream
telemetry, including transport request metadata; a host that installs handlers
must redact it. Config is the settings above, for the construction of one call.
Control is the sink's return: cancel or disconnect closes the local request.

## Limits

One provider and one wire surface. The fixtures came through OpenRouter, so no
test shows a stream from Anthropic's own endpoint. No thinking blocks,
structured output, cache hint, stop sequences or server tools. No claim about
memory beyond the retained raw block, the current receive chunk and the
assembled result. Tool arguments are not checked against the tool's schema;
`integration/ai-text` owns that check. No remote cancellation, retry, replay,
delivery durability or billing claim. Reading stops at `message_stop`, as in
`delivery/data-stream`: bytes after it in the same receive chunk are not read,
so they do not change a `:complete` result.
