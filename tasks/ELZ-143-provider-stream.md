# ELZ-143 — Provider stream with tool calls (Anthropic first)

## Scope and reuse

- Dependencies: ELZ-033, ELZ-101, ELZ-079
- Output: `delivery/provider-stream` (new Piece ID); release V1B; bot-platform level 1.
- Owned paths: `pieces/delivery/provider-stream/**` and its index/generated changes under AGENTS.md section 3.

Stream the partial output of one Anthropic model call, partial tool-call arguments included, to one local sink: one acknowledged frame at a time, no decoded backlog, a local close when the sink stops, and one assembled result inside a byte bound. Ready `delivery/data-stream` stays text-only, with its ID and Contract unchanged.

Implement only the acceptance groups below. Add no options, layers, behaviours, generic helpers or future hooks: no second provider, no provider interface, no owner process, capacity table, retention, lookup or status call, no retry or reconnect, no thinking, no server tools. Change no ready Piece, shared path, dependency, pin or CI file. The worker has no provider credential, and no test calls a host other than its own loopback peer. The independent reviewer flags extra features for removal.

## Stream fit (decided at admission)

This Piece reads the provider's event stream itself, as `delivery/data-stream` does. It does not use the streaming of pinned `req_llm` 1.30.0. That source, read at the pin, cannot keep the bounds:

- No acknowledgement. A consumer pulls with `StreamServer.next/2`. Each transport read is decoded whole, and every chunk from it is queued before the consumer sees one (`streaming/decoder.ex`; `stream_server.ex`, `process_data_chunk`).
- A decoded backlog. The queue holds up to `high_watermark` chunks (default 500, least 1), and one read can pass that mark by all the chunks of the read (module documentation of `StreamServer`). The server also keeps the whole message in `message_acc`, with no byte bound.
- No cap for one raw block and none for the body. A parse error is logged with its reason and skipped. At the end of the body a blank line is added and the rest is parsed (`streaming/sse.ex`, `flush/1`), and the end of the body counts as completion.
- The Anthropic decoder has no clause for the `error` event and gives no chunk for it (`providers/anthropic/response.ex`). By default a request is tried again up to 3 times before the first body byte.
- The local close holds: `StreamServer.cancel/1` kills the HTTP task. It is the only one of the bounds that holds.

Reuse by dependency, unchanged, the modules of `delivery/data-stream` that do not know the kind of content: `Framer` (raw blocks of at most 65,536 bytes, at most 65,536 blocks) and `Transport.request/5`, `headers/2` and `endpoint/1` (fixed endpoint and headers, HTTP/1 pool, status table, the loopback entry for tests). They are private modules of that Piece. The catalogue has a precedent for a call into a `@moduledoc false` module of a dependency: `Elzoo.EffectIntent.Model.key/1` is called from `http_job.ex:122`, `ai_batch.ex:225` and `data_stream/session.ex:94`. Where one does not fit unchanged, write that part here; do not edit `data-stream`. Do not reuse its `Request`, `Session`, `Adapter`, `Binding` and owner, which know only text. Do not reuse its `Protocol`, `Usage` and `JSON` either: they refuse each member outside a fixed list and each number with a fraction, and the recorded streams below carry both.

## Interface

`Elzoo.ProviderStream.run(payload, sink, settings)` makes at most one POST and returns when the call has ended. It blocks the calling process. The HTTP exchange and each sink call run in workers linked to that process, and both are dead before it returns.

**Settings** (a keyword list; an unknown, missing or duplicate key gives `{:error, :configuration}`): `credentials`, `models`, `total_timeout_ms`, `receive_timeout_ms` and `ack_timeout_ms` with the meaning, bounds and defaults of the `delivery/data-stream` README, and `max_result_bytes`, required, 1 to 1,048,576, with no default. A private entry for tests adds a loopback origin through `Transport.endpoint/1`; it is not a setting.

**Request.** `payload` is the bytes of one `elzoo/ai-text-request` version 1, decoded with `Elzoo.AiText.Request.decode/1`; write no second validator. Refused before the credential is read:

- `:invalid_request`, `:too_large` or `:unsupported_feature` from the decoder;
- `:unsupported_feature` for an `output_schema`, `sampling`, a `reasoning` other than none, a `cache_hint`, a `stop_sequences` or `provider_options` member that is not empty, and a system message after the first message of another role;
- `:invalid_request` for a model outside `models`, and for an assistant message with empty text and no tool call.

