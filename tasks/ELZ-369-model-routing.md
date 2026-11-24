# ELZ-369 — Pure model routing: the eligible candidates of a route in rank order, and the next step after each Attempt's outcome, with no fallback after an unknown outcome

- Phase: Wave 9 Level 2 (owner answers Q6 A and Q8 A of [the Wave 9 plan](../docs/plans/bot-platform-wave9.md#owner-answers-2026-11-24))
- Dependencies: ELZ-006, ELZ-033, ELZ-079, ELZ-272, ELZ-357
- Release: V1B
- Output: new `delivery/model-routing` Piece (replaces the proposal RC-25 for this output, as ELZ-347 replaced RC-11)
- Change class: Piece-only
- Owned paths: `pieces/delivery/model-routing/**`; in `registry/catalogue.json` the `delivery/model-routing` row and in `docs/plans/release-plan.json` its `entries` row (both in the last commit, `AGENTS.md` section 3); the generated `LEDGER.md`, `docs/plans/views.md` and `docs/plans/dependencies.mmd`. No other Piece (not `delivery/retry-timeout`, `domain/provider-data-policy`, `integration/ai-text` or `workflow/agent-loop`), no root test or helper, no `mix.exs`, `mix.lock` or CI.

## Outcome and boundary

One pure Piece in plain Elixir that decides two things for a host's model-call binding. `select/3` gives the candidates of a route that may take a request now, in rank order, and the reason each other candidate is left out. `after_failure/3` gives the next step after one Attempt's outcome: done, wait and send the same request to the same candidate again (only when nothing was sent), move to another candidate with a new Attempt, or stop. The Contract source is the `delivery/model-routing` section of the plan's "Level 2", under Q8 A: **no fallback after an unknown outcome**, so a request that may have reached a provider is never sent to a second one.

The Piece does no I/O, reads no clock and holds no state. A route holds candidate references only; each candidate's binding, credential Need and provider account are the host's, so no credential of one candidate can reach another's intent through this Piece. The caller is the host's model-call binding (the binding that runs `integration/ai-text` for a `model_call` action), not the pattern step: the binding waits a `{:retry_same, ms}` between its EffectIntent commands, and ends the action with its refusal after a `{:next, _}`, putting the candidate's ref in the outcome it gives back (`workflow/agent-loop`'s Attempts task, ELZ-376, reads it).

No durable state, I/O or concurrency: a low-risk Piece (`AGENTS.md` section 5). It may use the hosted `check-piece` run as its small-gate evidence and gets one light review.

## Facts on `main` that this task builds on

Checked at `main` `b9d1c9d5`. Confirm each before you start; if one differs, stop and comment on the issue.

- `Elzoo.RetryTimeout` (`pieces/delivery/retry-timeout/lib/elzoo/retry_timeout.ex`): `policy/1` (lines 21–55) takes a keyword list with `max_attempts` (≥ 1, default 3), `base_backoff_ms`, `max_backoff_ms` (`0 <= base <= cap`), `mode` (`:redispatch_forbidden | :redispatch_idempotent`), `jitter` (`:none | :full`) and `max_failure_delay_ms` (0..4,294,967,295, default 3,600,000), and returns `{:ok, policy}` or `{:error, reason}`. `decide(policy, attempt, class)` (lines 70–75) returns `{:ok, :settle | :retry | :permanent | :exhausted | :unresolved}`; `delay(policy, attempt, class, %{failure_delay_ms: nil | non_neg_integer, random: 0..4_294_967_295})` (lines 82–95, ELZ-357) returns `{:ok, ms}`; for the class `:retryable` a failure delay is never cut short (`max(fd, backoff)`, plus the jitter under `:full`). The class atoms are `:completed | :permanent | :retryable | :dispatched` (lines 5–10).
- `integration/ai-text` outcomes as its result sink gives them (`lib/elzoo/ai_text/adapter.ex`, lines 145–153 and 235–247): `{:completed, map}`, `{:refused, reason, %{retry_after: nil | 0..86_400}}` (`retry_after` in **seconds**) and `{:unknown, reason}`. Refused reasons (`lib/elzoo/ai_text/outcome.ex`, lines 32–84): `credentials_unavailable` and `input_unavailable` (the attested no-send tags, `Outcome.no_send/0`, line 51), `invalid_request`, `too_large`, `authentication_failed`, `permission_denied`, `not_found` (failed, dispatched, permanent), `throttled` and `overloaded` (failed, dispatched, retryable; Contract amendment 1: never sent again by default). Unknown reasons: `timeout`, `transport`, `malformed_response`, `provider_error`. `retry_after` is set only for `throttled` and `overloaded`. `unsupported_feature` is not an outcome: it is only an admission refusal, `{:error, {:refused, :unsupported_feature}}` of `Elzoo.AiText.admission/2` (`lib/elzoo/ai_text.ex`, lines 145–147), whose refusal set is `invalid_request | unsupported_feature | too_large | input_unavailable`.
- `Elzoo.AiText.Provider.features/0` returns `[:tools, :structured_output, :sampling, :stop_sequences, :cache_hint, :reasoning, :image_input]` (`lib/elzoo/ai_text/provider.ex`, lines 39–48).
- `Elzoo.ProviderDataPolicy.decide(policy, request)` (`pieces/domain/provider-data-policy/lib/elzoo/provider_data_policy.ex`, lines 20–104): the request has exactly `provider`, `region`, `retention` (each 1..64 bytes of UTF-8 with no control character) and `classes` (1..5 of `:public | :internal | :confidential | :pii | :secret`); it returns `:allow`, `{:deny, :secret | :provider | :class | :region | :retention}`, or `{:error, :policy | :request}`. Every result other than `:allow` is DENY.
- `delivery/circuit-breaker`'s `status/1` gives `mode` `:closed | :open | :half_open | :unavailable` and `cooldown_remaining_ms` on a local monotonic clock, with no timestamp (`pieces/delivery/circuit-breaker/lib/elzoo/circuit_breaker.ex`, lines 10, 144–156, 506–520); so the host stamps `observed_at_ms` itself. `delivery/rate-limit`'s `admit/4` refuses `{:refused, :tenant_rate | :principal_rate, retry_after_ms, state}` with a positive `retry_after_ms` (`pieces/delivery/rate-limit/lib/elzoo/rate_limit.ex`, lines 84–128). `workflow/budget`'s status gives `remaining`, a non-negative integer in the budget's unit (`pieces/workflow/budget/lib/elzoo/budget.ex`, lines 119–143). This Piece calls none of them: the host gives their values as facts, so the job does not depend on ELZ-100, ELZ-280 or ELZ-022 (a coordinator check of the plan's list).
- `core/selection` ranks Piece implementations by Port compatibility and refuses a tie in `select/2`; it has no capability, policy or health input, so it is not reused.
- No `pieces/delivery/model-routing` directory and no `Elzoo.ModelRouting` module exist; the catalogue row is `deferred` and the `entries` row names RC-25.

## Interface

`Elzoo.ModelRouting` (`lib/elzoo/model_routing.ex`), plain Elixir. Every refusal of a malformed input is a fixed error atom; nothing is raised for an input outside the shapes below.

- `new(route)` returns `{:ok, route}` or `{:error, :invalid_route}`. `route` is a map with exactly:
  - `id` (1..128 bytes of UTF-8 with no control character) and `version` (1..2^31−1);
  - `candidates`: 1..16 maps with exactly `ref` (1..64 bytes of `[a-z0-9_.-]`), `provider`, `region` and `retention` (each a `domain/provider-data-policy` text), `model_id` (1..256 bytes of UTF-8 with no control character), `features` (a list of members of `Elzoo.AiText.Provider.features/0`, no duplicate) and `rank` (1..1,000). Refs are unique and ranks are unique;
  - `on_unknown`: `:stop` (the one member in this version);
  - `max_health_age_ms` (1..3,600,000) and `cool_down_ms` (1..86,400,000), the cool-down after a `throttled` or `overloaded` Attempt that names no `retry_after`;
  - `retry`: a keyword list for `RetryTimeout.policy/1` without `mode`; the Piece adds `mode: :redispatch_forbidden`. A `mode` key or a policy that `policy/1` refuses is `:invalid_route`.
- `select(route, request, health)` returns `{:ok, %{eligible: refs, excluded: [{ref, reason}]}}` with `eligible` non-empty, or `{:error, {:no_candidate, excluded}}`; a malformed input is `{:error, :invalid_input}`. Both lists are in ascending `rank`.
  - `request` has exactly `features` (members of the feature set the request needs), `classes` (the data classes, as `decide/2` takes them), `data_policy` (the tenant's `domain/provider-data-policy` policy), `costs` (a map from every candidate's ref to a non-negative integer, the cost estimate in the budget's unit) and `tried` (a list of refs, the candidates of earlier Attempts of this call whose `after_failure/3` result was `{:next, _}`).
  - `health` has exactly `now_ms` (the host's trusted Unix ms), `budget_remaining` (a non-negative integer) and `candidates`, a map from ref to `%{circuit: :closed | :open | :half_open | :unavailable, observed_at_ms, not_before_ms: nil | integer}`. A ref of the route without an entry is `:stale_health`.
  - Each candidate is left out with the first reason that applies, in this order: `:tried` (its ref is in `tried`, whatever its cool-down; carried from the PR #853 review answer); `:capability` (a needed feature is not in its `features`); `{:data_policy, deny}` (`decide/2` on `%{provider, region, retention, classes}` returned `{:deny, deny}`; an `{:error, _}` of `decide/2` makes the whole call `{:error, :invalid_input}`); `:stale_health` (no entry, or `now_ms − observed_at_ms > max_health_age_ms`; a fact exactly `max_health_age_ms` old is fresh; an `observed_at_ms` after `now_ms` is `:invalid_input`); `:circuit_open` (`:open` or `:unavailable`; `:half_open` stays eligible, since the breaker's own `admit/1` decides its probe); `:cooling_down` (`not_before_ms > now_ms`); `:budget` (its cost is greater than `budget_remaining`).
- `after_failure(route, attempt, facts)` returns one of `{:ok, :done}`, `{:ok, {:retry_same, ms}}`, `{:ok, {:next, cool_down}}` and `{:ok, {:stop, why}}`, or `{:error, :invalid_input}`. `attempt` has exactly `ref` (a ref of the route), `same_ref_attempts` (1..256: the dispatches of this request to this ref so far, this one included) and `outcome`; `facts` has exactly `now_ms` and `random` (0..4,294,967,295, the caller's draw, as `delay/4` takes it). By `outcome`:
  - `{:completed, _}` gives `:done`.
  - `{:refused, :credentials_unavailable | :input_unavailable, _}` (nothing was sent) gives, when `decide(policy, same_ref_attempts, :retryable)` is `:retry`, `{:retry_same, ms}` with `ms` from `delay(policy, same_ref_attempts, :retryable, %{failure_delay_ms: nil, random: random})`, and at `:exhausted` `{:stop, :retries_exhausted}`.
  - `{:rate_limited, retry_after_ms}`, the host's own `delivery/rate-limit` refusal of `:tenant_rate` or `:principal_rate` before any intent (a positive integer), gives the same with `failure_delay_ms: retry_after_ms`, so the wait the limiter named is never cut short.
  - `{:refused, :throttled | :overloaded, %{retry_after: s}}` gives `{:next, %{ref: ref, not_before_ms: now_ms + 1,000 × s}}`, or `now_ms + cool_down_ms` when `s` is `nil`. The first request is never sent again; the host records its possible cost as unknown usage.
  - `{:refused, :authentication_failed | :permission_denied | :not_found, _}` gives `{:next, nil}`: the fault is the candidate's.
  - `{:refused, :invalid_request | :too_large, _}` and `{:not_admitted, reason}` (an admission refusal of ai-text, `reason` in its admission set) give `{:stop, :request_fault}`: another candidate would get the same request.
  - `{:unknown, _}` gives `{:stop, :unknown_outcome}` under `on_unknown: :stop`.
  - Any other term is `{:error, :invalid_input}`.

`piece.json` declares telemetry, config and control `not_applicable` (pure; the route is the caller's value), the dependencies `delivery/retry-timeout`, `domain/provider-data-policy` and `integration/ai-text` (for `Provider.features/0`), and the providers `elixir` and `otp`. A Cure module is not required: the rules are table lookups over the reused Pieces' pure decisions; if the worker writes one, its laws are named in the PR.

## Kept open (owner's "no corner" rule)

The route, the request facts, the health facts, the exclusion reasons and the result set may gain keys and members in place before the first release.

- *`on_unknown: :fallback`* (Q8 B), accepting two answers and two costs.
- *A price order from a rate card*, a latency or health score, a region preference, hedged requests.
- *A cool-down bound* other than ai-text's 86,400 s `retry_after`.

## Acceptance

RC-25's list, through the public functions with literal inputs:

1. `new/1`: 16 candidates accepted and 17 refused; a duplicate ref, a duplicate rank, an unknown feature, rank 0 and 1,001, `max_health_age_ms` 0 and 3,600,001, a `retry` with `mode`, and `on_unknown: :fallback` are `:invalid_route`.
2. Capability: a request needing `:tools` and `:structured_output`, and one needing `:image_input`, select only the candidates that declare them; the others are `:capability`.
3. Health at its edge: a fact exactly `max_health_age_ms` old is eligible and one 1 ms older is `:stale_health`; a missing entry is `:stale_health`; `:open` and `:unavailable` are `:circuit_open` and `:half_open` is eligible; `not_before_ms` equal to `now_ms` is eligible and 1 ms later is `:cooling_down`.
4. Data policy: an unapproved provider and an unapproved region are `{:data_policy, :provider}` and `{:data_policy, :region}`; `:secret` data is `{:data_policy, :secret}` for every candidate, which is `{:error, {:no_candidate, excluded}}`.
5. Budget: a cost equal to `budget_remaining` is eligible and one more is `:budget`.
6. Order: eligible refs come in ascending rank, ranks 1 and 1,000 at the ends; the first reason that applies is the one given (a candidate both tried and stale is `:tried`).
7. `after_failure/3`: a `throttled` Attempt with `retry_after: 30` gives `{:next, %{ref, not_before_ms: now_ms + 30,000}}`, and the next `select/3` with that ref in `tried` and that cool-down does not return it; `retry_after: nil` uses `cool_down_ms`; an `authentication_failed` Attempt gives `{:next, nil}` and the next `select/3` leaves that ref out as `:tried`.
8. A local rate refusal `{:rate_limited, 2,500}` under `jitter: :none` gives `{:retry_same, ms}` with `ms` equal to `max(2,500, backoff)`; a `credentials_unavailable` at `same_ref_attempts` equal to `max_attempts` gives `{:stop, :retries_exhausted}`.
9. An `{:unknown, :timeout}` first Attempt gives `{:stop, :unknown_outcome}`, and `invalid_request`, `too_large` and `{:not_admitted, :unsupported_feature}` give `{:stop, :request_fault}`.
10. Negative controls, one at a time, each restored before the final gates: fall back after `unknown` (case 9 fails); skip the data-policy check (case 4 fails); drop the `tried` exclusion (case 7's `authentication_failed` case fails).

Run the Piece tests and the small gate (locally, or the hosted `check-piece` run as `AGENTS.md` section 5 allows for a low-risk Piece), the roadmap and claims checks and the diff check. One light review, the exact-head hosted check and the merge queue are required.

## Limits to state

The candidates, their features, the data policy, the costs, the health facts and the trusted clock are the host's; the Piece decides only on what they give, and its health facts are only as fresh as the host stamps them. No candidate is called and no provider's behaviour is shown here; fallback between real providers is composed in the Wave 9 root acceptance with scripted models. A provider's `retry_after` is a cool-down before a new Attempt, never a resend of the first request (the plan's reading of settled decision 2). After a `{:next, _}` the first Attempt's possible cost is the host's to record. No price order, latency score, hedging or fallback after an unknown outcome.
