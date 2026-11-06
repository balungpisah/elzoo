# SPDX-License-Identifier: Apache-2.0
defmodule Elzoo.RequestRouteRetryCompositionTest do
  use ExUnit.Case, async: false
  alias Elzoo.RequestRouteRetry, as: R
  alias Elzoo.RetryTimeout, as: Retry
  @core :"Cure.Elzoo.RequestRouteRetry"

  defmodule Stub do
    use GenServer
    def start_link(opts), do: GenServer.start_link(__MODULE__, opts)
    def init(opts), do: {:ok, opts}

    def handle_call({:step, input}, _from, opts) do
      send(opts[:parent], {:dispatch, self(), input})
      Process.sleep(opts[:delay] || 0)

      case opts[:operator] do
        {module, function, state} ->
          {:Transition, state, output} = apply(module, function, [state, input])

          {:reply, output,
           Keyword.put(opts, :operator, {module, function, state}) |> Keyword.put(:delay, 0)}

        nil ->
          {:reply, opts[:output] || :bad, opts}
      end
    end
  end

  defp payload(s \\ 1, i \\ 1, q \\ 1, v \\ 10),
    do: %{"sender" => s, "incarnation" => i, "sequence" => q, "value" => v}

  defp request(id, payload \\ payload()),
    do: %{
      "version" => 1,
      "message_id" => id,
      "kind" => "command",
      "schema_id" => "example/rr-request",
      "schema_version" => 1,
      "producer" => %{"unit_id" => "client", "port_id" => "request"},
      "reply_to" => %{"unit_id" => "client", "port_id" => "reply.in"},
      "payload" => payload
    }

  defp child(module, opts),
    do: start_supervised!(%{id: make_ref(), start: {module, :start_link, [opts]}})

  defp units(placement) do
    {:ok, states} = R.initial_state(placement, 3, 1)

    Map.new(states, fn {name, state} ->
      {module, function} =
        case name do
          "worker" -> {@core, :worker}
          "dedup" -> {@core, :labelled_dedup}
          "accumulate" -> {:"Cure.Elzoo.Core", :accumulate}
        end

      {name, child(Elzoo.Unit, {module, function, state})}
    end)
  end

  defp runner(placement, units, opts \\ []) do
    tasks = child(Task.Supervisor, [])

    {:ok, policy} =
      Retry.policy(
        Keyword.get(opts, :policy_opts, max_attempts: 3, base_backoff_ms: 0, max_backoff_ms: 0)
      )

    options = [
      placement: placement,
      units: units,
      window: 3,
      max_senders: 1,
      capacity: 4,
      policy: policy,
      attempt_timeout_ms: 1000,
      task_supervisor: tasks,
      dead_letter: fn _ -> :ok end
    ]

    child(R, Keyword.merge(options, Keyword.drop(opts, [:policy_opts])))
  end

  defp settle(runner, request) do
    assert {:ok, ref} = R.submit(runner, request)

    receive do
      {Retry, ^ref, settlement} -> settlement
    after
      3000 -> flunk("missing settlement")
    end
  end

  defp completed(runner, request) do
    assert {:completed, result} = settle(runner, request)
    assert {:ok, ^result} = Elzoo.Envelope.validate_result(result)

    assert {:ok, ^result} =
             Elzoo.RequestReply.correlate(
               Map.put(request, "attempt_id", request["message_id"] <> "/attempt/1"),
               result
             )

    assert result["value_schema_id"] == "example/rr-result"
    assert result["value_schema_version"] == 1
    result
  end

  test "S3/S4/S5/S7/S21 crash-free direct/fused/hop trace; all decision labels and exact schemas" do
    trace = [
      payload(),
      payload(),
      payload(1, 1, 3),
      payload(1, 1, 2),
      payload(1, 1, 5),
      payload(1, 1, 1),
      payload(1, 0, 6),
      payload(2),
      payload(1, 2, 1)
    ]

    {:ok, %{"worker" => initial}} = R.initial_state(:fused, 3, 1)
    {expected, _} = R.direct(initial, trace)

    assert Enum.map(expected, & &1["decision"]) ==
             ~w(fresh duplicate advance reorder advance stale superseded full new_incarnation)

    for placement <- [:fused, :hop] do
      units = units(placement)
      runner = runner(placement, units)

      actual =
        for {payload, index} <- Enum.with_index(trace) do
          req = request("trace-#{index}", payload)

          req =
            if rem(index, 2) == 0, do: Map.put(req, "correlation_id", "client-#{index}"), else: req

          completed(runner, req)["value"]
        end

      assert actual == expected
      assert Enum.at(actual, 1) == %{"decision" => "duplicate", "total" => nil}

      if placement == :hop,
        do: assert({_, :accumulate, 50} = Elzoo.Unit.snapshot(units["accumulate"]))
    end
  end

  test "S8 malformed payload is permanent; S9 first restarting exhausts, hop-2 restarting is unresolved" do
    for placement <- [:fused, :hop] do
      runner = runner(placement, units(placement))
      assert {:dead_lettered, record} = settle(runner, request("malformed", %{"value" => 1}))
      assert record["reason"] == "permanent"
      assert record["attempts"] == 1

      absent =
        if placement == :fused,
          do: %{"worker" => :restarting},
          else: %{"dedup" => :restarting, "accumulate" => :restarting}

      runner = runner(placement, absent)
      assert {:dead_lettered, record} = settle(runner, request("restarting"))
      assert record["reason"] == "retries_exhausted"
      assert record["attempts"] == 3
    end

    units = units(:hop) |> Map.put("accumulate", :restarting)
    runner = runner(:hop, units)
    assert {:dead_lettered, record} = settle(runner, request("hop-2"))
    assert record["reason"] == "dispatched_unresolved"
    assert record["last_dispatch"] == "dispatched"
    assert record["attempts"] == 1

    assert completed(runner, request("hop-2-again"))["value"] == %{
             "decision" => "duplicate",
             "total" => nil
           }
  end

  test "S6/S10/S13 a bounded slow Unit has one dispatch, correlation refusal and capacity release" do
    stub = child(Stub, parent: self(), delay: 150)
    runner = runner(:fused, %{"worker" => stub}, capacity: 1, attempt_timeout_ms: 40)
    req = request("slow")
    assert {:ok, ref} = R.submit(runner, req)
    assert_receive {:dispatch, ^stub, _}
    assert {:error, :operation_in_flight} = R.submit(runner, req)
    assert {:error, {:saturated, _}} = R.submit(runner, request("saturated"))
    assert_receive {Retry, ^ref, {:dead_lettered, record}}, 1000
    assert record["reason"] == "dispatched_unresolved"
    assert record["attempts"] == 1
    assert record["last_outcome"] == "timed_out"
    assert Retry.Runner.snapshot(runner).in_flight == 0
    refute_receive {:dispatch, ^stub, _}, 10
  end

  test "S11 bounded serialized Unit applies once; idempotent retry returns duplicate" do
    {:ok, %{"worker" => initial}} = R.initial_state(:fused, 3, 1)
    stub = child(Stub, parent: self(), delay: 80, operator: {@core, :worker, initial})

    runner =
      runner(:fused, %{"worker" => stub},
        attempt_timeout_ms: 50,
        policy_opts: [
          max_attempts: 3,
          base_backoff_ms: 70,
          max_backoff_ms: 70,
          mode: :redispatch_idempotent
        ]
      )

    assert {:completed, result} = settle(runner, request("idempotent"))
    assert result["value"] == %{"decision" => "duplicate", "total" => nil}
    assert result["attempt_id"] == "idempotent/attempt/2"
    assert_receive {:dispatch, ^stub, _}
    assert_receive {:dispatch, ^stub, _}
    refute_receive {:dispatch, ^stub, _}, 10
    {_, opts} = {:state, :sys.get_state(stub)}
    assert {_, :worker, {:Joined, _, 10}} = opts[:operator]
  end

  test "S12/S17 dead receiver is never not_dispatched; hop dedup advance is not atomic" do
    dead = spawn(fn -> :ok end)
    monitor = Process.monitor(dead)
    assert_receive {:DOWN, ^monitor, :process, ^dead, _}

    for {placement, units} <- [
          {:fused, %{"worker" => dead}},
          {:hop, Map.put(units(:hop), "accumulate", dead)}
        ] do
      runner = runner(placement, units)
      assert {:dead_lettered, record} = settle(runner, request("dead"))
      assert record["reason"] == "dispatched_unresolved"
      assert record["last_dispatch"] != "not_dispatched"
      assert record["attempts"] == 1

      if placement == :hop,
        do:
          assert(
            completed(runner, request("lost"))["value"] == %{
              "decision" => "duplicate",
              "total" => nil
            }
          )
    end
  end

  test "S14/S15 deadlines before dispatch and during flight" do
    stub = child(Stub, parent: self(), delay: 150)
    runner = runner(:fused, %{"worker" => stub}, now_ms: fn -> 1000 end)

    assert {:error, {:expired, _}} =
             R.submit(runner, Map.put(request("expired"), "deadline_unix_ms", 999))

    refute_receive {:dispatch, ^stub, _}, 10
    assert {:ok, ref} = R.submit(runner, Map.put(request("flight"), "deadline_unix_ms", 1040))
    assert_receive {:dispatch, ^stub, _}
    assert_receive {Retry, ^ref, {:dead_lettered, record}}, 1000
    assert record["reason"] == "deadline_expired"
  end

  test "S16 source/kind refusals do not dispatch; S18 sink non-ok and raise are unsettled" do
    stub = child(Stub, parent: self())
    runner = runner(:fused, %{"worker" => stub})

    assert {:error, {:route, :no_route}} =
             R.submit(runner, Map.put(request("event"), "kind", "event"))

    assert {:error, {:source, :producer_mismatch}} =
             R.submit(runner, put_in(request("foreign"), ["producer", "unit_id"], "foreign"))

    refute_receive {:dispatch, ^stub, _}, 10

    for sink <- [fn _ -> {:error, :offline} end, fn _ -> raise "sink" end] do
      runner = runner(:fused, %{"worker" => :restarting}, dead_letter: sink)
      assert {:unsettled, record} = settle(runner, request("sink"))
      assert record["reason"] == "retries_exhausted"
    end
  end

  test "S19 reply client identity and exact deadline Option for completed and dead-lettered" do
    for placement <- [:fused, :hop], deadline <- [nil, 10_000], success <- [true, false] do
      runner = runner(placement, units(placement), now_ms: fn -> 1000 end)
      req = request("reply", if(success, do: payload(), else: :malformed))
      req = if deadline, do: Map.put(req, "deadline_unix_ms", deadline), else: req
      settlement = settle(runner, req)
      assert {:ok, reply} = R.reply(req, settlement, "reply-envelope")
      result = reply["payload"]
      assert result["message_id"] == "reply"
      refute Map.has_key?(result, "attempt_id")
      assert Map.take(result, ["deadline_unix_ms"]) == Map.take(req, ["deadline_unix_ms"])
      assert Map.take(reply, ["deadline_unix_ms"]) == Map.take(req, ["deadline_unix_ms"])
      assert {:ok, ^result} = Elzoo.RequestReply.accept_reply(req, reply, req["reply_to"])

      assert {:error, _} =
               Elzoo.RequestReply.accept_reply(req, reply, %{
                 "unit_id" => "wrong",
                 "port_id" => "reply.in"
               })

      other = request("other-reply") |> Map.merge(Map.take(req, ["deadline_unix_ms"]))
      foreign = settle(runner, other)

      assert {:error, {:settlement, :identity_mismatch}} =
               R.reply(req, foreign, "reply-envelope")

      {kind, settled} = settlement
      shifted = {kind, Map.put(settled, "deadline_unix_ms", (deadline || 0) + 1)}
      assert {:error, {:settlement, :identity_mismatch}} = R.reply(req, shifted, "reply-envelope")

      attempt_key = if kind == :completed, do: "attempt_id", else: "last_attempt_id"
      odd = {kind, Map.put(settled, attempt_key, %{"bad" => 1})}
      assert {:error, {:settlement, :identity_mismatch}} = R.reply(req, odd, "reply-envelope")
      assert {:error, {:settlement, :invalid}} = R.reply(req, {:other, %{}}, "reply-envelope")

      if deadline do
        for broken <- [
              update_in(reply, ["payload"], &Map.delete(&1, "deadline_unix_ms")),
              put_in(reply, ["payload", "deadline_unix_ms"], deadline + 1)
            ] do
          assert {:error, _} = Elzoo.RequestReply.accept_reply(req, broken, req["reply_to"])
        end
      end
    end
  end

  test "S20 seeded mixed trace totality and attempt bound" do
    :rand.seed(:exsss, {8, 20, 22})
    runner = runner(:fused, units(:fused))

    for n <- 1..30 do
      req = request("mixed-#{n}", payload(1, 1, :rand.uniform(8)))

      req =
        case rem(n, 5) do
          0 -> Map.put(req, "kind", "event")
          1 -> Map.put(req, "payload", nil)
          _ -> req
        end

      case R.submit(runner, req) do
        {:error, {:route, :no_route}} ->
          :ok

        {:ok, ref} ->
          assert_receive {Retry, ^ref, settlement}, 1000

          case settlement do
            {:completed, _} -> :ok
            {:dead_lettered, record} -> assert record["attempts"] in 1..3
          end

          refute_receive {Retry, ^ref, _}, 1
      end
    end
  end

  test "S21 malformed labelled/total outputs fail after dispatch; S22 worker restart resets window" do
    for placement <- [:fused, :hop] do
      units = units(placement)
      runner = runner(placement, units)
      assert completed(runner, request("before"))["value"]["decision"] == "fresh"
      name = if placement == :fused, do: "worker", else: "dedup"
      GenServer.stop(units[name])
      fresh = units(placement)
      runner = runner(placement, fresh)
      assert completed(runner, request("after"))["value"]["decision"] == "fresh"
    end

    for {placement, name, output} <- [
          {:fused, "worker", {:some, {:RouteRetryOutput, :WindowFresh, :none}}},
          {:hop, "dedup", {:some, {:DedupOutcome, :WindowFresh, :none}}},
          {:hop, "accumulate", {:some, "not-an-integer"}}
        ] do
      stub = child(Stub, parent: self(), output: output)
      runner = runner(placement, Map.put(units(placement), name, stub))
      assert {:dead_lettered, record} = settle(runner, request("invalid-output"))
      assert record["last_outcome"] == "failed"
      assert record["last_dispatch"] == "dispatched"
      assert record["last_error_class"] == "unclassified"
    end
  end

  test "S21 production helper probe rejects malformed intermediate metadata and rebuilt results" do
    source =
      File.read!(
        Path.expand(
          "../pieces/assembly/request-route-retry/lib/elzoo/request_route_retry.ex",
          __DIR__
        )
      )

    source =
      source
      |> String.replace(
        "defmodule Elzoo.RequestRouteRetry do",
        "defmodule Elzoo.RequestRouteRetryBoundaryProbe do"
      )
      |> String.replace("defp combine_hop(", "def combine_hop(")
      |> String.replace("defp finalize_result(", "def finalize_result(")

    Code.compile_string(source)
    probe = Elzoo.RequestRouteRetryBoundaryProbe
    outer = request("probe") |> Map.put("attempt_id", "probe/attempt/1")

    base = %{
      "version" => 1,
      "message_id" => "inner",
      "correlation_id" => "probe",
      "attempt_id" => outer["attempt_id"],
      "outcome" => "completed",
      "dispatch" => "dispatched"
    }

    first =
      Map.merge(base, %{
        "value_schema_id" => "example/rr-dedup-outcome",
        "value_schema_version" => 1,
        "value" => %{"decision" => "fresh", "accepted" => payload()}
      })

    second =
      Map.merge(base, %{
        "value_schema_id" => "example/rr-total",
        "value_schema_version" => 1,
        "value" => 10
      })

    assert apply(probe, :combine_hop, [first, {"fresh", second}])["value"] == %{
             "decision" => "fresh",
             "total" => 10
           }

    for {a, b} <- [
          {Map.put(first, "value_schema_version", 2), {"fresh", second}},
          {put_in(first, ["value", "decision"], "arbitrary"), {"fresh", second}},
          {Map.put(first, "value", %{"decision" => "duplicate", "accepted" => payload()}),
           :not_attempted},
          {first, {"fresh", Map.put(second, "value_schema_id", "wrong")}},
          {first, {"fresh", Map.put(second, "value", "wrong")}}
        ] do
      result = apply(probe, :combine_hop, [a, b])
      assert result["outcome"] == "failed"
      assert result["dispatch"] == "dispatched"
      refute Map.has_key?(result, "value")
    end

    combined = apply(probe, :combine_hop, [first, {"fresh", second}])

    for invalid <- [
          Map.put(combined, "dispatch", "not_dispatched"),
          Map.put(combined, "extra", true),
          Map.put(combined, "value_schema_id", "wrong"),
          put_in(combined, ["value", "total"], nil)
        ] do
      result = apply(probe, :finalize_result, [outer, invalid])
      assert result["outcome"] == "failed"
      assert result["dispatch"] == "dispatched"
      assert {:ok, ^result} = Elzoo.Envelope.validate_result(result)
      refute Map.has_key?(result, "value")
    end

    result = apply(probe, :finalize_result, [outer, Map.put(combined, "correlation_id", "wrong")])
    assert result["outcome"] == "unknown"
    assert result["dispatch"] == "unknown"
  end
end
