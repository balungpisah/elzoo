# SPDX-License-Identifier: Apache-2.0
defmodule Elzoo.RecipePackageTest do
  use ExUnit.Case, async: false
  import Kernel, except: [node: 1]
  import ExUnit.CaptureLog
  alias Elzoo.{RecipePackage, RecipeGraph, RecipeConfig}

  defp typed(direction) do
    %{
      "port" => %{
        "id" => direction,
        "direction" => direction,
        "schema_id" => "value",
        "schema_version" => 1
      },
      "schema" => %{"type" => "object"}
    }
  end

  defp callable(name \\ "main", kind \\ "graph") do
    base = %{"name" => name, "kind" => kind, "input" => typed("input"), "output" => typed("output")}

    case kind do
      "graph" -> Map.merge(base, %{"nodes" => [], "links" => [], "input_slots" => []})
      "agent" -> Map.put(base, "binding", "worker")
      "decision" -> Map.merge(base, %{"binding" => "worker", "choices" => ["yes", "no"]})
    end
  end

  defp graph(callables \\ [callable()]) do
    %{
      "version" => 1,
      "id" => "graph",
      "revision" => 1,
      "root" => hd(callables)["name"],
      "callables" => callables,
      "bindings" => [%{"name" => "worker", "target" => "unresolved"}],
      "rules" => []
    }
  end

  defp descriptor do
    %{
      "version" => 1,
      "id" => "independent-settings",
      "revision" => 1,
      "port" => typed("input")["port"],
      "secrets" => [],
      "schema" => %{"type" => "object", "properties" => %{}, "additionalProperties" => false}
    }
  end

  defp package(overrides \\ %{}) do
    Map.merge(
      %{
        "format_version" => 1,
        "name" => "package",
        "version" => "opaque",
        "needs" => [],
        "permissions" => [],
        "graph" => graph(),
        "settings" => descriptor(),
        "skills" => []
      },
      overrides
    )
    |> sign()
  end

  # Independent test oracle: ordered-object encoding delegates scalar encoding
  # to Jason, and recursively sorts every object's UTF-8 binary keys.
  defp canonical(value), do: Jason.encode!(ordered_value(value))

  defp ordered_value(value) when is_map(value),
    do: %Jason.OrderedObject{values: for({k, v} <- Enum.sort(value), do: {k, ordered_value(v)})}

  defp ordered_value(value) when is_list(value), do: Enum.map(value, &ordered_value/1)
  defp ordered_value(value), do: value

  defp sign(map) do
    hash = :crypto.hash(:sha256, canonical(Map.delete(map, "identity")))
    Map.put(map, "identity", "recipe-package-v1:sha256:" <> Base.encode16(hash, case: :lower))
  end

  defp skill(name \\ "helper") do
    %{
      "name" => name,
      "version" => "v1",
      "tools" => [],
      "frontmatter" => %{"name" => name, "description" => "Instructions"},
      "body" => ""
    }
  end

  defp exact(map) do
    assert {:ok, checked} = RecipePackage.decode(map)
    assert RecipePackage.encode(checked) === map
    checked
  end

  defp refuse(map, reason), do: assert(RecipePackage.decode(map) == {:error, reason})
  defp nest(0, value), do: value
  defp nest(n, value), do: [nest(n - 1, value)]
  defp names(n), do: for(i <- 1..n, do: "item-#{i}")

  defp node(id, extra \\ %{}),
    do: Map.merge(%{"id" => id, "kind" => "ask", "needs" => [], "gives" => []}, extra)

  defp link(from, to), do: %{"from" => from, "to" => to, "kind" => "order"}

  defp with_nodes(nodes, links \\ []),
    do: graph([Map.merge(callable(), %{"nodes" => nodes, "links" => links})])

  describe "manifest_identity_and_roundtrip" do
    test "minimal and three roots, opaque identities and digest coverage" do
      exact(package())

      for kind <- ~w(graph agent decision),
          do: exact(package(%{"graph" => graph([callable("root", kind)])}))

      base =
        package(%{"skills" => [skill()], "permissions" => ["read"], "needs" => ["host", "schema"]})

      mutations = [
        Map.put(base, "name", "packagf"),
        Map.put(base, "version", "opaquf"),
        put_in(base, ["skills"], [Map.put(skill(), "body", "x")]),
        put_in(base, ["graph", "revision"], 2),
        put_in(base, ["settings", "schema", "description"], "x"),
        Map.put(base, "permissions", ["reaf"]),
        Map.put(base, "skills", [Map.put(skill(), "tools", ["tool"])]),
        Map.put(base, "skills", [Map.put(skill(), "version", "v2")]),
        Map.put(base, "needs", Enum.reverse(base["needs"]))
      ]

      for changed <- mutations do
        refuse(changed, :invalid_identity)
        exact(sign(changed))
      end

      # Rebuild maps in reverse enumeration order, including nested maps.
      reordered = reorder(base)
      assert sign(reordered)["identity"] == base["identity"]
      exact(reordered)
      exact(package(%{"name" => "é", "version" => "a/../* opaque + version"}))
    end

    test "fixed canonical vector uses UTF-8 byte key order and Jason scalars" do
      # U+E000 sorts before U+10000 in UTF-8; RFC 8785 orders these differently.
      schema = %{
        "type" => "object",
        "examples" => [%{"\uE000" => 1.0, "𐀀" => [nil, true, false, "\n"]}]
      }

      base = package(%{"graph" => graph([put_in(callable(), ["input", "schema"], schema)])})
      exact(base)
      assert canonical(%{"𐀀" => 2, "\uE000" => 1}) == "{\"\uE000\":1,\"𐀀\":2}"
      wrong = Map.put(base, "identity", "recipe-package-v1:sha256:" <> String.duplicate("A", 64))

      for identity <- [
            nil,
            "",
            "sha256:bad",
            wrong["identity"],
            String.replace(base["identity"], "sha256", "SHA256")
          ] do
        refuse(Map.put(base, "identity", identity), :invalid_identity)
      end
    end

    test "representation and closed shape refuse without coercion" do
      for version <- [2, 0, "1", 1.0],
          do: refuse(Map.put(package(), "format_version", version), :unsupported_version)

      refuse(Map.put(package(), "extra", nil), :invalid_shape)
      refuse(Map.delete(package(), "name"), :invalid_shape)

      for bad <- [
            self(),
            make_ref(),
            fn -> :ok end,
            {:tuple},
            :atom,
            <<255>>,
            [1 | 2],
            %{1 => 2},
            ~D[2026-01-01],
            9_223_372_036_854_775_808,
            -9_223_372_036_854_775_809
          ] do
        refuse(put_in(package(), ["settings", "schema", "examples"], [bad]), :invalid_shape)
      end

      refuse(Map.put(package(), <<255>>, nil), :invalid_shape)

      for n <- [-9_223_372_036_854_775_808, 9_223_372_036_854_775_807, 1.5, nil, true, false] do
        exact(
          package(%{"graph" => graph([put_in(callable(), ["input", "schema", "examples"], [n])])})
        )
      end

      # BEAM refuses nonfinite IEEE-754 values at construction, before this API.
      for bits <- [0x7FF0000000000000, 0x7FF8000000000000, 0xFFF0000000000000] do
        assert_raise MatchError, fn -> <<_value::float-64>> = <<bits::unsigned-64>> end
      end
    end
  end

  defp reorder(value) when is_map(value),
    do: value |> Enum.reverse() |> Map.new(fn {k, v} -> {k, reorder(v)} end)

  defp reorder(value) when is_list(value), do: Enum.map(value, &reorder/1)
  defp reorder(value), do: value

  describe "ready_graph_and_settings_reuse" do
    test "actual ready API calls retain independent descriptors and unused bindings" do
      base = package()
      {result, calls, logs} = observe(fn -> RecipePackage.decode(base) end)
      assert {:ok, checked} = result
      assert RecipePackage.encode(checked) === base
      assert {RecipeGraph, :decode, [base["graph"]]} in calls
      assert Enum.any?(calls, &match?({RecipeGraph, :encode, [_]}, &1))
      assert {RecipeConfig, :build, [base["settings"]]} in calls
      assert logs == ""
      assert forbidden(calls) == []
    end

    test "graph refusals are wrapped including counts, nesting and cycles" do
      cycle = with_nodes([node("a"), node("b")], [link("a", "b"), link("b", "a")])

      bad_graphs = [
        Map.put(graph(), "root", "missing"),
        Map.put(graph([callable("main", "agent")]), "bindings", []),
        Map.put(graph(), "bindings", List.duplicate(hd(graph()["bindings"]), 2)),
        with_nodes([node("a", %{"kind" => "call", "callable" => "missing"})]),
        cycle,
        with_nodes([node("a", %{"kind" => "call", "callable" => "main"})]),
        graph(
          for i <- 1..17 do
            c = callable("c#{i}")

            if i == 17,
              do: c,
              else: Map.put(c, "nodes", [node("a", %{"kind" => "call", "callable" => "c#{i + 1}"})])
          end
        ),
        graph(for(i <- 1..65, do: callable("c#{i}"))),
        with_nodes(for(i <- 1..1001, do: node("n#{i}")))
      ]

      for g <- bad_graphs, do: refuse(Map.put(package(), "graph", g), :invalid_graph)
    end

    test "settings refusals and credential-reference declaration stay upstream-owned" do
      reference = %{
        "type" => "object",
        "required" => ["ref", "scope"],
        "additionalProperties" => false,
        "properties" =>
          Map.new(~w(ref scope), &{&1, %{"type" => "string", "minLength" => 1, "maxLength" => 128}})
      }

      settings =
        descriptor()
        |> put_in(["schema", "properties"], %{"key" => reference})
        |> Map.put("secrets", ["key"])

      exact(package(%{"settings" => settings}))

      for bad <- [
            Map.put(descriptor(), "version", 2),
            Map.put(descriptor(), "extra", nil),
            put_in(descriptor(), ["schema", "type"], "unknown"),
            put_in(settings, ["schema", "properties", "key", "default"], "PRIVATE_MARKER"),
            %{"key" => %{"ref" => "key", "scope" => "scope"}},
            put_in(descriptor(), ["schema", "properties"], Map.new(names(65), &{&1, %{}}))
          ] do
        refuse(Map.put(package(), "settings", bad), :invalid_settings_descriptor)
      end
    end
  end

  describe "skill_refusal_before_load" do
    test "required and optional decoded frontmatter, empty Markdown and no loader" do
      s =
        put_in(
          skill(),
          ["frontmatter"],
          Map.merge(skill()["frontmatter"], %{
            "license" => "Apache-2.0",
            "compatibility" => "host",
            "metadata" => %{"key" => ""},
            "allowed-tools" => "* ${advisory} &alias"
          })
        )

      checked = exact(package(%{"skills" => [s]}))
      assert RecipePackage.encode(checked)["skills"] == [s]
      would_be_loader = fn -> raise "must never load" end
      Process.put(:recipe_package_loader, would_be_loader)
      on_exit(fn -> Process.delete(:recipe_package_loader) end)
      exact(package(%{"skills" => [s]}))
    end

    test "first and last malformed skill never return a partial package" do
      s = skill()

      bad =
        [
          Map.delete(s, "version"),
          Map.put(s, "extra", nil),
          Map.put(s, "version", 1),
          Map.put(s, "version", ""),
          Map.put(s, "tools", ["t", "t"]),
          Map.put(s, "tools", [""]),
          Map.put(s, "tools", %{}),
          Map.put(s, "body", nil),
          Map.put(s, "frontmatter", []),
          put_in(s, ["frontmatter", "name"], "different"),
          Map.update!(s, "frontmatter", &Map.delete(&1, "description")),
          put_in(s, ["frontmatter", "description"], ""),
          put_in(s, ["frontmatter", "description"], 1),
          put_in(s, ["frontmatter", "metadata"], []),
          put_in(s, ["frontmatter", "metadata"], %{"key" => 1}),
          put_in(s, ["frontmatter", "metadata"], %{"" => "v"}),
          put_in(s, ["frontmatter", "license"], ""),
          put_in(s, ["frontmatter", "compatibility"], ""),
          put_in(s, ["frontmatter", "allowed-tools"], []),
          put_in(s, ["frontmatter", "unknown"], "x")
        ] ++ Enum.map(["Upper", "bad--name", "-edge", "edge-", "dot.name", "é", "a\n"], &skill/1)

      for malformed <- bad, list <- [[malformed, skill("other")], [skill("other"), malformed]] do
        refuse(package(%{"skills" => list}), :invalid_skill)
      end

      refuse(package(%{"skills" => [s, s]}), :invalid_skill)

      refuse(
        put_in(package(%{"skills" => [s]}), ["skills"], [Map.put(s, "body", <<255>>)]),
        :invalid_shape
      )
    end
  end

  describe "trust_and_bounds" do
    test "package bytes and depth are checked before upstream work or digest" do
      base = package()
      # An upstream-invalid graph can still exercise the outer exact byte cap.
      padded = put_in(base, ["graph", "padding"], "")
      pad = 2_097_152 - byte_size(Jason.encode!(padded))
      at = put_in(padded, ["graph", "padding"], String.duplicate("x", pad))
      assert byte_size(Jason.encode!(at)) == 2_097_152
      refuse(at, :invalid_graph)
      over = put_in(padded, ["graph", "padding"], String.duplicate("x", pad + 1))
      {result, calls, _} = observe(fn -> RecipePackage.decode(over) end)
      assert result == {:error, :too_large}
      assert calls == []

      for {n, reason} <- [{26, nil}, {27, :too_large}] do
        c = put_in(callable(), ["input", "schema", "examples"], nest(n, "leaf"))
        p = package(%{"graph" => graph([c])})
        if reason, do: refuse(p, reason), else: exact(p)
      end

      # Settings starts at package depth 2; unknown annotation containers count.
      d = put_in(descriptor(), ["schema", "examples"], nest(29, "leaf"))
      exact(package(%{"settings" => d}))

      refuse(
        package(%{"settings" => put_in(d, ["schema", "examples"], nest(30, "leaf"))}),
        :too_large
      )
    end

    test "needs permissions skill counts and unique tools have exact caps" do
      for field <- ~w(needs permissions) do
        exact(package(%{field => names(64)}))
        refuse(package(%{field => names(65)}), :too_large)
        refuse(package(%{field => ["same", "same"]}), :invalid_shape)
        refuse(package(%{field => [""]}), :invalid_shape)
        exact(package(%{field => [String.duplicate("é", 64)]}))
        refuse(package(%{field => [String.duplicate("é", 64) <> "x"]}), :too_large)
      end

      exact(package(%{"skills" => Enum.map(names(16), &skill/1)}))
      refuse(package(%{"skills" => Enum.map(names(17), &skill/1)}), :too_large)
      exact(package(%{"skills" => [Map.put(skill(), "tools", names(64))]}))
      refuse(package(%{"skills" => [Map.put(skill(), "tools", names(65))]}), :too_large)

      exact(
        package(%{
          "skills" => [
            Map.put(skill("one"), "tools", names(64)),
            Map.put(skill("two"), "tools", names(64))
          ]
        })
      )

      refuse(
        package(%{
          "skills" => [
            Map.put(skill("one"), "tools", names(64)),
            Map.put(skill("two"), "tools", ["extra"])
          ]
        }),
        :too_large
      )

      exact(package(%{"skills" => [Map.put(skill(), "tools", [String.duplicate("é", 64)])]}))

      refuse(
        package(%{"skills" => [Map.put(skill(), "tools", [String.duplicate("é", 64) <> "x"])]}),
        :too_large
      )
    end

    test "all text bounds count bytes or code points exactly without truncation" do
      for field <- ~w(name version) do
        exact(package(%{field => String.duplicate("é", 64)}))
        refuse(package(%{field => String.duplicate("é", 64) <> "x"}), :too_large)
        refuse(package(%{field => ""}), :invalid_shape)
      end

      exact(package(%{"skills" => [skill(String.duplicate("a", 64))]}))
      refuse(package(%{"skills" => [skill(String.duplicate("a", 65))]}), :too_large)

      text_caps = [
        {["version"], String.duplicate("é", 64)},
        {["body"], String.duplicate("é", 8192)},
        {["frontmatter", "license"], String.duplicate("é", 512)},
        {["frontmatter", "allowed-tools"], String.duplicate("é", 2048)},
        {["frontmatter", "metadata"], %{String.duplicate("é", 64) => String.duplicate("é", 512)}}
      ]

      for {path, value} <- text_caps do
        exact(package(%{"skills" => [put_in(skill(), path, value)]}))

        over =
          if is_map(value), do: Map.new(value, fn {k, v} -> {k, v <> "x"} end), else: value <> "x"

        refuse(package(%{"skills" => [put_in(skill(), path, over)]}), :too_large)
      end

      refuse(
        package(%{
          "skills" => [
            put_in(skill(), ["frontmatter", "metadata"], %{String.duplicate("k", 129) => ""})
          ]
        }),
        :too_large
      )

      for {field, max} <- [{"description", 1024}, {"compatibility", 500}] do
        # Combining marks are separate code points, despite grapheme clustering.
        at = String.duplicate("é", div(max, 2))
        exact(package(%{"skills" => [put_in(skill(), ["frontmatter", field], at)]}))

        refuse(
          package(%{"skills" => [put_in(skill(), ["frontmatter", field], at <> "x")]}),
          :too_large
        )
      end

      exact(
        package(%{
          "skills" => [put_in(skill(), ["frontmatter", "metadata"], Map.new(names(32), &{&1, ""}))]
        })
      )

      refuse(
        package(%{
          "skills" => [put_in(skill(), ["frontmatter", "metadata"], Map.new(names(33), &{&1, ""}))]
        }),
        :too_large
      )

      full = Map.put(skill("one"), "body", String.duplicate("x", 16_384))
      second = Map.put(skill("two"), "body", full["body"])
      exact(package(%{"skills" => [full, second]}))

      refuse(
        package(%{"skills" => [full, second, Map.put(skill("three"), "body", "x")]}),
        :too_large
      )
    end

    test "upstream byte caps are wrapped and declaration strings grant nothing" do
      for {field, limit, reason} <- [
            {"graph", 1_048_576, :invalid_graph},
            {"settings", 65_536, :invalid_settings_descriptor}
          ] do
        base = package()

        path =
          if field == "graph",
            do: [field, "callables", Access.at(0), "input", "schema", "description"],
            else: [field, "schema", "description"]

        padded = put_in(base, path, "")
        pad = limit - byte_size(Jason.encode!(padded[field]))
        at = padded |> put_in(path, String.duplicate("x", pad)) |> sign()
        assert byte_size(Jason.encode!(at[field])) == limit
        exact(at)
        refuse(padded |> put_in(path, String.duplicate("x", pad + 1)) |> sign(), reason)
      end

      rule = %{
        "callable" => "main",
        "node" => "ask",
        "policy" => %{"id" => "policy", "version" => 1, "content_hash" => String.duplicate("a", 64)},
        "requirement" => %{"name" => "approve", "version" => 1, "scope" => "once"}
      }

      g = Map.put(with_nodes([node("ask")]), "rules", [rule])

      p =
        package(%{
          "graph" => g,
          "permissions" => ["*", "ALLOW", "skip-approval"],
          "skills" => [put_in(skill(), ["frontmatter", "allowed-tools"], "*")]
        })

      exact(p)
      assert p["skills"] |> hd() |> Map.fetch!("tools") == []
      checked = exact(p)
      assert RecipePackage.encode(checked)["graph"]["rules"] === [rule]
      refuse(Map.put(p, "graph", Map.put(g, "root", "missing")), :invalid_graph)
      # Anyone can compute a matching digest; no trusted-origin flag is returned.
      exact(package(%{"name" => "untrusted-source", "permissions" => ["root"]}))
    end
  end

  describe "redaction_and_no_effects" do
    test "poisoned refusals return fixed atoms with no logs or effect calls" do
      marker = "PRIVATE_SYNTHETIC_MARKER"
      p = package(%{"name" => marker, "version" => marker, "permissions" => [marker]})

      bad = [
        {Map.put(p, "extra", marker), :invalid_shape},
        {Map.put(p, "format_version", marker), :unsupported_version},
        {Map.put(p, "identity", marker), :invalid_identity},
        {put_in(p, ["graph", "root"], marker), :invalid_graph},
        {put_in(p, ["settings", "schema", "type"], marker), :invalid_settings_descriptor},
        {Map.put(p, "skills", [
           put_in(skill(), ["frontmatter", "metadata"], %{marker => marker, "bad" => 1})
         ]), :invalid_skill},
        {Map.put(p, "name", String.duplicate(marker, 10)), :too_large}
      ]

      {results, calls, logs} =
        observe(fn -> Enum.map(bad, fn {input, _} -> RecipePackage.decode(input) end) end)

      assert results == Enum.map(bad, fn {_, reason} -> {:error, reason} end)
      refute inspect(results) =~ marker
      assert forbidden(calls) == []
      assert logs == ""
      assert RecipePackage.decode(p) === RecipePackage.decode(p)

      {:ok, {RecipePackage, [{:imports, imports}]}} =
        :beam_lib.chunks(:code.which(RecipePackage), [:imports])

      refute Enum.any?(imports, fn {module, _, _} ->
               module in [File, System, Process, Registry, Elzoo.Secrets]
             end)
    end

    test "checked example composes only graph and settings declarations" do
      path = Path.expand("../../examples/recipe_package.exs", __DIR__)
      {checked, _} = Code.eval_file(path)
      data = RecipePackage.encode(checked)
      assert data["skills"] == []
      assert data["settings"]["id"] != data["graph"]["id"]
      exact(data)
    end
  end

  defp patterns do
    [
      {RecipeGraph, :decode, 1},
      {RecipeGraph, :encode, 1},
      {RecipeConfig, :build, 1},
      {:crypto, :hash, 2},
      {:telemetry, :execute, 3},
      {Elzoo.Secrets, :_, :_},
      {File, :_, :_},
      {:file, :_, :_},
      {:gen_tcp, :_, :_},
      {:ssl, :_, :_},
      {Registry, :_, :_},
      {System, :cmd, 3},
      {:erlang, :open_port, 2},
      {:erlang, :spawn, :_},
      {:erlang, :spawn_link, :_},
      {:erlang, :spawn_monitor, :_}
    ]
  end

  defp forbidden(calls),
    do:
      Enum.reject(calls, fn {m, f, _} ->
        {m, f} in [
          {RecipeGraph, :decode},
          {RecipeGraph, :encode},
          {RecipeConfig, :build},
          {:crypto, :hash}
        ]
      end)

  defp observe(fun) do
    parent = self()
    for {module, _, _} <- patterns(), do: Code.ensure_loaded!(module)

    worker =
      spawn(fn ->
        receive do: (:run -> send(parent, {:result, fun.()}))
        receive do: (:stop -> :ok)
      end)

    for pattern <- patterns(), do: :erlang.trace_pattern(pattern, true, [:local])
    :erlang.trace(worker, true, [:call])

    on_exit(fn ->
      send(worker, :stop)
      for pattern <- patterns(), do: :erlang.trace_pattern(pattern, false, [:local])
    end)

    logs =
      capture_log(fn ->
        send(worker, :run)
        assert_receive {:result, result}, 10_000
        send(parent, {:observed, result})
      end)

    assert_receive {:observed, result}
    delivered = :erlang.trace_delivered(worker)
    assert_receive {:trace_delivered, ^worker, ^delivered}
    {result, collect(worker), logs}
  end

  defp collect(worker) do
    receive do
      {:trace, ^worker, :call, call} -> [call | collect(worker)]
    after
      0 -> []
    end
  end
end
