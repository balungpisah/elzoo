# integration/ai-token-count

`Elzoo.AiTokenCount.Anthropic.estimate(payload)` gives an upper bound for the
input tokens of one `integration/ai-text` request to Anthropic, before the call,
so that a caller can refuse or shorten the request before it spends. The value
is not a token count, it is not exact, it is not tight and it is not proved.
The usage that the provider reports after the call stays the only usage fact.

The function is pure: no Effect, credential, network, clock, process or storage
write. Its one read outside its argument is the model catalogue of pinned
`llm_db` 2026.11.0, which loads from the snapshot file inside the package on the
first query and contacts no source.

## Interface

`payload` is the bytes of one `elzoo/ai-text-request` version 1, the same bytes
that `integration/ai-text` admits. They are decoded with
`Elzoo.AiText.Request.decode/1`; this Piece has no second validator.

    {:ok, %{size: n, unit: :tokens, direction: :upper_bound,
            provider_id: "anthropic", model_id: model,
            estimator_id: "elzoo/ai-token-count/anthropic-bytes", estimator_version: 1}}
    {:refused, :invalid_request | :too_large | :unsupported_feature | :unknown_model}

- `size` (estimator version 1) is `3 * byte_size(canonical)`, plus 1,024 when the
  request has at least one tool. `canonical` is the canonical encoding that
  `Request.decode/1` returns: it holds each system text, message text, echoed
  tool call, tool result, tool name, tool description and input schema.
- The 1,024 covers the tool-use system prompt that Anthropic adds when a request
  has tools. Anthropic's table of tool use system prompt tokens (page "Tool use
  with Claude", section "Pricing") had 804 as its largest value when read on
  2026-11-13; that is an upstream statement, not a recording.
- `:invalid_request`, `:too_large` and `:unsupported_feature` are the reasons of
  `Request.decode/1`, unchanged. A request with an `output_schema` is also
  refused `:unsupported_feature`: for structured output Anthropic adds a system
  prompt of no documented size, so no bound is claimed.
- `:unknown_model`: `LLMDB.model(:anthropic, model)` does not return `{:ok, _}`.
  An alias that `llm_db` resolves is accepted; `model_id` is the text of the
  request, unchanged.
- A refusal carries no number, no function returns a bare number and no
  refusal echoes request content.
- The seven fields have the types of a window of `workflow/context-selection`:
  `size` is the number that a caller puts under such a window. A change of the
  rule for `size` is a new `estimator_version`.

What `direction: :upper_bound` claims: for a request that ready
`integration/ai-text-anthropic` sends, the reported prompt input
(`input_tokens + cache_read_input_tokens + cache_creation_input_tokens` of the
response `usage`) is at most `size`. A caller reads the limit of a model from
`LLMDB.model/2` itself and makes the comparison; this Piece wraps neither.

## Why three times the bytes

Anthropic publishes no tokenizer for its current models, and its token-counting
page said on 2026-11-13 that Claude 4.7 and later models count about 30 percent
more tokens for the same text than earlier models (an upstream statement). The
count endpoint needs a credential and a network call, and Anthropic calls its
result an estimate that might differ by a small amount, so it is not an upper
bound either. A count of bytes needs neither, but one token for each byte is not
an upper bound: the recordings below show more reported tokens than canonical
bytes for `expanding` and the three `adv_` fixtures. With the factor 1 these
four are below the reported value; that is why the factor is 3.

The fixtures were recorded through OpenRouter's Anthropic-compatible endpoint, routed to Anthropic,
on 2026-11-13, for the model `claude-haiku-5-5`; Anthropic's own endpoint was
not called. `test/fixtures/openrouter-anthropic/PROVENANCE.md`
says how the provider was pinned, which response members show it, each
difference from a direct call and what was not recorded. A recording is a
Monitored observation of one model on one day through one intermediary: it is
not a proof and not the provider's Contract. Seven response fixtures hold the
`signature` of a thinking block as recorded: opaque provider data, not a
credential.

