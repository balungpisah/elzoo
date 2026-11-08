# SPDX-License-Identifier: Apache-2.0
defmodule Elzoo.ContextSelectionTest do
  use ExUnit.Case, async: false
  alias Elzoo.ContextSelection, as: S
  @cure :"Cure.Elzoo.ContextSelection"
  @source File.read!(Path.expand("../../cure/elzoo/context_selection.cure", __DIR__))

  defp candidate(id, opts \\ []) do
    content = Keyword.get(opts, :content, id)

    %{
      item_id: id,
      version: Keyword.get(opts, :version, 1),
      source: "catalogue",
      content: content,
      estimate: Keyword.get(opts, :estimate, byte_size(content)),
      priority: Keyword.get(opts, :priority, 0),
      content_hash: Keyword.get(opts, :hash),
      derived_from: Keyword.get(opts, :refs, []),
      access: %{principal: "alice", checked_at: 80, result: :allowed}
    }
  end

  defp ref(id, version \\ 1), do: %{item_id: id, version: version}

  defp provenance_node(c, opts \\ []) do
    base =
      Map.take(c, [:item_id, :version, :source, :content_hash, :derived_from])
      |> Map.put(:tenant, "tenant")

    check =
      base
      |> Map.delete(:derived_from)
      |> Map.merge(%{
        principal: "alice",
        checked_at: Keyword.get(opts, :time, 95),
        result: Keyword.get(opts, :result, :allowed)
      })

    Map.put(base, :check, check)
  end

  defp context(nodes, opts \\ []) do
    window = %{
      provider_id: "host",
      model_id: "brief",
      size: Keyword.get(opts, :size, 1000),
      unit: Keyword.get(opts, :unit, :tokens),
      estimator_id: "fixture",
      estimator_version: 1
    }

    %{
      principal: "alice",
      tenant: "tenant",
      now: 100,
      snapshot_at: 100,
      window: window,
      windows: [window],
      reservations: Keyword.get(opts, :reservations, []),
      provenance: nodes,
      policy: %{
        max_age: 10,
        allow_derived: true,
        priority: :input,
        recency: :input,
        max_selected_count: Keyword.get(opts, :count, 256),
        max_selected_bytes: Keyword.get(opts, :bytes, 8_388_608)
      }
    }
  end

  defp run(items, ctx), do: S.select(%{candidates: items}, ctx)
  defp ids(result), do: Enum.map(result.selected, & &1.item_id)
  defp details(result), do: Enum.map(result.dropped, &{&1.item_id, &1.reason, &1.detail})

  test "production Cure compiles with a clean totality audit" do
    assert {:ok, env} = Cure.Compiler.check_source(@source)
    audit = Cure.Audit.Ledger.audit_env(env)

    for field <- [:axioms, :holes, :opaque, :unresolved, :unaudited, :not_proven_total],
        do: assert(Map.fetch!(audit, field) == [])

    assert audit.absurd == 0
  end

  test "ordinary selection preserves bytes, current check, retrieval evidence and estimator" do
    x = candidate("x")
    assert {:ok, r} = run([x], context([provenance_node(x)]))
    assert ids(r) == ["x"]
    assert r.dropped == []
    assert hd(r.selected).content == "x"
    assert hd(r.selected).access.checked_at == 95
    assert hd(r.selected).retrieval_access == x.access
    assert hd(r.selected).kind == :source

    assert r.total_estimate == %{
             size: 1,
             unit: :tokens,
             estimator_id: "fixture",
             estimator_version: 1
           }

    assert {r.selected_count, r.selected_bytes, r.reserved_estimate} == {1, 1, 0}
  end

  test "revoked, stale and denied-derived exclusions retain an allowed survivor" do
    good = candidate("good")
    denied = candidate("denied")
    stale = candidate("stale")
    summary = candidate("summary", refs: [ref("denied")])

    nodes = [
      provenance_node(summary),
      provenance_node(good),
      provenance_node(denied, result: :denied),
      provenance_node(stale, time: 89)
    ]

    assert {:ok, r} = run([denied, stale, summary, good], context(nodes))
    assert ids(r) == ["good"]

    assert details(r) == [
             {"denied", :access_denied, :denied},
             {"stale", :stale_access_check, :expired_check},
             {"summary", :access_denied, :source_denied}
           ]
  end

  test "exact window and age boundaries, derived source need not be injected" do
    source = candidate("source")
    summary = candidate("summary", estimate: 7, refs: [ref("source")])

    assert {:ok, r} =
             run(
               [summary],
               context([provenance_node(summary), provenance_node(source, time: 90)],
                 size: 10,
                 reservations: [{"system", 3}]
               )
             )

    assert ids(r) == ["summary"]
    assert r.dropped == []
    assert hd(r.selected).kind == :derived
    assert hd(r.selected).derived_from == [ref("source")]
    assert r.total_estimate.size + r.reserved_estimate == 10
  end

  test "retrieval deny and principal mismatch veto current allow; missing check has no fallback" do
    a = put_in(candidate("a").access.result, :denied)
    b = put_in(candidate("b").access.principal, "eve")
    c = candidate("c")

    assert {:ok, r} =
             run(
               [a, b, c],
               context([provenance_node(a), provenance_node(b), %{provenance_node(c) | check: nil}])
             )

    assert r.selected == []

    assert details(r) == [
             {"a", :access_denied, :retrieval_denied},
             {"b", :access_denied, :principal_mismatch},
             {"c", :access_denied, :missing_check}
           ]
  end

  test "request cannot override any context or policy field" do
    ctx = context([])
    fields = Map.keys(ctx) ++ Map.keys(ctx.policy)

    for field <- fields do
      assert {:error, {:invalid_input, {:unknown_field, ^field}}} =
               S.select(%{field => false, candidates: []}, ctx)
    end
  end

  test "hash mismatch and byte estimate underflow reject whole call" do
    bad = candidate("x", hash: <<0::256>>)
    assert {:error, {:invalid_input, :hash_mismatch}} = run([bad], context([provenance_node(bad)]))
    good = candidate("x", hash: :crypto.hash(:sha256, "x"))
    assert {:ok, r} = run([good], context([provenance_node(good)]))
    assert ids(r) == ["x"]
    under = candidate("x", estimate: 0)

    assert {:error, {:invalid_input, :byte_estimate_underflow}} =
             run([under], context([provenance_node(under)], unit: :bytes))

    assert {:ok, tokens} = run([under], context([provenance_node(under)]))
    assert hd(tokens.selected).content == "x"
  end

  test "tenant, current principal and source/hash bindings precede denial" do
    x = candidate("x")
    n = provenance_node(x)

    bad_nodes = [
      put_in(n.tenant, "other"),
      put_in(n.check.tenant, "other"),
      put_in(n.check.principal, "eve"),
      put_in(n.check.source, "other"),
      put_in(n.check.content_hash, <<0::256>>)
    ]

    for bad <- bad_nodes do
      assert {:ok, r} = run([x], context([put_in(bad.check.result, :denied)]))
      assert details(r) == [{"x", :access_denied, :binding_mismatch}]
    end
  end

  test "source unchecked, transitive stale, tenant mismatch and missing node are distinct" do
    x = candidate("x", refs: [ref("mid")])
    mid = candidate("mid", refs: [ref("leaf")])
    leaf = candidate("leaf")

    for {n, expected} <- [
          {%{provenance_node(leaf) | check: nil}, {:access_denied, :source_unchecked}},
          {provenance_node(leaf, time: 89), {:stale_access_check, :source_stale}},
          {put_in(provenance_node(leaf).check.tenant, "other"), {:access_denied, :binding_mismatch}}
        ] do
      assert {:ok, r} = run([x], context([provenance_node(x), n, provenance_node(mid)]))
      {reason, detail} = expected
      assert details(r) == [{"x", reason, detail}]
    end

    assert {:ok, missing} = run([x], context([provenance_node(x), provenance_node(mid)]))
    assert details(missing) == [{"x", :policy, :missing_node}]
  end

  test "absent candidate node drops; disagreement rejects the whole call" do
    x = candidate("x")
    assert {:ok, r} = run([x], context([]))
    assert details(r) == [{"x", :policy, :missing_node}]

    assert {:error, {:invalid_input, :candidate_binding_mismatch}} =
             run([x], context([%{provenance_node(x) | derived_from: [ref("hidden")]}]))
  end

  test "first failed reference follows declaration order, not raw-node order" do
    denied = candidate("denied")

    for {refs, expected} <- [
          {[ref("missing"), ref("denied")], {:policy, :missing_node}},
          {[ref("denied"), ref("missing")], {:access_denied, :source_denied}}
        ] do
      root = candidate("root", refs: refs)

      assert {:ok, r} =
               run(
                 [root],
                 context([provenance_node(denied, result: :denied), provenance_node(root)])
               )

      {reason, detail} = expected
      assert details(r) == [{"root", reason, detail}]
    end
  end

  test "cycle membership fails closed; own denial precedes cycle; independent survivor" do
    a = candidate("a", refs: [ref("b")])
    b = candidate("b", refs: [ref("a")])
    good = candidate("good")

    assert {:ok, r} =
             run(
               [a, b, good],
               context([
                 provenance_node(a, result: :denied),
                 provenance_node(good),
                 provenance_node(b)
               ])
             )

    assert ids(r) == ["good"]
    assert details(r) == [{"a", :access_denied, :denied}, {"b", :policy, :cyclic_provenance}]
  end

  test "depth sixteen passes and seventeen drops" do
    for depth <- [16, 17] do
      items =
        for i <- 1..depth,
            do: candidate("n#{i}", refs: if(i == depth, do: [], else: [ref("n#{i + 1}")]))

      assert {:ok, r} = run([hd(items)], context(Enum.map(items, &provenance_node/1)))

      if depth == 16,
        do: assert(ids(r) == ["n1"]),
        else: assert(details(r) == [{"n1", :policy, :provenance_depth}])
    end
  end

  test "window, count, byte caps in that precedence; continue after oversized candidate" do
    a = candidate("large", estimate: 20)
    b = candidate("small", estimate: 1)
    nodes = [provenance_node(a), provenance_node(b)]
    assert {:ok, r} = run([a, b], context(nodes, size: 1))
    assert ids(r) == ["small"]
    assert details(r) == [{"large", :over_window, :insufficient_window}]
    assert {:ok, zero} = run([a, b], context(nodes, size: 1, count: 0, bytes: 0))

    assert details(zero) == [
             {"large", :over_window, :insufficient_window},
             {"small", :policy, :count_limit}
           ]

    assert {:ok, byte_cap} = run([b], context([provenance_node(b)], bytes: 4))
    assert details(byte_cap) == [{"small", :policy, :byte_limit}]
    empty = candidate("empty", content: "", estimate: 0)
    assert {:ok, cap} = run([empty], context([provenance_node(empty)], count: 0, bytes: 0))
    assert details(cap) == [{"empty", :policy, :count_limit}]
  end

  test "supersession includes denied retrieval candidates and unselected sources; no fallback" do
    old = candidate("x", version: 1)
    new = put_in(candidate("x", version: 2).access.result, :denied)
    assert {:ok, r} = run([old, new], context([provenance_node(old)]))

    assert details(r) == [
             {"x", :superseded, :newer_version},
             {"x", :access_denied, :retrieval_denied}
           ]

    summary = candidate("summary", refs: [ref("x", 1)])

    assert {:ok, derived} =
             run(
               [summary],
               context([provenance_node(summary), provenance_node(old), provenance_node(new)])
             )

    assert details(derived) == [{"summary", :policy, :superseded_source}]
  end

  test "dedupe domains, first eligible winner even when packing refuses, and conflicting duplicate failure" do
    digest = :crypto.hash(:sha256, "same")
    a = candidate("a", content: "same", hash: digest, estimate: 10)
    b = candidate("b", content: "same", hash: digest, estimate: 1)
    assert {:ok, r} = run([a, b], context([provenance_node(a), provenance_node(b)], size: 1))
    assert details(r) == [{"a", :over_window, :insufficient_window}, {"b", :policy, :duplicate}]
    assert {:ok, duplicate} = run([b, b], context([provenance_node(b)]))
    assert ids(duplicate) == ["b"]
    assert details(duplicate) == [{"b", :policy, :duplicate}]

    assert {:error, {:invalid_input, :conflicting_candidate}} =
             run([b, %{b | priority: 1}], context([provenance_node(b)]))

    assert {:error, {:unavailable_context, :duplicate_provenance_node}} =
             run([b], context([provenance_node(b), provenance_node(b)]))
  end

  test "all ranking modes are deterministic; future updated_at is only ranking data" do
    a = Map.put(candidate("a", priority: 2), :updated_at, 200)
    b = Map.put(candidate("b", priority: 5), :updated_at, 50)

    for {priority, recency, expected} <- [
          {:input, :input, ["a", "b"]},
          {:descending, :input, ["b", "a"]},
          {:input, :newest, ["a", "b"]},
          {:descending, :newest, ["b", "a"]}
        ] do
      ctx =
        context([provenance_node(b), provenance_node(a)])
        |> put_in([:policy, :priority], priority)
        |> put_in([:policy, :recency], recency)

      assert {:ok, r} = run([a, b], ctx)
      assert ids(r) == expected
      assert {:ok, ^r} = run([a, b], ctx)
    end
  end

  @tag timeout: 60_000
  test "full 16x16 DAG: one verdict/node, 4096 budget, 4097 rejected before evaluation" do
    items =
      for layer <- 0..15, col <- 0..15 do
        refs = if layer == 15, do: [], else: for(next <- 0..15, do: ref("#{layer + 1}:#{next}"))
        candidate("#{layer}:#{col}", refs: refs)
      end

    nodes = Enum.map(items, &provenance_node/1)
    assert length(nodes) + Enum.sum(Enum.map(nodes, &length(&1.derived_from))) == 4096
    assert 1 == :erlang.trace_pattern({@cure, :node_verdict, 5}, true, [:call_count])

    try do
      {elapsed, outcome} = :timer.tc(fn -> run([hd(items)], context(nodes)) end)
      assert {:ok, r} = outcome
      assert ids(r) == ["0:0"]
      assert {:call_count, 256} == :erlang.trace_info({@cure, :node_verdict, 5}, :call_count)
      assert elapsed < 5_000_000
      :erlang.trace_pattern({@cure, :node_verdict, 5}, :restart, [:call_count])
      over = List.update_at(nodes, 240, &%{&1 | derived_from: [ref("15:1")]})
      {over_time, over_result} = :timer.tc(fn -> run([hd(items)], context(over)) end)

      assert over_result ==
               {:error, {:unavailable_context, {:bound_exceeded, :provenance_expansions}}}

      assert {:call_count, 0} == :erlang.trace_info({@cure, :node_verdict, 5}, :call_count)
      assert over_time < 5_000_000
    after
      :erlang.trace_pattern({@cure, :node_verdict, 5}, false, [:call_count])
    end
  end

  @facade_source File.read!(Path.expand("../../lib/elzoo/context_selection.ex", __DIR__))

  defp without_proofs(source) do
    Regex.replace(
      ~r/^  @total true\n(?:  @reducible\n)?  (?:local )?fn .*?(?=^  @total true|^end\s*$)/ms,
      source,
      fn block ->
        if block =~ "-> Equivalent(", do: "", else: block
      end
    )
  end

  defp mutant(label, edits, opts \\ []) do
    changed =
      Enum.reduce(edits, @source, fn {from, to}, acc ->
        assert acc =~ from
        String.replace(acc, from, to)
      end)

    if Keyword.get(opts, :proofs_pass, false),
      do: assert(match?({:ok, _}, Cure.Compiler.check_source(changed)))

    module = "Elzoo.ContextSelectionMutation#{label}"

    runtime =
      changed |> without_proofs() |> String.replace("mod Elzoo.ContextSelection", "mod " <> module)

    assert {:ok, cure} = Cure.Compiler.compile_and_load(runtime)
    facade = "Elzoo.ContextSelectionFacade#{label}"

    code =
      @facade_source
      |> String.replace("defmodule Elzoo.ContextSelection do", "defmodule #{facade} do")
      |> String.replace(~s(@cure :"Cure.Elzoo.ContextSelection"), "@cure #{inspect(cure)}")

    [{facade_mod, _}] = Code.compile_string(code)
    facade_mod
  end

  test "selected production laws and raw correspondence declarations are present" do
    for name <-
          ~w(selected_window selected_access_law resolution_law prepared_node_law prepared_edges_law prepared_position_law memo_lookup_corresponds raw_schedule_law) do
      assert @source =~ ~r/^  fn #{name}\(/m
    end

    assert @source =~ "local fn node_verdict"
    assert {:node_verdict, 5} in @cure.module_info(:exports)
    # Local is intent, not BEAM privacy. Only select is used by the facade.
    assert Regex.scan(~r/apply\(@cure,\s*:(\w+)/, @facade_source) |> Enum.map(&List.last/1) == [
             "select"
           ]
  end

  @tag timeout: 120_000
  test "genuine production mutations fail checked laws, not just parsing" do
    edits = [
      {"window omits reservations", "sum_estimates(xs) + c.reserved <= c.window",
       "sum_estimates(xs) <= c.window"},
      {"bypass final access guard",
       "False() -> ContextSelectionFailed(ContextSelectionAccessInvariant())\n                  True() -> ContextSelectionSelected(xs, drops)",
       "False() -> ContextSelectionSelected(xs, drops)\n                  True() -> ContextSelectionSelected(xs, drops)"},
      {"skip own check", "node_after_own(all, scheduled, cache, own_failure(n, c, known))",
       "node_after_own(all, scheduled, cache, None())"},
      {"drop declared provenance edges", "edges: resolve_edges(raw, n.refs)", "edges: []"},
      {"wrong runtime cycle classification",
       "False() -> False()\n      True() -> reachable(fuel, edges_at(all, n), n, all, blank)",
       "False() -> True()\n      True() -> reachable(fuel, edges_at(all, n), n, all, blank)"},
      {"wrong positional cache", "ContextSelectionMemo{pos: scheduled_position(n), verdict:",
       "ContextSelectionMemo{pos: ContextSelectionHere(), verdict:"},
      {"wrong raw resolution", "False() -> shift(resolve(rest, key))",
       "False() -> ContextSelectionFound(ContextSelectionHere())"}
    ]

    for {{label, from, to}, i} <- Enum.with_index(edits) do
      assert @source =~ from, label
      changed = String.replace(@source, from, to)
      assert {:error, error} = Cure.Compiler.check_source(changed), label
      evidence = inspect(error, limit: :infinity)

      assert evidence =~ "conversion_failure" or evidence =~ "rewrite_no_match" or
               evidence =~ "branch_type",
             evidence

      runtime =
        changed
        |> without_proofs()
        |> String.replace(
          "mod Elzoo.ContextSelection",
          "mod Elzoo.ContextSelectionProofNegative#{i}"
        )

      assert {:ok, _} = Cure.Compiler.compile_and_load(runtime), label
    end
  end

  @tag timeout: 120_000
  test "E2 always-refuse, E3 removed filter and E4 shared weak freshness fail positive scenarios" do
    good = candidate("good")
    denied = candidate("denied")
    stale = candidate("stale")
    all = [denied, stale, good]

    ctx =
      context([
        provenance_node(good),
        provenance_node(denied, result: :denied),
        provenance_node(stale, time: 89)
      ])

    assert {:ok, baseline} = run(all, ctx)
    assert ids(baseline) == ["good"]

    e2 =
      mutant("E2", [
        {"select_prepared(xs, raw, node_keys(raw, known), c, prepare(raw, raw, ContextSelectionHere()))",
         "ContextSelectionFailed(ContextSelectionAccessInvariant())"}
      ])

    assert apply(e2, :select, [%{candidates: [good]}, context([provenance_node(good)])]) !=
             run([good], context([provenance_node(good)]))

    e3 =
      mutant("E3", [
        {"ContextSelectionRejected(detail) -> add_drop(x, detail, pack(rest, raw, cache, c, keys, remaining, count, bytes))",
         "ContextSelectionRejected(detail) -> pack_duplicate(x, rest, raw, cache, c, keys, remaining, count, bytes, seen(dedupe_key(x), keys))"}
      ])

    assert apply(e3, :select, [%{candidates: all}, ctx]) != {:ok, baseline}

    e4 =
      mutant(
        "E4",
        [
          {"c.now - current_check.checked_at <= c.max_age", "True()"},
          {"c.now - ck.checked_at <= c.max_age", "True()"}
        ],
        proofs_pass: true
      )

    assert {:ok, wrong} = apply(e4, :select, [%{candidates: all}, ctx])
    assert ids(wrong) == ["stale", "good"]
    refute wrong == baseline
  end

  @tag timeout: 120_000
  test "transitive-denial bypass and fabricated selection are caught by behavior assertions" do
    source = candidate("source")
    summary = candidate("summary", refs: [ref("source")])
    good = candidate("good")

    ctx =
      context([
        provenance_node(source, result: :denied),
        provenance_node(summary),
        provenance_node(good)
      ])

    assert {:ok, expected} = run([summary, good], ctx)
    bypass = mutant("Edges", [{"edges: resolve_edges(raw, n.refs)", "edges: []"}])
    assert apply(bypass, :select, [%{candidates: [summary, good]}, ctx]) != {:ok, expected}

    fabricate =
      mutant("Fabricate", [
        {"ContextSelectionSelected([x | xs], drops)",
         "ContextSelectionSelected([x, x | xs], drops)"}
      ])

    assert {:ok, wrong} =
             apply(fabricate, :select, [%{candidates: [good]}, context([provenance_node(good)])])

    refute length(wrong.selected) == 1
  end

  test "facade reconstruction independently vetoes injected denied retrieval evidence" do
    code =
      @facade_source
      |> String.replace(
        "defmodule Elzoo.ContextSelection do",
        "defmodule Elzoo.ContextSelectionBadReconstruction do"
      )
      |> String.replace(
        "Map.put(:retrieval_access, original.access)",
        "Map.put(:retrieval_access, %{original.access | result: :denied})"
      )

    assert code != @facade_source
    [{mod, _}] = Code.compile_string(code)
    x = candidate("x")

    assert {:error, {:invariant_failed, :access}} =
             apply(mod, :select, [%{candidates: [x]}, context([provenance_node(x)])])
  end

  test "malformed and overridden input never reaches the Cure entry" do
    assert 1 == :erlang.trace_pattern({@cure, :select, 4}, true, [:call_count])

    try do
      for request <- [nil, 0, [], %{candidates: [nil]}, %{candidates: [], policy: %{}}] do
        assert {:error, _} = S.select(request, context([]))
      end

      assert {:call_count, 0} == :erlang.trace_info({@cure, :select, 4}, :call_count)
    after
      :erlang.trace_pattern({@cure, :select, 4}, false, [:call_count])
    end
  end

  test "ingress fixed count/bytes bounds are separate from selected caps" do
    zeroes = for i <- 1..256, do: candidate("z#{i}", content: "", estimate: 0)
    assert {:ok, r} = run(zeroes, context(Enum.map(zeroes, &provenance_node/1), bytes: 0))
    assert r.selected_count == 256
    assert r.selected_bytes == 0

    assert {:error, {:invalid_input, {:bound_exceeded, :provenance}}} =
             run([candidate("absent")], context(Enum.map(zeroes, &provenance_node/1)))

    assert {:error, {:invalid_input, {:bound_exceeded, :candidates}}} =
             run([hd(zeroes) | zeroes], context([]))

    assert {:error, {:unavailable_context, {:bound_exceeded, :provenance}}} =
             run([], context(Enum.map([hd(zeroes) | zeroes], &provenance_node/1)))

    content = :binary.copy("x", 1_048_576)
    items = for i <- 1..8, do: candidate("bytes#{i}", content: content, estimate: 0)
    ctx = context(Enum.map(items, &provenance_node/1))
    assert {:ok, exact} = run(items, ctx)
    assert exact.selected_bytes == 8_388_608

    assert {:error, {:invalid_input, {:bound_exceeded, :candidate_bytes}}} =
             run([hd(items) | items], ctx)

    too_large = candidate("huge", content: content <> "x")

    assert {:error, {:invalid_input, {:bound_exceeded, :content_bytes}}} =
             run([too_large], context([]))
  end

  test "unknown windows, altered windows, snapshot inconsistency and huge reservations fail explicitly" do
    ctx = context([])

    assert {:error, {:unavailable_context, :unknown_window}} =
             run([], put_in(ctx.window.model_id, "unknown"))

    assert {:error, {:unavailable_context, :window_mismatch}} = run([], put_in(ctx.window.size, 10))

    assert {:error, {:unavailable_context, :invalid_snapshot_time}} =
             run([], %{ctx | snapshot_at: 101})

    huge = 9_007_199_254_740_991

    assert {:error, {:unavailable_context, :reservations_exceed_window}} =
             run([], context([], size: huge, reservations: [{"a", huge}, {"b", huge}]))
  end

  test "per-call derived and recency configuration is effective" do
    source = candidate("s")
    derived = candidate("d", refs: [ref("s")])
    ctx = context([provenance_node(derived), provenance_node(source)])
    assert {:ok, allowed} = run([derived], ctx)
    assert ids(allowed) == ["d"]
    assert {:ok, denied} = run([derived], put_in(ctx.policy.allow_derived, false))
    assert details(denied) == [{"d", :policy, :derived_disabled}]

    assert {:error, {:invalid_input, {:missing_field, :updated_at}}} =
             run([derived], put_in(ctx.policy.recency, :newest))
  end

  test "independent bounded DAG oracle agrees across permissions, edge sets and raw order" do
    # 3 vertices; all 8 forward-edge subsets and all 8 permission assignments.
    # Oracle uses raw map traversal with no Cure ordering, indices or cache.
    for edges <- 0..7, permissions <- 0..7 do
      items =
        for i <- 0..2 do
          refs =
            for {a, b, bit} <- [{0, 1, 0}, {0, 2, 1}, {1, 2, 2}],
                a == i,
                Bitwise.band(edges, Bitwise.bsl(1, bit)) != 0,
                do: ref("v#{b}")

          candidate("v#{i}", refs: refs)
        end

      nodes =
        for {item, i} <- Enum.with_index(items),
            do:
              provenance_node(item,
                result:
                  if(Bitwise.band(permissions, Bitwise.bsl(1, i)) != 0, do: :allowed, else: :denied)
              )

      by_id = Map.new(nodes, &{&1.item_id, &1})

      allowed = fn recurse, id ->
        n = Map.fetch!(by_id, id)
        n.check.result == :allowed and Enum.all?(n.derived_from, &recurse.(recurse, &1.item_id))
      end

      expected = Enum.filter(items, &allowed.(allowed, &1.item_id)) |> Enum.map(& &1.item_id)

      for order <- [nodes, Enum.reverse(nodes), [Enum.at(nodes, 1), Enum.at(nodes, 2), hd(nodes)]] do
        assert {:ok, result} = run(items, context(order))
        assert ids(result) == expected

        assert Enum.sort(
                 Enum.map(result.selected, & &1.index) ++ Enum.map(result.dropped, & &1.index)
               ) == [0, 1, 2]
      end
    end
  end

  test "Cure call receives metadata and byte sizes, never candidate content" do
    secret = "raw-content-not-an-identifier-2b72"
    x = candidate("safe-id", content: secret)

    {outcome, events} =
      Cure.Dev.Trace.calls(@cure, :select, fn -> run([x], context([provenance_node(x)])) end,
        arity: 4
      )

    assert {:ok, r} = outcome
    assert hd(r.selected).content == secret
    assert length(events) == 1
    [event] = events
    refute :binary.match(:erlang.term_to_binary(event.args), secret) != :nomatch
    [encoded, _, _, _] = event.args
    assert elem(hd(encoded), 5) == byte_size(secret)
  end

  test "native String, digest and numeric comparison corpus agrees with boundary encoding" do
    strings = ["", "a", "b", "é", "é", "漢字", <<0>>, String.duplicate("x", 1024)]

    for a <- strings, b <- strings do
      assert apply(@cure, :same, [
               {:String, String.to_charlist(a)},
               {:String, String.to_charlist(b)}
             ]) == (a === b)
    end

    hashes = [nil, <<0::256>>, <<1::256>>, :crypto.hash(:sha256, "a")]

    encode = fn
      nil -> :none
      h -> {:some, {:String, String.to_charlist(Base.encode16(h, case: :lower))}}
    end

    for a <- hashes, b <- hashes do
      assert apply(@cure, :hash_eq, [encode.(a), encode.(b)]) == (a === b)
    end

    for now <- [0, 1, 99, 100, 9_007_199_254_740_991], age <- [0, 1, 10], checked <- [0, 90, 100] do
      x = candidate("age")
      ctx = %{context([provenance_node(x, time: checked)]) | now: now, snapshot_at: now}
      ctx = put_in(ctx.policy.max_age, age)
      assert {:ok, r} = run([x], ctx)
      assert ids(r) == ["age"] == (checked <= now and now - checked <= age)
    end
  end

  test "ELZ-024 exact-write read-marker fixture translates allow and revoke; no general ACL claim" do
    x = candidate("report")
    marker = %{target: "report:1", field: "context-read", value: true}

    proposal = %{
      tenant: "tenant",
      resource: "report:1",
      action_id: "read:1",
      payload: nil,
      writes: [marker]
    }

    authority = %{proposer: "alice", effect_class: "read-marker", own: [marker], parent: :none}

    base = %{
      id: "read-policy",
      version: 1,
      content_hash: <<0::256>>,
      effect_classes: ["read-marker"]
    }

    for verdict <- [:allow, :deny] do
      policy =
        Map.put(base, :rules, [%{id: "host-rule", effect_class: "read-marker", verdict: verdict}])

      assert {:ok, decision} = Elzoo.Authorization.decide(policy, proposal, authority)
      assert decision.verdict == verdict

      current =
        if decision.verdict == :allow and decision.permitted == [marker],
          do: :allowed,
          else: :denied

      assert {:ok, r} = run([x], context([provenance_node(x, result: current)]))
      assert ids(r) == if(verdict == :allow, do: ["report"], else: [])
    end
  end

  @tag timeout: 120_000
  test "copied original and renamed namespace run in a separate VM without root application" do
    dir = Path.join(System.tmp_dir!(), "elz030-copy-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)
    example = File.read!(Path.expand("../../examples/brief.exs", __DIR__))

    for {name, source} <- [
          {"policy.cure", @source},
          {"facade.ex", @facade_source},
          {"brief.exs", example}
        ] do
      File.write!(Path.join(dir, name), source)

      assert :crypto.hash(:sha256, File.read!(Path.join(dir, name))) ==
               :crypto.hash(:sha256, source)
    end

    script = ~S"""
    {:ok, _} = Application.ensure_all_started(:cure)
    false = Code.ensure_loaded?(Elzoo.Application)
    false = Enum.any?(Application.started_applications(), fn {a, _, _} -> a == :elzoo end)
    cure = File.read!("policy.cure")
    {:ok, _} = Cure.Compiler.compile_and_load(cure)
    Code.compile_file("facade.ex")
    {{:ok, original}, _} = Code.eval_file("brief.exs")
    [item] = original.selected
    "Approved brief." = item.content
    15 = original.selected_bytes
    rename = fn s -> s |> String.replace("Elzoo.ContextSelection", "Copied.BriefSelection") |> String.replace("ContextSelection", "BriefSelection") end
    {:ok, renamed_module} = Cure.Compiler.compile_and_load(rename.(cure))
    Code.compile_string(rename.(File.read!("facade.ex")))
    {{:ok, renamed}, _} = Code.eval_string(rename.(File.read!("brief.exs")))
    ^original = renamed
    true = renamed_module == :"Cure.Copied.BriefSelection"
    false = Code.ensure_loaded?(Elzoo.Application)
    IO.puts("STANDALONE_OK: source hashes, original and renamed module/record tags")
    """

    script_path = Path.join(dir, "run.exs")
    File.write!(script_path, script)

    # Use only upstream artifacts, including when this test itself runs in an exported app.
    closure = fn recur, app, seen ->
      if MapSet.member?(seen, app) do
        seen
      else
        _ = Application.load(app)

        Enum.reduce(
          (Application.spec(app, :applications) || []) --
            (Application.spec(app, :optional_applications) || []),
          MapSet.put(seen, app),
          fn dependency, acc -> recur.(recur, dependency, acc) end
        )
      end
    end

    apps = closure.(closure, :cure, MapSet.new())
    refute MapSet.member?(apps, :elzoo)
    refute MapSet.member?(apps, :consumer)
    dep_paths = Enum.map(apps, &Application.app_dir(&1, "ebin"))

    args = Enum.flat_map(dep_paths, &["-pa", &1]) ++ [script_path]

    {output, exit} =
      System.cmd(System.find_executable("elixir"), args,
        cd: dir,
        stderr_to_stdout: true,
        env: [
          {"LANG", "en_US.UTF-8"},
          {"LC_ALL", "en_US.UTF-8"},
          {"ERL_FLAGS", "+S 4:4 +SDcpu 1 +SDio 1"}
        ]
      )

    assert exit == 0, output
    assert output =~ "STANDALONE_OK"
  end

  test "core envelope payload fixture keeps content version distinct from transport version" do
    x = candidate("document", version: 7)

    message = %{
      "version" => 1,
      "message_id" => "event:1",
      "schema_id" => "context/candidate",
      "schema_version" => 1,
      "kind" => "event",
      "producer" => %{"unit_id" => "retrieval", "port_id" => "out"},
      "payload" => x
    }

    assert {:ok, ^message} = Elzoo.Envelope.validate(message)
    assert {:ok, r} = run([message["payload"]], context([provenance_node(x)]))
    assert hd(r.selected).version == 7
    assert hd(r.selected).item_id == "document"
  end

  @tag timeout: 120_000
  test "F1 snapshot boundary and ancestor freshness reject checks between snapshot and now" do
    exact = candidate("snapshot-exact")
    future = candidate("snapshot-future")
    derived = candidate("snapshot-derived", refs: [ref(future.item_id)])
    items = [exact, future, derived]

    ctx = %{
      context([
        provenance_node(derived, time: 95),
        provenance_node(future, time: 97),
        provenance_node(exact, time: 95)
      ])
      | now: 100,
        snapshot_at: 95
    }

    assert {:ok, expected} = run(items, ctx)
    assert ids(expected) == ["snapshot-exact"]
    assert hd(expected.selected).access.checked_at == 95

    assert details(expected) == [
             {"snapshot-future", :stale_access_check, :future_check},
             {"snapshot-derived", :stale_access_check, :source_stale}
           ]

    weakened =
      mutant(
        "F1Snapshot",
        [
          {"current_check.checked_at <= c.snapshot", "current_check.checked_at <= c.now"},
          {"ck.checked_at <= c.snapshot", "ck.checked_at <= c.now"}
        ],
        proofs_pass: true
      )

    # Both runtime and reference were weakened: the proofs still check, but the
    # same scenario's expected selection and drops no longer hold.
    assert {:ok, wrong} = apply(weakened, :select, [%{candidates: items}, ctx])
    assert ids(wrong) == ["snapshot-exact", "snapshot-future", "snapshot-derived"]
    assert wrong.dropped == []
    refute ids(wrong) == ids(expected)
    refute details(wrong) == details(expected)
  end

  @tag timeout: 120_000
  test "F2 node tenant mismatch precedes nil current check for candidates and ancestors" do
    own = candidate("tenant-own")
    ancestor = candidate("tenant-ancestor")
    derived = candidate("tenant-derived", refs: [ref(ancestor.item_id)])
    good = candidate("tenant-good")
    items = [own, derived, good]

    ctx =
      context([
        %{provenance_node(own) | tenant: "other", check: nil},
        provenance_node(derived),
        %{provenance_node(ancestor) | tenant: "other", check: nil},
        provenance_node(good)
      ])

    assert {:ok, expected} = run(items, ctx)
    assert ids(expected) == ["tenant-good"]

    assert details(expected) == [
             {"tenant-own", :access_denied, :binding_mismatch},
             {"tenant-derived", :access_denied, :binding_mismatch}
           ]

    weakened =
      mutant(
        "F2Tenant",
        [
          {"own_tenant(n, c, known, same(n.tenant, c.tenant))", "own_tenant(n, c, known, True())"},
          {"spec_tenant(n, c, known, same(n.tenant, c.tenant))", "spec_tenant(n, c, known, True())"}
        ],
        proofs_pass: true
      )

    assert {:ok, wrong} = apply(weakened, :select, [%{candidates: items}, ctx])
    assert ids(wrong) == ["tenant-good"]

    assert details(wrong) == [
             {"tenant-own", :access_denied, :missing_check},
             {"tenant-derived", :access_denied, :source_unchecked}
           ]

    refute details(wrong) == details(expected)
  end

  test "F3 malformed contexts and nested data fail before the Cure entry" do
    item = candidate("boundary")
    node = provenance_node(item)
    ctx = context([node])
    request = %{candidates: [item]}

    cases = [
      {request, nil, :unavailable_context},
      {request, [], :unavailable_context},
      {request, %{ctx | principal: 7}, :unavailable_context},
      {request, put_in(ctx.policy.max_age, 1.5), :unavailable_context},
      {request, put_in(ctx.window.size, "1000"), :unavailable_context},
      {request, %{ctx | provenance: [node | :bad_tail]}, :unavailable_context},
      {request, %{ctx | provenance: [%{node | derived_from: 3}]}, :unavailable_context},
      {request, %{ctx | provenance: [%{node | version: 0}]}, :unavailable_context},
      {request, %{ctx | provenance: [%{node | check: "not-a-check"}]}, :unavailable_context},
      {request, %{ctx | provenance: [put_in(node.check.result, :unknown)]}, :unavailable_context},
      {request, %{ctx | provenance: [put_in(node.check.checked_at, 95.5)]}, :unavailable_context},
      {%{candidates: [%{item | content: :not_bytes}]}, ctx, :invalid_input},
      {%{candidates: [%{item | access: []}]}, ctx, :invalid_input},
      {%{candidates: [%{item | derived_from: [%{item_id: <<255>>, version: 1}]}]}, ctx,
       :invalid_input}
    ]

    assert 1 == :erlang.trace_pattern({@cure, :select, 4}, true, [:call_count])

    try do
      for {bad_request, bad_context, class} <- cases do
        assert {:error, {^class, _reason}} = S.select(bad_request, bad_context)
        assert {:call_count, 0} == :erlang.trace_info({@cure, :select, 4}, :call_count)
      end
    after
      :erlang.trace_pattern({@cure, :select, 4}, false, [:call_count])
    end
  end
end
