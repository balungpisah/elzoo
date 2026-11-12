# SPDX-License-Identifier: Apache-2.0
# Run with mix run in Elzoo or a consuming project with this dependency closure.
defmodule DurableUnitExample do
  def step(state, n), do: {:Transition, state * 2 + n, {:some, state * 2 + n}}
end

alias Elzoo.{DurableUnit, Outbox}
alias Elzoo.DurableLog.Memory

dispatcher = self()

opts = [
  stream: "example",
  operator: {DurableUnitExample, :step, 3},
  retention_count: 2,
  max_record_bytes: 1_024,
  max_checkpoint_bytes: 100_000,
  offer: fn %Outbox.Item{} = item ->
    send(dispatcher, {:offered, item})
    :ok
  end
]

{:ok, memory} = Memory.start_link(fold: DurableUnit.fold(opts), limits: DurableUnit.limits(opts))
store = Memory.store(memory)
opts = Keyword.put(opts, :store, store)
{:ok, unit} = DurableUnit.start_link(opts)
{:ok, :applied} = DurableUnit.step(unit, "input-1", 5)
11 = DurableUnit.snapshot(unit)
{:committed, 2} = DurableUnit.checkpoint(unit)
GenServer.stop(unit)
{:ok, unit} = DurableUnit.start_link(opts)
11 = DurableUnit.snapshot(unit)
{:ok, :duplicate} = DurableUnit.step(unit, "input-1", 5)

# Here the destination commit point is receipt in this caller-owned in-memory
# sink. A real dispatcher must commit at its own destination before this ack.
receive do
  {:offered, item} ->
    {:committed, 2} = Outbox.ack(store, item.idempotency_key, :crypto.strong_rand_bytes(16))
end

{:ok, 0} = DurableUnit.offer_pending(unit)
# The two-completion FIFO does not refresh on duplicates. Once an ID is evicted
# it may apply again. This window does not bound log/complete-witness memory.
GenServer.stop(unit)
GenServer.stop(memory)
IO.puts("apply/restart/duplicate/offer/ack example passed (volatile Memory, not disk durability)")
