# SPDX-License-Identifier: Apache-2.0
defmodule Elzoo.SelectionTest do
  use ExUnit.Case, async: false
  alias Elzoo.Selection
  @source File.read!(Path.expand("../../cure/elzoo/selection.cure", __DIR__))
  @roots Mix.Project.config() |> Keyword.get(:cure_paths, ["cure"]) |> Enum.map(&Path.expand/1)

  defp port(id, direction, schema) do
    %{"id" => id, "direction" => direction, "schema_id" => schema, "schema_version" => 1}
  end

  defp fixture do
    requirement = %{
      "upstream" => port("source", "output", "source-schema"),
      "downstream" => port("sink", "input", "sink-schema"),
      "delivery" => "fused"
    }

    candidate = %{
      "piece_id" => "candidate/a",
      "interface" => %{
        "input" => port("in", "input", "source-schema"),
        "output" => port("out", "output", "sink-schema")
      },
      "delivery" => "fused",
      "rank" => 0
    }

    {requirement, candidate}
  end

  defp permutations([]), do: [[]]

  defp permutations(values) do
    for value <- values, rest <- permutations(List.delete(values, value)), do: [value | rest]
  end

  test "unique best rank, groups and permutations; ID order never breaks best-rank ties" do
    {requirement, a} = fixture()
    b = a |> Map.put("piece_id", "candidate/b") |> Map.put("rank", 2)
    c = a |> Map.put("piece_id", "candidate/c") |> Map.put("rank", 2)

    for shuffled <- permutations([c, b, a]) do
      assert Selection.select(requirement, shuffled) == {:ok, "candidate/a"}

      assert Selection.rank(requirement, shuffled) ==
               {:ok, [{0, ["candidate/a"]}, {2, ["candidate/b", "candidate/c"]}]}
    end

    tied = Map.put(b, "rank", 0)

    for shuffled <- permutations([c, tied, a]) do
      assert Selection.select(requirement, shuffled) ==
               {:error, {:selection, {:ambiguous, ["candidate/a", "candidate/b"]}}}

      assert Selection.rank(requirement, shuffled) ==
               {:ok, [{0, ["candidate/a", "candidate/b"]}, {2, ["candidate/c"]}]}
    end

    assert Selection.select(requirement, []) == {:error, {:selection, :missing}}
    assert Selection.rank(requirement, []) == {:ok, []}
  end

  test "input then output then delivery compatibility, sorted diagnostics and permutation invariance" do
    {requirement, a} = fixture()

    input =
      a |> put_in(["interface", "input", "schema_id"], "wrong") |> Map.put("delivery", "volatile")

    output =
      a
      |> Map.put("piece_id", "candidate/b")
      |> put_in(["interface", "output", "schema_version"], 2)
      |> Map.put("delivery", "volatile")

    delivery = a |> Map.put("piece_id", "candidate/c") |> Map.put("delivery", "volatile")

    expected =
      {:error,
       {:selection,
        {:incompatible,
         [
           {"candidate/a", {:input, :schema_mismatch}},
           {"candidate/b", {:output, :version_mismatch}},
           {"candidate/c", :delivery_mismatch}
         ]}}}

    for shuffled <- permutations([delivery, output, input]) do
      assert Selection.select(requirement, shuffled) == expected
      assert Selection.rank(requirement, shuffled) == {:ok, []}
    end

    version = put_in(a, ["interface", "input", "schema_version"], 2)

    assert Selection.select(requirement, [version]) ==
             {:error, {:selection, {:incompatible, [{"candidate/a", {:input, :version_mismatch}}]}}}

    schema = put_in(a, ["interface", "output", "schema_id"], "wrong")

    assert Selection.select(requirement, [schema]) ==
             {:error, {:selection, {:incompatible, [{"candidate/a", {:output, :schema_mismatch}}]}}}

    assert Selection.select(requirement, [input, Map.put(a, "piece_id", "compatible")]) ==
             {:ok, "compatible"}
  end

  test "per-call configuration changes rank and delivery, without any placement constraint" do
    {requirement, a} = fixture()
    b = a |> Map.put("piece_id", "candidate/b") |> Map.put("rank", 1)
    assert Selection.select(requirement, [a, b]) == {:ok, "candidate/a"}
    assert Selection.select(requirement, [Map.put(a, "rank", 2), b]) == {:ok, "candidate/b"}
    volatile = Map.put(b, "delivery", "volatile")
    assert Selection.select(requirement, [a, volatile]) == {:ok, "candidate/a"}

    assert Selection.select(Map.put(requirement, "delivery", "volatile"), [a, volatile]) ==
             {:ok, "candidate/b"}

    assert Selection.rank(Map.put(requirement, "delivery", "volatile"), [a, volatile]) ==
             {:ok, [{1, ["candidate/b"]}]}
  end

  test "delivery boundary drift: exactly fused/volatile are accepted by Edge and selection" do
    {requirement, candidate} = fixture()

    samples =
      ~w(fused volatile hop durable at_least_once exactly_once unknown FUSED) ++
        ["", nil, :fused, 1, <<255>>]

    accepted =
      Enum.filter(samples, fn delivery ->
        binding = %{
          "unit_id" => candidate["piece_id"],
          "port" => candidate["interface"]["input"],
          "delivery" => delivery,
          "required_route" => false
        }

        match?({:ok, _}, Elzoo.Edge.decode_binding(binding))
      end)

    assert MapSet.new(accepted) == MapSet.new(["fused", "volatile"])

    for delivery <- samples do
      result =
        Selection.select(Map.put(requirement, "delivery", delivery), [
          Map.put(candidate, "delivery", delivery)
        ])

      if delivery in accepted do
        assert result == {:ok, candidate["piece_id"]}
      else
        assert {:error, {:requirement, _}} = result

        assert {:error, {:candidate, 0, _}} =
                 Selection.select(requirement, [Map.put(candidate, "delivery", delivery)])
      end
    end

    edge_source = Path.expand("../../../../core/edge/cure/elzoo/edge.cure", __DIR__)
    edge_source = if File.exists?(edge_source), do: edge_source, else: "cure/elzoo/edge.cure"

    declared =
      Regex.scan(~r/equal\(binding\.delivery, "([^"]+)"\)/, File.read!(edge_source),
        capture: :all_but_first
      )
      |> List.flatten()

    assert MapSet.new(declared) == MapSet.new(["fused", "volatile"])
  end

  test "requirement before candidates, first bad candidate index before duplicates and compatibility" do
    {requirement, candidate} = fixture()

    for invalid <- [nil, %{}, Map.put(requirement, "extra", :secret)] do
      assert Selection.select(invalid, nil) == {:error, {:requirement, :invalid_shape}}
    end

    for {field, direction, reason} <- [
          {"upstream", "input", :invalid_upstream},
          {"downstream", "output", :invalid_downstream}
        ] do
      invalid = put_in(requirement, [field, "direction"], direction)
      assert Selection.select(invalid, [nil]) == {:error, {:requirement, reason}}
      assert Selection.rank(invalid, [nil]) == {:error, {:requirement, reason}}
    end

    assert Selection.select(Map.put(requirement, "upstream", %{}), []) ==
             {:error, {:requirement, :invalid_upstream}}

    assert Selection.select(Map.put(requirement, "downstream", nil), []) ==
             {:error, {:requirement, :invalid_downstream}}

    assert Selection.select(requirement, nil) == {:error, {:candidate, :invalid_shape}}

    for invalid <- [
          nil,
          %{},
          Map.put(candidate, "extra", true),
          Map.put(candidate, "piece_id", ""),
          Map.put(candidate, "piece_id", <<255>>),
          Map.put(candidate, "rank", -1),
          Map.put(candidate, "rank", 1.0)
        ] do
      assert Selection.select(requirement, [candidate, candidate, invalid, nil]) ==
               {:error, {:candidate, 2, :invalid_shape}}
    end

    assert Selection.select(requirement, [Map.put(candidate, "interface", nil)]) ==
             {:error, {:candidate, 0, :invalid_shape}}

    assert Selection.select(requirement, [
             put_in(candidate, ["interface", "input", "direction"], "output")
           ]) == {:error, {:candidate, 0, :invalid_direction}}

    assert Selection.select(requirement, [put_in(candidate, ["interface", "output", "id"], "in")]) ==
             {:error, {:candidate, 0, :duplicate_port_id}}

    assert Selection.select(requirement, [
             put_in(candidate, ["interface", "input", "schema_version"], 0)
           ]) == {:error, {:candidate, 0, {:input, :invalid_schema_version}}}

    assert Selection.select(requirement, [Map.put(candidate, "delivery", "durable")]) ==
             {:error, {:candidate, 0, :invalid_delivery}}

    b = Map.put(candidate, "piece_id", "candidate/b")

    for values <- [[b, candidate, b, candidate], [candidate, candidate, b, b]] do
      assert Selection.select(requirement, values) ==
               {:error, {:candidate, :duplicate_id, "candidate/a"}}

      assert Selection.rank(requirement, values) ==
               {:error, {:candidate, :duplicate_id, "candidate/a"}}
    end
  end

  test "improper candidate lists return list-shape errors before traversing candidates" do
    requirement = %{
      "upstream" => port("source", "output", "x"),
      "downstream" => port("sink", "input", "x"),
      "delivery" => "fused"
    }

    candidate = %{
      "piece_id" => "candidate",
      "interface" => %{"input" => port("in", "input", "x"), "output" => port("out", "output", "x")},
      "delivery" => "fused",
      "rank" => 0
    }

    for candidates <- [
          [candidate | :bad_tail],
          [candidate, candidate | :bad_tail],
          [nil | :bad_tail]
        ] do
      assert Selection.select(requirement, candidates) == {:error, {:candidate, :invalid_shape}}
      assert Selection.rank(requirement, candidates) == {:error, {:candidate, :invalid_shape}}
    end

    assert Selection.select(nil, [candidate | :bad_tail]) ==
             {:error, {:requirement, :invalid_shape}}

    assert Selection.rank(nil, [candidate | :bad_tail]) == {:error, {:requirement, :invalid_shape}}
  end

  test "Cure audit and measured record tuples" do
    assert {:ok, env} = Cure.Compiler.check_source(@source, source_roots: @roots)
    audit = Cure.Audit.Ledger.audit_env(env)

    for field <- [:unaudited, :unresolved, :holes, :axioms, :not_proven_total],
        do: assert(Map.fetch!(audit, field) == [])

    assert audit.absurd == 0
    {requirement, candidate} = fixture()
    {:ok, upstream} = Elzoo.Port.decode(requirement["upstream"])
    {:ok, downstream} = Elzoo.Port.decode(requirement["downstream"])
    {:ok, face} = Elzoo.Assembly.decode(candidate["interface"])
    req = {:SelectionRequirement, upstream, downstream, {:String, ~c"fused"}}
    choice = {:SelectionCandidate, {:String, ~c"candidate/a"}, face, {:String, ~c"fused"}, 0}
    assert apply(:"Cure.Elzoo.Selection", :compatible, [req, choice]) == {:ok, true}

    assert apply(:"Cure.Elzoo.Selection", :compatible, [
             req,
             put_elem(choice, 3, {:String, ~c"volatile"})
           ]) == {:error, {:delivery, :delivery_mismatch}}
  end
end
