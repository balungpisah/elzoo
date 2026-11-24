# SPDX-License-Identifier: Apache-2.0
defmodule Elzoo.ModelRouting do
  @moduledoc """
  Pure model routing for a host's model-call binding.

  `select/3` gives the candidates of a route that may take a request now, in
  rank order, with a fixed reason for each candidate left out. `after_failure/3`
  gives the next step after one Attempt's outcome. There is no fallback after
  an unknown outcome: a request that may have reached a provider is never sent
  to a second one. No I/O, no clock, no state; the route is the caller's value.
  """

  alias Elzoo.AiText.Provider
  alias Elzoo.ProviderDataPolicy
  alias Elzoo.RetryTimeout

  @max_u32 4_294_967_295
  @route_keys Enum.sort([
                :id,
                :version,
                :candidates,
                :on_unknown,
                :max_health_age_ms,
                :cool_down_ms,
                :retry
              ])
  @candidate_keys Enum.sort([:ref, :provider, :region, :retention, :model_id, :features, :rank])
  @request_keys Enum.sort([:features, :classes, :data_policy, :costs, :tried])
  @health_keys Enum.sort([:now_ms, :budget_remaining, :candidates])
  @entry_keys Enum.sort([:circuit, :observed_at_ms, :not_before_ms])
  @attempt_keys Enum.sort([:ref, :same_ref_attempts, :outcome])
  @facts_keys Enum.sort([:now_ms, :random])
  @retry_keys [:max_attempts, :base_backoff_ms, :max_backoff_ms, :jitter, :max_failure_delay_ms]
  @circuits [:closed, :open, :half_open, :unavailable]
  @no_send [:credentials_unavailable, :input_unavailable]
  @cooled [:throttled, :overloaded]
  @candidate_fault [:authentication_failed, :permission_denied, :not_found]
  @request_fault [:invalid_request, :too_large]

  @doc "Validate a route. Returns `{:ok, route}` with the route unchanged, or `{:error, :invalid_route}`."
  def new(route) do
    case route(route) do
      {:ok, _policy} -> {:ok, route}
      :error -> {:error, :invalid_route}
    end
  end

  @doc """
  The candidates of `route` that may take `request` now under `health`.

  Returns `{:ok, %{eligible: refs, excluded: [{ref, reason}]}}` with `eligible`
  non-empty, `{:error, {:no_candidate, excluded}}`, or `{:error, :invalid_input}`.
  Both lists are in ascending rank.
  """
  def select(route, request, health) do
    with {:ok, _policy} <- route(route),
         refs = Enum.map(route.candidates, & &1.ref),
         true <- request?(request, refs) and health?(health, refs),
         {:ok, verdicts} <- data_verdicts(route.candidates, request) do
      {eligible, excluded} =
        route.candidates
        |> Enum.sort_by(& &1.rank)
        |> Enum.reduce({[], []}, fn candidate, {eligible, excluded} ->
          case exclusion(candidate, route, request, health, Map.fetch!(verdicts, candidate.ref)) do
            nil -> {[candidate.ref | eligible], excluded}
            reason -> {eligible, [{candidate.ref, reason} | excluded]}
          end
        end)

      case {Enum.reverse(eligible), Enum.reverse(excluded)} do
        {[], excluded} -> {:error, {:no_candidate, excluded}}
        {eligible, excluded} -> {:ok, %{eligible: eligible, excluded: excluded}}
      end
    else
      _ -> {:error, :invalid_input}
    end
  end

  @doc """
  The next step after one Attempt's outcome: `{:ok, :done}`,
  `{:ok, {:retry_same, ms}}`, `{:ok, {:next, cool_down}}`, `{:ok, {:stop, why}}`
  or `{:error, :invalid_input}`.
  """
  def after_failure(route, attempt, facts) do
    with {:ok, policy} <- route(route),
         true <- attempt?(attempt, Enum.map(route.candidates, & &1.ref)) and facts?(facts),
         {:ok, step} <- step(route, policy, attempt, facts) do
      {:ok, step}
    else
      _ -> {:error, :invalid_input}
    end
  end

  # Exclusion order: the first reason that applies.
  defp exclusion(candidate, route, request, health, verdict) do
    entry = Map.get(health.candidates, candidate.ref)

    cond do
      candidate.ref in request.tried -> :tried
      not Enum.all?(request.features, &(&1 in candidate.features)) -> :capability
      verdict != :allow -> {:data_policy, elem(verdict, 1)}
      entry == nil -> :stale_health
      health.now_ms - entry.observed_at_ms > route.max_health_age_ms -> :stale_health
      entry.circuit in [:open, :unavailable] -> :circuit_open
      entry.not_before_ms != nil and entry.not_before_ms > health.now_ms -> :cooling_down
      Map.fetch!(request.costs, candidate.ref) > health.budget_remaining -> :budget
      true -> nil
    end
  end

  # Every candidate's decision first: any error of decide/2 makes the whole call invalid.
  defp data_verdicts(candidates, request) do
    Enum.reduce_while(candidates, {:ok, %{}}, fn c, {:ok, acc} ->
      facts = %{
        provider: c.provider,
        region: c.region,
        retention: c.retention,
        classes: request.classes
      }

      case ProviderDataPolicy.decide(request.data_policy, facts) do
        :allow -> {:cont, {:ok, Map.put(acc, c.ref, :allow)}}
        {:deny, deny} -> {:cont, {:ok, Map.put(acc, c.ref, {:deny, deny})}}
        {:error, _} -> {:halt, :error}
      end
    end)
  end

  defp step(_route, _policy, %{outcome: {:completed, _}}, _facts), do: {:ok, :done}

  defp step(_route, policy, %{outcome: {:refused, reason, _}} = a, facts) when reason in @no_send,
    do: {:ok, same(policy, a.same_ref_attempts, nil, facts.random)}

  defp step(_route, policy, %{outcome: {:not_admitted, :input_unavailable}} = a, facts),
    do: {:ok, same(policy, a.same_ref_attempts, nil, facts.random)}

  defp step(_route, policy, %{outcome: {:rate_limited, wait}} = a, facts)
       when is_nil(wait) or (is_integer(wait) and wait > 0),
       do: {:ok, same(policy, a.same_ref_attempts, wait, facts.random)}

  defp step(route, _policy, %{outcome: {:refused, reason, %{retry_after: s} = meta}} = a, facts)
       when reason in @cooled and map_size(meta) == 1 and
              (is_nil(s) or (is_integer(s) and s >= 0 and s <= 86_400)) do
    wait = if is_nil(s), do: route.cool_down_ms, else: 1_000 * s
    {:ok, {:next, %{ref: a.ref, not_before_ms: facts.now_ms + wait}}}
  end

  defp step(_route, _policy, %{outcome: {:refused, reason, _}}, _facts)
       when reason in @candidate_fault,
       do: {:ok, {:next, nil}}

  defp step(_route, _policy, %{outcome: {:not_admitted, :unsupported_feature}}, _facts),
    do: {:ok, {:next, nil}}

  defp step(_route, _policy, %{outcome: {:refused, reason, _}}, _facts)
       when reason in @request_fault,
       do: {:ok, {:stop, :request_fault}}

  defp step(_route, _policy, %{outcome: {:not_admitted, reason}}, _facts)
       when reason in @request_fault,
       do: {:ok, {:stop, :request_fault}}

  # on_unknown is :stop, its one member in this version.
  defp step(%{on_unknown: :stop}, _policy, %{outcome: {:unknown, _}}, _facts),
    do: {:ok, {:stop, :unknown_outcome}}

  defp step(_route, _policy, _attempt, _facts), do: :error

  # Nothing was sent: the same request to the same candidate, under the route's retry policy.
  defp same(policy, n, wait, random) do
    case RetryTimeout.decide(policy, n, :retryable) do
      {:ok, :retry} ->
        {:ok, ms} =
          RetryTimeout.delay(policy, n, :retryable, %{failure_delay_ms: wait, random: random})

        {:retry_same, ms}

      {:ok, :exhausted} ->
        {:stop, :retries_exhausted}
    end
  end

  # Route shape; returns the retry policy that the route implies.
  defp route(route) do
    with true <- keys?(route, @route_keys),
         true <- text?(route.id, 128) and int_in?(route.version, 1, 2_147_483_647),
         true <- route.on_unknown == :stop,
         true <- int_in?(route.max_health_age_ms, 1, 3_600_000),
         true <- int_in?(route.cool_down_ms, 1, 86_400_000),
         true <- bounded?(route.candidates, 1, 16) and Enum.all?(route.candidates, &candidate?/1),
         true <- unique?(Enum.map(route.candidates, & &1.ref)),
         true <- unique?(Enum.map(route.candidates, & &1.rank)),
         {:ok, policy} <- retry(route.retry) do
      {:ok, policy}
    else
      _ -> :error
    end
  end

  defp candidate?(c) do
    keys?(c, @candidate_keys) and ref?(c.ref) and text?(c.provider, 64) and
      text?(c.region, 64) and text?(c.retention, 64) and text?(c.model_id, 256) and
      features?(c.features) and int_in?(c.rank, 1, 1_000)
  end

  defp retry(retry) do
    with true <- bounded?(retry, 0, length(@retry_keys)) and Keyword.keyword?(retry),
         keys = Keyword.keys(retry),
         true <- unique?(keys) and Enum.all?(keys, &(&1 in @retry_keys)),
         true <- Keyword.get(retry, :max_attempts, 3) |> at_most?(256),
         {:ok, policy} <- RetryTimeout.policy(retry ++ [mode: :redispatch_forbidden]) do
      {:ok, policy}
    else
      _ -> :error
    end
  end

  defp at_most?(n, max), do: not is_integer(n) or n <= max

  defp request?(r, refs) do
    keys?(r, @request_keys) and features?(r.features) and
      is_map(r.costs) and not is_struct(r.costs) and Enum.sort(Map.keys(r.costs)) == Enum.sort(refs) and
      Enum.all?(Map.values(r.costs), &non_neg?/1) and
      proper_list?(r.tried) and Enum.all?(r.tried, &(&1 in refs))
  end

  defp health?(h, refs) do
    keys?(h, @health_keys) and is_integer(h.now_ms) and non_neg?(h.budget_remaining) and
      is_map(h.candidates) and not is_struct(h.candidates) and
      Enum.all?(h.candidates, fn {ref, entry} -> ref in refs and entry?(entry, h.now_ms) end)
  end

  defp entry?(e, now) do
    keys?(e, @entry_keys) and e.circuit in @circuits and is_integer(e.observed_at_ms) and
      e.observed_at_ms <= now and (is_nil(e.not_before_ms) or is_integer(e.not_before_ms))
  end

  defp attempt?(a, refs) do
    keys?(a, @attempt_keys) and a.ref in refs and int_in?(a.same_ref_attempts, 1, 256)
  end

  defp facts?(f),
    do: keys?(f, @facts_keys) and is_integer(f.now_ms) and int_in?(f.random, 0, @max_u32)

  defp features?(list) do
    features = Provider.features()

    bounded?(list, 0, length(features)) and Enum.all?(list, &(&1 in features)) and unique?(list)
  end

  # A plain map with exactly these atom keys; a struct has one key more.
  defp keys?(map, keys), do: is_map(map) and Enum.sort(Map.keys(map)) == keys

  defp ref?(ref), do: is_binary(ref) and String.match?(ref, ~r/\A[a-z0-9_.-]{1,64}\z/)

  # 1..max bytes of valid UTF-8 without C0 (U+0000..U+001F), DEL or C1 (U+0080..U+009F).
  defp text?(value, max) do
    is_binary(value) and byte_size(value) in 1..max//1 and String.valid?(value) and
      not String.match?(value, ~r/[\x{00}-\x{1F}\x{7F}-\x{9F}]/u)
  end

  defp int_in?(n, min, max), do: is_integer(n) and n >= min and n <= max
  defp non_neg?(n), do: is_integer(n) and n >= 0
  defp unique?(list), do: length(list) == length(Enum.uniq(list))

  # A proper list whose length is in min..max; walks at most max + 1 cells.
  defp bounded?(list, min, max), do: count(list, 0, max) in min..max//1

  defp count([], n, _max), do: n
  defp count([_ | tail], n, max) when n <= max, do: count(tail, n + 1, max)
  defp count(_, _n, _max), do: :invalid

  defp proper_list?([]), do: true
  defp proper_list?([_ | tail]), do: proper_list?(tail)
  defp proper_list?(_), do: false
end
