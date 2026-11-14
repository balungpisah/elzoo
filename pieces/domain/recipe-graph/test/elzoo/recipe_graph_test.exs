# SPDX-License-Identifier: Apache-2.0
defmodule Elzoo.RecipeGraphTest do
  use ExUnit.Case, async: false
  import Kernel, except: [node: 1]
  import ExUnit.CaptureLog
  alias Elzoo.{Approval, Authorization, RecipeGraph}

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

  defp callable(name \\ "main", kind \\ "graph") do
    base = %{"name" => name, "kind" => kind, "input" => typed("input"), "output" => typed("output")}

    case kind do
      "graph" -> Map.merge(base, %{"nodes" => [], "links" => [], "input_slots" => []})
      "agent" -> Map.put(base, "binding", "worker")
      "decision" -> Map.merge(base, %{"binding" => "worker", "choices" => ["yes", "no"]})
    end
  end

  defp recipe(callables \\ [callable()]) do
    %{
      "version" => 1,
      "id" => "recipe",
      "revision" => 1,
      "root" => hd(callables)["name"],
      "callables" => callables,
      "bindings" => [%{"name" => "worker", "target" => "binding"}],
      "rules" => []
    }
  end

  defp node(id, kind \\ "ask", extra \\ %{}),
    do: Map.merge(%{"id" => id, "kind" => kind, "needs" => [], "gives" => []}, extra)

  defp slot(name \\ "value"), do: %{"name" => name, "schema_id" => "value", "schema_version" => 1}

  defp link(from, to, kind \\ "order", extra \\ %{}),
    do: Map.merge(%{"from" => from, "to" => to, "kind" => kind}, extra)

  defp graph(nodes, links \\ [], inputs \\ []),
    do: Map.merge(callable(), %{"nodes" => nodes, "links" => links, "input_slots" => inputs})

  defp roundtrip(map) do
    assert {:ok, checked} = RecipeGraph.decode(map)
    assert RecipeGraph.encode(checked) === map
    checked
  end

  defp refused(map, reason \\ nil) do
    assert {:error, actual} = RecipeGraph.decode(map)
    if reason, do: assert(actual == reason)
    actual
  end

  defp branches do
    nodes = [node("choose", "decision", %{"callable" => "choice"}), node("yes"), node("no")]
    links = for choice <- ~w(yes no), do: link("choose", choice, "choice", %{"choice" => choice})
    recipe([graph(nodes, links), callable("choice", "decision")])
  end

  describe "three_callable_six_node_kinds" do
    test "three roots and six node kinds retain identity and separate bindings" do
      for kind <- ~w(graph agent decision), do: roundtrip(recipe([callable("root", kind)]))

      nodes = [
        node("call", "call", %{"callable" => "agent"}),
        node("tool", "tool", %{"tool" => "tool"}),
        node("ask"),
        node("decision", "decision", %{"callable" => "choice"}),
        node("map", "map", %{"callable" => "agent", "max_iterations" => 1}),
        node("loop", "loop", %{"callable" => "agent", "max_iterations" => 256})
      ]

      links = for choice <- ~w(yes no), do: link("decision", "ask", "choice", %{"choice" => choice})

      roundtrip(
        recipe([graph(nodes, links), callable("agent", "agent"), callable("choice", "decision")])
      )
    end

    test "closed shapes, identities, schema directions and references" do
      base = recipe()

      for bad <- [
            Map.put(base, "extra", nil),
            Map.put(base, "revision", 0),
            Map.put(base, "id", ""),
            Map.put(base, "id", String.duplicate("x", 129)),
            Map.put(base, "callables", []),
            Map.put(base, "callables", [callable(), callable()])
          ] do
        refused(bad, :invalid_shape)
      end

      refused(Map.put(base, "version", 2), :unsupported_version)
      refused(Map.put(base, "root", "missing"), :unknown_name)
      refused(recipe([Map.put(callable(), "kind", "unknown")]), :invalid_shape)

      refused(
        recipe([put_in(callable(), ["input", "schema"], %{"type" => "bad"})]),
        :invalid_schema
      )

      refused(
        recipe([put_in(callable(), ["input", "port", "direction"], "output")]),
        :invalid_schema
      )

      refused(recipe([graph([node("call", "call", %{"callable" => "missing"})])]), :unknown_name)
      refused(recipe([Map.put(callable("agent", "agent"), "binding", "missing")]), :unknown_name)
      refused(recipe([graph([node("$input")])]), :invalid_shape)

      for tool <- ["", String.duplicate("x", 129)],
          do: refused(recipe([graph([node("tool", "tool", %{"tool" => tool})])]), :invalid_shape)

      roundtrip(recipe([graph([node("tool", "tool", %{"tool" => String.duplicate("x", 128)})])]))
    end
  end

  describe "dependencies_and_data_slots" do
    test "exactly one matching giver including input, with ordered edges" do
      source = node("source", "ask", %{"gives" => [slot()]})
      target = node("target", "ask", %{"needs" => [slot()]})
      data = link("source", "target", "data", %{"give" => "value", "need" => "value"})
      roundtrip(recipe([graph([source, target], [data, link("source", "target")])]))
      roundtrip(recipe([graph([target], [Map.put(data, "from", "$input")], [slot()])]))
      refused(recipe([graph([source, target])]), :missing_giver)
      refused(recipe([graph([source, target], [data, data])]), :missing_giver)

      for key <- ~w(from to give need),
          do:
            refused(
              recipe([graph([source, target], [Map.put(data, key, "missing")])]),
              :unknown_name
            )

      for {key, value} <- [{"schema_id", "other"}, {"schema_version", 2}] do
        changed = put_in(target, ["needs"], [Map.put(slot(), key, value)])
        refused(recipe([graph([source, changed], [data])]), :invalid_schema)
      end

      refused(recipe([graph([source], [link("$input", "source")])]), :unknown_name)
      refused(recipe([graph([Map.put(source, "gives", [slot(), slot()])])]), :invalid_shape)
    end

    test "all projected link kinds reject self and multi-node cycles" do
      refused(recipe([graph([node("a")], [link("a", "a")])]), :cycle)
      refused(recipe([graph([node("a"), node("b")], [link("a", "b"), link("b", "a")])]), :cycle)

      nodes = [
        node("a", "ask", %{"needs" => [slot()], "gives" => [slot()]}),
        node("b", "ask", %{"needs" => [slot()], "gives" => [slot()]})
      ]

      data =
        for {a, b} <- [{"a", "b"}, {"b", "a"}],
            do: link(a, b, "data", %{"give" => "value", "need" => "value"})

      refused(recipe([graph(nodes, data)]), :cycle)
      map = branches()
      [g, c] = map["callables"]

      refused(
        %{map | "callables" => [%{g | "links" => g["links"] ++ [link("yes", "choose")]}, c]},
        :cycle
      )

      refused(
        recipe([
          graph([node("a"), node("b")], [
            link("a", "b", "outcome", %{"outcome" => "failed"}),
            link("b", "a")
          ])
        ]),
        :cycle
      )
    end
  end

  describe "branches_and_outcomes" do
    test "decision routes are total and exact" do
      map = branches()
      roundtrip(map)
      [g, c] = map["callables"]
      [first, second] = g["links"]

      for links <- [[first], [first, first, second], [first, Map.put(second, "choice", "other")]] do
        refused(%{map | "callables" => [%{g | "links" => links}, c]}, :invalid_branch)
      end

      refused(
        recipe([graph([node("a"), node("b")], [link("a", "b", "choice", %{"choice" => "yes"})])]),
        :invalid_branch
      )
    end

    test "nine optional outcomes, no duplicate class or implicit fallback" do
      outcomes =
        ~w(completed failed refused late unknown out_of_budget retries_exhausted expired resource_lost)

      for outcome <- outcomes do
        route = link("a", "b", "outcome", %{"outcome" => outcome})
        roundtrip(recipe([graph([node("a"), node("b")], [route])]))
        refused(recipe([graph([node("a"), node("b")], [route, route])]), :invalid_outcome)
      end

      roundtrip(recipe([graph([node("a"), node("b")])]))

      refused(
        recipe([
          graph([node("a"), node("b")], [link("a", "b", "outcome", %{"outcome" => "success"})])
        ]),
        :invalid_outcome
      )

      refused(
        recipe([graph([node("a")], [link("a", "missing", "outcome", %{"outcome" => "failed"})])]),
        :unknown_name
      )
    end
  end

  defp chain(count) do
    for n <- 1..count do
      if n == count,
        do: callable("c#{n}", "agent"),
        else:
          Map.put(callable("c#{n}"), "nodes", [node("call", "call", %{"callable" => "c#{n + 1}"})])
    end
  end

  describe "bounded_named_nesting" do
    test "all named chains count root and map or loop calls" do
      roundtrip(recipe(chain(16)))
      refused(recipe(chain(17)), :depth_exceeded)
      refused(recipe([callable("unused", "agent") | chain(17)]), :depth_exceeded)
      recursive = Map.put(callable(), "nodes", [node("self", "call", %{"callable" => "main"})])
      refused(recipe([recursive]), :cycle)
      refused(recipe([callable("unused", "agent"), recursive]), :cycle)
      [a, b | rest] = chain(3)

      refused(
        recipe([a, put_in(b, ["nodes"], [node("back", "call", %{"callable" => "c1"})]) | rest]),
        :cycle
      )

      for kind <- ~w(map loop) do
        for bound <- [1, 256],
            do:
              roundtrip(
                recipe([
                  graph([
                    node("repeat", kind, %{"callable" => "agent", "max_iterations" => bound})
                  ]),
                  callable("agent", "agent")
                ])
              )

        for bound <- [0, 257],
            do:
              refused(
                recipe([
                  graph([
                    node("repeat", kind, %{"callable" => "agent", "max_iterations" => bound})
                  ]),
                  callable("agent", "agent")
                ]),
                :invalid_shape
              )

        refused(
          recipe([
            graph([node("repeat", kind, %{"callable" => "agent", "max_iterations" => 1})], [
              link("repeat", "repeat")
            ]),
            callable("agent", "agent")
          ]),
          :cycle
        )

        [head | tail] = chain(17)

        changed =
          put_in(head, ["nodes"], [
            node("repeat", kind, %{"callable" => "c2", "max_iterations" => 1})
          ])

        refused(recipe([changed | tail]), :depth_exceeded)
      end
    end

    test "total counts include unreachable declarations and input links" do
      nodes = for n <- 1..1_000, do: node("n#{n}")
      roundtrip(recipe([graph(nodes)]))
      refused(recipe([graph(nodes ++ [node("extra")])]), :too_large)

      refused(
        recipe([graph(nodes), Map.put(callable("unreachable"), "nodes", [node("extra")])]),
        :too_large
      )

      links = List.duplicate(link("a", "b"), 10_000)
      roundtrip(recipe([graph([node("a"), node("b")], links)]))
      refused(recipe([graph([node("a"), node("b")], [link("a", "b") | links])]), :too_large)
      input = link("$input", "a", "data", %{"give" => "value", "need" => "value"})
      a = node("a", "ask", %{"needs" => [slot()]})
      roundtrip(recipe([graph([a, node("b")], [input | Enum.take(links, 9_999)], [slot()])]))
      refused(recipe([graph([a, node("b")], [input | links], [slot()])]), :too_large)
    end

    test "callable, slot, binding, rule, byte and container depth bounds" do
      declarations = for n <- 1..64, do: callable("a#{n}", "agent")
      roundtrip(recipe(declarations))
      refused(recipe(declarations ++ [callable("extra", "agent")]), :too_large)
      slots = for n <- 1..64, do: slot("s#{n}")
      roundtrip(recipe([graph([node("a", "ask", %{"gives" => slots})], [], slots)]))

      for key <- ~w(needs gives) do
        refused(recipe([graph([node("a", "ask", %{key => slots ++ [slot("extra")]})])]), :too_large)
      end

      refused(recipe([graph([], [], slots ++ [slot("extra")])]), :too_large)
      bindings = for n <- 1..64, do: %{"name" => "b#{n}", "target" => "binding"}
      roundtrip(Map.put(recipe(), "bindings", bindings))

      refused(
        Map.put(recipe(), "bindings", bindings ++ [%{"name" => "extra", "target" => "binding"}]),
        :too_large
      )

      nodes = for n <- 1..256, do: node("n#{n}")
      rules = for n <- 1..256, do: Map.put(rule(), "node", "n#{n}")
      roundtrip(Map.put(recipe([graph(nodes)]), "rules", rules))
      refused(Map.put(recipe([graph(nodes)]), "rules", [rule() | rules]), :too_large)
      base = recipe()
      bytes = byte_size(Jason.encode!(base))

      sized =
        put_in(base, ["callables"], [
          put_in(
            callable(),
            ["input", "schema", "description"],
            String.duplicate("x", 1_048_576 - bytes - 17)
          )
        ])

      assert byte_size(Jason.encode!(sized)) == 1_048_576
      roundtrip(sized)

      refused(
        update_in(
          sized,
          ["callables", Access.at(0), "input", "schema", "description"],
          &(&1 <> "x")
        ),
        :too_large
      )

      nested = fn count -> Enum.reduce(1..count, nil, fn _, acc -> [acc] end) end
      roundtrip(recipe([put_in(callable(), ["input", "schema", "const"], nested.(27))]))

      refused(
        recipe([put_in(callable(), ["input", "schema", "const"], nested.(28))]),
        :depth_exceeded
      )
    end
  end

  defp rule do
    %{
      "callable" => "main",
      "node" => "a",
      "policy" => %{"id" => "policy", "version" => 1, "content_hash" => String.duplicate("09", 32)},
      "requirement" => %{"name" => "review", "version" => 1, "scope" => "once"}
    }
  end

  describe "requirements_never_grant" do
    test "rules contain only exact requirements and policy identities" do
      base = recipe([graph([node("a")])])
      roundtrip(Map.put(base, "rules", [rule()]))

      for scope <- ~w(once run root),
          do: roundtrip(Map.put(base, "rules", [put_in(rule(), ["requirement", "scope"], scope)]))

      for bad <- [
            Map.put(rule(), "allow", true),
            Map.put(rule(), "node", "missing"),
            Map.put(rule(), "callable", "missing"),
            put_in(rule(), ["policy", "content_hash"], String.duplicate("A", 64)),
            put_in(rule(), ["requirement", "scope"], "allow"),
            put_in(rule(), ["requirement", "version"], 0),
            put_in(rule(), ["requirement", "evidence"], "approval")
          ] do
        refused(Map.put(base, "rules", [bad]), :invalid_rule)
      end

      refused(Map.put(base, "rules", [rule(), rule()]), :invalid_rule)
    end

    test "actual authorization and approval preserve DENY, ASK and exact bindings" do
      map = Map.put(recipe([graph([node("a")])]), "rules", [rule()])
      {:ok, checked} = RecipeGraph.decode(map)
      [r] = RecipeGraph.encode(checked)["rules"]

      requirement = %{
        name: r["requirement"]["name"],
        version: r["requirement"]["version"],
        scope: :once
      }

      policy = %{
        id: r["policy"]["id"],
        version: r["policy"]["version"],
        content_hash: Base.decode16!(r["policy"]["content_hash"], case: :lower),
        effect_classes: ["publish"],
        rules: [%{id: "review", effect_class: "publish", verdict: :ask, requirement: requirement}]
      }

      write = %{target: "item", field: "state", value: {:text, "published"}}

      proposal = %{
        tenant: "tenant",
        resource: "item",
        action_id: "action",
        payload: {:text, "body"},
        writes: [write]
      }

      authority = %{proposer: "proposer", effect_class: "publish", own: [write], parent: :none}

      {:ok, denied} =
        Authorization.decide(
          %{
            policy
            | rules: [%{id: "deny", effect_class: "publish", verdict: :deny} | policy.rules]
          },
          proposal,
          authority
        )

      assert denied.verdict == :deny and denied.permitted == []
      assert {:error, _} = Approval.request(Approval.new(), "run", denied)
      {:ok, asked} = Authorization.decide(policy, proposal, authority)
      assert asked.verdict == :ask and asked.permitted == [] and asked.escrowed == [write]
      {:ok, state, request, {:requested, _}} = Approval.request(Approval.new(), "run", asked)

      context = %{
        now: 2_000,
        max_age: 10_000,
        verifiers: ["verifier"],
        run: %{id: "run", root: "root", ancestry: ["root"]},
        policy: policy,
        proposal: proposal,
        authority: authority,
        approver: %{identity: "reviewer", authority: [write]}
      }

      evidence = %{
        verifier: "verifier",
        evidence_id: "evidence",
        reviewer: "reviewer",
        request: request.key,
        decision: :approve,
        scope: :once,
        issued_at: 1_000,
        expiry: 100_000
      }

      assert {:refused, _, _} = Approval.release(state, request.key, :retained, context)
      assert {:released, _, [^write], _} = Approval.release(state, request.key, evidence, context)
      changed_write = %{write | value: {:text, "changed"}}

      for changed <- [
            %{context | proposal: %{proposal | payload: {:text, "changed"}}},
            %{context | proposal: %{proposal | action_id: "other"}},
            %{context | policy: %{policy | version: 2}},
            %{
              context
              | proposal: %{proposal | writes: [changed_write]},
                authority: %{authority | own: [changed_write]},
                approver: %{identity: "reviewer", authority: [changed_write]}
            }
          ] do
        assert {:refused, _, _} = Approval.release(state, request.key, evidence, changed)
      end
    end
  end

  describe "stable_data_and_redaction" do
    test "equal independent plain values agree without list reordering" do
      map =
        put_in(recipe(), ["callables"], [
          put_in(callable(), ["input", "schema", "const"], %{
            "items" => [3, 1, true, nil, %{"x" => "text"}]
          })
        ])

      checked = roundtrip(map)
      copy = Jason.decode!(Jason.encode!(map))
      assert RecipeGraph.decode(copy) == {:ok, checked}
      assert_raise FunctionClauseError, fn -> RecipeGraph.encode(map) end
    end

    test "empty, malformed and nonplain data yield only fixed redacted atoms without logs" do
      sentinel = "SECRET_SENTINEL_DO_NOT_ECHO"

      output =
        capture_log(fn ->
          for bad <- [
                %{},
                [],
                nil,
                "",
                :invalid,
                self(),
                make_ref(),
                fn -> :ok end,
                %URI{},
                Map.put(recipe(), "secret", sentinel),
                put_in(recipe(), ["callables"], [
                  put_in(callable(), ["input", "schema", "const"], {sentinel, :bad})
                ])
              ] do
            reason = refused(bad)

            assert reason in [
                     :invalid_shape,
                     :unsupported_version,
                     :too_large,
                     :invalid_schema,
                     :unknown_name,
                     :cycle,
                     :depth_exceeded,
                     :missing_giver,
                     :invalid_branch,
                     :invalid_outcome,
                     :invalid_rule
                   ]

            refute inspect({:error, reason}) =~ sentinel
          end

          refused(
            recipe([put_in(callable(), ["input", "schema"], %{"type" => sentinel})]),
            :invalid_schema
          )
        end)

      assert output == ""
      refute output =~ sentinel
    end

    test "checked example" do
      {result, _} = Code.eval_file(Path.expand("../../examples/recipe_graph.exs", __DIR__))
      assert result == :ok
    end

    test "secret-bearing refusals emit no telemetry events" do
      parent = self()
      Code.ensure_loaded!(:telemetry)
      sentinel = "SECRET_EVENT_SENTINEL"

      worker =
        spawn(fn ->
          receive do
            :run ->
              results =
                for schema <- [%{"type" => sentinel}, %{"const" => %{sentinel => {sentinel}}}],
                    do:
                      RecipeGraph.decode(recipe([put_in(callable(), ["input", "schema"], schema)]))

              send(parent, {:results, results})
          end

          receive do: (:stop -> :ok)
        end)

      :erlang.trace_pattern({:telemetry, :execute, 3}, true, [:local])
      :erlang.trace(worker, true, [:call])

      on_exit(fn ->
        send(worker, :stop)
        :erlang.trace_pattern({:telemetry, :execute, 3}, false, [:local])
      end)

      logs =
        capture_log(fn ->
          send(worker, :run)
          assert_receive {:results, results}, 5_000
          assert results == [{:error, :invalid_schema}, {:error, :invalid_shape}]
          refute inspect(results) =~ sentinel
        end)

      delivered = :erlang.trace_delivered(worker)
      assert_receive {:trace_delivered, ^worker, ^delivered}
      refute_received {:trace, ^worker, :call, {:telemetry, :execute, _}}
      assert logs == ""
    end
  end
end
