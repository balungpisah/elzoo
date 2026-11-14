# SPDX-License-Identifier: Apache-2.0
defmodule Elzoo.RecipeCheck do
  @moduledoc """
  Pure load-time check of a recipe package, or of a recipe that is not in a package,
  against caller-supplied facts. Compares and sums; grants, reserves and executes nothing.
  """

  @fact_keys Enum.sort(
               ~w(tools provided_needs granted_permissions tool_requirements unit costs cap)
             )
  @declared_keys Enum.sort(~w(needs permissions))
  @requirement_keys Enum.sort(~w(needs permissions))
  @node_cost_keys Enum.sort(~w(callable node estimate))
  @callable_cost_keys Enum.sort(~w(callable estimate))
  @max_estimate 9_007_199_254_740_992
  @max_cap 9_223_372_036_854_775_807

  @doc "Check a neutral recipe package against the facts; `{:ok, verdict}`, `{:refused, reasons}` or `{:error, :invalid_facts}`."
  def check(package, facts) do
    if facts?(facts) do
      case Elzoo.RecipePackage.decode(package) do
        {:ok, _checked} -> package_stage_two(package, facts)
        {:error, :invalid_graph} -> {:refused, [graph_reason(package["graph"])]}
        {:error, reason} -> {:refused, [%{path: location(reason), code: reason}]}
      end
    else
      {:error, :invalid_facts}
    end
  end

  @doc "As `check/2` for a neutral recipe and its `declared` needs and permissions."
  def check_graph(recipe, declared, facts) do
    if facts?(facts) and declared?(declared) do
      case Elzoo.RecipeGraph.decode(recipe) do
        {:ok, checked} ->
          recipe = Elzoo.RecipeGraph.encode(checked)
          identity = {recipe["id"], recipe["revision"], recipe["version"]}
          verdict(stage_two(recipe, declared, facts), identity, facts)

        {:error, reason} ->
          {:refused, [%{path: [], code: reason}]}
      end
    else
      {:error, :invalid_facts}
    end
  end

  defp package_stage_two(package, facts) do
    declared = %{"needs" => package["needs"], "permissions" => package["permissions"]}

    case stage_two(package["graph"], declared, facts) do
      {:ok, cost} ->
        verdict({:ok, cost}, package["identity"], facts)

      {:refused, reasons} ->
        {:refused, sort(Enum.map(reasons, &update_in(&1.path, fn path -> into_package(path) end)))}
    end
  end

  defp verdict({:ok, cost}, identity, facts),
    do: {:ok, %{identity: identity, unit: facts["unit"], upper_cost: cost}}

  defp verdict({:refused, reasons}, _identity, _facts), do: {:refused, reasons}

  defp location(:invalid_settings_descriptor), do: ["settings"]
  defp location(:invalid_skill), do: ["skills"]
  defp location(_reason), do: []

  # A package fault that RecipePackage reports as :invalid_graph keeps that atom when the
  # member alone decodes (its own encode check or a package-level cap saw it first).
  defp graph_reason(graph) do
    case Elzoo.RecipeGraph.decode(graph) do
      {:error, reason} -> %{path: ["graph"], code: reason}
      {:ok, _} -> %{path: ["graph"], code: :invalid_graph}
    end
  end

  defp into_package([]), do: ["graph"]
  defp into_package(["callables" | _] = path), do: ["graph" | path]
  defp into_package(path), do: path

  defp sort(reasons), do: reasons |> Enum.uniq() |> Enum.sort_by(&{&1.path, &1.code})

  # Stage 2. Paths are relative to the recipe; declared paths point into `declared`.
  defp stage_two(recipe, declared, facts) do
    context = %{
      tools: facts["tools"],
      requirements: facts["tool_requirements"],
      needs: MapSet.new(declared["needs"]),
      permissions: MapSet.new(declared["permissions"]),
      costs: Map.new(facts["costs"], &{target(&1), &1["estimate"]})
    }

    callables = recipe["callables"]

    local =
      for {callable, index} <- Enum.with_index(callables),
          reason <- callable_reasons(callable, index, context),
          do: reason

    declared_reasons =
      missing(declared["needs"], facts["provided_needs"], "needs", :need_not_provided) ++
        missing(
          declared["permissions"],
          facts["granted_permissions"],
          "permissions",
          :permission_not_granted
        )

    missing_cost? = Enum.any?(local, &(&1.code == :missing_cost))

    unknown =
      if unknown_target?(callables, context.costs),
        do: [%{path: [], code: :unknown_cost_target}],
        else: []

    {cost, over} =
      if missing_cost? do
        {nil, []}
      else
        cost = upper_cost(recipe, context.costs)

        {cost, if(cost > facts["cap"], do: [%{path: [], code: :over_cap}], else: [])}
      end

    case sort(local ++ declared_reasons ++ unknown ++ over) do
      [] -> {:ok, cost}
      reasons -> {:refused, reasons}
    end
  end

  defp target(%{"callable" => callable, "node" => node}), do: {callable, node}
  defp target(%{"callable" => callable}), do: {callable}

  defp missing(declared, available, key, code) do
    held = MapSet.new(available)

    for {text, index} <- Enum.with_index(declared),
        not MapSet.member?(held, text),
        do: %{path: [key, index], code: code}
  end

  defp callable_reasons(%{"kind" => "graph", "name" => name, "nodes" => nodes}, index, context) do
    for {node, node_index} <- Enum.with_index(nodes),
        reason <- node_reasons(name, node, ["callables", index, "nodes", node_index], context),
        do: reason
  end

  defp callable_reasons(%{"name" => name}, index, context) do
    if Map.has_key?(context.costs, {name}),
      do: [],
      else: [%{path: ["callables", index], code: :missing_cost}]
  end

  defp node_reasons(callable, %{"kind" => "tool", "tool" => tool} = node, path, context),
    do: tool_reasons(tool, path, context) ++ node_cost_reasons(callable, node, path, context)

  defp node_reasons(callable, %{"kind" => "ask"} = node, path, context),
    do: node_cost_reasons(callable, node, path, context)

  defp node_reasons(_callable, _node, _path, _context), do: []

  defp tool_reasons(tool, path, context) do
    resolved? = match?({:resolved, _}, Elzoo.ToolRegistry.resolve(context.tools, tool))
    required = Map.get(context.requirements, tool, %{"needs" => [], "permissions" => []})

    [
      {not resolved?, :unknown_tool},
      {not subset?(required["needs"], context.needs), :need_not_declared},
      {not subset?(required["permissions"], context.permissions), :permission_not_declared}
    ]
    |> Enum.filter(&elem(&1, 0))
    |> Enum.map(&%{path: path, code: elem(&1, 1)})
  end

  defp subset?(required, declared), do: Enum.all?(required, &MapSet.member?(declared, &1))

  defp node_cost_reasons(callable, %{"id" => id}, path, context) do
    if Map.has_key?(context.costs, {callable, id}),
      do: [],
      else: [%{path: path, code: :missing_cost}]
  end

  defp unknown_target?(callables, costs) do
    valid =
      MapSet.new(
        Enum.flat_map(callables, fn
          %{"kind" => "graph", "name" => name, "nodes" => nodes} ->
            for %{"kind" => kind, "id" => id} <- nodes, kind in ["tool", "ask"], do: {name, id}

          %{"name" => name} ->
            [{name}]
        end)
      )

    Enum.any?(Map.keys(costs), &(not MapSet.member?(valid, &1)))
  end

  # Exact integers. The recipe is acyclic (RecipeGraph.decode refused cycles), so the
  # recursion ends; each callable is summed once.
  defp upper_cost(recipe, costs) do
    by_name = Map.new(recipe["callables"], &{&1["name"], &1})
    {cost, _memo} = callable_cost(recipe["root"], by_name, costs, %{})
    cost
  end

  defp callable_cost(name, by_name, costs, memo) do
    case memo do
      %{^name => cost} ->
        {cost, memo}

      _ ->
        {cost, memo} = own_cost(Map.fetch!(by_name, name), by_name, costs, memo)
        {cost, Map.put(memo, name, cost)}
    end
  end

  defp own_cost(%{"kind" => "graph", "name" => name, "nodes" => nodes}, by_name, costs, memo) do
    Enum.reduce(nodes, {0, memo}, fn node, {sum, memo} ->
      {cost, memo} = node_cost(name, node, by_name, costs, memo)
      {sum + cost, memo}
    end)
  end

  defp own_cost(%{"name" => name}, _by_name, costs, memo), do: {Map.fetch!(costs, {name}), memo}

  defp node_cost(callable, %{"kind" => kind, "id" => id}, _by_name, costs, memo)
       when kind in ["tool", "ask"],
       do: {Map.fetch!(costs, {callable, id}), memo}

  defp node_cost(_callable, %{"kind" => kind, "callable" => name}, by_name, costs, memo)
       when kind in ["call", "decision"],
       do: callable_cost(name, by_name, costs, memo)

  defp node_cost(
         _callable,
         %{"kind" => kind, "callable" => name, "max_iterations" => times},
         by_name,
         costs,
         memo
       )
       when kind in ["map", "loop"] do
    {cost, memo} = callable_cost(name, by_name, costs, memo)
    {times * cost, memo}
  end

  # Facts and declared: shape and bounds, each bound checked before its list or map is walked.
  defp facts?(facts) do
    plain_map?(facts) and keys?(facts, @fact_keys) and tools?(facts["tools"]) and
      texts?(facts["provided_needs"], 256) and texts?(facts["granted_permissions"], 256) and
      requirements?(facts["tool_requirements"]) and text?(facts["unit"]) and
      costs?(facts["costs"]) and is_integer(facts["cap"]) and facts["cap"] in 1..@max_cap
  end

  defp declared?(declared) do
    plain_map?(declared) and keys?(declared, @declared_keys) and texts?(declared["needs"], 64) and
      texts?(declared["permissions"], 64)
  end

  defp tools?({:ToolRegistry, sources, entries, removed}),
    do: is_list(sources) and plain_map?(entries) and plain_map?(removed)

  defp tools?(_), do: false

  defp requirements?(requirements) do
    plain_map?(requirements) and map_size(requirements) <= 1_000 and
      Enum.all?(requirements, fn {tool, required} ->
        text?(tool) and plain_map?(required) and keys?(required, @requirement_keys) and
          texts?(required["needs"], 64) and texts?(required["permissions"], 64)
      end)
  end

  defp costs?(costs) do
    within?(costs, 1_064) and Enum.all?(costs, &cost?/1) and
      length(Enum.uniq_by(costs, &target/1)) == length(costs)
  end

  defp cost?(entry) do
    plain_map?(entry) and
      ((keys?(entry, @node_cost_keys) and text?(entry["node"])) or
         keys?(entry, @callable_cost_keys)) and text?(entry["callable"]) and
      is_integer(entry["estimate"]) and entry["estimate"] in 1..@max_estimate
  end

  defp texts?(list, max),
    do: within?(list, max) and Enum.all?(list, &text?/1) and unique?(list)

  defp text?(value),
    do: is_binary(value) and byte_size(value) in 1..128 and String.valid?(value)

  defp unique?(list), do: MapSet.size(MapSet.new(list)) == length(list)

  defp plain_map?(value), do: is_map(value) and not is_struct(value)
  defp keys?(map, sorted), do: Enum.sort(Map.keys(map)) == sorted

  # A proper list of at most `left` elements, walked no further than that bound.
  defp within?([], _left), do: true
  defp within?([_ | rest], left) when left > 0, do: within?(rest, left - 1)
  defp within?(_, _left), do: false
end
