# SPDX-License-Identifier: Apache-2.0
defmodule Elzoo.AggregationRunnerTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog
  import ExUnit.CaptureIO

  alias Elzoo.{Aggregation, Aggregation.Runner}

  defp new_join(ids, overrides \\ []) do
    config =
      [branch_key: {:field, ["correlation_id"]}, max_result_bytes: 65_536, max_branches: 8]
      |> Keyword.merge(overrides)

    {:ok, join} = Aggregation.new(ids, config)
    join
  end

  defp ok_result(id) do
    %{
      "version" => 1,
      "message_id" => "m/" <> id,
      "correlation_id" => id,
      "outcome" => "completed",
      "dispatch" => "dispatched",
      "value" => %{"branch" => id},
      "value_schema_id" => "test/result",
      "value_schema_version" => 1
    }
  end

  defp failed_result(id) do
    %{
      "version" => 1,
      "message_id" => "m/" <> id,
      "correlation_id" => id,
      "outcome" => "failed",
      "dispatch" => "dispatched",
      "error_class" => "unclassified"
    }
  end

  defp sup_name, do: :"agg-sup-#{System.unique_integer([:positive])}"

  defp await(fun, tries \\ 200)
  defp await(_fun, 0), do: flunk("condition not met in time")

  defp await(fun, tries) do
    if fun.() do
      :ok
    else
      Process.sleep(10)
      await(fun, tries - 1)
    end
  end

  defp await_settled(runner) do
    await(fn ->
      case Runner.status(runner) do
        {:ok, branches} ->
          Enum.all?(branches, fn {_id, record} ->
            record.status not in [:pending, :late]
          end)

        _ ->
          false
      end
    end)
  end

  defp decide(runner) do
    Runner.decision(runner, System.os_time(:millisecond))
  end

  test "runs declared branch funs and joins their results" do
    sup = start_supervised!({Task.Supervisor, name: sup_name()})
    join = new_join(["a", "b"])

    runner =
      start_supervised!(
        {Runner,
         join: join,
         branches: [
           {"a", fn id -> ok_result(id) end},
           {"b", fn id -> ok_result(id) end}
         ],
         task_supervisor: sup}
      )

    await_settled(runner)
    {_join, %{decision: :all}} = decide(runner)
    assert %{launched: 2, running: 0, closed: true, outcome: :all} = Runner.snapshot(runner)
  end

  test "a raising branch becomes :failed through the same join" do
    sup = start_supervised!({Task.Supervisor, name: sup_name()})
    join = new_join(["boom", "fine"])

    runner =
      start_supervised!(
        {Runner,
         join: join,
         branches: [
           {"boom", fn _id -> raise "branch exploded" end},
           {"fine", fn id -> ok_result(id) end}
         ],
         task_supervisor: sup}
      )

    await_settled(runner)
    {_join, %{decision: :partial}} = decide(runner)

    {:ok, branches} = Runner.status(runner)
    assert branches["boom"].status == :failed
    assert branches["boom"].outcome == "failed"
    assert branches["boom"].dispatch == "dispatched"
    assert branches["fine"].status == :fulfilled
  end

  test "a non-result return becomes :failed, not a crash" do
    sup = start_supervised!({Task.Supervisor, name: sup_name()})
    join = new_join(["lazy"])

    runner =
      start_supervised!(
        {Runner,
         join: join, branches: [{"lazy", fn _id -> :not_a_result end}], task_supervisor: sup}
      )

    await_settled(runner)
    {_join, %{decision: :failed}} = decide(runner)

    {:ok, %{"lazy" => record}} = Runner.status(runner)
    assert record.status == :failed
    assert record.error_class == "unclassified"
  end

  test "an explicit failed result from the branch is preserved" do
    sup = start_supervised!({Task.Supervisor, name: sup_name()})
    join = new_join(["bad", "good"])

    runner =
      start_supervised!(
        {Runner,
         join: join,
         branches: [
           {"bad", fn id -> failed_result(id) end},
           {"good", fn id -> ok_result(id) end}
         ],
         task_supervisor: sup}
      )

    await_settled(runner)
    {_join, %{decision: :partial}} = decide(runner)

    {:ok, %{"bad" => bad}} = Runner.status(runner)
    assert bad.status == :failed
    assert bad.error_class == "unclassified"
  end

  test "deadline kills running branches as :timed_out" do
    sup = start_supervised!({Task.Supervisor, name: sup_name()})

    join =
      new_join(["fast", "slow"],
        deadline_unix_ms: System.os_time(:millisecond) + 400
      )

    runner =
      start_supervised!(
        {Runner,
         join: join,
         branches: [
           {"fast", fn id -> ok_result(id) end},
           {"slow", fn _id -> Process.sleep(30_000) end}
         ],
         task_supervisor: sup}
      )

    await(fn ->
      case Runner.status(runner) do
        {:ok, branches} -> branches["slow"].status == :timed_out
        _ -> false
      end
    end)

    await_settled(runner)
    {_join, %{decision: :partial}} = decide(runner)

    {:ok, %{"slow" => slow, "fast" => fast}} = Runner.status(runner)
    assert slow.status == :timed_out
    assert slow.loss == :timed_out
    assert fast.status == :fulfilled
    assert %{running: 0} = Runner.snapshot(runner)
  end

  test "one observed invocation and no retries in one runner call" do
    sup = start_supervised!({Task.Supervisor, name: sup_name()})
    join = new_join(["once"])
    {:ok, counter} = Agent.start_link(fn -> 0 end)

    runner =
      start_supervised!(
        {Runner,
         join: join,
         branches: [
           {"once",
            fn _id ->
              Agent.update(counter, &(&1 + 1))
              raise "always fails"
            end}
         ],
         task_supervisor: sup}
      )

    await_settled(runner)
    {_join, %{decision: :failed}} = decide(runner)
    assert Agent.get(counter, & &1) == 1
  end

  for carrier <- ["correlation_id", "attempt_id"], target <- ["b", "undeclared"] do
    @tag carrier: carrier, target: target
    test "#{carrier}: a response identifying #{target} cannot settle another branch", ctx do
      sup = start_supervised!({Task.Supervisor, name: sup_name()})
      join = new_join(["a", "b"], branch_key: {:field, [ctx.carrier]})
      parent = self()
      result = ok_result("shared") |> Map.put(ctx.carrier, ctx.target)

      runner =
        start_supervised!(
          {Runner,
           join: join,
           branches: [
             {"a", fn _ -> result end},
             {"b",
              fn _ ->
                send(parent, {:waiting, self()})

                receive do
                  :fail -> raise "b failed independently"
                end
              end}
           ],
           task_supervisor: sup}
        )

      assert_receive {:waiting, task}, 1_000
      await(fn -> Runner.snapshot(runner).running == 1 end)
      assert {:ok, %{"a" => a, "b" => b}} = Runner.status(runner)
      assert a.status == :failed
      assert a.outcome == "failed"
      assert a.dispatch == "dispatched"
      assert b.status == :pending
      assert b.duplicate_count == 0
      assert b.conflicted == false

      send(task, :fail)
      await_settled(runner)
      assert {_join, %{decision: :failed, branches: branches}} = decide(runner)
      assert Map.keys(branches) |> Enum.sort() == ["a", "b"]
      assert branches["b"].status == :failed
      assert branches["b"].conflicted == false
      assert branches["b"].duplicate_count == 0
    end
  end

  defp failure_bytes(id, carrier) do
    for {outcome, dispatch, error_class} <- [
          {"failed", "dispatched", "unclassified"},
          {"rejected", "not_dispatched", "unavailable"}
        ] do
      %{
        "version" => 1,
        "message_id" => "aggregation-runner/" <> id,
        "correlation_id" => id,
        "outcome" => outcome,
        "dispatch" => dispatch,
        "error_class" => error_class
      }
      |> Map.put(carrier, id)
      |> :erlang.term_to_binary()
      |> byte_size()
    end
    |> Enum.max()
  end

  for carrier <- ["correlation_id", "attempt_id"], failure <- [:exception, :invalid, :start] do
    @tag carrier: carrier, failure: failure
    test "#{carrier}/#{failure}: insufficient failure capacity is refused before any launch", ctx do
      sup =
        start_supervised!(
          {Task.Supervisor,
           name: sup_name(), max_children: if(ctx.failure == :start, do: 0, else: 8)}
        )

      parent = self()

      fun = fn _ ->
        send(parent, :unexpected_launch)
        if ctx.failure == :exception, do: raise("failure"), else: :invalid
      end

      for {ids, cap} <- [
            {["a"], 64},
            {["a", String.duplicate("i", 256)], 300},
            {[String.duplicate("i", 256)],
             failure_bytes(String.duplicate("i", 256), ctx.carrier) - 1}
          ] do
        join = new_join(ids, branch_key: {:field, [ctx.carrier]}, max_result_bytes: cap)

        assert {:error, :invalid_options} =
                 GenServer.start(Runner,
                   join: join,
                   branches: Enum.map(ids, &{&1, fun}),
                   task_supervisor: sup
                 )

        assert Task.Supervisor.children(sup) == []
        assert {:ok, records} = Aggregation.status(join)
        assert Enum.all?(records, fn {_, r} -> r.status == :pending end)
      end

      refute_receive :unexpected_launch
    end

    @tag carrier: carrier, failure: failure
    test "#{carrier}/#{failure}: failure records fit at the capacity boundary, including long ids",
         ctx do
      sup =
        start_supervised!(
          {Task.Supervisor,
           name: sup_name(), max_children: if(ctx.failure == :start, do: 0, else: 8)}
        )

      parent = self()

      for id <- ["a", String.duplicate("i", 256)] do
        join =
          new_join([id],
            branch_key: {:field, [ctx.carrier]},
            max_result_bytes: failure_bytes(id, ctx.carrier)
          )

        fun = fn _ ->
          send(parent, :invoked)
          if ctx.failure == :exception, do: raise("failure"), else: :invalid
        end

        runner =
          start_supervised!({Runner, join: join, branches: [{id, fun}], task_supervisor: sup},
            id: make_ref()
          )

        await_settled(runner)
        assert {_join, %{decision: :failed}} = decide(runner)
        assert {:ok, %{^id => record}} = Runner.status(runner)
        assert record.status == :failed
        assert record.loss == nil
        assert %{running: 0, refused: refused} = Runner.snapshot(runner)
        assert refused == if(ctx.failure == :invalid, do: 1, else: 0)

        if ctx.failure == :start do
          assert record.outcome == "rejected"
          assert record.dispatch == "not_dispatched"
          assert record.error_class == "unavailable"
          refute_receive :invoked
        else
          assert record.outcome == "failed"
          assert record.dispatch == "dispatched"
          assert record.error_class == "unclassified"
          assert_receive :invoked
        end
      end
    end
  end

  test "raise, throw and exit contents never escape through actual Task logs or public output" do
    sup = start_supervised!({Task.Supervisor, name: sup_name()})
    parent = self()
    secret = "fake-branch-secret-regression"

    logs =
      capture_log(fn ->
        output =
          capture_io(fn ->
            runner =
              start_supervised!(
                {Runner,
                 join: new_join(["raise", "throw", "exit", "invalid"]),
                 branches: [
                   {"raise", fn _ -> raise secret end},
                   {"throw", fn _ -> throw({:secret, secret}) end},
                   {"exit", fn _ -> exit({:secret, secret}) end},
                   {"invalid", fn _ -> {:error, secret} end}
                 ],
                 task_supervisor: sup}
              )

            await_settled(runner)
            assert {join, %{decision: :failed} = outcome} = decide(runner)
            assert {:ok, records} = Runner.status(runner)

            assert Enum.all?(records, fn {_, r} ->
                     r.status == :failed and r.error_class == "unclassified"
                   end)

            observed = {join, outcome, Runner.join(runner), Runner.snapshot(runner)}
            send(parent, {:inspection, inspect(observed)})
            Logger.flush()
          end)

        refute output =~ secret
      end)

    refute logs =~ secret
    refute logs =~ "Task.Supervised"
    assert_receive {:inspection, inspection}
    refute inspection =~ secret
  end

  for reason <- [:kill, :killed, :shutdown] do
    @tag exit_reason: reason
    test "caught #{reason} exit retains the killed loss mapping", ctx do
      sup = start_supervised!({Task.Supervisor, name: sup_name()})

      runner =
        start_supervised!(
          {Runner,
           join: new_join(["a"]),
           branches: [{"a", fn _ -> exit(ctx.exit_reason) end}],
           task_supervisor: sup}
        )

      await_settled(runner)

      assert {:ok, %{"a" => %{status: :killed, loss: :killed, outcome: nil}}} =
               Runner.status(runner)

      assert {_join, %{decision: :failed}} = decide(runner)
    end
  end

  test "an early timer rearms and eventually kills a task after clock advancement" do
    sup = start_supervised!({Task.Supervisor, name: sup_name()})
    clock = start_supervised!({Agent, fn -> 1_000 end})
    parent = self()
    join = new_join(["slow"], now: fn -> Agent.get(clock, & &1) end, deadline_unix_ms: 1_500)

    runner =
      start_supervised!(
        {Runner,
         join: join,
         branches: [
           {"slow",
            fn _ ->
              Process.flag(:trap_exit, true)
              send(parent, {:task, self()})

              receive do
                :finish -> :invalid
              end
            end}
         ],
         task_supervisor: sup}
      )

    assert_receive {:task, task}, 1_000
    monitor = Process.monitor(task)
    first_timer = :sys.get_state(runner).timer
    send(runner, :aggregation_deadline)
    state = :sys.get_state(runner)
    assert state.timer != first_timer
    assert is_integer(Process.read_timer(state.timer))
    assert Process.read_timer(first_timer) == false
    assert Process.alive?(task)
    assert {:ok, %{"slow" => %{status: :pending}}} = Runner.status(runner)

    Agent.update(clock, fn _ -> 1_500 end)
    assert_receive {:DOWN, ^monitor, :process, ^task, :killed}, 2_000
    assert Process.alive?(sup)
    assert Task.Supervisor.children(sup) == []

    assert {:ok, %{"slow" => %{status: :timed_out, loss: :timed_out, decided_unix_ms: 1_500}}} =
             Runner.status(runner)

    assert {_join, %{decision: :failed}} = Runner.decision(runner, 1_500)
  end

  test "invalid or raising deadline clocks retry without losing the timer or fabricating losses" do
    sup = start_supervised!({Task.Supervisor, name: sup_name()})
    clock = start_supervised!({Agent, fn -> 1_000 end})
    parent = self()

    now = fn ->
      case Agent.get(clock, & &1) do
        :raise -> raise "fake-clock-secret"
        value -> value
      end
    end

    runner =
      start_supervised!(
        {Runner,
         join: new_join(["slow"], now: now, deadline_unix_ms: 1_100),
         branches: [
           {"slow",
            fn _ ->
              send(parent, {:task, self()})

              receive do
                :finish -> :invalid
              end
            end}
         ],
         task_supervisor: sup}
      )

    assert_receive {:task, task}, 1_000
    monitor = Process.monitor(task)

    logs =
      capture_log(fn ->
        for invalid <- [:not_a_time, -1, :raise] do
          Agent.update(clock, fn _ -> invalid end)
          send(runner, :aggregation_deadline)
          assert is_reference(:sys.get_state(runner).timer)
          assert Process.alive?(task)
          assert {:ok, %{"slow" => %{status: :pending}}} = Runner.status(runner)
        end

        Agent.update(clock, fn _ -> 1_100 end)
        assert_receive {:DOWN, ^monitor, :process, ^task, :killed}, 1_000
      end)

    refute logs =~ "fake-clock-secret"
    assert {:ok, %{"slow" => %{status: :timed_out, loss: :timed_out}}} = Runner.status(runner)
  end

  test "expiry records all losses using the clock reading that established the deadline" do
    sup = start_supervised!({Task.Supervisor, name: sup_name()})
    clock = start_supervised!({Agent, fn -> :before end})

    now = fn ->
      Agent.get_and_update(clock, fn
        :before -> {1_000, :before}
        :deadline -> {1_100, :invalid}
        :invalid -> {:invalid, :invalid}
      end)
    end

    runner =
      start_supervised!(
        {Runner,
         join: new_join(["a", "b"], now: now, deadline_unix_ms: 1_100),
         branches: Enum.map(["a", "b"], &{&1, fn _ -> Process.sleep(:infinity) end}),
         task_supervisor: sup}
      )

    Agent.update(clock, fn _ -> :deadline end)
    send(runner, :aggregation_deadline)
    await_settled(runner)
    assert {:ok, records} = Runner.status(runner)

    assert Enum.all?(records, fn {_, r} -> r.status == :timed_out and r.decided_unix_ms == 1_100 end)

    assert %{running: 0} = Runner.snapshot(runner)
    assert Task.Supervisor.children(sup) == []
  end

  for stop <- [:normal, :supervisor_shutdown] do
    @tag stop: stop
    test "#{stop} cleans active tasks while their injected supervisor remains alive", ctx do
      sup = start_supervised!({Task.Supervisor, name: sup_name()})
      parent = self()

      runner =
        start_supervised!(
          {Runner,
           join: new_join(["slow"], deadline_unix_ms: System.os_time(:millisecond) + 30_000),
           branches: [
             {"slow",
              fn _ ->
                Process.flag(:trap_exit, true)
                send(parent, {:task, self()})

                receive do
                  :finish -> :invalid
                end
              end}
           ],
           task_supervisor: sup},
          restart: :temporary
        )

      assert_receive {:task, task}, 1_000
      monitor = Process.monitor(task)

      case ctx.stop do
        :normal -> GenServer.stop(runner, :normal)
        :supervisor_shutdown -> stop_supervised!(Runner)
      end

      assert_receive {:DOWN, ^monitor, :process, ^task, :killed}, 1_000
      refute Process.alive?(runner)
      assert Process.alive?(sup)
      assert Task.Supervisor.children(sup) == []
      refute_receive {:task, _}, 120
    end
  end

  test "refuses duplicate, undeclared, malformed or empty run declarations" do
    sup = start_supervised!({Task.Supervisor, name: sup_name()})
    join = new_join(["a", "b"])
    fun = fn _id -> ok_result("a") end

    assert {:error, :invalid_options} =
             GenServer.start(Runner,
               join: join,
               branches: [{"a", fun}, {"a", fun}],
               task_supervisor: sup
             )

    assert {:error, :invalid_options} =
             GenServer.start(Runner,
               join: join,
               branches: [{"zzz", fun}],
               task_supervisor: sup
             )

    assert {:error, :invalid_options} =
             GenServer.start(Runner, join: join, branches: [], task_supervisor: sup)

    assert {:error, :invalid_options} =
             GenServer.start(Runner,
               join: join,
               branches: [{123, fun}],
               task_supervisor: sup
             )

    assert {:error, :invalid_options} =
             GenServer.start(Runner,
               join: join,
               branches: [{"a", :not_a_function}],
               task_supervisor: sup
             )

    assert {:error, :invalid_options} =
             GenServer.start(Runner, join: join, branches: [{"a", fun}])

    assert {:error, :invalid_options} =
             GenServer.start(Runner,
               join: %{bogus: true},
               branches: [{"a", fun}],
               task_supervisor: sup
             )
  end

  test "refuses a value-rooted branch key it cannot synthesize" do
    sup = start_supervised!({Task.Supervisor, name: sup_name()})

    join =
      new_join(["a"], branch_key: {:field, ["value", "route", "id"]})

    assert {:error, :invalid_options} =
             GenServer.start(Runner,
               join: join,
               branches: [{"a", fn _id -> ok_result("a") end}],
               task_supervisor: sup
             )
  end

  test "failure capacity includes a valid Envelope carrier before dispatch" do
    sup = start_supervised!({Task.Supervisor, name: sup_name()})
    parent = self()

    for id <- ["", <<255>>] do
      assert {:error, :invalid_options} =
               GenServer.start(Runner,
                 join: new_join([id]),
                 branches: [{id, fn _ -> send(parent, :unexpected_launch) end}],
                 task_supervisor: sup
               )

      assert Task.Supervisor.children(sup) == []
    end

    refute_receive :unexpected_launch
  end

  test "join/1 exposes the live plain-map state" do
    sup = start_supervised!({Task.Supervisor, name: sup_name()})
    join = new_join(["a"])

    runner =
      start_supervised!(
        {Runner, join: join, branches: [{"a", fn id -> ok_result(id) end}], task_supervisor: sup}
      )

    await_settled(runner)
    {_join, %{decision: :all}} = decide(runner)
    assert {:ok, live} = Runner.join(runner)
    assert Aggregation.valid_state?(live)
    assert live.closed
  end
end
