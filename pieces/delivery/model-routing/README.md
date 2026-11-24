# delivery/model-routing

`Elzoo.ModelRouting` is pure model routing for a host's model-call binding (the
binding that runs `integration/ai-text` for a `model_call` action). It decides
two things: which candidates of a route may take a request now, in rank order,
and what follows one Attempt's outcome. **There is no fallback after an unknown
outcome**: a request that may have reached a provider is never sent to a second
one. No I/O, no clock, no state. A route holds candidate references only; each
candidate's binding, credential Need and provider account are the host's, so no
credential of one candidate can reach another's intent through this Piece.

## Interface

Every refusal of a malformed input is a fixed error atom; nothing is raised for
an input outside the shapes below. Maps are plain atom-keyed maps with exactly
the keys named (a struct or an extra key is refused); lists are proper lists.

- `new(route)` returns `{:ok, route}` (the same value) or
  `{:error, :invalid_route}`. `select/3` and `after_failure/3` check the route
  again on each call and give `{:error, :invalid_input}` for a route that
  `new/1` refuses.
- `select(route, request, health)` returns
  `{:ok, %{eligible: refs, excluded: [{ref, reason}]}}` with `eligible`
  non-empty, `{:error, {:no_candidate, excluded}}` or
  `{:error, :invalid_input}`. Both lists are in ascending `rank`.
- `after_failure(route, attempt, facts)` returns `{:ok, :done}`,
  `{:ok, {:retry_same, ms}}`, `{:ok, {:next, cool_down}}`,
  `{:ok, {:stop, why}}` or `{:error, :invalid_input}`.

### Route

| Key | Value |
| --- | --- |
| `id` | 1..128 bytes of UTF-8 with no control character |
| `version` | 1..2,147,483,647 |
| `candidates` | 1..16 candidates, refs unique, ranks unique |
| `on_unknown` | `:stop`, the one member in this version |
| `max_health_age_ms` | 1..3,600,000 |
| `cool_down_ms` | 1..86,400,000: the cool-down after a `throttled` or `overloaded` Attempt with no `retry_after` |
| `retry` | a keyword list for `Elzoo.RetryTimeout.policy/1` with only `max_attempts` (at most 256), `base_backoff_ms`, `max_backoff_ms`, `jitter` and `max_failure_delay_ms`, each at most once; the Piece adds `mode: :redispatch_forbidden`, so a `mode` key is refused |

A candidate has `ref` (1..64 bytes of `[a-z0-9_.-]`), `provider`, `region` and
`retention` (each a `domain/provider-data-policy` text: 1..64 bytes of UTF-8
with no C0, DEL or C1 control), `model_id` (1..256 bytes, the same text rule),
`features` (members of `Elzoo.AiText.Provider.features/0`, no duplicate) and
`rank` (1..1,000).

### select/3

`request` has `features` (the features the request needs, members of
`Provider.features/0`, no duplicate), `classes` (as
`Elzoo.ProviderDataPolicy.decide/2` takes them), `data_policy` (the tenant's
policy), `costs` (every candidate's ref to a non-negative cost estimate in the
budget's unit) and `tried` (refs of earlier Attempts of this call whose
`after_failure/3` result was `{:next, _}`).

`health` has `now_ms` (the host's trusted Unix ms), `budget_remaining` (a
non-negative integer) and `candidates`: a map from ref to
`%{circuit: :closed | :open | :half_open | :unavailable, observed_at_ms, not_before_ms: nil | integer}`.
The host stamps `observed_at_ms` itself (`delivery/circuit-breaker` gives no
timestamp) and gives the cool-down of `after_failure/3` as `not_before_ms`.

The whole input is checked before any candidate is: a `tried` ref, a `costs`
key or a `health.candidates` key that is not a ref of the route, a missing
`costs` ref, an `{:error, _}` of `decide/2` for any candidate (a malformed
policy or classes) and an `observed_at_ms` after `now_ms` each give
`{:error, :invalid_input}`, whatever the exclusions would be.

Each other candidate is left out with the first reason that applies:

1. `:tried`: its ref is in `tried`, whatever its cool-down.
2. `:capability`: a needed feature is not in its `features`.
3. `{:data_policy, deny}`: `decide/2` on its `provider`, `region`, `retention`
   and the request's `classes` gave `{:deny, deny}`.
4. `:stale_health`: no entry, or `now_ms − observed_at_ms > max_health_age_ms`
   (a fact exactly `max_health_age_ms` old is fresh).
5. `:circuit_open`: `:open` or `:unavailable`. `:half_open` stays eligible;
   the breaker's own `admit/1` decides its probe.
6. `:cooling_down`: `not_before_ms > now_ms`.
7. `:budget`: its cost is greater than `budget_remaining`.

### after_failure/3

