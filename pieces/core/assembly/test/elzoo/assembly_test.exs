# SPDX-License-Identifier: Apache-2.0
defmodule Elzoo.AssemblyTest do
  use ExUnit.Case, async: false
  @source File.read!(Path.expand("../../cure/elzoo/assembly.cure", __DIR__))
  @roots Mix.Project.config() |> Keyword.get(:cure_paths, ["cure"]) |> Enum.map(&Path.expand/1)

  defp port(id, direction, schema) do
    %{"id" => id, "direction" => direction, "schema_id" => schema, "schema_version" => 1}
  end

  defp face(name, input, output) do
    %{
      "input" => port(name <> ".in", "input", input),
      "output" => port(name <> ".out", "output", output)
    }
  end

  test "nested declarations preserve the exact outer ports" do
    first = face("first", "example/count", "example/count")
    second = face("second", "example/count", "example/flag")
    third = face("third", "example/flag", "example/flag")
    assert {:ok, pair} = Elzoo.Assembly.connect(first, second)
    assert pair == %{"input" => first["input"], "output" => second["output"]}
    assert {:ok, nested} = Elzoo.Assembly.connect(pair, third)
    assert nested == %{"input" => first["input"], "output" => third["output"]}
    assert {:ok, tail} = Elzoo.Assembly.connect(second, third)
    assert Elzoo.Assembly.connect(first, tail) == {:ok, nested}
  end

  test "invalid outer ports and incompatible inner declarations reject before execution" do
    first = face("first", "example/count", "example/count")
    second = face("second", "example/count", "example/flag")

    assert Elzoo.Assembly.connect(first, put_in(second, ["input", "schema_id"], "example/money")) ==
             {:error, :schema_mismatch}

    assert Elzoo.Assembly.connect(first, put_in(second, ["input", "schema_version"], 2)) ==
             {:error, :version_mismatch}

    assert Elzoo.Assembly.connect(put_in(first, ["input", "direction"], "output"), second) ==
             {:error, {:first, :invalid_direction}}

    assert Elzoo.Assembly.connect(first, put_in(second, ["output", "direction"], "input")) ==
             {:error, {:second, :invalid_direction}}

    assert Elzoo.Assembly.decode(%{}) == {:error, :invalid_shape}
    assert Elzoo.Assembly.decode(Map.put(first, "state", "implicit")) == {:error, :invalid_shape}
    assert Elzoo.Assembly.decode(Map.put(first, "input", nil)) == {:error, {:input, :invalid_shape}}

    assert Elzoo.Assembly.decode(put_in(first, ["output", "id"], first["input"]["id"])) ==
             {:error, :duplicate_port_id}

    assert Elzoo.Assembly.connect(first, put_in(second, ["output", "id"], first["input"]["id"])) ==
             {:error, :duplicate_port_id}
  end

  test "legal nested Cure functions compile and run; an incompatible connection cannot compile" do
    source = """
    mod Elzoo.AssemblyExample
      use Std.Option
      use Elzoo.Composition
      fn count(state: Int, input: Int) -> Transition(Int, Int) =
        Transition{state: state + input, output: Some(state + input)}
      fn threshold(state: Int, input: Int) -> Transition(Int, Bool) =
        Transition{state: state, output: Some(input >= state)}
      fn retain(state: Bool, input: Bool) -> Transition(Bool, Bool) =
        Transition{state: input, output: Some(input)}
      fn pair(state: Joined(Int, Int), input: Int) -> Transition(Joined(Int, Int), Bool) =
        compose(count, threshold, state, input)
      fn nested(state: Joined(Joined(Int, Int), Bool), input: Int) -> Transition(Joined(Joined(Int, Int), Bool), Bool) =
        compose(pair, retain, state, input)
    end
    """

    assert {:ok, module} = Cure.Compiler.compile_and_load(source, source_roots: @roots)

    assert apply(module, :nested, [{:Joined, {:Joined, 0, 5}, false}, 7]) ==
             {:Transition, {:Joined, {:Joined, 7, 5}, true}, {:some, true}}

    wrong =
      source
      |> String.replace("Elzoo.AssemblyExample", "Elzoo.AssemblyWrong")
      |> String.replace("compose(pair, retain, state, input)", "compose(pair, count, state, input)")

    assert {:error,
            {:codegen_error, {:source_context, {:index_mismatch, {:cannot_unify, _, _}}, _}}} =
             Cure.Compiler.compile_and_load(wrong, source_roots: @roots)
  end

  test "interface decisions check without owned foreign axioms or unfinished proofs" do
    assert {:ok, env} = Cure.Compiler.check_source(@source, source_roots: @roots)
    audit = Cure.Audit.Ledger.audit_env(env)
    assert audit.unaudited == []
    assert audit.unresolved == []
    assert audit.holes == []
    assert audit.axioms == []
    assert audit.not_proven_total == []
    assert audit.absurd == 0
  end
end
