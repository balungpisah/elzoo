# SPDX-License-Identifier: Apache-2.0
defmodule Elzoo.Budget.Owner do
  @moduledoc """
  Volatile owner for one budget identity, built on the unchanged `Elzoo.Unit`.

  Every client function reads the wall clock in the caller, then calls
  `Elzoo.Unit.step(owner, {now_ms, input})`. The Unit mailbox serializes
  callers. An owner that is not running, has exited or does not answer within
  `GenServer.call/2`'s fixed 5000 ms default gives `{:rejected,
  :owner_unavailable}` (fail closed). After a timeout the input may still have
  been applied.

  Holding the owner pid is the only authority. The child spec uses
  `restart: :temporary`: a crash leaves the budget unavailable until the
  Assembly starts a new owner, which gets a new random incarnation.
  """

  @start_keys [:budget_id, :cap, :unit]

  @spec child_spec(keyword()) :: Supervisor.child_spec()
  def child_spec(opts) do
    %{id: __MODULE__, start: {__MODULE__, :start_link, [opts]}, restart: :temporary}
  end

  @doc "Start an owner with sealed `budget_id`, `cap` and `unit`."
  @spec start_link(term()) :: GenServer.on_start() | {:error, atom()}
  def start_link(opts) do
    with true <- Keyword.keyword?(opts) and Enum.sort(Keyword.keys(opts)) == Enum.sort(@start_keys),
         {:ok, state} <-
           Elzoo.Budget.initial(opts[:budget_id], incarnation(), opts[:cap], opts[:unit]) do
      Elzoo.Unit.start_link({Elzoo.Budget, :step, state})
    else
      false -> {:error, :invalid_input}
      {:error, reason} -> {:error, reason}
    end
  end

  def reserve(owner, fields), do: call(owner, {:reserve, fields})
  def settle(owner, fields), do: call(owner, {:settle, fields})
  def release(owner, fields), do: call(owner, {:release, fields})
  def reset(owner, fields), do: call(owner, {:reset, fields})
  def status(owner), do: call(owner, :status)
  def sweep(owner), do: call(owner, :sweep)

  defp call(owner, input) do
    now = System.os_time(:millisecond)

    case Elzoo.Unit.step(owner, {now, input}) do
      {:some, result} -> result
      _other -> {:rejected, :owner_unavailable}
    end
  catch
    :exit, _reason -> {:rejected, :owner_unavailable}
  end

  defp incarnation, do: Base.encode16(:crypto.strong_rand_bytes(16), case: :lower)
end
