# SPDX-License-Identifier: Apache-2.0
defmodule Elzoo.UnitAdapter.Codec do
  @moduledoc "Consumer-owned runtime payload and output translation."
  @callback decode_payload(String.t(), pos_integer(), term()) :: {:ok, term()} | {:error, atom()}
  @callback encode_output(:none | {:some, term()}) :: {:ok, term()} | {:error, atom()}
  @callback value_schema() :: {String.t(), pos_integer()}
end

defmodule Elzoo.UnitAdapter do
  @moduledoc """
  One synchronous delivery through validated wiring to a volatile Unit.

  Dispatched means message submitted, not receiver execution. A noproc call
  exit leaves dispatch unknown. Timed_out denotes the observed OTP call-timeout
  exit reason, not proof that 5000 ms elapsed: a callback can exit with the same
  reason. No retries, deadline enforcement or durable delivery are supplied.
  The Adapter emits no raw payload or exception data in errors or logs;
  successful values are codec-owned. Upstream OTP crash reports may log the
  unchanged Unit's last request/state; consumers control Logger configuration.
  """

  def deliver(unit_lookup, wiring, edge_id, envelope, codec) do
    with {:envelope, {:ok, decoded}} <- {:envelope, Elzoo.Envelope.decode(envelope)},
         {:wiring, {:ok, _}} <- {:wiring, Elzoo.Wiring.validate(wiring)} do
      envelope = Elzoo.Envelope.encode(decoded)

      base =
        envelope
        |> Map.take(~w(message_id attempt_id deadline_unix_ms))
        |> Map.merge(%{
          "version" => 1,
          "correlation_id" => Map.get(envelope, "correlation_id", envelope["message_id"])
        })

      {:ok, route(unit_lookup, wiring, edge_id, envelope, codec, base)}
    else
      {phase, {:error, reason}} -> {:error, {phase, reason}}
    end
  end

  defp route(lookup, wiring, edge, envelope, codec, base) do
    with {:ok, _} <- Elzoo.Wiring.accept(wiring, edge, envelope),
         {:ok, input} <-
           codec.decode_payload(
             envelope["schema_id"],
             envelope["schema_version"],
             envelope["payload"]
           ) do
      case if(is_function(lookup, 0), do: lookup.(), else: lookup) do
        absent when absent in [:restarting, :undefined, nil] ->
          failure(base, "rejected", "not_dispatched", "unavailable")

        pid when is_pid(pid) ->
          call(pid, input, codec, base)
      end
    else
      {:error, _} -> failure(base, "rejected", "not_dispatched", "permanent")
    end
  end

  defp call(pid, input, codec, base) do
    reply =
      try do
        {:ok, Elzoo.Unit.step(pid, input)}
      catch
        :exit, {:timeout, _} -> {:exit, "timed_out", "dispatched"}
        :exit, {:noproc, _} -> {:exit, "unknown", "unknown"}
        :exit, _ -> {:exit, "unknown", "dispatched"}
      end

    case reply do
      {:ok, output}
      when output == :none or
             (is_tuple(output) and tuple_size(output) == 2 and elem(output, 0) == :some) ->
        encode(output, codec, base)

      {:ok, _} ->
        failure(base, "failed", "dispatched", "unclassified")

      {:exit, outcome, dispatch} ->
        failure(base, outcome, dispatch, "unclassified")
    end
  end

  defp encode(output, codec, base) do
    case codec.encode_output(output) do
      {:ok, encoded} ->
        {schema, version} = codec.value_schema()

        Map.merge(base, %{
          "outcome" => "completed",
          "dispatch" => "dispatched",
          "value" => if(output == :none, do: nil, else: encoded),
          "value_schema_id" => schema,
          "value_schema_version" => version
        })

      {:error, _} ->
        failure(base, "failed", "dispatched", "unclassified")
    end
  end

  defp failure(base, outcome, dispatch, error) do
    Map.merge(base, %{"outcome" => outcome, "dispatch" => dispatch, "error_class" => error})
  end
end