| Fixture | Canonical bytes | Reported | `size` | `size` / reported |
| --- | ---: | ---: | ---: | ---: |
| `short` | 132 | 16 | 396 | 24.75 |
| `system` | 270 | 56 | 810 | 14.46 |
| `tools` | 772 | 557 | 3340 | 6.00 |
| `tools_any` | 771 | 677 | 3337 | 4.93 |
| `tool_turn` | 1098 | 687 | 4318 | 6.29 |
| `prose` | 6151 | 1967 | 18453 | 9.38 |
| `dense` | 6320 | 4690 | 18960 | 4.04 |
| `symbols` | 4102 | 3784 | 12306 | 3.25 |
| `non_latin` | 6184 | 2123 | 18552 | 8.74 |
| `expanding` | 4679 | 5478 | 14037 | 2.56 |
| `many_messages` | 1932 | 195 | 5796 | 29.72 |
| `many_tools` | 2748 | 1458 | 9268 | 6.36 |
| `adv_ascii_caps_punct` | 702 | 908 | 2106 | 2.32 |
| `adv_rare_punct` | 552 | 758 | 1656 | 2.18 |
| `adv_upper_rare_punct` | 702 | 1208 | 2106 | 1.74 |

The smallest ratio is 1.74 (`adv_upper_rare_punct`) and the largest is 29.72 (`many_messages`).

On ordinary prose the bound is about nine times the reported value. Beside the
fifteen fixtures, `probe-table.tsv` summarizes 465 further recorded requests of
one user message each (464 with usage), used to choose the factor; no test
reads it. Its highest result is 1,208 reported tokens for 600 bytes of text (a
two-byte capital letter outside ASCII followed by a punctuation mark or a
digit): 2.01 tokens for each byte of text as reported, 2.00 after the 8 tokens
that a one-message request reports beyond its text, and 1.72 for each canonical
byte. If the pattern stays linear in length, the ratio of `size` to the reported
value falls toward 1.50 for a long text of that kind and stays above it. No
recording has a lower ratio than 1.74. The tokenizer is not published, so a
text pattern that was not tried can pass the factor.

## Grounding

- Monitored: the fifteen fixtures and the probe table, recorded through
  OpenRouter's Anthropic-compatible endpoint, routed to Anthropic, for one model
  on one day.
- Test: `test/elzoo/ai_token_count_anthropic_test.exs` runs seven groups on those
  files with no network. `fixtures_upper_bound`: each fixture's `size` is at
  least its reported prompt input. `observed_error_stated`: the table and the
  extremes above are computed again from the fixtures. `fixture_matches_adapter`:
  the body that `integration/ai-text-anthropic` sends for each request fixture,
  captured through its `:plug` test transport with a stub credential, equals the
  recorded upstream body without its `provider` member. `unknown_model_refused`,
  `tools_and_system_counted`, `never_exact` and `no_network` check the rule, the
  refusals, the result shape and a source audit of this Piece's `lib` file.
  Finite scenarios, not proofs.
- Upstream: the model lookup of `llm_db` 2026.11.0; Anthropic's token-counting
  page and tool-use table as documented, read on 2026-11-13.
- Assumption, not proved: no request gives more than three reported tokens for
  each canonical byte; OpenRouter passes the request body and Anthropic's
  `usage` on unchanged.
- Cure law: none. The rule is one product and one sum, and the claim is about a
  provider.

## Needs and limits

- Needs: the pinned `llm_db` catalogue as packaged (a host that filters or
  replaces it changes which models are known), and a request that goes
  unchanged through `integration/ai-text-anthropic`.
- `integration/ai-text-anthropic` and `plug` are used by the test only (group
  `fixture_matches_adapter`); the `lib` file uses neither.
- No claim for another model, a direct call to Anthropic, or a request feature
  that no fixture covers (reasoning, cache hint, stop sequences). A new model or
  tokenizer can break the bound.
- No claim about output tokens, cost, cache savings or a rate limit. The value
  is not a usage fact and is not for billing.
- No tokenizer, no count endpoint, no second provider, no estimate of a single
  item. A count endpoint or a tokenizer is a later estimator with its own
  `estimator_id`.
- Telemetry, Config and Control are not applicable: a pure function with no
  process, no setting and no state to control.
