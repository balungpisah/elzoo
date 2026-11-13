# ELZ-156 — Test `delivery/provider-stream` on a stream recorded from Anthropic's own endpoint

- Dependencies: ELZ-143
- Allowed implementation path: `pieces/delivery/provider-stream/**` only, and its index/generated changes under AGENTS.md section 3.

The README and `piece.json` of `delivery/provider-stream` say that its recorded streams came through OpenRouter and that no test shows a stream from Anthropic's own endpoint. One text stream was recorded on 2026-11-13 from Anthropic's own endpoint (the facts are at the end of this body). Outside the repository, the protocol reader of the Piece on `main` read these bytes without a fault at piece sizes of 1, 97 and 4,096 bytes: the text of the recording, the finish `stop`, input 22 and output 13. This task puts the recording and the test in the repository and corrects the sentences.

No change of `lib/` is expected. If a test of this task needs a change of `lib/`, stop and write the exact point on this issue.

Contract: no change of the public functions, the frames, the settings, the result, the reasons or the Piece ID. The files in `test/fixtures/openrouter-anthropic-stream/` do not change, except the one sentence named below.

## Fixture

Add `test/fixtures/anthropic-direct-stream/` with three files:

- `text.sse`: the response body exactly as received (1,408 bytes, SHA-256 `2d76b71a857ec16d5fec8bdbc4e90998c7e85fda3544b98fb32ae314a999362a`).
- `text.upstream.json`: the request body exactly as sent (177 bytes, SHA-256 `64326ee9e0285b49974b48e8d8e415de25487b5f81ba4c433f401d64d1ff3f11`). The Piece did not build it. `PROVENANCE.md` says so.
- `PROVENANCE.md`: the facts at the end of this body, in the form of the `PROVENANCE.md` of the OpenRouter recording.

The coordinator gives the worker the two recorded files. The worker checks the length and the SHA-256 of each and does not edit them. The worker makes no live call. No response header and no credential is stored in any file.

## Acceptance

- `direct_recording`: one new group in `test/elzoo/provider_stream_test.exs`. A finite loopback scenario over real HTTP/1.1, as the group `text_only`, sends `text.sse` as the response body: once whole, once in pieces of 97 bytes and once in pieces of 1 byte. Each run gives the text frames `Red` and then a line feed, `Orange`, a line feed, `Yellow`, each acknowledged before the next, and a complete result with that text, no tool call, the finish `stop`, input 22, output 13, cache read 0 and cache write 0, and the response id and the model of the recording in the provenance. The `ping` event gives no frame.
- Negative control: with the `ping` clause of `lib/` changed to return `malformed_response`, `direct_recording` fails. Record the failure and revert.
- Each existing test stays unchanged and passes.
- README and `piece.json`: replace the sentences which say that no test shows a stream from Anthropic's own endpoint. State what the recording shows (one model, one day, text only, one `ping`, spaces before the last brace) and what it does not show (see "Not recorded" below). Add the recording to the grounding of `piece.json` as an observation, beside the entry of the OpenRouter recording, and add the three files to its file list.
- In `test/fixtures/openrouter-anthropic-stream/PROVENANCE.md`, the section "Not recorded" names "A direct call to Anthropic" and "A stream with a comment line or a `ping`". Change only that section, so that it says that those files hold no such stream and names the new directory.
- `mix test pieces/delivery/provider-stream/test` exits 0. Run `mix check --piece "$(git merge-base origin/main HEAD)"` and `git diff --check` before delivery. Record exact commands and exit codes.

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
