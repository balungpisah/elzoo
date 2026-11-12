# SPDX-License-Identifier: Apache-2.0
# Run with MIX_ENV=test mix run in Elzoo or the copied dependency closure.
defmodule DynamicUnitsExample do
  def step(state, input), do: {:Transition, state * 2 + input, :none}
end

alias Elzoo.{DurableUnit, DynamicUnits}
alias Elzoo.DurableLog.Memory

opts = [
  operator: {DynamicUnitsExample, :step, 3},
  retention_count: 2,
  max_record_bytes: 1_024,
  max_checkpoint_bytes: 100_000,
  offer: fn _ -> :ok end
]

{:ok, memory} = Memory.start_link(fold: DurableUnit.fold(opts), limits: DurableUnit.limits(opts))
opts = Keyword.put(opts, :store, Memory.store(memory))

# Caller owns the whole infrastructure boundary. One failed component resets
# Registry, child supervisor and controller together; Store history is external.
{:ok, boundary} =
  Supervisor.start_link(
    [
      {Registry, keys: :unique, name: DynamicUnitsExample.Registry},
      {DynamicSupervisor,
       strategy: :one_for_one, max_children: 2, name: DynamicUnitsExample.Children},
      {DynamicUnits,
       registry: DynamicUnitsExample.Registry,
       supervisor: DynamicUnitsExample.Children,
       name: DynamicUnitsExample.Directory,
       unit_options: fn _identity -> opts end,
       idle_ms: 60_000}
    ],
    strategy: :one_for_all
  )

directory = DynamicUnitsExample.Directory
{:ok, :routed} = DynamicUnits.route(directory, "room", {:durable_unit_input, "first", 5})
{:ok, first} = DynamicUnits.find(directory, "room")
11 = DurableUnit.snapshot(first)
# Routed is not acceptance: this synchronous duplicate reply establishes the
# retained committed result. Direct calls are outside directory idle accounting.
{:ok, :duplicate} = DurableUnit.step(first, "first", 5)
:ok = DynamicUnits.stop(directory, "room")
:not_found = DynamicUnits.find(directory, "room")
{:ok, :routed} = DynamicUnits.route(directory, "room", {:durable_unit_input, "second", -3})
{:ok, awakened} = DynamicUnits.find(directory, "room")
false = first == awakened
19 = DurableUnit.snapshot(awakened)
Supervisor.stop(boundary)
GenServer.stop(memory)
IO.puts("sleep/wake example passed (volatile Memory process recovery, not disk durability)")
