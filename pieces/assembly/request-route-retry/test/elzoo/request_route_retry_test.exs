# SPDX-License-Identifier: Apache-2.0
defmodule Elzoo.RequestRouteRetryTest do
  use ExUnit.Case, async: false
  alias Elzoo.RequestRouteRetry, as: R
  alias Elzoo.RequestRouteRetry.Codec
  @source File.read!(Path.expand("../../cure/elzoo/request_route_retry.cure", __DIR__))
  @roots Mix.Project.config() |> Keyword.get(:cure_paths, ["cure"]) |> Enum.map(&Path.expand/1)

  test "S1/S2 topology, declared endpoints and selection; first failing dependency" do
    for placement <- [:fused, :hop] do
      data = R.topology(placement)
      id = "request-route-retry/#{placement}-worker"
      assert R.check_topology(placement) == {:ok, %{"selected" => id}}
      assert {:ok, [{0, [^id]}]} = Elzoo.Selection.rank(data["requirement"], data["candidates"])
      assert data["requirement"]["downstream"]["id"] == "result.in"

      broken =
        update_in(data, ["wiring", "units"], fn units ->
          Enum.map(units, fn unit ->
            if unit["id"] == "gateway",
              do:
                update_in(unit, ["ports"], fn ports ->
                  Enum.map(ports, fn b ->
                    if b["port"]["id"] == "work",
                      do: put_in(b, ["port", "schema_version"], 2),
                      else: b
                  end)
                end),
              else: unit
          end)
        end)

      assert {:error, {:topology, :wiring, _}} = R.check_topology(broken)
      broken = put_in(data, ["routes", "routes"], [%{"edge_id" => "missing", "match" => %{}}])
      assert {:error, {:topology, :routing, _}} = R.check_topology(broken)
      broken = put_in(data, ["requirement", "delivery"], "durable")
      assert {:error, {:topology, :selection, _}} = R.check_topology(broken)
    end
  end

  test "config, exact codecs, invalid and empty traces" do
    assert R.initial_state(:fused, 0, 1) == {:error, :invalid_window}
    assert R.initial_state(:hop, 1, 0) == {:error, :invalid_max_senders}
    assert R.initial_state(:other, 1, 1) == {:error, :invalid_placement}
    assert R.start_link([]) == {:error, :invalid_options}
    assert R.start_link([{:placement, :fused} | :bad]) == {:error, :invalid_options}
    {:ok, %{"worker" => state}} = R.initial_state(:fused, 3, 1)
    assert R.direct(state, []) == {[], state}

    for codec <- [Codec.Worker, Codec.Dedup, Codec.Accumulate] do
      assert {:error, _} = codec.decode_payload("wrong", 1, nil)
      assert {:error, _} = codec.encode_output(:none)
      assert {:error, _} = codec.encode_output({:some, :bad})
    end

    assert {:error, _} =
             Codec.message(%{"sender" => "1", "incarnation" => 1, "sequence" => 1, "value" => 1})

    assert {:error, _} =
             Codec.Worker.encode_output({:some, {:RouteRetryOutput, :WindowInvalid, :none}})

    assert {:error, _} =
             Codec.Worker.encode_output({:some, {:RouteRetryOutput, :WindowFresh, :none}})

    assert {:error, _} =
             Codec.Dedup.encode_output(
               {:some, {:DedupOutcome, :WindowDuplicate, {:some, {:Message, 1, 1, 1, 1}}}}
             )
  end

  test "start-time placement and caller-owned Units work without the root Application" do
    tasks = start_supervised!({Task.Supervisor, []})
    {:ok, policy} = Elzoo.RetryTimeout.policy(max_attempts: 1)

    for placement <- [:fused, :hop] do
      {:ok, states} = R.initial_state(placement, 2, 1)

      units =
        Map.new(states, fn {name, state} ->
          {module, function} =
            case name do
              "worker" -> {:"Cure.Elzoo.RequestRouteRetry", :worker}
              "dedup" -> {:"Cure.Elzoo.RequestRouteRetry", :labelled_dedup}
              "accumulate" -> {:"Cure.Elzoo.Core", :accumulate}
            end

          {name, start_supervised!({Elzoo.Unit, {module, function, state}}, id: make_ref())}
        end)

      {:ok, runner} =
        R.start_link(
          placement: placement,
          units: units,
          window: 2,
          max_senders: 1,
          capacity: 1,
          policy: policy,
          task_supervisor: tasks,
          attempt_timeout_ms: 1000,
          dead_letter: fn _ -> :ok end
        )

      try do
        request = %{
          "version" => 1,
          "message_id" => "bundle",
          "schema_id" => "example/rr-request",
          "schema_version" => 1,
          "kind" => "command",
          "producer" => %{"unit_id" => "client", "port_id" => "request"},
          "payload" => %{"sender" => 1, "incarnation" => 1, "sequence" => 1, "value" => 7}
        }

        assert {:ok, ref} = R.submit(runner, request)
        assert_receive {Elzoo.RetryTimeout, ^ref, {:completed, result}}, 1000
        assert result["value"] == %{"decision" => "fresh", "total" => 7}
      after
        GenServer.stop(runner)
      end
    end
  end

  test "selected supplied-decision laws compile/audit; three executable negative controls" do
    assert {:module, :"Cure.Elzoo.RequestRouteRetry"} =
             Code.ensure_loaded(:"Cure.Elzoo.RequestRouteRetry")

    assert {:ok, env} = Cure.Compiler.check_source(@source, source_roots: @roots)
    report = Cure.Audit.Ledger.audit_env(env)

    for key <- [:axioms, :holes, :unresolved, :unaudited, :opaque, :not_proven_total],
        do: assert(Map.fetch!(report, key) == [])

    assert report.absurd == 0

    for law <-
          ~w(labelled_duplicate_keeps_state labelled_duplicate_not_accepted labelled_full_keeps_state) do
      assert function_exported?(:"Cure.Elzoo.RequestRouteRetry", String.to_existing_atom(law), 2)
      IO.puts("ELZ-008 law compiled: #{law}")
    end

    for {name, from, to} <- [
          {"FalseLabelLaw", "duplicate_answer(None())) =", "duplicate_answer(Some(input))) ="},
          {"MutatedLabelStep", "accepted: t.output", "accepted: Some(input)"},
          {"WrongLabelOperator", "Elzoo.Core.accumulate(state.right, message)",
           "Elzoo.Core.threshold(state.right, message)"}
        ] do
      assert String.contains?(@source, from)

      wrong =
        @source
        |> String.replace("mod Elzoo.RequestRouteRetry", "mod Elzoo." <> name)
        |> String.replace(from, to)

      assert {:error, _} = Cure.Compiler.compile_and_load(wrong, source_roots: @roots)
      IO.puts("ELZ-008 negative rejected: #{name}")
    end
  end
end
