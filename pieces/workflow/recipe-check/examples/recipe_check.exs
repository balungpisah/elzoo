# SPDX-License-Identifier: Apache-2.0
typed = fn direction ->
  %{
    "port" => %{
      "id" => direction,
      "direction" => direction,
      "schema_id" => "item",
      "schema_version" => 1
    },
    "schema" => %{"type" => "object"}
  }
end

recipe = %{
  "version" => 1,
  "id" => "weekly-report",
  "revision" => 1,
  "root" => "main",
  "callables" => [
    %{
      "name" => "main",
      "kind" => "graph",
      "input" => typed.("input"),
      "output" => typed.("output"),
      "input_slots" => [],
      "nodes" => [
        %{
          "id" => "fetch",
          "kind" => "tool",
          "tool" => "listing_search",
          "needs" => [],
          "gives" => []
        },
        %{"id" => "review", "kind" => "ask", "needs" => [], "gives" => []}
      ],
      "links" => []
    }
  ],
  "bindings" => [],
  "rules" => []
}

settings = %{
  "version" => 1,
  "id" => "report-settings",
  "revision" => 1,
  "port" => typed.("input")["port"],
  "secrets" => [],
  "schema" => %{"type" => "object", "properties" => %{}, "additionalProperties" => false}
}

# The package identity is the SHA-256 of the canonical JSON of the package without it.
canonical = fn canonical, value ->
  cond do
    is_map(value) ->
      members =
        for {key, child} <- Enum.sort(value),
            do: [Jason.encode!(key), ":", canonical.(canonical, child)]

      ["{", Enum.intersperse(members, ","), "}"]

    is_list(value) ->
      ["[", Enum.intersperse(Enum.map(value, &canonical.(canonical, &1)), ","), "]"]

    true ->
      Jason.encode!(value)
  end
end

package =
  %{
    "format_version" => 1,
    "name" => "weekly-report",
    "version" => "1",
    "needs" => ["search-index"],
    "permissions" => ["read-docs"],
    "graph" => recipe,
    "settings" => settings,
    "skills" => []
  }
  |> then(fn map ->
    digest = :crypto.hash(:sha256, IO.iodata_to_binary(canonical.(canonical, map)))
    Map.put(map, "identity", "recipe-package-v1:sha256:" <> Base.encode16(digest, case: :lower))
  end)

tool = %{
  "trust" => "untrusted",
  "name" => "search",
  "description" => "Search documents",
  "input_schema" => %{"type" => "object"},
  "annotations" => nil
}

{:ok, tools} =
  Elzoo.ToolRegistry.snapshot([
    %{"id" => "listing", "kind" => "host_listing", "callable" => "adapter", "tools" => [tool]}
  ])

facts = %{
  "tools" => tools,
  "provided_needs" => ["search-index"],
  "granted_permissions" => ["read-docs"],
  "tool_requirements" => %{
    "listing_search" => %{"needs" => ["search-index"], "permissions" => ["read-docs"]}
  },
  "unit" => "token",
  "costs" => [
    %{"callable" => "main", "node" => "fetch", "estimate" => 40},
    %{"callable" => "main", "node" => "review", "estimate" => 2}
  ],
  "cap" => 100
}

# One run of the root costs at most 40 + 2 in "token", within the cap of 100.
identity = package["identity"]

{:ok, %{identity: ^identity, unit: "token", upper_cost: 42}} =
  Elzoo.RecipeCheck.check(package, facts)

# The tenant did not grant the permission that the package declares.
{:refused, [%{path: ["permissions", 0], code: :permission_not_granted}]} =
  Elzoo.RecipeCheck.check(package, %{facts | "granted_permissions" => []})

# The same recipe outside a package: the host states what it declares.
declared = %{"needs" => ["search-index"], "permissions" => ["read-docs"]}

{:ok, %{identity: {"weekly-report", 1, 1}, unit: "token", upper_cost: 42}} =
  Elzoo.RecipeCheck.check_graph(recipe, declared, facts)

{:refused, [%{path: [], code: :over_cap}]} =
  Elzoo.RecipeCheck.check_graph(recipe, declared, %{facts | "cap" => 41})

:ok
