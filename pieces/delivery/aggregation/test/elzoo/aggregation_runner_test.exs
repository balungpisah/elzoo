# SPDX-License-Identifier: Apache-2.0
defmodule Elzoo.AggregationRunnerTest do
  use ExUnit.Case, async: true

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

  test "branches run exactly once — no retries" do
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
