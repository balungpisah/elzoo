# SPDX-License-Identifier: Apache-2.0
defmodule AsyncWorkExample.Owner do
  use GenServer

  def start_link(name), do: GenServer.start_link(__MODULE__, nil, name: name)
  def init(nil), do: {:ok, MapSet.new()}

  def handle_call({:open, ref}, _, open), do: {:reply, :ok, MapSet.put(open, ref)}
  def handle_call({:close, ref}, _, open), do: {:reply, :ok, MapSet.delete(open, ref)}

  def handle_info({:input, value}, open) do
    IO.inspect(value, label: "ordinary owner input")
    {:noreply, open}
  end

  def handle_info({:work, ref, outcome}, open) do
    # Consumer-owned diagnostics; only open local actions may apply a result.
    if MapSet.member?(open, ref), do: IO.inspect(outcome, label: "local outcome")
    {:noreply, MapSet.delete(open, ref)}
  end
end

owner = {:via, Registry, {AsyncWorkExample.Registry, :owner}}

{:ok, supervisor} =
  Supervisor.start_link(
    [
      {Registry, keys: :unique, name: AsyncWorkExample.Registry},
      {Task.Supervisor, name: AsyncWorkExample.Tasks},
      {AsyncWorkExample.Owner, owner},
      {Elzoo.AsyncWork,
       owner: owner,
       task_supervisor: AsyncWorkExample.Tasks,
       max_concurrency: 2,
       name: AsyncWorkExample.Controller}
    ],
    strategy: :one_for_one
  )

# A barrier makes both owner responsiveness and cancellation visible.
observer = self()
wrap = fn ref, outcome -> {:work, ref, outcome} end

{:ok, ref} =
  Elzoo.AsyncWork.start(
    AsyncWorkExample.Controller,
    fn ->
      send(observer, {:running, self()})
      receive do: (:release -> 6 * 7)
    end,
    5_000,
    wrap
  )

:ok = GenServer.call(owner, {:open, ref})
send(GenServer.whereis(owner), {:input, :still_responsive})
receive do: ({:running, worker} -> send(worker, :release))

{:ok, cancelled} =
  Elzoo.AsyncWork.start(
    AsyncWorkExample.Controller,
    fn ->
      receive do: (:release -> :unused)
    end,
    5_000,
    wrap
  )

:ok = GenServer.call(owner, {:close, cancelled})
:ok = Elzoo.AsyncWork.cancel(AsyncWorkExample.Controller, cancelled)
IO.puts("cancelled local work; owner rejects any late offer")
Supervisor.stop(supervisor)
