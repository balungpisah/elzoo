# ELZ-138 — Token estimate before a model call (Anthropic first)

## Scope and reuse

- Dependencies: ELZ-033, ELZ-079, ELZ-030
- Output: `integration/ai-token-count`; release V1B; bot-platform level 1.
- Owned paths: `pieces/integration/ai-token-count/**` and its index/generated changes under AGENTS.md section 3.

Give an upper bound for the input tokens of one `integration/ai-text` request before the call, so that a caller can refuse or shorten the request before it spends. The value carries the estimator fields that a window of `workflow/context-selection` names. The usage that the provider reports stays the only usage fact.

Implement only the acceptance groups below. Add no options, layers, behaviours, generic helpers or future hooks: no tokenizer, no count endpoint, no second provider, no estimate of a single item, no wrapper for model limits. Change no ready Piece, shared path, `mix.exs`, `mix.lock`, `registry/providers.json` or CI file. The worker has no provider credential and makes no network call, and no test calls the network. The independent reviewer flags extra features for removal.

## Provider fit (decided at admission)

Method: three times the bytes of the canonical request, counted locally. No tokenizer and no provider call.

- A local tokenizer does not fit. None is pinned, and Anthropic publishes none for its current models. Its token-counting page said on 2026-11-13 that Claude 4.7 and later models count about 30 percent more tokens for the same text than earlier models; this is an upstream statement, not a recording. So one tokenizer cannot serve them all. A tokenizer of another provider gives a wrong count with no known direction.
- The provider count endpoint (`POST /v1/messages/count_tokens`) does not fit this task. Pinned `req_llm` 1.30.0 has no call for it. It needs a credential and one network call for each estimate, so the Piece would be an Adapter, and a pure caller could not use it. Anthropic's page calls the result "an estimate" that "might differ by a small amount": it is an approximate value, not an upper bound.
- A count of bytes needs no dependency, no credential and no call. But one token for each byte is not an upper bound: the highest recording has 1,208 reported tokens for 600 bytes of text. As reported that is 2.01 tokens for each byte of text; it is 2.00 only after the 8 tokens that a one-message request reports beyond its text are subtracted, and it is 1.72 for each canonical byte. With the factor 3, `size` for that request is 2,106, which is 1.74 times the reported value. If the pattern stays linear in length, this ratio falls toward 1.50 for a long text and stays above it. No recording has a lower ratio.

So this Piece is pure and is not an Adapter: no Effect, credential, network, clock, process or storage write. Its one read outside its argument is the model catalogue of pinned `llm_db` 2026.11.0. That catalogue loads from the snapshot file inside the package on the first query and contacts no source.

What the method cannot claim: it is not a token count, it is not exact, it is not tight and it is not proved. The tokenizer is not published, so the factor rests on recorded observations, and a text pattern that was not tried can pass it. On ordinary prose the bound is about nine times the reported value. A count endpoint or a tokenizer is a later estimator with its own `estimator_id`; a tokenizer is first its own provider-prerequisite task.

## Interface

One public function: `Elzoo.AiTokenCount.Anthropic.estimate(payload)`.

`payload` is the bytes of one `elzoo/ai-text-request` version 1, the same bytes that `integration/ai-text` admits. Decode them with `Elzoo.AiText.Request.decode/1`; write no second validator. The model is the `model` member of the request.

    {:ok, %{size: n, unit: :tokens, direction: :upper_bound,
            provider_id: "anthropic", model_id: model,
            estimator_id: "elzoo/ai-token-count/anthropic-bytes", estimator_version: 1}}
    {:refused, :invalid_request | :too_large | :unsupported_feature | :unknown_model}

