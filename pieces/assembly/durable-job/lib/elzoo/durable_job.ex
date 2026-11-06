# SPDX-License-Identifier: Apache-2.0
defmodule Elzoo.DurableJob do
  @moduledoc """
  `assembly/durable-job`: the tally job flow over the ELZ-009 Store and Oban
  2.24.2. See docs/work/ELZ-010.md for the Contract, result tables and limits.

  `start_link/1` starts, for one queue, a Task.Supervisor, the Submitter and the
  Relay, and registers the worker runner for the queue on this node. Entry
  points (`submit/5`, `cancel/3`, `status/2`) refuse with
  `{:error, :caller_transaction}` before any I/O when the configured Repo is in
  a transaction in the calling process; their Store writes run in
  ELZ-010-owned processes.

  The handler must be pure and deterministic (assumption, not enforced); no
  external Effect is dispatched by this Assembly.
  """
  use Supervisor
  alias Elzoo.DurableJob.{Run, Submitter}
  alias Elzoo.DurableLog, as: Log
  alias Elzoo.DurableLog.Writer
  alias Elzoo.{JobRun, Jobs}

  @rounds 3

  # -- lifecycle --------------------------------------------------------------

  @doc """
  Options: `:queue` (string, `[a-z][a-z0-9_]*`, ≤ 32 bytes), `:store`
  (ELZ-009 Store configured with `Elzoo.DurableJob.Run.store_fold/0` and
  `Run.limits/0`), `:repo` (the Ecto Repo Oban uses), `:oban` (Oban instance
  name), `:handler` (`(input -> {:ok, integer} | {:error, :transient | :permanent})`,
  default `Elzoo.DurableJob.Tally.run/1`), `:now_ms` (default
  `System.os_time(:millisecond)`), `:provider_slack` (default 2),
  `:snooze_s` (default 1), `:relay_limit` (default 100), `:relay_interval_ms`
  (default 1000 or `:manual`), `:test_hook` (test-only barrier
  `fn :before_begin, job -> :ok end`). All fixed at start; no hot
  reconfiguration.
  """
  def start_link(opts) do
    queue = Keyword.fetch!(opts, :queue)
    if not Run.queue?(queue), do: raise(ArgumentError, "invalid queue")
    Supervisor.start_link(__MODULE__, opts, name: name(queue, :supervisor))
  end

  def child_spec(opts),
    do: %{
      id: {__MODULE__, Keyword.fetch!(opts, :queue)},
      start: {__MODULE__, :start_link, [opts]},
      type: :supervisor
    }

  @impl true
  def init(opts) do
    queue = Keyword.fetch!(opts, :queue)

    config = %{
      queue: queue,
      store: Keyword.fetch!(opts, :store),
      repo: Keyword.fetch!(opts, :repo),
      oban: Keyword.fetch!(opts, :oban),
      handler: Keyword.get(opts, :handler, &Elzoo.DurableJob.Tally.run/1),
      now_ms: Keyword.get(opts, :now_ms, fn -> System.os_time(:millisecond) end),
      slack: Keyword.get(opts, :provider_slack, 2),
      snooze: Keyword.get(opts, :snooze_s, 1),
      test_hook: Keyword.get(opts, :test_hook, fn _event, _data -> :ok end),
      tasks: name(queue, :tasks),
      submitter: name(queue, :submitter),
      relay: name(queue, :relay)
    }

    :persistent_term.put({__MODULE__, queue}, config)

    :ok =
      Jobs.register(queue, %{
        perform: fn job -> perform(config, job) end,
        backoff: &backoff/1
      })

    children = [
      {Task.Supervisor, name: config.tasks},
      {Submitter, name: config.submitter, store: config.store, queue: queue},
      {Elzoo.Jobs.Relay,
       name: config.relay,
       store: config.store,
       stream: Run.submission_stream(queue),
       limit: Keyword.get(opts, :relay_limit, 100),
       interval_ms: Keyword.get(opts, :relay_interval_ms, 1_000),
       handle: fn item -> relay(config, item) end}
    ]

    Supervisor.init(children, strategy: :one_for_all)
  end

  @doc "Relay process of `queue` (for `Elzoo.Jobs.Relay.run_once/1`)."
  def relay_process(queue), do: name(queue, :relay)

  defp name(queue, role), do: String.to_atom("Elixir.Elzoo.DurableJob.#{role}.#{queue}")
  defp config(queue), do: :persistent_term.get({__MODULE__, queue}, nil)

  # -- entry points -------------------------------------------------------------

  @doc "Submit a Work Item. Results: see the Contract's result table."
  def submit(queue, job_key, input, policy, deadline_ms) do
    guarded(queue, fn cfg ->
      with {:ok, request} <- Run.request(job_key, input, policy, deadline_ms, cfg.now_ms.()) do
        case Submitter.submit(cfg.submitter, request) do
          {:duplicate, _} -> {:duplicate, status_of(cfg, job_key)}
          other -> other
        end
      end
    end)
  end

  @doc "Cancel a Work Item's Run (also before the relay ran)."
  def cancel(queue, job_key, requested_by)
      when is_binary(requested_by) and byte_size(requested_by) <= 200 do
    guarded(queue, fn cfg ->
      owned(cfg, fn ->
        with_writer(cfg, job_key, &cancel_loop(cfg, job_key, requested_by, &1, @rounds))
      end)
    end)
  end

  @doc "Read-only status of a Work Item's Run."
  def status(queue, job_key), do: guarded(queue, fn cfg -> status_of(cfg, job_key) end)

  defp guarded(queue, fun) do
    case config(queue) do
      nil -> {:error, :not_started}
      cfg -> if cfg.repo.in_transaction?(), do: {:error, :caller_transaction}, else: fun.(cfg)
    end
  end

  defp owned(cfg, fun) do
    task =
      Task.Supervisor.async_nolink(cfg.tasks, fn ->
        Process.flag(:trap_exit, true)
        fun.()
      end)

    case Task.yield(task, 15_000) || Task.shutdown(task) do
      {:ok, result} -> result
      _ -> {:error, :unavailable}
    end
  end

  defp with_writer(cfg, job_key, fun) do
    case Writer.start_link(
           store: cfg.store,
           stream: Run.run_stream(cfg.queue, job_key),
           fold: Run.run_fold(),
           limits: Run.limits()
         ) do
      {:ok, writer} ->
        try do
          fun.(writer)
        after
          if Process.alive?(writer), do: GenServer.stop(writer)
        end

      {:error, {:replay_damaged, _}} ->
        {:error, :damaged}

      {:error, _} ->
        {:error, :unavailable}
    end
  end

  defp model(writer), do: Writer.snapshot(writer).model

  defp append(writer, kind, data),
    do: Writer.append(writer, [{kind, Run.version(), Run.encode(data)}])

  defp cancel_loop(_cfg, _key, _by, _writer, 0), do: {:error, :contended}

  defp cancel_loop(cfg, key, by, writer, rounds) do
    m = model(writer)

    if m.phase == :none do
      case Submitter.known?(cfg.submitter, key) do
        {:ok, true} -> write_cancel(cfg, key, by, writer, m, rounds)
        {:ok, false} -> {:error, :not_found}
        {:error, reason} -> {:error, reason}
      end
    else
      {:ok, {_, action}} = JobRun.step(m.phase, :cancel, false, :retry)

      case action do
        :record_cancel -> write_cancel(cfg, key, by, writer, m, rounds)
        :no_change -> {:error, {:terminal, m.phase}}
      end
    end
  end

  defp write_cancel(cfg, key, by, writer, m, rounds) do
    case append(writer, "cancelled", %{"attempt" => m.last_attempt, "requested_by" => by}) do
      {:committed, _} ->
        _ = Jobs.cancel(cfg.oban, cfg.queue, key)
        {:ok, :cancelled}

      {:conflict, _} ->
        cancel_loop(cfg, key, by, writer, rounds - 1)

      {:indeterminate, info} ->
        {:indeterminate, info}

      {:rejected, reason} ->
        {:error, {:rejected, reason}}
    end
  end

  defp status_of(cfg, key) do
    stream = Run.run_stream(cfg.queue, key)

    with {:ok, rows, head} <- Log.read(cfg.store, stream, 1, 1_000) do
      replay = Log.replay(rows, head, Map.put(Run.run_fold(), :limits, Run.limits()))
      {_, damaged, _} = replay.cursor
      m = replay.model

      cond do
        damaged ->
          {:error, :damaged}

        m.phase == :none ->
          case Submitter.known?(cfg.submitter, key) do
            {:ok, true} ->
              {:ok,
               %{phase: :submitted, attempts_made: 0, deadline_ms: nil, result: nil, stalled: false}}

            {:ok, false} ->
              {:error, :not_found}

            {:error, reason} ->
              {:error, reason}
          end

        true ->
          {:ok,
           %{
             phase: m.phase,
             attempts_made: m.attempts_made,
             deadline_ms: m.request["deadline_ms"],
             result: m.result,
             stalled: stalled?(cfg, key, m)
           }}
      end
    else
      {:error, _} -> {:error, :unavailable}
    end
  end

  # A non-terminal Run whose provider job is terminal, or absent after an
  # attempt was bound, cannot progress: reported, never repaired (limit).
  defp stalled?(cfg, key, m) do
    if Run.terminal?(m.phase) do
      false
    else
      case Jobs.state(cfg.oban, cfg.queue, key) do
        {:ok, {_, state}} -> state in ~w(discarded cancelled completed)
        {:ok, :absent} -> m.phase in [:active, :waiting]
        {:error, _} -> false
      end
    end
  end

  # -- relay ----------------------------------------------------------------------

  @doc false
  def relay(cfg, item) do
    request = Run.decode!(item.payload)
    key = request["job_key"]
    if not Run.job_key?(key), do: raise(ArgumentError, "bad key")
    with_writer(cfg, key, &relay_loop(cfg, request, item, &1, @rounds)) |> relay_result()
  rescue
    _ -> {:skip, :malformed}
  end

  defp relay_result({:error, reason}), do: {:skip, reason}
  defp relay_result(other), do: other

  defp relay_loop(_cfg, _request, _item, _writer, 0), do: {:skip, :contended}

  defp relay_loop(cfg, request, item, writer, rounds) do
    m = model(writer)

    cond do
      m.phase == :none ->
        case append(writer, "accepted", %{
               "request" => request,
               "submission" => item.idempotency_key
             }) do
          {:committed, _} -> enqueue(cfg, request)
          {:conflict, _} -> relay_loop(cfg, request, item, writer, rounds - 1)
          {:indeterminate, _} -> {:skip, :indeterminate}
          {:rejected, reason} -> {:skip, {:rejected, reason}}
        end

      m.first == "cancelled" ->
        :done

      m.submission != item.idempotency_key ->
        {:skip, :foreign_run}

      Run.terminal?(m.phase) ->
        :done

      true ->
        enqueue(cfg, m.request)
    end
  end

  defp enqueue(cfg, request) do
    changeset =
      Jobs.changeset(cfg.queue, request["job_key"], request["max_attempts"] + cfg.slack, %{
        "base_backoff_ms" => request["base_backoff_ms"],
        "max_backoff_ms" => request["max_backoff_ms"]
      })

    case Jobs.enqueue(cfg.oban, changeset) do
      {:ok, _id} -> :done
      {:retry, reason} -> {:skip, reason}
      {:error, reason} -> {:skip, {:insert, reason}}
    end
  end

  # -- worker ---------------------------------------------------------------------

  @doc false
  def backoff(%Oban.Job{attempt: attempt, args: args}) do
    with {:ok, policy} <-
           Elzoo.RetryTimeout.policy(
             base_backoff_ms: Map.get(args, "base_backoff_ms", 1_000),
             max_backoff_ms: Map.get(args, "max_backoff_ms", 60_000)
           ),
         {:ok, ms} <- Elzoo.RetryTimeout.backoff(policy, max(attempt, 1)) do
      div(ms + 999, 1000)
    else
      _ -> 1
    end
  end

  @doc false
  def perform(cfg, %Oban.Job{args: %{"job_key" => key}} = job) do
    snooze = {:snooze, cfg.snooze}

    case with_writer(cfg, key, &start_loop(cfg, job, &1, @rounds)) do
      {:error, :damaged} -> {:cancel, :damaged}
      {:error, _} -> snooze
      result -> result
    end
  end

  # W2: classify the start against the freshly folded Run; after this
  # execution's own attempt_started commits, no start is evaluated again.
  defp start_loop(cfg, _job, _writer, 0), do: {:snooze, cfg.snooze}

  defp start_loop(cfg, job, writer, rounds) do
    m = model(writer)

    cond do
      m.phase == :none ->
        {:snooze, cfg.snooze}

      Run.terminal?(m.phase) ->
        {:cancel, m.phase}

      true ->
        expired = cfg.now_ms.() >= m.request["deadline_ms"]
        {:ok, input} = JobRun.start_input(m.bound_job, job.id, m.last_oban_attempt, job.attempt)
        {:ok, retry} = JobRun.retry_decision(Run.policy(m.request), m.attempts_made, :retryable)
        {:ok, {_, action}} = JobRun.step(m.phase, input, expired, retry)
        start_action(cfg, job, writer, rounds, m, action)
    end
  end

  defp start_action(cfg, job, writer, rounds, m, :begin_attempt) do
    n = m.attempts_made + 1
    cfg.test_hook.(:before_begin, job)

    data = %{
      "attempt" => n,
      "oban_job_id" => job.id,
      "oban_attempt" => job.attempt,
      "started_ms" => cfg.now_ms.()
    }

    case append(writer, "attempt_started", data) do
      {:committed, _} -> attempt(cfg, writer, m.request, n)
      {:conflict, _} -> start_loop(cfg, job, writer, rounds - 1)
      _ -> {:snooze, cfg.snooze}
    end
  end

  defp start_action(cfg, job, writer, rounds, m, action)
       when action in [:record_expired, :record_exhausted] do
    kind = if action == :record_expired, do: "expired", else: "exhausted"

    case append(writer, kind, %{"attempt" => m.last_attempt, "reason" => kind}) do
      {:committed, _} -> {:cancel, String.to_existing_atom(kind)}
      {:conflict, _} -> start_loop(cfg, job, writer, rounds - 1)
      _ -> {:snooze, cfg.snooze}
    end
  end

  defp start_action(_cfg, _job, _writer, _rounds, _m, :yield_duplicate),
    do: {:cancel, :duplicate_job}

  defp start_action(cfg, _job, _writer, _rounds, _m, _no_begin), do: {:snooze, cfg.snooze}

  defp attempt(cfg, writer, request, n) do
    {completed?, outcome} =
      try do
        case cfg.handler.(request["input"]) do
          {:ok, result} when is_integer(result) -> {true, result}
          {:error, :permanent} -> {false, :permanent}
          _ -> {false, :retryable}
        end
      rescue
        _ -> {false, :retryable}
      catch
        _, _ -> {false, :retryable}
      end

    result_loop(cfg, writer, request, n, completed?, outcome, @rounds)
  end

  # W3: results are re-classified against the refolded Run after a conflict;
  # stale results snooze (the stale execution's ack is a no-op under Oban's
  # attempted_at guard).
  defp result_loop(cfg, _writer, _request, _n, _completed?, _outcome, 0), do: {:snooze, cfg.snooze}

  defp result_loop(cfg, writer, request, n, completed?, outcome, rounds) do
    m = model(writer)
    expired = cfg.now_ms.() >= request["deadline_ms"]
    {:ok, input} = JobRun.result_input(completed?, n, m.last_attempt)
    class = if completed?, do: :retryable, else: outcome
    {:ok, retry} = JobRun.retry_decision(Run.policy(request), max(m.attempts_made, 1), class)
    {:ok, {next, action}} = JobRun.step(m.phase, input, expired, retry)

    {kind, data, reply} =
      case action do
        :record_success ->
          {"succeeded", %{"attempt" => n, "result" => outcome, "finished_ms" => cfg.now_ms.()}, :ok}

        :schedule_retry ->
          {"attempt_failed", %{"attempt" => n, "class" => "transient"}, {:error, :retry}}

        :record_exhausted ->
          {"exhausted", %{"attempt" => n, "reason" => "exhausted"}, {:cancel, :exhausted}}

        :record_failure ->
          {"failed", %{"attempt" => n, "reason" => "permanent"}, {:cancel, :failed}}

        :record_expired ->
          {"expired", %{"attempt" => n, "reason" => "expired"}, {:cancel, :expired}}

        :no_change ->
          {nil, nil, if(Run.terminal?(next), do: {:cancel, next}, else: {:snooze, cfg.snooze})}
      end

    if kind == nil do
      reply
    else
      case append(writer, kind, data) do
        {:committed, _} -> reply
        {:conflict, _} -> result_loop(cfg, writer, request, n, completed?, outcome, rounds - 1)
        _ -> {:snooze, cfg.snooze}
      end
    end
  end
end
