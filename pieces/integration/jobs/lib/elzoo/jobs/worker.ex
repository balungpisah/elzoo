# SPDX-License-Identifier: Apache-2.0
defmodule Elzoo.Jobs.Worker do
  @moduledoc """
  Oban worker that dispatches to the runner registered for the job's queue.
  `perform/1` traps exits for its duration so a linked helper (for example an
  ELZ-009 Writer that stops on an indeterminate write or at init) cannot kill
  the execution, and maps an exit escaping the runner to `{:snooze, 5}`; it
  restores the previous flag and drains stray exit messages.
  Missing runner or unknown args version are explicit results.
  """
  use Oban.Worker, queue: :elzoo_jobs

  @snooze 5

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"v" => 1, "queue" => queue, "job_key" => key}} = job)
      when is_binary(queue) and is_binary(key) do
    case Elzoo.Jobs.runner(queue) do
      nil -> {:snooze, @snooze}
      runner -> trapping(fn -> runner.perform.(job) end)
    end
  end

  def perform(%Oban.Job{}), do: {:cancel, :unsupported_version}

  @impl Oban.Worker
  def backoff(%Oban.Job{args: %{"queue" => queue}} = job) do
    case Elzoo.Jobs.runner(queue) do
      nil -> @snooze
      runner -> runner.backoff.(job)
    end
  end

  def backoff(_job), do: @snooze

  @doc false
  def trapping(fun) do
    previous = Process.flag(:trap_exit, true)

    try do
      fun.()
    catch
      # Any exit reaching here (for example a GenServer call timeout) is a
      # non-attempt outcome: snooze, which does not consume an Oban attempt.
      :exit, _ -> {:snooze, @snooze}
    after
      Process.flag(:trap_exit, previous)
      drain()
    end
  end

  defp drain do
    receive do
      {:EXIT, _, _} -> drain()
    after
      0 -> :ok
    end
  end
end
