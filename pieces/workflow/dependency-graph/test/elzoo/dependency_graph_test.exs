# SPDX-License-Identifier: Apache-2.0
defmodule Elzoo.DependencyGraphTest do
  use ExUnit.Case, async: false
  alias Elzoo.DependencyGraph, as: DG

  @cure :"Cure.Elzoo.DependencyGraph"
  @source File.read!(Path.expand("../../cure/elzoo/dependency_graph.cure", __DIR__))
  @roots Mix.Project.config() |> Keyword.get(:cure_paths, ["cure"]) |> Enum.map(&Path.expand/1)
  @laws ~w(unknown_never_satisfies undeclared_never_satisfies duplicate_never_satisfies
           unplaceable_never_satisfies completed_satisfies cancelled_never_satisfies
           closed_never_satisfies open_needs_support external_needs_support
           unknown_never_attributes unsatisfied_never_attributes model_never_attributes
           expired_never_attributes informational_never_blocks hierarchy_never_blocks
           blocked_never_ready deferred_never_ready duplicate_never_ready
           unplaceable_never_ready completed_never_ready admitted_keeps_acyclic
           admission_keeps_acyclic blocking_keeps_blocking blocking_drops_informational
           blocking_drops_hierarchy non_blocking_admitted_informational
           non_blocking_admitted_hierarchy reject_keeps_state)

  # {mutation, from, to, function the kernel must reject it in}
  @negatives [
    {"FalseLaw",
     "DgN(i, DgCompleted(), False(), False()), support), True()) =\n    reflexive(True())",
     "DgN(i, DgCompleted(), False(), False()), support), False()) =\n    reflexive(False())",
     "completed_satisfies"},
    {"ModelAttributes", "DgModelDeclared() -> False()\n          DgToolResult() -> live",
     "DgModelDeclared() -> live\n          DgToolResult() -> live", "unattributed_no_attr"},
    {"UnknownAttributes", "DgUnknown() -> False()\n\n  @total true\n  fn attributes",
     "DgUnknown() -> live\n\n  @total true\n  fn attributes", "unattributed_no_attr"},
    {"ExpiredAttributes", "fn current(expiry: Int, now: Int) -> Bool = now < expiry",
     "fn current(expiry: Int, now: Int) -> Bool = True()", "unattributed_no_attr"},
    {"CancelledSatisfies", "DgCancelled() -> False()\n                  DgClosed() -> False()",
     "DgCancelled() -> True()\n                  DgClosed() -> False()",
     "cancelled_never_satisfies"},
    {"ClosedSatisfies", "DgClosed() -> False()\n                  DgOpen() -> support",
     "DgClosed() -> True()\n                  DgOpen() -> support", "closed_never_satisfies"},
    {"DuplicateSatisfies", "match duplicate\n          True() -> False()",
     "match duplicate\n          True() -> True()", "duplicate_never_satisfies"},
    {"InformationalBlocks", "DgInformational() -> edges_ok(rest, i, nodes, facts, now)",
     "DgInformational() -> edge_step(from == i, to, nodes, facts, now, edges_ok(rest, i, nodes, facts, now))",
     "informational_never_blocks"},
    {"BlockingEdgeIgnored", "True() -> `and`(target_satisfied(to, nodes, facts, now), r)",
     "True() -> `or`(target_satisfied(to, nodes, facts, now), r)", "pick_head"},
    {"DeferralIgnored", "True() -> False()\n              False() -> edges",
     "True() -> edges\n              False() -> edges", "open_blocked"},
    {"CertificateIgnoresSource", "`and`(mem_int(s, t), `and`(closed(es, s), `not`(mem_int(s, f))))",
     "`and`(mem_int(s, t), `and`(closed(es, s), True()))", "new_cycle_contradicts"},
    {"ClosureSkipsEdge", "[e | rest] -> `and`(edge_closed(e, s), closed(rest, s))",
     "[e | rest] -> closed(rest, s)", "closed_mem"},
    {"ProjectionDropsBlocking", "DgBlocking() -> [DgE(from, to) | blocking(rest)]",
     "DgBlocking() -> blocking(rest)", "committed_cycle_inner"},
    {"ProjectionKeepsInformational", "DgInformational() -> blocking(rest)",
     "DgInformational() -> [DgE(from, to) | blocking(rest)]", "blocking_drops_informational"},
    {"RejectCommits", "False() -> Transition{state: es, output: Some(DgReject())}",
     "False() -> Transition{state: [proposal | es], output: Some(DgReject())}", "reject_inner"},
    {"NonStructuralProof",
     "dg_hop(m, rest) -> transport(s, g, c, rest, closed_mem(s, g, c, m, ha))",
     "dg_hop(m, rest) -> transport(s, g, c, w, ha)", nil}
  ]

  describe "selected Cure laws" do
    test "compile, audit clean and are exported" do
      assert {:module, @cure} = Code.ensure_loaded(@cure)
      assert {:ok, env} = Cure.Compiler.check_source(@source, source_roots: @roots)
      report = Cure.Audit.Ledger.audit_env(env)

      for key <- [:axioms, :holes, :unresolved, :unaudited, :opaque, :not_proven_total],
          do: assert(Map.fetch!(report, key) == [], "#{key}: #{inspect(Map.fetch!(report, key))}")

      exports = @cure.module_info(:exports) |> Enum.map(&elem(&1, 0))
      for law <- @laws, do: assert(String.to_atom(law) in exports, law)

      # Every function in the source carries @total true.
      lines = String.split(@source, "\n")

      for {line, n} <- Enum.with_index(lines),
          Regex.match?(~r/^  fn /, line),
          do: assert(Enum.at(lines, n - 1) == "  @total true", "missing @total true: #{line}")

      IO.puts("ELZ-026 DependencyGraph laws compiled: #{length(@laws)}")
    end

    test "every negative control is rejected by the pinned kernel" do
      for {name, from, to, function} <- @negatives do
        assert String.contains?(@source, from), name

        wrong =
          @source
          |> String.replace("mod Elzoo.DependencyGraph", "mod Elzoo.DependencyGraph" <> name)
          |> String.replace(from, to, global: false)

        assert {:error, {:codegen_error, {:source_context, reason, context}}} =
                 Cure.Compiler.compile_and_load(wrong, source_roots: @roots),
               "#{name} was accepted"

        kind = elem(reason, 0)

        if function do
          assert kind in [
                   :conversion_failure,
                   :branch_type,
                   :let_needs_annotation,
                   :unsolved_metavariables,
                   :index_mismatch
                 ],
                 "#{name}: #{kind}"

          at = function_at(wrong, context.line)
          assert at == function, "#{name} failed in #{at}, expected #{function}"
          IO.puts("ELZ-026 negative rejected: #{name} (#{kind}) in #{at}")
        else
          assert kind == :total_required_by_decorator, "#{name}: #{kind}"
          IO.puts("ELZ-026 negative rejected: #{name} (#{kind})")
        end
      end
    end

    test "the compiled decision module imports only :erlang" do
      {:ok, {_, [imports: imports]}} = :beam_lib.chunks(:code.which(@cure), [:imports])
      assert imports |> Enum.map(&elem(&1, 0)) |> Enum.uniq() == [:erlang]
    end
  end

  defp function_at(source, line) do
    source
    |> String.split("\n")
    |> Enum.take(line)
    |> Enum.reverse()
    |> Enum.find_value(fn text ->
      case Regex.run(~r/^  fn (\w+)\(/, text) do
        [_, name] -> name
        nil -> nil
      end
    end)
  end

  # ---------------------------------------------------------------- fixtures

  @now 1_767_225_000_000

  defp item(id, lifecycle \\ :open, deferred_until \\ nil),
    do: %{id: id, lifecycle: lifecycle, deferred_until: deferred_until}

  defp edge(from, to, kind \\ :blocking), do: %{from: from, to: to, kind: kind}

  defp fact(target, value, provenance \\ :tool_result, expiry \\ @now + 60_000, source \\ "src"),
    do: %{
      prerequisite: target,
      value: value,
      source: source,
      provenance: provenance,
      expiry: expiry
    }

  defp graph(items, edges \\ [], facts \\ [], externals \\ []),
    do: %{items: items, externals: externals, edges: edges, facts: facts}

  defp ready(g, now \\ @now) do
    {:ok, r} = DG.readiness(g, now)
    r
  end

  defp reasons(r, id) do
    r.blocked |> Enum.find(&(&1.id == id)) |> Map.fetch!(:blockers) |> Enum.map(& &1.reason)
  end

  # ---------------------------------------------------------------- readiness

  describe "readiness" do
    test "orientation: from waits for to; the blocker target is to" do
      r = ready(graph([item("a"), item("b")], [edge("a", "b")]))
      assert r.ready == ["b"]

      assert [
               %{
                 id: "a",
                 blockers: [%{target: "b", present: true, satisfied: false, reason: :no_fact}]
               }
             ] = r.blocked
    end

    test "closed and cancelled are not completed" do
      for {lifecycle, ready?, reason} <- [
            {:completed, true, nil},
            {:closed, false, :closed_without_completion},
            {:cancelled, false, :cancelled}
          ] do
        g = graph([item("a"), item("b", lifecycle)], [edge("a", "b")], [fact("b", :satisfied)])
        r = ready(g)
        assert "a" in r.ready == ready?, "#{lifecycle}"
        if reason, do: assert(reasons(r, "a") == [reason])
        assert r.inactive == ["b"]
      end
    end

    test "expiry boundary: current iff now < expiry" do
      for {expiry, ready?} <- [{@now + 1, true}, {@now, false}, {@now - 1, false}] do
        r =
          ready(
            graph([item("a"), item("b")], [edge("a", "b")], [
              fact("b", :satisfied, :tool_result, expiry)
            ])
          )

        assert "a" in r.ready == ready?, "expiry #{expiry - @now}"
        unless ready?, do: assert(reasons(r, "a") == [:fact_expired])
      end
    end

    test "deferral boundary: deferred iff now < deferred_until" do
      for {until, ready?} <- [{@now + 1, false}, {@now, true}, {@now - 1, true}, {nil, true}] do
        r = ready(graph([item("a", :open, until)]))
        assert "a" in r.ready == ready?, inspect(until)
        unless ready?, do: assert(reasons(r, "a") == [:deferred])
      end
    end

    test "model-declared facts never unblock, but a model veto blocks" do
      only_model =
        graph([item("a"), item("b")], [edge("a", "b")], [fact("b", :satisfied, :model_declared)])

      assert reasons(ready(only_model), "a") == [:model_declared_only]

      for provenance <- [:tool_result, :artifact_reference, :event_fold] do
        g = graph([item("a"), item("b")], [edge("a", "b")], [fact("b", :satisfied, provenance)])
        assert "a" in ready(g).ready

        vetoed = %{g | facts: g.facts ++ [fact("b", :unsatisfied, :model_declared)]}
        assert reasons(ready(vetoed), "a") == [:fact_vetoed]
      end
    end

    test "unknown, unsatisfied, expired and missing facts never satisfy" do
      cases = [
        {[fact("b", :unknown)], :fact_unknown},
        {[fact("b", :unknown, :tool_result, @now)], :fact_expired},
        {[fact("b", :unsatisfied)], :fact_vetoed},
        {[fact("b", :satisfied, :tool_result, @now)], :fact_expired},
        {[], :no_fact},
        # reviewer example: expired tool result + current model-declared satisfied
        {[fact("b", :satisfied, :tool_result, @now - 5), fact("b", :satisfied, :model_declared)],
         :model_declared_only},
        {[fact("b", :unknown), fact("b", :satisfied, :model_declared)], :model_declared_only},
        {[fact("b", :unsatisfied, :tool_result, @now), fact("b", :unknown)], :fact_unknown}
      ]

      for {facts, reason} <- cases do
        r = ready(graph([item("a"), item("b")], [edge("a", "b")], facts))
        assert reasons(r, "a") == [reason], inspect(facts)
      end
    end

    test "external prerequisites are satisfied only by attributable facts" do
      g = graph([item("a")], [edge("a", "window")], [], ["window"])
      assert reasons(ready(g), "a") == [:no_fact]
      assert "a" in ready(%{g | facts: [fact("window", :satisfied, :event_fold)]}).ready

      assert reasons(ready(%{g | facts: [fact("window", :satisfied, :model_declared)]}), "a") == [
               :model_declared_only
             ]
    end

    test "completion contradicted by a current veto: reported, readiness unchanged" do
      g =
        graph([item("a"), item("b", :completed)], [edge("a", "b")], [
          fact("b", :unsatisfied, :tool_result, @now + 10, "probe")
        ])

      r = ready(g)
      assert r.ready == ["a"]

      assert r.contradictions == [
               %{item: "a", target: "b", reason: :completion_contradicted, sources: ["probe"]}
             ]

      expired = %{g | facts: [fact("b", :unsatisfied, :tool_result, @now)]}
      assert ready(expired).contradictions == []
    end

    test "a duplicate or unplaceable completed target is unsatisfied without a contradiction" do
      veto = [fact("b", :unsatisfied)]
      dup = graph([item("a"), item("b", :completed), item("b", :completed)], [edge("a", "b")], veto)
      r = ready(dup)
      assert reasons(r, "a") == [:duplicate_node]
      assert r.contradictions == []

      cyc =
        graph(
          [item("a"), item("b", :completed), item("c")],
          [edge("a", "b"), edge("b", "c"), edge("c", "b")],
          veto
        )

      r = ready(cyc)
      assert reasons(r, "a") == [:cycle, :cycle]
      assert r.contradictions == []
    end

    test "informational and hierarchy edges never block" do
      g =
        graph([item("a"), item("b")], [edge("a", "b", :informational), edge("a", "b", :hierarchy)])

      assert ready(g).ready == ["a", "b"]
    end

    test "blocker order: own entries first, then blocking edges in graph order" do
      g =
        graph(
          [item("a", :open, @now + 1), item("a2"), item("b"), item("c")],
          [edge("a", "c"), edge("a", "b"), edge("a", "a2"), edge("a2", "a")]
        )

      [blocked_a] = Enum.filter(ready(g).blocked, &(&1.id == "a"))

      assert Enum.map(blocked_a.blockers, &{&1.target, &1.reason}) ==
               [{"a", :deferred}, {"a", :cycle}, {"c", :no_fact}, {"b", :no_fact}, {"a2", :cycle}]

      base = graph([item("a"), item("b"), item("c")], [edge("a", "b")])
      {:admit, g2} = DG.admit(base, edge("a", "c"))
      assert hd(Enum.find(ready(g2).blocked, &(&1.id == "a")).blockers).target == "c"
    end

    test "present is false only for an undeclared target" do
      g = graph([item("a"), item("a", :open)], [edge("a", "ghost")])
      r = ready(g)

      for %{blockers: bs} <- r.blocked,
          b <- bs,
          do: assert(b.present == (b.reason != :unknown_dependency))

      assert Enum.any?(r.blocked, fn %{blockers: bs} ->
               Enum.any?(bs, &(&1.reason == :unknown_dependency))
             end)
    end

    test "orphan facts are ignored and listed" do
      g = graph([item("a")], [], [fact("ghost", :satisfied), fact("a", :unknown)])
      r = ready(g)
      assert r.orphan_facts == [0]
      assert r.issues == []
      assert r.ready == ["a"]
    end

    test "explanation equals decision on random graphs" do
      :rand.seed(:exsss, {26, 43, 2026})

      for _ <- 1..300 do
        g = random_graph(8)
        r = ready(g)
        for %{blockers: bs} <- r.blocked, do: assert(bs != [])

        open = for %{id: id, lifecycle: :open} <- g.items, uniq: true, do: id
        assert Enum.sort(open) == Enum.sort(Enum.uniq(r.ready ++ Enum.map(r.blocked, & &1.id)))
        assert MapSet.disjoint?(MapSet.new(r.ready), MapSet.new(Enum.map(r.blocked, & &1.id)))
      end
    end
  end

  defp random_graph(n) do
    ids = for i <- 1..n, do: "n#{i}"
    lifecycles = [:open, :open, :open, :completed, :cancelled, :closed]

    items =
      for id <- Enum.take(ids, n - 2),
          do: item(id, Enum.random(lifecycles), Enum.random([nil, nil, @now + 1, @now]))

    externals = Enum.drop(ids, n - 2)
    pick = fn -> Enum.random(ids ++ ["ghost"]) end

    edges =
      for _ <- 1..Enum.random(0..12)//1,
          do:
            edge(
              Enum.random(Enum.map(items, & &1.id) ++ ["ghost"]),
              pick.(),
              Enum.random([:blocking, :blocking, :informational, :hierarchy])
            )

    facts =
      for _ <- 1..Enum.random(0..8)//1,
          do:
            fact(
              pick.(),
              Enum.random([:satisfied, :unsatisfied, :unknown]),
              Enum.random([:tool_result, :artifact_reference, :event_fold, :model_declared]),
              @now + Enum.random(-2..2)
            )

    graph(items, edges, facts, externals)
  end

  # ------------------------------------------------------------ validation

  describe "validation" do
    test "three issue kinds stay separate and every unplaceable node is named" do
      g =
        graph(
          [item("a"), item("b"), item("c"), item("d"), item("e"), item("dup"), item("dup")],
          [
            edge("a", "b"),
            edge("b", "a"),
            edge("c", "a"),
            edge("d", "c"),
            edge("e", "ghost"),
            edge("w", "a", :informational)
          ],
          [],
          ["w"]
        )

      assert {:ok, issues} = DG.validate(g)

      assert issues == [
               %{kind: :duplicate_node, id: "dup"},
               %{
                 kind: :unknown_dependency,
                 from: "e",
                 to: "ghost",
                 endpoints: %{from: :item, to: :undeclared}
               },
               %{
                 kind: :unknown_dependency,
                 from: "w",
                 to: "a",
                 endpoints: %{from: :external, to: :item}
               },
               %{kind: :cycle, nodes: ["a", "b", "c", "d"]}
             ]
    end

    test "a self-loop is a cycle; unknown-dependency edges are excluded from placement" do
      assert {:ok, [%{kind: :cycle, nodes: ["a"]}]} =
               DG.validate(graph([item("a")], [edge("a", "a")]))

      assert {:ok, [%{kind: :unknown_dependency}]} =
               DG.validate(graph([item("a")], [edge("a", "ghost")]))

      assert {:ok, []} = DG.validate(graph([item("a")], [edge("a", "a", :hierarchy)]))
    end

    test "exact bound errors; the proposed edge counts" do
      big = fn n -> for i <- 1..n, do: item("i#{i}") end
      assert {:error, {:too_large, :nodes}} = DG.validate(graph(big.(1_000), [], [], ["x"]))
      assert {:ok, []} = DG.validate(graph(big.(1_000)))

      edges = for _ <- 1..10_000, do: edge("i1", "i2", :informational)
      g = graph(big.(2), edges)
      assert {:ok, []} = DG.validate(g)
      assert {:error, {:too_large, :edges}} = DG.validate(%{g | edges: [edge("i1", "i2") | edges]})
      assert {:error, {:too_large, :edges}} = DG.admit(g, edge("i2", "i1"))

      facts = for _ <- 1..10_001, do: fact("i1", :unknown)
      assert {:error, {:too_large, :facts}} = DG.readiness(graph(big.(2), [], facts), @now)
    end

    test "exact invalid paths" do
      ok = graph([item("a")])
      assert {:error, {:invalid, []}} = DG.validate(:nope)
      assert {:error, {:invalid, []}} = DG.validate(Map.put(ok, :extra, []))
      assert {:error, {:invalid, [:edges]}} = DG.validate(%{ok | edges: :x})
      assert {:error, {:invalid, [:items, 0, :lifecycle]}} = DG.validate(graph([item("a", :done)]))
      assert {:error, {:invalid, [:items, 0, :id]}} = DG.validate(graph([item("")]))
      assert {:error, {:invalid, [:items, 0, :id]}} = DG.validate(graph([item(<<255>>)]))

      assert {:error, {:invalid, [:items, 0, :deferred_until]}} =
               DG.validate(graph([item("a", :open, -1)]))

      assert {:error, {:invalid, [:items, 0]}} = DG.validate(graph([Map.put(item("a"), :x, 1)]))
      assert {:error, {:invalid, [:externals, 0]}} = DG.validate(graph([], [], [], [:x]))

      assert {:error, {:invalid, [:edges, 0, :kind]}} =
               DG.validate(graph([item("a")], [edge("a", "a", :soft)]))

      assert {:error, {:invalid, [:facts, 0, :expiry]}} =
               DG.validate(graph([item("a")], [], [fact("a", :satisfied, :tool_result, 1.5)]))

      assert {:error, {:invalid, [:facts, 0, :provenance]}} =
               DG.validate(graph([item("a")], [], [fact("a", :satisfied, :oracle)]))

      assert {:error, {:invalid, [:now]}} = DG.readiness(ok, -1)
      assert {:error, {:invalid, [:proposal, :kind]}} = DG.admit(ok, edge("a", "a", :soft))
      assert {:error, {:invalid, [:proposal]}} = DG.admit(ok, %{from: "a"})
    end
  end

  # ------------------------------------------------------------- admission

  describe "admission" do
    test "reject precedence: error, invalid_graph, unknown_dependency, cycle" do
      cyclic = graph([item("a"), item("b")], [edge("a", "b"), edge("b", "a")])
      assert {:error, {:invalid, [:proposal, :kind]}} = DG.admit(cyclic, edge("a", "ghost", :soft))
      assert {:reject, {:invalid_graph, [%{kind: :cycle}]}} = DG.admit(cyclic, edge("a", "ghost"))

      g = graph([item("a"), item("b")], [edge("a", "b")], [], ["w"])

      assert {:reject,
              {:unknown_dependency,
               %{from: "w", to: "ghost", endpoints: %{from: :external, to: :undeclared}}}} =
               DG.admit(g, edge("w", "ghost"))

      assert {:reject, {:unknown_dependency, %{endpoints: %{from: :undeclared, to: :item}}}} =
               DG.admit(g, edge("ghost", "a", :informational))

      assert {:reject, {:cycle, ["a", "b", "a"]}} = DG.admit(g, edge("b", "a"))
    end

    test "self-loop and path shape; non-blocking edges skip the cycle check" do
      g =
        graph([item("a"), item("b"), item("c"), item("d")], [
          edge("a", "b"),
          edge("b", "c"),
          edge("a", "d"),
          edge("d", "c")
        ])

      assert {:reject, {:cycle, ["a", "a"]}} = DG.admit(g, edge("a", "a"))
      assert {:reject, {:cycle, [_, _, _, _] = path}} = DG.admit(g, edge("c", "a"))
      assert hd(path) == "a" and List.last(path) == "a" and Enum.at(path, 2) == "c"
      assert {:admit, g2} = DG.admit(g, edge("c", "a", :informational))
      assert hd(g2.edges) == edge("c", "a", :informational)
      assert {:admit, g3} = DG.admit(g, edge("b", "d"))
      assert g3.edges == [edge("b", "d") | g.edges]
      assert g3.items == g.items and g3.facts == g.facts and g3.externals == g.externals
    end

    test "the Elixir step commits exactly the Cure next mapped back to IDs" do
      g = graph([item("a"), item("b"), item("c")], [edge("a", "b", :hierarchy), edge("b", "c")])
      cure_edges = [{:DgRE, :DgHierarchy, 0, 1}, {:DgRE, :DgBlocking, 1, 2}]

      assert {:Transition, next, {:some, :DgAdmit}} =
               @cure.admission_step(cure_edges, {:DgRE, :DgBlocking, 0, 2})

      assert next == [{:DgRE, :DgBlocking, 0, 2} | cure_edges]
      assert {:Transition, g2, {:some, :admit}} = DG.admission_step(g, edge("a", "c"))
      assert g2.edges == [edge("a", "c"), edge("a", "b", :hierarchy), edge("b", "c")]

      assert {:Transition, ^g, {:some, {:reject, {:cycle, ["b", "c", "b"]}}}} =
               DG.admission_step(g, edge("c", "b"))

      assert {:Transition, :bad, {:some, {:error, {:invalid, []}}}} =
               DG.admission_step(:bad, edge("c", "b"))
    end

    test "search completeness: exhaustive on small graphs, no search disagreement" do
      for n <- [2, 3], edges <- all_edge_sets(n, true), reference_acyclic?(n, edges) do
        g = graph(for(i <- 1..n, do: item("v#{i}")), edges)

        for f <- 1..n, t <- 1..n do
          expected = if f == t or reaches?(edges, "v#{t}", "v#{f}"), do: :reject, else: :admit
          result = DG.admit(g, edge("v#{f}", "v#{t}"))
          refute result == {:error, :search_disagreement}
          assert elem(result, 0) == expected, "#{inspect(edges)} + v#{f}->v#{t}"
        end
      end

      count =
        for edges <- all_edge_sets(4, false), reference_acyclic?(4, edges), reduce: 0 do
          acc ->
            g = graph(for(i <- 1..4, do: item("v#{i}")), edges)

            for f <- 1..4, t <- 1..4, f != t do
              expected = if reaches?(edges, "v#{t}", "v#{f}"), do: :reject, else: :admit
              assert elem(DG.admit(g, edge("v#{f}", "v#{t}")), 0) == expected
            end

            acc + 1
        end

      IO.puts(
        "ELZ-026 completeness: all acyclic blocking graphs on 2-3 nodes (with self-loops) and #{count} on 4 nodes"
      )
    end

    test "search completeness on random larger graphs and a long chain" do
      :rand.seed(:exsss, {43, 26, 7})

      for _ <- 1..60 do
        n = 30
        order = Enum.shuffle(1..n)
        rank = Map.new(Enum.with_index(order))

        edges =
          for _ <- 1..60,
              a = Enum.random(1..n),
              b = Enum.random(1..n),
              rank[a] > rank[b],
              uniq: true,
              do: edge("v#{a}", "v#{b}")

        g = graph(for(i <- 1..n, do: item("v#{i}")), edges)
        f = Enum.random(1..n)
        t = Enum.random(1..n)
        expected = if f == t or reaches?(edges, "v#{t}", "v#{f}"), do: :reject, else: :admit
        assert elem(DG.admit(g, edge("v#{f}", "v#{t}")), 0) == expected
      end

      chain = for i <- 1..999, do: edge("v#{i}", "v#{i + 1}")
      g = graph(for(i <- 1..1_000, do: item("v#{i}")), chain)
      assert {:reject, {:cycle, path}} = DG.admit(g, edge("v1000", "v1"))
      assert length(path) == 1_001
      assert {:admit, _} = DG.admit(g, edge("v1", "v1000"))
    end
  end

  defp all_edge_sets(n, loops?) do
    pairs = for f <- 1..n, t <- 1..n, loops? or f != t, do: edge("v#{f}", "v#{t}")
    Enum.reduce(pairs, [[]], fn e, acc -> acc ++ Enum.map(acc, &[e | &1]) end)
  end

  defp reaches?(edges, from, to), do: to in reach(edges, [from], MapSet.new())

  defp reach(_edges, [], seen), do: MapSet.to_list(seen)

  defp reach(edges, [x | rest], seen) do
    next = for %{from: ^x, to: y} <- edges, not MapSet.member?(seen, y), do: y
    reach(edges, rest ++ next, MapSet.union(seen, MapSet.new(next)))
  end

  defp reference_acyclic?(n, edges), do: Enum.all?(1..n, &(not reaches?(edges, "v#{&1}", "v#{&1}")))

  # ---------------------------------------------------- concurrent admission

  describe "concurrent admission" do
    test "a serialized Elzoo.Unit owner never commits two racing edges that form a cycle" do
      for _ <- 1..200 do
        {:ok, owner} = Elzoo.Unit.start_link({DG, :admission_step, graph([item("a"), item("b")])})

        results =
          [edge("a", "b"), edge("b", "a")]
          |> Enum.map(fn p -> Task.async(fn -> Elzoo.Unit.step(owner, p) end) end)
          |> Enum.map(&Task.await/1)

        assert Enum.count(results, &(&1 == {:some, :admit})) == 1
        assert Enum.count(results, &match?({:some, {:reject, {:cycle, [_, _, _]}}}, &1)) == 1

        {DG, :admission_step, final} = Elzoo.Unit.snapshot(owner)
        assert length(final.edges) == 1
        assert {:ok, []} = DG.validate(final)
        GenServer.stop(owner)
      end
    end

    test "negative control: snapshot check then separate commit commits a cycle" do
      {:ok, store} = Agent.start_link(fn -> graph([item("a"), item("b")]) end)
      parent = self()

      tasks =
        for p <- [edge("a", "b"), edge("b", "a")] do
          Task.async(fn ->
            snapshot = Agent.get(store, & &1)
            verdict = DG.admit(snapshot, p)
            send(parent, {:checked, self()})
            receive do: (:commit -> :ok)
            if match?({:admit, _}, verdict), do: Agent.update(store, &%{&1 | edges: [p | &1.edges]})
            elem(verdict, 0)
          end)
        end

      # Force the interleaving: both check against the same snapshot first.
      for _ <- tasks, do: assert_receive({:checked, _}, 1_000)
      for t <- tasks, do: send(t.pid, :commit)
      assert Enum.map(tasks, &Task.await/1) == [:admit, :admit]
      assert {:ok, [%{kind: :cycle, nodes: ["a", "b"]}]} = DG.validate(Agent.get(store, & &1))
    end
  end
end
