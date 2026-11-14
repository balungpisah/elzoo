# SPDX-License-Identifier: Apache-2.0
typed = fn direction ->
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

package = %{
  "format_version" => 1,
  "name" => "example",
  "version" => "opaque-revision",
  "needs" => [],
  "permissions" => [],
  "skills" => [],
  "graph" => %{
    "version" => 1,
    "id" => "graph",
    "revision" => 1,
    "root" => "main",
    "callables" => [
      %{
        "name" => "main",
        "kind" => "graph",
        "input" => typed.("input"),
        "output" => typed.("output"),
        "nodes" => [],
        "links" => [],
        "input_slots" => []
      }
    ],
    "bindings" => [],
    "rules" => []
  },
  "settings" => %{
    "version" => 1,
    "id" => "independent-settings",
    "revision" => 1,
    "port" => typed.("input")["port"],
    "schema" => %{"type" => "object", "properties" => %{}, "additionalProperties" => false},
    "secrets" => []
  }
}

# The publisher computes a content digest; the host independently pins a trusted
# source. This example composes descriptors only; it runs no recipe or resolver.
canonical = fn recur, value ->
  cond do
    is_map(value) ->
      fields =
        for {key, child} <- Enum.sort(value), do: [Jason.encode!(key), ?:, recur.(recur, child)]

      [?{, Enum.intersperse(fields, ?,), ?}]

    is_list(value) ->
      [?[, Enum.intersperse(Enum.map(value, &recur.(recur, &1)), ?,), ?]]

    true ->
      Jason.encode!(value)
  end
end

identity =
  "recipe-package-v1:sha256:" <>
    Base.encode16(:crypto.hash(:sha256, canonical.(canonical, package)), case: :lower)

package = Map.put(package, "identity", identity)
{:ok, checked} = Elzoo.RecipePackage.decode(package)
^package = Elzoo.RecipePackage.encode(checked)
checked
