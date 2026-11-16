# SPDX-License-Identifier: Apache-2.0
defmodule Elzoo.TriggerBindingTest.StructValue do
  defstruct [:tenant, :source]
end

defmodule Elzoo.TriggerBindingTest do
  use ExUnit.Case, async: true

  alias Elzoo.TriggerBinding

  @max_integer 9_223_372_036_854_775_807
  @target %{
    "bot_ref" => "bot:orders",
    "package_digest" => String.duplicate("a", 64),
    "callable" => "handle_order"
  }
  @declaration %{
    "version" => 1,
    "id" => "binding-1",
    "revision" => 7,
    "tenant" => "tenant-a",
    "source" => "webhook",
    "schema_id" => "order.created",
    "schema_version" => 2,
    "enabled" => true,
    "target" => @target
  }
  @scope %{tenant: "tenant-a", source: "webhook"}
  @event_schema %{"schema_id" => "order.created", "schema_version" => 2}

  test "validates an exact declaration unchanged" do
    assert {:ok, @declaration} = TriggerBinding.validate_declaration(@declaration)
  end

  test "rejects declaration versions and exact-shape violations" do
    invalid = [
      Map.delete(@declaration, "version"),
      Map.put(@declaration, "version", 1.0),
      Map.put(@declaration, "version", "1"),
      Map.put(@declaration, "version", 2),
      Map.put(@declaration, "unknown", "sentinel"),
      Map.delete(@declaration, "enabled"),
      Map.put(@declaration, :id, "binding-1"),
      struct(Elzoo.TriggerBindingTest.StructValue, tenant: "tenant-a", source: "webhook")
    ]

    for declaration <- invalid do
      assert {:error, :invalid_declaration} = TriggerBinding.validate_declaration(declaration)
    end
  end

  test "accepts bounded whitespace exactly and does not normalize it" do
    spaced =
      Map.merge(@declaration, %{
        "id" => " leading ",
        "tenant" => " ",
        "source" => " trailing ",
        "schema_id" => " order.created "
      })

    scope = %{tenant: " ", source: " trailing "}
    event = %{"schema_id" => " order.created ", "schema_version" => 2}

    assert {:ok, spaced} = TriggerBinding.validate_declaration(spaced)

    assert {:ok, %{id: " leading ", revision: 7, target: @target}} =
             TriggerBinding.select([spaced], scope, event)

    whitespace_only =
      Map.merge(spaced, %{
        "id" => " ",
        "tenant" => "\t",
        "source" => " ",
        "schema_id" => " ",
        "target" => Map.merge(@target, %{"bot_ref" => " ", "callable" => " "})
      })

    assert {:ok, _} = TriggerBinding.validate_declaration(whitespace_only)

    assert {:ok, %{id: " ", target: %{"bot_ref" => " ", "callable" => " "}}} =
             TriggerBinding.select(
               [whitespace_only],
               %{tenant: "\t", source: " "},
               %{"schema_id" => " ", "schema_version" => 2}
             )
  end

  test "whitespace mismatches remain byte-exact" do
    rows = [
      declaration(%{"id" => "tenant-space", "tenant" => "tenant-a "}),
      declaration(%{"id" => "source-space", "source" => "webhook "}),
      declaration(%{"id" => "schema-space", "schema_id" => "order.created "})
    ]

    assert {:ok, :no_match} = TriggerBinding.select(rows, @scope, @event_schema)
  end

  test "counts UTF-8 text bounds in bytes" do
    exact_limits =
      @declaration
      |> put_text("id", String.duplicate("é", 80))
      |> put_text("target.callable", String.duplicate("é", 64))

    assert {:ok, _} = TriggerBinding.validate_declaration(exact_limits)

    over_id = put_text(@declaration, "id", String.duplicate("é", 81))
    over_callable = put_text(@declaration, "target.callable", String.duplicate("é", 65))

    assert {:error, :invalid_declaration} = TriggerBinding.validate_declaration(over_id)
    assert {:error, :invalid_declaration} = TriggerBinding.validate_declaration(over_callable)
  end

  test "rejects empty, NUL, invalid UTF-8 and over-bound declaration text" do
    fields = ["id", "tenant", "source", "schema_id", "target.bot_ref", "target.callable"]

    for field <- fields, value <- ["", <<0, "x"::binary>>, <<255>>] do
      assert {:error, :invalid_declaration} =
               TriggerBinding.validate_declaration(put_text(@declaration, field, value))
    end

    for field <- fields do
      max_bytes = if field == "target.callable", do: 128, else: 160

      assert {:error, :invalid_declaration} =
               TriggerBinding.validate_declaration(
                 put_text(@declaration, field, String.duplicate("x", max_bytes + 1))
               )
    end
  end

  test "validates the signed integer bounds and boolean enabled field" do
    assert {:ok, _} =
             TriggerBinding.validate_declaration(
               Map.merge(@declaration, %{
                 "revision" => @max_integer,
                 "schema_version" => @max_integer
               })
             )

    for field <- ["revision", "schema_version"], value <- [0, -1, 1.0, @max_integer + 1] do
      assert {:error, :invalid_declaration} =
               TriggerBinding.validate_declaration(Map.put(@declaration, field, value))
    end

    for enabled <- [nil, 0, "true"] do
      assert {:error, :invalid_declaration} =
               TriggerBinding.validate_declaration(Map.put(@declaration, "enabled", enabled))
    end

    assert {:ok, _} = TriggerBinding.validate_declaration(Map.put(@declaration, "enabled", false))
  end

  test "requires an exact well-formed target and lowercase SHA-256 digest" do
    invalid_targets = [
      Map.delete(@target, "callable"),
      Map.put(@target, "extra", "sentinel"),
      Map.put(@target, "package_digest", String.upcase(@target["package_digest"])),
      Map.put(@target, "package_digest", String.duplicate("g", 64)),
      Map.put(@target, "package_digest", String.duplicate("a", 63)),
      Map.put(@target, "package_digest", 123),
      %{bot_ref: "bot", package_digest: @target["package_digest"], callable: "call"},
      :not_a_map,
      struct(Elzoo.TriggerBindingTest.StructValue, tenant: "bot", source: "call")
    ]

    for target <- invalid_targets do
      assert {:error, :invalid_declaration} =
               TriggerBinding.validate_declaration(Map.put(@declaration, "target", target))
    end
  end

  test "empty, zero, one and multiple matches have exact outcomes" do
    assert {:ok, :no_match} = TriggerBinding.select([], @scope, @event_schema)

    assert {:ok, :no_match} =
             TriggerBinding.select([declaration(%{"tenant" => "other"})], @scope, @event_schema)

    assert {:ok, %{id: "binding-1", revision: 7, target: @target} = selected} =
             TriggerBinding.select([@declaration], @scope, @event_schema)

    assert map_size(selected) == 3

    second = declaration(%{"id" => "binding-2", "revision" => 8})

    assert {:error, :ambiguous} =
             TriggerBinding.select([@declaration, second], @scope, @event_schema)
  end

  @tag :tenant_comparison
  test "a cross-tenant declaration is not selected" do
    cross_tenant = declaration(%{"id" => "cross-tenant", "tenant" => "tenant-b"})
    assert {:ok, :no_match} = TriggerBinding.select([cross_tenant], @scope, @event_schema)
  end

  test "disabled and cross-source or cross-schema rows do not match" do
    rows = [
      declaration(%{"id" => "disabled", "enabled" => false}),
      declaration(%{"id" => "source", "source" => "other"}),
      declaration(%{"id" => "schema", "schema_id" => "other.schema"}),
      declaration(%{"id" => "schema-version", "schema_version" => 3})
    ]

    assert {:ok, :no_match} = TriggerBinding.select(rows, @scope, @event_schema)
  end

  test "selects one exact row among unmatched rows and is permutation invariant" do
    rows = [
      @declaration,
      declaration(%{"id" => "other-tenant", "tenant" => "tenant-b"}),
      declaration(%{"id" => "other-source", "source" => "queue"})
    ]

    expected = {:ok, %{id: "binding-1", revision: 7, target: @target}}

    for permutation <- permutations(rows) do
      assert TriggerBinding.select(permutation, @scope, @event_schema) == expected
    end
  end

  test "no-match is permutation invariant" do
    rows = [
      declaration(%{"id" => "other-tenant", "tenant" => "tenant-b"}),
      declaration(%{"id" => "other-source", "source" => "queue"}),
      declaration(%{"id" => "disabled", "enabled" => false})
    ]

    for permutation <- permutations(rows) do
      assert TriggerBinding.select(permutation, @scope, @event_schema) == {:ok, :no_match}
    end
  end

  test "a selected target always comes from the exact scope and event match" do
    rows = [
      declaration(%{"id" => "tenant", "tenant" => "tenant-b", "target" => target("tenant")}),
      declaration(%{"id" => "source", "source" => "other", "target" => target("source")}),
      declaration(%{"id" => "schema", "schema_id" => "other", "target" => target("schema")}),
      declaration(%{"id" => "version", "schema_version" => 3, "target" => target("version")}),
      declaration(%{"id" => "exact", "target" => target("exact")})
    ]

    assert {:ok, %{id: "exact", target: %{"bot_ref" => "exact"}}} =
             TriggerBinding.select(rows, @scope, @event_schema)
  end

  @tag :ambiguity_refusal
  test "same-target matching declarations remain ambiguous" do
    second = declaration(%{"id" => "binding-2", "revision" => 8})
    assert second["target"] == @declaration["target"]

    for permutation <- permutations([second, @declaration]) do
      assert TriggerBinding.select(permutation, @scope, @event_schema) == {:error, :ambiguous}
    end
  end

  test "validates every row and rejects duplicate IDs before selection" do
    malformed = Map.put(@declaration, "unexpected", "sentinel")
    duplicate = declaration(%{"revision" => 8})

    assert {:error, :invalid_snapshot} =
             TriggerBinding.select([@declaration, duplicate, malformed], @scope, @event_schema)

    assert {:error, :duplicate_binding_id} =
             TriggerBinding.select([@declaration, duplicate], @scope, @event_schema)
  end

  test "duplicate IDs include disabled and nonmatching declarations" do
    disabled = declaration(%{"enabled" => false})
    nonmatching = declaration(%{"tenant" => "other", "source" => "queue"})

    for permutation <- permutations([disabled, nonmatching]) do
      assert TriggerBinding.select(permutation, @scope, @event_schema) ==
               {:error, :duplicate_binding_id}
    end
  end

  test "accepts 256 valid declarations and refuses 257 without truncation" do
    unmatched =
      for number <- 1..255 do
        declaration(%{"id" => "other-#{number}", "tenant" => "other"})
      end

    assert {:ok, %{id: "binding-1"}} =
             TriggerBinding.select([@declaration | unmatched], @scope, @event_schema)

    assert {:error, :invalid_snapshot} =
             TriggerBinding.select(
               [@declaration | List.duplicate(@declaration, 256)],
               @scope,
               @event_schema
             )
  end

  test "snapshot must be a proper list and scope errors take precedence" do
    assert {:error, :invalid_snapshot} = TriggerBinding.select(:not_a_list, @scope, @event_schema)

    assert {:error, :invalid_snapshot} =
             TriggerBinding.select([@declaration | :improper], @scope, @event_schema)

    assert {:error, :invalid_scope} =
             TriggerBinding.select(
               :not_a_list,
               %{tenant: "secret", source: "secret", extra: true},
               %{}
             )
  end

  test "host scope is an exact atom-keyed map with bounded text" do
    for scope <- [
          %{"tenant" => "tenant-a", "source" => "webhook"},
          %{tenant: "", source: "webhook"},
          %{tenant: "tenant-a", source: <<255>>},
          %{tenant: "tenant-a", source: String.duplicate("x", 161)},
          %{tenant: "tenant-a", source: "webhook", extra: true},
          struct(Elzoo.TriggerBindingTest.StructValue, tenant: "tenant-a", source: "webhook")
        ] do
      assert {:error, :invalid_scope} = TriggerBinding.select([], scope, @event_schema)
    end

    assert {:error, :invalid_scope} =
             TriggerBinding.select([], %{tenant: <<0>>, source: "webhook"}, @event_schema)
  end

  test "event schema is exact, string-keyed and bounded" do
    for event <- [
          %{schema_id: "order.created", schema_version: 2},
          %{"schema_id" => "", "schema_version" => 2},
          %{"schema_id" => <<255>>, "schema_version" => 2},
          %{"schema_id" => <<0>>, "schema_version" => 2},
          %{"schema_id" => "order.created", "schema_version" => 0},
          %{"schema_id" => "order.created", "schema_version" => 1.0},
          %{"schema_id" => "order.created", "schema_version" => @max_integer + 1},
          %{"schema_id" => "order.created", "schema_version" => 2, "extra" => true}
        ] do
      assert {:error, :invalid_event_schema} = TriggerBinding.select([], @scope, event)
    end

    assert {:error, :invalid_event_schema} =
             TriggerBinding.select(
               [],
               @scope,
               %{"schema_id" => String.duplicate("x", 161), "schema_version" => 2}
             )
  end

  test "refusal precedence is scope, event, list, declarations, duplicates and selection" do
    duplicate = declaration(%{"revision" => 8})
    malformed = Map.put(@declaration, "unknown", "sentinel")

    assert {:error, :invalid_scope} = TriggerBinding.select(:bad, :bad, :bad)
    assert {:error, :invalid_event_schema} = TriggerBinding.select(:bad, @scope, :bad)
    assert {:error, :invalid_snapshot} = TriggerBinding.select(:bad, @scope, @event_schema)

    for permutation <- permutations([@declaration, duplicate, malformed]) do
      assert TriggerBinding.select(permutation, @scope, @event_schema) ==
               {:error, :invalid_snapshot}
    end

    assert {:error, :duplicate_binding_id} =
             TriggerBinding.select([@declaration, duplicate], @scope, @event_schema)

    assert {:ok, :no_match} = TriggerBinding.select([], @scope, @event_schema)
  end

  defp declaration(overrides), do: Map.merge(@declaration, overrides)

  defp target(bot_ref), do: Map.put(@target, "bot_ref", bot_ref)

  defp put_text(declaration, "target." <> field, value) do
    Map.put(declaration, "target", Map.put(declaration["target"], field, value))
  end

  defp put_text(declaration, field, value), do: Map.put(declaration, field, value)

  defp permutations([]), do: [[]]

  defp permutations(list) do
    for {item, index} <- Enum.with_index(list),
        rest <- permutations(List.delete_at(list, index)) do
      [item | rest]
    end
  end
end
