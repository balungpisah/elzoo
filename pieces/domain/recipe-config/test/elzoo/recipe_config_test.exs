# SPDX-License-Identifier: Apache-2.0
defmodule Elzoo.RecipeConfigTest do
  use ExUnit.Case, async: false
  import ExUnit.CaptureLog
  alias Elzoo.RecipeConfig

  @reference %{
    "type" => "object",
    "required" => ["ref", "scope"],
    "properties" => %{
      "ref" => %{"type" => "string", "minLength" => 1, "maxLength" => 128},
      "scope" => %{"type" => "string", "minLength" => 1, "maxLength" => 128}
    },
    "additionalProperties" => false
  }

  defp port(overrides \\ %{}) do
    Map.merge(
      %{
        "id" => "recipe.settings",
        "direction" => "input",
        "schema_id" => "example/recipe-settings",
        "schema_version" => 1
      },
      overrides
    )
  end

  defp object(properties, required \\ []) do
    %{
      "type" => "object",
      "properties" => properties,
      "required" => required,
      "additionalProperties" => false
    }
  end

  defp descriptor(schema, secrets \\ [], overrides \\ %{}) do
    Map.merge(
      %{
        "version" => 1,
        "id" => "example/recipe",
        "revision" => 1,
        "port" => port(),
        "schema" => schema,
        "secrets" => secrets
      },
      overrides
    )
  end

  defp built(schema, secrets \\ []) do
    assert {:ok, checked} = RecipeConfig.build(descriptor(schema, secrets))
    checked
  end

  defp exact(checked, settings) do
    assert {:ok, returned} = RecipeConfig.check(checked, settings)
    assert returned === settings
  end

  defp secret_schema, do: object(%{"key" => @reference, "note" => %{"type" => "string"}})
  defp ref(ref, scope \\ "tenant-a/model"), do: %{"ref" => ref, "scope" => scope}

  defp nest(0, leaf), do: leaf
  defp nest(n, leaf), do: [nest(n - 1, leaf)]

  describe "declared_settings_only" do
    test "ordinary nested and optional values are accepted unchanged and never dropped" do
      checked =
        built(
          object(
            %{
              "name" => %{"type" => "string"},
              "limits" => %{"type" => "object", "properties" => %{"max" => %{"type" => "integer"}}},
              "tags" => %{"type" => "array", "items" => %{"type" => "string"}}
            },
            ["name"]
          )
        )

      exact(checked, %{"name" => "bot"})
      exact(checked, %{"name" => "bot", "tags" => ["a", "b"], "limits" => %{"max" => 3}})
      exact(checked, %{"name" => "bot", "limits" => %{"max" => 3, "unlisted" => [nil, 1.5]}})

      assert {:error, :invalid_settings} = RecipeConfig.check(checked, %{"name" => 1})
      assert {:error, :invalid_settings} = RecipeConfig.check(checked, %{"tags" => []})

      assert {:error, :invalid_settings} =
               RecipeConfig.check(checked, %{"name" => "bot", "extra" => true})

      assert {:error, :invalid_settings} =
               RecipeConfig.check(checked, %{"name" => "bot", "limits" => %{"max" => "3"}})

      assert {:error, :invalid_settings} = RecipeConfig.check(checked, ["name"])
    end

    test "empty settings follow the declarations" do
      exact(built(object(%{})), %{})
      exact(built(object(%{"opt" => %{"type" => "integer"}})), %{})

      assert {:error, :invalid_settings} = RecipeConfig.check(built(object(%{})), %{"x" => 1})

      assert {:error, :invalid_settings} =
               RecipeConfig.check(built(object(%{"r" => %{}}, ["r"])), %{})

      assert {:error, :invalid_settings} =
               RecipeConfig.check(built(secret_schema() |> Map.put("required", ["key"])), %{})
    end

    test "invalid descriptors and unsupported versions are refused before compilation" do
      schema = object(%{})

      for invalid <- [
            nil,
            [],
            "{}",
            Map.delete(descriptor(schema), "secrets"),
            Map.put(descriptor(schema), "extra", 1),
            Map.new(descriptor(schema), fn {k, v} -> {String.to_atom(k), v} end),
            descriptor(schema, [], %{"version" => "1"}),
            descriptor(schema, [], %{"version" => 1.0}),
            descriptor(schema, [], %{"id" => ""}),
            descriptor(schema, [], %{"id" => :id}),
            descriptor(schema, [], %{"id" => <<0xFF>>}),
            descriptor(schema, [], %{"revision" => 0}),
            descriptor(schema, [], %{"revision" => "1"}),
            descriptor(schema, "x"),
            descriptor(schema, [1])
          ] do
        assert {:error, :invalid_descriptor} = RecipeConfig.build(invalid)
      end

      for version <- [0, 2, -1] do
        assert {:error, :unsupported_version} =
                 RecipeConfig.build(descriptor(schema, [], %{"version" => version}))
      end
    end

    test "undeclared or duplicate secret names and open object schemas are refused" do
      assert {:error, :invalid_descriptor} = RecipeConfig.build(descriptor(secret_schema(), ["x"]))

      assert {:error, :invalid_descriptor} =
               RecipeConfig.build(descriptor(secret_schema(), ["key", "key"]))

      closed = object(%{"a" => %{}})

      for open <- [
            Map.delete(closed, "additionalProperties"),
            Map.put(closed, "additionalProperties", true),
            Map.put(closed, "additionalProperties", %{"type" => "string"}),
            Map.put(closed, "patternProperties", %{"^x" => %{}}),
            Map.put(closed, "unevaluatedProperties", false),
            Map.delete(closed, "type"),
            Map.put(closed, "type", ["object"]),
            Map.delete(closed, "properties"),
            Map.put(closed, "properties", [%{}]),
            true,
            %{}
          ] do
        assert {:error, :invalid_schema} = RecipeConfig.build(descriptor(open))
      end
    end
  end

  describe "secret_reference_not_value" do
    test "a valid reference is retained byte for byte" do
      checked = built(secret_schema(), ["key"])
      exact(checked, %{"key" => ref("key-1")})
      exact(checked, %{"key" => ref("ключ/é€", "tenant/ü"), "note" => "n"})
      exact(checked, %{"note" => "absent optional secret"})
    end

    test "raw values, value members, wrong members, bad identifiers and structs are refused" do
      checked = built(secret_schema(), ["key"])
      long = String.duplicate("a", 129)

      for invalid <- [
            "raw-credential",
            1,
            nil,
            [],
            %{"value" => "raw-credential"},
            %{"ref" => "k", "scope" => "s", "value" => "raw-credential"},
            %{"ref" => "k"},
            %{"scope" => "s"},
            %{},
            ref(""),
            ref("k", ""),
            ref(long),
            ref("k", long),
            ref(1),
            ref(["k"])
          ] do
        assert {:error, :invalid_secret} = RecipeConfig.check(checked, %{"key" => invalid})
      end

      credential = %Elzoo.Secrets.Credential{
        value: "raw-credential",
        version: 1,
        expires_at_unix_ms: 1
      }

      for invalid <- [credential, %{ref: "k", scope: "s"}, Map.from_struct(credential)] do
        assert RecipeConfig.check(checked, %{"key" => invalid}) == {:error, :invalid_settings}
      end
    end

    test "multibyte identifiers are bounded by 128 bytes, not characters" do
      checked = built(secret_schema(), ["key"])
      two = String.duplicate("é", 64)
      three = String.duplicate("€", 42) <> "ab"
      assert byte_size(two) == 128 and String.length(two) == 64
      assert byte_size(three) == 128

      exact(checked, %{"key" => ref(two, three)})

      for over <- [two <> "a", three <> "c", String.duplicate("€", 43)] do
        assert byte_size(over) == 129
        assert String.length(over) < 128
        assert {:error, :invalid_secret} = RecipeConfig.check(checked, %{"key" => ref(over)})
        assert {:error, :invalid_secret} = RecipeConfig.check(checked, %{"key" => ref("k", over)})
      end
    end

    test "secret property schemas must be exactly the reference shape" do
      assert {:ok, _} =
               RecipeConfig.build(
                 descriptor(
                   object(%{"key" => Map.put(@reference, "required", ["scope", "ref"])}),
                   ["key"]
                 )
               )

      put_ref = fn key, value -> put_in(@reference, ["properties", "ref", key], value) end

      for bad <- [
            %{"type" => "string"},
            %{},
            Map.put(@reference, "default", ref("k")),
            Map.put(@reference, "enum", [ref("k")]),
            Map.put(@reference, "const", ref("k")),
            Map.put(@reference, "description", "credential"),
            Map.delete(@reference, "required"),
            Map.put(@reference, "required", ["ref"]),
            Map.put(@reference, "additionalProperties", true),
            put_in(@reference, ["properties", "value"], %{"type" => "string"}),
            put_ref.("maxLength", 256),
            put_ref.("maxLength", 128.0),
            put_ref.("minLength", 0),
            put_ref.("default", "k")
          ] do
        assert {:error, :invalid_schema} =
                 RecipeConfig.build(descriptor(object(%{"key" => bad}), ["key"]))
      end
    end

    test "no resolver or reveal path is called or present" do
      parent = self()

      resolver = fn _, _ ->
        send(parent, :resolver_called)
        raise "resolver must not be called"
      end

      checked = built(secret_schema(), ["key"])

      {results, calls, logs} =
        observe(fn ->
          [
            RecipeConfig.check(checked, %{"key" => ref("k")}),
            RecipeConfig.check(checked, %{"key" => resolver}),
            RecipeConfig.check(checked, %{"key" => ref("k"), "note" => resolver})
          ]
        end)

      assert [{:ok, _}, {:error, :invalid_settings}, {:error, :invalid_settings}] = results
      refute_received :resolver_called
      assert calls == []
      assert logs == ""

      {:ok, {_, [imports: imports]}} =
        :beam_lib.chunks(:code.which(RecipeConfig), [:imports])

      modules = imports |> Enum.map(&elem(&1, 0)) |> Enum.uniq()
      refute Elzoo.Secrets in modules
      refute Elzoo.Secrets.Credential in modules
      assert {Elzoo.PayloadSchema, :build, 2} in imports
      assert {Elzoo.PayloadSchema, :check, 3} in imports
    end
  end

  describe "identity_and_ready_schema_reuse" do
    test "identical independent descriptors give equal results and identity is retained" do
      make = fn -> descriptor(secret_schema(), ["key"]) end
      assert {:ok, a} = RecipeConfig.build(make.())
      assert {:ok, b} = RecipeConfig.build(make.())
      assert a == b
      settings = %{"key" => ref("k"), "note" => "n"}
      assert RecipeConfig.check(a, settings) == RecipeConfig.check(b, settings)

      for change <- [
            %{"id" => "example/other"},
            %{"revision" => 2},
            %{"port" => port(%{"schema_version" => 2})},
            %{"port" => port(%{"id" => "other.settings"})}
          ] do
        assert {:ok, other} = RecipeConfig.build(Map.merge(make.(), change))
        assert other != a
        exact(other, settings)
      end
    end

    test "Ports and schemas are refused through the ready payload schema" do
      schema = object(%{"a" => %{"type" => "integer"}})

      for invalid <- [
            port(%{"direction" => "output"}),
            Map.put(port(), "extra", 1),
            Map.delete(port(), "schema_id"),
            port(%{"schema_version" => 0}),
            port(%{"id" => ""}),
            port(%{"direction" => "sideways"}),
            "port"
          ] do
        assert {:error, :invalid_descriptor} =
                 RecipeConfig.build(descriptor(schema, [], %{"port" => invalid}))
      end

      for bad <- [
            %{"$ref" => "https://example.invalid/schema"},
            %{"$ref" => "jsv:module:Elixir.Elzoo.RecipeConfig"},
            %{"$dynamicRef" => "urn:example:x"},
            %{"type" => "not-a-type"},
            %{"pattern" => "("}
          ] do
        assert {:error, :invalid_schema} = RecipeConfig.build(descriptor(object(%{"a" => bad})))
      end

      assert {:error, :invalid_schema} =
               RecipeConfig.build(
                 descriptor(Map.put(schema, "$schema", "http://json-schema.org/draft-07/schema#"))
               )

      local =
        schema
        |> Map.put("$defs", %{"n" => %{"type" => "integer"}})
        |> put_in(["properties", "a"], %{"$ref" => "#/$defs/n"})

      checked = built(local)
      exact(checked, %{"a" => 1})
      assert {:error, :invalid_settings} = RecipeConfig.check(checked, %{"a" => "1"})
    end

    test "no coercion, defaults or lookup" do
      checked =
        built(
          object(%{
            "n" => %{"type" => "integer", "default" => 7},
            "s" => %{"type" => "string", "default" => "d"}
          })
        )

      exact(checked, %{})
      exact(checked, %{"n" => 3.0})
      assert {:error, :invalid_settings} = RecipeConfig.check(checked, %{"n" => "3"})
      assert {:error, :invalid_settings} = RecipeConfig.check(checked, %{"s" => 1})
    end

    test "checked example hands references to host injection code only" do
      parent = self()
      path = Path.expand("../../examples/elzoo/recipe_config.exs", __DIR__)
      {{results, _}, calls, _logs} = observe(fn -> Code.eval_file(path) end)
      assert calls == []

      assert results.settings == %{
               "greeting" => "hello",
               "model_key" => %{"ref" => "key-1", "scope" => "tenant-a/model"}
             }

      assert results.requests == [{"model_key", %{ref: "key-1", scope: "tenant-a/model"}}]
      assert results.raw_value == {:error, :invalid_secret}

      resolver = fn _, _ -> send(parent, :resolver_called) end

      for {_, request} <- results.requests do
        assert {:error, :denied} =
                 Elzoo.Secrets.resolve(request, %{grant: :deny, resolver: resolver})
      end

      refute_received :resolver_called
    end

    test "values not returned by build are refused" do
      {:ok, payload_checked} = Elzoo.PayloadSchema.build(port(), object(%{}))

      for forged <- [nil, payload_checked, {RecipeConfig, nil}] do
        assert {:error, :validation_failed} = RecipeConfig.check(forged, %{})
      end
    end
  end

  describe "fixed_bounds_and_redacted_failure" do
    test "64 properties and secret declarations are accepted, 65 refused" do
      names = for i <- 1..65, do: "s#{i}"
      properties = Map.new(names, &{&1, @reference})
      sixty_four = Enum.take(names, 64)

      checked = built(object(Map.take(properties, sixty_four)), sixty_four)
      exact(checked, Map.new(sixty_four, &{&1, ref(&1)}))

      assert {:error, :invalid_schema} =
               RecipeConfig.build(descriptor(object(properties), sixty_four))

      assert {:error, :invalid_descriptor} =
               RecipeConfig.build(descriptor(object(properties), names))

      assert {:error, :invalid_descriptor} =
               RecipeConfig.build(
                 descriptor(object(Map.take(properties, sixty_four)), sixty_four ++ ["s1"])
               )
    end

    test "name identifier and revision limits" do
      name = String.duplicate("é", 64)
      exact(built(object(%{name => %{}})), %{name => 1})

      for bad <- ["", name <> "a"] do
        assert {:error, :invalid_schema} = RecipeConfig.build(descriptor(object(%{bad => %{}})))
      end

      assert {:error, :invalid_descriptor} =
               RecipeConfig.build(descriptor(object(%{<<0xFF>> => %{}})))

      assert {:ok, _} = RecipeConfig.build(descriptor(object(%{}), [], %{"id" => name}))

      assert {:ok, _} =
               RecipeConfig.build(descriptor(object(%{}), [], %{"revision" => 2_147_483_647}))

      for bad <- [%{"id" => name <> "a"}, %{"revision" => 2_147_483_648}] do
        assert {:error, :invalid_descriptor} = RecipeConfig.build(descriptor(object(%{}), [], bad))
      end
    end

    test "descriptor compact size and depth limits are exact" do
      base = descriptor(Map.put(object(%{}), "description", ""))
      pad = 65_536 - byte_size(Jason.encode!(base))
      at = put_in(base, ["schema", "description"], String.duplicate("d", pad))
      assert byte_size(Jason.encode!(at)) == 65_536
      assert {:ok, _} = RecipeConfig.build(at)

      over = put_in(base, ["schema", "description"], String.duplicate("d", pad + 1))
      assert {:error, :invalid_descriptor} = RecipeConfig.build(over)

      # Descriptor map is depth 1 and the schema depth 2; examples add 30 or 31 more.
      deep = fn n -> descriptor(Map.put(object(%{}), "examples", nest(n, []))) end
      assert {:ok, _} = RecipeConfig.build(deep.(29))
      assert {:error, :invalid_descriptor} = RecipeConfig.build(deep.(30))

      for nonplain <- [self(), {:tuple}, :atom, <<0xFF>>, [1 | 2], %{1 => 2}, ~D[2026-01-01]] do
        assert {:error, :invalid_descriptor} =
                 RecipeConfig.build(descriptor(Map.put(object(%{}), "examples", [nonplain])))
      end
    end

    test "settings size and depth limits are exact and nonplain values are refused" do
      checked = built(secret_schema() |> put_in(["properties", "tree"], %{}), ["key"])
      base = %{"note" => ""}
      pad = 65_536 - byte_size(Jason.encode!(base))
      at = %{"note" => String.duplicate("n", pad)}
      assert byte_size(Jason.encode!(at)) == 65_536
      exact(checked, at)

      over = %{"note" => String.duplicate("n", pad + 1)}
      assert {:error, :too_large} = RecipeConfig.check(checked, over)

      # Settings map is depth 1; nest(n, []) adds n + 1 containers.
      exact(checked, %{"tree" => nest(30, [])})
      assert {:error, :too_deep} = RecipeConfig.check(checked, %{"tree" => nest(31, [])})

      for nonplain <- [self(), {:tuple}, :atom, <<0xFF>>, [1 | 2], ~D[2026-01-01]] do
        assert {:error, :invalid_settings} = RecipeConfig.check(checked, %{"note" => nonplain})
      end

      assert {:error, :invalid_settings} = RecipeConfig.check(checked, %{note: "n"})
      assert {:error, :invalid_settings} = RecipeConfig.check(checked, %{<<0xFF>> => "n"})

      # Bounds first, then secret shape, then the schema.
      bad_secret = %{"key" => "raw-credential"}
      assert {:error, :too_large} = RecipeConfig.check(checked, Map.merge(over, bad_secret))

      assert {:error, :too_deep} =
               RecipeConfig.check(checked, Map.put(bad_secret, "tree", nest(31, [])))

      assert {:error, :invalid_settings} =
               RecipeConfig.check(checked, Map.put(bad_secret, "tree", self()))

      assert {:error, :invalid_secret} = RecipeConfig.check(checked, Map.put(bad_secret, "x", 1))
    end

    test "sentinels never appear in errors, logs or telemetry" do
      secret = "SECRET_SENTINEL"
      value = "VALUE_SENTINEL"
      key = "KEY/SENTINEL~"
      declared = "DECLARED/SENTINEL~"

      schema =
        object(%{"key" => @reference, declared => %{"type" => "integer"}}, [declared, "key"])

      {results, calls, logs} =
        observe(fn ->
          {:ok, checked} = RecipeConfig.build(descriptor(schema, ["key"]))
          # Test-only forged validator root, to induce an upstream validation fault.
          faulty = put_elem(checked, 4, put_elem(elem(checked, 4), 4, {:fault, secret, key}))

          [
            RecipeConfig.build(descriptor(object(%{declared => %{"pattern" => value <> "("}}))),
            RecipeConfig.build(descriptor(object(%{declared => %{"type" => value}}))),
            RecipeConfig.build(descriptor(object(%{declared => %{"$ref" => "urn:" <> value}}))),
            RecipeConfig.build(descriptor(schema, [key])),
            RecipeConfig.build(descriptor(schema, ["key"], %{"id" => String.duplicate(value, 10)})),
            RecipeConfig.check(checked, %{"key" => secret}),
            RecipeConfig.check(checked, %{"key" => %{"value" => secret}}),
            RecipeConfig.check(checked, %{"key" => ref(secret), declared => value}),
            RecipeConfig.check(checked, %{"key" => ref(secret), declared => 1, key => value}),
            RecipeConfig.check(checked, %{"key" => ref(secret)}),
            RecipeConfig.check(checked, %{"key" => ref(secret), declared => [value, self()]}),
            RecipeConfig.check(checked, %{key => String.duplicate(value, 7_000)}),
            RecipeConfig.check(faulty, %{"key" => ref(secret), declared => 1})
          ]
        end)

      assert Enum.all?(results, &match?({:error, reason} when is_atom(reason), &1))
      assert List.last(results) == {:error, :validation_failed}
      for sentinel <- [secret, value, key, declared], do: refute(inspect(results) =~ sentinel)
      assert calls == []
      assert logs == ""
    end
  end

  # Runs fun in a worker traced for telemetry and Secrets calls; returns the
  # result, those calls and captured logs.
  defp observe(fun) do
    parent = self()
    Code.ensure_loaded!(:telemetry)
    Code.ensure_loaded!(Elzoo.Secrets)
    patterns = [{:telemetry, :execute, 3}, {Elzoo.Secrets, :_, :_}]

    worker =
      spawn(fn ->
        receive do
          :run -> send(parent, {:result, fun.()})
        end

        receive do: (:stop -> :ok)
      end)

    for pattern <- patterns, do: :erlang.trace_pattern(pattern, true, [:local])
    :erlang.trace(worker, true, [:call])

    on_exit(fn ->
      send(worker, :stop)
      for pattern <- patterns, do: :erlang.trace_pattern(pattern, false, [:local])
    end)

    logs =
      capture_log(fn ->
        send(worker, :run)
        assert_receive {:result, result}, 5_000
        send(parent, {:observed, result})
      end)

    assert_receive {:observed, result}
    delivered = :erlang.trace_delivered(worker)
    assert_receive {:trace_delivered, ^worker, ^delivered}
    calls = collect_calls(worker)
    {result, calls, logs}
  end

  defp collect_calls(worker) do
    receive do
      {:trace, ^worker, :call, call} -> [call | collect_calls(worker)]
    after
      0 -> []
    end
  end
end
