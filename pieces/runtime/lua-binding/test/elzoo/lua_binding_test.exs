# SPDX-License-Identifier: Apache-2.0
defmodule Elzoo.LuaBindingTest do
  use ExUnit.Case, async: true
  import ExUnit.CaptureLog
  alias Elzoo.{LuaBinding, ToolRegistry}

  @sentinel "SENTINEL-9f3c-do-not-leak"
  @max_estimate 9_007_199_254_740_992

  defp port(name, direction, suffix \\ ""),
    do: %{
      "id" => name <> "_" <> direction,
      "direction" => direction,
      "schema_id" => "elzoo.test." <> name <> suffix,
      "schema_version" => 1
    }

  defp arguments_schema,
    do: %{
      "type" => "object",
      "properties" => %{
        "query" => %{"type" => "string"},
        "tags" => %{"type" => "array", "items" => %{"type" => "string"}}
      },
      "required" => ["query"],
      "additionalProperties" => false
    }

  defp result_schema,
    do: %{
      "type" => "object",
      "properties" => %{"count" => %{"type" => "integer"}},
      "required" => ["count"],
      "additionalProperties" => false
    }

  defp manifest(name, version \\ 1, overrides \\ %{}) do
    Map.merge(
      %{
        "name" => name,
        "version" => version,
        "description" => "Function " <> name,
        "arguments" => %{"port" => port(name, "input"), "schema" => arguments_schema()},
        "result" => %{"port" => port(name, "output"), "schema" => result_schema()},
        "cost" => %{"unit" => "call", "estimate" => 3},
        "permissions" => ["read", "write"]
      },
      overrides
    )
  end

  defp declare(names) when is_list(names),
    do: Enum.map(names, fn {name, version} -> %{"name" => name, "version" => version} end)

  defp bind!(names, manifests) do
    {:ok, bindings} = LuaBinding.resolve(declare(names), manifests)
    bindings
  end

  defp one(overrides \\ %{}), do: bind!([{"search", 1}], [manifest("search", 1, overrides)])

  defp refused(declaration, manifests), do: LuaBinding.resolve(declaration, manifests)

  test "resolve_at_load" do
    five = [
      manifest("alpha"),
      manifest("beta", 2),
      manifest("gamma"),
      manifest("delta"),
      manifest("epsilon")
    ]

    assert {:ok, bindings} =
             LuaBinding.resolve(declare([{"alpha", 1}, {"beta", 2}, {"gamma", 1}]), five)

    assert LuaBinding.names(bindings) == ["alpha", "beta", "gamma"]

    # A missing function, a wrong version and a refused schema: all at once, in order.
    bad_schema =
      manifest("zeta", 1, %{
        "arguments" => %{"port" => port("zeta", "input"), "schema" => %{"type" => 12}}
      })

    declaration = declare([{"zeta", 1}, {"beta", 1}, {"alpha", 1}, {"missing", 1}])

    assert refused(declaration, five ++ [bad_schema]) ==
             {:refused,
              [
                %{name: "beta", code: :wrong_version},
                %{name: "missing", code: :unknown_function},
                %{name: "zeta", code: :invalid_manifest}
              ]}

    # An undeclared manifest with a fault in another member changes nothing.
    faulty = manifest("faulty") |> Map.put("module", "Elixir.Mod") |> Map.put("cost", :nope)
    assert {:ok, same} = LuaBinding.resolve(declare([{"alpha", 1}]), [manifest("alpha"), faulty])
    assert same == bind!([{"alpha", 1}], [manifest("alpha")])

    # Two versions of one name: the declared one resolves.
    v1 = manifest("search", 1, %{"cost" => %{"unit" => "call", "estimate" => 1}})
    v2 = manifest("search", 2, %{"cost" => %{"unit" => "call", "estimate" => 2}})
    assert {:ok, one_v2} = LuaBinding.resolve(declare([{"search", 2}]), [v1, v2])
    assert LuaBinding.cost(one_v2, "search") == {:ok, %{"unit" => "call", "estimate" => 2}}
    assert {:ok, one_v1} = LuaBinding.resolve(declare([{"search", 1}]), [v2, v1])
    assert LuaBinding.cost(one_v1, "search") == {:ok, %{"unit" => "call", "estimate" => 1}}

    invalid = fn manifest ->
      assert refused(declare([{"search", 1}]), [manifest]) ==
               {:refused, [%{name: "search", code: :invalid_manifest}]}
    end

    # Extra and missing keys, and a function value in a schema.
    invalid.(Map.put(manifest("search"), "module", "Elixir.Mod"))
    invalid.(Map.delete(manifest("search"), "cost"))

    invalid.(
      manifest("search", 1, %{
        "arguments" => %{
          "port" => port("search", "input"),
          "schema" => Map.put(arguments_schema(), "default", fn -> :ok end)
        }
      })
    )

    invalid.(
      manifest("search", 1, %{
        "result" => %{
          "port" => port("search", "output"),
          "schema" => Map.put(result_schema(), "default", &is_atom/1)
        }
      })
    )

    # The arguments schema must be an object schema that allows no other member.
    for schema <- [
          %{"type" => "string"},
          %{"properties" => %{"query" => %{"type" => "string"}}, "additionalProperties" => false},
          Map.delete(arguments_schema(), "additionalProperties"),
          Map.put(arguments_schema(), "additionalProperties", true),
          Map.put(arguments_schema(), "additionalProperties", %{"type" => "string"})
        ] do
      invalid.(
        manifest("search", 1, %{
          "arguments" => %{"port" => port("search", "input"), "schema" => schema}
        })
      )
    end

    # Directions, shapes of the two operands, and the port.
    invalid.(
      manifest("search", 1, %{
        "arguments" => %{"port" => port("search", "output"), "schema" => arguments_schema()}
      })
    )

    invalid.(
      manifest("search", 1, %{
        "result" => %{"port" => port("search", "input"), "schema" => result_schema()}
      })
    )

    invalid.(
      manifest("search", 1, %{
        "result" => %{"port" => port("search", "output"), "schema" => result_schema(), "extra" => 1}
      })
    )

    invalid.(manifest("search", 1, %{"result" => %{"schema" => result_schema()}}))

    invalid.(
      manifest("search", 1, %{
        "result" => %{"port" => %{"direction" => "output"}, "schema" => result_schema()}
      })
    )

    invalid.(manifest("search", 1, %{"result" => "nope"}))
  end

  test "arguments_located" do
    bindings = one()
    refused = fn value, path -> check_arguments(bindings, value, path) end

    assert LuaBinding.check_arguments(bindings, "search", %{"query" => "x", "tags" => ["a"]}) == :ok
    assert LuaBinding.check_arguments(bindings, "search", %{"query" => "x"}) == :ok

    # A member of a wrong type: the function name and the path of the member.
    assert {:refused, %{name: "search", violations: violations}} =
             LuaBinding.check_arguments(bindings, "search", %{"query" => 5})

    assert %{path: [:key], code: :schema_mismatch} in violations
    refused.(%{"query" => ["not", "a", "string"]}, [:key])

    # A missing member, an extra member, and an array where an object is declared.
    refused.(%{}, [])
    refused.(%{"query" => "x", "other" => 1}, [])
    refused.([%{"query" => "x"}], [])
    refused.("text", [])

    # A wrong element of an array member: the integer position.
    refused.(%{"query" => "x", "tags" => ["a", "b", 3]}, [:key, 2])
    refused.(%{"query" => "x", "tags" => [1]}, [:key, 0])

    # Over the size bound of core/payload-schema: one entry at the root.
    big = %{"query" => String.duplicate("a", 70_000)}

    assert LuaBinding.check_arguments(bindings, "search", big) ==
             {:refused, %{name: "search", violations: [%{path: [], code: :too_large}]}}

    # Any other error of check/3 is one entry at the root.
    assert LuaBinding.check_arguments(bindings, "search", %{"query" => {:tuple}}) ==
             {:refused, %{name: "search", violations: [%{path: [], code: :invalid_payload}]}}

    assert LuaBinding.check_arguments(bindings, "missing", %{}) == {:error, :unknown_function}
    assert LuaBinding.check_arguments(bindings, :search, %{}) == {:error, :unknown_function}
  end

  defp check_arguments(bindings, value, path) do
    assert {:refused, %{name: "search", violations: violations}} =
             LuaBinding.check_arguments(bindings, "search", value)

    assert %{path: path, code: :schema_mismatch} in violations
  end

  test "results_checked_before_return" do
    bindings = one()

    assert LuaBinding.check_result(bindings, "search", %{"count" => 3}) == :ok

    refused = fn value, path ->
      assert {:refused, %{name: "search", violations: violations}} =
               LuaBinding.check_result(bindings, "search", value)

      assert %{path: path, code: :schema_mismatch} in violations
    end

    refused.(%{"count" => "three"}, [:key])
    refused.(%{}, [])
    refused.(%{"count" => 1, "other" => 1}, [])
    refused.([1], [])

    # The result schema may allow what the arguments schema must not.
    open =
      one(%{
        "result" => %{
          "port" => port("search", "output"),
          "schema" => %{"type" => "array", "items" => %{"type" => "integer"}}
        }
      })

    assert LuaBinding.check_result(open, "search", [1, 2]) == :ok
    assert {:refused, %{violations: violations}} = LuaBinding.check_result(open, "search", [1, "2"])
    assert %{path: [1], code: :schema_mismatch} in violations

    big = %{"count" => 1, "pad" => String.duplicate("a", 70_000)}

    assert LuaBinding.check_result(bindings, "search", big) ==
             {:refused, %{name: "search", violations: [%{path: [], code: :too_large}]}}

    assert LuaBinding.check_result(bindings, "missing", %{"count" => 1}) ==
             {:error, :unknown_function}

    # Arguments are not results.
    assert {:refused, _} = LuaBinding.check_result(bindings, "search", %{"query" => "x"})
  end

  test "identity_changes_with_the_manifest" do
    base = [manifest("alpha"), manifest("beta"), manifest("gamma")]
    names = [{"alpha", 1}, {"beta", 1}, {"gamma", 1}]
    identity = LuaBinding.identity(bind!(names, base))

    assert identity =~ ~r/\Alua-binding-v1:sha256:[0-9a-f]{64}\z/

    # Any input order.
    assert LuaBinding.identity(bind!(Enum.reverse(names), Enum.reverse(base))) == identity
    assert LuaBinding.identity(bind!(names, Enum.shuffle(base))) == identity

    # Key order inside a map is not part of the manifest.
    reordered = for m <- base, do: m |> Map.to_list() |> Enum.reverse() |> Map.new()
    assert LuaBinding.identity(bind!(names, reordered)) == identity

    changed = fn overrides ->
      changed = [manifest("alpha", 1, overrides), manifest("beta"), manifest("gamma")]
      LuaBinding.identity(bind!(names, changed))
    end

    other_schema = %{
      "type" => "object",
      "properties" => %{"query" => %{"type" => "integer"}},
      "additionalProperties" => false
    }

    variants = [
      changed.(%{"description" => "Another description"}),
      changed.(%{"arguments" => %{"port" => port("alpha", "input"), "schema" => other_schema}}),
      changed.(%{
        "result" => %{"port" => port("alpha", "output"), "schema" => %{"type" => "object"}}
      }),
      changed.(%{
        "arguments" => %{"port" => port("alpha", "input", "_2"), "schema" => arguments_schema()}
      }),
      changed.(%{"cost" => %{"unit" => "call", "estimate" => 4}}),
      changed.(%{"cost" => %{"unit" => "token", "estimate" => 3}}),
      changed.(%{"permissions" => ["read"]}),
      changed.(%{"permissions" => ["read", "write", "admin"]})
    ]

    assert identity not in variants
    assert length(Enum.uniq(variants)) == length(variants)

    # A version change of a declared function.
    v2 = [manifest("alpha", 2), manifest("beta"), manifest("gamma")]

    assert LuaBinding.identity(bind!([{"alpha", 2}, {"beta", 1}, {"gamma", 1}], v2)) not in [
             identity | variants
           ]

    # An unresolved manifest does not change it, whatever it holds.
    extras = [
      manifest("delta"),
      manifest("alpha", 2),
      Map.put(manifest("eps"), "module", "M"),
      manifest("zeta", 1, %{"cost" => 1})
    ]

    assert LuaBinding.identity(bind!(names, base ++ extras)) == identity
    assert LuaBinding.identity(bind!([], base)) != identity
    assert LuaBinding.identity(bind!([{"alpha", 1}], base)) != identity
  end

  test "registry_source" do
    names = ["alpha", "beta", "gamma"]
    bindings = bind!(Enum.map(names, &{&1, 1}), Enum.map(names, &manifest/1))

    assert {:ok, source} = LuaBinding.source(bindings, "lua")
    assert source["id"] == "lua" and source["kind"] == "other" and source["callable"] == "adapter"

    assert Enum.map(source["tools"], & &1["name"]) == names

    for tool <- source["tools"] do
      assert Map.keys(tool) |> Enum.sort() == ~w(annotations description input_schema name trust)
      assert tool["trust"] == "untrusted" and tool["annotations"] == %{}
      assert tool["description"] == "Function " <> tool["name"]
      assert tool["input_schema"] == arguments_schema()
    end

    assert {:ok, snapshot} = ToolRegistry.snapshot([source])
    aliases = Enum.map(ToolRegistry.tools(snapshot), & &1["name"])
    assert aliases == ["lua_alpha", "lua_beta", "lua_gamma"]

    arguments = %{"query" => "x", "tags" => ["a"]}
    assert LuaBinding.check_arguments(bindings, "alpha", arguments) == :ok

    for alias <- aliases do
      assert {:resolved, tool} = ToolRegistry.resolve(snapshot, alias)
      assert tool.source == "lua" and "lua_" <> tool.tool == alias
      assert ToolRegistry.check(tool, arguments) == :ok
    end

    # 64 functions pass; the declaration bound refuses 65.
    many = for i <- 1..64, do: "f" <> Integer.to_string(i)

    assert {:ok, big} =
             LuaBinding.resolve(declare(Enum.map(many, &{&1, 1})), Enum.map(many, &manifest/1))

    assert {:ok, big_source} = LuaBinding.source(big, "lua")
    assert length(big_source["tools"]) == 64
    assert {:ok, _} = ToolRegistry.snapshot([big_source])
    assert LuaBinding.names(big) == Enum.sort(many)

    sixty_five = many ++ ["f65"]

    assert LuaBinding.resolve(
             declare(Enum.map(sixty_five, &{&1, 1})),
             Enum.map(sixty_five, &manifest/1)
           ) == {:error, :invalid_input}

    # A name of 64 characters gets a cut alias and still resolves.
    long = "a" <> String.duplicate("b", 63)
    longs = bind!([{long, 1}], [manifest(long)])
    assert {:ok, long_source} = LuaBinding.source(longs, "lua")
    assert {:ok, snapshot} = ToolRegistry.snapshot([long_source])
    assert [%{"name" => cut}] = ToolRegistry.tools(snapshot)
    assert byte_size(cut) == 64 and cut != "lua_" <> long
    assert {:resolved, %{tool: ^long, source: "lua"} = tool} = ToolRegistry.resolve(snapshot, cut)
    assert ToolRegistry.check(tool, %{"query" => "x"}) == :ok

    # An id that the registry refuses.
    for id <- ["", String.duplicate("a", 33), "bad id", "a.b", "abc\n", "é", nil, :lua, 5] do
      assert LuaBinding.source(bindings, id) == {:error, :invalid_input}
    end

    assert {:ok, _} = LuaBinding.source(bindings, String.duplicate("a", 32))
    assert {:ok, _} = LuaBinding.source(bindings, "A_z-9")
    assert {:ok, %{"tools" => []}} = LuaBinding.source(bind!([], []), "lua")
  end

  test "names_fit_the_sandbox" do
    sandbox? = &String.match?(&1, ~r/\A[a-z][a-z0-9_]{0,63}\z/)

    candidates =
      [
        "a",
        "z",
        "a0",
        "a_",
        "a__b",
        "abc_123",
        "search",
        String.duplicate("a", 64),
        String.duplicate("a", 63) <> "9",
        "",
        "A",
        "Abc",
        "aBc",
        "1a",
        "_a",
        "a-b",
        "a b",
        "a.b",
        "a/b",
        "ab\n",
        "abc\n",
        "\nabc",
        "é",
        "aé",
        "a\0",
        String.duplicate("a", 65),
        "a" <> String.duplicate("b", 64),
        <<255>>,
        "ａｂｃ"
      ]

    for name <- candidates do
      accepted = match?({:ok, _}, LuaBinding.resolve(declare([{name, 1}]), [manifest(name)]))
      assert accepted == sandbox?.(name), inspect(name)

      # The name of a manifest is read the same way, also when it is not declared.
      assert match?({:ok, _}, LuaBinding.resolve([], [manifest(name)])) == accepted, inspect(name)
    end

    for name <- [nil, :search, 5, 1.0, ["a"], %{}] do
      assert LuaBinding.resolve(declare([{name, 1}]), [manifest("search")]) ==
               {:error, :invalid_input}

      assert LuaBinding.resolve([], [manifest("search", 1, %{"name" => name})]) ==
               {:error, :invalid_input}
    end

    accepted = Enum.filter(candidates, &(is_binary(&1) and sandbox?.(&1)))
    bindings = bind!(Enum.map(Enum.shuffle(accepted), &{&1, 1}), Enum.map(accepted, &manifest/1))
    names = LuaBinding.names(bindings)
    assert names == Enum.sort(accepted)
    assert names == Enum.uniq(names)
    assert Enum.all?(names, sandbox?)

    # A name twice is refused, and so is a name that differs only by the end of line.
    assert LuaBinding.resolve(declare([{"a", 1}, {"a", 1}]), [manifest("a")]) ==
             {:error, :invalid_input}

    assert LuaBinding.resolve(declare([{"a", 1}, {"a\n", 1}]), [manifest("a")]) ==
             {:error, :invalid_input}
  end

  test "bounds_and_redaction" do
    invalid_manifest = fn overrides ->
      assert LuaBinding.resolve(declare([{"search", 1}]), [manifest("search", 1, overrides)]) ==
               {:refused, [%{name: "search", code: :invalid_manifest}]}
    end

    resolved = fn overrides ->
      assert {:ok, _} =
               LuaBinding.resolve(declare([{"search", 1}]), [manifest("search", 1, overrides)])
    end

    # Each bound and bound plus 1, in the members of a manifest.
    resolved.(%{"description" => "x"})
    resolved.(%{"description" => String.duplicate("a", 1_024)})
    resolved.(%{"description" => String.duplicate("é", 512)})

    for bad <- [
          "",
          String.duplicate("a", 1_025),
          String.duplicate("é", 512) <> "a",
          <<255>>,
          nil,
          5
        ],
        do: invalid_manifest.(%{"description" => bad})

    resolved.(%{"cost" => %{"unit" => "u", "estimate" => 1}})
    resolved.(%{"cost" => %{"unit" => String.duplicate("u", 128), "estimate" => @max_estimate}})

    for bad <- [
          %{"unit" => "", "estimate" => 1},
          %{"unit" => String.duplicate("u", 129), "estimate" => 1},
          %{"unit" => <<255>>, "estimate" => 1},
          %{"unit" => "u", "estimate" => 0},
          %{"unit" => "u", "estimate" => @max_estimate + 1},
          %{"unit" => "u", "estimate" => 1.0},
          %{"unit" => "u", "estimate" => "1"},
          %{"unit" => "u"},
          %{"estimate" => 1},
          %{"unit" => "u", "estimate" => 1, "extra" => 1},
          "call",
          nil
        ],
        do: invalid_manifest.(%{"cost" => bad})

    permissions = for i <- 1..64, do: "p" <> Integer.to_string(i)
    resolved.(%{"permissions" => []})
    resolved.(%{"permissions" => permissions})
    resolved.(%{"permissions" => [String.duplicate("p", 128), "é"]})

    for bad <- [
          permissions ++ ["p65"],
          ["a", "a"],
          [""],
          [String.duplicate("p", 129)],
          [<<255>>],
          [:read],
          [["read"]],
          %{"read" => true},
          "read",
          nil,
          ["read" | "tail"]
        ],
        do: invalid_manifest.(%{"permissions" => bad})

    # Name and version of a manifest or declaration are the one fault that is read of every manifest.
    for version <- [1, 2_147_483_647] do
      assert {:ok, _} =
               LuaBinding.resolve(declare([{"search", version}]), [manifest("search", version)])
    end

    for version <- [0, -1, 2_147_483_648, 1.0, "1", nil, :one] do
      assert LuaBinding.resolve(declare([{"search", version}]), [manifest("search")]) ==
               {:error, :invalid_input}

      assert LuaBinding.resolve([], [manifest("search", version)]) == {:error, :invalid_input}
    end

    # Bounds of the two lists.
    names = for i <- 1..64, do: "f" <> Integer.to_string(i)

    assert {:ok, _} =
             LuaBinding.resolve(declare(Enum.map(names, &{&1, 1})), Enum.map(names, &manifest/1))

    assert LuaBinding.resolve(declare(Enum.map(names ++ ["f65"], &{&1, 1})), [manifest("f1")]) ==
             {:error, :invalid_input}

    versions = for v <- 1..256, do: manifest("search", v)
    assert {:ok, _} = LuaBinding.resolve(declare([{"search", 256}]), versions)

    assert LuaBinding.resolve(declare([{"search", 256}]), versions ++ [manifest("other")]) ==
             {:error, :invalid_input}

    assert LuaBinding.resolve([], versions ++ [manifest("other")]) == {:error, :invalid_input}

    # Each malformed operand is :invalid_input.
    entry = %{"name" => "search", "version" => 1}
    one = manifest("search")

    for declaration <- [
          nil,
          :search,
          %{},
          "search",
          [nil],
          [%{}],
          [%{"name" => "search"}],
          [Map.put(entry, "extra", 1)],
          [%{"name" => "search", "version" => 1, "module" => "M"}],
          [entry | entry],
          [entry, entry],
          [[entry]],
          [{"search", 1}]
        ] do
      assert LuaBinding.resolve(declaration, [one]) == {:error, :invalid_input}
    end

    for manifests <- [
          nil,
          %{},
          one,
          "search",
          [nil],
          [[]],
          [:search],
          [one | one],
          [one, one],
          [Map.delete(one, "name")],
          [Map.delete(one, "version")],
          [Map.put(one, "version", 1.0)]
        ] do
      assert LuaBinding.resolve([entry], manifests) == {:error, :invalid_input}
    end

    bindings = bind!([{"search", 1}], [one])
    other = bind!([{"zeta", 1}], [manifest("zeta", 1, %{"permissions" => ["admin", "read"]})])

    for bad <- [
          nil,
          :bindings,
          [],
          %{},
          {:LuaBinding, nil},
          {:LuaBinding, []},
          {:Other, %{}},
          {:LuaBinding}
        ] do
      assert LuaBinding.names(bad) == {:error, :invalid_input}
      assert LuaBinding.identity(bad) == {:error, :invalid_input}
      assert LuaBinding.permissions(bad) == {:error, :invalid_input}
      assert LuaBinding.cost(bad, "search") == {:error, :invalid_input}
      assert LuaBinding.check_arguments(bad, "search", %{}) == {:error, :invalid_input}
      assert LuaBinding.check_result(bad, "search", %{}) == {:error, :invalid_input}
      assert LuaBinding.source(bad, "lua") == {:error, :invalid_input}
    end

    # cost/2 and permissions/1.
    assert LuaBinding.cost(bindings, "search") == {:ok, %{"unit" => "call", "estimate" => 3}}
    assert LuaBinding.cost(bindings, "zeta") == {:error, :unknown_function}
    assert LuaBinding.cost(bindings, nil) == {:error, :unknown_function}
    assert LuaBinding.permissions(bindings) == ["read", "write"]
    assert LuaBinding.permissions(bind!([], [])) == []

    assert {:ok, both} =
             LuaBinding.resolve(declare([{"zeta", 1}, {"search", 1}]), [
               manifest("zeta", 1, %{"permissions" => ["write", "admin"]}),
               one
             ])

    assert LuaBinding.permissions(both) == ["admin", "read", "write"]
    assert LuaBinding.permissions(other) == ["admin", "read"]

    # Equal inputs give equal results.
    assert LuaBinding.resolve(declare([{"search", 1}]), [one]) ==
             LuaBinding.resolve(declare([{"search", 1}]), [one])

    assert LuaBinding.identity(bindings) ==
             LuaBinding.identity(bind!([{"search", 1}], [manifest("search")]))

    assert LuaBinding.source(bindings, "lua") == LuaBinding.source(bindings, "lua")

    assert LuaBinding.check_arguments(bindings, "search", %{}) ==
             LuaBinding.check_arguments(bindings, "search", %{})

    # A sentinel in an argument, a result and a manifest description never appears in a reason, an
    # error or the log.
    leaky = manifest("search", 1, %{"description" => @sentinel})
    strict = bind!([{"search", 1}], [leaky])

    log =
      capture_log(fn ->
        outcomes = [
          LuaBinding.check_arguments(strict, "search", %{"query" => @sentinel, "other" => @sentinel}),
          LuaBinding.check_arguments(strict, "search", %{"query" => [@sentinel]}),
          LuaBinding.check_arguments(strict, "search", %{"tags" => [@sentinel, 1]}),
          LuaBinding.check_arguments(strict, "search", @sentinel),
          LuaBinding.check_arguments(strict, "search", %{
            "query" => String.duplicate(@sentinel, 4_000)
          }),
          LuaBinding.check_arguments(strict, "search", %{"query" => {@sentinel}}),
          LuaBinding.check_arguments(strict, @sentinel, %{"query" => @sentinel}),
          LuaBinding.check_result(strict, "search", %{"count" => @sentinel}),
          LuaBinding.check_result(strict, "search", [@sentinel]),
          LuaBinding.check_result(strict, "search", %{"count" => 1, "extra" => @sentinel}),
          LuaBinding.check_result(strict, @sentinel, @sentinel),
          LuaBinding.resolve(declare([{"search", 1}, {@sentinel, 1}]), [leaky]),
          LuaBinding.resolve(declare([{"search", 2}]), [leaky]),
          LuaBinding.resolve(declare([{"search", 1}]), [Map.put(leaky, "module", @sentinel)]),
          LuaBinding.resolve(declare([{"search", 1}]), [Map.put(leaky, "cost", @sentinel)]),
          LuaBinding.resolve(declare([{"search", 1}]), [Map.put(leaky, "name", @sentinel)]),
          LuaBinding.resolve(declare([{"search", 1}]), [leaky | @sentinel]),
          LuaBinding.resolve(@sentinel, [leaky]),
          LuaBinding.cost(strict, @sentinel),
          LuaBinding.names(@sentinel),
          LuaBinding.source(strict, @sentinel <> "!"),
          LuaBinding.identity(strict),
          LuaBinding.permissions(strict),
          LuaBinding.cost(strict, "search")
        ]

        for outcome <- outcomes do
          refute inspect(outcome, limit: :infinity, printable_limit: :infinity) =~ @sentinel,
                 "a sentinel text appears in " <> String.slice(inspect(outcome), 0, 300)
        end
      end)

    refute log =~ @sentinel

    # The description of a resolved function is only in the source that the caller asks for.
    assert {:ok, %{"tools" => [%{"description" => @sentinel}]}} = LuaBinding.source(strict, "lua")

    # No raise escapes a public function for a malformed operand.
    junk = [
      nil,
      :atom,
      5,
      1.5,
      "text",
      <<255>>,
      [],
      [1 | 2],
      %{},
      %{"name" => 1},
      {},
      {:a, :b},
      self(),
      &is_atom/1
    ]

    for a <- junk, b <- junk do
      # Two empty lists are the one valid pair: nothing declared, nothing supplied.
      if {a, b} != {[], []}, do: assert(LuaBinding.resolve(a, b) == {:error, :invalid_input})
      assert LuaBinding.names(a) == {:error, :invalid_input}
      assert LuaBinding.identity(a) == {:error, :invalid_input}
      assert LuaBinding.permissions(a) == {:error, :invalid_input}
      assert LuaBinding.cost(a, b) == {:error, :invalid_input}
      assert LuaBinding.source(a, b) == {:error, :invalid_input}
      assert LuaBinding.check_arguments(a, b, a) == {:error, :invalid_input}
      assert LuaBinding.check_result(a, b, a) == {:error, :invalid_input}
      assert LuaBinding.check_arguments(bindings, b, a) == {:error, :unknown_function}
      assert LuaBinding.check_result(bindings, b, a) == {:error, :unknown_function}
    end

    # One small checked example covers the public API.
    {result, _} = Code.eval_file(Path.expand("../../examples/elzoo/lua_binding.exs", __DIR__))

    assert result == %{
             names: ["docs_count", "issues_count"],
             permissions: ["docs.read", "issues.read"],
             refused_at_member: true,
             identity_bytes: 86,
             alias: "lua_issues_count"
           }
  end
end
