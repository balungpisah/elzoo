# SPDX-License-Identifier: Apache-2.0
defmodule Elzoo.Jobs do
  @moduledoc """
  Oban 2.24.2 translation for `integration/jobs`: a unique job per
  `(queue, job_key)`, a persisted-id rule for unique inserts, and a per-queue
  runner registration used by `Elzoo.Jobs.Worker`.

  Oban owns persistence, claim, retry staging, uniqueness, cancellation, snooze
  and rescue (upstream contracts). This module only translates.
  """
  import Ecto.Query

  @doc "Register the runner for `queue` on this node (a map with `:perform` and `:backoff` funs)."
  def register(queue, %{perform: perform, backoff: backoff} = runner)
      when is_binary(queue) and is_function(perform, 1) and is_function(backoff, 1) do
    :persistent_term.put({__MODULE__, queue}, runner)
    :ok
  end

  def unregister(queue), do: :persistent_term.erase({__MODULE__, queue}) && :ok
  def runner(queue), do: :persistent_term.get({__MODULE__, queue}, nil)

  @doc """
  Build the unique Oban job changeset for a Run. `max_attempts` is the provider
  budget (the Run budget is owned by the caller); `backoff` holds the retry
  policy fields the worker's `backoff/1` needs.
  """
  def changeset(queue, job_key, max_attempts, backoff \\ %{}) do
    Elzoo.Jobs.Worker.new(
      Map.merge(%{"v" => 1, "queue" => queue, "job_key" => job_key}, backoff),
      queue: queue,
      max_attempts: max_attempts,
      unique: [keys: [:queue, :job_key], period: :infinity, states: :all]
    )
  end

  @doc """
  Insert a unique job. Returns `{:ok, id}` only when Oban returned a persisted
  job (new or `conflict?: true` with an id). `conflict?: true` with `id: nil`
  (the unique advisory lock is held by an uncommitted inserter) is
  `{:retry, :unique_lock_held}`: the caller must not treat it as enqueued.
  """
  def enqueue(oban, changeset) do
    case Oban.insert(oban, changeset) do
      {:ok, %Oban.Job{id: id}} when is_integer(id) -> {:ok, id}
      {:ok, %Oban.Job{id: nil}} -> {:retry, :unique_lock_held}
      {:error, reason} -> {:error, reason}
    end
  rescue
    exception -> {:error, {:exception, exception.__struct__}}
  catch
    :exit, _ -> {:error, :exit}
  end

  @doc "Query for the job of `(queue, job_key)` (any state)."
  def query(queue, job_key),
    do:
      Oban.Job
      |> where([j], fragment("? @> ?", j.args, ^%{"queue" => queue, "job_key" => job_key}))

  @doc "Current Oban state of the job, or `:absent`."
  def state(oban, queue, job_key) do
    conf = Oban.config(oban)

    case Oban.Repo.all(conf, query(queue, job_key) |> select([j], {j.id, j.state})) do
      [] -> {:ok, :absent}
      [{id, state} | _] -> {:ok, {id, state}}
    end
  rescue
    _ -> {:error, :unavailable}
  end

  @doc "Oban state of the job with `id`, or `:absent`."
  def state_by_id(oban, id) when is_integer(id) do
    conf = Oban.config(oban)

    case Oban.Repo.all(conf, Oban.Job |> where([j], j.id == ^id) |> select([j], j.state)) do
      [] -> {:ok, :absent}
      [state] -> {:ok, {id, state}}
    end
  rescue
    _ -> {:error, :unavailable}
  end

  @doc "All `{id, state}` rows of the `(queue, job_key)` jobs, ordered by id."
  def states(oban, queue, job_key) do
    conf = Oban.config(oban)

    {:ok,
     Oban.Repo.all(
       conf,
       query(queue, job_key) |> order_by([j], j.id) |> select([j], {j.id, j.state})
     )}
  rescue
    _ -> {:error, :unavailable}
  end

  @doc "Best-effort cancellation of the `(queue, job_key)` job (Oban.cancel_all_jobs/2)."
  def cancel(oban, queue, job_key) do
    Oban.cancel_all_jobs(oban, query(queue, job_key))
  rescue
    _ -> {:error, :unavailable}
  end
end
