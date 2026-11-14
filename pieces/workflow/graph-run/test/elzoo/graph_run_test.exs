# SPDX-License-Identifier: Apache-2.0
defmodule Elzoo.GraphRunTest do
  use ExUnit.Case, async: false
  import Kernel, except: [node: 3]
  alias Elzoo.{GraphRun, PatternStep, ToolRegistry}

  # Recorded-trace tests: every input is a literal neutral map, every expected request is
  # written by hand, and no model, tool, clock or process is involved.

  @bound 65_536
  @sentinel "SENTINEL-7c1e"
  @uncompleted ~w(failed refused unknown out_of_budget retries_exhausted expired resource_lost)

  ## Recipes

  defp typed(direction) do
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

  defp callable(name, kind, extra),
    do:
      Map.merge(
        %{"name" => name, "kind" => kind, "input" => typed("input"), "output" => typed("output")},
        extra
      )

  defp slot(name), do: %{"name" => name, "schema_id" => "value", "schema_version" => 1}

  defp node(id, kind, needs, gives, extra \\ %{}) do
    base = %{
      "id" => id,
      "kind" => kind,
      "needs" => Enum.map(needs, &slot/1),
      "gives" => Enum.map(gives, &slot/1)
    }

    extra =
      case kind do
        "call" -> %{"callable" => "agent"}
        "decision" -> %{"callable" => "choice"}
        kind when kind in ["map", "loop"] -> %{"callable" => "agent", "max_iterations" => 5}
        _ -> %{}
      end
      |> Map.merge(extra)

    Map.merge(base, extra)
  end

  defp data(from, give, to, need),
    do: %{"from" => from, "to" => to, "kind" => "data", "give" => give, "need" => need}

  defp order(from, to), do: %{"from" => from, "to" => to, "kind" => "order"}

  defp choice(from, to, name),
    do: %{"from" => from, "to" => to, "kind" => "choice", "choice" => name}

  defp route(from, to, class),
    do: %{"from" => from, "to" => to, "kind" => "outcome", "outcome" => class}

  defp recipe(nodes, links, slots) do
    graph =
      callable("main", "graph", %{
        "nodes" => nodes,
        "links" => links,
        "input_slots" => Enum.map(slots, &slot/1)
      })

    %{
      "version" => 1,
      "id" => "recipe",
      "revision" => 1,
      "root" => "main",
      "callables" => [
        graph,
        callable("agent", "agent", %{"binding" => "worker"}),
        callable("choice", "decision", %{"binding" => "worker", "choices" => ["yes", "no"]})
      ],
      "bindings" => [%{"name" => "worker", "target" => "binding"}],
      "rules" => []
    }
  end

  defp spec(recipe, extra \\ %{}),
    do:
      Map.merge(
        %{id: "run", recipe: recipe, callable: "main", sources: [], maps: %{}, max_open: 8},
        extra
      )

  defp build(nodes, links, slots \\ ["x"], extra \\ %{}) do
    assert {:ok, state} = GraphRun.new(spec(recipe(nodes, links, slots), extra))
    state
  end

  ## Inputs

  defp input(kind, fields),
    do: Map.merge(%{"type" => "input", "version" => 1, "kind" => kind, "at_ms" => 1}, fields)

  defp start(values),
    do:
      input("start", %{
        "schema_id" => "elzoo.graph-run.input",
        "schema_version" => 1,
        "payload" => %{"input" => values}
      })

  defp outcome(id, class, payload \\ nil),
    do:
      input("action_outcome", %{
        "action_id" => id,
        "outcome" => class,
        "schema_id" => "elzoo.graph-run.node-result",
        "schema_version" => 1,
        "payload" => payload
      })

  defp done(id, gives, extra \\ %{}),
    do: outcome(id, "completed", Map.merge(%{"gives" => gives}, extra))

  defp answer(id, text),
    do:
      input("person_answer", %{
        "action_id" => id,
        "person_id" => "p1",
        "schema_id" => "elzoo.graph-run.answer",
        "schema_version" => 1,
        "payload" => %{"text" => text}
      })

  defp typed_input(kind),
    do:
      input(kind, %{
        "schema_id" => "elzoo.graph-run.input",
        "schema_version" => 1,
        "payload" => %{"input" => %{}}
      })

  ## Expected requests, written by hand

  defp req(actions), do: %{"type" => "request", "version" => 1, "actions" => actions}

  defp act(id, kind, key, payload),
    do: %{
      "id" => id,
      "kind" => kind,
      "schema_id" => key,
      "schema_version" => 1,
      "payload" => payload
    }

  defp call(id, input, callable \\ "agent"),
    do:
      act("run:n:" <> id, "nested_callable", "elzoo.graph-run.call", %{
        "callable" => callable,
        "input" => input
      })

  defp finish(status, reason, node, action_id, gives),
    do:
      act("run:finish", "finish", "elzoo.graph-run.result", %{
        "status" => status,
        "reason" => reason,
        "node" => node,
        "action_id" => action_id,
        "gives" => gives
      })

  defp completed(action_id, gives), do: finish("completed", nil, nil, action_id, gives)
  defp failed(reason, node), do: finish("failed", reason, node, nil, nil)

  ## Folding a trace

  defp plain?(value) when is_map(value) and not is_struct(value),
    do: Enum.all?(value, fn {k, v} -> plain?(k) and plain?(v) end)

  defp plain?(value) when is_list(value), do: Enum.all?(value, &plain?/1)
  defp plain?(value) when is_tuple(value), do: value |> Tuple.to_list() |> Enum.all?(&plain?/1)
  defp plain?(value), do: is_atom(value) or is_number(value) or is_binary(value)

  defp size(state),
    do: byte_size(:erlang.term_to_binary(state, [:deterministic, {:minor_version, 2}]))

  # Folds step/2 over the inputs. Each state is plain data within the bound, each request
  # passes PatternStep.decode/1, and no action ID appears in two requests of the trace.
  defp fold(state, inputs) do
    {state, steps, _} =
      Enum.reduce(inputs, {state, [], MapSet.new()}, fn input, {state, steps, seen} ->
        assert {:Transition, next, out} = GraphRun.step(state, input)
        assert plain?(next)
        assert size(next) <= @bound

        {request, ids} =
          case out do
            :none ->
              {nil, []}

            {:some, request} ->
              assert {:ok, _} = PatternStep.decode(request)
              {request, Enum.map(request["actions"], & &1["id"])}
          end

        assert ids == Enum.uniq(ids)
        assert MapSet.disjoint?(seen, MapSet.new(ids))
        {next, [request | steps], MapSet.union(seen, MapSet.new(ids))}
      end)

    {state, Enum.reverse(steps)}
  end

  defp run(state, inputs), do: fold(state, inputs) |> elem(1)

  defp unchanged(state, input),
    do: assert(GraphRun.step(state, input) == {:Transition, state, :none})

  defp closed?(state), do: assert(state.phase == :closed)

  defp ids(requests),
    do: for(request <- requests, request != nil, action <- request["actions"], do: action["id"])

  ## Graphs

  # Four nodes, data links only: a and b take the input; c takes a; d takes b and c.
  defp four do
    nodes = [
      node("a", "call", ["x"], ["ga"]),
      node("b", "call", ["x"], ["gb"]),
      node("c", "call", ["ga"], ["gc"]),
      node("d", "call", ["gb", "gc"], ["gd"])
    ]

    links = [
      data("$input", "x", "a", "x"),
      data("$input", "x", "b", "x"),
      data("a", "ga", "c", "ga"),
      data("b", "gb", "d", "gb"),
      data("c", "gc", "d", "gc")
    ]

    build(nodes, links)
  end

  defp four_trace,
    do: [
      start(%{"x" => 1}),
      done("run:n:a", %{"ga" => 10}),
      done("run:n:c", %{"gc" => 20}),
      done("run:n:b", %{"gb" => 30}),
      done("run:n:d", %{"gd" => 40})
    ]

  # A decision selects between two branches of two nodes each; j joins them by order links.
  defp branches do
    nodes = [
      node("pick", "decision", ["x"], []),
      node("y1", "call", [], []),
      node("y2", "call", [], []),
      node("n1", "call", [], []),
      node("n2", "call", [], []),
      node("j", "call", [], ["r"])
    ]

    links = [
      data("$input", "x", "pick", "x"),
      choice("pick", "y1", "yes"),
      choice("pick", "n1", "no"),
      order("y1", "y2"),
      order("n1", "n2"),
      order("y2", "j"),
      order("n2", "j")
    ]

    build(nodes, links)
  end

  defp map_graph(mode, max \\ 5, concurrency \\ 2) do
    nodes = [node("m", "map", ["items", "tag"], ["items"], %{"max_iterations" => max})]

    links = [data("$input", "xs", "m", "items"), data("$input", "tag", "m", "tag")]
    maps = %{"m" => %{concurrency: concurrency, on_item_failure: mode}}
    build(nodes, links, ["xs", "tag"], %{maps: maps})
  end

  defp item(index, value),
    do: call("m:#{index}", %{"tag" => "t", "item" => value, "index" => index})

  defp five, do: start(%{"xs" => ~w(a b c d e), "tag" => "t"})

  defp loop_graph(max) do
    nodes = [node("lp", "loop", ["x"], ["r"], %{"max_iterations" => max})]
    build(nodes, [data("$input", "x", "lp", "x")])
  end

  defp iteration(k, previous),
    do: call("lp:#{k}", %{"x" => 1, "iteration" => k, "previous" => previous})

  defp twice(class, link_class) do
    nodes = [
      node("a", "call", ["x"], ["g"]),
      node("ok", "call", [], ["gok"]),
      node("alt", "call", [], ["galt"])
    ]

    links = [
      data("$input", "x", "a", "x"),
      order("a", "ok"),
      route("a", "alt", link_class)
    ]

    {class, build(nodes, links)}
  end

  # p, q and r take the input; s follows p and w follows r.
  defp fan do
    nodes = [
      node("p", "call", ["x"], ["gp"]),
      node("q", "call", ["x"], ["gq"]),
      node("r", "call", ["x"], ["gr"]),
      node("s", "call", ["gp"], ["gs"]),
      node("w", "call", ["gr"], ["gw"])
    ]

    links = [
      data("$input", "x", "p", "x"),
      data("$input", "x", "q", "x"),
      data("$input", "x", "r", "x"),
      data("p", "gp", "s", "gp"),
      data("r", "gr", "w", "gr")
    ]

    build(nodes, links)
  end

  defp fan_start, do: req([call("p", %{"x" => 1}), call("q", %{"x" => 1}), call("r", %{"x" => 1})])

  ## The ten groups

  describe "needs_and_gives_only" do
    test "four nodes with data links run in data order and finish with the gives of the last node" do
      requests = run(four(), four_trace())

      assert requests == [
               req([call("a", %{"x" => 1}), call("b", %{"x" => 1})]),
               req([call("c", %{"ga" => 10})]),
               nil,
               req([call("d", %{"gb" => 30, "gc" => 20})]),
               req([completed("run:n:d", %{"gd" => 40})])
             ]
    end

    test "only the declared give names are kept, and a node that lacks one fails" do
      requests =
        run(four(), [
          start(%{"x" => 1}),
          done("run:n:a", %{"ga" => 10, "extra" => @sentinel}),
          done("run:n:c", %{"gc" => 20}),
          done("run:n:b", %{"gb" => 30}),
          done("run:n:d", %{"gd" => 40, "extra" => @sentinel})
        ])

      assert List.last(requests) == req([completed("run:n:d", %{"gd" => 40})])
      refute inspect(requests) =~ @sentinel

      requests = run(four(), [start(%{"x" => 1}), done("run:n:a", %{"other" => 1})])
      assert requests == [req([call("a", %{"x" => 1}), call("b", %{"x" => 1})]), nil]
    end

    test "a tool node asks for the resolved tool, as a tool call or as a nested callable" do
      desc = fn name ->
        %{
          "trust" => "untrusted",
          "name" => name,
          "description" => "Tool " <> name,
          "input_schema" => %{"type" => "object"},
          "annotations" => nil
        }
      end

      sources = [
        %{"id" => "files", "kind" => "other", "callable" => "adapter", "tools" => [desc.("read")]},
        %{"id" => "sub", "kind" => "other", "callable" => "nested", "tools" => [desc.("plan")]}
      ]

      {:ok, snapshot} = ToolRegistry.snapshot(sources)
      {:resolved, read} = ToolRegistry.resolve(snapshot, "files_read")
      {:resolved, plan} = ToolRegistry.resolve(snapshot, "sub_plan")

      nodes = [
        node("t1", "tool", ["x"], ["r"], %{"tool" => "files_read"}),
        node("t2", "tool", ["r"], ["s"], %{"tool" => "sub_plan"})
      ]

      links = [data("$input", "x", "t1", "x"), data("t1", "r", "t2", "r")]
      state = build(nodes, links, ["x"], %{sources: sources})

      payload = fn tool, arguments ->
        %{
          "alias" => tool.alias,
          "source" => tool.source,
          "tool" => tool.tool,
          "version" => tool.version,
          "arguments" => arguments
        }
      end

      requests =
        run(state, [
          start(%{"x" => 1}),
          done("run:n:t1", %{"r" => 2}),
          done("run:n:t2", %{"s" => 3})
        ])

      assert requests == [
               req([
                 act(
                   "run:n:t1",
                   "tool_call",
                   "elzoo.graph-run.tool-call",
                   payload.(read, %{"x" => 1})
                 )
               ]),
               req([
                 act(
                   "run:n:t2",
                   "nested_callable",
                   "elzoo.graph-run.tool-call",
                   payload.(plan, %{"r" => 2})
                 )
               ]),
               req([completed("run:n:t2", %{"s" => 3})])
             ]
    end

    test "an ask node asks only its two needs, and the person answer is its text" do
      nodes = [
        node("ask", "ask", ["person_id", "question"], ["text"]),
        node("use", "call", ["text"], ["r"])
      ]

      links = [
        data("$input", "who", "ask", "person_id"),
        data("$input", "q", "ask", "question"),
        data("ask", "text", "use", "text")
      ]

      state = build(nodes, links, ["who", "q"])

      ask =
        act("run:n:ask", "ask_person", "elzoo.graph-run.ask", %{
          "person_id" => "p1",
          "question" => "Go?"
        })

      {open, [first]} = fold(state, [start(%{"who" => "p1", "q" => "Go?"})])
      assert first == req([ask])

      # a completed outcome of an ask is no change; a failed one fails the node
      unchanged(open, done("run:n:ask", %{"text" => "x"}))
      unchanged(open, outcome("run:n:ask", "completed"))

      requests =
        run(state, [
          start(%{"who" => "p1", "q" => "Go?"}),
          answer("run:n:ask", "yes"),
          done("run:n:use", %{"r" => 1})
        ])

      assert requests == [
               req([ask]),
               req([call("use", %{"text" => "yes"})]),
               req([completed("run:n:use", %{"r" => 1})])
             ]

      requests =
        run(state, [start(%{"who" => "p1", "q" => "Go?"}), outcome("run:n:ask", "expired")])

      assert requests == [req([ask]), req([failed("no_outcome_link", "ask")])]

      # an answer that is not the text form fails the node
      bad =
        input("person_answer", %{
          "action_id" => "run:n:ask",
          "person_id" => "p1",
          "schema_id" => "other",
          "schema_version" => 1,
          "payload" => %{}
        })

      requests = run(state, [start(%{"who" => "p1", "q" => "Go?"}), bad])
      assert requests == [req([ask]), req([failed("no_outcome_link", "ask")])]
    end
  end

  describe "decision_branch_and_join" do
    test "the yes branch runs, the no branch is skipped and the join runs when yes completes" do
      requests =
        run(branches(), [
          start(%{"x" => 1}),
          done("run:n:pick", %{}, %{"choice" => "yes"}),
          done("run:n:y1", %{}),
          done("run:n:y2", %{}),
          done("run:n:j", %{"r" => "joined"})
        ])

      assert requests == [
               req([call("pick", %{"x" => 1}, "choice")]),
               req([call("y1", %{})]),
               req([call("y2", %{})]),
               req([call("j", %{})]),
               req([completed("run:n:j", %{"r" => "joined"})])
             ]

      refute Enum.any?(ids(requests), &(&1 in ["run:n:n1", "run:n:n2"]))
    end

    test "the same graph with the other choice" do
      requests =
        run(branches(), [
          start(%{"x" => 1}),
          done("run:n:pick", %{}, %{"choice" => "no"}),
          done("run:n:n1", %{}),
          done("run:n:n2", %{}),
          done("run:n:j", %{"r" => "joined"})
        ])

      assert requests == [
               req([call("pick", %{"x" => 1}, "choice")]),
               req([call("n1", %{})]),
               req([call("n2", %{})]),
               req([call("j", %{})]),
               req([completed("run:n:j", %{"r" => "joined"})])
             ]

      refute Enum.any?(ids(requests), &(&1 in ["run:n:y1", "run:n:y2"]))
    end

    test "a branch that does not complete skips the join; a choice that is not declared fails the node" do
      requests =
        run(branches(), [
          start(%{"x" => 1}),
          done("run:n:pick", %{}, %{"choice" => "yes"}),
          outcome("run:n:y1", "failed")
        ])

      assert Enum.at(requests, 2) == req([failed("no_outcome_link", "y1")])

      requests =
        run(branches(), [start(%{"x" => 1}), done("run:n:pick", %{}, %{"choice" => "maybe"})])

      assert requests == [
               req([call("pick", %{"x" => 1}, "choice")]),
               req([failed("no_outcome_link", "pick")])
             ]

      # a decision outcome with no choice at all is not the completed form either
      requests = run(branches(), [start(%{"x" => 1}), done("run:n:pick", %{})])
      assert List.last(requests) == req([failed("no_outcome_link", "pick")])
    end
  end

  describe "map_bounds_and_part_failure" do
    test "partial: 5 items, concurrency 2, never more than 2 open, 5 entries in index order" do
      inputs = [
        five(),
        done("run:n:m:0", %{"v" => 0}),
        outcome("run:n:m:1", "failed"),
        done("run:n:m:2", %{"v" => 2}),
        outcome("run:n:m:3", "refused"),
        done("run:n:m:4", %{"v" => 4})
      ]

      requests = run(map_graph(:partial), inputs)

      assert requests == [
               req([item(0, "a"), item(1, "b")]),
               req([item(2, "c")]),
               req([item(3, "d")]),
               req([item(4, "e")]),
               nil,
               req([
                 completed("run:n:m:4", %{
                   "items" => [
                     %{"index" => 0, "status" => "completed", "gives" => %{"v" => 0}},
                     %{"index" => 1, "status" => "failed"},
                     %{"index" => 2, "status" => "completed", "gives" => %{"v" => 2}},
                     %{"index" => 3, "status" => "refused"},
                     %{"index" => 4, "status" => "completed", "gives" => %{"v" => 4}}
                   ]
                 })
               ])
             ]

      assert max_open(inputs, requests) == 2
    end

    test "fail: the first failed item stops further starts and the node fails" do
      inputs = [
        five(),
        done("run:n:m:0", %{"v" => 0}),
        outcome("run:n:m:1", "failed"),
        done("run:n:m:2", %{"v" => 2})
      ]

      requests = run(map_graph(:fail), inputs)

      assert requests == [
               req([item(0, "a"), item(1, "b")]),
               req([item(2, "c")]),
               nil,
               req([failed("no_outcome_link", "m")])
             ]

      assert max_open(inputs, requests) == 2
    end

    test "fail: every item completed gives the node completed" do
      inputs = [five()] ++ for i <- 0..4, do: done("run:n:m:#{i}", %{"v" => i})
      requests = run(map_graph(:fail), inputs)

      assert List.last(requests) |> Map.fetch!("actions") |> hd() |> get_in(["payload", "status"]) ==
               "completed"

      assert length(Enum.reject(requests, &is_nil/1)) == 5
    end

    test "partial: every item failed fails the node" do
      inputs = [five()] ++ for i <- 0..4, do: outcome("run:n:m:#{i}", "failed")
      requests = run(map_graph(:partial), inputs)

      assert requests == [
               req([item(0, "a"), item(1, "b")]),
               req([item(2, "c")]),
               req([item(3, "d")]),
               req([item(4, "e")]),
               nil,
               req([failed("no_outcome_link", "m")])
             ]
    end

    test "an empty list is done at once; a list of max_iterations items runs; one more fails" do
      empty = start(%{"xs" => [], "tag" => "t"})
      assert run(map_graph(:partial), [empty]) == [req([completed(nil, %{"items" => []})])]

      inputs =
        [start(%{"xs" => ~w(a b c), "tag" => "t"})] ++ for i <- 0..2, do: done("run:n:m:#{i}", %{})

      requests = run(map_graph(:partial, 3, 3), inputs)
      assert length(Enum.at(requests, 0)["actions"]) == 3

      assert List.last(requests) |> Map.fetch!("actions") |> hd() |> get_in(["payload", "status"]) ==
               "completed"

      too_many = start(%{"xs" => ~w(a b c d), "tag" => "t"})
      assert run(map_graph(:partial, 3, 3), [too_many]) == [req([failed("no_outcome_link", "m")])]
    end

    test "a value that is not a list fails the node without an action" do
      for bad <- ["abc", 7, nil, %{"a" => 1}] do
        assert run(map_graph(:partial), [start(%{"xs" => bad, "tag" => "t"})]) ==
                 [req([failed("no_outcome_link", "m")])]
      end
    end

    test "a completed item without the node-result form counts as a failed item" do
      inputs = [five(), outcome("run:n:m:0", "completed", %{"gives" => "not an object"})]
      requests = run(map_graph(:fail), inputs)
      assert requests == [req([item(0, "a"), item(1, "b")]), nil]
    end

    test "partial: the finish names the item that truly completed last, not a malformed completed one" do
      inputs = [
        five(),
        done("run:n:m:0", %{"v" => 0}),
        outcome("run:n:m:1", "failed"),
        done("run:n:m:2", %{"v" => 2}),
        done("run:n:m:3", %{"v" => 3}),
        outcome("run:n:m:4", "completed", %{"gives" => "not an object"})
      ]

      assert List.last(run(map_graph(:partial), inputs)) ==
               req([
                 completed("run:n:m:3", %{
                   "items" => [
                     %{"index" => 0, "status" => "completed", "gives" => %{"v" => 0}},
                     %{"index" => 1, "status" => "failed"},
                     %{"index" => 2, "status" => "completed", "gives" => %{"v" => 2}},
                     %{"index" => 3, "status" => "completed", "gives" => %{"v" => 3}},
                     %{"index" => 4, "status" => "failed"}
                   ]
                 })
               ])
    end

    # open actions after each step: requests add, an applied outcome of an open action removes
    defp max_open(inputs, requests) do
      {_, max} =
        inputs
        |> Enum.zip(requests)
        |> Enum.reduce({MapSet.new(), 0}, fn {input, request}, {open, max} ->
          open =
            if input["kind"] == "action_outcome",
              do: MapSet.delete(open, input["action_id"]),
              else: open

          open =
            Enum.reduce(if(request, do: request["actions"], else: []), open, fn action, acc ->
              if action["kind"] == "finish", do: acc, else: MapSet.put(acc, action["id"])
            end)

          {open, max(max, MapSet.size(open))}
        end)

      max
    end
  end

  describe "loop_bounded" do
    test "a loop that ends with continue false at iteration 2" do
      requests =
        run(loop_graph(3), [
          start(%{"x" => 1}),
          done("run:n:lp:1", %{"r" => "one"}, %{"continue" => true}),
          done("run:n:lp:2", %{"r" => "two"}, %{"continue" => false})
        ])

      assert requests == [
               req([iteration(1, nil)]),
               req([iteration(2, %{"r" => "one"})]),
               req([completed("run:n:lp:2", %{"r" => "two"})])
             ]
    end

    test "max_iterations 3 with every iteration true ends completed after exactly 3 actions" do
      inputs = [
        start(%{"x" => 1})
        | for(k <- 1..3, do: done("run:n:lp:#{k}", %{"r" => k}, %{"continue" => true}))
      ]

      requests = run(loop_graph(3), inputs)

      assert requests == [
               req([iteration(1, nil)]),
               req([iteration(2, %{"r" => 1})]),
               req([iteration(3, %{"r" => 2})]),
               req([completed("run:n:lp:3", %{"r" => 3})])
             ]

      assert length(ids(requests) -- ["run:finish"]) == 3
    end

    test "a failed iteration, and one that is not in the completed form, fails the node" do
      requests =
        run(loop_graph(3), [
          start(%{"x" => 1}),
          done("run:n:lp:1", %{"r" => 1}, %{"continue" => true}),
          outcome("run:n:lp:2", "failed")
        ])

      assert Enum.at(requests, 2) == req([failed("no_outcome_link", "lp")])

      for payload <- [
            %{"gives" => %{"r" => 1}},
            %{"gives" => %{"r" => 1}, "continue" => "yes"},
            %{"gives" => %{}, "continue" => true}
          ] do
        requests =
          run(loop_graph(3), [start(%{"x" => 1}), outcome("run:n:lp:1", "completed", payload)])

        assert requests == [req([iteration(1, nil)]), req([failed("no_outcome_link", "lp")])]
      end
    end
  end

  describe "each_outcome_link" do
    test "an uncompleted class with a route starts the target and skips the ordinary successor" do
      for class <- @uncompleted do
        {_, state} = twice(class, class)

        requests =
          run(state, [
            start(%{"x" => 1}),
            outcome("run:n:a", class),
            done("run:n:alt", %{"galt" => 5})
          ])

        assert requests == [
                 req([call("a", %{"x" => 1})]),
                 req([call("alt", %{})]),
                 req([completed("run:n:alt", %{"galt" => 5})])
               ]

        refute "run:n:ok" in ids(requests)
      end
    end

    test "a route of another class is not taken" do
      {_, state} = twice("failed", "refused")
      requests = run(state, [start(%{"x" => 1}), outcome("run:n:a", "failed")])
      assert requests == [req([call("a", %{"x" => 1})]), req([failed("no_outcome_link", "a")])]
    end

    test "a completed route starts its target and the ordinary successors" do
      {_, state} = twice("completed", "completed")

      requests =
        run(state, [
          start(%{"x" => 1}),
          done("run:n:a", %{"g" => 1}),
          done("run:n:alt", %{"galt" => 5}),
          done("run:n:ok", %{"gok" => 6})
        ])

      assert requests == [
               req([call("a", %{"x" => 1})]),
               req([call("ok", %{}), call("alt", %{})]),
               nil,
               req([completed("run:n:ok", %{"gok" => 6, "galt" => 5})])
             ]
    end

    test "without a completed route the target of an outcome link is skipped after completion" do
      {_, state} = twice("completed", "failed")

      requests =
        run(state, [
          start(%{"x" => 1}),
          done("run:n:a", %{"g" => 1}),
          done("run:n:ok", %{"gok" => 6})
        ])

      assert requests == [
               req([call("a", %{"x" => 1})]),
               req([call("ok", %{})]),
               req([completed("run:n:ok", %{"gok" => 6})])
             ]
    end
  end

  describe "missing_outcome_link_fails_run" do
    test "each uncompleted class with no route fails the Run after the open actions settle" do
      for class <- @uncompleted do
        requests =
          run(fan(), [
            start(%{"x" => 1}),
            done("run:n:p", %{"gp" => 2}),
            outcome("run:n:q", class),
            done("run:n:r", %{"gr" => 3}),
            done("run:n:s", %{"gs" => 4})
          ])

        assert requests == [
                 fan_start(),
                 req([call("s", %{"gp" => 2})]),
                 nil,
                 nil,
                 req([failed("no_outcome_link", "q")])
               ]

        # w follows r, and no node starts after the failure
        refute "run:n:w" in ids(requests)
      end
    end

    test "the first failing node in the order of the nodes list is named" do
      requests =
        run(fan(), [
          start(%{"x" => 1}),
          done("run:n:p", %{"gp" => 2}),
          done("run:n:s", %{"gs" => 4}),
          outcome("run:n:r", "failed"),
          outcome("run:n:q", "unknown")
        ])

      assert List.last(requests) == req([failed("no_outcome_link", "q")])
    end

    test "unknown starts no second try, with or without other open actions" do
      requests = run(fan(), [start(%{"x" => 1}), outcome("run:n:q", "unknown")])
      assert requests == [fan_start(), nil]

      requests =
        run(fan(), [
          start(%{"x" => 1}),
          outcome("run:n:q", "unknown"),
          outcome("run:n:p", "unknown"),
          outcome("run:n:r", "unknown")
        ])

      assert requests == [fan_start(), nil, nil, req([failed("no_outcome_link", "p")])]
      assert ids(requests) == ["run:n:p", "run:n:q", "run:n:r", "run:finish"]
    end
  end

  describe "settled_node_never_runs_again" do
    test "the trace cut at each position and folded again gives the same states and requests" do
      {full, requests} = fold(four(), four_trace())
      closed?(full)

      for cut <- 0..length(four_trace()) do
        {state, folded} = fold(four(), Enum.take(four_trace(), cut))
        assert folded == Enum.take(requests, cut)

        {again, _} = fold(four(), Enum.take(four_trace(), cut))
        assert again == state
      end
    end

    test "a second outcome, a late outcome and an outcome of an unknown action change nothing" do
      trace = four_trace()

      for cut <- 1..length(trace) do
        taken = Enum.take(trace, cut)
        {state, requests} = fold(four(), taken)

        settled = for %{"kind" => "action_outcome"} = input <- taken, do: input
        open = ids(requests) -- Enum.map(settled, & &1["action_id"])

        for input <- settled, do: unchanged(state, input)
        for id <- open, do: unchanged(state, outcome(id, "late"))
        unchanged(state, done("run:n:nope", %{"ga" => 1}))
        unchanged(state, outcome("run:n:nope", "failed"))
      end
    end

    test "a node that settled with an outcome that has a route is never asked again" do
      {_, state} = twice("failed", "failed")

      trace = [start(%{"x" => 1}), outcome("run:n:a", "failed"), done("run:n:alt", %{"galt" => 1})]
      requests = run(state, trace)
      assert ids(requests) == ["run:n:a", "run:n:alt", "run:finish"]

      {mid, _} = fold(state, Enum.take(trace, 2))
      unchanged(mid, outcome("run:n:a", "failed"))
      unchanged(mid, done("run:n:a", %{"g" => 1}))
    end
  end

  describe "arrival_order" do
    # a, b and c are open together; e follows a; d joins b, c and e.
    defp together do
      nodes = [
        node("a", "call", ["x"], ["ga"]),
        node("b", "call", ["x"], ["gb"]),
        node("c", "call", ["x"], ["gc"]),
        node("e", "call", ["ga"], ["ge"]),
        node("d", "call", ["gb", "gc", "ge"], ["gd"])
      ]

      links = [
        data("$input", "x", "a", "x"),
        data("$input", "x", "b", "x"),
        data("$input", "x", "c", "x"),
        data("a", "ga", "e", "ga"),
        data("b", "gb", "d", "gb"),
        data("c", "gc", "d", "gc"),
        data("e", "ge", "d", "ge")
      ]

      build(nodes, links)
    end

    defp permutations([]), do: [[]]
    defp permutations(list), do: for(x <- list, rest <- permutations(list -- [x]), do: [x | rest])

    test "each of the six orders gives the same set of actions and the same finish" do
      results =
        for order <- permutations(["a", "b", "c"]) do
          outcomes = for id <- order, do: done("run:n:#{id}", %{"g#{id}" => id})

          inputs =
            [start(%{"x" => 1})] ++
              outcomes ++ [done("run:n:e", %{"ge" => "e"}), done("run:n:d", %{"gd" => "d"})]

          {state, requests} = fold(together(), inputs)
          closed?(state)

          actions =
            for request <- requests, request != nil, action <- request["actions"], do: action

          {Enum.sort_by(actions, & &1["id"]), List.last(requests)}
        end

      [{set, finish} | rest] = results
      assert length(rest) == 5
      assert Enum.all?(rest, &(&1 == {set, finish}))
      assert finish == req([completed("run:n:d", %{"gd" => "d"})])

      assert Enum.map(set, & &1["id"]) ==
               ~w(run:finish run:n:a run:n:b run:n:c run:n:d run:n:e)

      d = Enum.find(set, &(&1["id"] == "run:n:d"))
      assert d == call("d", %{"gb" => "b", "gc" => "c", "ge" => "e"})
    end

    test "the grouping of requests differs with the order while the set does not" do
      first = run(together(), [start(%{"x" => 1}), done("run:n:a", %{"ga" => "a"})])
      second = run(together(), [start(%{"x" => 1}), done("run:n:b", %{"gb" => "b"})])
      assert Enum.at(first, 1) == req([call("e", %{"ga" => "a"})])
      assert Enum.at(second, 1) == nil
    end
  end

  describe "nested_graph_gets_only_its_input" do
    test "a call action holds exactly callable and the needs of the node" do
      nodes = [
        node("o", "call", ["secret"], ["leak"]),
        node("c", "call", ["x"], ["r"]),
        node("d", "call", ["r"], ["out"])
      ]

      links = [
        data("$input", "secret", "o", "secret"),
        data("$input", "x", "c", "x"),
        data("c", "r", "d", "r")
      ]

      state = build(nodes, links, ["x", "secret"])

      requests =
        run(state, [
          start(%{"x" => 1, "secret" => @sentinel}),
          done("run:n:o", %{"leak" => @sentinel}),
          done("run:n:c", %{"r" => 2}),
          done("run:n:d", %{"out" => 3})
        ])

      assert Enum.at(requests, 0)["actions"] == [
               call("o", %{"secret" => @sentinel}),
               call("c", %{"x" => 1})
             ]

      assert Enum.at(requests, 2) == req([call("d", %{"r" => 2})])

      for request <- requests, request != nil, action <- request["actions"] do
        if action["kind"] == "nested_callable" do
          assert Enum.sort(Map.keys(action["payload"])) == ["callable", "input"]
        end
      end

      # the sentinel is only where a need names it
      assert Enum.at(requests, 1) == nil
      refute inspect(Enum.at(requests, 2)) =~ @sentinel

      # o is a last node, so its give is in the finish by the finish rule, and only there
      assert Enum.at(requests, 3) == req([completed("run:n:d", %{"leak" => @sentinel, "out" => 3})])
    end
  end

  describe "new_refusals_and_closed" do
    defp simple,
      do: recipe([node("a", "call", ["x"], ["g"])], [data("$input", "x", "a", "x")], ["x"])

    defp ask_recipe(needs, gives),
      do:
        recipe(
          [node("k", "ask", needs, gives)],
          Enum.map(needs, &data("$input", &1, "k", &1)),
          needs
        )

    defp map_recipe(needs, gives),
      do:
        recipe(
          [node("m", "map", needs, gives)],
          Enum.map(needs, &data("$input", &1, "m", &1)),
          needs
        )

    test "each refusal of new/1" do
      base = spec(simple())
      assert {:ok, _} = GraphRun.new(base)

      for bad <- [
            nil,
            [],
            "spec",
            %{},
            Map.delete(base, :max_open),
            Map.put(base, :extra, 1),
            %{base | id: ""},
            %{base | id: "a:b"},
            %{base | id: String.duplicate("a", 65)},
            %{base | id: 5},
            %{base | id: <<255>>},
            %{base | max_open: 0},
            %{base | max_open: 65},
            %{base | max_open: 1.0},
            %{base | maps: nil},
            %{base | callable: 5},
            # map nodes
            spec(map_recipe(["items"], ["items"])),
            spec(map_recipe(["items"], ["items"]), %{
              maps: %{"zz" => %{concurrency: 1, on_item_failure: :fail}}
            }),
            spec(map_recipe(["items"], ["items"]), %{
              maps: %{"m" => %{concurrency: 0, on_item_failure: :fail}}
            }),
            spec(map_recipe(["items"], ["items"]), %{
              maps: %{"m" => %{concurrency: 65, on_item_failure: :fail}}
            }),
            spec(map_recipe(["items"], ["items"]), %{
              maps: %{"m" => %{concurrency: 1, on_item_failure: :retry}}
            }),
            spec(map_recipe(["items"], ["items"]), %{maps: %{"m" => %{concurrency: 1}}}),
            spec(map_recipe(["items"], ["items"]), %{
              maps: %{"m" => %{concurrency: 1, on_item_failure: :fail, extra: 1}}
            }),
            spec(map_recipe(["other"], ["items"]), %{
              maps: %{"m" => %{concurrency: 1, on_item_failure: :fail}}
            }),
            spec(map_recipe(["items"], ["items", "more"]), %{
              maps: %{"m" => %{concurrency: 1, on_item_failure: :fail}}
            }),
            # ask nodes
            spec(ask_recipe(["person_id"], ["text"])),
            spec(ask_recipe(["person_id", "question"], ["text", "more"])),
            spec(ask_recipe(["question", "other"], ["text"])),
            # a node ID that holds a colon
            spec(recipe([node("a:b", "call", [], [])], [], []))
          ] do
        assert GraphRun.new(bad) == {:error, :invalid_spec}
      end

      assert {:ok, _} =
               GraphRun.new(
                 spec(map_recipe(["items"], ["items"]), %{
                   maps: %{"m" => %{concurrency: 64, on_item_failure: :partial}}
                 })
               )

      assert {:ok, _} = GraphRun.new(spec(ask_recipe(["person_id", "question"], ["text"])))
      assert GraphRun.new(%{base | callable: "nope"}) == {:error, :unknown_callable}
      assert GraphRun.new(%{base | callable: "agent"}) == {:error, :unknown_callable}

      assert GraphRun.new(%{base | recipe: Map.put(simple(), "version", 2)}) ==
               {:error, {:recipe, :unsupported_version}}

      assert GraphRun.new(%{base | recipe: nil}) == {:error, {:recipe, :invalid_shape}}
      assert GraphRun.new(%{base | sources: nil}) == {:error, {:sources, :invalid_source}}

      tool = recipe([node("t", "tool", [], [], %{"tool" => "nope_tool"})], [], [])
      assert GraphRun.new(spec(tool)) == {:error, {:unknown_tool, "t"}}

      long = for i <- 1..300, do: node(String.duplicate("n", 120) <> "#{i}", "call", [], [])
      assert GraphRun.new(spec(recipe(long, [], []))) == {:error, :state_too_large}
    end

    test "cancel and run_ended close the step, with no request" do
      for kind <- ["cancel", "run_ended"] do
        stop =
          if kind == "cancel",
            do: input("cancel", %{"attempt_id" => "attempt-1"}),
            else: typed_input("run_ended")

        # new
        {state, [nil]} = fold(four(), [stop])
        closed?(state)
        every_input_is_no_change(state)

        # running
        {running, _} = fold(four(), [start(%{"x" => 1})])
        {state, [nil]} = fold(running, [stop])
        closed?(state)
        every_input_is_no_change(state)
      end
    end

    defp every_input_is_no_change(state) do
      for input <- [
            start(%{"x" => 1}),
            typed_input("message"),
            typed_input("resource_event"),
            typed_input("run_ended"),
            input("cancel", %{"attempt_id" => "attempt-1"}),
            input("wake", %{}),
            done("run:n:a", %{"ga" => 1}),
            outcome("run:n:a", "failed"),
            answer("run:n:a", "text")
          ],
          do: unchanged(state, input)
    end

    test "each input of the no-change row leaves a running step as it was" do
      {running, [first]} = fold(four(), [start(%{"x" => 1})])
      assert first == req([call("a", %{"x" => 1}), call("b", %{"x" => 1})])

      for input <- [
            typed_input("message"),
            typed_input("resource_event"),
            input("wake", %{}),
            start(%{"x" => 1}),
            outcome("run:n:a", "late"),
            done("run:n:nope", %{}),
            done("run:n:c", %{"gc" => 1}),
            answer("run:n:a", "text"),
            %{"type" => "input", "kind" => "bogus"},
            %{"type" => "input", "version" => 1, "kind" => "action_outcome"},
            nil,
            "start",
            []
          ],
          do: unchanged(running, input)

      # a settled action is not open
      {settled, _} = fold(four(), [start(%{"x" => 1}), done("run:n:a", %{"ga" => 1})])
      unchanged(settled, done("run:n:a", %{"ga" => 2}))

      # a step that has not started takes no outcome
      unchanged(four(), done("run:n:a", %{"ga" => 1}))
      unchanged(four(), typed_input("message"))
    end

    test "a start in another form finishes failed with invalid_input" do
      bad = [
        %{"input" => %{}},
        %{"input" => %{"x" => 1, "extra" => 2}},
        %{"input" => 5},
        %{"input" => %{"x" => 1}, "more" => 1},
        %{"other" => %{"x" => 1}},
        nil
      ]

      for payload <- bad do
        input = start(%{}) |> Map.put("payload", payload)
        {state, requests} = fold(four(), [input])
        assert requests == [req([failed("invalid_input", nil)])]
        closed?(state)
      end

      wrong = start(%{"x" => 1}) |> Map.put("schema_id", "elzoo.graph-run.other")
      assert run(four(), [wrong]) == [req([failed("invalid_input", nil)])]

      assert run(four(), [Map.put(start(%{"x" => 1}), "schema_version", 2)]) == [
               req([failed("invalid_input", nil)])
             ]
    end

    test "two last nodes that give one name are ambiguous_output" do
      nodes = [node("a", "call", ["x"], ["v"]), node("b", "call", ["x"], ["v"])]
      links = [data("$input", "x", "a", "x"), data("$input", "x", "b", "x")]

      requests =
        run(build(nodes, links), [
          start(%{"x" => 1}),
          done("run:n:a", %{"v" => 1}),
          done("run:n:b", %{"v" => 2})
        ])

      assert requests == [
               req([call("a", %{"x" => 1}), call("b", %{"x" => 1})]),
               nil,
               req([failed("ambiguous_output", nil)])
             ]
    end

    test "a graph without a node finishes with no action_id, and a skipped last node gives nothing" do
      assert run(build([], [], []), [start(%{})]) == [req([completed(nil, %{})])]

      nodes = [node("a", "call", ["x"], ["g"]), node("b", "call", [], ["gb"])]
      links = [data("$input", "x", "a", "x"), route("a", "b", "failed")]
      requests = run(build(nodes, links), [start(%{"x" => 1}), outcome("run:n:a", "failed")])
      assert Enum.at(requests, 1) == req([call("b", %{})])

      nodes = [node("a", "call", [], ["g"]), node("b", "call", [], ["gb"])]

      requests =
        run(build(nodes, [route("a", "b", "failed")], []), [
          start(%{}),
          done("run:n:a", %{"g" => 1})
        ])

      assert requests == [req([call("a", %{})]), req([completed("run:n:a", %{})])]
    end

    test "a state over the bound finishes failed with state_over_bound" do
      big = String.duplicate("x", 70_000)
      assert run(four(), [start(%{"x" => big})]) == [req([failed("state_over_bound", nil)])]

      nodes = [node("a", "call", ["x"], ["ga"]), node("b", "call", ["ga"], ["gb"])]
      links = [data("$input", "x", "a", "x"), data("a", "ga", "b", "ga")]

      {state, requests} =
        fold(build(nodes, links), [start(%{"x" => 1}), done("run:n:a", %{"ga" => big})])

      assert requests == [req([call("a", %{"x" => 1})]), req([failed("state_over_bound", nil)])]
      closed?(state)
    end

    test "max_open 1 runs a wide graph one action at a time" do
      nodes = for id <- ~w(a b c d), do: node(id, "call", ["x"], ["g#{id}"])
      links = for id <- ~w(a b c d), do: data("$input", "x", id, "x")

      requests =
        run(build(nodes, links, ["x"], %{max_open: 1}), [
          start(%{"x" => 1}),
          done("run:n:a", %{"ga" => 1}),
          done("run:n:b", %{"gb" => 2}),
          done("run:n:c", %{"gc" => 3}),
          done("run:n:d", %{"gd" => 4})
        ])

      assert requests == [
               req([call("a", %{"x" => 1})]),
               req([call("b", %{"x" => 1})]),
               req([call("c", %{"x" => 1})]),
               req([call("d", %{"x" => 1})]),
               req([completed("run:n:d", %{"ga" => 1, "gb" => 2, "gc" => 3, "gd" => 4})])
             ]
    end

    test "the checked example of the public API" do
      {result, _} = Code.eval_file(Path.expand("../../examples/elzoo/graph_run.exs", __DIR__))

      assert {:ok, _, first, second, last} = result
      assert first["actions"] |> Enum.map(& &1["id"]) == ["demo:n:greet"]
      assert second["actions"] |> Enum.map(& &1["id"]) == ["demo:n:shout"]
      assert last["actions"] |> Enum.map(& &1["id"]) == ["demo:finish"]
      assert last["actions"] |> hd() |> get_in(["payload", "status"]) == "completed"
    end
  end
end
