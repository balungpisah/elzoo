# SPDX-License-Identifier: Apache-2.0
defmodule Elzoo.CircuitLifecycleTest do
  use ExUnit.Case, async: false
  alias Elzoo.CircuitBreaker, as: C
  @event [:elzoo, :circuit_breaker, :transition]

  defp start(opts \\ []) do
    owner =
      start_supervised!(
        {C,
         Keyword.merge(
           [name: :circuit_lifecycle_test, cooldown_ms: 20, observation_timeout_ms: 10_000],
           opts
         )}
      )

    owner
  end

  defp status(owner) do
    {:ok, s} = C.status(owner)
    s
  end

  defp eventually(fun, tries \\ 200)
  defp eventually(_, 0), do: flunk("condition did not become true")

  defp eventually(fun, tries) do
    if fun.(),
      do: :ok,
      else:
        (
          Process.sleep(5)
          eventually(fun, tries - 1)
        )
  end

  def handle(event, measurements, metadata, pid), do: send(pid, {event, measurements, metadata})
  def fail(_, _, _, _), do: throw(:private_handler_secret)

  def slow(_, _, _, pid) do
    send(pid, {:handler_waiting, self()})

    receive do
      :release_observer -> :ok
    after
      2_000 -> :ok
    end
  end

  test "C13 transition schema is exactly allowlisted; invalid secret inputs and DOWN reason are discarded" do
    handler = {__MODULE__, make_ref()}
    :ok = :telemetry.attach(handler, @event, &__MODULE__.handle/4, self())
    on_exit(fn -> :telemetry.detach(handler) end)
    owner = start(role: :notification)

    assert_receive {@event, %{epoch: 0, tracked: 0, cooldown_remaining_ms: 0},
                    %{role: :notification, from: :half_open, to: :half_open, cause: :startup}}

    {:ok, p} = C.admit(owner)
    :erlang.trace(owner, true, [:receive])
    assert C.finish(owner, p, %{secret: "payload-secret"}) == {:error, :invalid_observation}
    assert C.finish(owner, %{payload: "payload-secret"}, :healthy) == {:error, :invalid_permit}

    refute_receive {:trace, ^owner, :receive, {:"$gen_call", _, {:finish, _, _}}}, 20

    :erlang.trace(owner, false, [:receive])
    refute_receive {@event, _, _}, 10
    assert C.finish(owner, p, :healthy) == {:ok, :applied}
    assert_receive {@event, m, meta}
    assert Enum.sort(Map.keys(m)) == [:cooldown_remaining_ms, :epoch, :tracked]
    assert Enum.sort(Map.keys(meta)) == [:cause, :from, :role, :to]
    assert meta == %{role: :notification, from: :half_open, to: :closed, cause: :probe_healthy}
    {:ok, p} = C.admit(owner)
    assert C.abandon(owner, p) == {:ok, :applied}
    assert_receive {@event, m, meta}
    assert meta == %{role: :notification, from: :closed, to: :open, cause: :unknown}
    assert m.tracked == 0 and m.epoch == 1 and m.cooldown_remaining_ms >= 0
    refute inspect(status(owner)) =~ "payload-secret"
  end

  test "C14 throwing observer is detached upstream and does not undo health; no observer is required" do
    owner = start()
    handler = {__MODULE__, make_ref()}
    :ok = :telemetry.attach(handler, @event, &__MODULE__.fail/4, nil)
    on_exit(fn -> :telemetry.detach(handler) end)
    {:ok, p} = C.admit(owner)
    assert C.finish(owner, p, :healthy) == {:ok, :applied}
    assert status(owner).mode == :closed
    assert :telemetry.list_handlers(@event) |> Enum.all?(&(&1.id != handler))
    {:ok, p} = C.admit(owner)
    assert C.finish(owner, p, :unknown) == {:ok, :applied}
    assert status(owner).mode == :open
  end

  test "C15 a slow synchronous handler delays owner; state has already applied" do
    owner = start()
    handler = {__MODULE__, make_ref()}
    :ok = :telemetry.attach(handler, @event, &__MODULE__.slow/4, self())
    on_exit(fn -> :telemetry.detach(handler) end)
    parent = self()

    holder =
      spawn_link(fn ->
        {:ok, p} = C.admit(owner)
        send(parent, {:holder_finishing, self()})
        send(parent, {:finished, C.finish(owner, p, :healthy)})
      end)

    assert_receive {:holder_finishing, ^holder}
    assert_receive {:handler_waiting, ^owner}
    refute_receive {:finished, _}, 30
    send(owner, :release_observer)
    assert_receive {:finished, {:ok, :applied}}
    assert status(owner).mode == :closed
    :telemetry.detach(handler)
  end

  @tag timeout: 15_000
  test "C16 all operational call timeouts are unknown; late admission expires conservatively" do
    owner = start(observation_timeout_ms: 50)
    :ok = :sys.suspend(owner)
    parent = self()
    operations = [:admit, :status, :finish, :abandon]
    forged_shape = {C, make_ref(), 0, make_ref()}

    tasks =
      for operation <- operations do
        Task.async(fn ->
          reply =
            case operation do
              :admit -> C.admit(owner)
              :status -> C.status(owner)
              :finish -> C.finish(owner, forged_shape, :healthy)
              :abandon -> C.abandon(owner, forged_shape)
            end

          send(parent, {:timeout_result, self(), reply})

          receive do
            :stop -> reply
          end
        end)
      end

    for %{pid: pid} <- tasks,
        do: assert_receive({:timeout_result, ^pid, {:unknown, :owner_call_timeout}}, 6_000)

    :ok = :sys.resume(owner)
    eventually(fn -> status(owner).mode == :open end)
    # The caller is still alive: an unobserved expired token retains its fence.
    assert status(owner).tracked == 1 and status(owner).recovery_probe_held
    for %{pid: pid} <- tasks, do: send(pid, :stop)
    for task <- tasks, do: assert(Task.await(task) == {:unknown, :owner_call_timeout})
    eventually(fn -> status(owner).tracked == 0 end)
  end

  test "C17 stop and replacement while delegated work survives demonstrate no cross-owner work bound" do
    old = start()
    {:ok, p} = C.admit(old)
    parent = self()

    work =
      spawn(fn ->
        send(parent, {:external_work, self()})

        receive do
          :stop -> :ok
        end
      end)

    assert_receive {:external_work, ^work}
    :ok = stop_supervised({C, :circuit_lifecycle_test})
    fresh = start()
    assert C.finish(fresh, p, :healthy) == {:error, :invalid_permit}
    assert Process.alive?(work)
    {:ok, new_probe} = C.admit(fresh)
    assert Process.alive?(work)
    assert C.finish(fresh, new_probe, :healthy) == {:ok, :applied}
    send(work, :stop)
  end

  test "C18 ordinary expiry cleans monitors/timers; retained probe DOWN and old timer cannot free a new fence" do
    {:ok, clock} = Agent.start_link(fn -> 0 end)

    owner =
      start(clock: fn -> Agent.get(clock, & &1) end, observation_timeout_ms: 50, cooldown_ms: 1)

    {:ok, p} = C.admit(owner)
    assert C.finish(owner, p, :healthy) == {:ok, :applied}
    {:ok, old} = C.admit(owner)
    before = :sys.get_state(owner)
    Agent.update(clock, fn _ -> 50 end)
    assert status(owner).mode == :open
    assert status(owner).tracked == 0
    for {_, e} <- before.permits, do: assert(Process.read_timer(e.timer) == false)
    assert C.finish(owner, old, :healthy) == {:error, :stale_permit}
    Agent.update(clock, fn _ -> 51 end)
    eventually(fn -> :fuse.ask({:elzoo_circuit_breaker, :circuit_lifecycle_test}, :sync) == :ok end)
    parent = self()

    holder =
      spawn(fn ->
        send(parent, {:held_probe, C.admit(owner)})

        receive do
          :die -> :ok
        end
      end)

    assert_receive {:held_probe, {:ok, probe}}
    {C, inc, _, ref} = probe
    Agent.update(clock, fn _ -> 101 end)
    assert status(owner).tracked == 1
    assert status(owner).recovery_probe_held
    Agent.update(clock, fn _ -> 102 end)
    eventually(fn -> :fuse.ask({:elzoo_circuit_breaker, :circuit_lifecycle_test}, :sync) == :ok end)
    assert C.admit(owner) == {:refused, :probe_busy}
    send(holder, :die)
    eventually(fn -> status(owner).tracked == 0 end)
    {:ok, new} = C.admit(owner)
    snapshot = status(owner)
    send(owner, {:circuit_expiry, inc, ref})
    send(owner, {:DOWN, make_ref(), :process, holder, "secret-old-reason"})
    assert status(owner) == snapshot
    assert C.finish(owner, new, :healthy) == {:ok, :applied}
    assert {:monitors, monitors} = Process.info(owner, :monitors)
    assert length(monitors) == 1
  end
end