The POST body is one JSON object: `model`; `max_tokens` (the `max_output_tokens` of the request); `stream: true`; `thinking: {"type": "disabled"}`; `system`, one text block for each system message in order, left out when there is none; `messages`; and, when the request has tools, `tools` (each `name`, `description`, `input_schema`) with `tool_choice` in the shape of the request (`{"type": "auto"}`, and so on). A user message becomes a user message with one text block. An assistant message becomes an assistant message with a text block when its text is not empty, then one `tool_use` block (`id`, `name`, `input`) for each echoed call. A run of tool-result messages becomes one user message with one `tool_result` block each (`tool_use_id`, `content`, and `is_error: true` only when set).

**Sink and frames.** `sink` is a function of one frame, `%Elzoo.ProviderStream.Frame{callback_ref, seq, chunk}`. It returns `{:ack, frame.callback_ref, frame.seq}`, `{:cancel, :caller_cancelled}` or `{:error, :disconnected}`; each other return or an exception is `:sink_failed`. `seq` starts at 0 and advances on offer. `chunk` is `%{seq, kind, payload}`:

- `:text_delta`, payload a text: a valid `Elzoo.AiModel.StreamChunk`.
- `:tool_delta`, payload `%{index, delta}`: a valid `Elzoo.AiModel.StreamChunk`. `delta` is one `partial_json` text that is not empty.
- `:tool_start`, payload `%{index, id, name}`: the shape that this Piece owns. `Elzoo.AiModel.StreamChunk` is unchanged and does not accept it. `Elzoo.ProviderStream.Chunk.validate/1` accepts it and passes each other kind to `Elzoo.AiModel.StreamChunk.validate/1`. `index` is the provider's content block index, 0 to 63, and each delta of that call has the same index. `id` is 1 to 128 bytes of `[A-Za-z0-9_-]`; `name` is 1 to 64 bytes of `[a-zA-Z0-9_-]`.

The `:tool_start` frame of a call is acknowledged before its first delta is offered. A frame is partial output and data only. A tool call is usable only from a complete result.

**Result.**

    {:complete, %{content: text, tool_calls: [%{id: id, name: name, arguments_json: json}],
                  finish: finish, usage: usage, provenance: provenance}}
    {:incomplete, reason}
    {:refused, reason}

- `:complete` needs a valid `message_stop`, an HTTP worker that ended normally with it, and an acknowledgement for each frame. `content` is all text in order. `tool_calls` are in block order. `arguments_json` is the deltas of the call joined, or `{}` when they are empty, and it decodes to a JSON object. `finish` uses the mapping of `Elzoo.AiText.Anthropic` (`anthropic.ex:352-359`) and stays equal to it: `end_turn` and `stop_sequence` are `:stop`, `max_tokens` is `:length`, `tool_use` is `:tool_calls`, `refusal` is `:refusal`; each other value is `{:other, raw}` when `raw` is a text of at most 64 bytes by `Elzoo.AiModel.text?/2`, and `{:other, "unrecognized"}` when it is not. `usage` is an `Elzoo.AiModel.Usage` value from `Usage.from_provider/3` (`input_includes_cached: false`, source `:provider_reported`): input, output and cache read from `input_tokens`, `output_tokens` and `cache_read_input_tokens`, and one `provider_default` cache write from `cache_creation_input_tokens`. For each counter the last report that names it counts; a counter that no report names is `:unknown`. `provenance` is an `Elzoo.AiModel.Provenance` value with exactly its five keys (`provenance.ex:14`): `model_ref`, which is `%{provider: "anthropic", model_id: model, wire_surface: "messages"}` with the model of the request; `provider_model`, the `model` text of the message; `response_id`, the `id` of the message; `request_id`, the value that `Transport.headers/2` returns for the `request-id` header, or `:absent`; and `provider_piece: "delivery/provider-stream"`.
- The byte bound: `byte_size(content)` plus, for each tool call, the bytes of `id`, `name` and `arguments_json`, is at most `max_result_bytes`. It is checked when a delta is accepted and before its frame is offered. A delta that would pass the bound is not offered: the HTTP worker is killed and the result is `{:incomplete, :result_limit}`. This is the explicit refusal of the brief: this Piece refuses to hold or return the result. It is not in the `:refused` class, because the provider did the work.
- `:incomplete` means sent, or possibly sent: the output is partial and the charges are unknown. Reasons: `:missing_completion` (the body ended with no `message_stop`), `:transport`, `:timeout`, `:provider_timeout` (status 504), `:provider_error` (each other status that is not 200 and is not in the refused list below), `:stream_error`, `:malformed_response`, `:unsupported_response`, `:receive_limit`, `:block_limit`, `:event_limit`, `:result_limit`, `:sink_timeout`, `:sink_failed`, `:caller_cancelled`, `:disconnected`, `:adapter_error`. An incomplete call gives no assembled result, so it gives no tool call.
- `:refused` means not sent, or answered with one of nine statuses of the table in `Transport.headers/2`: the three request reasons above, `:credentials_unavailable`, and `:provider_invalid_request` (400), `:authentication_failed` (401), `:billing_error` (402), `:permission_denied` (403), `:not_found` (404), `:conflict` (409), `:provider_too_large` (413), `:throttled` (429), `:overloaded` (529).
- Each reason is a fixed atom. A result holds no provider text.

