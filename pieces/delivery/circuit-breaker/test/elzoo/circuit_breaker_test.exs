# SPDX-License-Identifier: Apache-2.0
defmodule Elzoo.CircuitBreakerTest do
  use ExUnit.Case, async: false
  alias Elzoo.CircuitBreaker, as: C
  @name :circuit_test_primary
  @fuse {:elzoo_circuit_breaker, @name}

  defp start(opts \\ []) do
    {:ok, owner} =
      C.start_link(
        Keyword.merge([name: @name, cooldown_ms: 30, observation_timeout_ms: 2_000], opts)
      )

    Process.unlink(owner)
    on_exit(fn -> if Process.alive?(owner), do: GenServer.stop(owner) end)
    owner
  end

  defp closed(opts \\ []) do
    owner = start(opts)
    {:ok, p} = C.admit(owner)
    assert C.finish(owner, p, :healthy) == {:ok, :applied}
    owner
  end

  defp status(owner) do
    {:ok, s} = C.status(owner)
    s
  end

  defp clock(value) do
    {:ok, agent} = Agent.start_link(fn -> value end)

    {agent,
     fn ->
       case Agent.get(agent, & &1) do
         :raise -> raise "private clock error"
         :throw -> throw(:private_clock_error)
         value -> value
       end
     end}
  end

  defp eventually(fun, ms \\ 2_000) do
    deadline = System.monotonic_time(:millisecond) + ms
    wait(fun, deadline)
  end

  defp wait(fun, deadline) do
    if fun.(),
      do: :ok,
      else:
        (
          assert System.monotonic_time(:millisecond) < deadline, "condition did not become true"
          Process.sleep(5)
          wait(fun, deadline)
        )
  end

  test "C3 cold probation, one failure melts once, minimum cooldown and neutral/failed recovery" do
    owner = start()
    assert status(owner).mode == :half_open
    assert :fuse.ask(@fuse, :sync) == :ok
    {:ok, probe} = C.admit(owner)
    assert C.admit(owner) == {:refused, :probe_busy}
    assert C.finish(owner, probe, :neutral) == {:ok, :applied}
    assert status(owner).mode == :half_open
    {:ok, probe} = C.admit(owner)
    assert C.finish(owner, probe, :healthy) == {:ok, :applied}
    assert status(owner).mode == :closed
    {:ok, first} = C.admit(owner)
    {:ok, old} = C.admit(owner)
    before = :fuse_stats_ets.counters(@fuse)
    assert C.finish(owner, first, :unhealthy) == {:ok, :applied}
    assert :fuse.ask(@fuse, :sync) == :blown
    assert melt_count(@fuse) == Keyword.fetch!(before, :melt) + 1
    s = status(owner)
    assert s.mode == :open and s.tracked == 0 and s.epoch == 1
    assert C.finish(owner, old, :healthy) == {:error, :stale_permit}
    assert C.finish(owner, old, :unhealthy) == {:error, :stale_permit}
    assert melt_count(@fuse) == Keyword.fetch!(before, :melt) + 1
    assert C.admit(owner) == {:refused, :open}

    eventually(fn ->
      :fuse.ask(@fuse, :sync) == :ok and status(owner).cooldown_remaining_ms == 0
    end)

    {:ok, probe} = C.admit(owner)
    assert status(owner).mode == :half_open
    assert C.finish(owner, probe, :neutral) == {:ok, :applied}
    assert status(owner).mode == :half_open
    {:ok, probe} = C.admit(owner)
    assert C.finish(owner, probe, :unknown) == {:ok, :applied}
    assert status(owner).mode == :open

    eventually(fn ->
      :fuse.ask(@fuse, :sync) == :ok and status(owner).cooldown_remaining_ms == 0
    end)

    {:ok, probe} = C.admit(owner)
    assert C.finish(owner, probe, :healthy) == {:ok, :applied}
    assert C.finish(owner, old, :unhealthy) == {:error, :stale_permit}
    assert status(owner).mode == :closed
  end

  def observe(_, measurements, metadata, pid), do: send(pid, {:transition, measurements, metadata})

  defp melt_count(name), do: :fuse_stats_ets.counters(name) |> Keyword.fetch!(:melt)

  test "C4 32 concurrent requesters: delayed probe holds all other recovery admissions" do
    owner = start()
    parent = self()

    callers =
      for _ <- 1..32 do
        spawn_link(fn ->
          send(parent, {:ready, self()})

          receive do
            :go -> :ok
          end

          answer = C.admit(owner)
          send(parent, {:answer, self(), answer})

          receive do
            {:finish, observation} ->
              send(parent, {:finished, self(), C.finish(owner, elem(answer, 1), observation)})

            :done ->
              :ok
          end
        end)
      end

    for pid <- callers, do: assert_receive({:ready, ^pid})
    for pid <- callers, do: send(pid, :go)

    answers =
      for _ <- callers do
        receive do
          {:answer, pid, answer} -> {pid, answer}
        after
          2_000 -> flunk("missing admission")
        end
      end

    assert Enum.count(answers, fn {_, a} -> match?({:ok, _}, a) end) == 1
    assert Enum.count(answers, fn {_, a} -> a == {:refused, :probe_busy} end) == 31
    {holder, _} = Enum.find(answers, fn {_, a} -> match?({:ok, _}, a) end)
    assert C.admit(owner) == {:refused, :probe_busy}
    assert status(owner).tracked == 1
    send(holder, {:finish, :healthy})
    assert_receive {:finished, ^holder, {:ok, :applied}}
    for pid <- callers -- [holder], do: send(pid, :done)
    assert status(owner).mode == :closed
  end

  test "C5 exact expiry retains live probe; authenticated stale finish/abandon only retire its fence" do
    {agent, clock} = clock(-100)
    owner = start(clock: clock, cooldown_ms: 1, observation_timeout_ms: 10)
    {:ok, probe} = C.admit(owner)
    {C, incarnation, _, ref} = probe
    Agent.update(agent, fn _ -> -90 end)
    # The finish itself discovers equality expiry; the old healthy result is discarded.
    assert C.finish(owner, probe, :healthy) == {:ok, :applied}
    s = status(owner)
    assert s.mode == :open and s.epoch == 1 and s.tracked == 0
    Agent.update(agent, fn _ -> -80 end)
    eventually(fn -> :fuse.ask(@fuse, :sync) == :ok end)
    {:ok, probe2} = C.admit(owner)
    Agent.update(agent, fn _ -> -70 end)
    send(owner, {:circuit_expiry, incarnation, ref})
    assert status(owner).mode == :open
    assert status(owner).recovery_probe_held
    assert status(owner).tracked == 1
    Agent.update(agent, fn _ -> -60 end)
    eventually(fn -> :fuse.ask(@fuse, :sync) == :ok end)
    assert C.admit(owner) == {:refused, :probe_busy}
    snapshot = status(owner)
    assert Task.async(fn -> C.abandon(owner, probe2) end) |> Task.await() == {:error, :wrong_holder}
    assert status(owner) == snapshot
    # An already-invalidated fence needs identity, not a fresh health clock.
    before_retirement = :sys.get_state(owner)
    Agent.update(agent, fn _ -> :raise end)
    assert C.abandon(owner, probe2) == {:ok, :applied}
    after_retirement = :sys.get_state(owner)

    for key <- [:mode, :epoch, :open_until, :last_now],
        do: assert(Map.fetch!(after_retirement, key) == Map.fetch!(before_retirement, key))

    Agent.update(agent, fn _ -> -60 end)
    assert C.abandon(owner, probe2) == {:error, :stale_permit}
    {:ok, new_probe} = C.admit(owner)
    send(owner, {:circuit_expiry, incarnation, ref})
    assert C.admit(owner) == {:refused, :probe_busy}
    assert C.finish(owner, new_probe, :healthy) == {:ok, :applied}
    assert status(owner).mode == :closed
  end

  test "C6 saturation, authentication and malformed observations never consume a legitimate token" do
    owner = closed(max_tracked: 1)
    {:ok, permit} = C.admit(owner)
    assert C.admit(owner) == {:refused, :tracking_saturated}
    snapshot = status(owner)

    for malformed <- [:unrecognized, nil, %{secret: "Bearer sensitive"}, {:error, "secret"}] do
      assert C.finish(owner, permit, malformed) == {:error, :invalid_observation}
    end

    assert Task.async(fn -> C.finish(owner, permit, :unhealthy) end) |> Task.await() ==
             {:error, :wrong_holder}

    assert C.finish(owner, :forged, :healthy) == {:error, :invalid_permit}
    {C, incarnation, epoch, _} = permit

    assert C.finish(owner, {C, make_ref(), epoch, make_ref()}, :unhealthy) ==
             {:error, :invalid_permit}

    assert C.finish(owner, {C, incarnation, epoch, make_ref()}, :unhealthy) ==
             {:error, :stale_permit}

    other = start(name: :circuit_test_foreign)
    {:ok, foreign} = C.admit(other)
    assert C.finish(owner, foreign, :unhealthy) == {:error, :invalid_permit}
    assert C.finish(other, foreign, :healthy) == {:ok, :applied}

    assert C.finish(owner, {C, incarnation, epoch + 1, elem(permit, 3)}, :healthy) ==
             {:error, :invalid_permit}

    assert status(owner) == snapshot
    assert C.finish(owner, permit, :healthy) == {:ok, :applied}
    assert C.finish(owner, permit, :healthy) == {:error, :stale_permit}
    assert {:ok, next} = C.admit(owner)
    assert C.abandon(owner, next) == {:ok, :applied}
    assert status(owner).mode == :open
  end

  test "C7 holder DOWN uses unknown policy; raw secret reason never enters observations" do
    owner = start()
    parent = self()
    handler = {__MODULE__, make_ref()}

    :ok =
      :telemetry.attach(
        handler,
        [:elzoo, :circuit_breaker, :transition],
        &__MODULE__.observe/4,
        parent
      )

    on_exit(fn -> :telemetry.detach(handler) end)

    holder =
      spawn(fn ->
        send(parent, {:probe, C.admit(owner)})

        receive do
          :die -> exit({:secret, "credential-value"})
        end
      end)

    assert_receive {:probe, {:ok, _}}
    send(holder, :die)
    eventually(fn -> status(owner).mode == :open end)
    assert status(owner).tracked == 0
    refute inspect(:sys.get_state(owner)) =~ "credential-value"
    assert_receive {:transition, measurements, metadata}
    assert metadata.cause == :holder_down and metadata.to == :open
    refute inspect({measurements, metadata}) =~ "credential-value"
  end

  test "C21 holder DOWN during clock failure retires the dead probe after recovery" do
    {agent, clock} = clock(100)
    owner = start(clock: clock, cooldown_ms: 1, observation_timeout_ms: 500)
    parent = self()

    holder =
      spawn(fn ->
        send(parent, {:held, C.admit(owner)})

        receive do
          :die -> :ok
        end
      end)

    assert_receive {:held, {:ok, _}}
    Agent.update(agent, fn _ -> :raise end)
    send(holder, :die)

    eventually(fn ->
      Enum.any?(:sys.get_state(owner).permits, fn {_, entry} -> entry.down end)
    end)

    Agent.update(agent, fn _ -> 101 end)
    assert status(owner).mode == :open
    assert status(owner).tracked == 0
    refute status(owner).recovery_probe_held
    Agent.update(agent, fn _ -> 102 end)
    eventually(fn -> :fuse.ask(@fuse, :sync) == :ok end)
    assert {:ok, probe} = C.admit(owner)
    assert C.finish(owner, probe, :healthy) == {:ok, :applied}
    assert status(owner).mode == :closed
  end

  test "C8 duplicate registration cannot reset another fuse; explicit replacement is cold and rejects old tokens" do
    owner = closed()
    {:ok, permit} = C.admit(owner)
    cooldown = System.convert_time_unit(status(owner).settings.cooldown_ms, :millisecond, :native)

    eventually(fn ->
      if :fuse.ask(@fuse, :sync) == :ok and status(owner).cooldown_remaining_ms == 0 do
        {:ok, sample} = C.admit(owner)
        started = System.monotonic_time()
        assert C.finish(owner, sample, :unhealthy) == {:ok, :applied}
        assert C.start_link(name: @name, cooldown_ms: 60_000) == {:error, {:already_started, owner}}
        assert status(owner).mode == :open
        provider = :fuse.ask(@fuse, :sync)

        # A later auto-reset says nothing about whether the duplicate reset the fuse.
        if System.monotonic_time() - started < cooldown do
          assert provider == :blown
        else
          false
        end
      else
        false
      end
    end)

    assert C.child_spec(name: @name).restart == :temporary
    GenServer.stop(owner)
    replacement = start()
    assert status(replacement).mode == :half_open
    assert C.finish(replacement, permit, :healthy) == {:error, :invalid_permit}
    assert C.admit(owner) == {:error, :owner_unavailable}
    assert C.admit(@name) == {:error, :owner_unavailable}
  end

  test "C9 injected name-only resets after melt and name reuse cannot bypass local cooldown" do
    {agent, clock} = clock(-5_000)
    owner = closed(clock: clock, cooldown_ms: 1_000)
    {:ok, permit} = C.admit(owner)
    assert C.finish(owner, permit, :unhealthy) == {:ok, :applied}
    send(Process.whereis(:fuse_server), {:reset, @fuse})
    assert :fuse.ask(@fuse, :sync) == :ok
    assert C.admit(owner) == {:refused, :open}
    GenServer.stop(owner)
    replacement = closed(clock: clock, cooldown_ms: 1_000)
    {:ok, permit} = C.admit(replacement)
    assert C.finish(replacement, permit, :unknown) == {:ok, :applied}
    send(Process.whereis(:fuse_server), {:reset, @fuse})
    assert :fuse.ask(@fuse, :sync) == :ok
    assert C.admit(replacement) == {:refused, :open}
    Agent.update(agent, fn _ -> -4_000 end)
    {:ok, probe} = C.admit(replacement)
    assert C.admit(replacement) == {:refused, :probe_busy}
    assert C.finish(replacement, probe, :healthy) == {:ok, :applied}
  end

  test "C10 invalid/backward/raising clock refuses unchanged; large forward expires instead of healing" do
    {agent, clock} = clock(-100)
    owner = start(clock: clock, observation_timeout_ms: 100)
    {:ok, p} = C.admit(owner)

    for bad <- [-101, nil, 1.2, :raise, :throw] do
      Agent.update(agent, fn _ -> bad end)
      assert C.admit(owner) == {:refused, :clock_unavailable}
      assert C.finish(owner, p, :healthy) == {:error, :clock_unavailable}
      assert :sys.get_state(owner).mode == :half_open
      assert :sys.get_state(owner).epoch == 0
    end

    Agent.update(agent, fn _ -> 100_000 end)
    assert C.finish(owner, p, :healthy) == {:ok, :applied}
    assert status(owner).mode == :open
    # Model a wall discontinuity independently: wall time is never read by the owner.
    for wall <- [-9_999_999_999, 9_999_999_999] do
      Process.put(:model_wall, wall)
      assert status(owner).cooldown_remaining_ms == 30
      assert C.admit(owner) == {:refused, :open}
    end
  end

  test "C11 invalid construction is rejected before any upstream install" do
    assert :fuse.ask(@fuse, :sync) == {:error, :not_found}

    for opts <- [
          nil,
          %{},
          [],
          [name: "dynamic"],
          [name: nil],
          [name: @name, threshold: 2],
          [name: @name, role: :secret],
          [name: @name, clock: 1],
          [name: @name, name: @name],
          [name: @name, cooldown_ms: 0],
          [name: @name, cooldown_ms: 60_001],
          [name: @name, observation_timeout_ms: 0],
          [name: @name, observation_timeout_ms: 60_001],
          [name: @name, max_tracked: 0],
          [name: @name, max_tracked: 4097],
          [{:name, @name} | :bad]
        ] do
      assert C.start_link(opts) == {:error, :invalid_options}
      assert :fuse.ask(@fuse, :sync) == {:error, :not_found}
    end

    for opts <- [
          [cooldown_ms: 1, observation_timeout_ms: 1, max_tracked: 1],
          [cooldown_ms: 60_000, observation_timeout_ms: 60_000, max_tracked: 4096]
        ] do
      owner = start(opts)
      assert status(owner).settings.cooldown_ms == opts[:cooldown_ms]
      GenServer.stop(owner)
    end
  end
end
