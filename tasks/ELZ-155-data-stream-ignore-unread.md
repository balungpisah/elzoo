# ELZ-155 — Make `delivery/data-stream` ignore the members and event types that it does not read

- Dependencies: ELZ-101, ELZ-151, ELZ-154
- Allowed implementation path: `pieces/delivery/data-stream/**` only, and its index/generated changes under AGENTS.md section 3.

One text stream was recorded on 2026-11-13 from Anthropic's own endpoint (the facts are at the end of this body). `delivery/data-stream` on `main` refuses it at the first event with `unsupported_response`: the Message of `message_start` carries the member `diagnostics` (value `null`), and that member is in neither list of the exact-key schema. With that one member removed, the Piece reads the same bytes to the end at piece sizes of 1, 7, 97 and 4,096 bytes. ELZ-151 added eight members to the lists from a reading of the reference; this is the ninth. Anthropic's versioning page (read 2026-11-13) says that within one API version it may "add additional values to the output" and "add new variants to enum-like output values (for example, streaming event types)". Its streaming page says: "your code should handle unknown event types gracefully".

Decision of the owner (2026-11-13): the Piece ignores what it does not read. This replaces the rule "a member in neither list is `unsupported_response`" of ELZ-101 and ELZ-151. The task files of ELZ-101 and ELZ-151 are not edited.

## Rule

1. **Members.** The Piece reads these JSON objects: the object of each event, `message`, `content_block`, each `delta`, `error`, each `usage`, `cache_creation` and `output_tokens_details`. In each of them, a member that the Piece does not read is ignored. It may hold any JSON value inside the bounds of the decoder. Each member that the Piece reads keeps its present rule: required or optional, type, bound and value.
2. **Event types.** An event whose type the Piece does not read is ignored at each point where `ping` is accepted today. It must be one well-formed block: its data is one JSON object, and the `type` of that object is equal to the event name. If not, the result is `malformed_response`. An ignored event gives no frame and changes no state, except that it counts as one event, as `ping` does.
3. **Numbers.** The decoder accepts a number with a fraction or an exponent. Set one bound on the length of such a number, not below 32 bytes; state it in the README and test it at the bound and at one byte more. The bound of an integer stays. In a member that the Piece reads as an integer, a number that is not an integer is `malformed_response`, as each other wrong type is.
4. **One exception, to keep a usage amount right.** In `cache_creation` the names of the members are data: each name is one lifetime. If that group holds a member that the Piece does not read, the Piece does not use the group. The cache-write result is then `provider_default` with the amount of `cache_creation_input_tokens` of the same `usage` object, or unknown when that member is absent or `null`. The two members that the Piece reads in the group keep their type rule.

"Ignored" means: a stream with the member or the event gives exactly the frames, the usage, the finish reason, the provenance and the terminal of the same stream without it. Three things differ and no more: `received_body_bytes` counts its bytes, the two byte bounds (65,536 for one raw block and 4,194,304 for the body) count them, and an ignored event counts as one event.

## Contract: what stays

- The order of the events. A known event at a wrong point is `malformed_response`.
- A `content_block` whose `type` is not `text`, and a `delta` of `content_block_delta` whose `type` is not `text_delta`, are `unsupported_response`. To ignore them would lose content.
- A stop reason outside the four, a `stop_sequence` that is not `null` and a `thinking_tokens` amount other than 0 or `null` are `unsupported_response`.
- The `error` event ends the stream as it does today, and its read members keep their checks.
- Each bound: bytes, depth, length of an integer, text, the count of blocks. A duplicate key at any depth is still refused.
- A `model` text with `/` is still refused: this is a rule of a member that the Piece reads.
- No change of the public functions, the frames, the settings, the request bytes, `Framer`, `Transport`, `Session` or the Piece ID.

After this change `provider` in the message and `cost`, `is_byok` and `cost_details` in `usage` are ignored as each other member that is not read. The Piece sends its request only to Anthropic's endpoint, so their refusal protected nothing.

## Fixture

Add `test/fixtures/anthropic-direct-data-stream/` with three files. The directory has a name of this Piece's own: an exported consumer puts the test files of each selected Piece at the same relative path, and `delivery/provider-stream` holds `test/fixtures/anthropic-direct-stream/` with a `PROVENANCE.md` of other bytes (ELZ-156). The first form of this body named that same directory; the export refuses two different files at one path.

- `text.sse`: the response body exactly as received (1,408 bytes, SHA-256 `2d76b71a857ec16d5fec8bdbc4e90998c7e85fda3544b98fb32ae314a999362a`).
- `text.upstream.json`: the request body exactly as sent (177 bytes, SHA-256 `64326ee9e0285b49974b48e8d8e415de25487b5f81ba4c433f401d64d1ff3f11`).
- `PROVENANCE.md`: the facts at the end of this body, in the form of the `PROVENANCE.md` of `delivery/provider-stream`.