**Protocol.** Each raw block from `Framer` holds at most one event; parse it with `ServerSentEvents.Parser.parse/1` of pinned `server_sent_events` 1.1.0 (as `data_stream_mutation_test.exs:54` does; list it under the manifest's `providers`) and decode its data with `Jason`. The Piece reads the members below and checks their types. It ignores each other member, each event of another type and each comment block: Anthropic's versioning page says that a version may add values to the output and new event types, and the recorded streams carry members that Anthropic's streaming examples do not show (`PROVENANCE.md` lists them).

- `message_start`: `message.id` (1 to 128 bytes of `[A-Za-z0-9_-]`), `message.model` (a text of 1 to 256 bytes) and, when present, `message.usage`.
- `content_block_start`: `index`, which counts from 0 with no gap and is below 64, and `content_block.type`. For `text`: `text`, which gives a text frame when it is not empty. For `tool_use`: `id`, `name`, and an `input` that is `{}`. Another block type is `:unsupported_response`.
- `content_block_delta`: the `index` of the open block and `delta.type`. `text_delta` with `text` in a text block; `input_json_delta` with `partial_json` in a tool block, which gives a frame when it is not empty. The other of these two kinds in a block is `:malformed_response`; another delta type is `:unsupported_response`.
- `content_block_stop`: the `index` of the open block. At the stop of a tool block the joined arguments decode to a JSON object, or the result is `:malformed_response`.
- `message_delta`: `delta.stop_reason` and, when present, `usage`.
- `message_stop`: valid only after a stop reason and with no open block. Nothing may follow it.
- `ping`: nothing. `error`, after status 200: `:stream_error`.

One block is open at a time. A missing member, a member of the wrong type and an event out of this order are `:malformed_response`.

**Slow consumer.** At most one frame is unacknowledged. While it is, the HTTP callback waits: nothing more is read from the socket and nothing more is decoded. When `ack_timeout_ms` passes, the workers are killed, the local HTTP request is closed and the result is `{:incomplete, :sink_timeout}`. A sink that cancels, disconnects or fails closes the request in the same way, and so does the end of `total_timeout_ms`. This Piece claims no remote cancellation: provider work and charges after the close are unknown.

## Fixtures: supplied by the coordinator, committed unchanged

The coordinator supplies the recorded files. The worker commits them unchanged under `pieces/delivery/provider-stream/test/fixtures/openrouter-anthropic/` and does not write, edit or generate a provider response.

They were recorded on 2026-11-13 through OpenRouter's Anthropic-compatible endpoint, routed to Anthropic, for the model `claude-haiku-5-5`. They were not recorded from Anthropic's own endpoint. `PROVENANCE.md` in that directory says how the provider was pinned, which members show it, each difference from a direct call, and what was not recorded. Read it before you write the README.

For each of `text` and `tool`:

- `<name>.ai-text.json`: the ai-text request, the `payload` of the test.
- `<name>.upstream.json`: the request body as sent. It has one member that this Piece does not send, `provider`, which pinned the route.
- `<name>.sse`: the bytes of the event stream as received. `text` has one text block with 25 deltas. `tool` has a text block, then one tool call whose arguments come in 9 deltas.
- `<name>.message.json`: the same response in its second form, the Message object that Anthropic's official TypeScript SDK built from those recorded bytes.

A pair is one provider response in two forms. Two separate calls cannot make a pair, because the provider gives each response new tool-use ids and the text can differ; `not-a-pair/` holds one such second call for each request, and no test uses it. This replaces the brief's "paired recorded non-stream fixture" (docs/plans/views.md, RC-57 Acceptance): two separate calls cannot agree, so the pair is one recorded response as raw stream bytes and as the Message that the SDK built afterwards from those bytes.

If a recorded stream has an event that the protocol above does not accept, stop and comment on the issue. Do not edit the fixture.

## Acceptance groups

Each group runs against a Piece-local loopback peer over real HTTP. No production hook is added for a test.

1. **`text_only`**: `text.sse` gives text frames in order, each acknowledged before the next is offered, then `:complete` with no tool call. The peer gets one POST whose body, as decoded JSON, equals `text.upstream.json` without its `provider` member. A request that the Request rules refuse reaches neither the credential function nor the peer.
2. **`tool_call_split`**: the peer sends `tool.sse` in pieces that cut inside events. The `:tool_start` frame has the id and name and is acknowledged before the first `:tool_delta`; the nine deltas come as nine frames; the result is `:complete`. The POST body, as decoded JSON, equals `tool.upstream.json` without its `provider` member.
3. **`cut_in_tool_call`**: the test cuts `tool.sse` after a tool delta. With the connection closed there, and with the body ended normally there, the result is `:incomplete` (`:transport`, `:missing_completion`). No result holds a tool call.
4. **`slow_consumer`**: while one frame is unacknowledged, no second frame is offered and the peer sees no close. A sink that never returns gives `:sink_timeout`, and the peer sees the close. A sink that cancels closes the request too.
5. **`result_over_bound`**: with `max_result_bytes` equal to the size of the result (283 bytes for `text`, 212 for `tool`) the call is `:complete`. With one byte less it is `{:incomplete, :result_limit}`: the delta that would pass the bound is not offered, and the peer sees the close. A missing or out-of-range `max_result_bytes` is `{:error, :configuration}` and sends nothing.
6. **`provider_error_mid_stream`**: a prefix of `text.sse`, then an `error` event in Anthropic's documented format (written by hand and labelled so, because no such event was recorded), gives `{:incomplete, :stream_error}` and no result. For contrast, a status 529 with no stream gives `{:refused, :overloaded}`.
7. **`equals_non_stream`**: for both pairs the content, the tool calls (id, name, and arguments compared as decoded JSON) and the finish reason of the result equal those of `<name>.message.json`, read with the same finish mapping. Response id, usage and provenance are not compared.

Negative controls (edit temporarily, run, record the failure, revert): offer the next frame without the acknowledgement, and `slow_consumer` must fail; count the end of the body as completion, and `cut_in_tool_call` must fail.

## Needs, limits and evidence

Needs: the caller holds the `delivery/effect-intent` custody of the call, and `run/3` is the one send of one admitted attempt. This Piece keeps no intent, call or outcome record and cannot stop a caller that calls it twice. For that caller an `:incomplete` result is an unknown outcome and gets no automatic retry. Other Needs: a workspace API key from the injected `credentials`, TLS and network egress, a host-chosen model that accepts `thinking: disabled`, and a trusted sink. The host keeps the result and the usage.

Limits: one provider and one wire surface. The fixtures came through OpenRouter, so no test shows a stream from Anthropic's own endpoint. No thinking blocks, structured output, cache hint, stop sequences or server tools. No claim about memory beyond the retained raw block, the current receive chunk and the assembled result. The arguments of a tool call are not checked against the tool's schema; `integration/ai-text` owns that check. No remote cancellation, replay, delivery durability or billing claim.

Keep the evidence kinds apart. Monitored: the two recorded streams are observations of one model on one day, through OpenRouter's Anthropic-compatible endpoint, routed to Anthropic; they are not a proof and not the provider's Contract. The second form of each pair is the output of Anthropic's SDK on those bytes, not a second observation of the provider. Test: the seven groups, finite loopback scenarios on those files and on bytes that the test cuts or adds. Upstream: Req 0.7.5 through the reused `Transport`; `server_sent_events` 1.1.0 called directly on each raw block; Anthropic's "Streaming messages", "Claude API errors" and "API versions" pages as documented, each named with the date read. Cure law: none; tests only. Config: supported, construction of one call only. Control: the sink's cancel return. Telemetry: planned, no Elzoo event; the README says what Req and Finch emit.

Run the Piece tests, then `mix check --piece "$(git merge-base origin/main HEAD)"` and `git diff --check`. One independent review checks this body, the exact diff and needless features.
