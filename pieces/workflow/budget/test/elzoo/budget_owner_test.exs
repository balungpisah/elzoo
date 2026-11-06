# SPDX-License-Identifier: Apache-2.0
defmodule Elzoo.Budget.OwnerTest do
  use ExUnit.Case, async: true
  alias Elzoo.Budget.Owner

  defp start!(cap \\ 10, unit \\ "tokens") do
    {:ok, pid} = Owner.start_link(budget_id: "run-1/#{unit}", cap: cap, unit: unit)
    pid
  end

  defp generation(owner) do
    {:status, %{generation: g}} = Owner.status(owner)
    g
  end

  defp reserve_fields(ref, estimate, expiry, cap \\ 10),
    do: %{cap: cap, unit: "tokens", estimate: estimate, cost_ref: ref, expiry: expiry}

  defp later(ms), do: System.os_time(:millisecond) + ms

  test "start validates static Config and seals cap and unit" do
    assert Owner.start_link(budget_id: "b", cap: 0, unit: "u") == {:error, :invalid_amount}
    assert Owner.start_link(budget_id: "b", cap: 1, unit: "") == {:error, :invalid_unit}
    assert Owner.start_link(budget_id: "", cap: 1, unit: "u") == {:error, :invalid_input}
    assert Owner.start_link(budget_id: "b", cap: 1) == {:error, :invalid_input}

    assert Owner.start_link(budget_id: "b", cap: 1, unit: "u", incarnation: "x") ==
             {:error, :invalid_input}

    assert Owner.start_link(:nope) == {:error, :invalid_input}

    owner = start!()
    {:status, st} = Owner.status(owner)
    assert %{cap: 10, unit: "tokens", committed: 0, reserved: 0, remaining: 10, open: 0} = st
    assert {_inc, 1} = st.generation

    assert Owner.reserve(owner, reserve_fields("a", 1, later(1_000), 11)) ==
             {:rejected, :changed_limits}

    assert Owner.reserve(owner, %{reserve_fields("a", 1, later(1_000)) | unit: "calls"}) ==
             {:rejected, :changed_limits}
  end

  test "two starts get different incarnations" do
    incarnations = for _ <- 1..20, do: elem(generation(start!()), 0)
    assert length(Enum.uniq(incarnations)) == 20
    assert Enum.all?(incarnations, &(byte_size(&1) == 32))
  end

  test "concurrent callers cannot both reserve the last unit" do
    for _round <- 1..20 do
      owner = start!()
      assert {:reserved, _} = Owner.reserve(owner, reserve_fields("base", 9, later(60_000)))
      expiry = later(60_000)

      results =
        1..50
        |> Enum.map(fn i ->
          Task.async(fn -> Owner.reserve(owner, reserve_fields("c#{i}", 1, expiry)) end)
        end)
        |> Enum.map(&Task.await/1)

      assert Enum.count(results, &match?({:reserved, _}, &1)) == 1
      assert Enum.count(results, &(&1 == {:rejected, :insufficient})) == 49
      {:status, st} = Owner.status(owner)
      assert st.reserved == 10 and st.remaining == 0
    end
  end

  test "abandoned reservation expires and a late settle commits only the actual" do
    owner = start!()
    g = generation(owner)
    assert {:reserved, _} = Owner.reserve(owner, reserve_fields("a", 6, later(30)))
    Process.sleep(60)
    assert Owner.sweep(owner) == {:swept, %{expired: 1}}
    {:status, st} = Owner.status(owner)
    assert st.reserved == 0 and st.open == 0
    assert {:reserved, _} = Owner.reserve(owner, reserve_fields("b", 6, later(60_000)))

    assert Owner.settle(owner, %{cost_ref: "a", generation: g, actual: 9}) ==
             {:settled, %{cost_ref: "a", generation: g, overage: 3, late: true}}

    {:status, st} = Owner.status(owner)
    assert st.committed == 9 and st.reserved == 6 and st.remaining == 0
    assert Owner.reserve(owner, reserve_fields("c", 1, later(60_000))) == {:rejected, :insufficient}

    assert {:settled, %{late: false}} =
             Owner.settle(owner, %{cost_ref: "b", generation: g, actual: 6})

    assert Owner.reserve(owner, reserve_fields("c", 1, later(60_000))) == {:rejected, :overage}
  end

  test "overage on a normal settle keeps the observed figure and stops admission" do
    owner = start!()
    g = generation(owner)
    assert {:reserved, _} = Owner.reserve(owner, reserve_fields("a", 8, later(60_000)))

    assert Owner.settle(owner, %{cost_ref: "a", generation: g, actual: 25}) ==
             {:settled, %{cost_ref: "a", generation: g, overage: 17, late: false}}

    {:status, st} = Owner.status(owner)
    assert st.committed == 25 and st.remaining == 0
    assert Owner.reserve(owner, reserve_fields("b", 1, later(60_000))) == {:rejected, :overage}
    assert {:reset, %{forfeited: 0, generation: {_, 2}}} = Owner.reset(owner, %{generation: g})
    assert {:reserved, _} = Owner.reserve(owner, reserve_fields("b", 1, later(60_000)))
  end

  test "reset needs the current generation, forfeits open reservations and rejects their settles" do
    owner = start!()
    g = generation(owner)
    assert {:reserved, _} = Owner.reserve(owner, reserve_fields("a", 2, later(60_000)))
    assert {:reserved, _} = Owner.reserve(owner, reserve_fields("b", 3, later(60_000)))
    {inc, 1} = g
    assert Owner.reset(owner, %{generation: {inc, 2}}) == {:rejected, :stale_generation}
    assert Owner.reset(owner, %{generation: g}) == {:reset, %{generation: {inc, 2}, forfeited: 2}}

    assert Owner.settle(owner, %{cost_ref: "a", generation: g, actual: 2}) ==
             {:rejected, :stale_generation}

    assert Owner.reset(owner, %{generation: g}) == {:rejected, :stale_generation}
    assert generation(owner) == {inc, 2}
  end

  test "unreadable owner state fails closed for every input, including reset" do
    {:ok, owner} = Elzoo.Unit.start_link({Elzoo.Budget, :step, :garbage})
    assert Owner.reserve(owner, reserve_fields("a", 1, later(1_000))) == {:rejected, :unreadable}
    assert Owner.reset(owner, %{generation: {"x", 1}}) == {:rejected, :unreadable}
    assert Owner.status(owner) == {:rejected, :unreadable}
  end

  test "a stopped owner fails closed" do
    owner = start!()
    :ok = GenServer.stop(owner)

    assert Owner.reserve(owner, reserve_fields("a", 1, later(1_000))) ==
             {:rejected, :owner_unavailable}

    assert Owner.status(owner) == {:rejected, :owner_unavailable}
  end

  test "a supervised crash leaves the temporary owner gone; a new start is a new incarnation" do
    {:ok, sup} = Supervisor.start_link([], strategy: :one_for_one)

    {:ok, owner} =
      Supervisor.start_child(
        sup,
        Owner.child_spec(budget_id: "run-1/tokens", cap: 10, unit: "tokens")
      )

    assert Owner.child_spec([]).restart == :temporary
    old = generation(owner)
    assert {:reserved, _} = Owner.reserve(owner, reserve_fields("a", 4, later(60_000)))
    ref = Process.monitor(owner)
    Process.exit(owner, :kill)
    assert_receive {:DOWN, ^ref, :process, ^owner, :killed}
    assert Supervisor.which_children(sup) == []
    assert Owner.status(owner) == {:rejected, :owner_unavailable}

    {:ok, fresh} =
      Supervisor.start_child(
        sup,
        Owner.child_spec(budget_id: "run-1/tokens", cap: 10, unit: "tokens")
      )

    new = generation(fresh)
    assert elem(new, 0) != elem(old, 0)
    {:status, st} = Owner.status(fresh)
    assert st.committed == 0 and st.reserved == 0 and st.open == 0

    assert Owner.settle(fresh, %{cost_ref: "a", generation: old, actual: 4}) ==
             {:rejected, :stale_generation}

    Supervisor.stop(sup)
  end

  test "two budgets under one ordinary Supervisor have distinct child ids and both work" do
    specs = [
      Owner.child_spec(budget_id: "run-1/tokens", cap: 10, unit: "tokens"),
      Owner.child_spec(budget_id: "run-1/calls", cap: 3, unit: "calls")
    ]

    assert Enum.map(specs, & &1.id) == [
             {Owner, "run-1/tokens"},
             {Owner, "run-1/calls"}
           ]

    {:ok, sup} = Supervisor.start_link(specs, strategy: :one_for_one)
    children = Supervisor.which_children(sup)
    assert length(children) == 2

    tokens =
      Enum.find_value(children, fn {id, pid, _, _} -> id == {Owner, "run-1/tokens"} && pid end)

    calls = Enum.find_value(children, fn {id, pid, _, _} -> id == {Owner, "run-1/calls"} && pid end)
    assert is_pid(tokens) and is_pid(calls) and tokens != calls

    assert {:reserved, %{remaining: 2}} =
             Owner.reserve(tokens, reserve_fields("a", 8, later(60_000)))

    assert {:reserved, %{remaining: 1}} =
             Owner.reserve(calls, %{
               cap: 3,
               unit: "calls",
               estimate: 2,
               cost_ref: "a",
               expiry: later(60_000)
             })

    assert {:status, %{budget_id: "run-1/tokens", reserved: 8}} = Owner.status(tokens)
    assert {:status, %{budget_id: "run-1/calls", reserved: 2}} = Owner.status(calls)

    assert Owner.child_spec(budget_id: "", cap: 1, unit: "u").id == Owner
    assert Owner.child_spec(:nope).id == Owner

    # start_link/1 returns {:error, :invalid_input}; Supervisor wraps it with the child.
    assert {:error, {:invalid_input, _child}} =
             Supervisor.start_child(sup, Owner.child_spec(budget_id: "", cap: 1, unit: "u"))

    Supervisor.stop(sup)
  end

  @tag timeout: 60_000
  test "timeout then retry: replay, conflict with a recomputed expiry, rejected retry then release frees" do
    owner = start!()
    g = generation(owner)
    fields = reserve_fields("a", 4, later(60_000))
    :ok = :sys.suspend(owner)
    assert Owner.reserve(owner, fields) == {:rejected, :owner_unavailable}
    :ok = :sys.resume(owner)

    {:status, st} = Owner.status(owner)
    assert st.reserved == 4 and st.open == 1

    assert Owner.reserve(owner, fields) ==
             {:reserved, %{cost_ref: "a", generation: g, estimate: 4, remaining: 6}}

    assert Owner.reserve(owner, %{fields | expiry: fields.expiry + 1}) ==
             {:rejected, :cost_ref_conflict}

    # A rejected retry means "do not start the call"; release frees the hold (R1).
    assert {:reserved, _} = Owner.reserve(owner, reserve_fields("b", 6, later(60_000)))

    assert {:settled, %{overage: 3}} =
             Owner.settle(owner, %{cost_ref: "b", generation: g, actual: 9})

    assert Owner.reserve(owner, fields) == {:rejected, :insufficient}

    assert Owner.release(owner, %{cost_ref: "a", generation: g}) ==
             {:released, %{cost_ref: "a", generation: g}}

    {:status, st} = Owner.status(owner)
    assert st.reserved == 0 and st.open == 0 and st.committed == 9
  end

  @tag timeout: 60_000
  test "a timed-out reset has an unknown outcome resolved with status" do
    owner = start!()
    {inc, 1} = g = generation(owner)
    :ok = :sys.suspend(owner)
    assert Owner.reset(owner, %{generation: g}) == {:rejected, :owner_unavailable}
    :ok = :sys.resume(owner)
    assert Owner.reset(owner, %{generation: g}) == {:rejected, :stale_generation}
    assert generation(owner) == {inc, 2}
  end
end
