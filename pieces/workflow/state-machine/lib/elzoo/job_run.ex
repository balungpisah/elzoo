# SPDX-License-Identifier: Apache-2.0
defmodule Elzoo.JobRun do
  @moduledoc """
  Validating Elixir projection of the Cure job-Run lifecycle decision
  (`:"Cure.Elzoo.JobRun"`). Identity classification and `step/4` are pure; the
  integer comparisons inside `start_input/4` and `result_input/3` are
  test-grounded, the `step/4` table is covered by the selected Cure laws.
  """
  @cure :"Cure.Elzoo.JobRun"

  @phases %{
    requested: :RunRequested,
    active: :RunActive,
    waiting: :RunWaiting,
    succeeded: :RunSucceeded,
    failed: :RunFailed,
    exhausted: :RunExhausted,
    expired: :RunExpired,
    cancelled: :RunCancelled
  }
  @inputs %{
    start: :StartAttempt,
    duplicate_start: :StartDuplicate,
    stale_start: :StartStale,
    current_completed: :CurrentCompleted,
    current_failed: :CurrentFailed,
    stale_completed: :StaleCompleted,
    stale_failed: :StaleFailed,
    cancel: :CancelRequested
  }
  @actions %{
    BeginAttempt: :begin_attempt,
    RecordSuccess: :record_success,
    ScheduleRetry: :schedule_retry,
    RecordFailure: :record_failure,
    RecordExhausted: :record_exhausted,
    RecordExpired: :record_expired,
    RecordCancel: :record_cancel,
    YieldDuplicate: :yield_duplicate,
    YieldStale: :yield_stale,
    NoChange: :no_change
  }
  @retries %{
    retry: :DecideRetry,
    exhausted: :DecideExhausted,
    permanent: :DecidePermanent,
    settle: :DecideSettle,
    unresolved: :DecideUnresolved
  }
  @terminal [:succeeded, :failed, :exhausted, :expired, :cancelled]

  def phases, do: Map.keys(@phases)
  def terminal?(phase), do: phase in @terminal

  @doc "Classify a worker execution's start: `bound_job` and `recorded_oban_attempt` are 0 before the first attempt."
  def start_input(bound_job, job, recorded_oban_attempt, job_attempt) do
    if Enum.all?(
         [bound_job, job, recorded_oban_attempt, job_attempt],
         &(is_integer(&1) and &1 >= 0)
       ),
       do:
         {:ok,
          input(apply(@cure, :start_input, [bound_job, job, recorded_oban_attempt, job_attempt]))},
       else: {:error, :invalid_start}
  end

  @doc "Classify an attempt result against the Run's latest attempt (0 when none started)."
  def result_input(completed?, attempt, last_attempt) do
    if is_boolean(completed?) and is_integer(attempt) and attempt >= 1 and is_integer(last_attempt) and
         last_attempt >= 0,
       do: {:ok, input(apply(@cure, :result_input, [completed?, attempt, last_attempt]))},
       else: {:error, :invalid_result}
  end

  @doc "One lifecycle decision. `retry` is an `Elzoo.RetryTimeout.decide/3` result."
  def step(phase, input, expired?, retry) do
    with {:ok, p} <- fetch(@phases, phase, :invalid_phase),
         {:ok, i} <- fetch(@inputs, input, :invalid_input),
         true <- is_boolean(expired?) || {:error, :invalid_expired},
         {:ok, r} <- fetch(@retries, retry, :invalid_retry) do
      {:RunStep, next, action} = apply(@cure, :step, [p, i, expired?, r])
      {:ok, {phase_name(next), Map.fetch!(@actions, action)}}
    end
  end

  @doc "Retry decision for `class` after `attempts_made` attempts (ELZ-006 policy, unchanged)."
  def retry_decision(_policy, 0, _class), do: {:ok, :retry}

  def retry_decision(policy, attempts_made, class) when class in [:retryable, :permanent],
    do: Elzoo.RetryTimeout.decide(policy, attempts_made, class)

  def retry_decision(_, _, _), do: {:error, :invalid_class}

  defp fetch(map, key, error),
    do: if(Map.has_key?(map, key), do: {:ok, map[key]}, else: {:error, error})

  defp input(tag), do: Enum.find_value(@inputs, fn {k, v} -> if v == tag, do: k end)
  defp phase_name(tag), do: Enum.find_value(@phases, fn {k, v} -> if v == tag, do: k end)
end
