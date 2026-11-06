# SPDX-License-Identifier: Apache-2.0
defmodule Elzoo.RequestRouteRetry do
  @moduledoc "Volatile request/route/retry Assembly; callers supervise the unchanged Units and Runner."
  alias Elzoo.RequestRouteRetry.Codec
  alias Elzoo.RetryTimeout.Runner
  @core :"Cure.Elzoo.RequestRouteRetry"

  def topology(placement) when placement in [:fused, :hop] do
    fused = placement == :fused
    worker = if fused, do: "worker", else: "dedup"
    seam_delivery = if fused, do: "fused", else: "volatile"
    sink = if fused, do: "worker", else: "accumulate"

    units = [
      unit("client", [
        binding("request", "output", "rr-request"),
        binding("reply.in", "input", "elzoo/delivery-result")
      ]),
      unit("gateway", [
        binding("request.in", "input", "rr-request"),
        binding("work", "output", "rr-work"),
        binding("result.in", "input", "rr-result", "volatile", false),
        binding("reply", "output", "elzoo/delivery-result")
      ]),
      unit(worker, [
        binding("input", "input", "rr-work"),
        binding(
          if(fused, do: "dedup.accepted", else: "accepted"),
          "output",
          "rr-accepted",
          seam_delivery
        ),
        binding(
          if(fused, do: "result", else: "outcome"),
          "output",
          if(fused, do: "rr-result", else: "rr-dedup-outcome"),
          "volatile",
          false
        )
      ])
    ]

    units =
      if fused do
        List.update_at(units, 2, fn u ->
          Map.update!(
            u,
            "ports",
            &(&1 ++ [binding("accumulate.input", "input", "rr-accepted", "fused")])
          )
        end)
      else
        units ++
          [
            unit("accumulate", [
              binding("input", "input", "rr-accepted"),
              binding("total", "output", "rr-total", "volatile", false)
            ]),
            unit("hop-worker", [binding("result", "output", "rr-result", "volatile", false)])
          ]
      end

    wiring = %{
      "version" => 1,
      "units" => units,
      "edges" => [
        edge("ingress", "hop", "client", "request", "gateway", "request.in"),
        edge("work", "hop", "gateway", "work", worker, "input"),
        edge(
          "dedup-accumulate",
          if(fused, do: "fused", else: "hop"),
          worker,
          if(fused, do: "dedup.accepted", else: "accepted"),
          sink,
          if(fused, do: "accumulate.input", else: "input")
        ),
        edge("reply", "hop", "gateway", "reply", "client", "reply.in")
      ]
    }

    face = %{
      "input" => port("input", "input", "rr-work"),
      "output" => port("result", "output", "rr-result")
    }

    downstream = port("result.in", "input", "rr-result")

    %{
      "wiring" => wiring,
      "routes" => %{
        "version" => 1,
        "source" => endpoint("client", "request"),
        "routes" => [%{"edge_id" => "ingress", "match" => %{"kind" => "command"}}]
      },
      "requirement" => %{
        "upstream" => port("work", "output", "rr-work"),
        "downstream" => downstream,
        "delivery" => seam_delivery
      },
      "candidates" => [
        candidate("fused-worker", face, "fused"),
        candidate("hop-worker", face, "volatile"),
        candidate("legacy-worker", put_in(face, ["input", "schema_version"], 2), "volatile")
      ],
      "interfaces" => [
        face,
        %{"input" => downstream, "output" => port("reply", "output", "elzoo/delivery-result")}
      ]
    }
  end

  def check_topology(placement) when placement in [:fused, :hop],
    do: check_topology(topology(placement))

  def check_topology(%{
        "wiring" => wiring,
        "routes" => routes,
        "interfaces" => [first, second],
        "requirement" => req,
        "candidates" => candidates
      }) do
    with {:ok, _} <- phase(Elzoo.Wiring.validate(wiring), :wiring),
         {:ok, _} <- phase(Elzoo.Routing.validate(wiring, routes), :routing),
         {:ok, _} <- phase(Elzoo.Assembly.connect(first, second), :assembly),
         {:ok, id} <- phase(Elzoo.Selection.select(req, candidates), :selection) do
      {:ok, %{"selected" => id}}
    end
  end

  def initial_state(placement, window, max_senders) when placement in [:fused, :hop] do
    with {:ok, state} <- Elzoo.WindowedIdempotency.new(window, max_senders) do
      {:ok,
       if(placement == :fused,
         do: %{"worker" => {:Joined, state, 0}},
         else: %{"dedup" => state, "accumulate" => 0}
       )}
    end
  end

  def initial_state(_, _, _), do: {:error, :invalid_placement}

  def start_link(opts) when is_list(opts) do
    if Keyword.keyword?(opts) do
      placement = Keyword.get(opts, :placement)
      units = Keyword.get(opts, :units)

      with true <- placement in [:fused, :hop],
           {:ok, _} <- initial_state(placement, opts[:window], opts[:max_senders]),
           true <- valid_units?(units, placement),
           {:ok, %{"selected" => selected}} <- check_topology(placement) do
        data = topology(placement)

        delivery = %{
          "request-route-retry/fused-worker" => :fused,
          "request-route-retry/hop-worker" => :hop
        }

        attempt = fn outer ->
          attempt(outer, data["wiring"], units, Map.fetch!(delivery, selected))
        end

        opts
        |> Keyword.take([
          :capacity,
          :policy,
          :attempt_timeout_ms,
          :task_supervisor,
          :dead_letter,
          :now_ms
        ])
        |> Keyword.put(:attempt, attempt)
        |> Runner.start_link()
      else
        {:error, {:topology, _, _}} = error -> error
        _ -> {:error, :invalid_options}
      end
    else
      {:error, :invalid_options}
    end
  end

  def start_link(_), do: {:error, :invalid_options}

  def submit(runner, request) do
    data = topology(:fused)

    with {:ok, "ingress"} <- Elzoo.Routing.route_one(data["wiring"], data["routes"], request),
         do: Runner.submit(runner, request)
  end

  def direct(state, requests) do
    Enum.map_reduce(requests, state, fn request, state ->
      {:ok, message} = Codec.message(request)
      {:Transition, next, output} = apply(@core, :worker, [state, message])
      {:ok, value} = Codec.Worker.encode_output(output)
      {value, next}
    end)
  end

  defp attempt(outer, wiring, units, placement) do
    target = %{
      "unit_id" => "gateway",
      "message_id" => outer["attempt_id"] <> "/work",
      "port" => port("work", "output", "rr-work")
    }

    result =
      with {:ok, inner} <- Elzoo.Transformation.translate(outer, target, & &1) do
        case placement do
          :fused ->
            deliver(units["worker"], wiring, "work", inner, Codec.Worker)

          :hop ->
            first = deliver(units["dedup"], wiring, "work", inner, Codec.Dedup)

            second =
              case dedup_value(first) do
                {:ok, label, accepted} when not is_nil(accepted) ->
                  target = %{
                    "unit_id" => "dedup",
                    "message_id" => inner["message_id"] <> "/accumulate",
                    "port" => port("accepted", "output", "rr-accepted")
                  }

                  case Elzoo.Transformation.translate(inner, target, fn _ -> accepted end) do
                    {:ok, second} ->
                      {label,
                       deliver(
                         units["accumulate"],
                         wiring,
                         "dedup-accumulate",
                         second,
                         Codec.Accumulate
                       )}

                    _ ->
                      :invalid
                  end

                _ ->
                  :not_attempted
              end

            combine_hop(first, second)
        end
      else
        _ -> failure(identity(outer), "failed", "dispatched")
      end

    finalize_result(outer, result)
  end

  defp deliver(lookup, wiring, edge, envelope, codec) do
    case Elzoo.UnitAdapter.deliver(lookup, wiring, edge, envelope, codec) do
      {:ok, result} -> result
      _ -> failure(identity(envelope), "failed", "dispatched")
    end
  end

  defp dedup_value(%{
         "outcome" => "completed",
         "value_schema_id" => "example/rr-dedup-outcome",
         "value_schema_version" => 1,
         "value" => %{"decision" => label, "accepted" => accepted} = value
       })
       when map_size(value) == 2 do
    valid =
      Codec.known?(label) and
        if(Codec.accepted?(label),
          do: match?({:ok, _}, Codec.message(accepted)),
          else: is_nil(accepted)
        )

    if valid, do: {:ok, label, accepted}, else: :invalid
  end

  defp dedup_value(_), do: :invalid

  defp combine_hop(%{"outcome" => outcome} = first, _) when outcome != "completed",
    do: Map.drop(first, ~w(value value_schema_id value_schema_version))

  defp combine_hop(first, second) do
    case {dedup_value(first), second} do
      {{:ok, label, nil}, :not_attempted} ->
        completed(identity(first), label, nil)

      {{:ok, label, _},
       {label,
        %{
          "outcome" => "completed",
          "value_schema_id" => "example/rr-total",
          "value_schema_version" => 1,
          "value" => n
        }}}
      when is_integer(n) ->
        completed(identity(first), label, n)

      {{:ok, _, _}, {_, %{"outcome" => outcome}}}
      when outcome in ["timed_out", "unknown", "failed"] ->
        failure(identity(first), outcome, "dispatched")

      _ ->
        failure(identity(first), "failed", "dispatched")
    end
  end

  defp finalize_result(outer, result) do
    base = identity(outer)

    rebuilt =
      result
      |> Map.drop(~w(message_id correlation_id attempt_id deadline_unix_ms))
      |> Map.merge(base)

    rebuilt =
      cond do
        result["correlation_id"] != base["correlation_id"] ->
          failure(base, "unknown", "unknown")

        result["outcome"] == "completed" and
            not (result["value_schema_id"] == "example/rr-result" and
                   result["value_schema_version"] == 1 and Codec.valid_value?(result["value"])) ->
          failure(base, "failed", "dispatched")

        true ->
          rebuilt
      end

    case Elzoo.Envelope.validate_result(rebuilt) do
      {:ok, checked} ->
        checked

      _ ->
        {:ok, fallback} = Elzoo.Envelope.validate_result(failure(base, "failed", "dispatched"))
        fallback
    end
  end

  def reply(request, settlement, message_id) do
    with {:ok, _} <- reply_phase(Elzoo.Envelope.validate(request), :request),
         {:ok, _} <- reply_phase(Elzoo.RequestReply.reply_endpoint(request), :reply_to),
         base = identity(request) |> Map.delete("attempt_id"),
         :ok <- settlement_matches(base, settlement) do
      result =
        case settlement do
          {:completed, result} ->
            result
            |> Map.drop(~w(message_id correlation_id attempt_id deadline_unix_ms))
            |> Map.merge(base)

          {kind, record} when kind in [:dead_lettered, :unsettled] ->
            Map.merge(base, %{
              "outcome" => record["last_outcome"] || "unknown",
              "dispatch" => record["last_dispatch"] || "unknown",
              "error_class" => record["last_error_class"] || "unclassified"
            })
        end

      envelope = %{
        "version" => 1,
        "message_id" => message_id,
        "schema_id" => "elzoo/delivery-result",
        "schema_version" => 1,
        "kind" => if(result["outcome"] == "completed", do: "reply", else: "error"),
        "producer" => endpoint("gateway", "reply"),
        "causation_id" => request["message_id"],
        "correlation_id" => base["correlation_id"],
        "payload" => result
      }

      envelope = Map.merge(envelope, Map.take(request, ["deadline_unix_ms"]))

      with {:ok, _} <- reply_phase(Elzoo.Envelope.validate_result(result), :result),
           do: reply_phase(Elzoo.Envelope.validate(envelope), :reply)
    end
  end

  defp settlement_matches(base, {kind, settled})
       when kind in [:completed, :dead_lettered, :unsettled] and is_map(settled) do
    attempt = if kind == :completed, do: "attempt_id", else: "last_attempt_id"

    if Map.take(settled, ~w(message_id correlation_id deadline_unix_ms)) ==
         Map.take(base, ~w(message_id correlation_id deadline_unix_ms)) and
         (not Map.has_key?(settled, attempt) or
            attempt_of?(settled[attempt], base["message_id"])),
       do: :ok,
       else: {:error, {:settlement, :identity_mismatch}}
  end

  defp settlement_matches(_, _), do: {:error, {:settlement, :invalid}}

  defp attempt_of?(id, message_id) when is_binary(id) and is_binary(message_id),
    do: String.starts_with?(id, message_id <> "/attempt/")

  defp attempt_of?(_, _), do: false

  defp identity(envelope),
    do:
      envelope
      |> Map.take(~w(message_id attempt_id deadline_unix_ms))
      |> Map.merge(%{
        "version" => 1,
        "correlation_id" => Map.get(envelope, "correlation_id", envelope["message_id"])
      })

  defp failure(base, outcome, dispatch),
    do:
      Map.merge(base, %{
        "outcome" => outcome,
        "dispatch" => dispatch,
        "error_class" => "unclassified"
      })

  defp completed(base, label, n),
    do:
      Map.merge(base, %{
        "outcome" => "completed",
        "dispatch" => "dispatched",
        "value" => %{"decision" => label, "total" => n},
        "value_schema_id" => "example/rr-result",
        "value_schema_version" => 1
      })

  defp valid_units?(units, placement) when is_map(units) do
    keys = if placement == :fused, do: ["worker"], else: ["dedup", "accumulate"]

    Enum.sort(Map.keys(units)) == Enum.sort(keys) and
      Enum.all?(
        Map.values(units),
        &(is_pid(&1) or is_function(&1, 0) or &1 in [nil, :restarting, :undefined])
      )
  end

  defp valid_units?(_, _), do: false
  defp phase({:ok, value}, _), do: {:ok, value}
  defp phase({:error, reason}, phase), do: {:error, {:topology, phase, reason}}
  defp reply_phase({:ok, value}, _), do: {:ok, value}
  defp reply_phase({:error, reason}, phase), do: {:error, {phase, reason}}

  defp port(id, direction, schema),
    do: %{
      "id" => id,
      "direction" => direction,
      "schema_id" => if(String.contains?(schema, "/"), do: schema, else: "example/" <> schema),
      "schema_version" => 1
    }

  defp binding(id, direction, schema, delivery \\ "volatile", required \\ true),
    do: %{
      "port" => port(id, direction, schema),
      "delivery" => delivery,
      "required_route" => required
    }

  defp unit(id, ports), do: %{"id" => id, "ports" => ports}
  defp endpoint(unit, port), do: %{"unit_id" => unit, "port_id" => port}

  defp edge(id, placement, su, sp, tu, tp),
    do: %{
      "id" => id,
      "placement" => placement,
      "source" => endpoint(su, sp),
      "target" => endpoint(tu, tp)
    }

  defp candidate(id, face, delivery),
    do: %{
      "piece_id" => "request-route-retry/" <> id,
      "interface" => face,
      "delivery" => delivery,
      "rank" => 0
    }
end
