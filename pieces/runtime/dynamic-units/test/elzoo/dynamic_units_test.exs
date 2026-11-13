# SPDX-License-Identifier: Apache-2.0
defmodule Elzoo.DynamicUnitsTest do
  use ExUnit.Case, async: false
  alias Elzoo.{DurableUnit, DynamicUnits, Outbox}
  alias Elzoo.DurableLog, as: Log
  alias Elzoo.DurableLog.Memory

  defmodule Operator do
    def step(state, input) do
      observer = Agent.get(Probe, & &1.observer)
      send(observer, {:evaluated, self(), state, input})

      case input do
        {:block, add} ->
          receive do: (:continue -> {:Transition, state * 3 + add, {:some, add}})

        :fail ->
          {:Transition, state, :invalid}

        :error_state ->
          {:Transition, {:error, :business_state}, :none}

        add ->
          {:Transition, state * 3 + add, {:some, add}}
      end
    end
  end

  setup do
    Process.flag(:trap_exit, true)
    observer = self()
    # The fixtures deliberately perform I/O; the published Unit has no test hooks.
    start_supervised!(%{
      id: Probe,
      start:
        {Agent, :start_link,
         [fn -> %{observer: observer, block_offer: false, callback: :ok} end, [name: Probe]]}
    })

    opts = [
      operator: {Operator, :step, 2},
      retention_count: 2,
      max_record_bytes: 512,
      max_checkpoint_bytes: 100_000,
      offer: fn item ->
        %{observer: observer, block_offer: block} = Agent.get(Probe, & &1)
        send(observer, {:offered, self(), item})
        if block, do: receive(do: (:continue -> :ok))
        :ok
      end
    ]

    memory =
      start_supervised!({Memory, fold: DurableUnit.fold(opts), limits: DurableUnit.limits(opts)})

    store = Memory.store(memory)
    %{opts: Keyword.put(opts, :store, store), store: store}
  end

  defp pool(ctx, registry \\ RegistryA, extra \\ []) do
    start_supervised!({Registry, keys: :unique, name: registry}, id: registry)

    sup =
      start_supervised!({DynamicSupervisor, strategy: :one_for_one, max_children: 2},
        id: {registry, :children}
      )

    callback = fn identity ->
      case Agent.get(Probe, & &1.callback) do
        :raise ->
          raise "provider detail"

        :invalid ->
          Keyword.put(ctx.opts, :name, :forbidden)

        :bad_unit ->
          Keyword.put(ctx.opts, :retention_count, 0)

        :block ->
          send(ctx.observer, {:starting, identity, self()})
          receive do: (:continue -> ctx.opts)

        :ok ->
          ctx.opts
      end
    end

    options = [registry: registry, supervisor: sup, unit_options: callback, idle_ms: 60_000]
    # Keyword.merge makes the one idle override explicit, not a production default.
    options = Keyword.merge(options, extra)
    directory = start_supervised!({DynamicUnits, options}, id: {registry, :directory})
    %{directory: directory, supervisor: sup, registry: registry, options: options}
  end

  defp probe(changes), do: Agent.update(Probe, &Map.merge(&1, changes))

  defp async_call(tag, fun) do
    observer = self()
    spawn(fn -> send(observer, {tag, fun.()}) end)
  end

  defp eventually(fun, remaining \\ 200) do
    case fun.() do
      false when remaining > 0 ->
        Process.sleep(5)
        eventually(fun, remaining - 1)

      result ->
        assert result
    end
  end

  defp absent(pool, id),
    do: eventually(fn -> DynamicUnits.find(pool.directory, id) == :not_found end)

  defp rows(store, id) do
    {:ok, rows, _} = Log.read(store, id, 1, 100)
    rows
  end

  test "DY1 concurrent starts, independent identities, validation and no state reset", ctx do
    p = pool(Map.put(ctx, :observer, self()))
    d = p.directory
    async_call(:first, fn -> DynamicUnits.start(d, "A") end)
    async_call(:second, fn -> DynamicUnits.start(d, "A") end)
    assert_receive {:first, {:ok, pid}}
    assert_receive {:second, {:ok, ^pid}}
    assert Registry.lookup(p.registry, "A") == [{pid, nil}]
    assert DynamicSupervisor.count_children(p.supervisor).active == 1
    assert {:ok, :applied} = DurableUnit.step(pid, "one", 5)
    assert {:ok, ^pid} = DynamicUnits.start(d, "A")
    assert DurableUnit.snapshot(pid) == 11
    assert {:ok, other} = DynamicUnits.start(d, "longer")
    assert DurableUnit.snapshot(other) == 2

    for id <- ["", <<0>>, <<255>>, String.duplicate("x", 161), :atom] do
      assert {:error, :invalid_identity} = DynamicUnits.start(d, id)
      assert {:error, :invalid_identity} = DynamicUnits.find(d, id)
      assert {:error, :invalid_identity} = DynamicUnits.stop(d, id)
      assert {:error, :invalid_identity} = DynamicUnits.route(d, id, {:durable_unit_input, "id", 4})
    end

    for message <- [
          :input,
          {:durable_unit_input, "", 4},
          {:durable_unit_input, <<0>>, 4},
          {:durable_unit_input, "id", 4, :extra}
        ] do
      assert {:error, :invalid_message} = DynamicUnits.route(d, "A", message)
    end

    assert length(rows(ctx.store, "A")) == 2
    assert DynamicUnits.find(d, "missing") == :not_found

    for bad <- [
          [],
          [registry: p.registry],
          Keyword.put(p.options, :idle_ms, 0),
          Keyword.put(p.options, :idle_ms, 4_294_967_296),
          Keyword.put(p.options, :unit_options, :bad)
        ] do
      assert {:error, :invalid_options} = DynamicUnits.start_link(bad)
    end

    assert {:error, :unavailable} = DynamicUnits.start_link(p.options)

    assert {:error, :unavailable} =
             DynamicUnits.start_link(Keyword.put(p.options, :registry, MissingRegistry))

    assert {:error, :capacity} = DynamicUnits.start(d, String.duplicate("i", 160))
    assert :ok = DynamicUnits.stop(d, "longer")
    assert {:ok, edge} = DynamicUnits.start(d, String.duplicate("i", 160))
    assert Process.alive?(edge)
  end

  test "DY2 route barrier, stop/expiry arbitration, opaque state and stale messages", ctx do
    p = pool(Map.put(ctx, :observer, self()))
    d = p.directory
    # Kill before processing, after the exact tuple was sent. Bypassing the
    # real production snapshot barrier makes this report false routed success.
    {:ok, selected} = DynamicUnits.start(d, "before")
    assert :erlang.suspend_process(selected)
    :erlang.trace(d, true, [:send, {:tracer, self()}])
    message = {:durable_unit_input, "never", 7}
    async_call(:killed_route, fn -> DynamicUnits.route(d, "before", message) end)
    assert_receive {:trace, ^d, :send, ^message, ^selected}
    Process.exit(selected, :kill)
    assert_receive {:killed_route, {:indeterminate, :delivery}}
    :erlang.trace(d, false, [:send])
    eventually(fn -> match?({:ok, pid} when pid != selected, DynamicUnits.find(d, "before")) end)
    assert rows(ctx.store, "before") == []
    refute_receive {:evaluated, _, _, 7}
    assert :ok = DynamicUnits.stop(d, "before")

    {:ok, unit} = DynamicUnits.start(d, "race")
    old = :sys.get_state(d).entries["race"]

    async_call(:route, fn ->
      DynamicUnits.route(d, "race", {:durable_unit_input, "one", {:block, 5}})
    end)

    assert_receive {:evaluated, ^unit, 2, {:block, 5}}
    async_call(:stop, fn -> DynamicUnits.stop(d, "race") end)
    send(d, {:idle, "race", old.generation, old.token})
    refute_receive {:route, _}, 30
    refute_receive {:stop, _}, 30
    send(unit, :continue)
    assert_receive {:route, {:ok, :routed}}
    assert_receive {:stop, :ok}
    refute Process.alive?(unit)
    assert {:ok, :routed} = DynamicUnits.route(d, "race", {:durable_unit_input, "two", -1})
    {:ok, replacement} = DynamicUnits.find(d, "race")
    assert replacement != unit
    assert DurableUnit.snapshot(replacement) == 32
    send(d, {:idle, "race", old.generation, old.token})
    send(d, {:DOWN, old.ref, :process, unit, :killed})
    send(d, {:unit_started, "race", old.generation, unit})
    assert {:ok, ^replacement} = DynamicUnits.find(d, "race")

    assert {:ok, :routed} =
             DynamicUnits.route(d, "race", {:durable_unit_input, "same", :error_state})

    assert DurableUnit.snapshot(replacement) == {:error, :business_state}
    # Too large is rejected by the Unit, not by the routing boundary.
    assert {:ok, :routed} =
             DynamicUnits.route(d, "race", {:durable_unit_input, "big", String.duplicate("x", 600)})

    assert DurableUnit.snapshot(replacement) == {:error, :business_state}

    assert length(rows(ctx.store, "race")) == 6

    # Kill after evaluation but before snapshot can reply: no retry/false success.
    {:ok, live} = DynamicUnits.start(d, "after")

    async_call(:after_route, fn ->
      DynamicUnits.route(d, "after", {:durable_unit_input, "pending", {:block, 4}})
    end)

    assert_receive {:evaluated, ^live, 2, {:block, 4}}
    Process.exit(live, :kill)
    assert_receive {:after_route, {:indeterminate, :delivery}}
    assert_receive {:evaluated, recovered, 2, {:block, 4}}
    assert recovered != live
    send(recovered, :continue)
    eventually(fn -> match?({:ok, ^recovered}, DynamicUnits.find(d, "after")) end)
    assert length(rows(ctx.store, "after")) == 2
    refute_receive {:evaluated, _, _, {:block, 4}}
    assert :ok = DynamicUnits.stop(d, "race")
    assert :ok = DynamicUnits.stop(d, "after")

    # Death during wake recovery is a pre-send refusal, unlike death after send.
    {:ok, previous} = DynamicUnits.start(d, "startup")
    assert {:ok, :applied} = DurableUnit.step(previous, "recorded", 5)
    assert :ok = DynamicUnits.stop(d, "startup")
    probe(%{block_offer: true})

    async_call(:startup_route, fn ->
      DynamicUnits.route(d, "startup", {:durable_unit_input, "not-sent", 9})
    end)

    assert_receive {:offered, selected, %Outbox.Item{stream: "startup"}} when selected != previous
    Process.exit(selected, :kill)
    assert_receive {:startup_route, {:error, :start_failed}}
    probe(%{block_offer: false})
    assert length(rows(ctx.store, "startup")) == 2
    refute_receive {:evaluated, _, _, 9}
  end

  test "DY3 supervisor capacity includes starting, stopping and restarting children", ctx do
    ctx = Map.put(ctx, :observer, self())
    p = pool(ctx)
    d = p.directory

    for mode <- [:raise, :invalid, :bad_unit] do
      probe(%{callback: mode})
      assert {:error, :start_failed} = DynamicUnits.start(d, "failed")
      assert DynamicUnits.find(d, "failed") == :not_found
      assert DynamicSupervisor.count_children(p.supervisor).specs == 0
    end

    probe(%{callback: :block})
    async_call(:starting, fn -> DynamicUnits.start(d, "one") end)
    assert_receive {:starting, "one", controller}
    async_call(:waiting, fn -> DynamicUnits.start(d, "one") end)
    refute_receive {:waiting, _}, 30
    probe(%{callback: :ok})
    send(controller, :continue)
    assert_receive {:starting, {:ok, first}}
    assert_receive {:waiting, {:ok, ^first}}
    {:ok, second} = DynamicUnits.start(d, "two")
    assert {:error, :capacity} = DynamicUnits.start(d, "three")
    assert {:error, :capacity} = DynamicUnits.route(d, "three", {:durable_unit_input, "id", 1})
    assert rows(ctx.store, "three") == []
    assert {:ok, ^first} = DynamicUnits.start(d, "one")
    assert :erlang.suspend_process(second)
    async_call(:stopping, fn -> DynamicUnits.stop(d, "two") end)
    eventually(fn -> match?({:status, :waiting}, Process.info(p.supervisor, :status)) end)
    async_call(:third, fn -> DynamicUnits.start(d, "three") end)
    refute_receive {:stopping, _}, 30
    refute_receive {:third, _}, 30
    assert Process.alive?(second)
    :erlang.resume_process(second)
    assert_receive {:stopping, :ok}
    assert_receive {:third, {:ok, third}}
    refute Process.alive?(second)
    assert DynamicSupervisor.count_children(p.supervisor).active == 2
    assert Process.alive?(third)

    assert {:ok, :applied} = DurableUnit.step(first, "state", 5)
    probe(%{block_offer: true})
    Process.exit(first, :kill)
    assert_receive {:offered, restarted, %Outbox.Item{}}
    # Skip the earlier offer made by the original live child.
    restarted =
      if restarted == first do
        receive do: ({:offered, pid, %Outbox.Item{}} -> pid)
      else
        restarted
      end

    async_call(:restart_start, fn -> DynamicUnits.start(d, "one") end)
    async_call(:restart_capacity, fn -> DynamicUnits.start(d, "four") end)
    refute_receive {:restart_start, _}, 30
    assert Registry.count(p.registry) == 2
    probe(%{block_offer: false})
    send(restarted, :continue)
    assert_receive {:restart_start, start_reply}
    assert start_reply in [{:ok, restarted}, {:error, :busy}]
    assert_receive {:restart_capacity, {:error, :capacity}}
    eventually(fn -> DynamicUnits.find(d, "one") == {:ok, restarted} end)
    assert DurableUnit.snapshot(restarted) == 11
    assert DynamicSupervisor.count_children(p.supervisor).active == 2
  end

  test "DY4 OTP abnormal replacement, durable recovery, named shutdown and intensity", ctx do
    p = pool(Map.put(ctx, :observer, self()))
    d = p.directory
    {:ok, unit} = DynamicUnits.start(d, "recover")
    {:ok, :applied} = DurableUnit.step(unit, "first", 5)
    Process.exit(unit, :kill)
    eventually(fn -> match?({:ok, pid} when pid != unit, DynamicUnits.find(d, "recover")) end)
    {:ok, replacement} = DynamicUnits.find(d, "recover")
    assert DurableUnit.snapshot(replacement) == 11
    assert Registry.lookup(p.registry, "recover") == [{replacement, nil}]
    ref = Process.monitor(replacement)

    assert {:indeterminate, :delivery} =
             DynamicUnits.route(d, "recover", {:durable_unit_input, "fail", :fail})

    # A barrier cannot return normally after the Unit's named shutdown.
    assert_receive {:DOWN, ^ref, :process, ^replacement,
                    {:shutdown, :durable_unit_transition_failed}}

    absent(p, "recover")
    assert DynamicSupervisor.count_children(p.supervisor).specs == 0
    assert_receive {:evaluated, ^replacement, 11, :fail}
    refute_receive {:evaluated, _, _, :fail}

    # One restart was already used above. The fourth abnormal exit exceeds
    # the dedicated supervisor's ordinary OTP intensity (3 in 5 seconds).
    {:ok, first} = DynamicUnits.start(d, "intensity")

    last =
      Enum.reduce(1..2, first, fn _, pid ->
        Process.exit(pid, :kill)

        eventually(fn ->
          match?({:ok, next} when next != pid, DynamicUnits.find(d, "intensity"))
        end)

        {:ok, next} = DynamicUnits.find(d, "intensity")
        next
      end)

    sup_ref = Process.monitor(p.supervisor)
    Process.exit(last, :kill)
    assert_receive {:DOWN, ^sup_ref, :process, _, :shutdown}
    eventually(fn -> DynamicUnits.find(d, "intensity") == {:error, :unavailable} end)

    # Hold a real which_children reply containing an unadopted P2, then kill
    # P2 before the directory can check Registry. OTP still retains its spec.
    p = pool(Map.put(ctx, :observer, self()), RegistryB)
    d = p.directory
    sup = p.supervisor
    observer = self()

    for {id, reason} <- [{"unadopted", :killed}, {"terminal", :normal}] do
      {:ok, first} = DynamicUnits.start(d, id)
      assert {:ok, :applied} = DurableUnit.step(first, "committed", 5)

      :ok =
        :sys.install(
          sup,
          {fn
             :armed, {:out, children, {^d, _}, _}, _ when is_list(children) ->
               if Enum.any?(children, &(is_pid(elem(&1, 1)) and elem(&1, 1) != first)) do
                 send(observer, {:snapshot_held, children})
                 receive do: (:continue -> :released)
               else
                 :armed
               end

             state, _, _ ->
               state
           end, :armed}
        )

      :ok =
        :sys.install(
          d,
          {fn
             :armed, {:noreply, _}, _ ->
               send(observer, :snapshot_processed)
               :released

             state, _, _ ->
               state
           end, :armed}
        )

      assert :erlang.suspend_process(d)
      probe(%{block_offer: true})
      Process.exit(first, :kill)
      assert_receive {:offered, second, %Outbox.Item{stream: ^id}} when second != first
      assert :erlang.suspend_process(sup)
      :erlang.trace(d, true, [:send, {:tracer, self()}])

      try do
        assert :erlang.resume_process(d)
        assert_receive {:trace, ^d, :send, {:"$gen_call", _, :which_children}, ^sup}
        assert :erlang.suspend_process(d)
        :erlang.trace(d, false, [:send])
        send(second, :continue)
        assert :erlang.resume_process(sup)
        assert_receive {:snapshot_held, [{:undefined, ^second, :worker, _}]}
        second_ref = Process.monitor(second)
        if reason == :normal, do: :sys.terminate(second, :normal), else: Process.exit(second, :kill)
        assert_receive {:DOWN, ^second_ref, :process, ^second, ^reason}
        eventually(fn -> Registry.lookup(p.registry, id) == [] end)
        assert :erlang.resume_process(d)
        assert_receive :snapshot_processed

        if reason == :killed do
          async_call(:unadopted_find, fn -> DynamicUnits.find(d, id) end)
          refute_receive {:unadopted_find, :not_found}, 30
        end
      after
        :erlang.trace(d, false, [:send])

        for pid <- [d, sup] do
          if Process.info(pid, :status) == {:status, :suspended},
            do: :erlang.resume_process(pid)
        end

        probe(%{block_offer: false})
        send(sup, :continue)
      end

      if reason == :killed do
        assert_receive {:offered, third, %Outbox.Item{stream: ^id}}
                       when third != first and third != second

        assert_receive {:unadopted_find, reply}
        assert reply in [{:ok, third}, {:error, :busy}]
        eventually(fn -> DynamicUnits.find(d, id) == {:ok, third} end)
        assert DurableUnit.snapshot(third) == 11
        assert {:ok, :routed} = DynamicUnits.route(d, id, {:durable_unit_input, "next", -1})
        assert DurableUnit.snapshot(third) == 32
        assert :ok = DynamicUnits.stop(d, id)
        refute Process.alive?(third)
      else
        assert [] = DynamicSupervisor.which_children(sup)
        :sys.get_status(d)

        for fresh <- ["fresh-one", "fresh-two"] do
          assert {:ok, pid} = DynamicUnits.start(d, fresh)
          assert {:ok, ^pid} = DynamicUnits.find(d, fresh)
        end

        assert {:error, :capacity} = DynamicUnits.start(d, "overflow")
        assert DynamicSupervisor.count_children(sup).specs == 2
        assert Enum.sort(Map.keys(:sys.get_state(d).entries)) == ["fresh-one", "fresh-two"]
        assert :not_found = DynamicUnits.find(d, id)
        for fresh <- ["fresh-one", "fresh-two"], do: assert(:ok = DynamicUnits.stop(d, fresh))
      end

      assert DynamicSupervisor.count_children(sup).specs == 0
      assert :sys.get_state(d).entries == %{}
      :sys.no_debug(d)
      :sys.no_debug(sup)
    end

    # A terminal child and another identity's unadopted replacement share a snapshot.
    p = pool(Map.put(ctx, :observer, self()), RegistryC)
    d = p.directory
    {:ok, a} = DynamicUnits.start(d, "A")
    {:ok, b} = DynamicUnits.start(d, "B")
    assert :erlang.suspend_process(d)

    try do
      a_ref = Process.monitor(a)
      :sys.terminate(a, :normal)
      assert_receive {:DOWN, ^a_ref, :process, ^a, :normal}
      Process.exit(b, :kill)

      eventually(fn ->
        case Registry.lookup(p.registry, "B") do
          [{pid, nil}] when pid != b -> true
          _ -> false
        end
      end)

      eventually(fn ->
        Process.info(d, :messages) |> elem(1) |> Enum.any?(&match?({:unit_started, "B", _, _}, &1))
      end)

      assert :erlang.resume_process(d)
      assert {:ok, _} = DynamicUnits.start(d, "C")
      assert Enum.sort(Map.keys(:sys.get_state(d).entries)) == ["B", "C"]
    after
      if Process.info(d, :status) == {:status, :suspended}, do: :erlang.resume_process(d)
    end
  end

  test "DY5 explicit sleep, idle expiry, refresh versus find and durable wake", ctx do
    p = pool(Map.put(ctx, :observer, self()), RegistryA, idle_ms: 300)
    d = p.directory
    assert {:ok, :routed} = DynamicUnits.route(d, "sleep", {:durable_unit_input, "one", 5})
    {:ok, first} = DynamicUnits.find(d, "sleep")
    stale = :sys.get_state(d).entries["sleep"]
    assert :ok = DynamicUnits.stop(d, "sleep")
    assert :ok = DynamicUnits.stop(d, "sleep")
    assert length(rows(ctx.store, "sleep")) == 2
    assert {:ok, :routed} = DynamicUnits.route(d, "sleep", {:durable_unit_input, "two", -1})
    {:ok, next} = DynamicUnits.find(d, "sleep")
    assert next != first
    assert DurableUnit.snapshot(next) == 32
    send(d, {:idle, "sleep", stale.generation, stale.token})
    assert {:ok, ^next} = DynamicUnits.find(d, "sleep")
    old = :sys.get_state(d).entries["sleep"]
    Process.sleep(180)
    assert {:ok, ^next} = DynamicUnits.start(d, "sleep")
    send(d, {:idle, "sleep", old.generation, old.token})
    Process.sleep(180)
    assert {:ok, ^next} = DynamicUnits.find(d, "sleep")
    old = :sys.get_state(d).entries["sleep"]
    assert {:ok, :routed} = DynamicUnits.route(d, "sleep", {:durable_unit_input, "two", -1})
    send(d, {:idle, "sleep", old.generation, old.token})
    Process.sleep(180)
    assert {:ok, ^next} = DynamicUnits.find(d, "sleep")
    absent(p, "sleep")
    assert DynamicSupervisor.count_children(p.supervisor).specs == 0
    assert length(rows(ctx.store, "sleep")) == 4
    assert {:ok, awakened} = DynamicUnits.start(d, "sleep")
    assert DurableUnit.snapshot(awakened) == 32
    assert :ok = DynamicUnits.stop(d, "sleep")
  end

  test "DY6 independent local domains arbitrate only through Store CAS", ctx do
    ctx = Map.put(ctx, :observer, self())
    left = pool(ctx)
    right = pool(ctx, RegistryB)
    {:ok, winner} = DynamicUnits.start(left.directory, "shared")
    {:ok, loser} = DynamicUnits.start(right.directory, "shared")
    assert {:ok, :applied} = DurableUnit.step(winner, "one", 5)
    ref = Process.monitor(loser)

    assert {:indeterminate, :delivery} =
             DynamicUnits.route(right.directory, "shared", {:durable_unit_input, "losing", 9})

    assert_receive {:DOWN, ^ref, :process, ^loser, {:shutdown, :durable_unit_conflict}}
    absent(right, "shared")
    assert DynamicSupervisor.count_children(right.supervisor).specs == 0
    assert DurableUnit.snapshot(winner) == 11
    assert length(rows(ctx.store, "shared")) == 2
    assert {:ok, [item]} = Outbox.pending(ctx.store, "shared", 64)
    assert item.sequence == 2
    refute_receive {:evaluated, ^loser, _, _}
    refute_receive {:offered, ^loser, _}
  end

  test "DY7 bounded binary lifecycle and fresh infrastructure instead of orphan adoption", ctx do
    p = pool(Map.put(ctx, :observer, self()))
    d = p.directory

    cycle = fn identity ->
      assert {:ok, pid} = DynamicUnits.start(d, identity)
      assert :ok = DynamicUnits.stop(d, identity)
      assert {:ok, next} = DynamicUnits.start(d, identity)
      assert next != pid
      assert :ok = DynamicUnits.stop(d, identity)
      assert DynamicSupervisor.count_children(p.supervisor).specs == 0
    end

    cycle.("warm")
    before = :erlang.system_info(:atom_count)
    for index <- 1..20, do: cycle.("binary-#{index}")
    assert :erlang.system_info(:atom_count) == before
    eventually(fn -> Registry.count(p.registry) == 0 end)
    assert :sys.get_state(d).entries == %{}
    assert {:monitors, monitors} = Process.info(d, :monitors)
    assert length(monitors) == 2
    assert {:ok, live} = DynamicUnits.start(d, "owned")
    assert {:error, :unavailable} = DynamicUnits.start_link(p.options)
    assert Process.alive?(live)
    Process.exit(Process.whereis(p.registry), :kill)
    eventually(fn -> DynamicUnits.find(d, "owned") == {:error, :unavailable} end)
    assert {:error, :unavailable} = DynamicUnits.start(d, "new")
    # Caller resets the entire subtree, including its still-running children.
    stop_supervised!({p.registry, :directory})
    stop_supervised!({p.registry, :children})
    {:ok, test_supervisor} = ExUnit.fetch_test_supervisor()

    eventually(fn ->
      Enum.any?(Supervisor.which_children(test_supervisor), fn
        {id, pid, _, _} -> id == p.registry and is_pid(pid)
      end)
    end)

    stop_supervised!(p.registry)
    refute Process.alive?(live)
    fresh = pool(Map.put(ctx, :observer, self()))
    assert DynamicUnits.find(fresh.directory, "owned") == :not_found
    assert {:ok, _} = DynamicUnits.start(fresh.directory, "owned")
  end
end
