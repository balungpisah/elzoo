# SPDX-License-Identifier: Apache-2.0
defmodule Elzoo.RuntimeGraph do
  @moduledoc """
  Pure decision whether a graph that a model gave at run time may run: the graph is added to the
  recipe of the Run as one more `graph` callable, checked by `Elzoo.RecipeCheck.check_graph/3`
  and held to the limits of the agent. Runs nothing, stores nothing and grants nothing.
  """

  @context_keys Enum.sort(
                  ~w(recipe name callables agent_tools declared facts tool_costs ask_cost max_nodes max_depth depth)
                )
  @proposal_keys Enum.sort(~w(nodes links input_slots input output))
  @named_kinds ~w(call decision map loop)
  @max_bytes 65_536
  @max_estimate 9_007_199_254_740_992
  @max_rendered 64
  @codes ~w(
    invalid_shape too_large too_many_nodes callable_not_allowed tool_not_allowed
    tool_cost_unknown ask_not_allowed depth_exceeded
    unknown_tool need_not_declared permission_not_declared need_not_provided
    permission_not_granted missing_cost unknown_cost_target over_cap
    unsupported_version invalid_schema unknown_name cycle missing_giver invalid_branch
    invalid_outcome invalid_rule
  )a

  @doc "`{:ok, accepted}`, `{:refused, reasons}` or `{:error, :invalid_context}` for the proposal of a model."
  def accept(proposal, context) do
    case valid_context(context) do
      {:ok, ctx} ->
        with [] <- stage_one(proposal, ctx),
             [] <- stage_two(proposal, ctx) do
          stage_three(proposal, ctx)
        else
          reasons -> {:refused, reasons}
        end

      :error ->
        {:error, :invalid_context}
    end
  end

  @doc "The reasons as content for the model: fixed first line, at most 64 lines, no value of the input."
  def render(reasons) do
    if all?(reasons, &reason?/1) do
      {shown, rest} = Enum.split(reasons, @max_rendered)
      more = if rest == [], do: [], else: ["and #{length(rest)} more"]
      Enum.join(["graph refused:" | Enum.map(shown, &line/1)] ++ more, "\n")
    else
      {:error, :invalid_input}
    end
  end

  defp line(%{path: path, code: code}), do: render_path(path) <> ": " <> Atom.to_string(code)

  defp render_path(path) do
    Enum.reduce(path, "$", fn
      part, text when is_integer(part) -> text <> "[#{part}]"
      part, text -> text <> "." <> part
    end)
  end

  defp reason?(%{path: path, code: code} = reason) when not is_struct(reason) do
    map_size(reason) == 2 and code in @codes and within?(path, 16) and
      Enum.all?(path, &path_part?/1)
  end

  defp reason?(_), do: false

  defp path_part?(part) when is_integer(part), do: part >= 0
  defp path_part?(part) when is_binary(part), do: Regex.match?(~r/\A[a-z_]{1,32}\z/, part)
  defp path_part?(_), do: false

  # --- the context: an error of the host, never a verdict on the graph -----------------

  defp valid_context(context) do
    with true <- plain_map?(context) and keys?(context, @context_keys),
         %{"recipe" => recipe, "name" => name, "callables" => callables} = context,
         {:ok, names} <- recipe_names(recipe),
         true <- text?(name) and not MapSet.member?(names, name),
         true <- texts?(callables, 64) and Enum.all?(callables, &MapSet.member?(names, &1)),
         true <- tools?(context["agent_tools"]),
         # check_graph/3 checks `declared` and `facts` before anything else, so an empty
         # recipe shows whether the host built them wrongly.
         false <-
           Elzoo.RecipeCheck.check_graph(%{}, context["declared"], context["facts"]) ==
             {:error, :invalid_facts},
         true <- tool_costs?(context["tool_costs"]),
         true <- context["ask_cost"] == nil or estimate?(context["ask_cost"]),
         true <- int_in?(context["max_nodes"], 64),
         true <- int_in?(context["max_depth"], 16),
         true <- int_in?(context["depth"], 16) do
      {:ok,
       %{
         recipe: recipe,
         name: name,
         callables: callables,
         agent_tools: context["agent_tools"],
         declared: context["declared"],
         facts: context["facts"],
         tool_costs: context["tool_costs"],
         ask_cost: context["ask_cost"],
         max_nodes: context["max_nodes"],
         max_depth: context["max_depth"],
         depth: context["depth"]
       }}
    else
      _ -> :error
    end
  end

  defp recipe_names(recipe) do
    with true <- plain_map?(recipe),
         callables = Map.get(recipe, "callables"),
         true <- within?(callables, 64),
         true <- Enum.all?(callables, &(plain_map?(&1) and is_binary(Map.get(&1, "name")))) do
      {:ok, MapSet.new(callables, & &1["name"])}
    else
      _ -> :error
    end
  end

  defp tools?({:ToolRegistry, sources, entries, removed}),
    do: is_list(sources) and plain_map?(entries) and plain_map?(removed)

  defp tools?(_), do: false

  defp tool_costs?(costs) do
    plain_map?(costs) and map_size(costs) <= 1_000 and
      Enum.all?(costs, fn {tool, estimate} -> text?(tool) and estimate?(estimate) end)
  end

  defp estimate?(value), do: is_integer(value) and value in 1..@max_estimate
  defp int_in?(value, max), do: is_integer(value) and value in 1..max

  # --- stage 1: the proposal as data ---------------------------------------------------

  defp stage_one(proposal, ctx) do
    case scan(proposal, @max_bytes) do
      :invalid -> [reason([], :invalid_shape)]
      :too_large -> [reason([], :too_large)]
      :ok -> sized(proposal, ctx)
    end
  end

  defp sized(proposal, ctx) do
    cond do
      not shape?(proposal) -> [reason([], :invalid_shape)]
      byte_size(Jason.encode!(proposal)) > @max_bytes -> [reason([], :too_large)]
      length(proposal["nodes"]) > ctx.max_nodes -> [reason([], :too_many_nodes)]
      true -> []
    end
  end

  defp shape?(proposal) do
    keys?(proposal, @proposal_keys) and is_list(proposal["nodes"]) and
      is_list(proposal["links"]) and is_list(proposal["input_slots"]) and
      Enum.all?(proposal["nodes"], &(is_map(&1) and is_binary(Map.get(&1, "kind"))))
  end

  # Walks plain JSON data with a budget of bytes. Each charge is at most the compact JSON size
  # of the part, so an exhausted budget means that the document is over the bound. `:ok`,
  # `:invalid` (not plain JSON data) or `:too_large`.
  defp scan(value, left) do
    case walk(value, left) do
      {:ok, _left} -> :ok
      other -> other
    end
  end

  defp walk(_value, left) when left < 0, do: :too_large
  defp walk(value, left) when is_integer(value) or is_float(value), do: charge(left, 1)
  defp walk(value, left) when is_boolean(value) or is_nil(value), do: charge(left, 1)

  defp walk(value, left) when is_binary(value) do
    cond do
      byte_size(value) + 2 > left -> :too_large
      String.valid?(value) -> charge(left, byte_size(value) + 2)
      true -> :invalid
    end
  end

  defp walk(value, left) when is_list(value) do
    with {:ok, left} <- charge(left, 1), do: walk_list(value, left)
  end

  defp walk(value, left) when is_map(value) and not is_struct(value) do
    cond do
      map_size(value) * 4 > left -> :too_large
      true -> walk_map(Map.to_list(value), left)
    end
  end

  defp walk(_value, _left), do: :invalid

  defp walk_list([], left), do: {:ok, left}

  defp walk_list([head | tail], left) do
    with {:ok, left} <- walk(head, left), do: walk_list(tail, left)
  end

  defp walk_list(_improper, _left), do: :invalid

  defp walk_map([], left), do: {:ok, left}

  defp walk_map([{key, value} | rest], left) do
    with {:ok, left} <- walk(key, left),
         true <- is_binary(key) or :invalid,
         {:ok, left} <- walk(value, left) do
      walk_map(rest, left)
    end
  end

  defp charge(left, cost) when left - cost < 0, do: :too_large
  defp charge(left, cost), do: {:ok, left - cost}

  # --- stage 2: the limits of the agent ------------------------------------------------

  defp stage_two(proposal, ctx) do
    allowed = MapSet.new(ctx.callables)

    proposal["nodes"]
    |> Enum.with_index()
    |> Enum.flat_map(fn {node, index} -> limits(node, index, allowed, ctx) end)
    |> sort()
  end

  defp limits(%{"kind" => kind, "callable" => name}, index, allowed, _ctx)
       when kind in @named_kinds and is_binary(name) do
    if MapSet.member?(allowed, name),
      do: [],
      else: [reason(["nodes", index], :callable_not_allowed)]
  end

  defp limits(%{"kind" => "tool", "tool" => tool}, index, _allowed, ctx) when is_binary(tool) do
    [
      {not match?({:resolved, _}, Elzoo.ToolRegistry.resolve(ctx.agent_tools, tool)),
       :tool_not_allowed},
      {not is_map_key(ctx.tool_costs, tool), :tool_cost_unknown}
    ]
    |> Enum.filter(&elem(&1, 0))
    |> Enum.map(&reason(["nodes", index], elem(&1, 1)))
  end

  defp limits(%{"kind" => "ask"}, index, _allowed, %{ask_cost: nil}),
    do: [reason(["nodes", index], :ask_not_allowed)]

  defp limits(_node, _index, _allowed, _ctx), do: []

  # --- stage 3: the same check as at load time -----------------------------------------

  defp stage_three(proposal, ctx) do
    old = ctx.recipe["callables"]
    new = Map.merge(%{"name" => ctx.name, "kind" => "graph"}, proposal)
    recipe2 = ctx.recipe |> Map.put("callables", old ++ [new]) |> Map.put("root", ctx.name)
    facts2 = Map.put(ctx.facts, "costs", ctx.facts["costs"] ++ node_costs(proposal, ctx))

    case Elzoo.RecipeCheck.check_graph(recipe2, ctx.declared, facts2) do
      {:error, :invalid_facts} ->
        {:error, :invalid_context}

      {:refused, reasons} ->
        {:refused, reasons |> Enum.map(&locate(&1, length(old))) |> sort()}

      {:ok, verdict} ->
        if nesting(recipe2, ctx.name) + ctx.depth > ctx.max_depth do
          {:refused, [reason([], :depth_exceeded)]}
        else
          {:ok,
           %{
             recipe: recipe2,
             callable: ctx.name,
             unit: verdict.unit,
             upper_cost: verdict.upper_cost
           }}
        end
    end
  end

  # One cost entry for each tool and ask node. A node that RecipeGraph refuses (no text id,
  # a repeated id) gets none, so that its own fault, not the facts, is what is reported.
  defp node_costs(proposal, ctx) do
    proposal["nodes"]
    |> Enum.flat_map(fn
      %{"kind" => "tool", "tool" => tool, "id" => id} when is_binary(tool) ->
        cost_entry(id, ctx.tool_costs[tool], ctx.name)

      %{"kind" => "ask", "id" => id} ->
        cost_entry(id, ctx.ask_cost, ctx.name)

      _ ->
        []
    end)
    |> Enum.uniq_by(& &1["node"])
  end

  defp cost_entry(id, estimate, name) do
    if text?(id) and estimate != nil,
      do: [%{"callable" => name, "node" => id, "estimate" => estimate}],
      else: []
  end

  # A path into the new callable is a path into the proposal; `[]` stays; the rest is the recipe.
  defp locate(%{path: ["callables", new_index | rest]} = reason, new_index),
    do: %{reason | path: rest}

  defp locate(%{path: []} = reason, _new_index), do: reason
  defp locate(%{path: path} = reason, _new_index), do: %{reason | path: ["recipe" | path]}

  # 1 for the callable itself plus the longest chain of named calls below it. The recipe is
  # acyclic: check_graph/3 refused recursion before this runs.
  defp nesting(recipe, name) do
    by_name = Map.new(recipe["callables"], &{&1["name"], &1})
    {depth, _memo} = chain(name, by_name, %{})
    depth
  end

  defp chain(name, by_name, memo) do
    case memo do
      %{^name => depth} ->
        {depth, memo}

      _ ->
        {below, memo} =
          by_name[name]
          |> children()
          |> Enum.reduce({0, memo}, fn child, {longest, memo} ->
            {depth, memo} = chain(child, by_name, memo)
            {max(longest, depth), memo}
          end)

        {1 + below, Map.put(memo, name, 1 + below)}
    end
  end

  defp children(%{"kind" => "graph", "nodes" => nodes}),
    do: for(%{"kind" => kind, "callable" => name} <- nodes, kind in @named_kinds, do: name)

  defp children(_callable), do: []

  # --- shared helpers ------------------------------------------------------------------

  defp reason(path, code), do: %{path: path, code: code}
  defp sort(reasons), do: reasons |> Enum.uniq() |> Enum.sort_by(&{&1.path, &1.code})

  defp plain_map?(value), do: is_map(value) and not is_struct(value)
  defp keys?(map, sorted), do: plain_map?(map) and Enum.sort(Map.keys(map)) == sorted

  defp text?(value),
    do: is_binary(value) and byte_size(value) in 1..128 and String.valid?(value)

  defp texts?(list, max),
    do: within?(list, max) and Enum.all?(list, &text?/1) and unique?(list)

  defp unique?(list), do: MapSet.size(MapSet.new(list)) == length(list)

  # A proper list of at most `left` elements, walked no further than that bound.
  defp within?([], _left), do: true
  defp within?([_ | rest], left) when left > 0, do: within?(rest, left - 1)
  defp within?(_, _left), do: false

  defp all?([], _fun), do: true
  defp all?([head | tail], fun), do: fun.(head) and all?(tail, fun)
  defp all?(_improper, _fun), do: false
end
