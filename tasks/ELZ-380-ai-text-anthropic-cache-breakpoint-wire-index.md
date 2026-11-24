# ELZ-380 — integration/ai-text-anthropic marks exactly the message that a cache breakpoint names, or refuses the hint before any byte

- Phase: repair of the ready Piece `integration/ai-text-anthropic` before the first release (defect #913)
- Dependencies: ELZ-079, ELZ-371
- Release: V1B
- Output: none. A repair in place of the ready Piece `integration/ai-text-anthropic` (ELZ-079, image input ELZ-371) that restores its cache-hint rule, with the same Piece ID (`AGENTS.md` section 4).
- Change class: Piece-only implementation (`scripts/ci-change-class.py`: the Piece directory, its index row and generated files)
- Owned paths: `pieces/integration/ai-text-anthropic/**`; the `manifest_sha256` and `note` of its `entries` row in `docs/plans/release-plan.json` and the generated `LEDGER.md`, `docs/plans/views.md` and `docs/plans/dependencies.mmd` (`AGENTS.md` section 3). No other Piece, no root test or helper, no `mix.exs`, `mix.lock` or CI.

## Defect and boundary

Reported in #913, with the image-parts form in its first comment. This publication does not settle #913; the build pull request does.

A cache hint's message breakpoint `{"message": i}` names the `i`-th message of the request's non-system messages, as `cache_options/3` reads it on `main`. The Piece passes `i` unchanged to `req_llm` as `anthropic_cache_messages: i`. `req_llm` 1.30.0 applies that index to its encoded wire list, after `merge_consecutive_tool_results/1` has merged each run of consecutive tool-result messages into one user message (`deps/req_llm/lib/req_llm/providers/anthropic/context.ex`, `add_messages/2` and `merge_consecutive_tool_results/1`; `deps/req_llm/lib/req_llm/providers/anthropic.ex`, `do_cache_message_at/3`, which returns the body unchanged for an index out of range). When a run of two or more tool results precedes the named message, the marker lands on a later message, or is dropped with no error and the request is sent without it.

The rule this breaks: "a hint the provider cannot express exactly is refused `unsupported_feature`, never dropped" (`integration/ai-text` README, "Interface rules"), and this Piece's code comment in `cache/1`, "Other breakpoint sets cannot be expressed exactly and are refused". The Piece's README today states the shift as a known limit ("Image input", the last sentence of the cache-breakpoint bullet); this task removes that limit.

## Facts on `main` that this task builds on

Checked at `a9b1badb`; confirm each before you start, and comment on the issue if one differs.

- `Elzoo.AiText.Anthropic.cache/1` refuses, before any request, a TTL other than `5m` or `1h`, a non-message set other than `system` (plus `tools` when tools are present), more than one message breakpoint and a request without a system message (`unsupported_feature`), then calls `cache_options/3` with the non-system messages.
- `cache_options/3`, for `[{:message, i}] when i < length(conversation)`, refuses `unsupported_feature` when the neutral message `i` or the wire message `i` (`wire/1`, the Piece's own model of the merge) is a parts message, and otherwise returns `anthropic_cache_messages: i`; an index at or past the conversation's length is `invalid_request`.
- `req_llm`'s `add_cache_to_message_content/2` puts `cache_control` on a string content's one text block, or on the last block of a list content when that block has none. So marking a merged tool-result message marks the last tool result of its run.
- The tests: `A3 cache hint mapped to cache_control markers; inexpressible or overflowing hints refused before any request (translate)` and the ELZ-371 image test that refuses a breakpoint on the parts message, in `test/elzoo/ai_text_anthropic_test.exs`, and the golden wire requests of ELZ-371 acceptance 1.

## The repair

- The Piece maps the named message to its index in the wire list: each run of consecutive tool-result messages counts as one wire message, every other message as one.
- A breakpoint on a message that is not a tool result, or on the last tool result of its run, is sent as `anthropic_cache_messages: <wire index>`, so `req_llm` marks exactly that message (for a run, the last block of the merged message, which is that tool result).
- A breakpoint on a tool result that is not the last of its run is refused `unsupported_feature` before any request: `req_llm` would mark the run's last tool result, a later block than the one named.
- A breakpoint on a parts message stays refused `unsupported_feature`. The second half of today's rule (a wire index that names a parts message) no longer applies, because the wire index is now the named message's own; a breakpoint on a text message of a request with image parts is sent at its wire index.
- An index at or past the end of the non-system messages stays `invalid_request`. No hint is ever sent with an index that `req_llm` would drop.
- A request without a run of two or more tool results before the named message sends the same wire request as today, byte for byte, and so does every request without a message breakpoint.
- The README's cache-hint bullet and the image-input bullet say this, the limit sentence about the shift is removed, and `piece.json` (`contract`, `limits`, `grounding`) follows; the `note` and `manifest_sha256` of the index row follow `piece.json`.

## Acceptance

New tests in `test/elzoo/ai_text_anthropic_test.exs`, against the Piece's stub, each asserting the wire request (or that no request was made):

1. **The issue's case.** Non-system messages `[user "u0", assistant with tool calls t1 and t2, tool_result t1, tool_result t2, user "LAST"]` with a system message and tools, breakpoints `["system", "tools", {"message": 3}]` (the second tool result): the wire request has `cache_control` on the `tool_result` block of t2 in the merged message and on no block of `user "LAST"`. On `main` this case fails: the marker is on `"LAST"`.
2. **The last message after a run.** The same request with `{"message": 4}`: `cache_control` is on the text block of `"LAST"` (wire message 3). On `main` it fails: the index is out of range on the wire and the marker is dropped.
3. **Inside a run.** The same request with `{"message": 2}` (t1, not the last of its run): `{:refused, :unsupported_feature}` and no request.
4. **With image parts** (the first comment of #913). Non-system messages `[user parts (text and one image), assistant with two tool calls, tool_result, tool_result, user text]` with breakpoints `["system", "tools", {"message": 4}]`: `cache_control` is on the final user text block. On `main` it fails: the marker is dropped. The same request with `{"message": 0}` stays `unsupported_feature` with no request.
5. **The rest is unchanged.** Every existing test of the Piece passes unchanged, the golden wire requests and A3 included. Expected: no golden value changes, since no golden scenario holds a message breakpoint after a run of two or more tool results. If one changes, stop and comment on the issue before changing it.

Negative controls, each a temporary edit of `lib/` that is reverted and never committed; record each failure in the pull request:

- pass the neutral index unchanged (the code of `main`): cases 1, 2 and 4 fail;
- drop the refusal of a tool result that is not the last of its run: case 3 fails (a request is sent with the marker on t2).

## Gate, review and build

Run `mix test pieces/integration/ai-text-anthropic/test`, then the small gate `mix check --piece "$(git merge-base origin/main HEAD)"` and `git diff --check`. The Piece carries a provider key and an external-effect boundary, so it keeps the local small gate and gets the full review of the coordinator guide ("Reviewer by risk"); the hosted `check-piece` run on the exact head and the merge queue follow.

## Limits to state

- The mapping models `req_llm` 1.30.0's merge of consecutive tool results; a later `req_llm` that encodes differently needs this rule checked again (the pinned version is not changed here).
- Stub evidence only: conformance to the pinned documented format, not live cache behaviour.
- Finite listed scenarios, not a proof.
