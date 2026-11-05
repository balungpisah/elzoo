# SPDX-License-Identifier: Apache-2.0
defmodule Elzoo.PortTest do
  use ExUnit.Case, async: false
  @source File.read!(Path.expand("../../cure/elzoo/port.cure", __DIR__))
  @roots Mix.Project.config() |> Keyword.get(:cure_paths, ["cure"]) |> Enum.map(&Path.expand/1)

  defp port(direction, overrides \\ %{}) do
    Map.merge(
      %{
        "id" => direction,
        "direction" => direction,
        "schema_id" => "example/count",
        "schema_version" => 1
      },
      overrides
    )
  end

  test "neutral descriptors translate to the measured ABI and back" do
    descriptor = port("output")

    assert {:ok,
            {:Descriptor, {:String, ~c"output"}, {:String, ~c"output"},
             {:String, ~c"example/count"}, 1} = record} =
             Elzoo.Port.decode(descriptor)

    assert Elzoo.Port.encode(record) == descriptor
    assert Elzoo.Port.compatible(descriptor, port("input")) == {:ok, true}
    # A framework name has no special authority or inferred schema.
    assert Elzoo.Port.compatible(port("output", %{"id" => "ash.count"}), port("input")) ==
             {:ok, true}
  end

  test "schema identity, version and direction are independent negative controls" do
    assert Elzoo.Port.compatible(port("input"), port("output")) == {:error, :direction_mismatch}
    assert Elzoo.Port.compatible(port("output"), port("output")) == {:error, :direction_mismatch}

    assert Elzoo.Port.compatible(port("output"), port("input", %{"schema_id" => "example/money"})) ==
             {:error, :schema_mismatch}

    assert Elzoo.Port.compatible(port("output"), port("input", %{"schema_version" => 2})) ==
             {:error, :version_mismatch}
  end

  test "actual Cure text literals match the boundary including Unicode without normalization" do
    source = """
    mod Elzoo.PortExample
      use Elzoo.Port
      fn output() -> Elzoo.Port.Descriptor =
        Descriptor{id: "résultat.合計", direction: "output", schema_id: "example/数量", schema_version: 1}
    end
    """

    assert {:ok, module} = Cure.Compiler.compile_and_load(source, source_roots: @roots)
    descriptor = port("output", %{"id" => "résultat.合計", "schema_id" => "example/数量"})
    assert {:ok, record} = Elzoo.Port.decode(descriptor)
    assert apply(module, :output, []) == record
    assert Elzoo.Port.encode(record) == descriptor

    assert Elzoo.Port.compatible(
             port("output", %{"schema_id" => "é"}),
             port("input", %{"schema_id" => "e\u0301"})
           ) == {:error, :schema_mismatch}
  end

  test "malformed foreign representations never reach typed Cure decisions" do
    for invalid <- [
          nil,
          [],
          %{},
          Map.delete(port("input"), "id"),
          Map.put(port("input"), "delivery", "durable"),
          port("input", %{"id" => :atom}),
          port("input", %{"schema_version" => "1"}),
          port("input", %{"schema_version" => 1.0}),
          port("input", %{"id" => <<255>>})
        ] do
      assert Elzoo.Port.decode(invalid) == {:error, :invalid_shape}
      assert Elzoo.Port.compatible(invalid, port("input")) == {:error, {:source, :invalid_shape}}
      assert Elzoo.Port.compatible(port("output"), invalid) == {:error, {:target, :invalid_shape}}
    end
  end

  test "Cure validates descriptor contents, including when called directly" do
    for {field, value, reason} <- [
          {"id", "", :invalid_id},
          {"direction", "sideways", :invalid_direction},
          {"schema_id", "", :invalid_schema_id},
          {"schema_version", 0, :invalid_schema_version},
          {"schema_version", -1, :invalid_schema_version}
        ] do
      assert Elzoo.Port.decode(port("input", %{field => value})) == {:error, reason}
    end

    invalid = {:Descriptor, {:String, []}, {:String, ~c"output"}, {:String, ~c"example/count"}, 1}
    valid = {:Descriptor, {:String, ~c"in"}, {:String, ~c"input"}, {:String, ~c"example/count"}, 1}
    assert apply(:"Cure.Elzoo.Port", :compatible, [invalid, valid]) == {:error, :invalid_source}
    assert apply(:"Cure.Elzoo.Port", :compatible, [valid, invalid]) == {:error, :invalid_target}
  end

  test "descriptor source checks without owned foreign axioms or unfinished proofs" do
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
