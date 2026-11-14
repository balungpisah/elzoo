# SPDX-License-Identifier: Apache-2.0
defmodule Elzoo.RecipeGraph do
  @moduledoc "Bounded, caller-held recipe declarations. No execution or authority."

  @max_version 2_147_483_647
  @outcomes ~w(completed failed refused late unknown out_of_budget retries_exhausted expired resource_lost)

  @doc "Check an exact v1 neutral map without repairing or normalizing it."
  def decode(map) do
    try do
      plain(map, 0, 0)
      exact(map, ~w(version id revision root callables bindings rules))
      require!(map["version"] === 1, :unsupported_version)
      identity(map["id"])
      version(map["revision"])
      identity(map["root"])
      bounded(map["callables"], 64, 1)
      bounded(map["bindings"], 64)
      bounded(map["rules"], 256)
      counts(map["callables"])
      unique(map["callables"], "name")
      unique(map["bindings"], "name")

      Enum.each(map["bindings"], fn binding ->
        exact(binding, ~w(name target))
        Enum.each(Map.values(binding), &identity/1)
      end)

      Enum.each(map["callables"], &declaration/1)
      callables = Map.new(map["callables"], &{&1["name"], &1})
      bindings = MapSet.new(map["bindings"], & &1["name"])
      require!(Map.has_key?(callables, map["root"]), :unknown_name)

      Enum.each(map["callables"], fn callable ->
        if callable["kind"] == "graph" do
          graph(callable, callables)
        else
          require!(MapSet.member?(bindings, callable["binding"]), :unknown_name)
        end
      end)

      refs = Map.new(map["callables"], &{&1["name"], references(&1)})

      acyclic(
        Map.keys(callables),
        for({name, targets} <- refs, target <- targets, do: {name, target})
      )

      Enum.reduce(Map.keys(callables), %{}, fn name, memo ->
        {_depth, memo} = nesting(name, refs, memo)
        memo
      end)

      rules(map["rules"], callables)
      {:ok, {:RecipeGraph, map}}
    catch
      {:recipe_error, reason} -> {:error, reason}
    end
  end

  @doc "Translate a checked value back to its original neutral map."
  def encode({:RecipeGraph, map}), do: map

  defp require!(true, _), do: :ok
  defp require!(_, reason), do: throw({:recipe_error, reason})

  defp exact(map, keys, reason \\ :invalid_shape) do
    require!(is_map(map) and not is_struct(map), reason)
    require!(Enum.sort(Map.keys(map)) == Enum.sort(keys), reason)
  end

  defp identity(value, reason \\ :invalid_shape),
    do: require!(is_binary(value) and byte_size(value) in 1..128 and String.valid?(value), reason)

  defp version(value, reason \\ :invalid_shape),
    do: require!(is_integer(value) and value in 1..@max_version, reason)

  defp bounded(list, max, min \\ 0) do
    count = list_length(list, 0)
    require!(count <= max, :too_large)
    require!(count >= min, :invalid_shape)
  end

  defp list_length([], count), do: count
  defp list_length([_ | tail], count), do: list_length(tail, count + 1)
  defp list_length(_, _), do: require!(false, :invalid_shape)

  defp unique(list, key, reason \\ :invalid_shape) do
    names =
      Enum.map(list, fn value ->
        require!(is_map(value), reason)
        name = value[key]
        identity(name, reason)
        name
      end)

    require!(length(Enum.uniq(names)) == length(names), reason)
  end

  defp plain(value, depth, bytes) when is_map(value) and not is_struct(value) do
    require!(depth < 32, :depth_exceeded)

    Enum.reduce(value, add(bytes, 2 + max(map_size(value) - 1, 0)), fn {key, child}, size ->
      require!(is_binary(key), :invalid_shape)
      plain(child, depth + 1, add(plain(key, depth + 1, size), 1))
    end)
  end

  defp plain(value, depth, bytes) when is_list(value) do
    require!(depth < 32, :depth_exceeded)
    Enum.reduce(value, add(bytes, 2 + max(list_length(value, 0) - 1, 0)), &plain(&1, depth + 1, &2))
  end

  defp plain(value, _, bytes) when is_binary(value) do
    require!(String.valid?(value), :invalid_shape)
    require!(byte_size(value) <= 1_048_576, :too_large)
    add(bytes, byte_size(Jason.encode!(value)))
  end

  defp plain(value, _, bytes) when is_number(value) or value in [true, false, nil] do
    case Jason.encode(value) do
      {:ok, json} -> add(bytes, byte_size(json))
      _ -> require!(false, :invalid_shape)
    end
  end

  defp plain(_, _, _), do: require!(false, :invalid_shape)

  defp add(bytes, count) do
    require!(bytes + count <= 1_048_576, :too_large)
    bytes + count
  end

  defp counts(callables) do
    {nodes, links} =
      Enum.reduce(callables, {0, 0}, fn callable, {nodes, links} ->
        require!(is_map(callable), :invalid_shape)

        if callable["kind"] == "graph" do
          bounded(callable["nodes"], 1_000)
          bounded(callable["links"], 10_000)
          bounded(callable["input_slots"], 64)

          Enum.each(callable["nodes"], fn node ->
            require!(is_map(node), :invalid_shape)
            bounded(node["needs"], 64)
            bounded(node["gives"], 64)
          end)

          {nodes + length(callable["nodes"]), links + length(callable["links"])}
        else
          {nodes, links}
        end
      end)

    require!(nodes <= 1_000 and links <= 10_000, :too_large)
  end

  defp declaration(callable) do
    extra =
      case callable["kind"] do
        "graph" -> ~w(nodes links input_slots)
        "agent" -> ~w(binding)
        "decision" -> ~w(binding choices)
        _ -> require!(false, :invalid_shape)
      end

    exact(callable, ~w(name kind input output) ++ extra)
    identity(callable["name"])

    Enum.each(~w(input output), fn direction ->
      value = callable[direction]
      exact(value, ~w(port schema), :invalid_schema)
      port = value["port"]
      exact(port, ~w(id direction schema_id schema_version), :invalid_schema)
      identity(port["id"], :invalid_schema)
      identity(port["schema_id"], :invalid_schema)
      version(port["schema_version"], :invalid_schema)
      require!(port["direction"] == direction, :invalid_schema)
      require!(match?({:ok, _}, Elzoo.PayloadSchema.build(port, value["schema"])), :invalid_schema)
    end)

    if callable["kind"] != "graph", do: identity(callable["binding"])

    if callable["kind"] == "decision" do
      bounded(callable["choices"], 64, 1)
      Enum.each(callable["choices"], &identity/1)
      require!(Enum.uniq(callable["choices"]) == callable["choices"], :invalid_branch)
    end
  end

  defp slots(slots) do
    bounded(slots, 64)
    unique(slots, "name")

    Enum.each(slots, fn slot ->
      exact(slot, ~w(name schema_id schema_version))
      identity(slot["schema_id"])
      version(slot["schema_version"])
    end)
  end

  defp node(node, callables) do
    extra =
      case node["kind"] do
        "ask" -> []
        "tool" -> ~w(tool)
        kind when kind in ~w(call decision) -> ~w(callable)
        kind when kind in ~w(map loop) -> ~w(callable max_iterations)
        _ -> require!(false, :invalid_shape)
      end

    exact(node, ~w(id kind needs gives) ++ extra)
    identity(node["id"])
    require!(node["id"] != "$input", :invalid_shape)
    slots(node["needs"])
    slots(node["gives"])
    if node["kind"] == "tool", do: identity(node["tool"])

    if "callable" in extra do
      identity(node["callable"])
      require!(Map.has_key?(callables, node["callable"]), :unknown_name)

      if node["kind"] == "decision",
        do: require!(callables[node["callable"]]["kind"] == "decision", :invalid_branch)
    end

    if "max_iterations" in extra,
      do:
        require!(
          is_integer(node["max_iterations"]) and node["max_iterations"] in 1..256,
          :invalid_shape
        )
  end

  defp graph(graph, callables) do
    slots(graph["input_slots"])
    unique(graph["nodes"], "id")
    Enum.each(graph["nodes"], &node(&1, callables))
    nodes = Map.new(graph["nodes"], &{&1["id"], &1})
    Enum.each(graph["links"], &link(&1, nodes, graph["input_slots"]))

    Enum.each(graph["nodes"], fn node ->
      Enum.each(node["needs"], fn need ->
        require!(
          Enum.count(
            graph["links"],
            &(&1["kind"] == "data" and &1["to"] == node["id"] and &1["need"] == need["name"])
          ) == 1,
          :missing_giver
        )
      end)

      if node["kind"] == "decision" do
        choices =
          for link <- graph["links"],
              link["kind"] == "choice" and link["from"] == node["id"],
              do: link["choice"]

        require!(
          Enum.sort(choices) == Enum.sort(callables[node["callable"]]["choices"]),
          :invalid_branch
        )
      end
    end)

    outcomes =
      for link <- graph["links"], link["kind"] == "outcome", do: {link["from"], link["outcome"]}

    require!(Enum.uniq(outcomes) == outcomes, :invalid_outcome)
    edges = for link <- graph["links"], link["from"] != "$input", do: {link["to"], link["from"]}
    acyclic(Map.keys(nodes), edges)
  end

  defp link(link, nodes, inputs) do
    require!(is_map(link), :invalid_shape)

    extra =
      case link["kind"] do
        "order" -> []
        "data" -> ~w(give need)
        "choice" -> ~w(choice)
        "outcome" -> ~w(outcome)
        _ -> require!(false, :invalid_shape)
      end

    exact(link, ~w(from to kind) ++ extra)
    Enum.each(~w(from to) ++ extra, &identity(link[&1]))
    require!(Map.has_key?(nodes, link["to"]), :unknown_name)
    input = link["from"] == "$input" and link["kind"] == "data"
    require!(input or Map.has_key?(nodes, link["from"]), :unknown_name)

    case link["kind"] do
      "data" ->
        gives = if input, do: inputs, else: nodes[link["from"]]["gives"]
        give = Enum.find(gives, &(&1["name"] == link["give"]))
        need = Enum.find(nodes[link["to"]]["needs"], &(&1["name"] == link["need"]))
        require!(give != nil and need != nil, :unknown_name)

        require!(
          Map.take(give, ~w(schema_id schema_version)) ==
            Map.take(need, ~w(schema_id schema_version)),
          :invalid_schema
        )

      "choice" ->
        require!(nodes[link["from"]]["kind"] == "decision", :invalid_branch)

      "outcome" ->
        require!(link["outcome"] in @outcomes, :invalid_outcome)

      _ ->
        :ok
    end
  end

  defp acyclic(names, edges) do
    graph = %{
      items: Enum.map(names, &%{id: &1, lifecycle: :open, deferred_until: nil}),
      externals: [],
      facts: [],
      edges: Enum.map(edges, fn {from, to} -> %{from: from, to: to, kind: :blocking} end)
    }

    case Elzoo.DependencyGraph.validate(graph) do
      {:ok, []} -> :ok
      {:ok, _} -> require!(false, :cycle)
      _ -> require!(false, :invalid_shape)
    end
  end

  defp references(%{"kind" => "graph", "nodes" => nodes}),
    do: for(node <- nodes, Map.has_key?(node, "callable"), do: node["callable"])

  defp references(_), do: []

  defp nesting(name, refs, memo) do
    case Map.fetch(memo, name) do
      {:ok, depth} ->
        {depth, memo}

      :error ->
        {depth, memo} =
          Enum.reduce(refs[name], {1, memo}, fn target, {depth, memo} ->
            {child, memo} = nesting(target, refs, memo)
            {max(depth, child + 1), memo}
          end)

        require!(depth <= 16, :depth_exceeded)
        {depth, Map.put(memo, name, depth)}
    end
  end

  defp rules(rules, callables) do
    Enum.each(rules, fn rule ->
      exact(rule, ~w(callable node policy requirement), :invalid_rule)
      identity(rule["callable"], :invalid_rule)
      identity(rule["node"], :invalid_rule)
      callable = callables[rule["callable"]]

      require!(
        callable != nil and callable["kind"] == "graph" and
          Enum.any?(callable["nodes"], &(&1["id"] == rule["node"])),
        :invalid_rule
      )

      policy = rule["policy"]
      exact(policy, ~w(id version content_hash), :invalid_rule)
      identity(policy["id"], :invalid_rule)
      version(policy["version"], :invalid_rule)

      require!(
        is_binary(policy["content_hash"]) and
          Regex.match?(~r/\A[0-9a-f]{64}\z/, policy["content_hash"]),
        :invalid_rule
      )

      requirement = rule["requirement"]
      exact(requirement, ~w(name version scope), :invalid_rule)
      identity(requirement["name"], :invalid_rule)
      version(requirement["version"], :invalid_rule)
      require!(requirement["scope"] in ~w(once run root), :invalid_rule)
    end)

    targets = Enum.map(rules, &{&1["callable"], &1["node"]})
    require!(Enum.uniq(targets) == targets, :invalid_rule)
  end
end