The coordinator gives the worker the two recorded files. The worker checks the length and the SHA-256 of each and does not edit them. The worker makes no live call. No response header and no credential is stored in any file.

## Acceptance

- `direct_recording_refused_before`: before any change of `lib/`, feed `text.sse` through `Framer` and `Protocol` on the base of the branch. The result must be `unsupported_response` at the first event. Record it in the pull request. If the result is different, stop and write the exact point on this issue.
- `direct_recording_replay`: after the change, `text.sse` through `Framer` and `Protocol` at piece sizes of 1, 7, 97 and 4,096 bytes ends in the stopped state each time, with the text `Red`, a line feed, `Orange`, a line feed, `Yellow`, the finish reason `stop`, input 22, output 13, cache read 0, cache write 0, reasoning 0, and the response id and the model of the recording in the provenance.
- `direct_recording_owner`: one loopback run through the public `start`, with the recorded bytes as the response body and `text/event-stream; charset=utf-8` as the content type, gives a `complete` terminal with the same text, finish reason and usage.
- `unread_member_ignored`: for each object of rule 1 except `cache_creation` (rule 4), one added member with each of these values: `null`, a text, an integer, a number with a fraction, an object and a list. The state and the action are equal to those without the member.
- `unread_event_ignored`: an event of an unknown type before `message_start`, inside an open block, between two blocks and after `message_delta` gives no frame, and the stream ends with the result of the same stream without it. An unknown event whose data is not an object, or whose `type` is not equal to the event name, is `malformed_response`.
- `number_rule`: the cases of rule 3, with `input_tokens` and `index` as the members that are read as integers.
- `cache_creation_unread_member`: the cases of rule 4: with the total present, with the total absent and with the total `null`.
- `rules_kept`: each point of "Contract: what stays" has a test. An existing one is enough.
- Existing tests: an existing assertion changes only when it asserts the replaced rule, that is: an unread member or an unread event type is `unsupported_response`, or a number with a fraction in a member that is not read is `malformed_response`. List each changed assertion in the pull request, with its old and its new result. If an assertion of another rule must change, stop and write the exact point on this issue.
- Negative control: with the change of the member rule in `lib/` undone, `direct_recording_replay` fails with `unsupported_response`. Record it and revert.
- README: state the rule of this body where the README describes the schema, and remove the sentences of the replaced rule. Replace the sentence that starts with "Not verified" by what the recording shows and what it does not show. `piece.json`: change its text only where it names the replaced rule, the fixture files, the tests or their count; add the recording to the grounding as an observation, as `delivery/provider-stream` does for its recorded streams.
- `mix test pieces/delivery/data-stream/test` exits 0. Run `mix check --piece "$(git merge-base origin/main HEAD)"` and `git diff --check` before delivery. Record exact commands and exit codes.

## Facts of the recording

- One call on 2026-11-13 at 15:38:29 UTC: `POST https://api.anthropic.com/v1/messages`, made with curl 8.18.0. The response came over HTTP/2.
- Request headers: `anthropic-version: 2026-10-21`, `content-type: application/json`, `accept: text/event-stream`, `accept-encoding: identity`, a neutral `user-agent`, and the key in `x-api-key`. No beta header.
- Request body: model `claude-haiku-5-5`, `max_tokens` 64, thinking disabled, `stream` true. The prompt text is invented.
- Response: status 200, `content-type: text/event-stream; charset=utf-8`.
- Eight events in this order: `message_start`, `content_block_start`, `ping`, `content_block_delta` (two), `content_block_stop`, `message_delta`, `message_stop`. One text block. `stop_reason` is `end_turn`. `output_tokens` is 3 in `message_start` and 13 in `message_delta`.
- Members in the message: `container`, `stop_details` and `diagnostics`, each `null`. In its `usage`: `cache_creation` with both lifetimes 0, `service_tier`, `inference_geo` and `speed`. In the delta of `message_delta`: `container` and `stop_details`. In the `usage` of `message_delta`: `input_tokens`, the two cache totals, `output_tokens` and `output_tokens_details` with `thinking_tokens` 0.
- Not in this stream, but in the streams recorded through OpenRouter on the same day: `citations`, `context_management` and `server_tool_use`.
- Form: six `data:` lines have spaces before the last brace. The data of `ping` has a space after the colon. There is no comment line.
- Not recorded: another model, a second call, a tool call, thinking, an `error` event, a cut stream, and HTTP/1.1 on the live endpoint (the transport of the Piece).

One worker owns the claimed branch/worktree. One independent review under AGENTS.md section 6.