- `size`, under estimator version 1, is `3 * byte_size(canonical)`, plus 1,024 when the request has at least one tool. `canonical` is the canonical encoding that `Request.decode/1` returns. It holds each system text, message text, echoed tool call, tool result, tool name, tool description and input schema of the request.
- The 1,024 covers the tool-use system prompt that Anthropic adds when a request has tools. On 2026-11-13 the largest value in Anthropic's table of tool use system prompt tokens (page "Tool use with Claude", section "Pricing") was 804; this is what the page said, an upstream statement and not a recording. Read the table again when you build. If a value is above 1,024, stop and comment on the issue.
- `:invalid_request`, `:too_large` and `:unsupported_feature` are the reasons of `Request.decode/1`, unchanged. A request with an `output_schema` is also refused `:unsupported_feature`: for structured output Anthropic adds a system prompt of no documented size, so no bound is claimed.
- `:unknown_model`: `LLMDB.model(:anthropic, model)` does not return `{:ok, _}`. `model_id` in the result is the text of the request, unchanged.
- A refusal carries no number, and no function returns a bare number. No error echoes request content.
- `provider_id`, `model_id`, `unit`, `estimator_id` and `estimator_version` have the types of a window in `pieces/workflow/context-selection/lib/elzoo/context_selection.ex`: each ID a text of 1 to 1,024 bytes, the version an integer from 1. `size` is the bare number that a caller puts under such a window. A change of the rule for `size` is a new `estimator_version`.

What `direction: :upper_bound` claims: for a request that ready `integration/ai-text-anthropic` sends, the reported prompt input is at most `size`. The reported prompt input is `input_tokens + cache_read_input_tokens + cache_creation_input_tokens` of the response `usage`.

## Fixtures: supplied by the coordinator, committed unchanged

The coordinator supplies the recorded files. The worker commits them unchanged under `pieces/integration/ai-token-count/test/fixtures/openrouter-anthropic/` and does not write, edit or generate a provider response.

They were recorded on 2026-11-13 through OpenRouter's Anthropic-compatible endpoint, routed to Anthropic, for the model `claude-haiku-5-5`. They were not recorded from Anthropic's own endpoint. `PROVENANCE.md` in that directory says how the provider was pinned, which response members show it, each difference from a direct call, and what was not recorded. Read it before you write the README.

A fixture has three files: `<name>.request.json` (the ai-text request, the input of `estimate/1`), `<name>.upstream.json` (the request body as sent) and `<name>.response.json` (the response body as received). `probe-table.tsv` is the summary of 465 further recorded requests that were used to choose the factor; it is evidence for the README and no test reads it.

The numbers at admission, for you to check your implementation against:

| Fixture | Canonical bytes | `size` | Reported | `size` / reported |
| --- | ---: | ---: | ---: | ---: |
| `short` (one short user text) | 132 | 396 | 16 | 24.75 |
| `system` (system text and user text) | 270 | 810 | 56 | 14.46 |
| `tools` (two tools, `tool_choice` auto) | 772 | 3,340 | 557 | 6.00 |
| `tools_any` (the same, `tool_choice` any) | 771 | 3,337 | 677 | 4.93 |
| `tool_turn` (echoed tool call and its result) | 1,098 | 4,318 | 687 | 6.29 |
| `prose` (long English text) | 6,151 | 18,453 | 1,967 | 9.38 |
| `dense` (digits, hex, unbroken letter strings) | 6,320 | 18,960 | 4,690 | 4.04 |
| `symbols` (ASCII punctuation only) | 4,102 | 12,306 | 3,784 | 3.25 |
| `non_latin` (ten languages outside Latin script, and emoji) | 6,184 | 18,552 | 2,123 | 8.74 |
| `expanding` (compatibility characters) | 4,679 | 14,037 | 5,478 | 2.56 |
| `many_messages` (63 one-letter messages) | 1,932 | 5,796 | 195 | 29.72 |
| `many_tools` (40 smallest tools) | 2,748 | 9,268 | 1,458 | 6.36 |
| `adv_ascii_caps_punct` (`Q.` repeated) | 702 | 2,106 | 908 | 2.32 |
| `adv_rare_punct` (a rare letter and `.` repeated) | 552 | 1,656 | 758 | 2.18 |
| `adv_upper_rare_punct` (a rare capital and a mark repeated) | 702 | 2,106 | 1,208 | 1.74 |

