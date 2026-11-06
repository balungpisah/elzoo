defmodule Elzoo.RegistryTest do
  use ExUnit.Case, async: true
  @root File.cwd!()

  defp scratch do
    path = Path.join(System.tmp_dir!(), "elzoo-registry-#{System.unique_integer([:positive])}")
    File.mkdir_p!(path)
    on_exit(fn -> File.rm_rf!(path) end)
    path
  end

  defp fixture do
    path = scratch()

    for file <- ["registry", "pieces", "mix.lock", ".tool-versions"] do
      File.cp_r!(Path.join(@root, file), Path.join(path, file))
    end

    path
  end

  defp change_json(root, path, fun) do
    file = Path.join(root, path)
    content = file |> File.read!() |> Jason.decode!() |> fun.()
    File.write!(file, Jason.encode!(content))
  end

  test "library-only selection stays independent of Cure; dependencies are ordered" do
    registry = Elzoo.Registry.load!(@root)

    assert Enum.map(Elzoo.Registry.select!(registry, ["integration/json"]), & &1["id"]) == [
             "integration/json"
           ]

    selected = Elzoo.Registry.select!(registry, ["assembly/ingest-dedup-accumulate"])
    ids = Enum.map(selected, & &1["id"])

    assert Enum.find_index(ids, &(&1 == "core/operator")) <
             Enum.find_index(ids, &(&1 == "delivery/idempotency"))

    refute "integration/json" in ids

    assert_raise ArgumentError, ~r/not consumable/, fn ->
      Elzoo.Registry.select!(registry, ["state/scheduler"])
    end
  end

  test "missing source, unlisted source and fake proof cannot become ready metadata" do
    root = fixture()
    file = Path.join(root, "pieces/core/operator/cure/elzoo/composition.cure")
    bytes = File.read!(file)
    File.rm!(file)
    assert_raise ArgumentError, ~r/missing source/, fn -> Elzoo.Registry.load!(root) end
    File.write!(file, bytes)
    extra = Path.join(root, "pieces/core/operator/cure/forgotten.cure")
    File.write!(extra, "mod Forgotten\nend\n")
    assert_raise ArgumentError, ~r/unlisted/, fn -> Elzoo.Registry.load!(root) end
    File.rm!(extra)

    change_json(root, "pieces/core/operator/piece.json", fn piece ->
      Map.update!(piece, "grounding", fn claims ->
        Enum.map(claims, fn claim ->
          if claim["kind"] == "proof", do: Map.put(claim, "symbol", "invented_law"), else: claim
        end)
      end)
    end)

    assert_raise ArgumentError, ~r/missing checked equality proof/, fn ->
      Elzoo.Registry.load!(root)
    end
  end

  test "comments and strings cannot impersonate an equality proof declaration" do
    for impostor <- [
          "\n# fn invented_law(input) -> Equivalent(Int, input, input)\n",
          "\nmod Fake\n  fn text() -> String = \"fn invented_law(input) -> Equivalent(Int, input, input)\"\nend\n"
        ] do
      root = fixture()
      file = Path.join(root, "pieces/core/operator/cure/elzoo/composition.cure")
      File.write!(file, File.read!(file) <> impostor)

      change_json(root, "pieces/core/operator/piece.json", fn piece ->
        Map.update!(piece, "grounding", fn claims ->
          Enum.map(claims, fn claim ->
            if claim["kind"] == "proof", do: Map.put(claim, "symbol", "invented_law"), else: claim
          end)
        end)
      end)

      assert_raise ArgumentError, ~r/missing checked equality proof/, fn ->
        Elzoo.Registry.load!(root)
      end
    end
  end

  test "cycles, provider drift and traversal are rejected" do
    root = fixture()
    manifest = "pieces/core/operator/piece.json"
    change_json(root, manifest, &Map.put(&1, "dependencies", ["delivery/idempotency"]))
    assert_raise ArgumentError, ~r/dependency cycle/, fn -> Elzoo.Registry.load!(root) end
    change_json(root, manifest, &Map.put(&1, "dependencies", []))

    change_json(
      root,
      "registry/providers.json",
      &put_in(&1, ["providers", "jason", "version"], "0.0.0")
    )

    assert_raise ArgumentError, ~r/provider lock mismatch/, fn -> Elzoo.Registry.load!(root) end

    File.cp!(
      Path.join(@root, "registry/providers.json"),
      Path.join(root, "registry/providers.json")
    )

    change_json(root, manifest, &Map.put(&1, "files", ["../escape.ex"]))
    assert_raise ArgumentError, ~r/unsafe relative path/, fn -> Elzoo.Registry.load!(root) end
  end

  test "OTP application instructions require literal application names" do
    root = fixture()

    change_json(
      root,
      "pieces/runtime/unit/piece.json",
      &Map.put(&1, "applications", ["crypto, injected() "])
    )

    assert_raise ArgumentError, ~r/invalid OTP application/, fn -> Elzoo.Registry.load!(root) end
  end

  test "source symlinks cannot escape a bundle" do
    root = fixture()
    file = Path.join(root, "pieces/core/operator/cure/elzoo/composition.cure")
    File.rm!(file)
    File.ln_s!(Path.join(@root, "pieces/core/operator/cure/elzoo/composition.cure"), file)
    assert_raise ArgumentError, ~r/symlink source/, fn -> Elzoo.Registry.load!(root) end
  end

  test "generated ledger records planned gaps and has no drift" do
    registry = Elzoo.Registry.load!(@root)
    ledger = Elzoo.Registry.ledger(registry)
    assert ledger == File.read!(Path.join(@root, "LEDGER.md"))
    assert ledger =~ "state/event-log"
    assert ledger =~ "none claimed"
    assert ledger =~ "ready (subset)"
    assert ledger =~ "Operational applicability"
  end

  test "operational omissions and invalid inheritance cannot masquerade as declared contracts" do
    root = fixture()
    file = "pieces/runtime/unit/piece.json"
    original = File.read!(Path.join(root, file))

    for {change, expected} <- [
          {&update_in(&1, ["operations", "config"], fn entry -> Map.delete(entry, "evidence") end),
           ~r/missing config test evidence/},
          {&put_in(&1, ["operations", "config", "evidence"], []), ~r/missing config test evidence/},
          {&put_in(&1, ["operations", "config", "evidence"], ["README.md"]),
           ~r/invalid config test evidence/},
          {&put_in(&1, ["operations", "config", "evidence"], ["test/missing_test.exs"]),
           ~r/invalid config test evidence/},
          {&Map.delete(&1, "operations"), ~r/declare telemetry\/config\/control/},
          {&put_in(&1, ["operations", "config", "status"], "automatic"), ~r/invalid config/},
          {&put_in(&1, ["operations", "control", "contract"], ""), ~r/control contract/},
          {&put_in(&1, ["operations", "control"], %{
             "status" => "inherited",
             "contract" => "external lifecycle",
             "from" => "unknown"
           }), ~r/undeclared control inheritance/}
        ] do
      File.write!(Path.join(root, file), original)
      change_json(root, file, change)
      assert_raise ArgumentError, expected, fn -> Elzoo.Registry.load!(root) end
    end
  end
end
