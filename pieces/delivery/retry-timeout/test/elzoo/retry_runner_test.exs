# SPDX-License-Identifier: Apache-2.0
defmodule Elzoo.RetryRunnerTest do
  use ExUnit.Case, async: false
  alias Elzoo.RetryTimeout, as: R
  alias Elzoo.RetryTimeout.Runner

  defp request(id \\ "m", extra \\ %{}) do
    Map.merge(
      %{
        "version" => 1,
        "message_id" => id,
        "schema_id" => "v",
        "schema_version" => 1,
        "kind" => "command",
        "producer" => %{"unit_id" => "u", "port_id" => "p"},
        "payload" => "secret",
        "idempotency_key" => id
      },
      extra
    )
  end

  defp result(request, outcome \\ "completed", dispatch \\ "dispatched", error \\ nil) do
    common =
      Map.take(request, ~w(message_id attempt_id deadline_unix_ms))
      |> Map.merge(%{
        "version" => 1,
        "correlation_id" => Map.get(request, "correlation_id", request["message_id"]),
        "outcome" => outcome,
        "dispatch" => dispatch
      })

    if error,
      do: Map.put(common, "error_class", error),
      else:
        Map.merge(common, %{"value" => nil, "value_schema_id" => "v", "value_schema_version" => 1})
  end

  defp runner(attempt, opts \\ [], policy_opts \\ []) do
    supervisor = start_supervised!({Task.Supervisor, []}, id: make_ref())
    {:ok, policy} = R.policy(Keyword.merge([base_backoff_ms: 1, max_backoff_ms: 1], policy_opts))

    defaults = [
      capacity: 1,
      policy: policy,
      attempt_timeout_ms: 1000,
      attempt: attempt,
      dead_letter: fn _ -> :ok end,
      now_ms: fn -> 1000 end,
      task_supervisor: supervisor
    ]

    start_supervised!({Runner, Keyword.merge(defaults, opts)}, id: make_ref())
  end

  defp settlement(ref) do
    assert_receive {R, ^ref, value}, 2000
    value
  end

  defp bounds(pid, expected \\ 0) do
    snapshot = Runner.snapshot(pid)
    assert snapshot.in_flight == snapshot.open
    assert snapshot.open == expected
    assert snapshot.in_flight in 0..snapshot.capacity
    snapshot
  end

  test "success, duplicate-open and resubmission after settlement; overflow is declared" do
    parent = self()

    attempt = fn req ->
      send(parent, {:started, self(), req})

      receive do
        :complete -> result(req)
      end
    end

    pid = runner(attempt)
    assert {:error, {:envelope, _}} = Runner.submit(pid, nil)

    assert {:error, :attempt_id_present} =
             Runner.submit(pid, request("bad", %{"attempt_id" => "x"}))

    assert {:ok, ref} = Runner.submit(pid, request())
    assert_receive {:started, task, req}
    assert req["attempt_id"] == "m/attempt/1"
    assert req["idempotency_key"] == "m"
    assert Runner.submit(pid, request()) == {:error, :operation_in_flight}
    assert {:error, {:saturated, saturated}} = Runner.submit(pid, request("other"))
    assert {:ok, ^saturated} = Elzoo.Envelope.validate_result(saturated)
    assert saturated["dispatch"] == "not_dispatched"
    bounds(pid, 1)
    state = :sys.get_state(pid)
    op = state.ops[ref]

    stale =
      for {kind, {timer, token, _}} <- op.timers do
        {kind, token, timer}
      end

    send(task, :complete)
    assert {:completed, completed} = settlement(ref)
    assert {:ok, ^completed} = Elzoo.Envelope.validate_result(completed)
    assert bounds(pid).settled == 1

    for {kind, token, timer} <- stale do
      assert Process.read_timer(timer) == false
      send(pid, {:retry_timer, ref, kind, token})
    end

    send(pid, {make_ref(), completed})
    assert bounds(pid).settled == 1
    refute_receive {R, ^ref, _}, 10
    assert {:ok, again} = Runner.submit(pid, request())
    assert_receive {:started, task, _}
    send(task, :complete)
    assert {:completed, _} = settlement(again)
    assert bounds(pid).settled == 2
  end

  test "retry retains identity and slot, stops at max; idempotent mode is explicit" do
    parent = self()

    for mode <- [:redispatch_forbidden, :redispatch_idempotent] do
      attempt = fn req ->
        send(parent, {:attempt, req})

        if req["attempt_id"] == "m/attempt/1",
          do: result(req, "rejected", "not_dispatched", "unavailable"),
          else: result(req)
      end

      pid = runner(attempt, [], mode: mode)
      {:ok, ref} = Runner.submit(pid, request("m", %{"correlation_id" => "c"}))
      assert {:completed, _} = settlement(ref)
      assert_receive {:attempt, first}
      assert_receive {:attempt, second}
      assert first["idempotency_key"] == second["idempotency_key"]
      assert first["correlation_id"] == second["correlation_id"]
      assert second["attempt_id"] == "m/attempt/2"
      bounds(pid)
    end

    for {outcome, dispatch} <- [
          {"failed", "dispatched"},
          {"unknown", "unknown"},
          {"timed_out", "unknown"}
        ],
        {mode, count, reason} <- [
          {:redispatch_forbidden, 1, "dispatched_unresolved"},
          {:redispatch_idempotent, 3, "retries_exhausted"}
        ] do
      pid =
        runner(
          fn req ->
            send(parent, :dispatched)
            result(req, outcome, dispatch, "retryable")
          end,
          [],
          mode: mode
        )

      {:ok, ref} = Runner.submit(pid, request())
      assert {:dead_lettered, record} = settlement(ref)
      assert record["attempts"] == count
      assert record["reason"] == reason
      for _ <- 1..count, do: assert_receive(:dispatched)
      refute_receive :dispatched, 5
      bounds(pid)
    end
  end

  test "all terminal paths release exactly one slot, cancel timers and ignore stale tokens" do
    parent = self()

    cases = [
      {:permanent, fn req -> result(req, "failed", "dispatched", "permanent") end, [], [],
       "permanent"},
      {:exhausted, fn req -> result(req, "rejected", "not_dispatched", "retryable") end, [],
       [max_attempts: 1], "retries_exhausted"},
      {:unresolved, fn req -> result(req, "unknown", "unknown", "unclassified") end, [], [],
       "dispatched_unresolved"},
      {:invalid, fn _ -> :bad end, [], [], "dispatched_unresolved"},
      {:mismatch, fn req -> Map.put(result(req), "attempt_id", "wrong") end, [], [],
       "dispatched_unresolved"},
      {:crash, fn _ -> exit(:noproc) end, [], [], "dispatched_unresolved"},
      {:timeout,
       fn _ ->
         receive do
           :never -> nil
         end
       end, [attempt_timeout_ms: 100], [], "dispatched_unresolved"},
      {:deadline,
       fn _ ->
         receive do
           :never -> nil
         end
       end, [], [], "deadline_expired"}
    ]

    for {name, attempt, opts, policy, reason} <- cases do
      gated = fn req ->
        send(parent, {:gated, self()})

        receive do
          :go -> attempt.(req)
        end
      end

      pid = runner(gated, opts, policy)

      extra =
        if name == :deadline,
          do: %{"deadline_unix_ms" => 1200},
          else: %{"deadline_unix_ms" => 11000}

      {:ok, ref} = Runner.submit(pid, request(Atom.to_string(name), extra))
      assert_receive {:gated, task}
      bounds(pid, 1)
      state = :sys.get_state(pid)
      tokens = state.ops[ref].timers
      send(task, :go)
      assert {:dead_lettered, record} = settlement(ref)
      assert record["reason"] == reason
      assert record["last_dispatch"] != "not_dispatched" or name in [:exhausted]
      assert bounds(pid).settled == 1
      assert :sys.get_state(pid).tasks == %{}

      for {kind, {timer, token, _}} <- tokens do
        assert Process.read_timer(timer) == false
        send(pid, {:retry_timer, ref, kind, token})
      end

      assert bounds(pid).settled == 1
      refute_receive {R, ^ref, _}, 5
    end
  end

  test "sink errors, raises, throws and exits are unsettled and release capacity" do
    for sink <- [
          fn _ -> {:error, :offline} end,
          fn _ -> raise "secret" end,
          fn _ -> throw(:secret) end,
          fn _ -> exit(:secret) end
        ] do
      pid =
        runner(fn req -> result(req, "rejected", "not_dispatched", "permanent") end,
          dead_letter: sink
        )

      {:ok, ref} = Runner.submit(pid, request())
      assert {:unsettled, record} = settlement(ref)
      assert record["reason"] == "permanent"
      assert bounds(pid).dead_lettered == 0
      assert Process.alive?(pid)
    end
  end

  test "admission expiry, long chunked timer and deadline during backoff" do
    parent = self()
    pid = runner(fn _ -> send(parent, :should_not_dispatch) end)

    assert {:error, {:expired, expired}} =
             Runner.submit(pid, request("m", %{"deadline_unix_ms" => 1000}))

    assert {:ok, ^expired} = Elzoo.Envelope.validate_result(expired)

    assert {:ok, record} =
             Elzoo.DeadLetter.from_result(
               request("m", %{"deadline_unix_ms" => 1000}),
               expired,
               0,
               "deadline_before_dispatch"
             )

    assert record["attempts"] == 0
    bounds(pid)
    refute_receive :should_not_dispatch, 5

    pid =
      runner(fn req ->
        send(parent, {:far_attempt, self()})

        receive do
          :finish -> result(req)
        end
      end)

    {:ok, ref} = Runner.submit(pid, request("far", %{"deadline_unix_ms" => 1000 + 4_294_967_296}))
    assert_receive {:far_attempt, task}
    {timer, token, target} = :sys.get_state(pid).ops[ref].timers.deadline
    assert Process.read_timer(timer) <= 4_294_967_295
    Process.cancel_timer(timer)
    send(pid, {:retry_timer, ref, :deadline, token})
    {rearmed, ^token, ^target} = :sys.get_state(pid).ops[ref].timers.deadline
    refute rearmed == timer
    assert Process.read_timer(rearmed) > 0
    assert Process.read_timer(rearmed) <= 4_294_967_295
    send(pid, {:retry_timer, ref, :deadline, make_ref()})
    assert :sys.get_state(pid).ops[ref].timers.deadline == {rearmed, token, target}
    send(task, :finish)
    assert {:completed, _} = settlement(ref)
    assert Process.read_timer(rearmed) == false
    bounds(pid)

    pid =
      runner(
        fn req ->
          send(parent, :one_attempt)
          result(req, "rejected", "not_dispatched", "retryable")
        end,
        [],
        base_backoff_ms: 1000,
        max_backoff_ms: 1000
      )

    {:ok, ref} = Runner.submit(pid, request("backoff", %{"deadline_unix_ms" => 1040}))
    assert_receive :one_attempt
    assert {:dead_lettered, record} = settlement(ref)
    assert record["reason"] == "deadline_expired"
    assert record["attempts"] == 1
    refute_receive :one_attempt, 10
    bounds(pid)
  end

  test "deadline wins over queued retry and late task reply cannot settle again" do
    parent = self()

    pid =
      runner(fn req ->
        send(parent, {:begun, self(), req})

        receive do
          :never -> nil
        end
      end)

    {:ok, ref} = Runner.submit(pid, request("late", %{"deadline_unix_ms" => 1030}))
    assert_receive {:begun, task, req}
    state = :sys.get_state(pid)
    task_ref = state.ops[ref].task.ref
    assert {:dead_lettered, record} = settlement(ref)
    assert record["reason"] == "deadline_expired"
    refute Process.alive?(task)
    send(pid, {task_ref, result(req)})
    assert bounds(pid).late_or_mismatched == 1
    refute_receive {R, ^ref, _}, 10
  end

  test "finite concurrent trace conserves slots after each transition" do
    parent = self()

    pid =
      runner(
        fn req ->
          send(parent, {:blocked, req["message_id"], self()})

          receive do
            :go -> result(req)
          end
        end,
        capacity: 3
      )

    refs =
      for i <- 1..3 do
        {:ok, ref} = Runner.submit(pid, request("m" <> Integer.to_string(i)))
        bounds(pid, i)
        ref
      end

    tasks =
      for _ <- 1..3 do
        assert_receive {:blocked, id, task}
        {id, task}
      end

    assert {:error, {:saturated, _}} = Runner.submit(pid, request("fourth"))
    bounds(pid, 3)

    for {{_, task}, {ref, i}} <- Enum.zip(tasks |> Enum.sort(), Enum.with_index(refs, 1)) do
      send(task, :go)
      assert {:completed, _} = settlement(ref)
      bounds(pid, 3 - i)
    end
  end

  test "runner restart is volatile: DOWN is unknown, no success or resumed attempt" do
    parent = self()

    pid =
      runner(fn req ->
        send(parent, {:running, self()})

        receive do
          :go -> result(req)
        end
      end)

    monitor = Process.monitor(pid)
    {:ok, ref} = Runner.submit(pid, request())
    assert_receive {:running, old_task}
    Process.exit(pid, :kill)
    assert_receive {:DOWN, ^monitor, :process, ^pid, :killed}
    refute_receive {R, ^ref, _}, 10
    Process.exit(old_task, :kill)
    {:ok, supervisor} = ExUnit.fetch_test_supervisor()
    replacement = await_replacement(supervisor, pid, 100)
    assert bounds(replacement).capacity == 1
    {:ok, next} = Runner.submit(replacement, request())
    assert_receive {:running, new_task}
    send(new_task, :go)
    assert {:completed, _} = settlement(next)
  end

  defp spin, do: spin()

  defp await_replacement(_, _, 0), do: flunk("supervisor did not restart runner")

  defp await_replacement(supervisor, old, remaining) do
    case Enum.find(Supervisor.which_children(supervisor), fn
           {_, pid, _, [Runner]} when is_pid(pid) -> pid != old
           _ -> false
         end) do
      {_, pid, _, _} ->
        pid

      nil ->
        Process.sleep(10)
        await_replacement(supervisor, old, remaining - 1)
    end
  end

  test "timeout and deadline expiry kill an exit-trapping attempt without blocking" do
    parent = self()

    trapping = fn req ->
      Process.flag(:trap_exit, true)
      send(parent, {:trapping, self(), req["message_id"]})
      Process.sleep(:infinity)
    end

    for {name, opts, extra, reason} <- [
          {"attempt-timeout", [attempt_timeout_ms: 30], %{}, "dispatched_unresolved"},
          {"deadline", [], %{"deadline_unix_ms" => 1030}, "deadline_expired"}
        ] do
      pid = runner(trapping, opts)
      started = System.monotonic_time(:millisecond)
      {:ok, ref} = Runner.submit(pid, request(name, extra))
      assert_receive {:trapping, task, ^name}
      monitor = Process.monitor(task)
      assert_receive {:DOWN, ^monitor, :process, ^task, :killed}, 1000
      {elapsed_us, snapshot} = :timer.tc(fn -> Runner.snapshot(pid) end)
      assert elapsed_us < 500_000
      assert snapshot.settled == 1
      assert_receive {R, ^ref, {:dead_lettered, record}}, 1000
      assert record["reason"] == reason
      assert record["last_dispatch"] == "unknown"
      assert System.monotonic_time(:millisecond) - started < 1000
      assert :sys.get_state(pid).tasks == %{}
      bounds(pid)
    end
  end

  test "settlement frees the max_children slot of replied and killed attempts under load" do
    parent = self()

    attempt = fn req ->
      Process.flag(:priority, :low)
      send(parent, {:attempt, req["attempt_id"]})

      if String.ends_with?(req["attempt_id"], "/attempt/1") do
        Process.flag(:trap_exit, true)
        Process.sleep(:infinity)
      else
        result(req)
      end
    end

    spinners = for _ <- 1..8, do: spawn(fn -> spin() end)
    on_exit(fn -> Enum.each(spinners, &Process.exit(&1, :kill)) end)

    replying = fn req ->
      Process.flag(:priority, :low)
      send(parent, {:attempt, req["attempt_id"]})

      if String.ends_with?(req["attempt_id"], "/attempt/1"),
        do: result(req, "rejected", "not_dispatched", "retryable"),
        else: result(req)
    end

    for i <- 1..20 do
      tasks = start_supervised!({Task.Supervisor, max_children: 1}, id: make_ref())
      pid = runner(replying, [task_supervisor: tasks], base_backoff_ms: 0, max_backoff_ms: 0)
      id = "reply" <> Integer.to_string(i)
      {:ok, ref} = Runner.submit(pid, request(id))
      assert {:completed, _} = settlement(ref)
      assert Task.Supervisor.children(tasks) == []
      assert_receive {:attempt, first}
      assert_receive {:attempt, second}
      assert {first, second} == {id <> "/attempt/1", id <> "/attempt/2"}
      {:ok, ref} = Runner.submit(pid, request("again" <> Integer.to_string(i)))
      assert {:completed, _} = settlement(ref)
      assert Task.Supervisor.children(tasks) == []
      assert_receive {:attempt, _}
      assert_receive {:attempt, _}

      pid =
        runner(attempt, [attempt_timeout_ms: 20, task_supervisor: tasks],
          mode: :redispatch_idempotent,
          max_attempts: 2,
          base_backoff_ms: 0,
          max_backoff_ms: 0
        )

      id = "retry" <> Integer.to_string(i)
      {:ok, ref} = Runner.submit(pid, request(id))
      assert {:completed, _} = settlement(ref)
      assert Task.Supervisor.children(tasks) == []
      assert_receive {:attempt, first}
      assert_receive {:attempt, second}
      assert {first, second} == {id <> "/attempt/1", id <> "/attempt/2"}
      bounds(pid)

      pid =
        runner(attempt, [attempt_timeout_ms: 20, task_supervisor: tasks],
          mode: :redispatch_idempotent,
          max_attempts: 1
        )

      {:ok, ref} = Runner.submit(pid, request("dead" <> Integer.to_string(i)))
      assert {:dead_lettered, %{"reason" => "retries_exhausted"}} = settlement(ref)
      assert Task.Supervisor.children(tasks) == []
      assert_receive {:attempt, _}
      {:ok, ref} = Runner.submit(pid, request("next" <> Integer.to_string(i)))
      assert_receive {:attempt, _}
      assert {:dead_lettered, %{"reason" => "retries_exhausted"}} = settlement(ref)
      assert Task.Supervisor.children(tasks) == []
    end
  end

  test "elapsed deadline wins even when a success reply is ahead of timer in mailbox" do
    parent = self()

    pid =
      runner(fn req ->
        send(parent, {:waiting, self()})

        receive do
          :go -> result(req)
        end
      end)

    {:ok, ref} = Runner.submit(pid, request("ordered", %{"deadline_unix_ms" => 1200}))
    assert_receive {:waiting, task}
    :ok = :sys.suspend(pid)
    send(task, :go)
    Process.sleep(220)
    :ok = :sys.resume(pid)
    assert {:dead_lettered, record} = settlement(ref)
    assert record["reason"] == "deadline_expired"
    assert record["last_dispatch"] == "unknown"
    bounds(pid)
  end
end
