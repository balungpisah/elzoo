# SPDX-License-Identifier: Apache-2.0
defmodule Elzoo.AuthorizationTest do
  use ExUnit.Case, async: true
  alias Elzoo.Authorization, as: Auth

  @cure :"Cure.Elzoo.Authorization"
  @source File.read!(Path.expand("../../cure/elzoo/authorization.cure", __DIR__))
  @roots Mix.Project.config() |> Keyword.get(:cure_paths, ["cure"]) |> Enum.map(&Path.expand/1)
  @hash :binary.copy(<<7>>, 32)

  defp policy(rules, classes \\ ["publish", "read", "refund"]) do
    %{id: "pol", version: 1, content_hash: @hash, effect_classes: classes, rules: rules}
  end

  defp ask(id, opts \\ []),
    do:
      Map.merge(
        %{id: id, effect_class: "publish", verdict: :ask, requirement: req()},
        Map.new(opts)
      )

  defp allow(id, opts \\ []),
    do: Map.merge(%{id: id, effect_class: "publish", verdict: :allow}, Map.new(opts))

  defp deny(id, opts \\ []),
    do: Map.merge(%{id: id, effect_class: "publish", verdict: :deny}, Map.new(opts))

  defp req(name \\ "human", version \\ 1, scope \\ :once),
    do: %{name: name, version: version, scope: scope}

  defp w(target, field, value), do: %{target: target, field: field, value: value}
  defp post, do: w("post:1", "state", {:text, "published"})

  defp proposal(writes \\ [post()], extra \\ %{}) do
    Map.merge(
      %{
        tenant: "t1",
        resource: "post:1",
        action_id: "act-1",
        payload: {:record, [{"title", {:text, "Hi"}}]},
        writes: writes
      },
      extra
    )
  end

  defp ctx(opts \\ []) do
    Map.merge(
      %{proposer: "agent-1", effect_class: "publish", own: [post()], parent: :none},
      Map.new(opts)
    )
  end

  defp decide(rules, prop \\ proposal(), c \\ ctx()), do: Auth.decide(policy(rules), prop, c)

  defp verdict(result) do
    {:ok, d} = result
    {d.verdict, d.reason, d.permitted, d.escrowed}
  end

  # ------------------------------------------------------------------ Cure laws

  test "production Cure audit is clean: no axioms, holes, opacity or unproven totality" do
    assert {:ok, env} = Cure.Compiler.check_source(@source, source_roots: @roots)
    report = Cure.Audit.Ledger.audit_env(env)

    for key <- [:axioms, :holes, :unresolved, :unaudited, :opaque, :not_proven_total] do
      assert Map.fetch!(report, key) == [], "#{key}: #{inspect(Map.fetch!(report, key))}"
    end

    assert report.absurd == 0
  end

  test "every Cure function and law is marked total" do
    fns = Regex.scan(~r/^  fn (\w+)\(/m, @source, capture: :all_but_first) |> length()
    totals = Regex.scan(~r/^  @total true\n(?:  @reducible\n)?  fn /m, @source) |> length()
    assert fns > 0 and fns == totals
  end

  defp mutated(name, from, to) do
    assert String.contains?(@source, from), "mutation anchor missing: #{from}"

    src =
      @source
      |> String.replace("mod Elzoo.Authorization", "mod Elzoo.AuthorizationNeg" <> name)
      |> String.replace(from, to, global: false)

    refute src == @source
    Cure.Compiler.compile_and_load(src, source_roots: @roots)
  end

  test "negative control: DENY no longer absorbing is rejected by the precedence laws" do
    assert {:error, {:codegen_error, {:source_context, {:conversion_failure, _, _}, _}}} =
             mutated(
               "Join",
               "    match a\n      AuthDeny() -> AuthDeny()\n      AuthAsk() ->",
               "    match a\n      AuthDeny() -> b\n      AuthAsk() ->"
             )
  end

  test "negative control: ASK permitting its writes is rejected by the escrow laws" do
    assert {:error,
            {:codegen_error,
             {:source_context, {:conversion_failure, _, _}, %{checking: :ask_permits_nothing}}}} =
             mutated(
               "Ask",
               "reason: ReasonAsk(), permitted: [], escrowed: ws",
               "reason: ReasonAsk(), permitted: ws, escrowed: ws"
             )
  end

  test "negative control: skipping own-authority containment is rejected by non-escalation" do
    assert {:error,
            {:codegen_error,
             {:source_context, {:conversion_failure, _, _},
              %{checking: :contain_permitted_within_own}}}} =
             mutated(
               "Contain",
               "    match own_ok\n      False() -> exceeded()",
               "    match own_ok\n      False() -> evaluate(policy, a, ws)"
             )
  end

  test "negative control: text equal to bytes is rejected by constructor distinctness" do
    assert {:error, {:codegen_error, {:source_context, {:conversion_failure, _, _}, _}}} =
             mutated(
               "Text",
               "          AVText(y) -> eq_ints(x, y)\n          _ -> False()",
               "          AVText(y) -> eq_ints(x, y)\n          AVBytes(y) -> eq_ints(x, y)\n          _ -> False()"
             )
  end

  test "negative control: an unfinished law is a hole, not a proof" do
    assert {:error, {:codegen_error, {:unfilled_hole, info}}} =
             mutated(
               "Hole",
               "      [v | rest] -> rewrite deny_anywhere(rest, s) in deny_absorbs_right(v)",
               "      [v | rest] -> ?unfinished"
             )

    assert info.definition == :"Elzoo.AuthorizationNegHole#deny_anywhere"
  end

  test "Cure join is the deny > ask > allow maximum on every pair" do
    rank = %{AuthAllow: 0, AuthAsk: 1, AuthDeny: 2}

    for a <- Map.keys(rank), b <- Map.keys(rank) do
      expected = if rank[a] >= rank[b], do: a, else: b
      assert apply(@cure, :join, [a, b]) == expected
    end
  end

  # ------------------------------------------------------------------ verdicts

  test "ALLOW permits all writes; ASK escrows the whole action; DENY permits nothing" do
    assert {:allow, :allowed, [p], []} = verdict(decide([allow("a")]))
    assert p == post()
    assert {:ask, {:ask, %{name: "human"}}, [], [^p]} = verdict(decide([ask("q")]))
    assert {:deny, {:rule, "d"}, [], []} = verdict(decide([deny("d")]))
  end

  test "deny > ask > allow regardless of rule order" do
    for rules <- [
          [allow("a"), ask("q"), deny("d")],
          [deny("d"), ask("q"), allow("a")],
          [ask("q"), deny("d"), allow("a")]
        ] do
      assert {:deny, {:rule, "d"}, [], []} = verdict(decide(rules))
    end

    assert {:ask, _, [], [_]} = verdict(decide([allow("a"), ask("q")]))
    assert {:ask, _, [], [_]} = verdict(decide([ask("q"), allow("a")]))
  end

  test "a write with no applicable rule is default DENY, and the action follows it" do
    other = w("post:1", "body", {:text, "x"})
    c = ctx(own: [post(), other])
    rules = [allow("a", field: {:exact, "state"})]
    assert {:deny, :no_matching_rule, [], []} = verdict(decide(rules, proposal([post(), other]), c))
    assert {:deny, :no_matching_rule, [], []} = verdict(decide([]))
  end

  test "rule conditions on principal, tenant, resource, payload and write value change the verdict" do
    base = [allow("a")]

    assert {:deny, {:rule, "p"}, _, _} =
             verdict(decide(base ++ [deny("p", principal: {:exact, "agent-1"})]))

    assert {:allow, _, _, _} = verdict(decide(base ++ [deny("p", principal: {:exact, "someone"})]))
    assert {:deny, _, _, _} = verdict(decide(base ++ [deny("t", tenant: {:exact, "t1"})]))
    assert {:allow, _, _, _} = verdict(decide(base ++ [deny("t", tenant: {:exact, "t2"})]))
    assert {:deny, _, _, _} = verdict(decide(base ++ [deny("r", resource: {:exact, "post:1"})]))
    payload = {:record, [{"title", {:text, "Hi"}}]}
    assert {:ask, _, _, _} = verdict(decide(base ++ [ask("y", payload: {:exact, payload})]))
    assert {:allow, _, _, _} = verdict(decide(base ++ [ask("y", payload: {:exact, {:text, "Hi"}})]))

    refund = fn amount ->
      wr = w("refund:9", "amount", amount)

      rules = [
        %{
          id: "big",
          effect_class: "refund",
          value: {:exact, 500},
          verdict: :ask,
          requirement: req()
        }
      ]

      Auth.decide(policy(rules), proposal([wr]), ctx(effect_class: "refund", own: [wr]))
    end

    assert {:ask, _, [], [_]} = verdict(refund.(500))
    assert {:deny, :no_matching_rule, [], []} = verdict(refund.(499))
  end

  test "rules match the exact typed effect class only" do
    assert {:deny, :no_matching_rule, _, _} = verdict(decide([allow("a", effect_class: "read")]))
  end

  # ------------------------------------------------------------------ trusted context

  test "forged proposer: a proposal claiming another proposer is rejected whole" do
    assert {:error, {:invalid_input, :proposer_mismatch}} =
             decide([ask("q")], proposal([post()], %{proposer: "human-reviewer"}))

    {:ok, d} = decide([ask("q")], proposal([post()], %{proposer: "agent-1"}))
    assert d.action.proposer == "agent-1"
    {:ok, d} = decide([ask("q")])
    assert d.action.proposer == "agent-1"
  end

  test "mislabelled effect class cannot turn ASK into ALLOW" do
    rules = [ask("pub"), %{id: "rd", effect_class: "read", verdict: :allow}]

    assert {:error, {:invalid_input, :effect_class_mismatch}} =
             decide(rules, proposal([post()], %{effect_class: "read"}))

    assert {:ask, _, [], [_]} = verdict(decide(rules))

    assert {:ask, _, [], [_]} =
             verdict(decide(rules, proposal([post()], %{effect_class: "publish"})))
  end

  test "containment rejects the whole proposal; child is bounded by its parent" do
    extra = w("post:2", "state", {:text, "published"})

    assert {:deny, :authority_exceeded, [], []} =
             verdict(decide([allow("a")], proposal([post(), extra])))

    child = ctx(own: [post(), extra], parent: [post()])

    assert {:deny, :authority_exceeded, [], []} =
             verdict(decide([allow("a")], proposal([post(), extra]), child))

    assert {:allow, _, [_], []} = verdict(decide([allow("a")], proposal([post()]), child))

    assert {:deny, :authority_exceeded, [], []} =
             verdict(decide([allow("a")], proposal([post()]), ctx(parent: [])))
  end

  test "authority holds exact values: another value for the same target and field is outside it" do
    other = w("post:1", "state", {:text, "draft"})
    assert {:deny, :authority_exceeded, [], []} = verdict(decide([allow("a")], proposal([other])))
  end

  test "missing or invalid trusted context is unavailable_context, distinct from DENY and invalid input" do
    assert {:error, {:unavailable_context, {:missing_field, :own}}} =
             Auth.decide(policy([allow("a")]), proposal(), Map.delete(ctx(), :own))

    assert {:error, {:unavailable_context, :undeclared_effect_class}} =
             Auth.decide(policy([allow("a")]), proposal(), ctx(effect_class: "unknown"))

    assert {:error, {:unavailable_context, {:invalid_policy, _}}} =
             Auth.decide(%{policy([allow("a")]) | content_hash: "short"}, proposal(), ctx())

    assert {:error, {:unavailable_context, {:invalid_policy, :ask_without_requirement}}} =
             Auth.decide(
               policy([%{id: "q", effect_class: "publish", verdict: :ask}]),
               proposal(),
               ctx()
             )

    assert {:error, {:unavailable_context, {:invalid_policy, :duplicate_rule_id}}} =
             Auth.decide(policy([allow("a"), deny("a")]), proposal(), ctx())

    assert {:error, {:unavailable_context, {:conflicting_authority, "post:1", "state"}}} =
             Auth.decide(
               policy([allow("a")]),
               proposal(),
               ctx(own: [post(), w("post:1", "state", 1)])
             )

    assert {:error, {:unavailable_context, _}} = Auth.decide(nil, proposal(), ctx())
  end

  test "ambiguous ASK requirement fails closed" do
    rules = [ask("q1"), ask("q2", requirement: req("legal"))]
    assert {:error, {:unavailable_context, {:ambiguous_requirement, [_, _]}}} = decide(rules)
    assert {:ask, _, _, _} = verdict(decide([ask("q1"), ask("q2")]))
  end

  # ------------------------------------------------------------------ proposal faults

  test "atom control keys are DENY with policy identity; string keys are invalid input" do
    for key <- Auth.control_keys() do
      {:ok, d} = decide([allow("a")], Map.put(proposal(), key, :anything))
      assert d.verdict == :deny and d.reason == {:control_field, key}
      assert d.policy == %{id: "pol", version: 1, content_hash: @hash}
      assert d.permitted == [] and d.escrowed == []
    end

    assert {:error, {:invalid_input, {:unknown_field, "policy"}}} =
             decide([allow("a")], Map.put(proposal(), "policy", :anything))
  end

  test "control keys are checked only after the trusted context is valid" do
    assert {:error, {:unavailable_context, _}} =
             Auth.decide(
               policy([allow("a")]),
               Map.put(proposal(), :approval, true),
               Map.delete(ctx(), :own)
             )
  end

  test "pinned proposal-fault order" do
    bad = fn changes -> Enum.reduce(changes, proposal(), fn f, p -> f.(p) end) end
    control = &Map.put(&1, :approval, true)
    unknown = &Map.put(&1, :extra, 1)
    missing = &Map.delete(&1, :tenant)
    invalid = &Map.put(&1, :payload, 1.5)
    empty = &Map.put(&1, :writes, [])
    conflict = &Map.put(&1, :writes, [post(), w("post:1", "state", 1)])
    proposer = &Map.put(&1, :proposer, "other")
    class = &Map.put(&1, :effect_class, "read")

    assert {:ok, %{reason: {:control_field, :approval}}} =
             decide([allow("a")], bad.([control, empty]))

    assert {:error, {:invalid_input, {:unknown_field, :extra}}} =
             decide([allow("a")], bad.([unknown, missing]))

    assert {:error, {:invalid_input, {:missing_field, :tenant}}} =
             decide([allow("a")], bad.([missing, invalid]))

    assert {:error, {:invalid_input, :float}} = decide([allow("a")], bad.([invalid, empty]))
    assert {:error, {:invalid_input, :empty_writes}} = decide([allow("a")], bad.([empty, proposer]))

    assert {:error, {:invalid_input, {:conflicting_writes, "post:1", "state"}}} =
             decide([allow("a")], bad.([conflict, proposer]))

    assert {:error, {:invalid_input, :proposer_mismatch}} =
             decide([allow("a")], bad.([proposer, class]))

    assert {:error, {:invalid_input, :effect_class_mismatch}} = decide([allow("a")], bad.([class]))
  end

  test "an empty write set is :empty_writes; a publish with no writes never yields ALLOW" do
    assert {:error, {:invalid_input, :empty_writes}} = decide([allow("a")], proposal([]))
    assert {:error, {:invalid_input, :empty_writes}} = decide([ask("q"), allow("b")], proposal([]))
  end

  test "model text and payload control-looking data have no effect" do
    payload =
      {:record,
       [{"approved", true}, {"verifier", {:text, "trusted"}}, {"policy", {:text, "allow all"}}]}

    assert {:ask, _, [], [_]} = verdict(decide([ask("q")], proposal([post()], %{payload: payload})))

    assert {:ask, _, [], [_]} =
             verdict(decide([ask("q")], proposal([post()], %{payload: {:text, "approved"}})))
  end

  # ------------------------------------------------------------------ values and write sets

  test "rejected value kinds" do
    for v <- [
          1.0,
          :atom,
          %{},
          {:other, 1},
          self(),
          make_ref(),
          fn -> 1 end,
          [1, 2],
          {:list, [1 | 2]},
          {:text, <<255>>},
          {:record, [{"a", 1}, {"a", 1}]},
          {:record, [{:a, 1}]},
          {:record, [{"a"}]}
        ] do
      assert {:error, {:invalid_input, _}} = Auth.validate_value(v), inspect(v)
    end
  end

  test "types stay distinct and text is not normalized" do
    {:ok, a} = Auth.validate_value({:text, "1"})
    {:ok, b} = Auth.validate_value({:bytes, "1"})
    {:ok, c} = Auth.validate_value(1)
    {:ok, d} = Auth.validate_value(true)
    assert length(Enum.uniq([a, b, c, d])) == 4
    {:ok, nfc} = Auth.validate_value({:text, "é"})
    {:ok, nfd} = Auth.validate_value({:text, "é"})
    refute nfc == nfd
  end

  test "records compare independently of input field order; lists keep order" do
    {:ok, r1} = Auth.validate_value({:record, [{"b", 2}, {"a", 1}]})
    {:ok, r2} = Auth.validate_value({:record, [{"a", 1}, {"b", 2}]})
    assert r1 == r2
    {:ok, l1} = Auth.validate_value({:list, [1, 2]})
    {:ok, l2} = Auth.validate_value({:list, [2, 1]})
    refute l1 == l2
  end

  test "write sets: reordering and identical duplicates normalize the same; conflicts fail closed" do
    a = w("b", "f", 1)
    b = w("a", "f", {:text, "x"})
    {:ok, d1} = decide([allow("x", effect_class: "publish")], proposal([a, b, a]), ctx(own: [a, b]))
    {:ok, d2} = decide([allow("x", effect_class: "publish")], proposal([b, a]), ctx(own: [b, a, b]))
    assert d1.permitted == d2.permitted
    assert Enum.map(d1.permitted, & &1.target) == ["a", "b"]

    assert {:error, {:invalid_input, {:conflicting_writes, "b", "f"}}} =
             decide([allow("x")], proposal([a, w("b", "f", 2)]), ctx(own: [a]))
  end

  test "bounds: each limit is accepted and limit + 1 is rejected without truncation" do
    nest = fn n -> Enum.reduce(1..(n - 1)//1, nil, fn _, acc -> {:list, [acc]} end) end
    assert {:ok, _} = Auth.validate_value(nest.(16))
    assert {:error, {:invalid_input, {:bound_exceeded, :depth}}} = Auth.validate_value(nest.(17))

    assert {:ok, _} = Auth.validate_value({:list, List.duplicate(1, 4095)})

    assert {:error, {:invalid_input, {:bound_exceeded, :nodes}}} =
             Auth.validate_value({:list, List.duplicate(1, 4096)})

    assert {:ok, _} = Auth.validate_value({:text, String.duplicate("a", 4096)})

    assert {:error, {:invalid_input, {:bound_exceeded, :text}}} =
             Auth.validate_value({:text, String.duplicate("a", 4097)})

    assert {:error, {:invalid_input, {:bound_exceeded, :bytes}}} =
             Auth.validate_value({:bytes, :binary.copy(<<0>>, 4097)})

    max = Integer.pow(2, 256)
    assert {:ok, _} = Auth.validate_value(max - 1)
    assert {:ok, _} = Auth.validate_value(-(max - 1))
    assert {:error, {:invalid_input, {:bound_exceeded, :integer}}} = Auth.validate_value(max)

    id = String.duplicate("i", 1024)
    assert {:ok, _} = decide([allow("a")], proposal([post()], %{action_id: id}))

    assert {:error, {:invalid_input, {:bound_exceeded, :action_id}}} =
             decide([allow("a")], proposal([post()], %{action_id: id <> "i"}))

    writes = for i <- 1..257, do: w("t#{i}", "f", 1)
    assert {:ok, _} = decide([allow("a")], proposal(Enum.take(writes, 256)), ctx(own: writes))

    assert {:error, {:invalid_input, {:bound_exceeded, :writes}}} =
             decide([allow("a")], proposal(writes), ctx(own: writes))

    auth = for i <- 1..4097, do: w("t#{i}", "f", 1)
    assert {:ok, _} = decide([allow("a")], proposal([hd(auth)]), ctx(own: Enum.take(auth, 4096)))

    assert {:error, {:unavailable_context, {:bound_exceeded, :authority}}} =
             decide([allow("a")], proposal([hd(auth)]), ctx(own: auth))

    rules = for i <- 1..1025, do: allow("r#{i}")
    assert {:ok, _} = decide(Enum.take(rules, 1024))

    assert {:error, {:unavailable_context, {:invalid_policy, {:bound_exceeded, :rules}}}} =
             decide(rules)

    v = Integer.pow(2, 31) - 1
    assert {:ok, _} = Auth.decide(%{policy([allow("a")]) | version: v}, proposal(), ctx())

    assert {:error, {:unavailable_context, {:invalid_policy, :version}}} =
             Auth.decide(%{policy([allow("a")]) | version: v + 1}, proposal(), ctx())
  end

  # ------------------------------------------------------------------ agreement

  test "Elixir structural equality agrees with Cure eq_value on a listed corpus" do
    corpus = [
      nil,
      true,
      false,
      0,
      1,
      -1,
      Integer.pow(2, 200),
      {:text, ""},
      {:text, "1"},
      {:bytes, "1"},
      {:bytes, ""},
      {:text, "é"},
      {:text, "é"},
      {:list, []},
      {:list, [1, 2]},
      {:list, [2, 1]},
      {:record, []},
      {:record, [{"a", 1}, {"b", {:text, "x"}}]},
      {:record, [{"b", {:text, "x"}}, {"a", 1}]},
      {:record, [{"a", 1}]},
      {:record, [{"a", {:list, [nil, true]}}]}
    ]

    normalized =
      Enum.map(corpus, fn v ->
        {:ok, n} = Auth.validate_value(v)
        n
      end)

    for a <- normalized, b <- normalized do
      assert apply(@cure, :eq_value, [Auth.encode_value(a), Auth.encode_value(b)]) == (a == b),
             "#{inspect(a)} vs #{inspect(b)}"
    end

    for n <- normalized, do: assert(Auth.decode_value(Auth.encode_value(n)) == n)
  end

  test "proposer_view disclosure modes" do
    {:ok, d} = decide([deny("d")])
    assert Auth.proposer_view(d, :full) == d
    assert Auth.proposer_view(d, :verdict_only) == %{verdict: :deny, policy: d.policy}
  end

  test "same_action? is structural over normalized actions" do
    {:ok, d1} = decide([ask("q")], proposal([post()], %{payload: {:record, [{"b", 1}, {"a", 2}]}}))
    {:ok, d2} = decide([ask("q")], proposal([post()], %{payload: {:record, [{"a", 2}, {"b", 1}]}}))
    {:ok, d3} = decide([ask("q")], proposal([post()], %{payload: {:record, [{"a", 2}, {"b", 2}]}}))
    assert Auth.same_action?(d1.action, d2.action)
    refute Auth.same_action?(d1.action, d3.action)
  end
end
