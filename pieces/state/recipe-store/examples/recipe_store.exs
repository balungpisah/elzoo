# SPDX-License-Identifier: Apache-2.0
# The public API of Elzoo.RecipeStore on the Memory Store. The host binds
# `object_store`, an `%Elzoo.ObjectStore.Config{}` whose credential is its own
# injected Need; the bytes of each version are an artifact there.
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

package = fn version ->
  %{
    "format_version" => 1,
    "name" => "weekly-report",
    "version" => version,
    "needs" => ["search-index"],
    "permissions" => ["read-docs"],
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
          "input_slots" => [],
          "nodes" => [
            %{
              "id" => "fetch",
              "kind" => "tool",
              "tool" => "listing_search",
              "needs" => [],
              "gives" => []
            }
          ],
          "links" => []
        }
      ],
      "bindings" => [],
      "rules" => []
    },
    "settings" => %{
      "version" => 1,
      "id" => "settings",
      "revision" => 1,
      "port" => typed.("input")["port"],
      "secrets" => [],
      "schema" => %{"type" => "object", "properties" => %{}, "additionalProperties" => false}
    }
  }
  |> then(fn map ->
    digest = :crypto.hash(:sha256, IO.iodata_to_binary(canonical.(canonical, map)))
    Map.put(map, "identity", "recipe-package-v1:sha256:" <> Base.encode16(digest, case: :lower))
  end)
end

{:ok, tools} =
  Elzoo.ToolRegistry.snapshot([
    %{
      "id" => "listing",
      "kind" => "host_listing",
      "callable" => "adapter",
      "tools" => [
        %{
          "trust" => "untrusted",
          "name" => "search",
          "description" => "Search documents",
          "input_schema" => %{"type" => "object"},
          "annotations" => nil
        }
      ]
    }
  ])

facts = %{
  "tools" => tools,
  "provided_needs" => ["search-index"],
  "granted_permissions" => ["read-docs"],
  "tool_requirements" => %{
    "listing_search" => %{"needs" => ["search-index"], "permissions" => ["read-docs"]}
  },
  "unit" => "token",
  "costs" => [%{"callable" => "main", "node" => "fetch", "estimate" => 40}],
  "cap" => 100
}

# The host's fold carries the kinds of both Pieces; the Store is the Memory double.
fold = %{
  initial: 0,
  kinds: Map.merge(Elzoo.Artifact.kinds(), Elzoo.RecipeStore.kinds()),
  versions: [1],
  destinations: [],
  reduce: fn n, _row, _sequence, _revision -> n + 1 end
}

limits = %{max_record_bytes: 8_192, max_batch_size: 4, max_checkpoint_bytes: 10_000}
{:ok, memory} = Elzoo.DurableLog.Memory.start_link(fold: fold, limits: limits)
store = Elzoo.DurableLog.Memory.store(memory)

{:ok, artifact} = Elzoo.Artifact.new(store: store, object_store: object_store)
{:ok, recipes} = Elzoo.RecipeStore.new(artifact: artifact, log: store)

# The host verified the tenant of the caller.
caller = %{tenant: "example-tenant", principal: "publisher", scopes: []}

v1 = package.("1")
v2 = package.("2")

{:ok, id1} = Elzoo.RecipeStore.put(recipes, caller, v1)
{:ok, ^id1} = Elzoo.RecipeStore.put(recipes, caller, v1)
{:ok, ^v1} = Elzoo.RecipeStore.get(recipes, caller, id1)
{:ok, id2} = Elzoo.RecipeStore.put(recipes, caller, v2)

# Only a checked version is published; a refused check records nothing.
{:error, :not_checked} = Elzoo.RecipeStore.publish(recipes, caller, id1)

{:refused, _} =
  Elzoo.RecipeStore.check(recipes, caller, id1, %{facts | "granted_permissions" => []})

{:ok, %{identity: ^id1, upper_cost: 40}} = Elzoo.RecipeStore.check(recipes, caller, id1, facts)
{:ok, %{identity: ^id2}} = Elzoo.RecipeStore.check(recipes, caller, id2, facts)

{:ok, %{published: ^id1, previous: nil}} = Elzoo.RecipeStore.publish(recipes, caller, id1)
{:ok, %{published: ^id2, previous: ^id1}} = Elzoo.RecipeStore.publish(recipes, caller, id2)
# Go back: publish an older version again.
{:ok, %{published: ^id1, previous: ^id2}} = Elzoo.RecipeStore.publish(recipes, caller, id1)
{:ok, ^id1} = Elzoo.RecipeStore.published(recipes, caller)

# A live Run pins the version it uses; a pinned or published version is not deleted.
{:ok, :pinned} = Elzoo.RecipeStore.pin(recipes, caller, id2, "run-1")
{:error, :pinned} = Elzoo.RecipeStore.delete(recipes, caller, id2)
{:error, :published} = Elzoo.RecipeStore.delete(recipes, caller, id1)
{:ok, :unpinned} = Elzoo.RecipeStore.unpin(recipes, caller, id2, "run-1")
{:ok, :deleted} = Elzoo.RecipeStore.delete(recipes, caller, id2)
{:error, :deleted} = Elzoo.RecipeStore.get(recipes, caller, id2)

{:ok,
 [
   %{identity: ^id1, checked: true, pins: 0, published: true, deleted: false},
   %{identity: ^id2, checked: true, pins: 0, published: false, deleted: true}
 ]} = Elzoo.RecipeStore.versions(recipes, caller)

# The published version stays: a delete is refused until another version is published.
:ok
