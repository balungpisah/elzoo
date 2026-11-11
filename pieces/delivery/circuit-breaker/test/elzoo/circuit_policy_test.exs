# SPDX-License-Identifier: Apache-2.0
defmodule Elzoo.CircuitPolicyTest do
  use ExUnit.Case, async: true
  @source File.read!(Path.expand("../../cure/elzoo/circuit_policy.cure", __DIR__))
  @roots [Path.expand("../../cure", __DIR__)]
  @policy :"Cure.Elzoo.CircuitPolicy"

  test "C1 production decision table agrees with an independent finite table" do
    for mode <- [:Closed, :Open, :HalfOpen, :Unavailable],
        held <- [true, false],
        {now, target} <- [{-100, -99}, {-100, -100}, {-99, -100}] do
      expected =
        case mode do
          :Closed -> :Normal
          :Open -> if now < target, do: :RefuseOpen, else: :CheckReset
          :HalfOpen -> if held, do: :RefuseBusy, else: :Probe
          :Unavailable -> :RefuseUnavailable
        end

      assert apply(@policy, :admission, [mode, held, now, target]) == expected

      for current <- [true, false],
          probe <- [true, false],
          obs <- [:Healthy, :Unhealthy, :Neutral, :Unknown] do
        health =
          cond do
            not current -> {:Keep, mode}
            obs in [:Unhealthy, :Unknown] -> :Trip
            obs == :Healthy and probe -> :Close
            true -> {:Keep, mode}
          end

        assert apply(@policy, :observe, [mode, current, probe, obs]) == health
      end
    end
  end

  test "C2 four production laws audit cleanly and each production mutation fails at its law" do
    assert {:ok, env} = Cure.Compiler.check_source(@source, source_roots: @roots)
    report = Cure.Audit.Ledger.audit_env(env)

    for key <- [:axioms, :holes, :unresolved, :unaudited, :opaque, :not_proven_total],
        do: assert(Map.fetch!(report, key) == [])

    assert report.absurd == 0

    controls = [
      {"False() -> Keep(mode)\n      True() -> current_observation",
       "False() -> Trip()\n      True() -> current_observation",
       "stale_observation_cannot_change_health"},
      {"True() -> RefuseBusy()", "True() -> Probe()", "busy_probe_never_admits"},
      {"True() -> RefuseOpen()", "True() -> CheckReset()", "open_before_target_never_admits"},
      {"Neutral() -> Keep(mode)", "Neutral() -> Close()", "neutral_probe_never_closes"}
    ]

    for {{from, to, law}, index} <- Enum.with_index(controls) do
      assert length(String.split(@source, from)) == 2

      mutant =
        @source
        |> String.replace("mod Elzoo.CircuitPolicy", "mod Elzoo.CircuitMutant#{index}")
        |> String.replace(from, to)

      assert {:error, {:codegen_error, {:source_context, _, context}}} =
               Cure.Compiler.compile_and_load(mutant, source_roots: @roots)

      lines = String.split(@source, "\n")
      start = Enum.find_index(lines, &String.starts_with?(&1, "  fn #{law}("))
      assert context.line in (start + 1)..(start + 2)
    end

    false_law =
      @source
      |> String.replace("mod Elzoo.CircuitPolicy", "mod Elzoo.CircuitFalseLaw")
      |> String.replace(
        "observe(HalfOpen(), True(), True(), Neutral()), Keep(HalfOpen())",
        "observe(HalfOpen(), True(), True(), Neutral()), Close()"
      )

    assert {:error, {:codegen_error, {:source_context, _, _}}} =
             Cure.Compiler.compile_and_load(false_law, source_roots: @roots)

    hole =
      @source
      |> String.replace("mod Elzoo.CircuitPolicy", "mod Elzoo.CircuitHole")
      |> String.replace("reflexive(Keep(mode))", "?unfinished")

    assert {:error, {:codegen_error, {:unfilled_hole, _}}} =
             Cure.Compiler.compile_and_load(hole, source_roots: @roots)
  end
end
