# SPDX-License-Identifier: Apache-2.0
defmodule Elzoo.OutputRepairTest do
  use ExUnit.Case, async: true
  alias Elzoo.{OutputRepair, PayloadSchema}

  @port %{
    "id" => "answer",
    "direction" => "output",
    "schema_id" => "test/answer",
    "schema_version" => 1
  }
  @schema %{
    "type" => "object",
    "properties" => %{"n" => %{"type" => "integer"}, "tags" => %{"type" => "array"}},
    "required" => ["n"],
    "additionalProperties" => false
  }

  defp checked do
    {:ok, checked} = PayloadSchema.build(@port, @schema)
    checked
  end

  defp completed(content, structured, finish \\ :stop),
    do: %{content: content, structured: structured, finish: finish}

  defp decide(completed, used \\ 0, bound \\ 1),
    do: OutputRepair.decide(checked(), @port, completed, used, bound)

  @valid_text ~s({"n": 3})
  @valid {:valid, %{"n" => 3}}

  test "rules in order and invalid operands" do
    assert decide(completed(@valid_text, @valid)) == {:accept, %{"n" => 3}}
    # Members other than the three are not read.
    assert decide(Map.put(completed(@valid_text, @valid), :usage, :any)) == {:accept, %{"n" => 3}}

    for bad <- [
          completed(@valid_text, nil),
          completed(@valid_text, {:invalid, :other}),
          completed(@valid_text, {:valid}),
          completed(@valid_text, @valid, :stopped),
          completed(@valid_text, @valid, {:other, :atom}),
          completed(<<255>>, @valid),
          completed(nil, @valid),
          %{content: @valid_text, structured: @valid}
        ] do
      assert decide(bad) == {:error, :invalid_input}
    end

    ok = completed(@valid_text, @valid)

    for {used, bound} <- [{0, 9}, {2, 1}, {-1, 1}, {0, -1}, {0, nil}, {0.0, 1}] do
      assert OutputRepair.decide(checked(), @port, ok, used, bound) == {:error, :invalid_input}
    end

    assert OutputRepair.decide(:schema, @port, ok, 0, 1) == {:error, :invalid_input}
    assert OutputRepair.decide(checked(), %{"id" => "x"}, ok, 0, 1) == {:error, :invalid_input}

    input_port = Map.put(@port, "direction", "input")
    {:ok, input_checked} = PayloadSchema.build(input_port, @schema)
    assert OutputRepair.decide(input_checked, input_port, ok, 0, 1) == {:error, :invalid_input}
    assert OutputRepair.decide(checked(), @port, ok, 8, 8) == {:accept, %{"n" => 3}}

    # Rule 2 precedes rule 3: a cut, empty output fails as length.
    assert decide(completed("", {:invalid, :invalid_json}, :length)) == {:fail, :length, []}
    assert decide(completed("{}", @valid, {:other, "x"})) == {:fail, :no_answer, []}
    assert decide(completed(" \n\t ", {:invalid, :invalid_json})) == {:fail, :no_answer, []}
    assert decide(completed(@valid_text, {:invalid, :missing})) == {:fail, :no_answer, []}

    for finish <- [:tool_calls, :content_filter, :refusal],
        do: assert(decide(completed(@valid_text, @valid, finish)) == {:fail, :no_answer, []})

    assert decide(completed(@valid_text, @valid, :length), 0, 8) == {:fail, :length, []}
  end

  test "violation list" do
    # The list of the check, unchanged.
    {:error, {:violations, list}} =
      PayloadSchema.check(checked(), @port, %{"n" => "x", "tags" => 1})

    assert Enum.count(list, &(&1 == %{path: [:key], code: :schema_mismatch})) == 2

    assert decide(completed(~s({"n": "x", "tags": 1}), {:invalid, :schema_mismatch})) ==
             {:repair, list}

    assert decide(completed("not json", {:invalid, :invalid_json})) ==
             {:repair, [%{path: [], code: :invalid_json}]}

    # Any other error of the check (here a value the check cannot represent) gives [].
    deep = Enum.reduce(1..40, "1", fn _, acc -> "[" <> acc <> "]" end)
    assert decide(completed(deep, {:invalid, :schema_mismatch})) == {:repair, []}
  end

  test "invalid_at_bound" do
    invalid = completed(~s({"m": 1}), {:invalid, :schema_mismatch})
    {:repair, violations} = decide(invalid, 0, 1)
    assert violations != []
    assert decide(invalid, 1, 1) == {:fail, :invalid_at_bound, violations}
    assert decide(invalid, 0, 0) == {:fail, :invalid_at_bound, violations}
    assert decide(invalid, 7, 8) == {:repair, violations}
    assert decide(invalid, 8, 8) == {:fail, :invalid_at_bound, violations}

    assert decide(completed("{", {:invalid, :invalid_json}), 1, 1) ==
             {:fail, :invalid_at_bound, [%{path: [], code: :invalid_json}]}
  end

  test "validators_disagree" do
    for used <- [0, 1] do
      # ai-text valid, our check refuses.
      assert decide(completed(~s({"m": 1}), {:valid, %{"m" => 1}}), used) ==
               {:fail, :validator_disagreement, []}

      assert decide(completed("nope", {:valid, %{"n" => 1}}), used) ==
               {:fail, :validator_disagreement, []}

      # ai-text invalid, our check accepts.
      assert decide(completed(@valid_text, {:invalid, :schema_mismatch}), used) ==
               {:fail, :validator_disagreement, []}

      assert decide(completed(@valid_text, {:invalid, :invalid_json}), used) ==
               {:fail, :validator_disagreement, []}
    end
  end

  test "render" do
    assert OutputRepair.render([]) ==
             "The last output did not match the required schema.\n" <>
               "Answer again with one JSON value that matches the schema and nothing else."

    assert OutputRepair.render([
             %{path: [], code: :invalid_json},
             %{path: [:key, 0, :key, 12], code: :schema_mismatch}
           ]) ==
             "The last output did not match the required schema.\n" <>
               "$: invalid_json\n" <>
               "$.*[0].*[12]: schema_mismatch\n" <>
               "Answer again with one JSON value that matches the schema and nothing else."
  end

  test "laws_and_example" do
    source = File.read!(Path.expand("../../cure/elzoo/output_repair.cure", __DIR__))
    roots = Mix.Project.config() |> Keyword.fetch!(:cure_paths) |> Enum.map(&Path.expand/1)
    assert {:ok, _} = Cure.Compiler.compile_and_load(source, source_roots: roots)
    assert {:ok, env} = Cure.Compiler.check_source(source, source_roots: roots)
    audit = Cure.Audit.Ledger.audit_env(env)

    for key <- [:axioms, :holes, :unresolved, :unaudited, :opaque, :not_proven_total],
        do: assert(Map.fetch!(audit, key) == [])

    assert audit.absurd == 0

    {result, _} = Code.eval_file(Path.expand("../../examples/output_repair.exs", __DIR__))

    assert result ==
             {"The last output did not match the required schema.\n" <>
                "$.*: schema_mismatch\n" <>
                "$: schema_mismatch\n" <>
                "Answer again with one JSON value that matches the schema and nothing else.",
              %{"answer" => "no"}}
  end
end
