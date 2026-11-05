# SPDX-License-Identifier: Apache-2.0
defmodule Elzoo.WiringTest do
  use ExUnit.Case, async: false
  @source File.read!(Path.expand("../../cure/elzoo/wiring.cure", __DIR__))
  @roots Mix.Project.config() |> Keyword.get(:cure_paths, ["cure"]) |> Enum.map(&Path.expand/1)

  defp examples do
    {examples, _} = Code.eval_file(Path.expand("../../examples/p0.exs", __DIR__))
    examples
  end

  defp message do
    %{
      "version" => 1,
      "message_id" => "message-1",
      "schema_id" => "example/ingest-message",
      "schema_version" => 1,
      "kind" => "command",
      "producer" => %{"unit_id" => "pipeline", "port_id" => "ingest.accepted"},
      "payload" => nil
    }
  end

  defp change_port(wiring, unit_index, port_index, fun) do
    update_in(wiring, ["units", Access.at(unit_index), "ports", Access.at(port_index)], fun)
  end

  test "P0 fused and hop examples pass without executing processes or payloads" do
    %{fused: fused, hop: hop} = examples()
    assert Elzoo.Wiring.validate(fused) == {:ok, fused}
    assert Elzoo.Wiring.validate(hop) == {:ok, hop}
    assert Elzoo.Wiring.accept(fused, "ingest-dedup", message()) == {:ok, message()}
    hop_message = Map.put(message(), "producer", %{"unit_id" => "ingest", "port_id" => "accepted"})
    assert Elzoo.Wiring.accept(hop, "ingest-dedup", hop_message) == {:ok, hop_message}
  end

  test "unknown routes, incompatible schemas/versions and wrong producers fail" do
    wiring = examples().fused
    assert Elzoo.Wiring.accept(wiring, "missing", message()) == {:error, {:route, :unknown_edge}}

    assert Elzoo.Wiring.accept(wiring, "ingest-dedup", Map.put(message(), "schema_id", "money")) ==
             {:error, {:route, :schema_mismatch}}

    assert Elzoo.Wiring.accept(wiring, "ingest-dedup", Map.put(message(), "schema_version", 2)) ==
             {:error, {:route, :version_mismatch}}

    assert Elzoo.Wiring.accept(
             wiring,
             "ingest-dedup",
             put_in(message(), ["producer", "unit_id"], "wrong")
           ) == {:error, {:route, :producer_mismatch}}

    assert Elzoo.Wiring.accept(wiring, "ingest-dedup", Map.delete(message(), "payload")) ==
             {:error, {:envelope, :invalid_shape}}

    for {key, value, reason} <- [
          {"schema_id", "money", :schema_mismatch},
          {"schema_version", 2, :version_mismatch},
          {"direction", "output", :direction_mismatch}
        ] do
      invalid = change_port(wiring, 0, 1, &put_in(&1, ["port", key], value))
      assert Elzoo.Wiring.validate(invalid) == {:error, {:edge, 0, reason}}
    end

    invalid = update_in(wiring, ["edges", Access.at(0), "target", "port_id"], fn _ -> "missing" end)
    assert Elzoo.Wiring.validate(invalid) == {:error, {:edge, 0, :unknown_target}}
  end

  test "accept tags declaration, selection and message errors in phase order" do
    wiring = examples().fused
    invalid_wiring = Map.put(wiring, "extra", true)
    invalid_message = Map.delete(message(), "payload")

    assert Elzoo.Wiring.accept(invalid_wiring, "missing", invalid_message) ==
             {:error, {:wiring, :invalid_shape}}

    assert Elzoo.Wiring.accept(wiring, "missing", invalid_message) ==
             {:error, {:route, :unknown_edge}}

    assert Elzoo.Wiring.accept(wiring, "ingest-dedup", invalid_message) ==
             {:error, {:envelope, :invalid_shape}}

    assert Elzoo.Wiring.accept(wiring, "ingest-dedup", Map.put(message(), "version", 2)) ==
             {:error, {:envelope, :invalid_version}}

    missing_routes = Map.put(wiring, "edges", [])

    assert Elzoo.Wiring.accept(missing_routes, "missing", message()) ==
             {:error,
              {:wiring, {:route, {"pipeline", "accumulate.input"}, :required_route_missing}}}
  end

  test "required-route Config is checked after edges with deterministic missing route errors" do
    wiring = examples().fused
    missing = Map.put(wiring, "edges", [])

    assert Elzoo.Wiring.validate(missing) ==
             {:error, {:route, {"pipeline", "accumulate.input"}, :required_route_missing}}

    optional =
      update_in(missing, ["units", Access.at(0), "ports"], fn ports ->
        Enum.map(ports, &Map.put(&1, "required_route", false))
      end)

    assert Elzoo.Wiring.validate(optional) == {:ok, optional}

    assert Elzoo.Wiring.validate(Map.put(wiring, "edges", [%{}])) ==
             {:error, {:edge, 0, :invalid_shape}}

    for {required, connected, expected} <- [
          {true, true, {:ok, true}},
          {false, true, {:ok, true}},
          {false, false, {:ok, true}},
          {true, false, {:error, :required_route_missing}}
        ] do
      assert apply(:"Cure.Elzoo.Wiring", :require_route, [required, connected]) == expected
    end
  end

  test "duplicate unit/port/edge identities and repeated routes are rejected locally" do
    wiring = examples().fused
    unit = hd(wiring["units"])

    assert Elzoo.Wiring.validate(Map.put(wiring, "units", [unit, unit])) ==
             {:error, {:unit, 1, :duplicate_id}}

    duplicate_port =
      put_in(wiring, ["units", Access.at(0), "ports"], unit["ports"] ++ [hd(unit["ports"])])

    assert Elzoo.Wiring.validate(duplicate_port) == {:error, {:port, "pipeline", 4, :duplicate_id}}
    edge = hd(wiring["edges"])

    assert Elzoo.Wiring.validate(Map.put(wiring, "edges", [edge, edge])) ==
             {:error, {:edge, 1, :duplicate_id}}

    assert Elzoo.Wiring.validate(Map.put(wiring, "edges", [edge, Map.put(edge, "id", "other")])) ==
             {:error, {:edge, 1, :duplicate_route}}
  end

  test "fan-in and fan-out remain declarations while each incident required port is routed" do
    wiring = examples().fused
    unit = hd(wiring["units"])
    extra = unit["ports"] |> hd() |> put_in(["port", "id"], "other.output")
    target = Enum.at(unit["ports"], 1) |> put_in(["port", "id"], "other.input")
    edge = hd(wiring["edges"])
    fan_in = edge |> Map.put("id", "fan-in") |> put_in(["source", "port_id"], "other.output")
    fan_out = edge |> Map.put("id", "fan-out") |> put_in(["target", "port_id"], "other.input")

    wiring =
      wiring
      |> put_in(["units", Access.at(0), "ports"], unit["ports"] ++ [extra, target])
      |> Map.update!("edges", &(&1 ++ [fan_in, fan_out]))

    assert Elzoo.Wiring.validate(wiring) == {:ok, wiring}
  end

  test "foreign wiring shapes and misplaced delivery policies fail closed" do
    wiring = examples().fused

    for invalid <- [
          nil,
          [],
          %{},
          Map.put(wiring, "version", 2),
          Map.put(wiring, "version", 1.0),
          Map.put(wiring, "extra", true),
          Map.put(wiring, "units", %{}),
          Map.put(wiring, "edges", nil)
        ] do
      assert Elzoo.Wiring.validate(invalid) == {:error, :invalid_shape}
    end

    for unit <- [
          %{},
          %{"id" => <<255>>, "ports" => []},
          %{"id" => "", "ports" => []},
          %{"id" => "unit", "ports" => [], "extra" => true}
        ] do
      assert {:error, {:unit, 0, _}} = Elzoo.Wiring.validate(Map.put(wiring, "units", [unit]))
    end

    assert Elzoo.Wiring.validate(change_port(wiring, 0, 0, &Map.put(&1, "required_route", nil))) ==
             {:error, {:port, "pipeline", 0, :invalid_shape}}

    assert Elzoo.Wiring.validate(change_port(wiring, 0, 0, &Map.put(&1, "delivery", "durable"))) ==
             {:error, {:port, "pipeline", 0, :invalid_delivery}}

    assert Elzoo.Wiring.validate(change_port(wiring, 0, 0, &Map.put(&1, "delivery", "volatile"))) ==
             {:error, {:edge, 0, :placement_mismatch}}

    empty = %{"version" => 1, "units" => [], "edges" => []}
    assert Elzoo.Wiring.validate(empty) == {:ok, empty}
  end

  test "Cure checks actual imported message/binding types and rejects a wrong message type" do
    source = """
    mod Elzoo.WiringConsumer
      use Elzoo.Wiring
      use Elzoo.Edge
      use Elzoo.Envelope
      fn check(message: Elzoo.Envelope.EnvelopeMessage(Int), source: Elzoo.Edge.PortBinding) -> Std.Result.Result(Bool, Atom) =
        Elzoo.Wiring.accept(message, source)
    end
    """

    assert {:ok, _} = Cure.Compiler.check_source(source, source_roots: @roots)

    invalid =
      String.replace(
        source,
        "Elzoo.Wiring.accept(message, source)",
        "Elzoo.Wiring.accept(42, source)"
      )

    assert {:error, _} = Cure.Compiler.check_source(invalid, source_roots: @roots)
  end

  test "required-route and message-declaration source audits without local foreign assumptions" do
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
