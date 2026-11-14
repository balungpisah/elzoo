# SPDX-License-Identifier: Apache-2.0
defmodule Elzoo.GraphRun do
  @moduledoc """
  One `graph` callable of a recipe as one pure pattern step: recorded outcomes give the
  nodes that are ready, and the step asks for their actions. It calls no model, tool or
  callable, reads no clock, stores nothing and starts no process. See the bundle README
  for the payload shapes and the state form.
  """
  alias Elzoo.{NodeOutcome, PatternStep, RecipeGraph, ToolRegistry}

  @spec_keys [:callable, :id, :maps, :max_open, :recipe, :sources]
  @state_bound 65_536
  @input_key "elzoo.graph-run.input"
  @result_key "elzoo.graph-run.node-result"
  @call_key "elzoo.graph-run.call"
  @tool_key "elzoo.graph-run.tool-call"
  @ask_key "elzoo.graph-run.ask"
  @answer_key "elzoo.graph-run.answer"
  @finish_key "elzoo.graph-run.result"
  @kinds %{
    "call" => :call,
    "tool" => :tool,
    "ask" => :ask,
    "decision" => :decision,
    "map" => :map,
    "loop" => :loop
  }

  @doc """
  Checks a spec; `{:ok, state}` or `{:error, :invalid_spec | :unknown_callable |
  {:recipe, reason} | {:sources, reason} | {:unknown_tool, node_id} | :state_too_large}`.
  """
  def new(spec) do
    with {:ok, spec} <- shape(spec),
         {:ok, graph, recipe} <- graph(spec),
         {:ok, snapshot} <- snapshot(spec.sources),
         :ok <- nodes_shape(graph["nodes"]),
         {:ok, tools} <- tools(snapshot, graph["nodes"]),
         {:ok, maps} <- maps(spec.maps, graph["nodes"]),
         {:ok, nodes} <- nodes(graph, recipe, tools) do
      state = %{
        phase: :new,
        id: spec.id,
        max_open: spec.max_open,
        slots: Enum.map(graph["input_slots"], & &1["name"]),
        order: Enum.map(graph["nodes"], & &1["id"]),
        nodes: nodes,
        maps: maps,
        sinks: sinks(graph),
        input: nil,
        status: Map.new(graph["nodes"], &{&1["id"], :pending}),
        gives: %{},
        choices: %{},
        work: %{},
        open: %{},
        out: [],
        last: nil,
        failed: []
      }

      if size(state) <= @state_bound, do: {:ok, state}, else: {:error, :state_too_large}
    end
  end

  @doc """
  One `core/operator` transition over a neutral `Elzoo.PatternStep` input map:
  `{:Transition, new_state, :none | {:some, request}}`.
  """
  def step(state, input) do
    case PatternStep.decode(input) do
      {:ok, checked} -> bounded(state, transition(state, input, checked))
      _ -> unchanged(state)
    end
  end

  # A transition never returns a state over the bound: it finishes with state_over_bound.
  defp bounded(state, {:Transition, next, _} = result) do
    if size(next) <= @state_bound,
      do: result,
      else: finish(state, "failed", "state_over_bound", nil)
  end

  ## The step table

  defp transition(%{phase: :closed} = state, _, _), do: unchanged(state)

  defp transition(state, %{"kind" => kind}, _) when kind in ["cancel", "run_ended"],
    do: {:Transition, closed(state), :none}

  defp transition(%{phase: :new} = state, %{"kind" => "start"} = input, _) do
    case start_values(state, input) do
      {:ok, values} -> %{state | phase: :running, input: values} |> advance() |> conclude()
      :error -> finish(state, "failed", "invalid_input", nil)
    end
  end

  defp transition(%{phase: :running} = state, %{"kind" => kind} = input, checked)
       when kind in ["action_outcome", "person_answer"] do
    with {:ok, {node_id, tag, tracker}} <- Map.fetch(state.open, input["action_id"]),
         {:applied, _} <- PatternStep.accept(tracker, checked) do
      state
      |> settle(state.nodes[node_id], tag, input)
      |> advance()
      |> conclude()
    else
      _ -> unchanged(state)
    end
  end

  defp transition(state, _, _), do: unchanged(state)

  defp start_values(state, %{
         "schema_id" => @input_key,
         "schema_version" => 1,
         "payload" => %{"input" => values} = payload
       })
       when map_size(payload) == 1 and is_map(values) and not is_struct(values) do
    if Enum.sort(Map.keys(values)) == Enum.sort(state.slots), do: {:ok, values}, else: :error
  end

  defp start_values(_, _), do: :error

  ## Ready nodes

  # After each change, in the order of the nodes list and until nothing changes. A run that
  # has failed starts and skips nothing.
  defp advance(%{failed: [_ | _]} = state), do: state

  defp advance(state) do
    {state, changed} =
      Enum.reduce(state.order, {state, false}, fn id, {state, changed} ->
        {state, one} = visit(state, id)
        {state, changed or one}
      end)

    if changed, do: advance(state), else: state
  end

  defp visit(%{failed: [_ | _]} = state, _), do: {state, false}

  defp visit(state, id) do
    node = state.nodes[id]
    status = state.status[id]
    {decided, ready} = readiness(state, node)
    seat = map_size(state.open) < state.max_open

    case cure_move(status, decided, ready, seat) do
      :start -> start_node(state, node)
      :skip -> {%{state | status: Map.put(state.status, id, :skipped)}, true}
      :hold when status == :open -> continue(state, node)
      :hold -> {state, false}
    end
  end

  defp cure_move(status, decided, ready, seat) do
    case apply(:"Cure.Elzoo.GraphRun", :move, [cure_state(status), decided, ready, seat]) do
      :MoveStart -> :start
      :MoveSkip -> :skip
      :MoveHold -> :hold
    end
  end

  defp cure_state(:pending), do: :NodePending
  defp cure_state(:open), do: {:NodeLeft, :LeftOpen}
  defp cure_state(:skipped), do: {:NodeLeft, :LeftSkipped}
  defp cure_state({:done, _}), do: {:NodeLeft, :LeftDone}

  # {every incoming link decided, the readiness rule over the links}
  defp readiness(state, node) do
    marked = for link <- node.inc, do: {elem(link, 0), link_state(state, link)}
    gating = for {kind, link} <- marked, kind != :data, do: link

    {Enum.all?(marked, fn {_, link} -> link != :undecided end),
     Enum.all?(marked, fn {kind, link} -> kind != :data or link == :live end) and
       not Enum.any?(marked, fn {kind, link} -> kind == :order and link == :dead end) and
       (gating == [] or :live in gating)}
  end

  defp link_state(_, {:data, "$input", _, _}), do: :live

  defp link_state(state, {:data, from, _, _}) do
    case state.status[from] do
      {:done, "completed"} -> :live
      open when open in [:pending, :open] -> :undecided
      _ -> :dead
    end
  end

  defp link_state(state, {:order, from}) do
    case state.status[from] do
      {:done, "completed"} -> :live
      {:done, _} -> :dead
      :skipped -> :void
      _ -> :undecided
    end
  end

  defp link_state(state, {:choice, from, choice}) do
    case state.status[from] do
      {:done, "completed"} -> if state.choices[from] == choice, do: :live, else: :dead
      open when open in [:pending, :open] -> :undecided
      _ -> :dead
    end
  end

  defp link_state(state, {:outcome, from, class}) do
    case state.status[from] do
      {:done, ^class} -> :live
      open when open in [:pending, :open] -> :undecided
      _ -> :dead
    end
  end

  ## Starting actions

  defp start_node(state, %{kind: kind} = node) when kind in [:call, :decision] do
    payload = %{"callable" => node.callable, "input" => needs(state, node)}
    action = {"nested_callable", @call_key, payload}
    {state |> put_action(node, :whole, action_id(state, node), action) |> opened(node), true}
  end

  defp start_node(state, %{kind: :tool, tool: {name, source, tool, version, kind}} = node) do
    payload = %{
      "alias" => name,
      "source" => source,
      "tool" => tool,
      "version" => version,
      "arguments" => needs(state, node)
    }

    action = {kind, @tool_key, payload}
    {state |> put_action(node, :whole, action_id(state, node), action) |> opened(node), true}
  end

  defp start_node(state, %{kind: :ask} = node) do
    needs = needs(state, node)
    payload = %{"person_id" => needs["person_id"], "question" => needs["question"]}
    action = {"ask_person", @ask_key, payload}
    {state |> put_action(node, :whole, action_id(state, node), action) |> opened(node), true}
  end

  defp start_node(state, %{kind: :map} = node) do
    items = needs(state, node)["items"]

    cond do
      not (is_list(items) and not List.improper?(items) and length(items) <= node.max) ->
        {finish_node(state, node, "failed", %{}, nil), true}

      items == [] ->
        {finish_node(state, node, "completed", gives(node, %{"items" => []}), nil), true}

      true ->
        work = %{items: items, next: 0, results: %{}, stop: false}
        state = opened(%{state | work: Map.put(state.work, node.id, work)}, node)
        {state, _} = continue(state, node)
        {state, true}
    end
  end

  defp start_node(state, %{kind: :loop} = node) do
    work = %{next: 1, previous: nil, queued: true}
    state = opened(%{state | work: Map.put(state.work, node.id, work)}, node)
    {state, _} = continue(state, node)
    {state, true}
  end

  # More actions of a node that is open: items of a map, the next iteration of a loop.
  defp continue(%{failed: [_ | _]} = state, _), do: {state, false}

  defp continue(state, %{kind: :map} = node) do
    %{items: items, next: next, stop: stop} = work = state.work[node.id]
    {concurrency, _} = state.maps[node.id]

    if stop or next >= length(items) or open_items(state, node.id) >= concurrency or
         map_size(state.open) >= state.max_open do
      {state, false}
    else
      input =
        state
        |> needs(node)
        |> Map.delete("items")
        |> Map.merge(%{"item" => Enum.at(items, next), "index" => next})

      payload = %{"callable" => node.callable, "input" => input}
      id = action_id(state, node) <> ":" <> Integer.to_string(next)
      state = put_action(state, node, {:item, next}, id, {"nested_callable", @call_key, payload})
      state = %{state | work: Map.put(state.work, node.id, %{work | next: next + 1})}
      {state, _} = continue(state, node)
      {state, true}
    end
  end

  defp continue(state, %{kind: :loop} = node) do
    %{next: k, previous: previous, queued: queued} = state.work[node.id]

    if queued and map_size(state.open) < state.max_open do
      input = Map.merge(needs(state, node), %{"iteration" => k, "previous" => previous})
      payload = %{"callable" => node.callable, "input" => input}
      id = action_id(state, node) <> ":" <> Integer.to_string(k)
      state = put_action(state, node, {:iter, k}, id, {"nested_callable", @call_key, payload})
      work = %{state.work[node.id] | queued: false}
      {%{state | work: Map.put(state.work, node.id, work)}, true}
    else
      {state, false}
    end
  end

  defp continue(state, _), do: {state, false}

  # Each need by name, from the live data link that gives it.
  defp needs(state, node) do
    for {:data, from, give, need} <- node.inc, into: %{} do
      {need, if(from == "$input", do: state.input[give], else: state.gives[from][give])}
    end
  end

  defp put_action(state, node, tag, id, {kind, key, payload}) do
    action = %{
      "id" => id,
      "kind" => kind,
      "schema_id" => key,
      "schema_version" => 1,
      "payload" => payload
    }

    {:ok, checked} =
      PatternStep.decode(%{"type" => "request", "version" => 1, "actions" => [action]})

    %{
      state
      | out: [action | state.out],
        open: Map.put(state.open, id, {node.id, tag, PatternStep.open(checked)})
    }
  end

  defp opened(state, node), do: %{state | status: Map.put(state.status, node.id, :open)}
  defp action_id(state, node), do: state.id <> ":n:" <> node.id

  defp open_items(state, node_id),
    do: Enum.count(state.open, fn {_, {id, _, _}} -> id == node_id end)

  ## One settled action

  defp settle(state, node, tag, input) do
    state = %{state | open: Map.delete(state.open, input["action_id"])}

    state =
      if input["kind"] == "person_answer" or input["outcome"] == "completed",
        do: %{state | last: input["action_id"]},
        else: state

    result(state, node, tag, input)
  end

  defp result(state, node, :whole, input) do
    case whole(node, input) do
      {:completed, gives, choice} -> finish_node(state, node, "completed", gives, choice)
      {:class, class} -> finish_node(state, node, class, %{}, nil)
    end
  end

  defp result(state, node, {:item, index}, input) do
    result =
      case input["outcome"] do
        "completed" ->
          case input do
            %{"schema_id" => @result_key, "schema_version" => 1, "payload" => %{"gives" => g}}
            when is_map(g) and not is_struct(g) ->
              {"completed", g}

            _ ->
              {"failed", nil}
          end

        class ->
          {class, nil}
      end

    {_, mode} = state.maps[node.id]
    work = state.work[node.id]

    work = %{
      work
      | results: Map.put(work.results, index, result),
        stop: work.stop or (mode == :fail and elem(result, 0) != "completed")
    }

    state = %{state | work: Map.put(state.work, node.id, work)}

    if open_items(state, node.id) == 0 and (work.stop or work.next >= length(work.items)),
      do: finish_map(state, node, mode, work),
      else: state
  end

  defp result(state, node, {:iter, k}, input) do
    case whole(node, input) do
      {:completed, gives, {:continue, true}} when k < node.max ->
        work = %{next: k + 1, previous: gives, queued: true}
        %{state | work: Map.put(state.work, node.id, work)}

      {:completed, gives, {:continue, _}} ->
        finish_node(state, node, "completed", gives, nil)

      {:class, class} ->
        finish_node(state, node, class, %{}, nil)
    end
  end

  # The outcome of an action of the node as one of its own results.
  defp whole(%{kind: :ask} = node, %{"kind" => "person_answer"} = input) do
    case input do
      %{"schema_id" => @answer_key, "schema_version" => 1, "payload" => %{"text" => text} = p}
      when map_size(p) == 1 and is_binary(text) ->
        {:completed, gives(node, %{"text" => text}), nil}

      _ ->
        {:class, "failed"}
    end
  end

  defp whole(node, %{"outcome" => "completed"} = input) do
    with %{"schema_id" => @result_key, "schema_version" => 1, "payload" => %{"gives" => gives} = p} <-
           input,
         true <- is_map(gives) and not is_struct(gives),
         true <- Enum.all?(node.gives, &Map.has_key?(gives, &1)),
         {:ok, extra} <- extra(node, p) do
      {:completed, Map.take(gives, node.gives), extra}
    else
      _ -> {:class, "failed"}
    end
  end

  defp whole(_, %{"outcome" => class}), do: {:class, class}

  defp extra(%{kind: :decision} = node, %{"choice" => choice}) do
    if choice in node.choices, do: {:ok, choice}, else: :error
  end

  defp extra(%{kind: :loop}, %{"continue" => flag}) when is_boolean(flag),
    do: {:ok, {:continue, flag}}

  defp extra(%{kind: kind}, _) when kind in [:decision, :loop], do: :error
  defp extra(_, _), do: {:ok, nil}

  defp finish_map(state, node, mode, work) do
    results = fn -> Enum.map(0..(length(work.items) - 1), &Map.fetch!(work.results, &1)) end

    cond do
      mode == :fail and work.stop ->
        finish_node(state, node, "failed", %{}, nil)

      mode == :partial and Enum.all?(work.results, fn {_, {class, _}} -> class != "completed" end) ->
        finish_node(state, node, "failed", %{}, nil)

      true ->
        items =
          results.()
          |> Enum.with_index()
          |> Enum.map(fn
            {{"completed", gives}, index} ->
              %{"index" => index, "status" => "completed", "gives" => gives}

            {{class, _}, index} ->
              %{"index" => index, "status" => class}
          end)

        finish_node(state, node, "completed", gives(node, %{"items" => items}), nil)
    end
  end

  defp gives(node, all), do: Map.take(all, node.gives)

  # The node becomes done with one class; the outcome rule of node-outcome decides what
  # follows. A route needs no further action: the link table makes it live.
  defp finish_node(state, node, class, gives, choice) do
    state = %{
      state
      | status: Map.put(state.status, node.id, {:done, class}),
        work: Map.delete(state.work, node.id)
    }

    state =
      if class == "completed",
        do: %{
          state
          | gives: Map.put(state.gives, node.id, gives),
            choices: Map.put(state.choices, node.id, choice)
        },
        else: state

    case NodeOutcome.decide(node.routes, class) do
      {:fail_run, :no_outcome_link} -> %{state | failed: state.failed ++ [node.id]}
      _ -> state
    end
  end

  ## Requests and finishes

  defp conclude(%{failed: [_ | _]} = state) do
    if map_size(state.open) == 0 do
      first = Enum.find(state.order, &(&1 in state.failed))
      finish(state, "failed", "no_outcome_link", first)
    else
      emit(state)
    end
  end

  defp conclude(state) do
    if Enum.any?(state.status, fn {_, status} -> status in [:pending, :open] end),
      do: emit(state),
      else: done(state)
  end

  defp done(state) do
    sinks = Enum.filter(state.sinks, &(state.status[&1] == {:done, "completed"}))
    names = Enum.flat_map(sinks, &state.nodes[&1].gives)

    if length(names) == length(Enum.uniq(names)) do
      gives = Enum.reduce(sinks, %{}, &Map.merge(&2, state.gives[&1]))
      finish(state, "completed", nil, nil, gives, state.last)
    else
      finish(state, "failed", "ambiguous_output", nil)
    end
  end

  defp emit(%{out: []} = state), do: unchanged(state)

  defp emit(state) do
    request = %{"type" => "request", "version" => 1, "actions" => Enum.reverse(state.out)}
    {:Transition, %{state | out: []}, {:some, request}}
  end

  defp finish(state, "failed", reason, node), do: finish(state, "failed", reason, node, nil, nil)

  defp finish(state, status, reason, node, gives, action_id) do
    payload = %{
      "status" => status,
      "reason" => reason,
      "node" => node,
      "action_id" => action_id,
      "gives" => gives
    }

    action = %{
      "id" => state.id <> ":finish",
      "kind" => "finish",
      "schema_id" => @finish_key,
      "schema_version" => 1,
      "payload" => payload
    }

    {:Transition, closed(state),
     {:some, %{"type" => "request", "version" => 1, "actions" => [action]}}}
  end

  defp closed(state), do: %{phase: :closed, id: state.id}
  defp unchanged(state), do: {:Transition, state, :none}

  defp size(state),
    do: byte_size(:erlang.term_to_binary(state, [:deterministic, {:minor_version, 2}]))

  ## Spec checks

  defp shape(%{} = spec) when not is_struct(spec) do
    if Enum.sort(Map.keys(spec)) == @spec_keys and id?(spec.id) and is_binary(spec.callable) and
         is_integer(spec.max_open) and spec.max_open in 1..64 and is_map(spec.maps) and
         not is_struct(spec.maps),
       do: {:ok, spec},
       else: {:error, :invalid_spec}
  end

  defp shape(_), do: {:error, :invalid_spec}

  defp id?(id),
    do:
      is_binary(id) and byte_size(id) in 1..64 and String.valid?(id) and
        not String.contains?(id, ":")

  defp graph(spec) do
    case RecipeGraph.decode(spec.recipe) do
      {:ok, checked} ->
        recipe = RecipeGraph.encode(checked)

        case Enum.find(
               recipe["callables"],
               &(&1["name"] == spec.callable and &1["kind"] == "graph")
             ) do
          nil -> {:error, :unknown_callable}
          graph -> {:ok, graph, recipe}
        end

      {:error, reason} ->
        {:error, {:recipe, reason}}
    end
  end

  defp snapshot(sources) do
    case ToolRegistry.snapshot(sources) do
      {:ok, snapshot} -> {:ok, snapshot}
      {:error, reason} -> {:error, {:sources, reason}}
    end
  end

  defp nodes_shape(nodes) do
    if Enum.all?(nodes, &node_shape?/1), do: :ok, else: {:error, :invalid_spec}
  end

  defp node_shape?(node) do
    names = fn slots -> Enum.map(slots, & &1["name"]) end

    not String.contains?(node["id"], ":") and
      case node["kind"] do
        "map" ->
          "items" in names.(node["needs"]) and names.(node["gives"]) -- ["items"] == []

        "ask" ->
          Enum.all?(~w(person_id question), &(&1 in names.(node["needs"]))) and
            names.(node["gives"]) -- ["text"] == []

        _ ->
          true
      end
  end

  defp tools(snapshot, nodes) do
    Enum.reduce_while(nodes, {:ok, %{}}, fn
      %{"kind" => "tool", "id" => id, "tool" => name}, {:ok, tools} ->
        case ToolRegistry.resolve(snapshot, name) do
          {:resolved, tool} ->
            {kind, _, _} = tool.callable
            kind = if kind == :adapter, do: "tool_call", else: "nested_callable"
            entry = {tool.alias, tool.source, tool.tool, tool.version, kind}
            {:cont, {:ok, Map.put(tools, id, entry)}}

          _ ->
            {:halt, {:error, {:unknown_tool, id}}}
        end

      _, acc ->
        {:cont, acc}
    end)
  end

  defp maps(maps, nodes) do
    ids = for %{"kind" => "map", "id" => id} <- nodes, do: id

    if Enum.sort(Map.keys(maps)) == Enum.sort(ids) and Enum.all?(maps, &map_entry?/1),
      do: {:ok, Map.new(maps, fn {id, m} -> {id, {m.concurrency, m.on_item_failure}} end)},
      else: {:error, :invalid_spec}
  end

  defp map_entry?({_, %{} = entry}) when not is_struct(entry) do
    Enum.sort(Map.keys(entry)) == [:concurrency, :on_item_failure] and
      is_integer(entry.concurrency) and entry.concurrency in 1..64 and
      entry.on_item_failure in [:fail, :partial]
  end

  defp map_entry?(_), do: false

  defp nodes(graph, recipe, tools) do
    incoming = Enum.group_by(graph["links"], & &1["to"], &link/1)
    callables = Map.new(recipe["callables"], &{&1["name"], &1})

    Enum.reduce_while(graph["nodes"], {:ok, %{}}, fn node, {:ok, nodes} ->
      case NodeOutcome.routes(graph["links"], node["id"]) do
        {:ok, routes} ->
          spec = %{
            id: node["id"],
            kind: Map.fetch!(@kinds, node["kind"]),
            callable: node["callable"],
            needs: Enum.map(node["needs"], & &1["name"]),
            gives: Enum.map(node["gives"], & &1["name"]),
            tool: tools[node["id"]],
            max: node["max_iterations"],
            choices: if(node["kind"] == "decision", do: callables[node["callable"]]["choices"]),
            routes: routes,
            inc: Map.get(incoming, node["id"], [])
          }

          {:cont, {:ok, Map.put(nodes, node["id"], spec)}}

        _ ->
          {:halt, {:error, :invalid_spec}}
      end
    end)
  end

  defp link(%{"kind" => "data"} = l), do: {:data, l["from"], l["give"], l["need"]}
  defp link(%{"kind" => "order"} = l), do: {:order, l["from"]}
  defp link(%{"kind" => "choice"} = l), do: {:choice, l["from"], l["choice"]}
  defp link(%{"kind" => "outcome"} = l), do: {:outcome, l["from"], l["outcome"]}

  defp sinks(graph) do
    from = MapSet.new(graph["links"], & &1["from"])
    for %{"id" => id} <- graph["nodes"], not MapSet.member?(from, id), do: id
  end
end
