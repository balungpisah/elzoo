# SPDX-License-Identifier: Apache-2.0
defmodule Elzoo.UnitAdapterTest do
  use ExUnit.Case, async: true
  import ExUnit.CaptureLog

  defmodule Codec do
    @behaviour Elzoo.UnitAdapter.Codec
    def decode_payload("test/input", 1, value) when is_integer(value), do: {:ok, value}
    def decode_payload(_, _, _), do: {:error, :invalid_payload}
    def encode_output(:none), do: {:ok, nil}
    def encode_output({:some, :unencodable}), do: {:error, :invalid_output}
    def encode_output({:some, value}), do: {:ok, value}
    def value_schema, do: {"test/output", 1}
  end

  defmodule AlternateCodec do
    @behaviour Elzoo.UnitAdapter.Codec
    def decode_payload("test/alternate", 1, value), do: {:ok, value + 10}
    def encode_output({:some, value}), do: {:ok, value * 2}
    def value_schema, do: {"test/alternate-output", 2}
  end

  defmodule Server do
    use GenServer
    def init(state), do: {:ok, state}

    def handle_call({:step, _}, _from, {:exit, parent, reason}) do
      send(parent, :step_entered)
      exit(reason)
    end

    def handle_call({:step, _}, _from, :silent), do: {:noreply, :silent}
    def handle_call({:step, _}, _from, {:reply, output} = state), do: {:reply, output, state}
  end

  for {name, schema} <- [
        {EmptySchema, {"", 1}},
        {InvalidUTF8Schema, {<<0xFF>>, 1}},
        {ZeroVersionSchema, {"x", 0}}
      ] do
    defmodule name do
      @behaviour Elzoo.UnitAdapter.Codec
      defdelegate decode_payload(schema, version, payload), to: Elzoo.UnitAdapterTest.Codec
      defdelegate encode_output(output), to: Elzoo.UnitAdapterTest.Codec
      def value_schema, do: unquote(Macro.escape(schema))
    end
  end

  def transition(state, input), do: {:Transition, state + input, {:some, state + input}}

  defp server(state) do
    {:ok, pid} = GenServer.start(Server, state)
    on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid) end)
    pid
  end

  defp wiring(schema \\ "test/input") do
    port = fn id, direction ->
      %{
        "port" => %{
          "id" => id,
          "direction" => direction,
          "schema_id" => schema,
          "schema_version" => 1
        },
        "delivery" => "fused",
        "required_route" => true
      }
    end

    %{
      "version" => 1,
      "units" => [%{"id" => "pipeline", "ports" => [port.("out", "output"), port.("in", "input")]}],
      "edges" => [
        %{
          "id" => "ingress",
          "placement" => "fused",
          "source" => %{"unit_id" => "pipeline", "port_id" => "out"},
          "target" => %{"unit_id" => "pipeline", "port_id" => "in"}
        }
      ]
    }
  end

  defp envelope do
    %{
      "version" => 1,
      "message_id" => "outer",
      "correlation_id" => "conversation",
      "attempt_id" => "attempt",
      "deadline_unix_ms" => 123,
      "schema_id" => "test/input",
      "schema_version" => 1,
      "kind" => "event",
      "producer" => %{"unit_id" => "pipeline", "port_id" => "out"},
      "payload" => 3,
      "idempotency_key" => "not-the-dedup-key",
      "sequence" => 99
    }
  end

  defp result(lookup, opts \\ []) do
    message = Keyword.get(opts, :envelope, envelope())

    assert {:ok, result} =
             Elzoo.UnitAdapter.deliver(
               lookup,
               Keyword.get(opts, :wiring, wiring()),
               Keyword.get(opts, :edge, "ingress"),
               message,
               Keyword.get(opts, :codec, Codec)
             )

    assert {:ok, ^result} = Elzoo.Envelope.validate_result(result)

    assert Map.take(result, ~w(message_id attempt_id deadline_unix_ms)) ==
             Map.take(message, ~w(message_id attempt_id deadline_unix_ms))

    assert result["correlation_id"] == Map.get(message, "correlation_id", message["message_id"])
    refute Map.has_key?(result, "payload")
    refute Map.has_key?(result, "idempotency_key")
    result
  end

  defp failure(result, outcome, dispatch, error) do
    assert result["outcome"] == outcome
    assert result["dispatch"] == dispatch
    assert result["error_class"] == error
    refute Map.has_key?(result, "value")

    assert Map.keys(result) |> Enum.sort() ==
             Enum.sort(
               ~w(version message_id correlation_id attempt_id deadline_unix_ms outcome dispatch error_class)
             )
  end

  test "invalid envelopes and wiring are caller errors" do
    assert {:error, {:envelope, :invalid_shape}} =
             Elzoo.UnitAdapter.deliver(nil, nil, "ingress", %{}, Codec)

    assert {:error, {:wiring, :invalid_shape}} =
             Elzoo.UnitAdapter.deliver(nil, nil, "ingress", envelope(), Codec)
  end

  test "route failures win before payload validation and lookup" do
    lookup = fn -> flunk("lookup must not run") end
    failure(result(lookup, edge: "missing"), "rejected", "not_dispatched", "permanent")

    for message <- [
          put_in(envelope(), ["producer", "unit_id"], "wrong"),
          put_in(envelope(), ["producer", "port_id"], "wrong"),
          Map.put(envelope(), "schema_id", "wrong"),
          Map.put(envelope(), "schema_version", 2)
        ] do
      failure(result(lookup, envelope: message), "rejected", "not_dispatched", "permanent")
    end
  end

  test "codec decode failure rejects before lookup" do
    failure(
      result(fn -> flunk("lookup must not run") end,
        envelope: Map.put(envelope(), "payload", %{"secret" => "raw"})
      ),
      "rejected",
      "not_dispatched",
      "permanent"
    )
  end

  test "only explicit pre-call absence is unavailable" do
    for absent <- [:restarting, :undefined, nil] do
      failure(result(fn -> absent end), "rejected", "not_dispatched", "unavailable")
    end
  end

  test "noproc after callback side effect leaves execution and dispatch unknown" do
    capture_log(fn ->
      pid = server({:exit, self(), :noproc})
      answer = result(pid)
      assert_received :step_entered
      failure(answer, "unknown", "unknown", "unclassified")
      refute answer["outcome"] == "completed"
      refute answer["dispatch"] == "not_dispatched"
    end)
  end

  test "a supplied dead pid also leaves dispatch unknown" do
    pid = server(:silent)
    GenServer.stop(pid)
    failure(result(pid), "unknown", "unknown", "unclassified")
  end

  test "other callback exits are unknown dispatched without exception data" do
    capture_log(fn ->
      failure(
        result(server({:exit, self(), {:crash, "private"}})),
        "unknown",
        "dispatched",
        "unclassified"
      )

      assert_received :step_entered
    end)
  end

  @tag timeout: 10_000
  test "a nonreplying server observes the default OTP timeout" do
    failure(result(server(:silent)), "timed_out", "dispatched", "unclassified")
  end

  test "a callback can produce the same timeout exit reason" do
    capture_log(fn ->
      failure(
        result(server({:exit, self(), :timeout})),
        "timed_out",
        "dispatched",
        "unclassified"
      )

      assert_received :step_entered
    end)
  end

  test "bad output and encode failure are failed after dispatch" do
    for output <- [:bad, {:some, :unencodable}] do
      failure(result(server({:reply, output})), "failed", "dispatched", "unclassified")
    end
  end

  test "none is completed suppression with nil and a value schema" do
    answer = result(server({:reply, :none}), envelope: Map.delete(envelope(), "correlation_id"))
    assert answer["outcome"] == "completed"
    assert answer["dispatch"] == "dispatched"
    assert Map.fetch!(answer, "value") == nil
    assert answer["value_schema_id"] == "test/output"
    assert answer["value_schema_version"] == 1
    refute Map.has_key?(answer, "error_class")
  end

  test "fresh Unit output and per-call codec and wiring selection" do
    pid = start_supervised!({Elzoo.Unit, {__MODULE__, :transition, 0}})
    assert result(fn -> pid end)["value"] == 3

    answer =
      result(pid,
        wiring: wiring("test/alternate"),
        codec: AlternateCodec,
        envelope: Map.put(envelope(), "schema_id", "test/alternate")
      )

    assert answer["value"] == 32
    assert answer["outcome"] == "completed"
    assert answer["dispatch"] == "dispatched"
    assert answer["value_schema_id"] == "test/alternate-output"
    assert answer["value_schema_version"] == 2
    assert Elzoo.Unit.snapshot(pid) == {__MODULE__, :transition, 16}
  end

  test "invalid codec schemas fail after dispatch with valid identity and no foreign reason" do
    for codec <- [EmptySchema, InvalidUTF8Schema, ZeroVersionSchema],
        output <- [:none, {:some, 10}] do
      failure(
        result(server({:reply, output}), codec: codec),
        "failed",
        "dispatched",
        "unclassified"
      )
    end
  end
end
