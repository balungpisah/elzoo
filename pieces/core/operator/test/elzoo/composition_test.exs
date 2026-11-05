# SPDX-License-Identifier: Apache-2.0
defmodule Elzoo.CompositionTest do
  use ExUnit.Case, async: false
  @source File.read!(Path.expand("../../cure/elzoo/composition.cure", __DIR__))
  @cure_roots Mix.Project.config() |> Keyword.get(:cure_paths, ["cure"]) |> Enum.map(&Path.expand/1)

  test "a dropped input never invokes or advances the downstream operator" do
    first = fn state -> fn _input -> {:Transition, state + 1, :none} end end
    second = fn _ -> fn _ -> flunk("downstream invoked after a drop") end end

    assert apply(:"Cure.Elzoo.Composition", :compose, [first, second, {:Joined, 0, 42}, :input]) ==
             {:Transition, {:Joined, 1, 42}, :none}
  end

  test "compatible stateful functions compose through the same transition" do
    first = fn state -> fn input -> {:Transition, state + 1, {:some, input * 2}} end end
    second = fn state -> fn input -> {:Transition, state + input, {:some, state + input}} end end

    assert apply(:"Cure.Elzoo.Composition", :compose, [first, second, {:Joined, 0, 10}, 3]) ==
             {:Transition, {:Joined, 1, 16}, {:some, 16}}
  end

  test "owned Cure source audit has no hidden proof assumptions" do
    assert {:ok, env} = Cure.Compiler.check_source(@source, source_roots: @cure_roots)
    report = Cure.Audit.Ledger.audit_env(env)
    assert report.unaudited == []
    assert report.unresolved == []
    assert report.holes == []
    assert report.axioms == []
    assert report.not_proven_total == []
    assert report.absurd == 0
  end

  test "Cure rejects an incompatible connection using only this bundle" do
    wrong = """
    mod Elzoo.WrongPort
      use Std.Option
      use Elzoo.Composition
      fn first(state: Int, input: Int) -> Transition(Int, Int) =
        Transition{state: state, output: Some(input)}
      fn second(state: Int, input: String) -> Transition(Int, String) =
        Transition{state: state, output: Some(input)}
      fn broken(state: Joined(Int, Int), input: Int) -> Transition(Joined(Int, Int), String) =
        compose(first, second, state, input)
    end
    """

    assert {:error,
            {:codegen_error, {:source_context, {:index_mismatch, {:cannot_unify, _, _}}, _}}} =
             Cure.Compiler.compile_and_load(wrong, source_roots: @cure_roots)
  end
end
