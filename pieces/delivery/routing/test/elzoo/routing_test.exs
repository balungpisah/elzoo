# SPDX-License-Identifier: Apache-2.0
defmodule Elzoo.RoutingTest do
  use ExUnit.Case, async: false
  alias Elzoo.Routing
  @source File.read!(Path.expand("../../cure/elzoo/routing.cure", __DIR__))
  @roots Mix.Project.config() |> Keyword.get(:cure_paths, ["cure"]) |> Enum.map(&Path.expand/1)

  defp example(name, piece) do
    local = Path.expand("../../../../core/#{piece}/examples/#{name}.exs", __DIR__)
    {value, _} = Code.eval_file(if(File.exists?(local), do: local, else: "examples/#{name}.exs"))
    value
  end

  defp fixture do
    wiring = example("p0", "wiring").fused
    message = example("shared", "envelope").message
    [unit] = wiring["units"]
    input = unit["ports"] |> Enum.at(1) |> put_in(["port", "id"], "second.input")
    wiring = put_in(wiring, ["units"], [Map.update!(unit, "ports", &(&1 ++ [input]))])
    [edge, _] = wiring["edges"]
    second = edge |> Map.put("id", "aaa-second") |> put_in(["target", "port_id"], "second.input")
    wiring = Map.update!(wiring, "edges", &(&1 ++ [second]))

    table = %{
      "version" => 1,
      "source" => edge["source"],
      "routes" => [
        %{"edge_id" => edge["id"], "match" => %{}},
        %{"edge_id" => second["id"], "match" => %{}}
      ]
    }

    {wiring, table, message}
  end

  test "per-call tables, permutation independence, conjunctions, explicit filter and no expiry" do
    {wiring, table, message} = fixture()
    assert Routing.validate(wiring, table) == {:ok, table}

    for routes <- [table["routes"], Enum.reverse(table["routes"])],
        edges <- [wiring["edges"], Enum.reverse(wiring["edges"])] do
      assert Routing.route(
               Map.put(wiring, "edges", edges),
               Map.put(table, "routes", routes),
               message
             ) ==
               {:ok, ["aaa-second", "ingest-dedup"]}
    end

    assert Routing.route_one(wiring, table, message) == {:error, {:route, :ambiguous_route}}
    [route, _] = table["routes"]

    for match <- [
          %{},
          %{"kind" => "command"},
          %{"schema_id" => message["schema_id"], "schema_version" => 1},
          %{"kind" => "command", "schema_id" => message["schema_id"], "schema_version" => 1}
        ] do
      one = Map.put(table, "routes", [Map.put(route, "match", match)])

      assert Routing.route_one(wiring, one, Map.put(message, "deadline_unix_ms", 0)) ==
               {:ok, "ingest-dedup"}
    end

    for match <- [
          %{"kind" => "event"},
          %{"schema_id" => "different"},
          %{"schema_version" => 2},
          %{"kind" => "command", "schema_version" => 2}
        ] do
      filtered = Map.put(table, "routes", [Map.put(route, "match", match)])
      assert Routing.route(wiring, filtered, message) == {:ok, []}
      assert Routing.route_one(wiring, filtered, message) == {:error, {:route, :no_route}}
    end

    empty = Map.put(table, "routes", [])
    assert Routing.route(wiring, empty, message) == {:ok, []}
  end

  test "source acceptance precedes matching even for empty tables" do
    {wiring, table, message} = fixture()

    for routes <- [[], Enum.map(table["routes"], &Map.put(&1, "match", %{"kind" => "event"}))] do
      table = Map.put(table, "routes", routes)

      for {field, value, reason} <- [
            {"producer", %{"unit_id" => "other", "port_id" => "out"}, :producer_mismatch},
            {"schema_id", "other", :schema_mismatch},
            {"schema_version", 2, :version_mismatch}
          ] do
        assert Routing.route(wiring, table, Map.put(message, field, value)) ==
                 {:error, {:source, reason}}
      end
    end

    assert Routing.route(wiring, table, nil) == {:error, {:envelope, :invalid_shape}}

    assert Routing.route(wiring, table, Map.put(message, "version", 2)) ==
             {:error, {:envelope, :invalid_version}}
  end

  test "wiring, table shapes, declared output source and ordered route errors" do
    {wiring, table, message} = fixture()
    assert Routing.route(nil, nil, nil) == {:error, {:wiring, :invalid_shape}}

    for invalid <- [
          nil,
          %{},
          Map.put(table, "extra", true),
          Map.put(table, "version", 2),
          Map.put(table, "source", %{}),
          Map.put(table, "routes", nil),
          Map.put(table, "routes", [%{"edge_id" => "x", "match" => %{}, "extra" => true}]),
          Map.put(table, "routes", [%{"edge_id" => "", "match" => %{}}])
        ] do
      assert Routing.route(wiring, invalid, message) == {:error, {:table, :invalid_shape}}
    end

    [route, _] = table["routes"]

    for match <- [
          nil,
          %{"payload" => :secret},
          %{"kind" => nil},
          %{"schema_id" => <<255>>},
          %{"schema_version" => 0},
          %{"schema_version" => 1.0}
        ] do
      assert Routing.validate(wiring, Map.put(table, "routes", [Map.put(route, "match", match)])) ==
               {:error, {:table, :invalid_shape}}
    end

    unknown = Map.put(route, "edge_id", "missing")

    assert Routing.validate(wiring, Map.put(table, "routes", [unknown, route, route])) ==
             {:error, {:route, "missing", :unknown_edge}}

    assert Routing.validate(wiring, Map.put(table, "routes", [route, route, unknown])) ==
             {:error, {:route, "ingest-dedup", :duplicate_route}}

    other = Map.put(route, "edge_id", "dedup-accumulate")

    assert Routing.validate(wiring, Map.put(table, "routes", [other, other])) ==
             {:error, {:route, "dedup-accumulate", :source_mismatch}}

    assert Routing.validate(wiring, put_in(table, ["source", "port_id"], "absent")) ==
             {:error, {:table, :unknown_source}}

    assert Routing.validate(wiring, put_in(table, ["source", "port_id"], "dedup.input")) ==
             {:error, {:table, :invalid_source}}
  end

  test "Cure source audit and imported generic type rejection" do
    assert {:ok, env} = Cure.Compiler.check_source(@source, source_roots: @roots)
    audit = Cure.Audit.Ledger.audit_env(env)

    for field <- [:unaudited, :unresolved, :holes, :axioms, :not_proven_total],
        do: assert(Map.fetch!(audit, field) == [])

    assert audit.absurd == 0

    consumer = """
    mod Elzoo.RoutingConsumer
      use Elzoo.Routing
      use Elzoo.Envelope
      fn accepts(message: Elzoo.Envelope.EnvelopeMessage(Int), rule: Elzoo.Routing.RoutingMatch) -> Bool =
        Elzoo.Routing.matches(message, rule)
    end
    """

    assert {:ok, _} = Cure.Compiler.check_source(consumer, source_roots: @roots)
    wrong = String.replace(consumer, "message: Elzoo.Envelope.EnvelopeMessage(Int)", "message: Int")
    assert {:error, _} = Cure.Compiler.check_source(wrong, source_roots: @roots)
  end
end
