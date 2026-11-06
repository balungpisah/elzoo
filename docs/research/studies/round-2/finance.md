# Elzoo study — Finance data, trading and open-finance clients

Unit: `finance`. Observed 2026-11-06 against balungpisah/elzoo `main` @ bf16422.
Compared against `delivery/data-stream`, `integration/http`, `domain/money`, C9
metering (`domain/metering`, `domain/quota`), and the GOAL.md/AGENTS.md rule that
the catalogue carries reusable Pieces, not product features. Read-only study:
nothing executed, vendored or copied; file:line links point at the pinned revision.

Pinning method: Hex release metadata/tarball fetched per package; the source repo
was searched for a tag or, where none exists, for the commit whose `lib/` is
byte-identical to the tarball and precedes the Hex publish time. Hex checksums
are recorded in Open questions where relevant.

## Summary table

| Package | Pinned SHA | License | Last commit (pin / main tip) | Verdict | One line |
| --- | --- | --- | --- | --- | --- |
| theory_craft 0.1.0-dev (Elixir) | [a19d678](https://github.com/theorycraft-trading/theory_craft/tree/a19d67839735a25274494461edb9f74973603343) (no release tag; `lib/` identical to tarball) | Apache-2.0 | 2025-12-26 / 2026-02-16 | **distill** | Market-data GenStage topology; take two join/completeness design tests for `delivery/aggregation` and `delivery/data-stream`, adopt nothing |
| quant 0.1.0-alpha.1 (Elixir) | [463c70d](https://github.com/the-nerd-company/quant/tree/463c70d228cf7a62ceac3bad83fdd0959c9c28bf) (no tag; `lib/` identical to tarball) | **CC-BY-NC-4.0 — not adoptable** | 2025-10-17 / 2026-08-22 | **skip** | Non-commercial license; provider-schema ideas already stated in C9/`integration/search-data` reasons; only a negative example for ELZ-022's split test |
| pluggy_ai 0.1.1 (Elixir) | [a0d3349](https://github.com/fellipessanha/pluggy_ai_ex/tree/a0d334941af63a82b019a979178bd863c06d133d) = tag v0.1.1 | MIT (LICENSE.txt is the unfilled template "Copyright (c) [year] [fullname]") | 2026-06-08 / 2026-07-20 | **distill** | Thin Req client for one Brazilian open-finance vendor; distill the auth-retry re-dispatch case into ELZ-023 and the wire-key atom minting case into ELZ-011 |
| ursatoro 1.0.1 (Gleam) | [722aaed](https://github.com/GG-O-BP/ursatoro/tree/722aaed253b7d6748ef1a726b553562e14997e8e) = tag v1.0.1 | BlueOak-1.0.0 | 2026-03-22 / same | **skip** | Technical-indicator math over candles; a product feature, no Elzoo capability touched; one boundary lesson noted under skipped mechanisms |

No package is an adopt-candidate for any deferred/planned handle. No idea in this
unit earns a new Piece or a 6-step admission record: each distilled item is a
Contract sentence or dangerous-failure test on an existing handle (ELZ-006,
ELZ-011, ELZ-023, `delivery/aggregation`, `delivery/data-stream`).

## theory_craft — Observations (2026-11-06)

Package facts: Hex 0.1.0-dev published 2025-12-26T09:03Z; the repo has no
release tag, and `lib/` at a19d678 (08:56Z) and 456953b (09:03:43Z, README typo)
both match the tarball, so a19d678 is pinned. Runtime deps: `nimble_csv ~>1.3`,
`nimble_parsec ~>1.4`, `gen_stage ~>1.3`; ships an OTP `Application`
([mix.exs](https://github.com/theorycraft-trading/theory_craft/blob/a19d67839735a25274494461edb9f74973603343/mix.exs#L28-L31)).
One author (35/36 commits). The tagline says "backtesting and execution engine"
but at the pin only the `MarketSource` data pipeline exists; strategy logic was
removed the same day (2c8891b) and there is no order/broker/execution code.
README still says "not yet available on Hex". CHANGELOG has only `[Unreleased]`.

| Observed source | What it exposes | Elzoo capability / existing coverage |
| --- | --- | --- |
| [market_event.ex#L51](https://github.com/theorycraft-trading/theory_craft/blob/a19d67839735a25274494461edb9f74973603343/lib/theory_craft/market_source/market_event.ex#L51), [#L115-L118](https://github.com/theorycraft-trading/theory_craft/blob/a19d67839735a25274494461edb9f74973603343/lib/theory_craft/market_source/market_event.ex#L115-L118) | One envelope `{time, source, data: %{name => Tick\|Bar\|IndicatorValue}}`; accessors `raise` on missing names | `core/envelope` already exists (ELZ-003). A product record with raising accessors is not reusable; nothing to take |
| [data_feed.ex#L184](https://github.com/theorycraft-trading/theory_craft/blob/a19d67839735a25274494461edb9f74973603343/lib/theory_craft/market_source/data_feed.ex#L184), [data_feed_stage.ex#L204-L209](https://github.com/theorycraft-trading/theory_craft/blob/a19d67839735a25274494461edb9f74973603343/lib/theory_craft/market_source/stages/data_feed_stage.ex#L204-L209) | `stream/1 :: {:ok, Enumerable} \| {:error, _}` behaviour wrapped by `GenStage.from_enumerable` with `on_cancel: :stop`, `demand: :accumulate`, `DemandDispatcher max_demand 1000` | `delivery/data-stream` (deferred: bounded buffers, cancellation, close/reconnect). This is the ready Enum/Stream recipe behind a GenStage producer: in-process pull, no reconnect, no byte transport. Confirms the catalogue reason "distinct from the ready Enum/Stream recipe"; no gap filled |
| [aggregator_stage.ex#L224](https://github.com/theorycraft-trading/theory_craft/blob/a19d67839735a25274494461edb9f74973603343/lib/theory_craft/market_source/stages/aggregator_stage.ex#L224), [#L235](https://github.com/theorycraft-trading/theory_craft/blob/a19d67839735a25274494461edb9f74973603343/lib/theory_craft/market_source/stages/aggregator_stage.ex#L235), [#L247-L278](https://github.com/theorycraft-trading/theory_craft/blob/a19d67839735a25274494461edb9f74973603343/lib/theory_craft/market_source/stages/aggregator_stage.ex#L247-L278) | N-producer join: per-producer list buffers (`buffer ++ events`, unbounded), emit `min(buffer sizes)` events by **positional** `Enum.zip` and `Map.merge` of `data`; re-ask all producers only when all buffers are level; manual demand per producer ([#L160-L162](https://github.com/theorycraft-trading/theory_craft/blob/a19d67839735a25274494461edb9f74973603343/lib/theory_craft/market_source/stages/aggregator_stage.ex#L160-L162)) | `delivery/aggregation` (C5/C6 result correlation). Correctness depends on every producer emitting exactly one output per input in order — an assumption of the fan-out topology, never checked against `time`. Elzoo covers aggregation only as a planned handle; this is a negative design test, not a mechanism to reuse |
| [stage_helpers.ex#L121-L122](https://github.com/theorycraft-trading/theory_craft/blob/a19d67839735a25274494461edb9f74973603343/lib/theory_craft/market_source/stage_helpers.ex#L121-L122) | Stage-level outgoing buffer defaults `buffer_size 10000`, `buffer_keep :last` (passed through the stage init options; GenStage discards events beyond the buffer, oldest first, with only a log warning) | `delivery/backpressure` (ELZ-006 already requires any shed/drop policy to name the durable state from which dropped items are reconstructable, tasks/ELZ-006 lines 27-29, 41-42). Market ticks are not reconstructable; this is exactly the silent-loss case the Contract forbids |
| [bar_aggregator_stage.ex#L6-L42](https://github.com/theorycraft-trading/theory_craft/blob/a19d67839735a25274494461edb9f74973603343/lib/theory_craft/market_source/stages/bar_aggregator_stage.ex#L6-L42), [#L151](https://github.com/theorycraft-trading/theory_craft/blob/a19d67839735a25274494461edb9f74973603343/lib/theory_craft/market_source/stages/bar_aggregator_stage.ex#L151), [#L384-L403](https://github.com/theorycraft-trading/theory_craft/blob/a19d67839735a25274494461edb9f74973603343/lib/theory_craft/market_source/stages/bar_aggregator_stage.ex#L384-L403) | Incomplete windows carry an in-band `new_bar?` flag; a completed bar is emitted only when its successor opens; stored tuple tracks `already_emitted?` | `delivery/data-stream` / C7 "partial output is marked partial". The marker idea is sound; the close-on-successor rule means the final window has no emit trigger at end of stream (see Open questions) |
| [processor.ex#L108](https://github.com/theorycraft-trading/theory_craft/blob/a19d67839735a25274494461edb9f74973603343/lib/theory_craft/market_source/processor.ex#L108), [#L169](https://github.com/theorycraft-trading/theory_craft/blob/a19d67839735a25274494461edb9f74973603343/lib/theory_craft/market_source/processor.ex#L169) | `init/1` + `next(event, state)` behaviour, run inside a GenStage producer_consumer | Same shape as `core/operator` behind `runtime/unit` (ready). Already covered; no gap |
| [tick.ex#L12-L15](https://github.com/theorycraft-trading/theory_craft/blob/a19d67839735a25274494461edb9f74973603343/lib/theory_craft/market_source/tick.ex#L12-L15), [bar.ex#L22-L25](https://github.com/theorycraft-trading/theory_craft/blob/a19d67839735a25274494461edb9f74973603343/lib/theory_craft/market_source/bar.ex#L22-L25), [resample_processor.ex#L27](https://github.com/theorycraft-trading/theory_craft/blob/a19d67839735a25274494461edb9f74973603343/lib/theory_craft/market_source/processors/resample_processor.ex#L27) | Prices/volumes are `float() \| nil`; missing volume defaults to a fake 1.0 per tick | `domain/money`/`domain/metering`: contradicts the catalogue's "missing usage is unknown rather than zero" and the ex_money/Decimal direction. Negative example only |

Upstream reuse as-is: license fine (Apache-2.0); dependency weight small; but a
`-dev` release from a single maintainer with no tagged release, an OTP
Application in a library, and a product domain (ticks/bars/indicators) that no
coverage case C1-C9 needs. Not an adoption candidate for any handle.

### theory_craft — Proposals

1. `delivery/aggregation` (planned; C5 result correlation, C6 collect results) —
   design test to add when its task body is written: *"A join across N
   producers correlates by an explicit key carried in the Envelope (run/attempt
   or occurrence identity), never by arrival position. Test: one producer emits
   two outputs for one input (or drops one); the join must surface a
   correlation error, not merge neighbours."* Rationale: aggregator_stage.ex
   L247-L278 above.
2. `delivery/backpressure` (ELZ-006) — dangerous-failure case for its existing
   shedding rule: *"A stage-level drop-oldest buffer (e.g. GenStage
   `buffer_keep: :last`) in front of a consumer whose inputs are not
   reconstructable is silent loss; the Contract must either bound demand
   (pull) or name the durable source."* ELZ-006 already states the rule;
   this is one concrete test input, not a new Contract.
3. `delivery/data-stream` (deferred; C7/C8) — two Contract sentences for its
   future admission record: *"Partial results carry an explicit in-band
   completeness marker distinct from the payload"* and *"A window/segment
   that closes only when its successor opens must define an end-of-stream and
   cancellation flush, otherwise the last segment is never delivered."*

## quant — Observations (2026-11-06)

Package facts: Hex 0.1.0-alpha.1 published 2025-10-17T01:45Z, license
`CC-BY-NC-4.0` in both Hex metadata and
[LICENSE](https://github.com/the-nerd-company/quant/blob/463c70d228cf7a62ceac3bad83fdd0959c9c28bf/LICENSE)
("Creative Commons Attribution-NonCommercial 4.0", © 2025 Guillaume Dott). No
tag; `lib/` at 463c70d-554c6b9 matches the tarball; 463c70d precedes publish.
Main tip (3b43d6c, 2026-08-22) has diverged (cache layer, provider changes).
Runtime deps: `explorer ~>0.12`, `nx ~>0.10`, `decimal ~>3.1`, `telemetry`,
`certifi`; test dep `pythonx`. 14.8k lines across `Quant.Explorer` (providers),
`Quant.Math` (indicators), `Quant.Strategy` (backtest/orders). The repo's own
AGENTS.md project layout lists "LICENSE # MIT License" while the shipped file
is CC-BY-NC; the shipped file governs.

**License conflict (explicit):** CC-BY-NC-4.0 forbids commercial use and is
not an open-source license; it is not adoptable, forkable or vendorable in an
Apache-2.0 catalogue under docs/development/08-upstream-and-forks.md. Only
prose observations were taken; no code or data shapes were copied.

| Observed source | What it exposes | Elzoo capability / existing coverage |
| --- | --- | --- |
| [providers/behaviour.ex#L42-L93](https://github.com/the-nerd-company/quant/blob/463c70d228cf7a62ceac3bad83fdd0959c9c28bf/lib/quant_explorer/providers/behaviour.ex#L42-L93), [schema_standardizer.ex#L115](https://github.com/the-nerd-company/quant/blob/463c70d228cf7a62ceac3bad83fdd0959c9c28bf/lib/quant_explorer/schema_standardizer.ex#L115), [#L177-L200](https://github.com/the-nerd-company/quant/blob/463c70d228cf7a62ceac3bad83fdd0959c9c28bf/lib/quant_explorer/schema_standardizer.ex#L177-L200), [#L399](https://github.com/the-nerd-company/quant/blob/463c70d228cf7a62ceac3bad83fdd0959c9c28bf/lib/quant_explorer/schema_standardizer.ex#L399), [#L605](https://github.com/the-nerd-company/quant/blob/463c70d228cf7a62ceac3bad83fdd0959c9c28bf/lib/quant_explorer/schema_standardizer.ex#L605) | Universal `history/quote/info/search` behaviour; per-provider interval/period tables; a standard column list enforced by adding missing columns (nil-filled) and reordering; `validate_provider_support` before the call | `integration/search-data` (deferred, "product adapters; no generic data engine") and the C9 model-routing sentence "no assumption that similarly named models support identical …". Already covered as Contract prose; the shared DataFrame schema here is precisely the "shared schema does not establish matching semantics" warning in AGENTS.md |
| [data_transformer.ex#L91-L115](https://github.com/the-nerd-company/quant/blob/463c70d228cf7a62ceac3bad83fdd0959c9c28bf/lib/quant_explorer/data_transformer.ex#L91-L115), [#L121-L131](https://github.com/the-nerd-company/quant/blob/463c70d228cf7a62ceac3bad83fdd0959c9c28bf/lib/quant_explorer/data_transformer.ex#L121-L131) | Timestamps and numbers normalise to `nil` on parse failure; prices become `float` via `Float.parse` although `decimal` is a declared dependency | `domain/money` (deferred, Decimal/ex_money direction). Negative example: Elzoo's catalogue reason already requires explicit units and precision |
| [rate_limiter.ex#L57-L74](https://github.com/the-nerd-company/quant/blob/463c70d228cf7a62ceac3bad83fdd0959c9c28bf/lib/quant_explorer/rate_limiter.ex#L57-L74), [ets_backend.ex#L59-L75](https://github.com/the-nerd-company/quant/blob/463c70d228cf7a62ceac3bad83fdd0959c9c28bf/lib/quant_explorer/rate_limiting/ets_backend.ex#L59-L75), [#L78-L89](https://github.com/the-nerd-company/quant/blob/463c70d228cf7a62ceac3bad83fdd0959c9c28bf/lib/quant_explorer/rate_limiting/ets_backend.ex#L78-L89) | A singleton GenServer serialises `check_and_consume` (one step), but also exposes `check_limit` and a fire-and-forget `consume_limit` cast as separate public halves; per-provider/endpoint limits in [provider_config.ex#L15-L30](https://github.com/the-nerd-company/quant/blob/463c70d228cf7a62ceac3bad83fdd0959c9c28bf/lib/quant_explorer/rate_limiting/provider_config.ex#L15-L30) | `domain/quota` vs rate limit (capability-model distinctions table) and ELZ-022 step 4 "check and reserve cannot be two callable halves". Elzoo already states this; quant is a concrete instance of the anti-pattern the split test rejects. hammer remains the named rate-limit candidate |
| [http_client.ex#L60-L96](https://github.com/the-nerd-company/quant/blob/463c70d228cf7a62ceac3bad83fdd0959c9c28bf/lib/quant_explorer/http_client.ex#L60-L96) | `:httpc` wrapper retrying any `{:error, _}` with `:timer.sleep` and doubled delay, independent of method or idempotency | `integration/http` (ready: "Use Req directly … explicit retry") and `delivery/retry-timeout`. Elzoo's recipe already makes retry an explicit caller choice; nothing to take |

### quant — Proposals

None. Verdict **skip**, dated 2026-11-06: CC-BY-NC-4.0 is incompatible with the
Apache-2.0 catalogue and the MIT-fork policy, and every reusable idea (provider
capability validation before dispatch, missing value = unknown, one-step
check-and-consume) is already written in C9, `domain/money`'s reason or ELZ-022.
If a future `integration/search-data` task wants a provider-normalisation
reference, cite the behaviour/standardizer rows above as prose only.

## pluggy_ai — Observations (2026-11-06)

Package facts: Hex 0.1.1 published 2026-06-08T17:33Z, MIT in metadata; the
shipped [LICENSE.txt](https://github.com/fellipessanha/pluggy_ai_ex/blob/a0d334941af63a82b019a979178bd863c06d133d/LICENSE.txt)
is the GitHub template with `[year] [fullname]` unfilled. Hex `links` is empty;
`mix.exs` names https://github.com/fellipessanha/pluggy_ai_ex, whose tag
`v0.1.1` = a0d3349 has `lib/` byte-identical to the tarball. One author
(44 commits); main tip 1117f84 (2026-07-20). Runtime deps: `req ~>0.5`,
**`plug ~>1.16` (required, not optional)**, optional `kino`/`phoenix_live_view`.
3.0k lines; tests are Req.Test/Bandit-stubbed happy paths plus auth retry
(`test/pluggy/auth_test.exs`: "retries once on 401 and succeeds", "does not
retry more than once"); no transport-error, timeout or 429 scenario found
(`grep -i "transport\|timeout\|429"` over `test/pluggy` returns nothing).
Pluggy is one Brazilian open-finance aggregator (accounts, transactions,
investments, Pix payment requests/intents, boletos).

| Observed source | What it exposes | Elzoo capability / existing coverage |
| --- | --- | --- |
| [client.ex#L37-L66](https://github.com/fellipessanha/pluggy_ai_ex/blob/a0d334941af63a82b019a979178bd863c06d133d/lib/pluggy/client.ex#L37-L66), [http.ex#L172-L191](https://github.com/fellipessanha/pluggy_ai_ex/blob/a0d334941af63a82b019a979178bd863c06d133d/lib/pluggy/http.ex#L172-L191), [error.ex#L14-L20](https://github.com/fellipessanha/pluggy_ai_ex/blob/a0d334941af63a82b019a979178bd863c06d133d/lib/pluggy/error.ex#L14-L20) | `Req.new` + plugin steps; 204→`{:ok,nil}`, 2xx→body, non-2xx map→`Error.from_response`, `Req.TransportError`→`code: :transport`; no retry option set, no idempotency header, no 429 handling | `integration/http` (ready Req recipe) covers the transport; `integration/payments` (deferred) requires "stable idempotency keys and reconciliation", which this client does not provide. Pluggy's own API carries `clientPaymentId` on payment requests (design-docs/important_context.md L157) but the client never derives or enforces it |
| [auth.ex#L47-L62](https://github.com/fellipessanha/pluggy_ai_ex/blob/a0d334941af63a82b019a979178bd863c06d133d/lib/pluggy/auth.ex#L47-L62), [#L65-L89](https://github.com/fellipessanha/pluggy_ai_ex/blob/a0d334941af63a82b019a979178bd863c06d133d/lib/pluggy/auth.ex#L65-L89) | Request step fetches/caches an API key (no expiry tracked); on auth failure it **synthesises a fake 401 response**; response step on any 401 re-authenticates once and **re-runs the whole request via `Req.Request.run_request`**, including POST bodies | `delivery/effect-intent` (ELZ-023) and C3's "a timed-out request is unknown until reconciled". A transparent auth retry at the transport layer re-dispatches an irreversible Effect (payment intent) without the intent store knowing a second attempt happened — the dangerous path ELZ-023 step 5 should name explicitly. The repo's design doc (design_docs.md L415) argues concurrent re-auth is harmless because `POST /auth` is idempotent; the re-run of the *original* request is not discussed |
| [key_transform.ex#L19-L29](https://github.com/fellipessanha/pluggy_ai_ex/blob/a0d334941af63a82b019a979178bd863c06d133d/lib/pluggy/key_transform.ex#L19-L29), [client.ex#L52](https://github.com/fellipessanha/pluggy_ai_ex/blob/a0d334941af63a82b019a979178bd863c06d133d/lib/pluggy/client.ex#L52) | Every response key is `String.to_atom`'d recursively as a response step | ELZ-011 Adapter design tests already say "no atom minted from a wire string" (Raxol row, orchestration-references.md). Negative example; also the reason this client cannot sit inside an Elzoo Adapter unchanged |
| [http.ex#L111-L126](https://github.com/fellipessanha/pluggy_ai_ex/blob/a0d334941af63a82b019a979178bd863c06d133d/lib/pluggy/http.ex#L111-L126), [#L146-L166](https://github.com/fellipessanha/pluggy_ai_ex/blob/a0d334941af63a82b019a979178bd863c06d133d/lib/pluggy/http.ex#L146-L166), [unwrap.ex#L188-L211](https://github.com/fellipessanha/pluggy_ai_ex/blob/a0d334941af63a82b019a979178bd863c06d133d/lib/pluggy/unwrap.ex#L188-L211) | Page/total_pages cursor as a struct holding a fetcher closure; `Stream.resource` pagination that `raise`s mid-stream on error; a Req response step that rewrites the body into results/all/stream | `delivery/stream-combinators` (ready) plus `delivery/data-stream`: a closure-holding cursor is not resumable across processes or restarts, and raising inside a lazy stream loses the pages already consumed. Confirms the data-stream reason ("bounded buffers, cancellation, close/reconnect"); no mechanism to reuse |
| [webhooks.ex](https://github.com/fellipessanha/pluggy_ai_ex/blob/a0d334941af63a82b019a979178bd863c06d133d/lib/pluggy/webhooks.ex), [session.ex#L60-L72](https://github.com/fellipessanha/pluggy_ai_ex/blob/a0d334941af63a82b019a979178bd863c06d133d/lib/pluggy/session.ex#L60-L72) | Webhook CRUD only (no signature verification, no event dedup); session caches a connect token in a struct without expiry | `integration/payments` reason ("webhook verification") and `delivery/idempotency` (C3 duplicate/out-of-order webhooks). Gaps remain the consumer's; the client adds nothing here |

Upstream reuse as-is: MIT is fork-permitted under balungpisah, but (a) the
notice is defective and would have to be fixed upstream or recorded before any
copy; (b) `plug` is a hard dependency for an HTTP client whose Plug use is the
optional widget; (c) `String.to_atom` on wire keys and the transparent POST
re-run violate two Elzoo design tests, so "exercise its exact boundary" would
fail before promotion. No coverage case names Pluggy or Brazilian open finance;
`integration/payments` still says "choose an actual provider" first. Not an
adoption candidate.

### pluggy_ai — Proposals

1. `delivery/effect-intent` (ELZ-023, step 5 dangerous paths; C3/C9) — add:
   *"A transport-layer plugin (auth refresh, redirect, library retry) re-sends
   the dispatched request without the intent lifecycle observing a second
   attempt. Test: a stubbed provider returns 401 then 200 for one payment
   intent; the Adapter must either disable transparent re-run for
   non-idempotent Effects or record a second Attempt under the same intent
   before the second send."* Observed in auth.ex L65-L89.
2. `runtime/adapter` / `core/envelope` consumers (ELZ-011) — reuse the existing
   "no atom minted from a wire string" test; cite key_transform.ex L19-L29 as a
   second source when the task body is published. No new text needed.
3. `integration/payments` (deferred) — one Contract sentence for its eventual
   admission record: *"The provider's client-supplied payment identifier
   (e.g. Pluggy `clientPaymentId`) is derived from Elzoo's logical request
   identity by the Adapter, never generated per attempt; a vendor SDK that
   does not expose it cannot satisfy this Piece."*
4. `integration/http` (ready) — no change. The ready recipe's "explicit retry
   … choices" wording already excludes hidden retry steps; keep it.

## ursatoro — Observations (2026-11-06)

Package facts: Hex 1.0.1 published 2026-03-22T14:51Z; tag `v1.0.1` = 722aaed,
also the main tip; 8 commits, one author; license
[Blue Oak Model License 1.0.0](https://github.com/GG-O-BP/ursatoro/blob/722aaed253b7d6748ef1a726b553562e14997e8e/LICENSE)
(permissive, OSI-approved; outside the Apache/MIT cases named by the fork
policy, so its own terms would need recording). Deps: `gleam_stdlib`,
`bigdecimal >=1.4`, `gleam_deque`, `gleam_community_maths`. 1.9k lines.

| Observed source | What it exposes | Elzoo capability / existing coverage |
| --- | --- | --- |
| [ursatoro.gleam#L10-L202](https://github.com/GG-O-BP/ursatoro/blob/722aaed253b7d6748ef1a726b553562e14997e8e/src/ursatoro.gleam#L10-L202), [util.gleam#L13-L17](https://github.com/GG-O-BP/ursatoro/blob/722aaed253b7d6748ef1a726b553562e14997e8e/src/ursatoro/util.gleam#L13-L17) | Pure batch functions `List(Candle) -> Result(List(Float), IndicatorError)` with `InsufficientData/InvalidPeriod/DivisionByZero`; one streaming state (`kalman_update`, [filter.gleam#L15-L36](https://github.com/GG-O-BP/ursatoro/blob/722aaed253b7d6748ef1a726b553562e14997e8e/src/ursatoro/filter.gleam#L15-L36)) | None of C1-C9. Technical indicators are a trading-product feature (GOAL.md: catalogue carries Pieces, not product features). Pure total functions with typed errors are the shape Elzoo already prescribes for Operators |
| [candle.gleam#L3-L27](https://github.com/GG-O-BP/ursatoro/blob/722aaed253b7d6748ef1a726b553562e14997e8e/src/ursatoro/candle.gleam#L3-L27), [util.gleam#L45-L57](https://github.com/GG-O-BP/ursatoro/blob/722aaed253b7d6748ef1a726b553562e14997e8e/src/ursatoro/util.gleam#L45-L57), [#L77-L84](https://github.com/GG-O-BP/ursatoro/blob/722aaed253b7d6748ef1a726b553562e14997e8e/src/ursatoro/util.gleam#L77-L84) | Opaque `Candle` holds `BigDecimal` but is constructed only from `Float`; results are converted back to `Float`, with a silent `0.0` fallback on parse failure; division uses a fixed scale 10 and HalfUp | `domain/money` (deferred): the README's "all internal calculations use bigdecimal … prevents floating-point drift" claim is bounded by float in/out at both boundaries. A boundary lesson for the money Contract (units/precision must hold at the interface, not only inside), already implied by its catalogue reason |

Upstream reuse: no Elzoo capability needs OHLCV indicators; adopting a Gleam
dependency contradicts the ELZ-017 boundary ("does not justify … imposing
another toolchain on backend consumers"). Not an adoption candidate.

### ursatoro — Proposals

None. Verdict **skip**, dated 2026-11-06: product-domain math with no coverage
case, Gleam toolchain cost already ruled out for backend Pieces by ELZ-017, and
the one transferable lesson (precision promised internally but lost at a Float
boundary) is already covered by `domain/money`'s reason text.

## Skipped mechanisms and why

- theory_craft `MarketSource` fluent builder → GenStage topology
  ([market_source.ex#L192-L752](https://github.com/theorycraft-trading/theory_craft/blob/a19d67839735a25274494461edb9f74973603343/lib/theory_craft/market_source.ex#L192-L752)):
  a product pipeline DSL; `runtime/unit` + Wiring already own topology in Elzoo
  and ADR-0005/AGENTS.md forbid adopting a framework as a mandatory host.
- theory_craft `ResampleProcessor` time alignment and `TimeFrame` parsing:
  calendar/market-session policy specific to trading; `delivery/time` covers
  Elzoo's needs.
- theory_craft CSV tick feed (`nimble_csv`): ordinary library usage, no Piece.
- quant `Quant.Strategy` backtest/order/signal/optimisation and `Quant.Math`:
  product features and, in any case, CC-BY-NC.
- quant Explorer/Nx DataFrame dependency: `integration/search-data` explicitly
  defers "dataframe/columnar/analytics … product adapters; no generic data
  engine in core".
- pluggy_ai Phoenix/Kino Connect widget and `priv/static/*.js`: UI surface;
  `ui/component` stays deferred per ELZ-017.
- pluggy_ai resource modules (accounts, transactions, boletos, smart transfers,
  payment customers/recipients/requests): thin path wrappers over `HTTP.get/post`
  with no translation of failure semantics; a wrapper earns no catalogue slot
  (capability-model step 3).
- ursatoro microstructure/HAR/Savitzky-Golay functions: numerical methods with
  no caller in C1-C9.

## Open questions

1. theory_craft end-of-stream flush: `BarAggregatorStage` emits a bar only when
   its successor opens (bar_aggregator_stage.ex L6-L42) and `AggregatorStage`
   stops when the last producer cancels (L173-L188). Whether the final stored
   bar is ever emitted on a finite feed was not verified (nothing executed);
   the proposal 3 sentence for `delivery/data-stream` stands regardless.
2. pluggy_ai license notice: Hex metadata says MIT but the shipped text is the
   unfilled template. If a future task ever considers this client, the fork
   policy's "keep upstream copyright notices" requirement cannot be met until
   upstream fills the notice. No action now.
3. Hex checksums recorded for provenance: pluggy_ai 0.1.1
   `767B9A7DEC90E2D451E1E22C8BCF75BB7F15EBEC746EEC4F013FAC88BAA6EA20` (from the
   tarball's CHECKSUM); theory_craft/quant/ursatoro tarballs were fetched and
   diffed against the repos but their outer checksums were not copied into
   this report.
4. Not verified: Pluggy's live API idempotency semantics for `clientPaymentId`
   (read only from the repo's design-docs, not from vendor documentation), and
   whether any C9-style provider in Elzoo's roadmap will require a Brazilian
   open-finance connector at all. Both are provider-selection questions for a
   future `integration/payments` task, not for this study.
