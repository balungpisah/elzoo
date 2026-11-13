# ELZ-151 — Accept the documented response members in the data-stream schema

- Dependencies: ELZ-101
- Allowed implementation path: `pieces/delivery/data-stream/**` only, and its index/generated changes under AGENTS.md section 3.

Issue #309 records a finding by reading: the exact-key schema of `delivery/data-stream` lists fewer members than a current stream carries, so the Piece would answer `unsupported_response` at the first event of such a stream. The members were seen in two streams recorded on 2026-11-13 through OpenRouter's Anthropic-compatible endpoint, routed to Anthropic (now on `main` as `pieces/delivery/provider-stream/test/fixtures/openrouter-anthropic-stream/text.sse` and `tool.sse`). Anthropic's reference ("Create a Message", read 2026-11-13) lists them on the Message, the text block and `usage`, and its versioning page says that values may be added to the output within one API version. Not verified, and not claimed by this task: that Anthropic's own endpoint sends each of them in its stream events. No live call is made.

Repair, in two steps:

1. Confirm the reading with a test before any change of `lib/`. Take the `message_start`, the text `content_block_start` and the `message_delta` event of the recorded `text.sse` as test data of this Piece, with only the OpenRouter differences removed: the member `provider` of the message, the `anthropic/` prefix and the `.` form of `model` (use the model ID that the test settings name), and `cost`, `is_byok` and `cost_details` of `usage`. Write them in the test or its helper as derived data and say so in a comment; do not read a file of another Piece, and add no fixture directory. Feed them through `Protocol` as the schema tests do. On `main` each must be refused with `unsupported_response`. If one is accepted, or is refused for a member that this body does not name, stop and write the exact point on issue #309.
2. Add the named members to the accepted lists as members that are allowed and never read:
   - the message of `message_start`: `container`, `stop_details`;
   - the text block of `content_block_start`: `citations`;
   - `message_delta`: `context_management`; its `delta`: `container`, `stop_details`;
   - `usage` (in `message_start` and `message_delta`): `inference_geo`, `server_tool_use`, `service_tier`, `speed`.

   Each may hold any JSON value. None changes a frame, a usage amount, a finish reason, the provenance or a terminal field: a stream with these members gives exactly the frames and the terminal of the same stream without them.

Contract: the rule of the Piece stays. A member that is in neither list is still `unsupported_response`; a malformed shape or order is still `malformed_response`; every bound stays. `provider`, a `model` text with `/`, and the three cost members stay refused: a stream through OpenRouter is not a stream of this Piece (that is `delivery/provider-stream`). No change of the public functions, the frames, the settings or the Piece ID. A rule that ignores every unknown member is a different Contract and is not part of this task.

## Acceptance

- `derived_events_refused_before`: step 1, shown on `main` before the change (record the three results), and kept afterwards as three tests that now pass through `Protocol`.
- `members_not_read`: one whole stream through the public start function on the loopback peer, with every named member present, completes with the same text frames, usage and terminal as the same stream without them.
- `rule_kept`: for each of the five changed lists, one member that is not named is still `unsupported_response`; `provider`, a `model` with `/` and `usage.cost` are still refused.
- Negative control: remove one of the named members from its list again; the test of that event fails. Record it and revert.
- The README states the accepted members, their basis (the reference pages and their read date, the recorded route) and what is not verified; `piece.json` changes only where its text names the schema or the test count.
- `mix test pieces/delivery/data-stream/test` exits 0 with every existing case unchanged and passing. Run `mix check --piece "$(git merge-base origin/main HEAD)"` and `git diff --check` before delivery. Record exact commands and exit codes.

One worker owns the claimed branch/worktree. Do not edit `pieces/delivery/data-stream/test/elzoo/data_stream_postgres_test.exs`: ELZ-149 owns it. One independent review under AGENTS.md section 6. The pull request closes issue #309 as well.
