# SPDX-License-Identifier: Apache-2.0
defmodule Elzoo.EffectTest do
  use ExUnit.Case, async: false

  defp declaration do
    %{
      "capability_id" => "integration/http",
      "operation" => "publication",
      "classification" => "untrusted",
      "command" => %{
        "version" => 1,
        "message_id" => "m",
        "schema_id" => "publication",
        "schema_version" => 1,
        "kind" => "command",
        "producer" => %{"unit_id" => "u", "port_id" => "p"},
        "payload" => nil
      }
    }
  end

  test "pure declaration reuses the complete Envelope ABI and preserves opaque payload" do
    d = declaration()
    assert {:ok, record} = Elzoo.Effect.decode(d)
    assert Elzoo.Effect.encode(record) == d
    assert Elzoo.Effect.declared?(d, ["integration/http"])
    refute Elzoo.Effect.declared?(d, ["integration/smtp"])
    refute Elzoo.Effect.declared?(d, List.duplicate("integration/http", 65))
    assert {:error, :declaration} = Elzoo.Effect.validate(put_in(d, ["command", "kind"], "event"))
    assert {:error, :declaration} = Elzoo.Effect.validate(put_in(d, ["command", "extension"], true))

    for bad <- [
          nil,
          [],
          %{},
          Map.put(d, "extra", 1),
          Map.put(d, "classification", "admin"),
          Map.put(d, "operation", <<255>>)
        ],
        do: assert(Elzoo.Effect.validate(bad) == {:error, :declaration})

    assert {:ok, _} = Elzoo.Effect.validate(%{d | "classification" => "trusted"})
  end

  test "Cure source/type audit has no owned axioms holes or unresolved obligations" do
    roots = Mix.Project.config()[:cure_paths] |> Enum.map(&Path.expand/1)
    source = File.read!(Path.expand("../../cure/elzoo/effect.cure", __DIR__))
    assert {:ok, env} = Cure.Compiler.check_source(source, source_roots: roots)
    a = Cure.Audit.Ledger.audit_env(env)
    assert a.axioms == [] and a.holes == [] and a.unresolved == [] and a.unaudited == []
    assert a.not_proven_total == [] and a.absurd == 0
    refute source =~ "foreign"
  end
end
