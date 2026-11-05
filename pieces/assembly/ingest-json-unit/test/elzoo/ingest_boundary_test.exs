# SPDX-License-Identifier: Apache-2.0
host_recipe = Path.expand("../../examples/elzoo/host.exs", __DIR__)

host_recipe =
  if File.regular?(host_recipe),
    do: host_recipe,
    else: Path.expand("../../../../runtime/host/examples/elzoo/host.exs", __DIR__)

Code.require_file(host_recipe)

defmodule Elzoo.IngestBoundaryTest do
  use ExUnit.Case, async: true
  import ExUnit.CaptureLog

  defmodule Fake do
    use GenServer
    def init(state), do: {:ok, state}

    def handle_call({:step, input}, _from, {parent, action} = state) do
      send(parent, {:stepped, self(), input})

      case action do
        {:reply, value} -> {:reply, value, state}
        {:exit, reason} -> exit(reason)
      end
    end
  end

  defmodule Unencodable do
    @behaviour Elzoo.UnitAdapter.Codec
    defdelegate decode_payload(s, v, p), to: Elzoo.IngestCodec.Count
    def encode_output(_), do: {:ok, self()}
    defdelegate value_schema(), to: Elzoo.IngestCodec.Count
  end

  defmodule RejectTotal do
    @behaviour Elzoo.UnitAdapter.Codec
    def decode_payload(_, _, _), do: {:error, :invalid_payload}
    defdelegate encode_output(o), to: Elzoo.IngestCodec.Total
    defdelegate value_schema(), to: Elzoo.IngestCodec.Total
  end

  defp fake(action) do
    {:ok, pid} = GenServer.start(Fake, {self(), action})
    on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid) end)
    pid
  end

  defp host(placement) do
    core = :"Cure.Elzoo.Core"

    children =
      case placement do
        :fused ->
          [{"pipeline", {core, :assembly, apply(core, :empty, [])}}]

        :hop ->
          [
            {"dedup", {:"Cure.Elzoo.Idempotency", :receiver, []}},
            {"accumulate", {core, :accumulate, 0}}
          ]
      end

    {:ok, sup} = Elzoo.IngestHost.start_link(children)
    Process.unlink(sup)
    on_exit(fn -> if Process.alive?(sup), do: Supervisor.stop(sup) end)
    units = Map.new(children, fn {id, _} -> {id, fn -> Elzoo.IngestHost.lookup(sup, id) end} end)
    {sup, units}
  end

  defp envelope(placement, fields \\ {1, 1, 1, 10}) do
    {s, i, q, v} = fields

    producer =
      case placement do
        :fused -> %{"unit_id" => "pipeline", "port_id" => "ingress.request"}
        :hop -> %{"unit_id" => "client", "port_id" => "request"}
      end

    %{
      "version" => 1,
      "message_id" => "outer",
      "correlation_id" => "conversation",
      "attempt_id" => "attempt",
      "deadline_unix_ms" => 42,
      "kind" => "event",
      "producer" => producer,
      "schema_id" => "example/ingest-message",
      "schema_version" => 1,
      "payload" => %{"sender" => s, "incarnation" => i, "sequence" => q, "value" => v}
    }
  end

  defp result(placement, units, message \\ nil, opts \\ []) do
    message = message || envelope(placement)
    assert {:ok, json} = Elzoo.IngestBoundary.handle(placement, units, Jason.encode!(message), opts)
    answer = Jason.decode!(json)
    assert {:ok, ^answer} = Elzoo.Envelope.validate_result(answer)

    assert Map.take(answer, ~w(message_id attempt_id deadline_unix_ms)) ==
             Map.take(message, ~w(message_id attempt_id deadline_unix_ms))

    assert answer["correlation_id"] == Map.get(message, "correlation_id", message["message_id"])
    refute String.contains?(json, "Message")
    refute Map.has_key?(answer, "payload")
    answer
  end

  defp failure(result, outcome, dispatch) do
    assert result["outcome"] == outcome
    assert result["dispatch"] == dispatch
    assert result["error_class"] == "unclassified"
    refute Map.has_key?(result, "value")
  end

  test "named crash-free trace matches direct fused totals and suppression in both placements" do
    trace = [{1, 1, 4, 10}, {1, 1, 4, 999}, {1, 1, 2, 3}, {2, 1, 4, 7}, {1, 2, 4, 5}, {1, 1, 4, 10}]
    compare(trace)
  end

  test "seeded model traces and empty input match in both placements" do
    :rand.seed(:exsss, {17, 29, 43})

    traces =
      for _ <- 1..20 do
        for _ <- 1..30,
            do: {:rand.uniform(3), :rand.uniform(2), :rand.uniform(8), :rand.uniform(101) - 51}
      end

    Enum.each([[] | traces], &compare/1)
  end

  defp compare(trace) do
    messages = Enum.map(trace, fn {s, i, q, v} -> Elzoo.Runtime.message(s, i, q, v) end)
    {direct, _} = Elzoo.Runtime.fused(messages)

    {model, _} =
      Enum.map_reduce(trace, {MapSet.new(), 0}, fn {s, i, q, v}, {seen, total} ->
        key = {s, i, q}

        if MapSet.member?(seen, key),
          do: {nil, {seen, total}},
          else: {total + v, {MapSet.put(seen, key), total + v}}
      end)

    assert Enum.map(direct, fn
             :none -> nil
             {:some, v} -> v
           end) == model

    for placement <- [:fused, :hop] do
      {sup, units} = host(placement)

      actual =
        Enum.map(trace, fn fields ->
          answer = result(placement, units, envelope(placement, fields))
          assert answer["outcome"] == "completed"
          assert answer["dispatch"] == "dispatched"
          assert answer["value_schema_id"] == "example/optional-count"
          Map.fetch!(answer, "value")
        end)

      assert actual == model
      Supervisor.stop(sup)
    end
  end

  test "JSON errors and envelope errors are redacted and produce no own logs" do
    assert capture_log(fn ->
             assert {:error, :invalid_json} =
                      Elzoo.IngestBoundary.handle(:fused, %{}, "secret-invalid-json")

             for json <- ["null", "[]", "1", "{}"] do
               assert {:error, :invalid_envelope} = Elzoo.IngestBoundary.handle(:fused, %{}, json)
             end
           end) == ""
  end

  test "strict integer codecs reject wrong values, shapes and schemas" do
    for placement <- [:fused, :hop] do
      {_, units} = host(placement)

      for key <- ~w(sender incarnation sequence value), bad <- [1.0, 1.5, true, false, nil, "1"] do
        answer = result(placement, units, put_in(envelope(placement), ["payload", key], bad))
        assert answer["outcome"] == "rejected"
      end

      for payload <- [
            Map.delete(envelope(placement)["payload"], "value"),
            Map.put(envelope(placement)["payload"], "extra", 1)
          ] do
        assert result(placement, units, Map.put(envelope(placement), "payload", payload))["outcome"] ==
                 "rejected"
      end

      for {key, value} <- [{"schema_id", "wrong"}, {"schema_version", 2}] do
        assert result(placement, units, Map.put(envelope(placement), key, value))["outcome"] ==
                 "rejected"
      end
    end

    for codec <- [Elzoo.IngestCodec.Count, Elzoo.IngestCodec.Accepted, Elzoo.IngestCodec.Total] do
      assert {:error, :unsupported_schema} = codec.decode_payload("wrong", 1, nil)
    end

    assert {:error, :invalid_payload} =
             Elzoo.IngestCodec.Total.decode_payload(
               "example/accepted-message",
               1,
               {:Message, 1, 1, 1, 1.0}
             )

    huge = Integer.pow(2, 150)
    {_, units} = host(:fused)
    assert result(:fused, units, envelope(:fused, {huge, -huge, huge, huge}))["value"] == huge
  end

  test "producer mismatch is rejected without rewriting" do
    for placement <- [:fused, :hop] do
      lookup = fn -> flunk("mismatched producer dispatched") end
      units = %{"pipeline" => lookup, "dedup" => lookup}

      answer =
        result(placement, units, put_in(envelope(placement), ["producer", "unit_id"], "wrong"))

      assert answer["outcome"] == "rejected"
      assert answer["dispatch"] == "not_dispatched"

      answer =
        result(placement, units, put_in(envelope(placement), ["producer", "port_id"], "wrong"))

      assert answer["outcome"] == "rejected"
      assert answer["dispatch"] == "not_dispatched"
    end
  end

  test "optional metadata can be absent and correlation falls back to message ID" do
    for placement <- [:fused, :hop] do
      {_, units} = host(placement)
      message = Map.drop(envelope(placement), ~w(correlation_id attempt_id deadline_unix_ms))
      answer = result(placement, units, message)
      assert answer["correlation_id"] == message["message_id"]
      assert answer["value"] == 10
      refute Map.has_key?(answer, "attempt_id")
      refute Map.has_key?(answer, "deadline_unix_ms")
    end
  end

  test "first-hop failures pass through unchanged and never call accumulate" do
    capture_log(fn ->
      for {lookup, outcome, dispatch} <- [
            {fn -> :restarting end, "rejected", "not_dispatched"},
            {fake({:exit, :timeout}), "timed_out", "dispatched"},
            {fake({:exit, :noproc}), "unknown", "unknown"},
            {fake({:reply, :bad}), "failed", "dispatched"}
          ] do
        units = %{"dedup" => lookup, "accumulate" => fn -> flunk("second hop ran") end}
        answer = result(:hop, units)
        assert answer["outcome"] == outcome
        assert answer["dispatch"] == dispatch
      end
    end)
  end

  test "completed duplicate skips accumulate and returns nil" do
    answer =
      result(:hop, %{
        "dedup" => fake({:reply, :none}),
        "accumulate" => fn -> flunk("duplicate dispatched") end
      })

    assert answer["outcome"] == "completed"
    assert Map.fetch!(answer, "value") == nil
  end

  test "completed second hop has outer identity and encoded total" do
    pid = fake({:reply, {:some, 10}})

    answer =
      result(:hop, %{
        "dedup" => fake({:reply, {:some, Elzoo.Runtime.message(1, 1, 1, 10)}}),
        "accumulate" => pid
      })

    assert answer["outcome"] == "completed"
    assert answer["value"] == 10
    assert_received {:stepped, ^pid, {:Message, 1, 1, 1, 10}}
  end

  test "second-hop unavailable or payload rejection is failed after dedup advanced" do
    {_, units} = host(:hop)

    failure(
      result(:hop, Map.put(units, "accumulate", fn -> :undefined end)),
      "failed",
      "dispatched"
    )

    assert result(:hop, units)["value"] == nil
    {_, fresh} = host(:hop)
    failure(result(:hop, fresh, nil, codecs: %{total: RejectTotal}), "failed", "dispatched")
  end

  test "second-hop timeout is timed_out dispatched" do
    capture_log(fn ->
      {_, units} = host(:hop)

      failure(
        result(:hop, Map.put(units, "accumulate", fake({:exit, :timeout}))),
        "timed_out",
        "dispatched"
      )
    end)
  end

  test "second-hop unknown with either dispatch is outer unknown dispatched" do
    capture_log(fn ->
      for reason <- [:noproc, :crash] do
        {_, units} = host(:hop)

        failure(
          result(:hop, Map.put(units, "accumulate", fake({:exit, reason}))),
          "unknown",
          "dispatched"
        )
      end
    end)
  end

  test "second-hop failed is outer failed dispatched" do
    {_, units} = host(:hop)

    failure(
      result(:hop, Map.put(units, "accumulate", fake({:reply, :bad}))),
      "failed",
      "dispatched"
    )
  end

  test "unencodable injected codec output uses redacted JSON fallback" do
    for {placement, override} <- [{:fused, %{count: Unencodable}}, {:hop, %{total: Unencodable}}] do
      {_, units} = host(placement)

      assert capture_log(fn ->
               failure(result(placement, units, nil, codecs: override), "failed", "dispatched")
             end) == ""
    end
  end

  test "restart loses history and re-accepts the same key through Boundary" do
    for placement <- [:fused, :hop] do
      {sup, units} = host(placement)
      assert result(placement, units)["value"] == 10
      assert result(placement, units)["value"] == nil
      id = if placement == :fused, do: "pipeline", else: "dedup"
      old = Elzoo.IngestHost.lookup(sup, id)
      Process.exit(old, :kill)
      replacement(sup, id, old, 1000)
      expected = if placement == :fused, do: 10, else: 20
      assert result(placement, units)["value"] == expected
    end
  end

  defp replacement(_, _, _, 0), do: flunk("no replacement")

  defp replacement(sup, id, old, n) do
    case Elzoo.IngestHost.lookup(sup, id) do
      pid when is_pid(pid) and pid != old -> pid
      _ -> replacement(sup, id, old, n - 1)
    end
  end
end
