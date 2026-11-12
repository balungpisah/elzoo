# SPDX-License-Identifier: Apache-2.0
defmodule Elzoo.AsyncWorkTest do
  use ExUnit.Case, async: true
  import ExUnit.CaptureLog
  alias Elzoo.AsyncWork

  defmodule Receiver do
    use GenServer

    def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: opts[:name])

    def init(opts) do
      # Illustrates caller recovery policy, not an AsyncWork recovery feature.
      if ref = opts[:prior_action],
        do: send(opts[:observer], {:recovered, ref, {:lost, :unavailable}})

      {:ok, %{observer: opts[:observer], open: MapSet.new()}}
    end

    def handle_call({:open, ref}, _, state),
      do: {:reply, :ok, %{state | open: MapSet.put(state.open, ref)}}

    def handle_info({:close, ref}, state),
      do: {:noreply, %{state | open: MapSet.delete(state.open, ref)}}

    def handle_info({:input, value}, state) do
      send(state.observer, {:input_handled, self(), value})
      {:noreply, state}
    end

    def handle_info({:work, ref, outcome}, state) do
      status = if MapSet.member?(state.open, ref), do: :applied, else: :late
      send(state.observer, {:offer, self(), ref, outcome, status})
      {:noreply, %{state | open: MapSet.delete(state.open, ref)}}
    end
  end

  setup do
    registry = __MODULE__.Registry
    start_supervised!({Registry, keys: :unique, name: registry})
    supervisor = start_supervised!(Task.Supervisor)
    owner = {:via, Registry, {registry, :owner}}
    receiver = receiver(owner)
    opts = [owner: owner, task_supervisor: supervisor, max_concurrency: 2]
    controller = start_supervised!({AsyncWork, opts})
    %{controller: controller, receiver: receiver, owner: owner, supervisor: supervisor, opts: opts}
  end

  defp receiver(owner, prior_action \\ nil) do
    start_supervised!(%{
      id: Receiver,
      start: {Receiver, :start_link, [[name: owner, observer: self(), prior_action: prior_action]]},
      restart: :temporary
    })
  end

  defp wrap(ref, outcome), do: {:work, ref, outcome}

  defp held(tag, trap \\ false) do
    observer = self()

    fn ->
      Process.flag(:trap_exit, trap)
      send(observer, {:running, tag, self()})

      receive do
        :release -> {:value, tag}
      end
    end
  end

  defp start_held(controller, tag, timeout \\ 5_000, trap \\ false) do
    assert {:ok, ref} = AsyncWork.start(controller, held(tag, trap), timeout, &wrap/2)
    assert_receive {:running, ^tag, pid}
    {ref, pid, Process.monitor(pid)}
  end

  test "AW1 — free owner and completed work", c do
    {ref, pid, monitor} = start_held(c.controller, :first)
    assert is_reference(ref)
    :ok = GenServer.call(c.receiver, {:open, ref})
    send(c.receiver, {:input, :ordinary})
    assert_receive {:input_handled, receiver, :ordinary}
    assert receiver == c.receiver
    assert Process.alive?(pid)
    send(pid, :release)
    assert_receive {:offer, ^receiver, ^ref, {:completed, {:value, :first}}, :applied}
    assert_receive {:DOWN, ^monitor, :process, ^pid, _}
    assert {:error, :late} = AsyncWork.cancel(c.controller, ref)
    refute_receive {:offer, _, ^ref, _, _}
  end

  test "AW2 — cancel during work and result after cancel", c do
    {ref, pid, monitor} = start_held(c.controller, :cancelled, 5_000, true)
    :ok = GenServer.call(c.receiver, {:open, ref})
    send(c.receiver, {:close, ref})
    assert :ok = AsyncWork.cancel(c.controller, ref)
    assert_receive {:DOWN, ^monitor, :process, ^pid, :killed}
    assert_receive {:offer, _, ^ref, {:lost, :killed}, :late}
    send(pid, :release)
    send(c.controller, {ref, {:completed, :racing}})
    assert {:error, :late} = AsyncWork.cancel(c.controller, ref)
    refute_receive {:offer, _, ^ref, _, _}
    send(c.receiver, {:work, ref, {:completed, :already_sent}})
    assert_receive {:offer, _, ^ref, {:completed, :already_sent}, :late}

    # Completion can win controller arbitration while the receiver is cancelling.
    observer = self()

    {:ok, won} =
      AsyncWork.start(c.controller, held(:won), 5_000, fn ref, outcome ->
        send(observer, {:wrapped, ref})
        wrap(ref, outcome)
      end)

    assert_receive {:running, :won, worker}
    :ok = GenServer.call(c.receiver, {:open, won})
    :sys.suspend(c.receiver)

    try do
      send(c.receiver, {:close, won})
      send(worker, :release)
      assert_receive {:wrapped, ^won}
      assert {:error, :late} = AsyncWork.cancel(c.controller, won)
      :sys.resume(c.receiver)
      assert_receive {:offer, _, ^won, {:completed, {:value, :won}}, :late}
    after
      :sys.resume(c.receiver)
    end
  end

  test "AW3 — worker loss is sanitized, completed payload remains legitimate", c do
    sentinel = "PRIVATE_WORK_SENTINEL"

    logs =
      capture_log(fn ->
        for fun <- [fn -> raise sentinel end, fn -> throw(sentinel) end, fn -> exit(sentinel) end] do
          {:ok, ref} = AsyncWork.start(c.controller, fun, 5_000, &wrap/2)
          assert_receive {:offer, _, ^ref, {:lost, :unavailable}, :late}
        end

        for reason <- [:kill, :killed, :shutdown] do
          {:ok, ref} = AsyncWork.start(c.controller, fn -> exit(reason) end, 5_000, &wrap/2)
          assert_receive {:offer, _, ^ref, {:lost, :killed}, :late}
        end

        {ref, pid, monitor} = start_held(c.controller, :external_kill)
        Process.exit(pid, :kill)
        assert_receive {:DOWN, ^monitor, :process, ^pid, :killed}
        assert_receive {:offer, _, ^ref, {:lost, :killed}, :late}

        {:ok, ref} = AsyncWork.start(c.controller, fn -> sentinel end, 5_000, &wrap/2)
        assert_receive {:offer, _, ^ref, {:completed, ^sentinel}, :late}
      end)

    refute logs =~ sentinel
    assert logs == ""
    refute_receive _
  end

  test "AW4 — deadline kills survivors and queued success cannot win late", c do
    for trap <- [false, true] do
      {ref, pid, monitor} = start_held(c.controller, {:expiry, trap}, 100, trap)
      assert_receive {:offer, _, ^ref, {:lost, :timed_out}, :late}, 1_000
      assert_receive {:DOWN, ^monitor, :process, ^pid, :killed}
    end

    {ref, pid, monitor} = start_held(c.controller, :queued_success, 100)
    :sys.suspend(c.controller)

    try do
      send(pid, :release)
      assert_receive {:DOWN, ^monitor, :process, ^pid, :normal}
      Process.sleep(120)
      :sys.resume(c.controller)
      assert_receive {:offer, _, ^ref, {:lost, :timed_out}, :late}
      refute_receive {:offer, _, ^ref, _, _}
    after
      :sys.resume(c.controller)
    end
  end

  test "AW5 — owner-only restart retains tracking; controller restart loses it", c do
    {ref, pid, monitor} = start_held(c.controller, :owner_restart)
    :ok = GenServer.call(c.receiver, {:open, ref})
    dead = Process.monitor(c.receiver)
    Process.exit(c.receiver, :kill)
    assert_receive {:DOWN, ^dead, :process, _, :killed}
    replacement = receiver(c.owner, ref)
    assert replacement != c.receiver
    assert_receive {:recovered, ^ref, {:lost, :unavailable}}
    assert Process.alive?(c.controller)
    send(pid, :release)
    assert_receive {:offer, ^replacement, ^ref, {:completed, {:value, :owner_restart}}, :late}
    assert_receive {:DOWN, ^monitor, :process, ^pid, _}

    {old, worker, worker_monitor} = start_held(c.controller, :controller_restart, 5_000, true)
    :ok = stop_supervised(AsyncWork)
    assert_receive {:DOWN, ^worker_monitor, :process, ^worker, :killed}
    restarted = start_supervised!({AsyncWork, c.opts})
    assert {:error, :late} = AsyncWork.cancel(restarted, old)
    send(restarted, {old, {:completed, :not_recovered}})
    refute_receive {:offer, _, ^old, _, _}
  end

  test "AW6 — bound, refusal, concurrent admission and shutdown", c do
    {first, pid1, mon1} = start_held(c.controller, :one)
    {second, pid2, mon2} = start_held(c.controller, :two)
    assert {:error, :capacity} = AsyncWork.start(c.controller, held(:refused), 5_000, &wrap/2)
    refute_receive {:running, :refused, _}
    assert length(Task.Supervisor.children(c.supervisor)) == 2
    send(pid1, :release)
    assert_receive {:offer, _, ^first, {:completed, {:value, :one}}, :late}
    assert_receive {:DOWN, ^mon1, :process, ^pid1, _}
    {third, pid3, mon3} = start_held(c.controller, :three, 5_000, true)
    assert :ok = AsyncWork.cancel(c.controller, second)
    assert_receive {:DOWN, ^mon2, :process, ^pid2, :killed}
    assert_receive {:offer, _, ^second, {:lost, :killed}, :late}
    assert :ok = AsyncWork.cancel(c.controller, third)
    assert_receive {:DOWN, ^mon3, :process, ^pid3, :killed}
    assert_receive {:offer, _, ^third, {:lost, :killed}, :late}

    for {fun, timeout, wrap} <-
          [
            {:not_fun, 1, &wrap/2},
            {fn _ -> :bad_arity end, 1, &wrap/2},
            {fn -> :ok end, 1, fn _ -> :bad_arity end}
          ] ++ for(timeout <- [0, -1, 4_294_967_296, 1.0], do: {fn -> :ok end, timeout, &wrap/2}) do
      assert {:error, :invalid_work} = AsyncWork.start(c.controller, fun, timeout, wrap)
    end

    {:ok, maximum} = AsyncWork.start(c.controller, held(:maximum), 4_294_967_295, &wrap/2)
    assert_receive {:running, :maximum, _}
    assert :ok = AsyncWork.cancel(c.controller, maximum)
    assert_receive {:offer, _, ^maximum, {:lost, :killed}, :late}

    missing =
      start_supervised!({AsyncWork, Keyword.put(c.opts, :task_supervisor, :absent)}, id: :missing)

    assert {:error, :unavailable} = AsyncWork.start(missing, held(:missing), 1, &wrap/2)
    full_sup = start_supervised!({Task.Supervisor, max_children: 0}, id: :full_sup)

    full =
      start_supervised!({AsyncWork, Keyword.put(c.opts, :task_supervisor, full_sup)}, id: :full)

    assert {:error, :unavailable} = AsyncWork.start(full, held(:full), 1, &wrap/2)
    refute_receive {:running, _, _}
    refute_receive {:offer, _, _, _, _}

    observer = self()

    callers =
      for tag <- 1..8 do
        Task.async(fn ->
          AsyncWork.start(
            c.controller,
            fn ->
              Process.flag(:trap_exit, true)
              send(observer, {:concurrent, self()})
              receive do: (:release -> :ok)
            end,
            5_000,
            &wrap/2
          )
          |> then(&{tag, &1})
        end)
      end

    results = Enum.map(callers, &Task.await/1)
    assert Enum.count(results, &match?({_, {:ok, _}}, &1)) == 2
    assert Enum.count(results, &match?({_, {:error, :capacity}}, &1)) == 6
    assert_receive {:concurrent, a}
    assert_receive {:concurrent, b}
    assert a != b
    assert length(Task.Supervisor.children(c.supervisor)) == 2
    monitors = for pid <- [a, b], do: {pid, Process.monitor(pid)}
    :ok = stop_supervised(AsyncWork)
    for {pid, monitor} <- monitors, do: assert_receive({:DOWN, ^monitor, :process, ^pid, :killed})
    assert Process.alive?(c.supervisor)
    assert Task.Supervisor.children(c.supervisor) == []
  end

  test "AW7 — unavailable offers and settled duplicate signals", c do
    observer = self()

    {:ok, ref} =
      AsyncWork.start(c.controller, held(:absent_owner), 5_000, fn ref, outcome ->
        send(observer, {:wrap_attempt, ref})
        wrap(ref, outcome)
      end)

    assert_receive {:running, :absent_owner, pid}
    monitor = Process.monitor(pid)
    :ok = stop_supervised(Receiver)
    send(pid, :release)
    assert_receive {:DOWN, ^monitor, :process, ^pid, _}
    assert_receive {:wrap_attempt, ^ref}
    assert {:error, :late} = AsyncWork.cancel(c.controller, ref)

    # Capture the whole failing invocation, not just the later observation.
    {next, logs} =
      with_log(fn ->
        {:ok, work_ref} =
          AsyncWork.start(c.controller, fn -> :value end, 5_000, fn ref, _ ->
            send(observer, {:wrap_attempt, ref})
            raise "PRIVATE_WRAP_SENTINEL"
          end)

        assert_receive {:wrap_attempt, ^work_ref}
        assert {:error, :late} = AsyncWork.cancel(c.controller, work_ref)
        work_ref
      end)

    assert logs == ""
    assert Process.alive?(c.controller)
    replacement = receiver(c.owner)
    assert {:error, :late} = AsyncWork.cancel(c.controller, ref)

    for settled <- [ref, next] do
      send(c.controller, {settled, {:completed, :duplicate}})
      send(c.controller, {:DOWN, settled, :process, pid, :killed})
      send(c.controller, {:deadline, settled})
      assert {:error, :late} = AsyncWork.cancel(c.controller, settled)
    end

    assert {:error, :late} = AsyncWork.cancel(c.controller, make_ref())
    refute_receive {:wrap_attempt, _}
    refute_receive {:offer, ^replacement, _, _, _}
    {:ok, final} = AsyncWork.start(c.controller, fn -> :still_usable end, 5_000, &wrap/2)
    assert_receive {:offer, ^replacement, ^final, {:completed, :still_usable}, :late}
  end
end
