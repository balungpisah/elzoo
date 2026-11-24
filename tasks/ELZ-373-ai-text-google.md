# ELZ-373 — A Gemini API text provider for integration/ai-text over the locked req_llm, with tools, structured output and image input

- Phase: Wave 9 Level 2 (owner answers Q6 A and Q7 A of [the Wave 9 plan](../docs/plans/bot-platform-wave9.md#owner-answers-2026-11-24))
- Dependencies: ELZ-079, ELZ-364
- Release: V1B
- Output: new `integration/ai-text-google` Piece
- Change class: Piece-only
- Owned paths: `pieces/integration/ai-text-google/**`; its own `registry/catalogue.json` and `docs/plans/release-plan.json` rows (last commit, `AGENTS.md` section 3); the generated `LEDGER.md`, `docs/plans/views.md` and `docs/plans/dependencies.mmd`. No other Piece (not `integration/ai-text`, `integration/ai-model` or the two ready providers), no root test or helper, no `mix.exs`, `mix.lock` or CI.

## Outcome and boundary

A third provider of the `Elzoo.AiText.Provider` behaviour, for the Gemini API's `generateContent` with an API key, built as the two ready providers are: pure `translate/2` into a `req_llm` request of its `google` provider, `call/2` that makes exactly one HTTP exchange with retries and redirects off, `decode/2`, `classify_failure/1` and a status table, with stub evidence under the ELZ-087 rule ("stub only; no live API spend"). It gives `delivery/model-routing` (ELZ-369) a third vendor. The API key reaches it through ai-text's `credentials` Need, as for the ready providers; the host wires that Need to `integration/secrets`, so this Piece does not call it (the plan's dependency on ELZ-105 is dropped by coordinator check).

The Piece sends untrusted model input to a provider and parses its answers, as the ready providers do. It keeps the local small gate and gets one review at the depth of the ready provider Pieces.

## Facts on `main` that this task builds on

Checked at `main` `b9d1c9d5` and `deps/req_llm` 1.30.0. Confirm each before you start; if one differs, stop and comment on the issue.

- The behaviour (`pieces/integration/ai-text/lib/elzoo/ai_text/provider.ex`, lines 32–60): `capabilities/0` returns a map with `piece`, `provider`, `wire_surface`, `features` (members of `[:tools, :structured_output, :sampling, :stop_sequences, :cache_hint, :reasoning, :image_input]`), `reasoning`, `cache_ttls`, `convention: %{input_includes_cached: boolean}` and `options`; `translate(request, provider_config)` returns `{:ok, wire} | {:refused, atom}`; `call(wire, call_opts)` returns `{:ok, exchange} | {:transport, atom}`; `decode(exchange, request)` returns `{:ok, map} | {:failure, atom}`; `classify_failure/1` returns a tag. A provider tag outside `Elzoo.AiText.Outcome.provider_tags/0` becomes `adapter_error` (`lib/elzoo/ai_text/adapter.ex`, line 117). `retry_after` is kept as an integer of 0..86,400 seconds, only for `throttled` and `overloaded` (lines 119–120). The image part arrives as `%{type: :image, media_type: m, bytes: bytes}` (`lib/elzoo/ai_text.ex`, lines 273–282).
- The ready providers to copy from: `pieces/integration/ai-text-openai/lib/elzoo/ai_text/open_ai.ex` has a model table `@models` (line 34) and refuses another model `invalid_request` (lines 122–130); its `call/2` (lines 242–268) passes `api_key: call_opts.credential`, `max_retries: 0` and `req_http_options: [retry: false, plug: ...]`, runs `prepare_request` and `Req.request/1`; its status table is at lines 459–469 (400, 401, 403, 404, 413, 429 `throttled`, 503 `overloaded`, 504 `provider_timeout`, else `provider_error`). Its tests serve an in-process Req plug through `provider_config: %{plug: plug}` and run `Elzoo.AiText.Conformance.scenarios/0` (O1, lines 232–245) against a pinned schema.
- `ReqLLM.Providers.Google` (`deps/req_llm/lib/req_llm/providers/google.ex`): `default_base_url: "https://generativelanguage.googleapis.com/v1beta"` (lines 90–93); `prepare_request(:chat, ...)` (lines 301–353) posts to `/models/<id>:generateContent`; the API key goes in the `x-goog-api-key` header by default (lines 602–678, 150–156); `attach/3` also attaches `ReqLLM.Step.Retry` and `ReqLLM.Step.Error` (lines 669–670); a non-200 answer is a generic `ReqLLM.Error.API.Response` with the status and body (lines 1762–1771), so the status table is this Piece's. A user message of a text part and an image part encodes as `{"contents":[{"parts":[{"text":...},{"inline_data":{"data":<base64>,"mime_type":"image/png"}}],"role":"user"}], ...}` (read by a probe of `prepare_request` at `b9d1c9d5`; code path at lines 2609–2622, 3163–3172 and 3230–3248).
- `LLMDB` lists `gemini-3.8-flash` with `status: active`, input modalities `[:text, :image, :video, :audio, :pdf]`, tools enabled and native JSON schema output (read through `ReqLLM.model("google:gemini-3.8-flash")` at `b9d1c9d5`).

## Interface

`Elzoo.AiText.Google` (`lib/elzoo/ai_text/google.ex`) implements the behaviour.

- **Models:** a table in the Piece, `gemini-3.8-flash` only, with its reasoning levels if the task evidences reasoning; another model is `{:refused, :invalid_request}`. Adding a model is a later change with its own evidence.
- **Capabilities:** `provider: "google"`, `wire_surface: "generate_content"`, `features` exactly the features the stub tests evidence on the wire, at least `:tools`, `:structured_output` and `:image_input`; ai-text refuses any other `unsupported_feature` before translation. `convention.input_includes_cached` as the API documents it.
- **`translate/2`:** system messages into the system instruction, user, assistant (with tool calls) and tool-result messages into contents, user parts in order with each image as inline data, tools as function declarations with the callback that refuses to run (as the ready providers do), the output schema as the JSON response schema. A shape the API cannot express exactly is refused `unsupported_feature`, never approximated. `provider_config` is `nil` or a map with `base_url` (HTTPS) and `plug` (tests), as the ready providers take it.
- **`call/2`:** one exchange, `max_retries: 0`, `retry: false`, redirects off, the key only in the `x-goog-api-key` header, within ai-text's `receive_timeout_ms`.
- **Status table:** 400 `provider_invalid_request`, 401 `authentication_failed`, 403 `permission_denied`, 404 `not_found`, 413 `provider_too_large`, 429 `throttled`, 503 `overloaded`, 504 `provider_timeout`, every other status `provider_error`, with any row that Gemini's documented error codes contradict corrected and recorded in the README with the fetch date (for example an invalid key answered 400 `INVALID_ARGUMENT` with reason `API_KEY_INVALID` is `authentication_failed`). `retry_after` for 429 and 503 comes from a `Retry-After` header when there is one, else from the documented `google.rpc.RetryInfo` `retryDelay` of the error body; the README names which forms it reads.
- **Usage:** the documented `usageMetadata` counters into ai-model's units; a counter not reported is `:unknown`.
- **Evidence:** a request schema hand-derived from the Gemini API reference for `generateContent` (fetched date recorded) under `test/fixtures/google/`, used to validate every captured stub request, as the ready providers' fixtures are.

`piece.json` declares the dependency `integration/ai-text` (as `integration/ai-text-openai` does), the providers that `integration/ai-text-openai`'s `piece.json` lists (`req_llm` and its closure, `jsv` for the schema tests, `plug`, `elixir`, `otp`), telemetry, config and control as the ready providers declare them, and the stub claims.

## Kept open (owner's "no corner" rule)

- *Vertex AI* with a service account (after a JWT client authentication in `integration/oauth-client`); *streaming*; *batch*; *more models* with their own evidence; *reasoning, cache hints, sampling and stop sequences* where this task does not evidence them.

## Acceptance

The ai-text conformance kit against the stub:

1. Every scenario of `Conformance.scenarios/0` (its 15 scenarios need only `:tools` and `:structured_output`, `lib/elzoo/ai_text/conformance.ex` lines 58–78) and `:image_input` of `image_scenarios/0` pass, as A1 and O1 of the ready providers run them; a request needing an undeclared feature (for example `stop_sequences` when it is not declared) is refused `unsupported_feature` by ai-text with no request at the stub. Each captured request validates against the fixture schema, carries the key only in `x-goog-api-key`, and the image scenario's inline data decodes to the PNG.
2. Text, tools (a tool proposal decoded as inert data), structured output (a valid and an invalid answer), and images of each media type of the set.
3. Each status of the table, a 429 with `Retry-After`, a 429 with a `retryDelay` body and one with neither (`retry_after: nil`), a timeout, a transport error and a malformed body each give their outcome; exactly one request reaches the stub in each (no hidden retry).
4. A model outside the table is `invalid_request` before any request.
5. No API key in any outcome, error, `inspect` or captured log line (checked on the terms).
6. Negative control, restored before the final gates: map 429 to an unknown outcome (case 3's throttled case fails).

Run the Piece tests and the new-Piece small gate locally (`mix check --piece "$(git merge-base origin/main HEAD)"`), the roadmap and claims checks and the diff check. One review, the exact-head hosted check and the merge queue are required.

## Limits to state

Stub evidence only: conformance to the documented format as fetched, not live behaviour, quality, latency, safety filtering or prices. One model, one API surface, an API key only.
