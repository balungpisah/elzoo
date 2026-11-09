# SPDX-License-Identifier: Apache-2.0
defmodule Elzoo.AiText.Sink do
  @moduledoc """
  The volatile result sink: a trusted 2-arity function `sink.(key, delivery)`
  that receives, once per attempt and from the send task, either
  `{:outcome, attempt_id, outcome}` or, when that first call failed,
  `{:sink_failed, attempt_id}`. The sink's result never changes the Adapter's
  classification or the intent settlement. No durable retention, replay,
  recovery delivery or exactly-once delivery is supplied: after an owner
  restart or a lost call the content is gone and only the settled status
  remains. `to_pid/1` is the simple local form.
  """

  @doc "A sink that sends `{Elzoo.AiText, key, delivery}` to `pid`."
  def to_pid(pid) when is_pid(pid) do
    fn key, delivery ->
      send(pid, {Elzoo.AiText, key, delivery})
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
