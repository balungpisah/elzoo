# SPDX-License-Identifier: Apache-2.0
defmodule Elzoo.EdgeTest do
  use ExUnit.Case, async: false
  @source File.read!(Path.expand("../../cure/elzoo/edge.cure", __DIR__))
  @roots Mix.Project.config() |> Keyword.get(:cure_paths, ["cure"]) |> Enum.map(&Path.expand/1)

  defp binding(unit, id, direction, delivery) do
    %{
      "unit_id" => unit,
      "port" => %{
        "id" => id,
        "direction" => direction,
        "schema_id" => "count",
        "schema_version" => 1
      },
      "delivery" => delivery,
      "required_route" => true
    }
  end

  defp edge(placement, source, target) do
    %{
      "id" => "edge-1",
      "placement" => placement,
      "source" => %{"unit_id" => source["unit_id"], "port_id" => source["port"]["id"]},
      "target" => %{"unit_id" => target["unit_id"], "port_id" => target["port"]["id"]}
    }
  end

  test "per-check Config permits exactly matching fused or cross-unit volatile policies" do
    for placement <- ~w(fused hop),
        same_unit? <- [true, false],
        left <- ~w(fused volatile),
        right <- ~w(fused volatile) do
      source = binding("left", "out", "output", left)
      target = binding(if(same_unit?, do: "left", else: "right"), "in", "input", right)

      legal =
        (placement == "fused" and same_unit? and left == "fused" and right == "fused") or
          (placement == "hop" and not same_unit? and left == "volatile" and right == "volatile")

      expected = if legal, do: {:ok, true}, else: {:error, :placement_mismatch}
      assert Elzoo.Edge.connect(edge(placement, source, target), source, target) == expected
    end
  end

  test "unchanged Port schema/version/direction rules and route references are consumed" do
    source = binding("left", "out", "output", "volatile")
    target = binding("right", "in", "input", "volatile")
    route = edge("hop", source, target)

    for {key, value, reason} <- [
          {"direction", "output", :direction_mismatch},
          {"schema_id", "money", :schema_mismatch},
          {"schema_version", 2, :version_mismatch}
        ] do
      invalid = put_in(target, ["port", key], value)
      assert Elzoo.Edge.connect(route, source, invalid) == {:error, reason}
    end

    assert Elzoo.Edge.connect(put_in(route, ["source", "port_id"], "missing"), source, target) ==
             {:error, :reference_mismatch}

    assert Elzoo.Port.decode(source["port"]) ==
             Elzoo.Port.decode(Map.delete(source, "delivery")["port"])

    assert {:error, :invalid_shape} =
             Elzoo.Port.decode(Map.put(source["port"], "delivery", "volatile"))
  end

  test "Config booleans are explicit and malformed or unsupported policies fail closed" do
    binding = binding("unit", "out", "output", "fused")

    for required <- [true, false] do
      candidate = Map.put(binding, "required_route", required)
      assert {:ok, record} = Elzoo.Edge.decode_binding(candidate)
      assert elem(record, 4) == required
      assert Elzoo.Edge.decode_port("unit", Map.delete(candidate, "unit_id")) == {:ok, record}
    end

    for invalid <- [
          nil,
          [],
          Map.delete(binding, "required_route"),
          Map.put(binding, "extra", 1),
          Map.put(binding, "delivery", :fused),
          Map.put(binding, "unit_id", <<255>>),
          Map.put(binding, "required_route", "true"),
          put_in(binding, ["port", "schema_version"], "1")
        ] do
      assert Elzoo.Edge.decode_binding(invalid) == {:error, :invalid_shape}
    end

    for delivery <- ~w(durable at_least_once exactly_once),
        do:
          assert(
            Elzoo.Edge.decode_binding(Map.put(binding, "delivery", delivery)) ==
              {:error, :invalid_delivery}
          )

    assert Elzoo.Edge.decode_binding(Map.put(binding, "unit_id", "")) == {:error, :invalid_unit_id}
    assert Elzoo.Edge.decode_port("unit", binding) == {:error, :invalid_shape}
  end

  test "reference mismatches precede compatibility errors at both boundaries" do
    source = binding("left", "out", "output", "volatile")
    target = binding("right", "in", "input", "volatile")

    for side <- ~w(source target),
        {key, value} <- [{"schema_id", "money"}, {"schema_version", 2}, {"direction", "output"}] do
      route = put_in(edge("hop", source, target), [side, "port_id"], "missing")
      incompatible = put_in(target, ["port", key], value)

      assert Elzoo.Edge.connect(route, source, incompatible) == {:error, :reference_mismatch}
      assert {:ok, route_record} = Elzoo.Edge.decode(route)
      assert {:ok, source_record} = Elzoo.Edge.decode_binding(source)
      assert {:ok, target_record} = Elzoo.Edge.decode_binding(incompatible)

      assert apply(:"Cure.Elzoo.Edge", :connect, [route_record, source_record, target_record]) ==
               {:error, :reference_mismatch}
    end
  end

  test "edge exact shapes and nonempty references reject malformed declarations" do
    source = binding("unit", "out", "output", "fused")
    target = binding("unit", "in", "input", "fused")
    route = edge("fused", source, target)

    for field <- ~w(id placement source target),
        do: assert(Elzoo.Edge.decode(Map.delete(route, field)) == {:error, :invalid_shape})

    for invalid <- [
          nil,
          [],
          Map.put(route, "extra", 1),
          Map.put(route, "id", <<255>>),
          Map.put(route, "source", nil),
          put_in(route, ["source", "port_id"], :atom),
          Map.put(route, "target", Map.put(route["target"], "extra", 1))
        ] do
      assert Elzoo.Edge.decode(invalid) == {:error, :invalid_shape}
    end

    assert Elzoo.Edge.decode(Map.put(route, "placement", "durable")) == {:error, :invalid_placement}
    assert Elzoo.Edge.decode(Map.put(route, "id", "")) == {:error, :invalid_id}

    assert Elzoo.Edge.decode(put_in(route, ["source", "unit_id"], "")) ==
             {:error, :invalid_reference}

    assert Elzoo.Edge.connect(route, nil, target) == {:error, {:source, :invalid_shape}}
    assert Elzoo.Edge.connect(route, source, nil) == {:error, {:target, :invalid_shape}}
  end

  test "direct Cure calls enforce semantic placement too and source audit is clean" do
    source = binding("unit", "out", "output", "fused")
    target = binding("unit", "in", "input", "fused")
    assert {:ok, left} = Elzoo.Edge.decode_binding(source)
    assert {:ok, right} = Elzoo.Edge.decode_binding(target)
    assert {:ok, route} = Elzoo.Edge.decode(edge("hop", source, target))

    assert apply(:"Cure.Elzoo.Edge", :connect, [route, left, right]) ==
             {:error, :placement_mismatch}

    assert {:ok, env} = Cure.Compiler.check_source(@source, source_roots: @roots)
    audit = Cure.Audit.Ledger.audit_env(env)
    assert audit.unaudited == []
    assert audit.unresolved == []
    assert audit.holes == []
    assert audit.axioms == []
    assert audit.not_proven_total == []
    assert audit.absurd == 0
  end

  test "the example file evaluates to the documented results" do
    {result, _} = Code.eval_file(Path.expand("../../examples/elzoo/edge.exs", __DIR__))

    assert result == %{
             fused_inside_one_unit: {:ok, true},
             hop_between_two_units: {:ok, true},
             fused_between_two_units: {:error, :placement_mismatch},
             source_reference_names_missing_port: {:error, :reference_mismatch},
             source_binding_with_fifth_key: {:error, {:source, :invalid_shape}}
           }
  end
end
