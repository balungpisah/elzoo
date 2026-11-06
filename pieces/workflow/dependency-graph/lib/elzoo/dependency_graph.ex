# SPDX-License-Identifier: Apache-2.0
defmodule Elzoo.DependencyGraph do
  @moduledoc """
  Validating Elixir shell over the Cure decisions in
  `:"Cure.Elzoo.DependencyGraph"` (workflow/dependency-graph, ELZ-026).

  Edge orientation: `%{from: f, to: t}` means `f` waits for `t`. A proposed
  blocking `f -> t` creates a cycle iff `t` already reaches `f` (or `f == t`).
  Every blocker's `target` is the edge's `to`.

  Readiness, fact support, target satisfaction and admission are decided by
  the compiled Cure functions and covered by the selected laws in the Cure
  source. This module validates and bounds input, maps IDs to integer node
  indices, computes duplicate/unknown/unplaceable flags, blocker reasons and
  cycle paths, and maps results back. That layer is test-grounded only.
  No clock is read and no I/O is performed.
  """

  @cure :"Cure.Elzoo.DependencyGraph"

  @max_nodes 1_000
  @max_edges 10_000
  @max_facts 10_000

  @lifecycles %{open: :DgOpen, completed: :DgCompleted, cancelled: :DgCancelled, closed: :DgClosed}
  @kinds %{blocking: :DgBlocking, informational: :DgInformational, hierarchy: :DgHierarchy}
  @kind_names Map.new(@kinds, fn {k, v} -> {v, k} end)
  @values %{satisfied: :DgSatisfied, unsatisfied: :DgUnsatisfied, unknown: :DgUnknown}
  @provenances %{
    tool_result: :DgToolResult,
    artifact_reference: :DgArtifactReference,
    event_fold: :DgEventFold,
    model_declared: :DgModelDeclared
  }

  @graph_keys [:edges, :externals, :facts, :items]
  @item_keys [:deferred_until, :id, :lifecycle]
  @edge_keys [:from, :kind, :to]
  @fact_keys [:expiry, :prerequisite, :provenance, :source, :value]

  @doc "Fixed Contract bounds: `%{nodes: 1_000, edges: 10_000, facts: 10_000}`."
  def bounds, do: %{nodes: @max_nodes, edges: @max_edges, facts: @max_facts}

  @doc "Validation report: duplicate nodes, unknown dependencies, then one cycle issue."
  def validate(graph) do
    with :ok <- check_graph(graph, 0), do: {:ok, analyse(graph).issues}
  end

  @doc "Ready, blocked and inactive items at `now` (Unix milliseconds)."
  def readiness(graph, now) do
    with :ok <- check_graph(graph, 0),
         :ok <- if(non_neg_int?(now), do: :ok, else: {:error, {:invalid, [:now]}}) do
      {:ok, decide_readiness(analyse(graph), now)}
    end
  end

  @doc """
  Admit or reject one proposed edge after revalidating the whole graph.
  Returns `{:admit, graph2}` (edge prepended), `{:reject, reason}` or
  `{:error, reason}`; the caller's graph is never changed on reject or error.
  """
  def admit(graph, proposal) do
    with :ok <- check_graph(graph, 1),
         :ok <- check_proposal(proposal) do
      a = analyse(graph)

      cond do
        a.issues != [] ->
          {:reject, {:invalid_graph, a.issues}}

        unknown_endpoints?(a, proposal) ->
          {:reject,
           {:unknown_dependency,
            %{
              from: proposal.from,
              to: proposal.to,
              endpoints: %{from: role(a, proposal.from), to: role(a, proposal.to)}
            }}}

        true ->
          commit(graph, a, proposal)
      end
    end
  end

  @doc """
  Serialized-owner step for `Elzoo.Unit`: `{:Transition, next_graph, {:some, result}}`,
  where `result` is `:admit`, `{:reject, reason}` or `{:error, reason}`.
  `next_graph` is the Cure step's committed state mapped back to IDs on
  `:admit`, and the input graph unchanged otherwise.
  """
  def admission_step(graph, proposal) do
    case admit(graph, proposal) do
      {:admit, next} -> {:Transition, next, {:some, :admit}}
      {:reject, reason} -> {:Transition, graph, {:some, {:reject, reason}}}
      {:error, reason} -> {:Transition, graph, {:some, {:error, reason}}}
    end
  end

  # ------------------------------------------------------------- admission

  defp commit(graph, a, %{from: f, to: t, kind: kind}) do
    cure_proposal = {:DgRE, Map.fetch!(@kinds, kind), index(a, f), index(a, t)}

    case apply(@cure, :admission_step, [a.cure_edges, cure_proposal]) do
      {:Transition, next, {:some, :DgAdmit}} ->
        {:admit, %{graph | edges: Enum.map(next, &id_edge(a, &1))}}

      {:Transition, _same, {:some, :DgReject}} ->
        case route(a, t, f) do
          nil -> {:error, :search_disagreement}
          path -> {:reject, {:cycle, path ++ [t]}}
        end
    end
  end

  defp id_edge(a, {:DgRE, kind, from, to}),
    do: %{
      from: Map.fetch!(a.ids, from),
      to: Map.fetch!(a.ids, to),
      kind: Map.fetch!(@kind_names, kind)
    }

  # Shortest route of blocking edges from `source` to `target` (BFS).
  defp route(_a, same, same), do: [same]

  defp route(a, source, target) do
    bfs(a.successors, :queue.from_list([source]), %{source => nil}, target)
  end

  defp bfs(successors, queue, parents, target) do
    case :queue.out(queue) do
      {:empty, _} ->
        nil

      {{:value, node}, rest} ->
        {queue2, parents2} =
          successors
          |> Map.get(node, [])
          |> Enum.reduce({rest, parents}, fn next, {q, p} ->
            if Map.has_key?(p, next), do: {q, p}, else: {:queue.in(next, q), Map.put(p, next, node)}
          end)

        if Map.has_key?(parents2, target),
          do: unwind(parents2, target, []),
          else: bfs(successors, queue2, parents2, target)
    end
  end

  defp unwind(_parents, nil, acc), do: acc
  defp unwind(parents, node, acc), do: unwind(parents, Map.fetch!(parents, node), [node | acc])

  defp unknown_endpoints?(a, %{from: f, to: t}),
    do: role(a, f) != :item or role(a, t) == :undeclared

  # ------------------------------------------------------------- readiness

  defp decide_readiness(a, now) do
    results =
      Enum.map(a.item_nodes, fn {item, node} ->
        if item.lifecycle == :open do
          ready? =
            apply(@cure, :item_ready, [
              node,
              until(item),
              a.cure_edges,
              a.cure_nodes,
              a.cure_facts,
              now
            ])

          blockers = blockers(a, item, node, now)

          # The explanation must agree with the Cure decision for every item.
          if ready? != (blockers == []),
            do: raise(ArgumentError, "explanation disagrees with decision for #{inspect(item.id)}")

          {:open, item.id, ready?, blockers}
        else
          {:inactive, item.id}
        end
      end)

    %{
      ready: for({:open, id, true, _} <- results, do: id),
      blocked: for({:open, id, false, b} <- results, do: %{id: id, blockers: b}),
      inactive: for({:inactive, id} <- results, do: id),
      contradictions: contradictions(a, now),
      orphan_facts: a.orphan_facts,
      issues: a.issues
    }
  end

  defp until(%{deferred_until: nil}), do: :none
  defp until(%{deferred_until: u}), do: {:some, u}

  defp blockers(a, item, {:DgN, _i, _l, duplicate, unplaceable}, now) do
    own =
      [
        {apply(@cure, :deferred, [until(item), now]), :deferred},
        {duplicate, :duplicate_node},
        {unplaceable, :cycle}
      ]
      |> Enum.flat_map(fn
        {true, reason} -> [%{target: item.id, present: true, satisfied: false, reason: reason}]
        {false, _} -> []
      end)

    edges =
      for %{kind: :blocking, from: from, to: to} <- a.graph.edges,
          from == item.id,
          not satisfied?(a, to, now),
          do: %{
            target: to,
            present: role(a, to) != :undeclared,
            satisfied: false,
            reason: reason(a, to, now)
          }

    own ++ edges
  end

  defp satisfied?(a, to, now),
    do: apply(@cure, :target_satisfied, [index(a, to), a.cure_nodes, a.cure_facts, now])

  defp reason(a, to, now) do
    cond do
      role(a, to) == :undeclared -> :unknown_dependency
      MapSet.member?(a.duplicates, to) -> :duplicate_node
      MapSet.member?(a.unplaceable, to) -> :cycle
      lifecycle(a, to) == :cancelled -> :cancelled
      lifecycle(a, to) == :closed -> :closed_without_completion
      true -> fact_reason(Map.get(a.facts_by_target, to, []), now)
    end
  end

  defp fact_reason(facts, now) do
    live = Enum.filter(facts, &current?(&1, now))
    live_satisfied = Enum.filter(live, &(&1.value == :satisfied))

    cond do
      Enum.any?(live, &(&1.value == :unsatisfied)) ->
        :fact_vetoed

      live_satisfied != [] and Enum.all?(live_satisfied, &(&1.provenance == :model_declared)) ->
        :model_declared_only

      Enum.any?(live, &(&1.value == :unknown)) ->
        :fact_unknown

      facts != [] and live == [] ->
        :fact_expired

      facts == [] ->
        :no_fact
    end
  end

  defp current?(fact, now), do: apply(@cure, :current, [fact.expiry, now])

  defp contradictions(a, now) do
    for %{kind: :blocking, from: from, to: to} <- a.graph.edges,
        role(a, from) == :item,
        lifecycle(a, to) == :completed,
        not MapSet.member?(a.duplicates, to),
        not MapSet.member?(a.unplaceable, to),
        vetoes =
          Enum.filter(
            Map.get(a.facts_by_target, to, []),
            &(&1.value == :unsatisfied and current?(&1, now))
          ),
        vetoes != [],
        do: %{
          item: from,
          target: to,
          reason: :completion_contradicted,
          sources: Enum.map(vetoes, & &1.source)
        }
  end

  # -------------------------------------------------------------- analysis

  defp analyse(graph) do
    node_ids = Enum.map(graph.items, & &1.id) ++ graph.externals
    counts = Enum.frequencies(node_ids)
    duplicates = for {id, n} <- counts, n > 1, into: MapSet.new(), do: id

    first_index =
      node_ids
      |> Enum.with_index()
      |> Enum.reduce(%{}, fn {id, i}, acc -> Map.put_new(acc, id, i) end)

    item_ids = MapSet.new(graph.items, & &1.id)
    external_ids = MapSet.new(graph.externals)

    lifecycles =
      Enum.reduce(graph.items, %{}, fn item, acc -> Map.put_new(acc, item.id, item.lifecycle) end)

    base = %{
      graph: graph,
      index: first_index,
      ids: Map.new(first_index, fn {id, i} -> {i, id} end),
      items: item_ids,
      externals: external_ids,
      lifecycles: lifecycles,
      duplicates: duplicates
    }

    valid_blocking =
      for %{kind: :blocking, from: f, to: t} <- graph.edges,
          role(base, f) == :item,
          role(base, t) != :undeclared,
          do: {f, t}

    unplaceable = unplaceable(Enum.uniq(node_ids), valid_blocking)

    successors =
      Enum.reduce(Enum.reverse(valid_blocking), %{}, fn {f, t}, acc ->
        Map.update(acc, f, [t], &[t | &1])
      end)

    tags =
      Enum.map(graph.items, &Map.fetch!(@lifecycles, &1.lifecycle)) ++
        List.duplicate(:DgExternal, length(graph.externals))

    cure_nodes =
      [node_ids, tags, Stream.iterate(0, &(&1 + 1))]
      |> Enum.zip_with(fn [id, tag, i] ->
        {:DgN, i, tag, MapSet.member?(duplicates, id), MapSet.member?(unplaceable, id)}
      end)

    item_nodes = Enum.zip(graph.items, Enum.take(cure_nodes, length(graph.items)))

    {kept, orphans} =
      graph.facts
      |> Enum.with_index()
      |> Enum.split_with(fn {fact, _} -> role(base, fact.prerequisite) != :undeclared end)

    issues =
      for(
        id <- Enum.uniq(node_ids),
        MapSet.member?(duplicates, id),
        do: %{kind: :duplicate_node, id: id}
      ) ++
        for(
          %{from: f, to: t} <- graph.edges,
          role(base, f) != :item or role(base, t) == :undeclared,
          do: %{
            kind: :unknown_dependency,
            from: f,
            to: t,
            endpoints: %{from: role(base, f), to: role(base, t)}
          }
        ) ++
        case Enum.filter(Enum.uniq(node_ids), &MapSet.member?(unplaceable, &1)) do
          [] -> []
          nodes -> [%{kind: :cycle, nodes: nodes}]
        end

    Map.merge(base, %{
      unplaceable: unplaceable,
      successors: successors,
      cure_nodes: cure_nodes,
      item_nodes: item_nodes,
      cure_edges: Enum.map(graph.edges, &cure_edge(base, &1)),
      cure_facts:
        Enum.map(kept, fn {fact, _} ->
          {:DgF, index(base, fact.prerequisite), Map.fetch!(@values, fact.value),
           Map.fetch!(@provenances, fact.provenance), fact.expiry}
        end),
      facts_by_target: kept |> Enum.map(&elem(&1, 0)) |> Enum.group_by(& &1.prerequisite),
      orphan_facts: Enum.map(orphans, &elem(&1, 1)),
      issues: issues
    })
  end

  defp cure_edge(a, %{from: f, to: t, kind: k}),
    do: {:DgRE, Map.fetch!(@kinds, k), index(a, f), index(a, t)}

  defp index(a, id), do: Map.get(a.index, id, -1)

  defp role(a, id) do
    cond do
      MapSet.member?(a.items, id) -> :item
      MapSet.member?(a.externals, id) -> :external
      true -> :undeclared
    end
  end

  defp lifecycle(a, id), do: Map.get(a.lifecycles, id)

  # Kahn: a node is placed once every prerequisite it waits for is placed.
  defp unplaceable(nodes, edges) do
    waits = Enum.group_by(edges, &elem(&1, 0), &elem(&1, 1))
    place(MapSet.new(nodes), MapSet.new(), waits)
  end

  defp place(remaining, placed, waits) do
    ready =
      Enum.filter(remaining, fn n ->
        Enum.all?(Map.get(waits, n, []), &MapSet.member?(placed, &1))
      end)

    if ready == [],
      do: remaining,
      else:
        place(
          MapSet.difference(remaining, MapSet.new(ready)),
          MapSet.union(placed, MapSet.new(ready)),
          waits
        )
  end

  # ------------------------------------------------------------ validation

  defp check_graph(graph, extra_edges) do
    with :ok <- shape(graph),
         :ok <- check_bounds(graph, extra_edges) do
      check_entries(graph)
    end
  end

  defp shape(graph) when is_map(graph) do
    cond do
      Enum.sort(Map.keys(graph)) != @graph_keys ->
        {:error, {:invalid, []}}

      key = Enum.find(@graph_keys, &(not is_list(Map.fetch!(graph, &1)))) ->
        {:error, {:invalid, [key]}}

      true ->
        :ok
    end
  end

  defp shape(_), do: {:error, {:invalid, []}}

  defp check_bounds(graph, extra_edges) do
    cond do
      length(graph.items) + length(graph.externals) > @max_nodes -> {:error, {:too_large, :nodes}}
      length(graph.edges) + extra_edges > @max_edges -> {:error, {:too_large, :edges}}
      length(graph.facts) > @max_facts -> {:error, {:too_large, :facts}}
      true -> :ok
    end
  end

  defp check_entries(graph) do
    [
      {:items, &item_error/1},
      {:externals, fn id -> if id?(id), do: nil, else: [] end},
      {:edges, &edge_error/1},
      {:facts, &fact_error/1}
    ]
    |> Enum.find_value(:ok, fn {key, check} ->
      graph
      |> Map.fetch!(key)
      |> Enum.with_index()
      |> Enum.find_value(fn {entry, i} ->
        case check.(entry) do
          nil -> nil
          path -> {:error, {:invalid, [key, i | path]}}
        end
      end)
    end)
  end

  defp item_error(item) do
    cond do
      not exact?(item, @item_keys) -> []
      not id?(item.id) -> [:id]
      not Map.has_key?(@lifecycles, item.lifecycle) -> [:lifecycle]
      not (is_nil(item.deferred_until) or non_neg_int?(item.deferred_until)) -> [:deferred_until]
      true -> nil
    end
  end

  defp edge_error(edge) do
    cond do
      not exact?(edge, @edge_keys) -> []
      not id?(edge.from) -> [:from]
      not id?(edge.to) -> [:to]
      not Map.has_key?(@kinds, edge.kind) -> [:kind]
      true -> nil
    end
  end

  defp fact_error(fact) do
    cond do
      not exact?(fact, @fact_keys) -> []
      not id?(fact.prerequisite) -> [:prerequisite]
      not Map.has_key?(@values, fact.value) -> [:value]
      not id?(fact.source) -> [:source]
      not Map.has_key?(@provenances, fact.provenance) -> [:provenance]
      not non_neg_int?(fact.expiry) -> [:expiry]
      true -> nil
    end
  end

  defp check_proposal(proposal) do
    case if(exact?(proposal, @edge_keys), do: edge_error(proposal), else: []) do
      nil -> :ok
      path -> {:error, {:invalid, [:proposal | path]}}
    end
  end

  defp exact?(map, keys), do: is_map(map) and Enum.sort(Map.keys(map)) == keys
  defp id?(id), do: is_binary(id) and byte_size(id) > 0 and String.valid?(id)
  defp non_neg_int?(n), do: is_integer(n) and n >= 0
end
