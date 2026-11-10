# SPDX-License-Identifier: Apache-2.0
defmodule Elzoo.AiEmbedding.Retry do
  @moduledoc """
  Bounded retries through the ready `delivery/retry-timeout` policy
  (`Elzoo.RetryTimeout.classify/1`, `decide/3`, `backoff/2`), applied by the
  host between EffectIntent commands; the Runner is not used, because the
  intent owner is the dispatch authority.

  `next(policy, attempts_made, result, opts)` takes the outcome of the latest
  attempt (`:completed` or a failure tag) and returns:

  - `{:retry, delay_ms}`: only for a retryable **attested no-send** result
    (`credentials_unavailable`); the host then issues `:rearm` and `:dispatch`
    after the delay;
  - `{:stop, decision}` otherwise, with `decision` one of `:settle`,
    `:permanent`, `:exhausted`, `:unresolved` or `:deadline`.

  `throttled` and `overloaded` are `failed/dispatched/retryable` (ELZ-079
  amendment 1, family-wide): under the default `:redispatch_forbidden` mode they decide
  `:unresolved` and are never redispatched here. A caller that retries one
  does so explicitly with a ground of its own, for example a new logical
  request reference (a new intent), accepting that the first request may have
  been processed. `unknown` outcomes are never retried. A
  `:redispatch_idempotent` policy does not change this: a dispatched result
  decides `:unresolved` here because no provider supplies a replay-safe ground.
  `opts` takes
  `now_ms` and `deadline_ms`; a delay that would end at or after the deadline
  stops with `:deadline`.
  """
  alias Elzoo.AiEmbedding.Outcome

  def next(policy, attempts, result, opts \\ []) do
    with {:ok, envelope} <- envelope(result),
         {:ok, class} <- Elzoo.RetryTimeout.classify(envelope),
         {:ok, decision} <- Elzoo.RetryTimeout.decide(policy, attempts, class) do
      case decision do
        # Only an attested no-send result is redispatched, whatever the policy's
        # mode: a :redispatch_idempotent policy would permit dispatched results,
        # but no provider here supplies an idempotency or no-effect ground.
        :retry ->
          if result in Outcome.no_send(),
            do: delay(policy, attempts, opts),
            else: {:stop, :unresolved}

        other ->
          {:stop, other}
      end
    end
  end

  defp delay(policy, attempts, opts) do
    {:ok, ms} = Elzoo.RetryTimeout.backoff(policy, attempts)

    case {Keyword.get(opts, :now_ms), Keyword.get(opts, :deadline_ms)} do
      {now, deadline} when is_integer(now) and is_integer(deadline) and now + ms >= deadline ->
        {:stop, :deadline}

      _ ->
        {:retry, ms}
    end
  end

  defp envelope(:completed),
    do:
      {:ok,
       Map.merge(base("completed", "dispatched", nil), %{
         "value" => %{},
         "value_schema_id" => "elzoo/ai-embedding-result",
         "value_schema_version" => 1
       })}

  defp envelope(tag) do
    case Outcome.delivery(tag) do
      {:ok, {outcome, dispatch, class}} -> {:ok, base(outcome, dispatch, class)}
      _ -> {:error, :invalid_result}
    end
  end

  defp base(outcome, dispatch, class) do
    %{
      "version" => 1,
      "message_id" => "retry-decision",
      "correlation_id" => "retry-decision",
      "outcome" => outcome,
      "dispatch" => dispatch
    }
    |> then(&if(class, do: Map.put(&1, "error_class", class), else: &1))
  end
end
