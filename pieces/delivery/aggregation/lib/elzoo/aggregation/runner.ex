# SPDX-License-Identifier: Apache-2.0
defmodule Elzoo.Aggregation.Runner do
  @moduledoc """
  Volatile fan-out runner for a declared join, for callers without durable
  branches.

  `start_link/1` takes a join state from `Elzoo.Aggregation.new/2`, a list of
  declared `{branch_id, fun}` pairs and an injected `Task.Supervisor`. Each fun
  is a 1-arity function of its branch id that must return a `core/envelope`
  DeliveryResult map; every pair runs once under the supervisor with
  `:brutal_kill` shutdown and no retries. Branch ids must be binaries present
  in the join declaration, duplicates are refused, and the join's `branch_key`
  must carry identity in `correlation_id` or `attempt_id` so runner-synthesized
  failure results can be attributed — a `value`-rooted key is refused because
  a failed branch cannot mint a value payload.

  Runner outcomes feed the same join policy: a returned result goes through
  `Elzoo.Aggregation.accept/2`; a raising or exiting task becomes a synthetic
  `failed`/`dispatched`/`unclassified` result; a result the join refuses
  (`:invalid_result`) becomes the same synthetic failure, while
  `:invalid_branch_key`/`:too_large` become `mark_lost(:unavailable)` — the
  branch was dispatched but its evidence could not be joined. At the join
  deadline the runner records `mark_lost(:timed_out)` for every branch still
  unsettled and kills the surviving tasks; their late messages are recorded by
  the join, never merged.

  This runner is volatile: it keeps no queue, no durable state and starts no
  process of its own. Durable branches remain owned by `workflow/run`.
  `snapshot/1` is inspection, not telemetry or durable accounting.
  """
  use GenServer

  alias Elzoo.Aggregation

  @killed_reasons [:killed, :kill, :shutdown]

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

  @doc "Run `Aggregation.decision/2` against the runner's live join state."
  def decision(runner, now), do: GenServer.call(runner, {:decision, now})

  @doc "Payload-free branch view, same shape as `Aggregation.status/1`."
  def status(runner), do: GenServer.call(runner, :status)

  @doc "The runner's current plain-map join state for caller persistence."
  def join(runner), do: GenServer.call(runner, :join)

  @doc "Volatile counters: launched, running, accepted, refused, closed, outcome."
  def snapshot(runner), do: GenServer.call(runner, :snapshot)

  @impl true
  def init(opts) do
    with true <- proper_list?(opts) and Keyword.keyword?(opts),
         join when is_map(join) <- Keyword.get(opts, :join),
         true <- Aggregation.valid_state?(join),
         {:ok, branches} <- validate_branches(Keyword.get(opts, :branches), join),
         :ok <- carrier_supported?(join),
         supervisor when not is_nil(supervisor) <- Keyword.get(opts, :task_supervisor) do
      state = %{
        join: join,
        supervisor: supervisor,
        branches: %{},
        tasks: %{},
        launched: 0,
        accepted: 0,
        refused: 0
      }

      {:ok, arm_deadline(launch_all(state, branches))}
    else
      _ -> {:stop, :invalid_options}
    end
  end

  @impl true
  def handle_call(:join, _from, state), do: {:reply, {:ok, state.join}, state}

  def handle_call(:status, _from, state) do
    {:reply, Aggregation.status(state.join), state}
  end

  def handle_call({:decision, now}, _from, state) do
    case Aggregation.decision(state.join, now) do
      {%{} = join, %{decision: _} = outcome} ->
        {:reply, {join, outcome}, %{state | join: join}}

      {:error, _} = error ->
        {:reply, error, state}
    end
  end

  def handle_call(:snapshot, _from, state) do
    {:reply,
     %{
       launched: state.launched,
       running: map_size(state.tasks),
       accepted: state.accepted,
       refused: state.refused,
       closed: state.join.closed,
       outcome: state.join.outcome
     }, state}
  end

  @impl true
  def handle_info({task_ref, response}, state) when is_reference(task_ref) do
    case Map.fetch(state.tasks, task_ref) do
      :error ->
        {:noreply, state}

      {:ok, branch_id} ->
        Process.demonitor(task_ref, [:flush])
        state = clear_task(state, task_ref, branch_id)
        {:noreply, feed_result(state, branch_id, response)}
    end
  end

  def handle_info({:DOWN, task_ref, :process, _pid, reason}, state) do
    case Map.fetch(state.tasks, task_ref) do
      :error ->
        {:noreply, state}

      {:ok, branch_id} ->
        state = clear_task(state, task_ref, branch_id)

        state =
          if reason in @killed_reasons do
            record_loss(state, branch_id, :killed)
          else
            feed_synthetic(state, branch_id, "failed", "dispatched", "unclassified")
          end

        {:noreply, state}
    end
  end

  def handle_info(:aggregation_deadline, state) do
    now = state.join.now.()

    if state.join.deadline_unix_ms != :unbounded and is_integer(now) and
         now >= state.join.deadline_unix_ms do
      {:noreply, expire(state)}
    else
      {:noreply, state}
    end
  end

  def handle_info(_, state), do: {:noreply, state}

  defp launch_all(state, branches) do
    Enum.reduce(branches, state, fn {branch_id, fun}, acc ->
      case start_task(acc.supervisor, fun, branch_id) do
        {:ok, task} ->
          %{
            acc
            | branches: Map.put(acc.branches, branch_id, task),
              tasks: Map.put(acc.tasks, task.ref, branch_id),
              launched: acc.launched + 1
          }

        :error ->
          feed_synthetic(acc, branch_id, "rejected", "not_dispatched", "unavailable")
      end
    end)
  end

  defp start_task(supervisor, fun, branch_id) do
    try do
      {:ok,
       Task.Supervisor.async_nolink(
         supervisor,
         fn -> fun.(branch_id) end,
         shutdown: :brutal_kill
       )}
    catch
      _, _ -> :error
    end
  end

  defp feed_result(state, branch_id, response) do
    case Aggregation.accept(state.join, response) do
      {:ok, join} ->
        %{state | join: join, accepted: state.accepted + 1}

      {:error, reason} ->
        state = %{state | refused: state.refused + 1}

        case reason do
          :invalid_result ->
            feed_synthetic(state, branch_id, "failed", "dispatched", "unclassified")

          :invalid_branch_key ->
            record_loss(state, branch_id, :unavailable)

          :too_large ->
            record_loss(state, branch_id, :unavailable)

          _ ->
            state
        end
    end
  end

  defp feed_synthetic(state, branch_id, outcome, dispatch, error_class) do
    result = synthetic_result(state.join, branch_id, outcome, dispatch, error_class)

    case Aggregation.accept(state.join, result) do
      {:ok, join} -> %{state | join: join, accepted: state.accepted + 1}
      {:error, _} -> %{state | refused: state.refused + 1}
    end
  end

  defp record_loss(state, branch_id, kind) do
    case Aggregation.mark_lost(state.join, branch_id, kind) do
      {:ok, join} -> %{state | join: join, accepted: state.accepted + 1}
      {:error, _} -> %{state | refused: state.refused + 1}
    end
  end

  defp synthetic_result(join, branch_id, outcome, dispatch, error_class) do
    result = %{
      "version" => 1,
      "message_id" => "aggregation-runner/" <> branch_id,
      "correlation_id" => branch_id,
      "outcome" => outcome,
      "dispatch" => dispatch,
      "error_class" => error_class
    }

    case join.branch_key do
      {:field, ["attempt_id"]} -> Map.put(result, "attempt_id", branch_id)
      _ -> result
    end
  end

  defp expire(state) do
    state =
      Enum.reduce(state.join.branches, state, fn {branch_id, record}, acc ->
        if record.status in [:pending, :late] do
          record_loss(acc, branch_id, :timed_out)
        else
          acc
        end
      end)

    branches =
      Map.new(state.branches, fn {id, task} ->
        if task, do: remove_task(state.supervisor, task.pid)
        {id, nil}
      end)

    %{state | branches: branches, tasks: %{}}
  end

  defp clear_task(state, task_ref, branch_id) do
    Process.demonitor(task_ref, [:flush])

    tasks = Map.delete(state.tasks, task_ref)
    branches = Map.put(state.branches, branch_id, nil)

    %{state | tasks: tasks, branches: branches}
  end

  # Tasks run with :brutal_kill, so a healthy supervisor removes the child with
  # an untrappable kill. A dead or restarted supervisor no longer owns the task
  # (which may survive the supervisor's exit by trapping exits), so the runner
  # kills it directly.
  defp remove_task(supervisor, pid) do
    case Task.Supervisor.terminate_child(supervisor, pid) do
      :ok -> :ok
      {:error, :not_found} -> Process.exit(pid, :kill)
    end
  catch
    :exit, _ -> Process.exit(pid, :kill)
  end

  defp arm_deadline(state) do
    case state.join.deadline_unix_ms do
      :unbounded ->
        state

      deadline ->
        remaining =
          case state.join.now.() do
            now when is_integer(now) -> max(deadline - now, 0)
            _ -> 0
          end

        Process.send_after(self(), :aggregation_deadline, remaining)
        state
    end
  end

  defp validate_branches(branches, join) do
    with true <- proper_list?(branches) and branches != [],
         true <- Enum.all?(branches, &valid_pair?/1),
         :ok <- unique_ids(branches),
         :ok <- declared_subset(branches, join) do
      {:ok, branches}
    else
      _ -> {:error, :invalid_branches}
    end
  end

  defp valid_pair?({id, fun}) when is_binary(id) and is_function(fun, 1), do: true
  defp valid_pair?(_), do: false

  defp unique_ids(branches) do
    ids = Enum.map(branches, &elem(&1, 0))

    if Enum.uniq(ids) == ids, do: :ok, else: {:error, :duplicate_branch}
  end

  defp declared_subset(branches, join) do
    declared = MapSet.new(join.declared)

    if Enum.all?(branches, fn {id, _fun} -> MapSet.member?(declared, id) end),
      do: :ok,
      else: {:error, :undeclared_branch}
  end

  defp carrier_supported?(%{branch_key: {:field, [root]}})
       when root in ["correlation_id", "attempt_id"],
       do: :ok

  defp carrier_supported?(_), do: {:error, :unsupported_branch_key}

  defp proper_list?([]), do: true
  defp proper_list?([_ | tail]), do: proper_list?(tail)
  defp proper_list?(_), do: false
end