`attempt` has `ref` (a ref of the route), `same_ref_attempts` (1..256: the
Attempts of this request at this ref so far, this one included, sent or not, a
local rate refusal included) and `outcome`. `facts` has `now_ms` and `random`
(0..4,294,967,295, the caller's draw, as `RetryTimeout.delay/4` takes it).

| Outcome | Result |
| --- | --- |
| `{:completed, _}` | `:done` |
| `{:refused, :credentials_unavailable \| :input_unavailable, _}`, `{:not_admitted, :input_unavailable}` | nothing was sent: `{:retry_same, ms}` while `RetryTimeout.decide(policy, same_ref_attempts, :retryable)` is `:retry`, with `ms` from `delay/4` with no failure delay; `{:stop, :retries_exhausted}` at `:exhausted` |
| `{:rate_limited, wait}` | the host's own `delivery/rate-limit` refusal before any intent: the same, with `failure_delay_ms: wait` (`wait` the positive `retry_after_ms` of a `:tenant_rate` or `:principal_rate` refusal, or `nil` for `:keys`, `:slots` or `:tenant_slots`, the backoff alone) |
| `{:refused, :throttled \| :overloaded, %{retry_after: s}}` | `{:next, %{ref: ref, not_before_ms: now_ms + 1,000 × s}}`, or `now_ms + cool_down_ms` when `s` is `nil`; `s` is 0..86,400 |
| `{:refused, :authentication_failed \| :permission_denied \| :not_found, _}` | `{:next, nil}`: the fault is the candidate's |
| `{:not_admitted, :unsupported_feature}` | `{:next, nil}`: this candidate's provider does not take a feature of the request; nothing was sent |
| `{:refused, :invalid_request \| :too_large, _}`, `{:not_admitted, :invalid_request \| :too_large}` | `{:stop, :request_fault}` for every candidate |
| `{:unknown, _}` | `{:stop, :unknown_outcome}` under `on_unknown: :stop` |
| any other term | `{:error, :invalid_input}` |

A `retry_after` on a refusal other than `throttled` or `overloaded` is ignored.
`delay/4` caps a limiter wait at the route's `max_failure_delay_ms`, never
below the backoff, so a wait longer than that is cut to it: the next try is
then refused again by the limiter before any send, and counts as another
Attempt at the same ref.

## The binding's duty

The caller is the host's model-call binding, not the pattern step.

- On `{:retry_same, ms}` it waits `ms` (after checking the action's deadline)
  and sends the same request to the same candidate again.
- On `{:next, _}` for an Attempt that made no intent (`{:not_admitted, _}`) it
  adds the ref to `tried`, records the cool-down if any, and calls `select/3`
  again **inside the same action**: the next candidate gets the request with
  no new action.
- On `{:next, _}` for a refused outcome of a sent request it **ends the
  action** with its refusal, with the candidate's ref in the outcome it gives
  back, and records the first Attempt's possible cost as unknown usage. The
  first request is never sent again; `workflow/agent-loop` reads the ref.
- When the `select/3` after an admission refusal returns
  `{:error, {:no_candidate, _}}`, or `after_failure/3` returns `{:stop, _}`,
  it ends the action with the last Attempt's refusal (an admission refusal as
  a refused outcome with its reason).
- An Attempt that ends with no outcome delivered is given as
  `{:unknown, reason}`.

```elixir
route = %{
  id: "chat", version: 1, on_unknown: :stop,
  max_health_age_ms: 30_000, cool_down_ms: 10_000,
  retry: [max_attempts: 3, base_backoff_ms: 200, max_backoff_ms: 2_000],
  candidates: [
    %{ref: "primary", provider: "p1", region: "eu", retention: "zero",
      model_id: "model-large", features: [:tools], rank: 1},
    %{ref: "backup", provider: "p2", region: "eu", retention: "zero",
      model_id: "model-small", features: [:tools], rank: 2}
  ]
}

{:ok, %{eligible: ["primary", "backup"]}} = Elzoo.ModelRouting.select(route, request, health)

Elzoo.ModelRouting.after_failure(route,
  %{ref: "primary", same_ref_attempts: 1, outcome: {:refused, :throttled, %{retry_after: 30}}},
  %{now_ms: now_ms, random: :rand.uniform(4_294_967_296) - 1})
#=> {:ok, {:next, %{ref: "primary", not_before_ms: now_ms + 30_000}}}
```

## Grounding, Needs and Limits

Tests only: `mix test pieces/delivery/model-routing/test` runs `new/1` bounds,
`select/3` capability, health edges, data policy, budget, order and invalid
input, and `after_failure/3` for every outcome group. Three negative controls,
each a temporary edit (fall back after unknown; skip the data-policy check;
drop the `tried` exclusion), each failed a named case. Finite scenarios, not a
universal proof. Delays come from `delivery/retry-timeout`'s `decide/3` and
`delay/4`, and denials from `domain/provider-data-policy`'s `decide/2`.

Needs: the host binding gives each Attempt's outcome truthfully, stamps
`observed_at_ms` and `now_ms` on its trusted clock, and follows the duty above.

Limits: the candidates, their features, the data policy, the costs, the health
facts and the trusted clock are the host's; the Piece decides only on what they
give, and its health facts are only as fresh as the host stamps them. No
candidate is called and no provider's behaviour is shown here. A provider's
`retry_after` is a cool-down before a new Attempt, never a resend of the first
request. After a `{:next, _}` the first Attempt's possible cost is the host's to
record. A limiter wait over `max_failure_delay_ms` is cut to it. A
provider-specific `too_large` stops the call. There is no deadline input: the
binding checks the action's deadline before each wait. No price order, latency
or health score, region preference, hedging or fallback after an unknown
outcome. Telemetry, Config and Control are not applicable: the route is the
caller's value.

Module application-owned under `Elzoo.ModelRouting`. Apache-2.0; no new
dependency or pin. See [consumption instructions](../../../docs/consuming.md).
