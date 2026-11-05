# SPDX-License-Identifier: Apache-2.0
defmodule Elzoo.IngestBoundary do
  @moduledoc """
  Volatile JSON ingress over supervised Units. Emits no payload, exception or
  Jason error data in errors or logs. Equivalence is limited to named crash-free
  traces. The pipeline call is Adapter/Host entry, not fused-edge traversal;
  the fused ingress seam is checked on behalf of pipeline/ingress.request.
  Codec and lookup callback exceptions are a caller contract and out of scope.
  """

  def handle(placement, units, json, opts \\ []) do
    with {:json, {:ok, envelope}} <- {:json, Jason.decode(json)},
         {:envelope, {:ok, _}} <- {:envelope, Elzoo.Envelope.decode(envelope)},
         {:ok, result} <- deliver(placement, units, envelope, Keyword.get(opts, :codecs, %{})) do
      result =
        case Elzoo.Envelope.validate_result(result) do
          {:ok, checked} -> checked
          {:error, _} -> failure(envelope, "failed")
        end

      case Jason.encode(result) do
        {:ok, encoded} -> {:ok, encoded}
        {:error, _} -> Jason.encode(failure(envelope, "failed"))
      end
    else
      {:json, {:error, _}} -> {:error, :invalid_json}
      {:envelope, {:error, _}} -> {:error, :invalid_envelope}
      {:error, _} = error -> error
    end
  end

  defp deliver(:fused, units, envelope, codecs) do
    Elzoo.UnitAdapter.deliver(
      units["pipeline"],
      wiring(:fused),
      "ingress",
      envelope,
      Map.get(codecs, :count, Elzoo.IngestCodec.Count)
    )
  end

  defp deliver(:hop, units, envelope, codecs) do
    with {:ok, first} <-
           Elzoo.UnitAdapter.deliver(
             units["dedup"],
             wiring(:hop),
             "ingress",
             envelope,
             Map.get(codecs, :accepted, Elzoo.IngestCodec.Accepted)
           ) do
      cond do
        first["outcome"] != "completed" ->
          {:ok, first}

        first["value"] == nil ->
          {:ok,
           Map.merge(first, %{
             "value_schema_id" => "example/optional-count",
             "value_schema_version" => 1
           })}

        true ->
          inner =
            envelope
            |> Map.take(~w(attempt_id deadline_unix_ms))
            |> Map.merge(%{
              "version" => 1,
              "message_id" => envelope["message_id"] <> "/dedup-accumulate",
              "kind" => "event",
              "producer" => %{"unit_id" => "dedup", "port_id" => "accepted"},
              "schema_id" => "example/accepted-message",
              "schema_version" => 1,
              "causation_id" => envelope["message_id"],
              "correlation_id" => first["correlation_id"],
              "payload" => first["value"]
            })

          second =
            Elzoo.UnitAdapter.deliver(
              units["accumulate"],
              wiring(:hop),
              "dedup-accumulate",
              inner,
              Map.get(codecs, :total, Elzoo.IngestCodec.Total)
            )

          {:ok, combine(envelope, second)}
      end
    end
  end

  defp combine(envelope, {:ok, %{"outcome" => "completed"} = result}) do
    Map.merge(result, identity(envelope))
  end

  defp combine(envelope, {:ok, %{"outcome" => outcome}})
       when outcome in ["timed_out", "unknown", "failed"],
       do: failure(envelope, outcome)

  defp combine(envelope, _), do: failure(envelope, "failed")

  defp identity(envelope) do
    envelope
    |> Map.take(~w(message_id attempt_id deadline_unix_ms))
    |> Map.merge(%{
      "version" => 1,
      "correlation_id" => Map.get(envelope, "correlation_id", envelope["message_id"])
    })
  end

  defp failure(envelope, outcome),
    do:
      Map.merge(identity(envelope), %{
        "outcome" => outcome,
        "dispatch" => "dispatched",
        "error_class" => "unclassified"
      })

  def wiring(:fused) do
    %{
      "version" => 1,
      "units" => [
        unit("pipeline", [
          port("ingress.request", "output", "example/ingest-message", "fused"),
          port("dedup.input", "input", "example/ingest-message", "fused")
        ])
      ],
      "edges" => [
        edge("ingress", "fused", "pipeline", "ingress.request", "pipeline", "dedup.input")
      ]
    }
  end

  def wiring(:hop) do
    %{
      "version" => 1,
      "units" => [
        unit("client", [port("request", "output", "example/ingest-message", "volatile")]),
        unit("dedup", [
          port("input", "input", "example/ingest-message", "volatile"),
          port("accepted", "output", "example/accepted-message", "volatile")
        ]),
        unit("accumulate", [port("input", "input", "example/accepted-message", "volatile")])
      ],
      "edges" => [
        edge("ingress", "hop", "client", "request", "dedup", "input"),
        edge("dedup-accumulate", "hop", "dedup", "accepted", "accumulate", "input")
      ]
    }
  end

  defp unit(id, ports), do: %{"id" => id, "ports" => ports}

  defp port(id, direction, schema, delivery),
    do: %{
      "port" => %{
        "id" => id,
        "direction" => direction,
        "schema_id" => schema,
        "schema_version" => 1
      },
      "delivery" => delivery,
      "required_route" => true
    }

  defp edge(id, placement, source, output, target, input),
    do: %{
      "id" => id,
      "placement" => placement,
      "source" => %{"unit_id" => source, "port_id" => output},
      "target" => %{"unit_id" => target, "port_id" => input}
    }
end
