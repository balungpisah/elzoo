# Provenance of the ELZ-138 fixtures

Recorded 2026-11-13. These files are Monitored observations of one model on one day through one
intermediary. They are not a proof and not the provider's Contract.

## How each response was recorded

- Endpoint: OpenRouter's Anthropic-compatible Messages endpoint, `POST https://openrouter.ai/api/v1/messages`,
  routed to Anthropic. Nothing here was recorded from Anthropic's own endpoint.
- Model: the request names `claude-haiku-5-5` (the Anthropic id; the endpoint accepts it). Each response
  says `"model": "anthropic/claude-haiku-5.5"`. A probe with OpenRouter's routing metadata switched on named
  the endpoint model `anthropic/claude-haiku-5.5-20261007`.
- Provider pin: the request member `"provider": {"only": ["anthropic"], "allow_fallbacks": false}`.
  Each response says `"provider": "Anthropic"`. The metadata probe said `available=1, selected=Anthropic`.
- Authentication: `Authorization: Bearer`. (The endpoint also accepted `x-api-key`.) No request header and no
  credential is stored in any file.
- Other request headers sent: `anthropic-version: 2026-10-21`; `anthropic-beta: tools-2024-05-16` for the four
  requests with tools, as the adapter sends it; `Accept: application/json`; `Accept-Encoding: identity`;
  `Content-Type: application/json`; a neutral `User-Agent`.

## Files of one fixture

- `<name>.request.json`: the ai-text request (schema `elzoo/ai-text-request` version 1). It is the input of the
  estimator. All prompt text is invented.
- `<name>.upstream.json`: the request body exactly as sent.
- `<name>.response.json`: the response body exactly as received, 2xx, not edited.

## Where the upstream body comes from

- Twelve fixtures (`short`, `system`, `tools`, `tools_any`, `tool_turn`, `prose`, `dense`, `symbols`,
  `non_latin`, `expanding`, `many_messages`, `many_tools`): the body was captured with no network from ready
  `integration/ai-text-anthropic` (req_llm 1.30.0, llm_db 2026.11.0) through its `:plug` test transport, at
  repository commit 036e84e, where that Piece equals main 613b558. A second send gave the same bytes.
  The one change before sending: the `provider` member was inserted as the first member. The other bytes are
  the adapter's.
- Three fixtures (`adv_ascii_caps_punct`, `adv_rare_punct`, `adv_upper_rare_punct`): the body was not captured.
  It was built from the shape of the captured one-message bodies. That template gives the captured bytes
  exactly for the six captured one-message fixtures. The test that ties a fixture to the adapter checks these
  three as well.

## Deliberate differences from a direct Anthropic call through the adapter

1. The endpoint and the authentication header.
2. The added `provider` member in the request body.
3. The adapter's headers `x-api-key`, `accept: application/json` and `user-agent: req/0.7.5` were not
   reproduced as such. Whether OpenRouter passes `anthropic-version` and `anthropic-beta` on to Anthropic
   is not known.
4. The response `model` is OpenRouter's id. The response has a `provider` member, and its `usage` has
   `cost`, `is_byok` and `cost_details`. Response headers are not stored.

## What the recordings showed

- The adapter sends no `thinking` member, so the model's default applies. One probe got 18 input tokens with
  the default and 16 with `thinking` disabled for the same text.
- `tools_any` minus `tools` is 120 tokens. Only the 120 is recorded. Anthropic's table of tool use system prompt
  tokens (page "Tool use with Claude", section "Pricing") said 406 and 286 for this model on 2026-11-13, the
  same difference; the two table values are an upstream statement.
- Two fixture responses (`prose`, `expanding`) have `stop_reason: "refusal"` with category `bio` and no
  content. Their `usage` still reports the input tokens, and the two halves of `prose`, sent separately and
  not refused, sum to the same count. One probe was refused with zero usage; it is not used.
- A count of bytes is not an upper bound. `expanding` has 5,478 reported tokens for 4,679 canonical bytes.
  `probe-table.tsv` lists 465 further requests of one user message each (464 with usage). The highest result
  is 1,208 reported tokens for 600 bytes of text: a two-byte capital letter outside ASCII followed by a
  punctuation mark or a digit. As reported that is 2.01 tokens for each byte of text. It is 2.00 only after
  the 8 tokens that a one-message request reports beyond its text are subtracted (a one-letter message
  reported 9), and 1.72 for each canonical byte. For ASCII alone the highest is `Q.` repeated, 908 tokens
  for 600 bytes: 1.51 as reported, 1.50 after the same subtraction. `Y.` and `Z.` gave the same 1.50 on
  shorter requests.
  The tokenizer is not published, and a pattern that was not tried can be higher.
- With `size = 3 * canonical bytes (+ 1,024 with tools)` every fixture is covered; the smallest ratio of
  `size` to reported is 1.74 and the largest is 29.72.

## Not recorded

A direct call to Anthropic. Another model. A request with reasoning, an output schema, a cache hint or
stop sequences. A cache read or write (each cache counter is 0). An error response. The raw bodies of the
probes are kept by the coordinator beside this directory and are not files of the Piece; `probe-table.tsv`
is their summary.