With the factor 1 instead of 3, the last three fixtures and `expanding` are below the reported value. That is why the factor is 3.

## Acceptance groups

1. **`fixtures_upper_bound`**: for each of the fifteen fixtures, `size` is at least the reported prompt input. A fixture with `size` below it fails the test, and with it the upper-bound claim. Then stop and comment on the issue. Do not change the label, the rule or the fixture to get a green result. A fixture whose `usage` lacks one of the three fields is not used.
2. **`observed_error_stated`**: the README has one row for each fixture (reported, `size`, `size` divided by reported), names the smallest and the largest ratio, and says where the fixtures came from in the words of `PROVENANCE.md`. A test computes the same numbers from the fixtures and compares them with the README.
3. **`fixture_matches_adapter`**: for each fixture, with no network, the body that `integration/ai-text-anthropic` sends for `<name>.request.json` is captured through its `:plug` transport (`translate/2` with a plug, then `call/2` with a stub credential). As decoded JSON it equals `<name>.upstream.json` without the `provider` member, which is the one difference that `PROVENANCE.md` lists for the body.
4. **`unknown_model_refused`**: a model that `llm_db` does not know for Anthropic and a model of another provider are refused `:unknown_model`. An alias that `llm_db` resolves is accepted.
5. **`tools_and_system_counted`**: one more tool raises `size` by three times the bytes that it adds to the canonical request. The first tool also adds 1,024; a second tool does not add it again. One more system message raises `size` by at least three times the bytes of its text. Two payloads that differ only in key order and whitespace give the same result.
6. **`never_exact`**: each `{:ok, _}` result has exactly the seven keys above, with `direction: :upper_bound`. The module exports only `estimate/1`. Each refusal in the list above is reached and carries no number. The README and the manifest call the value an upper bound, never a count.
7. **`no_network`**: an audit of this Piece's own `lib` files finds no HTTP client, socket, `ReqLLM`, environment read or process start. The manifest lists no HTTP provider for the `lib` files.

Negative controls (edit temporarily, run, record the failure, revert): use the factor 1, and `fixtures_upper_bound` must fail on four fixtures; leave the tools out of the count, and `tools_and_system_counted` must fail.

## Needs, limits and evidence

Needs: the pinned `llm_db` catalogue as packaged (a host that filters or replaces it changes which models are known), and a request that goes unchanged through `integration/ai-text-anthropic`. A caller reads the limit of a model from `LLMDB.model/2` itself and makes the comparison; this Piece wraps neither. Group 3 needs `integration/ai-text-anthropic` and its `plug` test provider at test time only; declare that as the manifest rules require.

Limits: no claim for another model, a direct call to Anthropic, or a request feature that no fixture covers (reasoning, cache hint, stop sequences). A new model or tokenizer can break the bound. No claim about output tokens, cost, cache savings or a rate limit. The value is not a usage fact and is not for billing.

Keep the evidence kinds apart. Monitored: the fifteen fixtures and the probe table are observations of one model on one day, recorded through OpenRouter's Anthropic-compatible endpoint, routed to Anthropic; they are not a proof and not the provider's Contract. Test: the seven groups run on those files, finite. Upstream: the model lookup of `llm_db` 2026.11.0; Anthropic's token-counting page and tool-use table as documented, each named with the date read. Assumption, not proved: no request gives more than three reported tokens for each canonical byte, and OpenRouter passes the request body and Anthropic's `usage` on unchanged. Cure law: none. The rule is one product and one sum, and the claim is about a provider; tests only. Telemetry, Config and Control are not applicable to this pure function; the manifest says why.

Run the Piece tests, then `mix check --piece "$(git merge-base origin/main HEAD)"` and `git diff --check`. One independent review checks this body, the exact diff and needless features.
