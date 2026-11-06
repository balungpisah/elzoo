# SPDX-License-Identifier: Apache-2.0
defmodule Elzoo.BackpressureTest do
  use ExUnit.Case, async: false
  alias Elzoo.Backpressure, as: B
  @source File.read!(Path.expand("../../cure/elzoo/backpressure.cure", __DIR__))
  @roots Mix.Project.config() |> Keyword.get(:cure_paths, ["cure"]) |> Enum.map(&Path.expand/1)

  test "seeded capacity trace and invalid foreign values" do
    for bad <- [0, -1, 1.0, nil, [], [1 | :bad]],
        do: assert(B.new(bad) == {:error, :invalid_capacity})

    for bad <- [
          nil,
          [],
          [1 | :bad],
          {:CapacityState, 0, 0},
          {:CapacityState, 2, 3},
          {:CapacityState, 2, -1},
          {:CapacityState, 2, 0.0}
        ] do
      assert B.admit(bad) == {:error, :invalid_state}
      assert B.release(bad) == {:error, :invalid_state}
    end

    :rand.seed(:exsss, {6, 42, 99})

    for capacity <- 1..4 do
      {:ok, initial} = B.new(capacity)

      Enum.reduce(1..500, {initial, 0}, fn _, {state, count} ->
        {next, count} =
          if :rand.uniform(2) == 1 do
            {:ok, next, decision} = B.admit(state)
            assert decision == if(count == capacity, do: :saturated, else: :admitted)
            if count == capacity, do: assert(next == state)
            {next, min(count + 1, capacity)}
          else
            if count == 0 do
              assert B.release(state) == {:error, :release_underflow}
              {state, 0}
            else
              {:ok, next} = B.release(state)
              {next, count - 1}
            end
          end

        assert next == {:CapacityState, capacity, count}
        assert count >= 0 and count <= capacity
        {next, count}
      end)
    end
  end

  test "selected helper laws have clean audit and saturated production mutation fails at law" do
    assert {:ok, env} = Cure.Compiler.check_source(@source, source_roots: @roots)
    report = Cure.Audit.Ledger.audit_env(env)

    for key <- [:axioms, :holes, :unresolved, :unaudited, :opaque, :not_proven_total],
        do: assert(Map.fetch!(report, key) == [])

    assert report.absurd == 0

    wrong =
      @source
      |> String.replace("mod Elzoo.Backpressure", "mod Elzoo.WrongCapacity")
      |> String.replace(
        "Saturated() -> state",
        "Saturated() -> CapacityState{capacity: state.capacity, in_flight: state.in_flight + 1}"
      )

    assert {:error, {:codegen_error, {:source_context, {:conversion_failure, _, _}, _}}} =
             Cure.Compiler.compile_and_load(wrong, source_roots: @roots)
  end
end
