# SPDX-License-Identifier: Apache-2.0
defmodule Elzoo.BudgetTest do
  use ExUnit.Case, async: true
  alias Elzoo.Budget, as: B

  @cure :"Cure.Elzoo.Budget"
  @source File.read!(Path.expand("../../cure/elzoo/budget.cure", __DIR__))
  @roots Mix.Project.config() |> Keyword.get(:cure_paths, ["cure"]) |> Enum.map(&Path.expand/1)

  @laws ~w(admission_cap overage_admits_nothing settle_idempotent release_idempotent
           release_expired_replays reserve_rejection_keeps_state settle_rejection_keeps_state
           release_rejection_keeps_state reset_rejection_keeps_state settle_open_derived
           settle_expired_derived settle_released_derived settle_first_derived settle_first_stores
           late_refund_is_zero on_time_refund_is_difference overage_is_difference)

  @now 1_000_000

  defp fresh(cap \\ 10), do: elem(B.initial("run-42/tokens", "inc-a", cap, "tokens"), 1)
  defp gen(counter \\ 1), do: {"inc-a", counter}

  defp run(state, input, now \\ @now) do
    {:Transition, next, {:some, result}} = B.step(state, {now, input})
    {next, result}
  end

  defp reserve(ref, estimate, expiry \\ @now + 1_000, cap \\ 10, unit \\ "tokens"),
    do: {:reserve, %{cap: cap, unit: unit, estimate: estimate, cost_ref: ref, expiry: expiry}}

  defp settle(ref, actual, g \\ gen()),
    do: {:settle, %{cost_ref: ref, generation: g, actual: actual}}

  defp release(ref, g \\ gen()), do: {:release, %{cost_ref: ref, generation: g}}
  defp reset(g \\ gen()), do: {:reset, %{generation: g}}

  defp scalars({:BudgetState, _, cap, _, _, committed, reserved, _}), do: {cap, committed, reserved}

  describe "Cure laws" do
    test "selected laws L1-L6 compile with a clean audit" do
      assert {:module, @cure} = Code.ensure_loaded(@cure)
      assert {:ok, env} = Cure.Compiler.check_source(@source, source_roots: @roots)
      report = Cure.Audit.Ledger.audit_env(env)

      for key <- [:axioms, :holes, :unresolved, :unaudited, :opaque, :not_proven_total],
          do: assert(Map.fetch!(report, key) == [], "#{key}: #{inspect(Map.fetch!(report, key))}")

      assert report.absurd == 0

      for law <- @laws,
          do: assert(@source =~ ~r/^  fn #{law}\(/m, "missing law #{law}")
    end

    @mutations [
      {"admission_cap", "new_entry_cap",
       "fn fits_new(s: BudgetState, estimate: Int) -> Bool = s.committed + (s.reserved + estimate) <= s.cap",
       "fn fits_new(s: BudgetState, estimate: Int) -> Bool = s.committed + s.reserved <= s.cap"},
      {"overage_admits_nothing", "reserve_with_cap", "              True() -> reject(s, :overage)",
       "              True() -> admit_new(s, cost_ref, estimate, expiry)"},
      {"settle_idempotent", "settle_repeat_same",
       "      True() -> Step{state: s, result: derive(estimate, actual, late)}",
       "      True() -> Step{state: s, result: derive(estimate, actual, False())}"},
      {"release_idempotent", "release_released_with",
       "      Released(_e) -> Step{state: s, result: ReleasedOk()}",
       "      Released(e) -> Step{state: with_scalars(s, s.generation, s.committed, s.reserved - e, s.entries), result: ReleasedOk()}"},
      {"reserve_rejection_keeps_state", "new_entry_kept",
       "      False() -> reject(s, :insufficient)\n\n  @total true\n  @reducible\n  fn admit_new(",
       "      False() -> Step{state: admitted(s, cost_ref, estimate, expiry), result: Rejected(:insufficient)}\n\n  @total true\n  @reducible\n  fn admit_new("},
      {"settle_expired_derived", "settle_entry_kept",
       "      Expired(e) -> settle_first(s, cost_ref, actual, e, True(), s.reserved)",
       "      Expired(e) -> settle_first(s, cost_ref, actual, e, False(), s.reserved)"}
    ]

    test "negative controls: each broken transition is rejected by Cure" do
      for {law, rejected_at, from, to} <- @mutations do
        assert String.contains?(@source, from), "mutation anchor missing for #{law}"

        wrong =
          @source
          |> String.replace("mod Elzoo.Budget", "mod Elzoo.WrongBudget")
          |> String.replace(from, to, global: false)

        assert {:error, error} = Cure.Compiler.check_source(wrong, source_roots: @roots),
               "mutation for #{law} was accepted"

        # The rejection names the law proof that no longer checks.
        assert inspect(error, limit: :infinity, printable_limit: :infinity) =~
                 "checking: :#{rejected_at}",
               "mutation for #{law} was not rejected at #{rejected_at}"
      end
    end
  end

  describe "initial state and I0" do
    test "initial validates and seals" do
      assert {:ok, state} = B.initial("b", "i", 5, "calls")
      assert B.readable?(state)
      assert B.initial("", "i", 5, "calls") == {:error, :invalid_input}
      assert B.initial("b", "i", 0, "calls") == {:error, :invalid_amount}
      assert B.initial("b", "i", 1.0, "calls") == {:error, :invalid_amount}
      assert B.initial("b", "i", 5, "") == {:error, :invalid_unit}
      assert B.initial("b", "i", 5, <<255>>) == {:error, :invalid_unit}
    end

    test "a state that fails I0 rejects every input, including reset, and is not swept" do
      {state, {:reserved, _}} = run(fresh(), reserve("a", 4, @now + 10))
      broken = put_elem(state, 6, 0)
      negative = put_elem(state, 5, -1)
      bad_entry = put_elem(state, 7, [{:EntryRow, {:String, ~c"a"}, {:Open, 0, 1}}])

      for bad <- [broken, negative, bad_entry, :garbage, nil, {:BudgetState}] do
        refute B.readable?(bad)

        for input <- [reserve("b", 1), settle("a", 1), release("a"), reset(), :status, :sweep] do
          assert B.step(bad, {@now + 100, input}) ==
                   {:Transition, bad, {:some, {:rejected, :unreadable}}}
        end
      end
    end
  end

  describe "admission" do
    test "reserve records in one step and reports remaining" do
      {s, r} = run(fresh(), reserve("a", 4))
      assert r == {:reserved, %{cost_ref: "a", generation: gen(), estimate: 4, remaining: 6}}
      assert scalars(s) == {10, 0, 4}
      {s, r} = run(s, reserve("b", 6))
      assert {:reserved, %{remaining: 0}} = r
      assert {_, {:rejected, :insufficient}} = run(s, reserve("c", 1))
    end

    test "changed limits are rejected from the first call" do
      assert {_, {:rejected, :changed_limits}} = run(fresh(), reserve("a", 1, @now + 10, 11))

      assert {_, {:rejected, :changed_limits}} =
               run(fresh(), reserve("a", 1, @now + 10, 10, "calls"))
    end

    test "invalid inputs map to their reasons and change nothing" do
      s = fresh()

      cases = [
        {{:reserve, %{cap: 10, unit: "tokens", estimate: 0, cost_ref: "a", expiry: @now + 1}},
         :invalid_amount},
        {{:reserve, %{cap: 10, unit: "tokens", estimate: -1, cost_ref: "a", expiry: @now + 1}},
         :invalid_amount},
        {{:reserve, %{cap: 10, unit: "tokens", estimate: 1.0, cost_ref: "a", expiry: @now + 1}},
         :invalid_amount},
        {{:reserve, %{cap: 10, unit: "tokens", estimate: "1", cost_ref: "a", expiry: @now + 1}},
         :invalid_amount},
        {{:reserve, %{cap: 10, unit: "", estimate: 1, cost_ref: "a", expiry: @now + 1}},
         :invalid_unit},
        {{:reserve, %{cap: 10, unit: "tokens", estimate: 1, cost_ref: "", expiry: @now + 1}},
         :invalid_cost_ref},
        {{:reserve, %{cap: 10, unit: "tokens", estimate: 1, cost_ref: "a", expiry: 1.5}},
         :invalid_input},
        {{:reserve, %{cap: 10, unit: "tokens", estimate: 1, cost_ref: "a", expiry: @now}},
         :invalid_expiry},
        {{:reserve, %{cap: 10, unit: "tokens", estimate: 1, cost_ref: "a"}}, :invalid_input},
        {{:reserve,
          %{cap: 10, unit: "tokens", estimate: 1, cost_ref: "a", expiry: @now + 1, extra: 1}},
         :invalid_input},
        {{:reserve,
          %{
            "cap" => 10,
            :unit => "tokens",
            "estimate" => 1,
            "cost_ref" => "a",
            "expiry" => @now + 1
          }}, :invalid_input},
        {{:reserve,
          %{
            "cap" => 10,
            :cap => 10,
            "unit" => "tokens",
            "estimate" => 1,
            "cost_ref" => "a",
            "expiry" => 9
          }}, :invalid_input},
        {{:settle, %{cost_ref: "a", generation: {"inc-a", 0}, actual: 1}}, :invalid_input},
        {{:settle, %{cost_ref: "a", generation: "inc-a", actual: 1}}, :invalid_input},
        {{:settle, %{cost_ref: "a", generation: gen(), actual: 0}}, :invalid_amount},
        {{:release, %{cost_ref: "a", generation: {1, 1}}}, :invalid_input},
        {{:reset, %{generation: nil}}, :invalid_input},
        {{:bogus, %{}}, :invalid_input},
        {:other, :invalid_input}
      ]

      for {input, reason} <- cases do
        assert B.step(s, {@now, input}) == {:Transition, s, {:some, {:rejected, reason}}},
               inspect(input)
      end

      for now <- [0, -1, 1.0, nil] do
        assert B.step(s, {now, :status}) == {:Transition, s, {:some, {:rejected, :invalid_input}}}
      end

      assert B.step(s, :not_a_pair) == {:Transition, s, {:some, {:rejected, :invalid_input}}}
    end

    test "string-keyed maps are accepted" do
      input =
        {:reserve,
         %{
           "cap" => 10,
           "unit" => "tokens",
           "estimate" => 2,
           "cost_ref" => "a",
           "expiry" => @now + 5
         }}

      assert {_, {:reserved, %{estimate: 2}}} = run(fresh(), input)
    end
  end

  describe "replay, expiry and late settle" do
    test "reserve replay returns the original result without a second reservation" do
      {s, r1} = run(fresh(), reserve("a", 4, @now + 50))
      {s2, r2} = run(s, reserve("a", 4, @now + 50))
      assert r1 == r2 and s2 == s
      assert {^s, {:rejected, :cost_ref_conflict}} = run(s, reserve("a", 4, @now + 51))
      assert {^s, {:rejected, :cost_ref_conflict}} = run(s, reserve("a", 5, @now + 50))
    end

    test "expiry is reached when now >= expiry" do
      {s, _} = run(fresh(), reserve("a", 4, @now + 10))
      {s1, {:status, st}} = run(s, :status, @now + 9)
      assert st.reserved == 4 and st.open == 1
      {_, {:status, st}} = run(s1, :status, @now + 10)
      assert st.reserved == 0 and st.open == 0
      {_, r} = run(s, :sweep, @now + 10)
      assert r == {:swept, %{expired: 1}}
      {s3, _} = run(s, :sweep, @now + 10)
      assert {_, {:rejected, :cost_ref_closed}} = run(s3, reserve("a", 4, @now + 100), @now + 11)
    end

    test "out-of-order now never reopens an expired entry" do
      {s, _} = run(fresh(), reserve("a", 4, @now + 10))
      {s, _} = run(s, :sweep, @now + 20)
      {s2, {:status, st}} = run(s, :status, @now + 1)
      assert st.reserved == 0 and st.open == 0 and s2 == s
    end

    test "expire, reuse, late settle into overage, next reserve rejected (cap 10)" do
      {s, _} = run(fresh(), reserve("a", 6, @now + 10))
      {s, {:reserved, _}} = run(s, reserve("b", 6, @now + 100), @now + 10)
      assert scalars(s) == {10, 0, 6}
      {s, r} = run(s, settle("a", 9), @now + 11)
      assert r == {:settled, %{cost_ref: "a", generation: gen(), overage: 3, late: true}}
      assert scalars(s) == {10, 9, 6}
      assert B.readable?(s)
      {_, {:status, st}} = run(s, :status, @now + 12)
      assert st.remaining == 0
      assert {^s, {:rejected, :insufficient}} = run(s, reserve("b", 6, @now + 100), @now + 12)
      {s, _} = run(s, settle("b", 6), @now + 12)
      assert scalars(s) == {10, 15, 0}
      assert {^s, {:rejected, :overage}} = run(s, reserve("c", 1, @now + 100), @now + 12)
    end

    test "replay under overage caused by another entry's late settle" do
      {s, _} = run(fresh(), reserve("a", 5, @now + 10))
      {s, _} = run(s, reserve("b", 5, @now + 100), @now + 10)
      {s, _} = run(s, settle("a", 11), @now + 11)
      {_, cap_committed, _} = scalars(s)
      assert cap_committed == 11
      assert {^s, {:rejected, :overage}} = run(s, reserve("b", 5, @now + 100), @now + 12)
      {s, r} = run(s, settle("b", 2), @now + 12)
      assert r == {:settled, %{cost_ref: "b", generation: gen(), refund: 3, late: false}}
      assert scalars(s) == {10, 13, 0}
    end

    test "replay without overage: cap 10, expire/reuse/late-settle 5 gives insufficient" do
      {s, _} = run(fresh(), reserve("a", 6, @now + 10))
      {s, _} = run(s, reserve("b", 6, @now + 100), @now + 10)
      {s, r} = run(s, settle("a", 5), @now + 11)
      assert r == {:settled, %{cost_ref: "a", generation: gen(), refund: 0, late: true}}
      assert scalars(s) == {10, 5, 6}
      assert {^s, {:rejected, :insufficient}} = run(s, reserve("b", 6, @now + 100), @now + 12)
      {_, r} = run(s, release("b"), @now + 12)
      assert r == {:released, %{cost_ref: "b", generation: gen()}}
    end
  end

  describe "settle and release (L3/L4 link through step/2)" do
    test "repeat settle returns the identical state and result, non-late and late" do
      {s, _} = run(fresh(), reserve("a", 4, @now + 10))
      {s, _} = run(s, reserve("b", 4, @now + 5))

      {s1, r1} = run(s, settle("a", 3), @now + 6)
      assert r1 == {:settled, %{cost_ref: "a", generation: gen(), refund: 1, late: false}}
      assert run(s1, settle("a", 3), @now + 6) == {s1, r1}
      assert {^s1, {:rejected, :actual_conflict}} = run(s1, settle("a", 4), @now + 6)

      {s2, r2} = run(s1, settle("b", 7), @now + 6)
      assert r2 == {:settled, %{cost_ref: "b", generation: gen(), overage: 3, late: true}}
      assert run(s2, settle("b", 7), @now + 6) == {s2, r2}
      assert scalars(s2) == {10, 10, 0}
    end

    test "repeat release returns the identical state, including after expiry" do
      {s, _} = run(fresh(), reserve("a", 4, @now + 10))
      {s, _} = run(s, reserve("b", 3, @now + 5))
      {s1, r1} = run(s, release("a"), @now + 6)
      assert r1 == {:released, %{cost_ref: "a", generation: gen()}}
      assert run(s1, release("a"), @now + 6) == {s1, r1}
      assert {s2, {:released, _}} = run(s1, release("b"), @now + 6)

      assert run(s2, release("b"), @now + 6) ==
               {s2, {:released, %{cost_ref: "b", generation: gen()}}}

      assert scalars(s2) == {10, 0, 0}
      {s3, _} = run(s2, settle("a", 2), @now + 6)
      assert {^s3, {:rejected, :already_settled}} = run(s3, release("a"), @now + 6)
      assert {^s3, {:rejected, :unknown_cost_ref}} = run(s3, release("zz"), @now + 6)
      assert {^s3, {:rejected, :unknown_cost_ref}} = run(s3, settle("zz", 1), @now + 6)
    end

    test "stale generation and reset" do
      {s, _} = run(fresh(), reserve("a", 4))
      {s, _} = run(s, reserve("b", 2))
      assert {^s, {:rejected, :stale_generation}} = run(s, settle("a", 1, {"inc-a", 2}))
      assert {^s, {:rejected, :stale_generation}} = run(s, settle("a", 1, {"inc-b", 1}))
      assert {^s, {:rejected, :stale_generation}} = run(s, reset({"inc-a", 2}))
      {s2, r} = run(s, reset())
      assert r == {:reset, %{generation: gen(2), forfeited: 2}}
      assert scalars(s2) == {10, 0, 0}
      assert {^s2, {:rejected, :stale_generation}} = run(s2, settle("a", 1, gen(1)))
      assert {^s2, {:rejected, :stale_generation}} = run(s2, reset(gen(1)))
      {_, {:status, st}} = run(s2, :status)

      assert st.generation == gen(2) and st.cap == 10 and st.unit == "tokens" and
               st.budget_id == "run-42/tokens"
    end
  end

  describe "step/2 is the Cure call path" do
    test "step results equal direct Cure results for the same swept state" do
      s0 = fresh()
      {s1, _} = run(s0, reserve("a", 4, @now + 10))
      t = fn x -> {:String, String.to_charlist(x)} end
      g = {:Generation, t.("inc-a"), 1}

      for {input, cure_call} <- [
            {reserve("b", 3, @now + 50),
             fn sw ->
               apply(@cure, :reserve, [sw, @now + 20, 10, t.("tokens"), t.("b"), 3, @now + 50])
             end},
            {settle("a", 2), fn sw -> apply(@cure, :settle, [sw, t.("a"), g, 2]) end},
            {release("a"), fn sw -> apply(@cure, :release, [sw, t.("a"), g]) end},
            {reset(), fn sw -> apply(@cure, :reset, [sw, g]) end},
            {:status, fn sw -> apply(@cure, :status, [sw]) end}
          ] do
        swept = apply(@cure, :sweep, [s1, @now + 20])
        {:Step, cure_next, _} = cure_call.(swept)
        {next, _} = run(s1, input, @now + 20)
        assert next == cure_next, inspect(input)
      end

      {:Step, swept_next, {:Swept, 1}} = apply(@cure, :sweep_step, [s1, @now + 20])
      assert run(s1, :sweep, @now + 20) == {swept_next, {:swept, %{expired: 1}}}
    end
  end

  describe "generated sequences" do
    test "I0, the cap law and repeat equality hold over seeded random traces" do
      :rand.seed(:exsss, {22, 36, 2026})
      refs = ~w(a b c d e)

      for _trace <- 1..60 do
        Enum.reduce(1..80, {fresh(Enum.random(5..30)), @now}, fn _, {s, now} ->
          now = now + :rand.uniform(4) - 1
          {cap, _, _} = scalars(s)
          {:Status, _, _} = elem(apply(@cure, :status, [s]), 2)
          {inc, counter} = {"inc-a", elem(elem(s, 4), 2)}
          ref = Enum.random(refs)

          input =
            case :rand.uniform(6) do
              1 -> reserve(ref, :rand.uniform(8), now + :rand.uniform(12), cap)
              2 -> settle(ref, :rand.uniform(10), {inc, counter})
              3 -> release(ref, {inc, counter})
              4 -> if(:rand.uniform(10) == 1, do: reset({inc, counter}), else: :status)
              5 -> :sweep
              6 -> reserve(ref, :rand.uniform(4), now + :rand.uniform(12), cap)
            end

          {next, result} = run(s, input, now)
          assert B.readable?(next)
          # R2 (test-grounded): sweeping again at the same now changes nothing.
          assert apply(@cure, :sweep, [next, now]) == next

          case result do
            {:reserved, _} ->
              {_, c, r} = scalars(next)
              assert c + r <= cap

            {:rejected, _} ->
              assert next == apply(@cure, :sweep, [s, now])

            _ ->
              :ok
          end

          case input do
            {kind, _} when kind in [:settle, :release] ->
              assert run(next, input, now) == {next, result}

            _ ->
              :ok
          end

          {next, now}
        end)
      end
    end
  end

  describe "critical-path admission" do
    test "uniform formula and least sufficient deadline" do
      assert B.critical_path(10, 3, 5, 20) == {:admit, 20}
      assert B.critical_path(10, 3, 5, 19) == {:reject, :deadline_insufficient, 20}
      assert B.critical_path(9, 3, 5, 15) == {:admit, 15}
      assert B.critical_path(1, 8, 7, 7) == {:admit, 7}

      for n <- 1..12, k <- 1..5, b <- 1..3 do
        required = div(n + k - 1, k) * b
        assert B.critical_path(n, k, b, required) == {:admit, required}
        assert B.critical_path(n, k, b, required - 1) == {:reject, :deadline_insufficient, required}
      end
    end

    test "waves use the per-wave maximum with barriers" do
      assert B.critical_path_waves([[1, 2], [3]], 2, 5) == {:admit, 5}
      assert B.critical_path_waves([[1, 2], [3]], 1, 6) == {:reject, :deadline_insufficient, 7}
      assert B.critical_path_waves([[4, 4, 4]], 2, 8) == {:admit, 8}
    end

    test "invalid inputs" do
      for {n, k, b, d} <- [
            {0, 1, 1, 1},
            {1, 0, 1, 1},
            {1, 1, 0, 1},
            {1, 1, 1, -1},
            {1.0, 1, 1, 1},
            {1, 1, 1, nil}
          ] do
        assert B.critical_path(n, k, b, d) == {:error, :invalid_input}
      end

      for {w, k, d} <- [
            {[], 1, 1},
            {[[]], 1, 1},
            {[[0]], 1, 1},
            {[[1]], 0, 1},
            {[[1]], 1, -1},
            {:x, 1, 1},
            {[1], 1, 1}
          ] do
        assert B.critical_path_waves(w, k, d) == {:error, :invalid_input}
      end
    end
  end
end
