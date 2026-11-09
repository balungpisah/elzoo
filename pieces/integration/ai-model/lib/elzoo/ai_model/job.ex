# SPDX-License-Identifier: Apache-2.0
defmodule Elzoo.AiModel.Job do
  @moduledoc """
  Job reference and job state for job-shaped model calls (batch, image, video).

  - `job_ref`: `%{provider: text, provider_job_id: text, submitted_at: unix_ms}`.
  - `job_state`: `:pending | :running | :ending | {:ended, counts} | :expired |
    :cancelled | :failed`, where `counts` is
    `%{succeeded: n, errored: n, cancelled: n, expired: n}` of non-negative integers.

  Data and validators only; no submission, polling or lifecycle here.
  """
  import Elzoo.AiModel, only: [text?: 2, exact_keys?: 2]

  @count_keys [:succeeded, :errored, :cancelled, :expired]

  def validate_ref(ref) do
    if exact_keys?(ref, [:provider, :provider_job_id, :submitted_at]) and text?(ref.provider, 64) and
         text?(ref.provider_job_id, 256) and is_integer(ref.submitted_at) and ref.submitted_at >= 0,
       do: {:ok, ref},
       else: {:error, :job_ref}
  end

  def validate_state(state) when state in [:pending, :running, :ending, :expired, :cancelled, :failed],
    do: {:ok, state}

  def validate_state({:ended, counts} = state) do
    if exact_keys?(counts, @count_keys) and Enum.all?(Map.values(counts), &(is_integer(&1) and &1 >= 0)),
      do: {:ok, state},
      else: {:error, :job_state}
  end

  def validate_state(_), do: {:error, :job_state}
end
