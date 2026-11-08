# SPDX-License-Identifier: Apache-2.0
defmodule Elzoo.EffectIntent.TestAdapter do
  def failure_tags, do: [:timeout, :no_send, :permanent, :failed]
  def schema, do: Application.get_env(:elzoo, :effect_intent_test_schema, "v1")
  def validate("bad", _), do: {:error, :schema}
  def validate(bytes, schema), do: if(is_binary(bytes) and is_binary(schema), do: :ok, else: :error)

  def send_effect(req) do
    send(req.context.parent, {:physical_send, self(), req})
    req.context.send.(req)
  end

  def poll(req) do
    send(req.context.parent, {:physical_poll, self(), req})
    req.context.poll.(req)
  end

  def authenticate({_, evidence}, _), do: if(evidence == "trusted", do: :ok, else: :error)

  def authenticate(result, req) when is_map(result),
    do: if(result["correlation_id"] == req.key, do: :ok, else: :error)

  def authenticate(_, _), do: :error

  def validate_result(%{"outcome" => "completed", "value" => %{"digest" => digest}}, req),
    do: if(digest == req.arguments_digest, do: :ok, else: :error)

  def validate_result(%{"outcome" => "completed"}, _), do: :error
  def validate_result(_, _), do: :ok
end

defmodule Elzoo.EffectIntent.TestBinding do
  use Elzoo.EffectIntent.Binding,
    adapter: Elzoo.EffectIntent.TestAdapter,
    id: "test",
    provider_account: "account",
    operation: "refund",
    clock: "host-unix-ms",
    failures: %{
      timeout: {"timed_out", "unknown", "retryable"},
      no_send: {"timed_out", "not_dispatched", "retryable"},
      permanent: {"rejected", "not_dispatched", "permanent"},
      failed: {"failed", "dispatched", "permanent"}
    },
    no_send_attestations: [:no_send, :permanent],
    replay: %{
      window_ms: 1000,
      max_flight_ms: 100,
      clock_allowance_ms: 10,
      semantics: :same_key_same_arguments
    },
    revision: :same_key_changed_arguments,
    recovery_grace_ms: 100
end

defmodule Elzoo.EffectIntent.TestBadHost do
  def activate(%{change: change} = ctx, request) do
    case Elzoo.EffectIntent.StoreHost.activate(ctx, request) do
      {:active, g, grant} -> {:active, g, change.(grant)}
      other -> other
    end
  end
end

defmodule Elzoo.EffectIntent.TestNoReplayBinding do
  use Elzoo.EffectIntent.Binding,
      Elzoo.EffectIntent.TestBinding.__effect_intent_binding__()
      |> Map.delete(:digest)
      |> Map.put(:replay, :none)
end
