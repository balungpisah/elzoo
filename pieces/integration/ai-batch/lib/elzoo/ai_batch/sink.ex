# SPDX-License-Identifier: Apache-2.0
defmodule Elzoo.AiBatch.Sink do
  @moduledoc """
  The volatile result sink of submit and cancel: a trusted 2-arity function
  `sink.(key, delivery)` that receives, once per attempt and from the send task,
  either `{:outcome, attempt_id, outcome}` or, when that first call failed,
  `{:sink_failed, attempt_id}`. Its result never changes the Adapter's
  classification or the intent settlement. No durable retention, replay,
  recovery delivery or exactly-once delivery: after an owner restart or a lost
  call the outcome (and so the provider job id) is gone and only the settled
  status remains; the caller owns the job reference's durability.
  """

  @doc "A sink that sends `{Elzoo.AiBatch, key, delivery}` to `pid`."
  def to_pid(pid) when is_pid(pid) do
    fn key, delivery ->
      send(pid, {Elzoo.AiBatch, key, delivery})
      :ok
    end
  end

  @doc false
  def deliver(sink, key, attempt_id, outcome) do
    if call(sink, key, {:outcome, attempt_id, outcome}) == :ok,
      do: :ok,
      else: call(sink, key, {:sink_failed, attempt_id})
  end

  defp call(sink, key, delivery) do
    case sink.(key, delivery) do
      :ok -> :ok
      _ -> :error
    end
  rescue
    _ -> :error
  catch
    _, _ -> :error
  end
end
