# SPDX-License-Identifier: Apache-2.0
defmodule Elzoo.PayloadSchemaTest do
  use ExUnit.Case, async: false
  import ExUnit.CaptureLog
  alias Elzoo.PayloadSchema

  defmodule ReferenceTarget do
    def json_schema do
      send(self(), :schema_target_invoked)
      %{}
    end
  end

  defp port(overrides \\ %{}) do
    Map.merge(
      %{
        "id" => "argument",
        "direction" => "input",
        "schema_id" => "example/value",
        "schema_version" => 1
      },
      overrides
    )
  end

  test "declared types accept values and refuse wrong types without replacing integer floats" do
    for {type, valid, invalid} <- [
          {"string", "text", 1},
          {"number", 2.5, "2.5"},
          {"integer", 3, "3"},
          {"boolean", false, 0},
          {"null", nil, false},
          {"array", [1], %{}},
          {"object", %{"ok" => 1}, []}
        ] do
      assert {:ok, checked} = PayloadSchema.build(port(), %{"type" => type})
      assert :ok = PayloadSchema.check(checked, port(), valid)

      assert {:error, {:violations, [%{path: [], code: :schema_mismatch}]}} =
               PayloadSchema.check(checked, port(), invalid)
    end

    assert {:ok, checked} = PayloadSchema.build(port(), %{"type" => "integer"})
    payload = 3.0
    assert :ok = PayloadSchema.check(checked, port(), payload)
    assert payload === 3.0
    assert {:ok, string} = PayloadSchema.build(port(), %{"type" => "string"})
    assert :ok = PayloadSchema.check(string, port(), "{\"not\":\"parsed\"}")
  end

  test "malformed Ports schemas and payload representations return fixed errors" do
    assert {:ok, checked} = PayloadSchema.build(port(), %{})

    for invalid <- [
          nil,
          %{},
          Map.put(port(), "extra", true),
          port(%{"schema_version" => 0}),
          port(%{"direction" => "sideways"})
        ] do
      assert {:error, :invalid_port} = PayloadSchema.build(invalid, %{})
      assert {:error, :invalid_port} = PayloadSchema.check(checked, invalid, self())
    end

    for invalid <- [
          nil,
          true,
          [],
          "{}",
          ReferenceTarget,
          %JSV.Schema{},
          %{type: "string"},
          %{"type" => "not-a-type"},
          %{"const" => self()},
          %{"const" => [1 | nil]},
          %{"$schema" => "http://json-schema.org/draft-07/schema#"}
        ] do
      assert {:error, :invalid_schema} = PayloadSchema.build(port(), invalid)
    end

    for invalid <- [
          :atom,
          self(),
          fn -> :ok end,
          {:tuple},
          %{atom: 1},
          %URI{},
          <<255>>,
          %{"bad" => <<255>>},
          %{<<255>> => 1},
          [1 | :tail]
        ] do
      assert {:error, :invalid_payload} = PayloadSchema.check(checked, port(), invalid)
    end
  end

  test "local references work and external module and dynamic references cannot invoke a target" do
    schema = %{"$defs" => %{"count" => %{"type" => "integer"}}, "$ref" => "#/$defs/count"}
    assert {:ok, checked} = PayloadSchema.build(port(), schema)
    assert :ok = PayloadSchema.check(checked, port(), 4)
    assert {:error, {:violations, _}} = PayloadSchema.check(checked, port(), "4")

    for key <- ["$ref", "$dynamicRef"],
        ref <- ["https://example.invalid/schema", "jsv:module:#{ReferenceTarget}", 1] do
      assert {:error, :invalid_schema} = PayloadSchema.build(port(), %{key => ref})
      assert {:error, :invalid_schema} = PayloadSchema.build(port(), %{"const" => [%{key => ref}]})
    end

    assert {:error, :invalid_schema} = PayloadSchema.build(port(), ReferenceTarget)
    refute_received :schema_target_invoked

    assert {:ok, _} =
             PayloadSchema.build(port(), %{
               "$schema" => "https://json-schema.org/draft/2020-12/schema"
             })
  end

  test "unknown fields follow the schema and neither defaults nor coercions replace the object" do
    schema = %{
      "type" => "object",
      "properties" => %{"count" => %{"type" => "integer", "default" => 9}}
    }

    payload = %{"extra" => "retained"}
    assert {:ok, allowed} = PayloadSchema.build(port(), schema)
    assert :ok = PayloadSchema.check(allowed, port(), payload)
    assert payload === %{"extra" => "retained"}

    assert {:ok, closed} =
             PayloadSchema.build(port(), Map.put(schema, "additionalProperties", false))

    assert {:error, {:violations, _}} = PayloadSchema.check(closed, port(), payload)
    assert payload === %{"extra" => "retained"}
    assert {:error, {:violations, _}} = PayloadSchema.check(allowed, port(), %{"count" => "3"})
  end

  test "compact byte and container depth boundaries precede JSV validation" do
    assert {:ok, any} = PayloadSchema.build(port(), %{})
    assert {:ok, wrong_type} = PayloadSchema.build(port(), %{"type" => "boolean"})
    at_limit = String.duplicate("a", 65_534)
    over_limit = at_limit <> "a"
    assert byte_size(Jason.encode!(at_limit)) == 65_536
    assert byte_size(Jason.encode!(over_limit)) == 65_537
    assert :ok = PayloadSchema.check(any, port(), at_limit)
    assert {:error, :too_large} = PayloadSchema.check(wrong_type, port(), over_limit)
    # Escapes and multibyte strings use Jason's byte count, not character count.
    assert {:error, :too_large} = PayloadSchema.check(any, port(), String.duplicate("\n", 32_768))
    assert {:error, :too_large} = PayloadSchema.check(any, port(), String.duplicate("é", 32_768))

    for wrap <- [fn child -> [child] end, fn child -> %{"child" => child} end] do
      depth32 = Enum.reduce(1..32, nil, fn _, child -> wrap.(child) end)
      assert :ok = PayloadSchema.check(any, port(), depth32)
      assert {:error, :too_deep} = PayloadSchema.check(wrong_type, port(), wrap.(depth32))
      # The rejected 33rd container is not traversed, even with invalid contents.
      invalid33 = Enum.reduce(1..33, self(), fn _, child -> wrap.(child) end)
      assert {:error, :too_deep} = PayloadSchema.check(any, port(), invalid33)
    end
  end

  test "violations stay bounded and retain array positions in redacted nested paths" do
    assert {:ok, checked} =
             PayloadSchema.build(port(), %{"type" => "array", "items" => %{"type" => "integer"}})

    assert {:error, {:violations, violations}} =
             PayloadSchema.check(checked, port(), List.duplicate("wrong", 20))

    assert length(violations) in 1..16

    assert Enum.all?(violations, fn %{path: path, code: :schema_mismatch} = violation ->
             map_size(violation) == 2 and
               case path do
                 [] -> true
                 [index] -> is_integer(index) and index in 0..19
                 _ -> false
               end
           end)

    assert Enum.any?(violations, &match?(%{path: [_]}, &1))

    schema = %{
      "properties" => %{
        "rows" => %{"items" => %{"properties" => %{"secret" => %{"type" => "integer"}}}}
      }
    }

    assert {:ok, checked} = PayloadSchema.build(port(), schema)

    assert {:error, {:violations, nested}} =
             PayloadSchema.check(checked, port(), %{"rows" => [%{"secret" => "wrong"}]})

    assert %{path: [:key, 0, :key], code: :schema_mismatch} in nested

    {deep_schema, deep_payload} =
      Enum.reduce(1..32, {%{"type" => "integer"}, "wrong"}, fn _, {s, p} ->
        {%{"items" => s}, [p]}
      end)

    assert {:ok, checked} = PayloadSchema.build(port(), deep_schema)

    assert {:error, {:violations, deep}} =
             PayloadSchema.check(checked, port(), deep_payload)

    assert Enum.all?(deep, &(length(&1.path) <= 32))
    assert %{path: List.duplicate(0, 32), code: :schema_mismatch} in deep
  end

  test "version direction and schema mismatches precede payload inspection but local IDs do not bind" do
    assert {:ok, checked} = PayloadSchema.build(port(), %{"type" => "integer"})
    assert :ok = PayloadSchema.check(checked, port(%{"id" => "another"}), 1)

    assert {:error, :version_mismatch} =
             PayloadSchema.check(checked, port(%{"schema_version" => 2}), 1)

    assert {:error, :version_mismatch} =
             PayloadSchema.check(checked, port(%{"schema_version" => 2}), self())

    for change <- [
          %{"schema_id" => "other"},
          %{"direction" => "output"},
          %{"direction" => "output", "schema_version" => 2}
        ] do
      assert {:error, :port_mismatch} = PayloadSchema.check(checked, port(change), self())
    end
  end

  test "redaction hides value dynamic and declared key sentinels with no logs or telemetry" do
    value = "VALUE_SENTINEL"
    dynamic = "DYNAMIC/SENTINEL~"
    declared = "DECLARED/SENTINEL~"

    schema = %{
      "type" => "object",
      "required" => [declared],
      "additionalProperties" => false,
      "properties" => %{
        declared => %{
          "type" => "array",
          "items" => %{"properties" => %{dynamic => %{"type" => "integer"}}}
        }
      }
    }

    parent = self()
    Code.ensure_loaded!(:telemetry)

    worker =
      spawn(fn ->
        receive do
          :run ->
            {:ok, checked} = PayloadSchema.build(port(), schema)

            results =
              for payload <- [%{dynamic => value}, %{}, %{declared => [%{dynamic => value}]}] do
                PayloadSchema.check(checked, port(), payload)
              end

            send(parent, {:results, results})
        end

        receive do: (:stop -> :ok)
      end)

    :erlang.trace_pattern({:telemetry, :execute, 3}, true, [:local])
    :erlang.trace(worker, true, [:call])

    on_exit(fn ->
      send(worker, :stop)
      :erlang.trace_pattern({:telemetry, :execute, 3}, false, [:local])
    end)

    logs =
      capture_log(fn ->
        send(worker, :run)
        assert_receive {:results, results}, 1_000
        assert Enum.all?(results, &match?({:error, {:violations, [_ | _]}}, &1))
        for sentinel <- [value, dynamic, declared], do: refute(inspect(results) =~ sentinel)

        {:error, {:violations, nested}} = List.last(results)
        assert %{path: [:key, 0, :key], code: :schema_mismatch} in nested
      end)

    delivered = :erlang.trace_delivered(worker)
    assert_receive {:trace_delivered, ^worker, ^delivered}
    refute_received {:trace, ^worker, :call, {:telemetry, :execute, _}}
    assert logs == ""
  end

  test "pinned validator fit cases and integer controls have the documented divergence" do
    cases = [
      {%{"type" => "integer"}, 3, :ok, :ok},
      {%{"type" => "integer"}, "3", :invalid, :invalid},
      {%{"$schema" => "https://json-schema.org/draft/2020-12/schema", "type" => "object"}, %{}, :ok,
       :unsupported},
      {%{
         "type" => "object",
         "properties" => %{"ok" => %{"type" => "integer"}},
         "unevaluatedProperties" => false
       }, %{"ok" => 1, "extra" => 2}, :invalid, :ok},
      {%{"type" => "array", "prefixItems" => [%{"type" => "integer"}]}, ["wrong"], :invalid, :ok},
      {%{"type" => "string", "format" => "email"}, "not-an-email", :ok, :invalid},
      {%{"$id" => "urn:example:payload", "type" => "object"}, %{}, :ok, :ok}
    ]

    for {schema, payload, jsv, ex} <- cases do
      assert {:ok, root} =
               JSV.build(schema, resolver: [], formats: false, atoms: false, warnings: :silence)

      result = JSV.validate(payload, root, cast: false)
      assert if(match?({:ok, _}, result), do: :ok, else: :invalid) == jsv

      if ex == :unsupported do
        assert_raise ExJsonSchema.Schema.UnsupportedSchemaVersionError, fn ->
          ExJsonSchema.Schema.resolve(schema)
        end
      else
        result = ExJsonSchema.Validator.validate(ExJsonSchema.Schema.resolve(schema), payload)
        assert if(result == :ok, do: :ok, else: :invalid) == ex
      end
    end

    root =
      JSV.build!(%{"type" => "integer"},
        resolver: [],
        formats: false,
        atoms: false,
        warnings: :silence
      )

    assert {:ok, 3} = JSV.validate(3.0, root, cast: false)

    assert :ok =
             ExJsonSchema.Validator.validate(
               ExJsonSchema.Schema.resolve(%{"type" => "integer"}),
               3.0
             )
  end

  test "checked example shares the checking API across four boundary roles" do
    {results, _} = Code.eval_file(Path.expand("../../examples/elzoo/payload_schema.exs", __DIR__))

    assert results == %{
             module_function: :ok,
             recipe_node: :ok,
             tool_argument: :ok,
             model_output: :ok
           }
  end
end
