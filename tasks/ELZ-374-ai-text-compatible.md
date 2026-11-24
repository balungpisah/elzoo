# ELZ-374 — An OpenAI-compatible Chat Completions provider for integration/ai-text at an egress-checked HTTPS base URL, with a host-declared model table

- Phase: Wave 9 Level 2 (owner answer Q6 A of [the Wave 9 plan](../docs/plans/bot-platform-wave9.md#owner-answers-2026-11-24))
- Dependencies: ELZ-079, ELZ-087, ELZ-271, ELZ-362, ELZ-364
- Release: V1B
- Output: new `integration/ai-text-compatible` Piece
- Change class: Piece-only
- Owned paths: `pieces/integration/ai-text-compatible/**`; its own `registry/catalogue.json` and `docs/plans/release-plan.json` rows (last commit, `AGENTS.md` section 3); the generated `LEDGER.md`, `docs/plans/views.md` and `docs/plans/dependencies.mmd`. No other Piece (not `integration/ai-text`, `integration/egress-policy` or `integration/ai-text-openai`), no root test or helper, no `mix.exs`, `mix.lock` or CI.

## Outcome and boundary

A provider of the `Elzoo.AiText.Provider` behaviour for the Chat Completions wire shape at one HTTPS base URL per binding, which the host or a tenant gives (a self-hosted or regional model). Because the URL may be a tenant's, it is admitted through `Elzoo.EgressPolicy.resolve/3` when the endpoint is built, and every call reaches only the checked addresses through a host transport Need that pins them, as `integration/webhook-out` does. Each model's features come from a host-declared table, and a feature that the table does not declare for the request's model is refused `unsupported_feature` before any byte. The API key reaches it through ai-text's `credentials` Need, as for the ready providers and ELZ-373, so this Piece does not call `integration/secrets` (the plan's dependency on ELZ-105 is dropped by coordinator check).

The Piece makes an egress decision on an untrusted URL, so it keeps the local small gate and gets the full review of the coordinator guide ("Reviewer by risk").

## Facts on `main` that this task builds on

Checked at `main` `b9d1c9d5` and `deps/req_llm` 1.30.0. Confirm each before you start; if one differs, stop and comment on the issue.

- The behaviour and ai-text's outcome rules as in ELZ-373's facts (`provider.ex` lines 32–60; `adapter.ex` lines 117–120; the image part at `ai_text.ex` lines 273–282). ai-text checks requested features against `capabilities().features` of the provider module (`ai_text.ex`, lines 217–221, 317–325) and calls `translate(request, provider_config)` with the Config's `provider_config` term (line 231), whose `translate/2` refusals `invalid_request | unsupported_feature | too_large` pass through (lines 235–239).
- `Elzoo.EgressPolicy` (`pieces/integration/egress-policy/lib/elzoo/egress_policy.ex`, lines 15–119): `resolve(url, policy, resolver)` returns `{:ok, %{host, port, addresses}}` with every address public, or `{:error, reason}` with `reason` in `:malformed | :scheme | :host | :not_allowed | :port | :dns_failed | :unavailable | :non_public_address`; the resolver Need is `(String.t() -> {:ok, [ip]} | {:error, :nxdomain} | {:error, :unavailable})`; every IP literal is refused. Its URL parse refuses only userinfo and a fragment (`parse/1`, line 145) and never a query, so a query and an `http` URL are this Piece's own shape checks. `integration/mcp-runtime` admits its URL the same way (`mcp_runtime.ex`, lines 105–121) and refuses a URL with a query itself (lines 66, 94–95).
- `integration/webhook-out`'s transport Need is "one-arity Need given `%{host, port, addresses}`, returning `{:ok, req_options}`" (`pieces/integration/webhook-out/README.md`, line 103). The Piece puts those options in `Req.new/1`, merges its own `retry: false`, `redirect: false` and timeouts, and never sets `connect_options`, since `Req.merge/2` would replace the host's (`lib/elzoo/webhook_out/adapter.ex`, lines 133–155; README lines 113–116, 307–309; README line 116: Req refuses `connect_options` beside a `finch` pool).
- `req_llm` 1.30.0: `ReqLLM.model(%{provider: :vllm, id: "<any id>"})` returns `{:ok, model}` for an id outside the catalogue, and `ReqLLM.Providers.VLLM.prepare_request(:chat, model, context, api_key: k, base_url: "https://.../v1", max_retries: 0)` builds a POST to `<base_url>/chat/completions` with `authorization: Bearer <key>` (read by a probe at `b9d1c9d5`; `deps/req_llm/lib/req_llm/providers/vllm.ex` uses the defaults at `provider/defaults.ex` lines 247–280, 640–661 and 1939–1948). req_llm always sets Req's `finch` option on the request it prepares; with `connect_options` from a transport Need beside it, `Req.request/1` raises "cannot set both :finch and :connect_options" in Req's Finch adapter, while a `plug` or another `adapter` replaces that adapter and does not raise (confirmed by a probe at review). An image part is encoded as `{"type": "image_url", "image_url": {"url": "data:<media type>;base64,<data>"}}` (`defaults.ex`, lines 1092–1109). The task names the path it uses in its README; if it uses another module of `req_llm`, it says why.
- The ready OpenAI provider's status table (`pieces/integration/ai-text-openai/lib/elzoo/ai_text/open_ai.ex`, lines 459–469) is the one this Piece takes: 400, 401, 403, 404, 413, 429 `throttled`, 503 `overloaded`, 504 `provider_timeout`, else `provider_error`.

## Interface

`Elzoo.AiText.Compatible` (`lib/elzoo/ai_text/compatible.ex`).

- `endpoint(opts)` builds the `provider_config` term. `opts` is a keyword list with exactly:
  - `base_url`: an `https` URL of 1..2,048 bytes with no userinfo, query or fragment, checked by this Piece before the egress check (another scheme, userinfo, a query, a fragment or a longer URL is `{:error, :invalid}` with no resolver call);
  - `policy`: an `%Elzoo.EgressPolicy{}` and `resolver`: its resolver Need;
  - `transport`: a one-arity Need given `%{host, port, addresses}` that returns `{:ok, req_options}`, the host's pinning of the checked addresses (production options, or a `Req.Test` plug in tests);
  - `models`: 1..64 maps `%{id, features}`, `id` 1..256 bytes of UTF-8 with no control character and unique, `features` a list of members of `[:tools, :structured_output, :stop_sequences, :sampling, :image_input]`.

  After its own checks it calls `EgressPolicy.resolve/3` once and returns `{:ok, endpoint}` or `{:error, {:egress, reason}}` or `{:error, :invalid}`; the endpoint holds the checked host, port and addresses, and `inspect` shows neither Need. The addresses are fixed for the endpoint's lifetime; a host that needs new ones builds a new endpoint and Config.
- `capabilities/0` declares the features the Piece can translate, `[:tools, :structured_output, :stop_sequences, :sampling, :image_input]`, `piece`, `provider: "openai-compatible"`, `wire_surface: "chat_completions"`, `reasoning: []`, `cache_ttls: []`, `convention: %{input_includes_cached: true}` (as the Chat Completions `usage` object documents it; the README cites the fetched reference) and `options: %{}`, so it passes `Provider.valid_capabilities?/1` (`provider.ex`, lines 51–58).
- `translate(request, endpoint)`: a model not in the table is `{:refused, :invalid_request}`; a request that needs a feature the table does not declare for its model is `{:refused, :unsupported_feature}`; a value that is not an endpoint is `{:refused, :invalid_request}`. Then the Chat Completions body, user parts in order with each image as a `data:` URL.
- `call(wire, call_opts)`: removes req_llm's own `finch` option from the prepared request (`Req.Request.drop_options/2`) so that the transport Need's options are the only connection options (its `connect_options`, its own `finch` pool, or a test `plug`), then the transport Need's options for the endpoint's target, then `retry: false`, `redirect: false` and ai-text's receive timeout, `max_retries: 0`, exactly one exchange, the key only in the `authorization` header; a transport Need that fails, raises or gives a non-keyword answer is `{:transport, :unavailable}` before any byte, and the README states that this is classified `transport` (unknown) by ai-text, since `call/2` cannot report an attested no-send.
- `decode/2` and the status table as the OpenAI provider's for Chat Completions; `retry_after` from a `Retry-After` header in seconds; usage counters from the documented `usage` object, unreported as `:unknown`.

`piece.json` declares the dependencies `integration/ai-text` and `integration/egress-policy`, the providers of `integration/ai-text-openai`'s `piece.json` (the `req_llm` closure, `jsv`, `plug`, `elixir`, `otp`), the Config of `endpoint/1` with its bounds, and the stub claims. The request schema is hand-derived from OpenAI's Chat Completions reference (fetched date recorded) under `test/fixtures/`; the README says that a compatible endpoint may differ from it and that only conformance to that shape is shown.

## Kept open (owner's "no corner" rule)

- *Per-endpoint quirks* as declared options; *reasoning and cache hints* per declared model; *streaming*; *a refresh of the checked addresses* inside one endpoint.

## Acceptance

Through a resolver double and the transport Need returning a `Req.Test` plug (no socket):

1. The conformance kit's `scenarios/0` and `image_scenarios/0` against the stub, for a model whose table entry declares `:tools`, `:structured_output` and `:image_input`; each captured request validates against the fixture schema and reaches the path `/chat/completions` under the base URL's path.
2. A feature the table does not declare for the model (tools, an output schema, image parts, stop sequences, sampling, each once) is `unsupported_feature` with no request at the stub, while the same request to a model that declares it is sent.
3. A model outside the table is `invalid_request` before any request.
4. `endpoint/1`: a base URL whose name the resolver double answers with a private address is `{:egress, :non_public_address}`; an IP literal, a name not in the policy and a resolver failure each give their egress reason; `http`, userinfo, a query, a fragment and 2,049 bytes are each `:invalid` with no resolver call; 64 models accepted and 65, a duplicate id and an unknown feature refused `:invalid`.
5. The transport Need gets exactly the checked host, port and addresses; a transport Need that raises gives `{:transport, :unavailable}` with no request at the stub. A transport Need that returns `connect_options: [hostname: h]` and a recording `adapter:` function (Req's adapter option, in place of the plug) gets one request whose options hold the host's `connect_options` and no `finch`.
6. Each status of the table, a 429 with and without `Retry-After`, a timeout and a malformed body; exactly one request in each.
7. No API key in an outcome, an error or `inspect` of the endpoint or the Config.
8. Negative controls, one at a time, each restored before the final gates: skip the model table's feature check (case 2's undeclared-feature case sends a request); keep req_llm's `finch` option (case 5's `connect_options` case fails).

Run the Piece tests and the new-Piece small gate locally (`mix check --piece "$(git merge-base origin/main HEAD)"`), the roadmap and claims checks and the diff check. The full independent review, the exact-head hosted check and the merge queue are required.

## Limits to state

The endpoint's actual behaviour is the host's or tenant's: stub evidence shows conformance to the documented Chat Completions shape only. The address pinning is the host's transport Need; the resolver, the policy and the model table are the host's. Addresses are checked when the endpoint is built, not per call. ai-text reads the image artifacts before `translate/2`, so a per-model refusal comes after those reads. The provider name `openai-compatible` is the same for every endpoint, so an outcome's provenance does not tell two endpoints apart; a host that routes between endpoints names each by its route candidate. No successful public connect is shown; the `finch` removal is shown by a recording adapter, not through Finch.
